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
