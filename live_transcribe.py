"""Live-транскрипция во время записи: читает растущие mic.caf/system.caf,
транскрибирует чанки по мере поступления, на стоп — финальная диаризация и мерж.

Запускается Swift-приложением при старте записи:
    python live_transcribe.py <session-dir>

Сигнал остановки — файл-маркер <session>/.stopped (создаёт приложение при «Стоп»).
Выход: <session>/transcript.md (тот же формат, что у transcribe.py).

Идея: whisper на GPU 11x realtime → чанк 30с считается за ~3с, успевает вживую.
После «Стоп» остаётся лишь диаризация на полном system.caf — текст готов почти сразу.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import time
from pathlib import Path

from transcribe import (
    Segment, assign_speaker, dedupe_bleed, diarize, hhmmss,
    load_env, prettify_speaker, _is_hallucination,
)

REPO = "mlx-community/whisper-large-v3-mlx"
CHUNK_STEP = 30.0   # «своя» зона чанка, сек
OVERLAP = 3.0       # перекрытие для контекста
POLL = 12.0         # период опроса растущих файлов, сек
LANGUAGE = "ru"


def _duration(path: Path) -> float:
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, timeout=30)
        return float(r.stdout.strip())
    except (ValueError, subprocess.TimeoutExpired, subprocess.SubprocessError):
        return 0.0


def _transcribe_slice(src: Path, pos: float, dur: float, is_final: bool,
                      tmp: Path) -> list[tuple[float, float, str]]:
    """Транскрибирует «свою» зону [pos, pos+CHUNK_STEP) с контекстом-перекрытием
    СЛЕВА и справа (чтобы whisper не резал слова на границах), но оставляет только
    сегменты, чей ЦЕНТР попал в зону владения [pos, pos+CHUNK_STEP). Так каждый
    сегмент принадлежит ровно одному чанку — ни потерь, ни дублей на стыках."""
    import mlx_whisper
    slice_start = max(0.0, pos - OVERLAP)
    slice_end = min(dur, pos + CHUNK_STEP + OVERLAP)
    length = slice_end - slice_start
    if length <= 0.2:
        return []
    clip = tmp / "slice.wav"
    r = subprocess.run(
        ["ffmpeg", "-y", "-ss", str(slice_start), "-t", str(length),
         "-i", str(src), "-ar", "16000", "-ac", "1", str(clip)],
        capture_output=True, timeout=120)
    if r.returncode != 0 or not clip.exists() or clip.stat().st_size < 1000:
        return []  # ffmpeg сбойнул/пустой клип — пропускаем чанк, не роняем прогон
    result = mlx_whisper.transcribe(
        str(clip), path_or_hf_repo=REPO, language=LANGUAGE,
        condition_on_previous_text=False)
    out = []
    for seg in result["segments"]:
        txt = seg["text"].strip()
        if not txt or _is_hallucination(txt):
            continue
        abs_start = slice_start + float(seg["start"])
        abs_end = slice_start + float(seg["end"])
        center = (abs_start + abs_end) / 2
        if center < pos and pos > 0:
            continue  # принадлежит предыдущей зоне
        if center >= pos + CHUNK_STEP and not is_final:
            continue  # принадлежит следующей зоне
        out.append((abs_start, abs_end, txt))
    return out


def _drain_track(path: Path, pos: float, stopped: bool,
                 tmp: Path) -> tuple[list[tuple[float, float, str]], float]:
    """Дотранскрибирует всё доступное новое аудио дорожки. Возвращает (новые сегменты, новый pos)."""
    new: list[tuple[float, float, str]] = []
    if not path.exists():
        return new, pos
    dur = _duration(path)
    while True:
        avail = dur - pos
        # во время записи ждём полную зону; после стопа добираем хвост
        if avail < CHUNK_STEP + OVERLAP and not stopped:
            break
        if avail <= 0.3:
            break
        is_final = (pos + CHUNK_STEP >= dur)
        try:
            new.extend(_transcribe_slice(path, pos, dur, is_final, tmp))
        except Exception as e:  # noqa: BLE001 — один плохой чанк не должен ронять прогон
            print(f"  чанк @ {pos:.0f}s пропущен: {e}")
        pos += CHUNK_STEP
        if pos >= dur:
            break
    return new, pos


def _write_partial(session: Path, mic: list, system: list) -> None:
    """Промежуточный текст (без спикеров) — можно подсматривать во время встречи."""
    segs = ([Segment(s, e, t, "Я") for s, e, t in mic]
            + [Segment(s, e, t, "Собеседник") for s, e, t in system])
    segs.sort(key=lambda x: x.start)
    lines = ["# Транскрипт (идёт запись…)\n"]
    for sg in segs:
        lines.append(f"**[{hhmmss(sg.start)}] {sg.speaker}:** {sg.text}")
    (session / "live_partial.md").write_text("\n\n".join(lines) + "\n", encoding="utf-8")


def _finalize(session: Path, mic: list, system: list) -> None:
    """Диаризация полного system.caf + мерж + дедуп → transcript.md."""
    import os
    segments: list[Segment] = [Segment(s, e, t, "Я") for s, e, t in mic]

    turns: list[tuple[float, float, str]] = []
    hf_token = os.environ.get("HF_TOKEN", "")
    sys_path = session / "system.caf"
    if hf_token and sys_path.exists() and _duration(sys_path) > 1:
        print("Финал: диаризация…")
        try:
            turns = diarize(sys_path, hf_token)
        except Exception as e:  # noqa: BLE001
            print(f"  диаризация не удалась: {e}")

    for s, e, t in system:
        spk = prettify_speaker(assign_speaker(s, e, turns)) if turns else "Собеседник"
        segments.append(Segment(s, e, t, spk))

    segments = dedupe_bleed(segments)
    segments.sort(key=lambda x: x.start)

    out = session / "transcript.md"
    lines = [f"# Транскрипт встречи — {session.name}\n"]
    for sg in segments:
        lines.append(f"**[{hhmmss(sg.start)}] {sg.speaker}:** {sg.text}")
    out.write_text("\n\n".join(lines) + "\n", encoding="utf-8")
    print(f"Готово: {out}  ({len(segments)} реплик)")


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("Использование: python live_transcribe.py <session-dir>")
    session = Path(sys.argv[1])
    load_env()
    tmp = Path(tempfile.mkdtemp())
    mic_path = session / "mic.caf"
    sys_path = session / "system.caf"
    stop_marker = session / ".stopped"

    mic_segs: list[tuple[float, float, str]] = []
    sys_segs: list[tuple[float, float, str]] = []
    mic_pos = sys_pos = 0.0
    print(f"live-транскрипция: {session.name}")

    while True:
        stopped = stop_marker.exists()
        new_mic, mic_pos = _drain_track(mic_path, mic_pos, stopped, tmp)
        new_sys, sys_pos = _drain_track(sys_path, sys_pos, stopped, tmp)
        mic_segs.extend(new_mic)
        sys_segs.extend(new_sys)
        if new_mic or new_sys:
            _write_partial(session, mic_segs, sys_segs)
            print(f"  чанки: мик {len(mic_segs)} сегм, система {len(sys_segs)} сегм")

        if stopped:
            mic_done = (not mic_path.exists()) or mic_pos >= _duration(mic_path) - 0.5
            sys_done = (not sys_path.exists()) or sys_pos >= _duration(sys_path) - 0.5
            if mic_done and sys_done:
                break
        time.sleep(POLL)

    _finalize(session, mic_segs, sys_segs)
    import shutil
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
