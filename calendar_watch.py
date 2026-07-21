"""Опрос Google Calendar: ближайшие встречи со ссылкой на видеозвонок.

Настройка (разово):
    1. В Google Cloud Console создать OAuth-клиент типа Desktop, скачать
       credentials.json в корень проекта (см. README раздел «Календарь»).
    2. python calendar_watch.py --auth   # откроет браузер, подтвердить доступ

Использование (дёргает Swift-аппка):
    python calendar_watch.py --upcoming        # JSON встреч в ближайший час
    python calendar_watch.py --upcoming --within 90

Вывод — JSON-массив: [{id, title, start, minutes_until, meeting_url}, ...]
Только события с dateTime (не all-day) и, по умолчанию, со ссылкой на звонок.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build

SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]
PROJECT = Path(__file__).parent
CREDENTIALS = PROJECT / "credentials.json"
TOKEN = PROJECT / ".gcal_token.json"

MEETING_URL_RE = re.compile(
    r"https?://[^\s<>\"]*"
    r"(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com)"
    r"[^\s<>\"]*",
    re.IGNORECASE,
)


def get_credentials(interactive: bool) -> Credentials:
    creds: Credentials | None = None
    if TOKEN.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN), SCOPES)
    if creds and creds.valid:
        return creds
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
        TOKEN.write_text(creds.to_json())
        return creds
    if not interactive:
        sys.exit("Нет валидного токена. Запусти: python calendar_watch.py --auth")
    if not CREDENTIALS.exists():
        sys.exit(f"Нет {CREDENTIALS}. Скачай OAuth-креды из Google Cloud (см. README).")
    flow = InstalledAppFlow.from_client_secrets_file(str(CREDENTIALS), SCOPES)
    creds = flow.run_local_server(port=0)
    TOKEN.write_text(creds.to_json())
    return creds


def extract_meeting_url(event: dict) -> str | None:
    if event.get("hangoutLink"):
        return event["hangoutLink"]
    for ep in event.get("conferenceData", {}).get("entryPoints", []):
        if ep.get("entryPointType") == "video" and ep.get("uri"):
            return ep["uri"]
    for field in ("location", "description"):
        m = MEETING_URL_RE.search(event.get(field, "") or "")
        if m:
            return m.group(0)
    return None


def upcoming(within_min: int, require_link: bool) -> list[dict]:
    creds = get_credentials(interactive=False)
    service = build("calendar", "v3", credentials=creds, cache_discovery=False)
    now = datetime.now(timezone.utc)
    time_max = now + timedelta(minutes=within_min)
    events = service.events().list(
        calendarId="primary",
        timeMin=now.isoformat(),
        timeMax=time_max.isoformat(),
        singleEvents=True,
        orderBy="startTime",
    ).execute().get("items", [])

    result = []
    for ev in events:
        start_raw = ev.get("start", {}).get("dateTime")
        if not start_raw:  # all-day — пропускаем
            continue
        start = datetime.fromisoformat(start_raw)
        minutes_until = (start - now).total_seconds() / 60.0
        if minutes_until < 0:
            continue
        url = extract_meeting_url(ev)
        if require_link and not url:
            continue
        # Участники: имена нужны в шапке транскрипта (кто вообще был на встрече),
        # а число подтвердивших — как ВЕРХНЯЯ граница для диаризации. Именно
        # верхняя: половина приглашённых обычно молчит, поэтому фиксировать
        # точное число нельзя — заставим алгоритм дробить одного человека на двух.
        attendees = [a for a in ev.get("attendees", []) if not a.get("resource")]
        names = [a.get("displayName") or a.get("email", "") for a in attendees]
        accepted = sum(1 for a in attendees if a.get("responseStatus") == "accepted")
        result.append({
            "id": ev.get("id"),
            "title": ev.get("summary", "(без названия)"),
            "start": start.isoformat(),
            "minutes_until": round(minutes_until, 1),
            "meeting_url": url,
            "attendees": [n for n in names if n],
            "accepted_count": accepted,
        })
    return result


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--auth", action="store_true", help="разовая авторизация в браузере")
    ap.add_argument("--upcoming", action="store_true", help="JSON ближайших встреч")
    ap.add_argument("--within", type=int, default=60, help="горизонт в минутах (default 60)")
    ap.add_argument("--all-events", action="store_true",
                    help="включая события без ссылки на звонок")
    args = ap.parse_args()

    if args.auth:
        get_credentials(interactive=True)
        print("Авторизация успешна, токен сохранён.")
        return

    events = upcoming(args.within, require_link=not args.all_events)
    print(json.dumps(events, ensure_ascii=False))


if __name__ == "__main__":
    main()
