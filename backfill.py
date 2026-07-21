"""Ретроспектива: достаёт данные встреч из календаря для уже сделанных записей
и переименовывает спикеров по библиотеке голосов.

Зачем: записи, сделанные до появления авто-разметки, лежат с метками
«Собеседник 1..N». Календарь помнит, что это были за встречи и кто на них был,
а звук сохранён — значит имена можно восстановить задним числом.

    python backfill.py            # только подтянуть данные встреч (быстро, без GPU)
    python backfill.py --rerun    # + перепрогнать диаризацию и переписать транскрипты

Порядок обработки не случайный: сначала встречи один-на-один — они пополняют
библиотеку голосов, — и только потом групповые, где эта библиотека применяется.
"""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timedelta
from pathlib import Path

from transcribe import (Segment, assign_speaker, diarize, hhmmss, load_env,
                        load_meeting_meta, prettify_speaker, resolve_speaker_names)

SESSION_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})[_ ](\d{2})-(\d{2})-(\d{2})$")
LINE_RE = re.compile(r"^\*\*\[(\d+:\d+(?::\d+)?)\]\s*([^:]+):\*\*\s*(.+)$")


def session_start(session: Path) -> datetime | None:
    m = SESSION_RE.match(session.name)
    if not m:
        return None
    d, hh, mm, ss = m.groups()
    return datetime.fromisoformat(f"{d}T{hh}:{mm}:{ss}")


def fetch_event(start: datetime, tolerance_min: int = 15) -> dict | None:
    """Событие календаря, начавшееся рядом с моментом записи."""
    from googleapiclient.discovery import build

    from calendar_watch import get_credentials  # переиспользуем ту же авторизацию

    svc = build("calendar", "v3", credentials=get_credentials(interactive=False),
                cache_discovery=False)
    lo = (start - timedelta(minutes=tolerance_min)).astimezone()
    hi = (start + timedelta(minutes=tolerance_min)).astimezone()
    items = svc.events().list(calendarId="primary",
                              timeMin=lo.isoformat(), timeMax=hi.isoformat(),
                              singleEvents=True, orderBy="startTime").execute().get("items", [])
    best, best_gap = None, None
    for ev in items:
        raw = ev.get("start", {}).get("dateTime")
        if not raw:
            continue
        gap = abs((datetime.fromisoformat(raw).replace(tzinfo=None) - start).total_seconds())
        if best_gap is None or gap < best_gap:
            best, best_gap = ev, gap
    return best


def write_meta(session: Path, ev: dict) -> dict:
    from calendar_watch import attendee_name  # одна логика имён на весь проект

    att = [a for a in ev.get("attendees", []) if not a.get("resource")]
    meta = {
        "title": ev.get("summary", session.name),
        "attendees": [attendee_name(a) for a in att],
        "accepted_count": sum(1 for a in att if a.get("responseStatus") == "accepted"),
        "others": [attendee_name(a) for a in att if not a.get("self")],
    }
    (session / "meeting.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    return meta


def parse_transcript(path: Path) -> list[Segment]:
    """Читает готовый transcript.md обратно в сегменты — чтобы не гонять
    whisper заново: текст уже распознан, менять нужно только имена."""
    segs = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = LINE_RE.match(line.strip())
        if not m:
            continue
        parts = [int(x) for x in m.group(1).split(":")]
        sec = parts[0] * 3600 + parts[1] * 60 + parts[2] if len(parts) == 3 \
            else parts[0] * 60 + parts[1]
        segs.append(Segment(float(sec), float(sec) + 3, m.group(3).strip(), m.group(2).strip()))
    return segs


def rename_speakers(session: Path, meta: dict, hf_token: str) -> int:
    """Перепрогоняет диаризацию и переписывает имена в существующем транскрипте."""
    audio = session / "system.caf"
    tpath = session / "transcript.md"
    if not audio.exists() or not tpath.exists():
        return 0
    segs = parse_transcript(tpath)
    if not segs:
        return 0
    turns, vecs = diarize(audio, hf_token, max_speakers=meta.get("accepted_count") or None)
    names = resolve_speaker_names(turns, vecs, meta)
    if not turns:
        return 0

    renamed = 0
    for sg in segs:
        if sg.speaker == "Я":       # своя дорожка — её диаризация не касается
            continue
        lbl = assign_speaker(sg.start, sg.end, turns)
        new = names.get(lbl) or prettify_speaker(lbl)
        if new != sg.speaker:
            sg.speaker = new
            renamed += 1

    lines = [f"# Транскрипт встречи — {meta.get('title') or session.name}\n"]
    if meta.get("attendees"):
        lines.append("**Участники:** " + ", ".join(meta["attendees"]) + "\n")
    for sg in segs:
        lines.append(f"**[{hhmmss(sg.start)}] {sg.speaker}:** {sg.text}")
    tpath.write_text("\n\n".join(lines) + "\n", encoding="utf-8")
    return renamed


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", type=Path,
                    default=Path.home() / "Documents" / "Meeting Transcriber" / "Записи")
    ap.add_argument("--rerun", action="store_true",
                    help="перепрогнать диаризацию и переписать имена в транскриптах")
    args = ap.parse_args()
    load_env()

    import os
    hf_token = os.environ.get("HF_TOKEN", "")
    sessions = sorted([p for p in args.dir.iterdir() if p.is_dir()])

    # 1) данные встреч из календаря
    metas: dict[Path, dict] = {}
    for s in sessions:
        meta = load_meeting_meta(s)
        if not meta and session_start(s):
            try:
                ev = fetch_event(session_start(s))
            except Exception as e:  # noqa: BLE001 — одна неудача не должна ронять проход
                print(f"  {s.name}: календарь недоступен ({e})")
                ev = None
            if ev:
                meta = write_meta(s, ev)
                print(f"  {s.name}: {meta['title'][:40]} "
                      f"(участников {len(meta['attendees'])})")
        if meta:
            metas[s] = meta

    print(f"\nданные встреч есть у {len(metas)} из {len(sessions)} записей")
    if not args.rerun:
        print("для переименования спикеров запусти с --rerun")
        return
    if not hf_token:
        print("HF_TOKEN не задан — диаризация невозможна")
        return

    # 2) сначала 1:1 (пополняют библиотеку), потом групповые (используют её)
    order = sorted(metas, key=lambda s: len(metas[s].get("others") or []) != 1)
    total = 0
    for s in order:
        n = rename_speakers(s, metas[s], hf_token)
        total += n
        print(f"  {s.name}: переименовано реплик {n}")
    print(f"\nГотово. Всего переименовано: {total}")


if __name__ == "__main__":
    main()
