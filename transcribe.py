"""Транскрибирует записанную встречу и размечает спикеров.

Пайплайн:
    1. MLX-whisper (Apple GPU) по обеим дорожкам (mic.wav = "Я", system.wav = собеседники)
    2. pyannote диаризирует system.wav -> Speaker 1/2/3...
    3. каждому whisper-сегменту system.wav присваивается спикер по максимальному
       перекрытию с турном диаризации
    4. мерж всех сегментов по таймлайну -> transcript.md

Использование:
    python transcribe.py recordings/2026-07-15_10-30-00
    python transcribe.py recordings/<...> --model large-v3 --language ru --no-diarize

Диаризация требует HF-токен (env HF_TOKEN или .env) и принятых условий модели
pyannote/speaker-diarization-community-1 на Hugging Face. Без токена — пропускается
(--no-diarize или отсутствие HF_TOKEN), все реплики system.wav идут как "Собеседник".
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


def mean_volume_db(path: Path) -> float:
    """Средняя громкость дорожки в dB (через ffmpeg). Тишина ≈ -91 dB.
    При сбое возвращает 0.0 (трактуется как «есть звук» — безопаснее пропустить фильтр)."""
    try:
        r = subprocess.run(
            ["ffmpeg", "-i", str(path), "-af", "volumedetect", "-f", "null", "/dev/null"],
            capture_output=True, text=True, timeout=120)
    except (subprocess.TimeoutExpired, subprocess.SubprocessError):
        return 0.0
    for line in r.stderr.splitlines():
        if "mean_volume:" in line:
            try:
                return float(line.split("mean_volume:")[1].split("dB")[0].strip())
            except ValueError:
                return 0.0
    return 0.0


@dataclass
class Segment:
    start: float
    end: float
    text: str
    speaker: str


def load_env() -> None:
    """Подхватывает .env из папки проекта в os.environ (без внешних зависимостей)."""
    env_path = Path(__file__).parent / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip())


def find_track(session: Path, stem: str) -> Path:
    """Ищет дорожку mic/system с любым расширением (wav от Python, caf от Swift)."""
    for ext in ("wav", "caf", "m4a", "flac", "aiff"):
        p = session / f"{stem}.{ext}"
        if p.exists():
            return p
    return session / f"{stem}.wav"  # дефолт для сообщения "не найдено"


def hhmmss(sec: float) -> str:
    m, s = divmod(int(sec), 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


# Whisper на Apple GPU через MLX (Metal) — ~7x быстрее CPU-CTranslate2 на M-серии.
MLX_REPOS = {
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
    "medium": "mlx-community/whisper-medium-mlx",
    "small": "mlx-community/whisper-small-mlx",
    "base": "mlx-community/whisper-base-mlx",
}


# Типовые галлюцинации whisper на тишине/паузах (артефакты обучения на YouTube).
# Дропаем сегмент, если его нормализованный текст — целиком одна из этих фраз.
HALLUCINATION_PHRASES = {
    "продолжение следует",
    "спасибо за просмотр",
    "спасибо за внимание",
    "подписывайтесь на канал",
    "спасибо что смотрите",
    "до новых встреч",
    "субтитры сделал dimatorzok",
    "субтитры создавал dimatorzok",
    "редактор субтитров а семкин корректор а егорова",
}


_HALLUCINATION_RE = re.compile(
    r"^(спасибо за субтитры|субтитры .{0,50}(сделал|создал|редактор|подготовил)"
    r"|редактор субтитров)")


def _is_hallucination(text: str) -> bool:
    n = _norm(text)
    return n in HALLUCINATION_PHRASES or bool(_HALLUCINATION_RE.match(n))


def transcribe_track(repo: str, path: Path,
                     language: str | None) -> list[tuple[float, float, str]]:
    """Возвращает список (start, end, text) для дорожки (MLX, GPU)."""
    # Тихую дорожку не транскрибируем — иначе whisper галлюцинирует
    # («Продолжение следует…», «Спасибо за просмотр» и т.п.).
    vol = mean_volume_db(path)
    if vol < -60:
        print(f"  {path.name}: тишина ({vol:.0f} dB) — пропуск")
        return []

    import mlx_whisper
    result = mlx_whisper.transcribe(
        str(path), path_or_hf_repo=repo, language=language,
        condition_on_previous_text=False,  # меньше зацикливаний/галлюцинаций
    )
    print(f"  {path.name}: язык={result.get('language', language)}")
    out = []
    dropped = 0
    for seg in result["segments"]:
        txt = seg["text"].strip()
        if not txt:
            continue
        # Галлюцинации на паузах: типовая фраза-артефакт, либо высокая «нет речи»
        # + низкая уверенность (у MLX нет VAD, поэтому фильтруем сами).
        if _is_hallucination(txt) or (
            seg.get("no_speech_prob", 0.0) > 0.8 and seg.get("avg_logprob", 0.0) < -0.5
        ):
            dropped += 1
            continue
        out.append((float(seg["start"]), float(seg["end"]), txt))
    tail = f" (отсеяно {dropped} на тишине)" if dropped else ""
    print(f"  {path.name}: {len(out)} сегментов{tail}")
    return out


def diarize(path: Path, hf_token: str,
            num_speakers: int | None = None,
            max_speakers: int | None = None) -> list[tuple[float, float, str]]:
    """Возвращает список (start, end, speaker_label) турнов диаризации.

    num_speakers: точное число говорящих, если оно достоверно известно.
    max_speakers: верхняя граница. Именно её стоит брать из календаря —
        подтвердивших приглашение обычно больше, чем реально говоривших
        (на встрече из 15 человек говорят 13, остальные молчат). Если
        зафиксировать точное число, алгоритм начнёт дробить одного
        человека на нескольких, чтобы добить до заданного количества.
    """
    import torch
    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-community-1", token=hf_token
    )
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))
    elif torch.cuda.is_available():
        pipeline.to(torch.device("cuda"))

    kwargs: dict[str, int] = {}
    if num_speakers:
        kwargs["num_speakers"] = num_speakers
    elif max_speakers:
        kwargs["max_speakers"] = max_speakers
    dia = pipeline(str(path), **kwargs)
    # pyannote 4.x возвращает DiarizeOutput; аннотация — в .speaker_diarization.
    # Старые версии возвращают Annotation напрямую.
    annotation = getattr(dia, "speaker_diarization", dia)
    turns = [(t.start, t.end, spk)
             for t, _, spk in annotation.itertracks(yield_label=True)]
    n_speakers = len({spk for _, _, spk in turns})
    print(f"  диаризация: {len(turns)} турнов, {n_speakers} спикер(ов)")
    return turns


def assign_speaker(seg_start: float, seg_end: float,
                   turns: list[tuple[float, float, str]]) -> str:
    """Присваивает спикера по максимальному перекрытию сегмента с турнами."""
    best_spk, best_overlap = None, 0.0
    for t_start, t_end, spk in turns:
        overlap = max(0.0, min(seg_end, t_end) - max(seg_start, t_start))
        if overlap > best_overlap:
            best_spk, best_overlap = spk, overlap
    return best_spk or "Собеседник"


def _norm(text: str) -> str:
    """Нормализует текст для сравнения: нижний регистр, без пунктуации/лишних пробелов."""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", text.lower())).strip()


def dedupe_bleed(segments: list["Segment"], time_tol: float = 10.0,
                 contain_threshold: float = 0.6,
                 echo_session_ratio: float = 0.5,
                 overlap_tol: float = 2.0) -> list["Segment"]:
    """Убирает протечку системного звука в микрофон (эхо из динамиков без наушников).

    Опора на физику, а не на эвристику: СВОЙ голос никогда не попадает в системную
    дорожку — конференция не проигрывает тебя тебе же. Значит любой текст микрофона,
    который звучит и в системной дорожке рядом по времени, — это эхо из динамиков,
    а не твоя речь. Удалять такое безопасно: настоящие реплики совпасть не могут.

    Сравниваем по ДОЛЕ общих слов, а не по схожести строк целиком: whisper режет
    две дорожки на сегменты по-разному, и эхо приходит со сдвигом 1-4 секунды,
    поэтому посегментное сравнение промахивается (реальный случай: 413 чужих
    реплик, помеченных как «Я», при выключенном микрофоне).
    """
    system_segs = [s for s in segments if s.speaker != "Я"]
    mic_total = sum(1 for s in segments if s.speaker == "Я")
    if not system_segs or not mic_total:
        return segments

    # Проход 1: эхо, которое расслышано так же, как оригинал — ловим по словам.
    kept: list[Segment] = []
    dropped = 0
    for seg in segments:
        if seg.speaker == "Я":
            words = set(_norm(seg.text).split())
            if words:
                # ponytail: линейный проход по системным сегментам, O(mic*system).
                # На часовой встрече ~0.6M сравнений множеств — доли секунды.
                # Бакетизация по времени — если корпус вырастет на порядок.
                near: set[str] = set()
                for sys_seg in system_segs:
                    if abs(sys_seg.start - seg.start) <= time_tol:
                        near.update(_norm(sys_seg.text).split())
                if near and len(words & near) / len(words) >= contain_threshold:
                    dropped += 1
                    continue
        kept.append(seg)

    # Проход 2 — только если запись явно велась БЕЗ наушников (эхом оказалась
    # большая часть микрофонной дорожки). Остаток эха whisper расслышал иначе,
    # чем оригинал (звук из динамиков хуже), поэтому по словам он не ловится.
    # Но живая речь идёт в ПАУЗАХ чужой (люди говорят по очереди), а эхо звучит
    # одновременно с ней. На сессиях в наушниках правило не включается вовсе.
    if dropped / mic_total >= echo_session_ratio:
        pruned: list[Segment] = []
        dropped2 = 0
        for seg in kept:
            if seg.speaker == "Я" and any(
                abs(s.start - seg.start) <= overlap_tol for s in system_segs
            ):
                dropped2 += 1
                continue
            pruned.append(seg)
        kept, dropped = pruned, dropped + dropped2
        print(f"  запись велась без наушников — микрофон ловил динамики "
              f"(эхом оказалось {dropped}/{mic_total} реплик). Наушники это убирают.")
    if dropped:
        print(f"  дедуп: убрано {dropped} микрофонных дублей (эхо из динамиков)")
    return kept


def load_meeting_meta(session: Path) -> dict:
    """Данные встречи из календаря (пишет приложение при старте записи):
    {"title": ..., "attendees": [...], "accepted_count": N}. Нет файла — пусто."""
    p = session / "meeting.json"
    if not p.exists():
        return {}
    try:
        import json
        return json.loads(p.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return {}


def prettify_speaker(label: str) -> str:
    """SPEAKER_00 -> Собеседник 1."""
    if label.startswith("SPEAKER_"):
        try:
            return f"Собеседник {int(label.split('_')[1]) + 1}"
        except (IndexError, ValueError):
            return label
    return label


def build_transcript(session: Path, model_name: str, language: str | None,
                     do_diarize: bool, num_speakers: int | None = None,
                     dedupe: bool = True) -> Path:
    mic = find_track(session, "mic")
    system = find_track(session, "system")
    meta = load_meeting_meta(session)

    repo = MLX_REPOS.get(model_name, model_name)  # можно передать и полный HF-repo
    print(f"Whisper на GPU (MLX): {model_name} → {repo}")

    segments: list[Segment] = []

    if mic.exists():
        print("Транскрипция микрофона:")
        for s, e, txt in transcribe_track(repo, mic, language):
            segments.append(Segment(s, e, txt, "Я"))

    if system.exists():
        print("Транскрипция системного звука:")
        sys_segs = transcribe_track(repo, system, language)
        turns: list[tuple[float, float, str]] = []
        hf_token = os.environ.get("HF_TOKEN", "")
        if do_diarize and hf_token:
            print("Диаризация системного звука:")
            # Из календаря берём ВЕРХНЮЮ границу (кто подтвердил приглашение) —
            # часть из них на встрече молчит, точное число задавать нельзя.
            cap = meta.get("accepted_count") or None
            if cap and not num_speakers:
                print(f"  подтвердили приглашение: {cap} → верхняя граница спикеров")
            try:
                turns = diarize(system, hf_token, num_speakers, max_speakers=cap)
            except Exception as e:  # noqa: BLE001 — не терять транскрипт из-за сбоя диаризации
                print(f"  диаризация не удалась ({e}) — реплики пойдут как «Собеседник»")
        elif do_diarize and not hf_token:
            print("  HF_TOKEN не задан — диаризация пропущена (см. README).")
        for s, e, txt in sys_segs:
            spk = prettify_speaker(assign_speaker(s, e, turns)) if turns else "Собеседник"
            segments.append(Segment(s, e, txt, spk))

    if dedupe:
        segments = dedupe_bleed(segments)
    segments.sort(key=lambda x: x.start)

    out = session / "transcript.md"
    title = meta.get("title") or session.name
    lines = [f"# Транскрипт встречи — {title}\n"]
    # Кто был на встрече: спикеров алгоритм называет «Собеседник N», и без
    # списка участников читатель вообще не понимает, чьи это реплики.
    if meta.get("attendees"):
        lines.append("**Участники:** " + ", ".join(meta["attendees"]) + "\n")
    for seg in segments:
        lines.append(f"**[{hhmmss(seg.start)}] {seg.speaker}:** {seg.text}")
    out.write_text("\n\n".join(lines) + "\n", encoding="utf-8")
    print(f"\nГотово: {out}  ({len(segments)} реплик)")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Транскрипт + диаризация записанной встречи")
    ap.add_argument("session", type=Path, help="папка recordings/<timestamp>")
    ap.add_argument("--model", default="auto",
                    help="whisper модель или 'auto' — подбор под железо (default auto)")
    ap.add_argument("--resource-mode", choices=("auto", "low", "high"), default="auto",
                    help="auto — модель под мощность машины; low — легче+уступать CPU; "
                         "high — форсировать large-v3 (default auto)")
    ap.add_argument("--language", default="ru", help="код языка или 'auto' (default ru)")
    ap.add_argument("--no-diarize", action="store_true", help="не размечать спикеров")
    ap.add_argument("--speakers", type=int, default=None,
                    help="точное число участников (подсказка диаризации; иначе авто)")
    ap.add_argument("--no-dedupe", action="store_true",
                    help="не убирать протечку системного звука в микрофон")
    args = ap.parse_args()

    load_env()
    if not args.session.is_dir():
        raise SystemExit(f"Папка не найдена: {args.session}")

    import capability
    if args.resource_mode == "low":
        capability.apply_nice()
    model = args.model
    if model == "auto":
        model = capability.pick_model(args.resource_mode)
        print(capability.describe(args.resource_mode))

    language = None if args.language == "auto" else args.language
    build_transcript(args.session, model, language, not args.no_diarize,
                     args.speakers, not args.no_dedupe)


if __name__ == "__main__":
    main()
