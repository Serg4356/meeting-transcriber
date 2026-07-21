"""Определение владельца записи по голосу — без ручной разметки и без наушников.

Задача: понять, какие куски микрофонной дорожки принадлежат владельцу. Просто
«весь микрофон = владелец» неверно: без наушников туда попадают собеседники из
колонок, а в общественном месте — случайные прохожие. Реальный замер: из 167
секунд речи в микрофоне 111 оказались чужим человеком из динамиков.

Метод опирается на два физических факта, оба проверены на реальных записях:

1. Голос владельца попадает в микрофон НАПРЯМУЮ, а все остальные — через путь
   «динамик → комната → микрофон», который сильно искажает тембр. Замерено:
   голос коллеги, пришедший через колонки, совпадает со своим же чистым
   отпечатком лишь на 0.521 при пороге 0.75, то есть НЕ УЗНАЁТСЯ. Владелец же
   узнаётся на 0.95.
2. Поэтому только владелец стабильно похож сам на себя между встречами (замер:
   0.822 в двух независимых записях). Искажённое эхо каждый раз искажается
   по-своему и само с собой не схлопывается.

ВАЖНО, чего делать НЕЛЬЗЯ: считать «не совпал с системной дорожкой = живой
человек рядом». Проверено на реальной встрече — так коллеги, пришедшие через
колонки, были ошибочно приняты за прохожих в коридоре. Совпадение с системной
дорожкой отсеивает лишь часть эха, остальное отсеивается пунктом 2.

Использование:
    python owner.py            # показать, кто определился владельцем
    python owner.py --enroll   # + внести его в библиотеку голосов
"""
from __future__ import annotations

import argparse
import itertools
import json
import os
import subprocess
import tempfile
from pathlib import Path

import voiceprints as vp
from transcribe import load_env

# Порог, выше которого кластер микрофона считается эхом системной дорожки.
ECHO_MATCH = 0.75
# Порог «это один и тот же человек на разных встречах». Поднят до 0.70:
# искажённое эхо иногда случайно совпадает на 0.6, владелец даёт 0.82.
SAME_PERSON = 0.70
# Сколько секунд речи должно быть у кандидата, чтобы его вообще рассматривать.
MIN_SPEECH = 10.0

CACHE = "voices.json"


def _slice_wav(src: Path, dst: str, start: float, dur: float) -> bool:
    r = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-ss", str(start),
                        "-t", str(dur), "-i", str(src), "-ar", "16000", "-ac", "1", dst],
                       capture_output=True)
    return r.returncode == 0 and os.path.getsize(dst) > 1000


def session_voices(session: Path, hf_token: str, window: float = 300.0,
                   offset: float = 180.0, refresh: bool = False) -> dict:
    """Голоса сессии: кластеры микрофона (кроме эха) и системной дорожки.

    Результат кэшируется рядом с записью — диаризация дорогая, а прогонять
    определение владельца приходится по многим встречам сразу.
    """
    cache = session / CACHE
    if cache.exists() and not refresh:
        try:
            return json.loads(cache.read_text(encoding="utf-8"))
        except ValueError:
            pass

    from transcribe import diarize

    out: dict = {"candidates": {}, "system_count": 0}
    with tempfile.TemporaryDirectory() as tmp:
        tracks = {}
        for name in ("mic", "system"):
            src = session / f"{name}.caf"
            dst = f"{tmp}/{name}.wav"
            if src.exists() and _slice_wav(src, dst, offset, window):
                tracks[name] = dst
        if "mic" not in tracks or "system" not in tracks:
            return out

        mt, mv = diarize(Path(tracks["mic"]), hf_token)
        st, sv = diarize(Path(tracks["system"]), hf_token)
        if not mv or not sv:
            return out
        out["system_count"] = len(sv)
        dur = {l: sum(e - b for b, e, x in mt if x == l) for l in mv}
        for label, vec in mv.items():
            echo = max(vp.cosine(vec, s) for s in sv.values())
            if echo >= ECHO_MATCH or dur.get(label, 0) < MIN_SPEECH:
                continue
            out["candidates"][label] = {"vec": vec, "seconds": round(dur[label], 1),
                                        "echo_score": round(echo, 3)}
    cache.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    return out


