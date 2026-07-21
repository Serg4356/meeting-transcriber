"""Тесты извлечения ссылки на видеозвонок из события календаря."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from calendar_watch import extract_meeting_url  # noqa: E402


def test_hangout_link_preferred():
    ev = {"hangoutLink": "https://meet.google.com/abc-defg-hij"}
    assert extract_meeting_url(ev) == "https://meet.google.com/abc-defg-hij"


def test_conference_data_video_entry():
    ev = {"conferenceData": {"entryPoints": [
        {"entryPointType": "phone", "uri": "tel:+123"},
        {"entryPointType": "video", "uri": "https://zoom.us/j/123456"},
    ]}}
    assert extract_meeting_url(ev) == "https://zoom.us/j/123456"


def test_zoom_url_in_location():
    ev = {"location": "Zoom: https://us02web.zoom.us/j/999?pwd=x встреча"}
    assert extract_meeting_url(ev) == "https://us02web.zoom.us/j/999?pwd=x"


def test_teams_url_in_description():
    ev = {"description": "join https://teams.microsoft.com/l/meetup-join/abc here"}
    assert extract_meeting_url(ev) == "https://teams.microsoft.com/l/meetup-join/abc"


def test_no_link_returns_none():
    assert extract_meeting_url({"description": "встреча в переговорке 3"}) is None


def test_empty_event_returns_none():
    assert extract_meeting_url({}) is None


# --- окно события: идёт / закончилась / впереди -------------------------------
# Раньше события с отрицательным временем до старта отбрасывались, и встреча,
# которая уже идёт, была для приложения невидимой. Из-за этого транскрипт
# оставался без названия: запись включают, уже подключившись к звонку.

from datetime import datetime, timedelta, timezone  # noqa: E402

from calendar_watch import event_window  # noqa: E402

NOW = datetime(2026, 7, 21, 12, 0, tzinfo=timezone.utc)


def _ev(start_min: int, end_min: int) -> dict:
    return {"start": {"dateTime": (NOW + timedelta(minutes=start_min)).isoformat()},
            "end": {"dateTime": (NOW + timedelta(minutes=end_min)).isoformat()}}


def test_running_meeting_is_kept():
    minutes_until, running = event_window(_ev(-10, 50), NOW)
    assert running is True
    assert minutes_until == -10.0


def test_finished_meeting_is_dropped():
    assert event_window(_ev(-65, -5), NOW) is None


def test_upcoming_meeting_is_kept():
    minutes_until, running = event_window(_ev(3, 63), NOW)
    assert running is False
    assert minutes_until == 3.0


def test_all_day_event_is_dropped():
    assert event_window({"start": {"date": "2026-07-21"}}, NOW) is None
