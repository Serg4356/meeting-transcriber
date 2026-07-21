"""Данные встречи из календаря: участники в шапке + верхняя граница спикеров."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from transcribe import load_meeting_meta  # noqa: E402


def test_missing_file_gives_empty(tmp_path):
    assert load_meeting_meta(tmp_path) == {}


def test_broken_json_does_not_crash(tmp_path):
    (tmp_path / "meeting.json").write_text("{не json", encoding="utf-8")
    assert load_meeting_meta(tmp_path) == {}


def test_reads_attendees_and_cap(tmp_path):
    (tmp_path / "meeting.json").write_text(json.dumps({
        "title": "Weekly", "attendees": ["Аня", "Боря"], "accepted_count": 15,
    }), encoding="utf-8")
    meta = load_meeting_meta(tmp_path)
    assert meta["attendees"] == ["Аня", "Боря"]
    # именно верхняя граница: подтвердивших больше, чем реально говорящих
    assert meta["accepted_count"] == 15