def owner_name(session: Path) -> str | None:
    """Имя владельца из календаря: участник, которого нет среди «остальных»."""
    p = session / "meeting.json"
    if not p.exists():
        return None
    try:
        meta = json.loads(p.read_text(encoding="utf-8"))
    except ValueError:
        return None
    others = set(meta.get("others", []))
    return next((a for a in meta.get("attendees", []) if a not in others), None)


def identify(sessions: list[Path], hf_token: str, refresh: bool = False) -> tuple[list | None, dict]:
    """Возвращает (вектор владельца, отчёт). Владелец — кандидат, повторяющийся
    в наибольшем числе встреч: прохожий встречается один раз, владелец — всегда."""
    pool: dict[str, dict] = {}
    for s in sessions:
        for label, rec in session_voices(s, hf_token, refresh=refresh)["candidates"].items():
            pool[f"{s.name}/{label}"] = rec

    hits: dict[str, set] = {k: set() for k in pool}
    for a, b in itertools.combinations(pool, 2):
        if a.split("/")[0] == b.split("/")[0]:
            continue  # внутри одной встречи не считаем
        if vp.cosine(pool[a]["vec"], pool[b]["vec"]) >= SAME_PERSON:
            hits[a].add(b.split("/")[0])
            hits[b].add(a.split("/")[0])

    report = {k: {"seconds": pool[k]["seconds"], "in_meetings": len(hits[k]) + 1} for k in pool}
    if not pool:
        return None, report
    best = max(pool, key=lambda k: (len(hits[k]), pool[k]["seconds"]))
    # Один-единственный кандидат без подтверждения другой встречей — это может
    # быть и прохожий. Требуем, чтобы голос встретился минимум в двух записях.
    if not hits[best]:
        return None, report

    group = [pool[best]["vec"]] + [pool[k]["vec"] for k in pool
                                   if k != best and k.split("/")[0] in hits[best]
                                   and vp.cosine(pool[best]["vec"], pool[k]["vec"]) >= SAME_PERSON]
    mean = [sum(c) / len(group) for c in zip(*group)]
    return mean, report


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", type=Path,
                    default=Path.home() / "Documents" / "Meeting Transcriber" / "Записи")
    ap.add_argument("--limit", type=int, default=8, help="сколько последних встреч смотреть")
    ap.add_argument("--enroll", action="store_true", help="внести владельца в библиотеку")
    ap.add_argument("--refresh", action="store_true", help="пересчитать кэш голосов")
    args = ap.parse_args()

    load_env()
    token = os.environ.get("HF_TOKEN", "")
    if not token:
        raise SystemExit("HF_TOKEN не задан — без него диаризация невозможна")

    sessions = sorted((p for p in args.dir.iterdir()
                       if p.is_dir() and (p / "mic.caf").exists()),
                      reverse=True)[:args.limit]
    print(f"Смотрю {len(sessions)} записей…")
    vec, report = identify(sessions, token, refresh=args.refresh)

    print(f"\n  {'кандидат':<34}{'речи':>7}{'встреч':>8}")
    for k, r in sorted(report.items(), key=lambda kv: -kv[1]["in_meetings"]):
        print(f"  {k:<34}{r['seconds']:>6.0f}с{r['in_meetings']:>7}")

    if vec is None:
        print("\nВладелец не определён: ни один голос не повторился в двух встречах.")
        return

    name = next((owner_name(s) for s in sessions if owner_name(s)), None)
    print(f"\nВладелец определён. Имя из календаря: {name or '(не найдено)'}")
    if args.enroll:
        if not name:
            raise SystemExit("Без имени вносить нельзя — нет данных календаря")
        vp.save(vp.enroll(vp.load(), name, vec))
        print(f"Внесён в библиотеку: {name}")
    else:
        print("Повтори с --enroll, чтобы внести в библиотеку.")


if __name__ == "__main__":
    main()
