"""Режим одной дорожки — записи с телефона.

Телефон не может писать звук чужих приложений: все спикеры оказываются в
микрофонной дорожке. Пайплайн обязан диаризовать её, а не считать речью
владельца (иначе от встречи остаётся один голос).
"""

from __future__ import annotations

import json
from pathlib import Path

import transcribe


def test_owner_from_meta_prefers_explicit_owner() -> None:
    meta = {"owner": "Иванов", "attendees": ["Петров", "Сидоров"], "others": ["Петров"]}
    assert transcribe.owner_from_meta(meta) == "Иванов"


def test_owner_from_meta_falls_back_to_calendar() -> None:
    meta = {"attendees": ["Иванов", "Петров"], "others": ["Петров"]}
    assert transcribe.owner_from_meta(meta) == "Иванов"


def test_owner_from_meta_none_for_phone_without_name() -> None:
    assert transcribe.owner_from_meta({"single_track": True, "source": "iphone"}) is None


def test_speaker_label_marks_owner_as_me() -> None:
    names = {"SPEAKER_00": "Иванов", "SPEAKER_01": "Петров"}
    assert transcribe.speaker_label("SPEAKER_00", names, "Иванов") == "Я"
    assert transcribe.speaker_label("SPEAKER_01", names, "Иванов") == "Петров"


def test_speaker_label_unknown_cluster_gets_number() -> None:
    assert transcribe.speaker_label("SPEAKER_02", {}, "Иванов") == "Собеседник 3"


def test_speaker_label_without_owner_keeps_names() -> None:
    # телефон без имени владельца: спикеров всё равно различаем
    assert transcribe.speaker_label("SPEAKER_00", {"SPEAKER_00": "Петров"}, None) == "Петров"


def test_single_track_session_is_diarized_not_owner_filtered(tmp_path: Path, monkeypatch) -> None:
    """Ключевой инвариант: реплики РАЗНЫХ спикеров сохраняются и различаются."""
    session = tmp_path / "2026-08-11 14-05-33"
    session.mkdir()
    (session / "mic.m4a").write_bytes(b"\x00")
    (session / "meeting.json").write_text(
        json.dumps({"title": "Планёрка", "single_track": True, "owner": "Иванов"}),
        encoding="utf-8")

    monkeypatch.setenv("HF_TOKEN", "x")
    monkeypatch.setattr(transcribe, "_asr_cached", lambda *a, **k: [
        (0.0, 2.0, "Привет"), (2.0, 4.0, "И тебе привет"), (4.0, 6.0, "Начнём"),
    ])
    monkeypatch.setattr(transcribe, "_diar_cached", lambda *a, **k: (
        [(0.0, 2.0, "SPEAKER_00"), (2.0, 4.0, "SPEAKER_01"), (4.0, 6.0, "SPEAKER_00")],
        {"SPEAKER_00": [1.0, 0.0], "SPEAKER_01": [0.0, 1.0]},
    ))
    monkeypatch.setattr(transcribe, "resolve_speaker_names",
                        lambda turns, vecs, meta: {"SPEAKER_00": "Иванов"})

    out = transcribe.build_transcript(session, "large-v3", "ru", do_diarize=True)
    text = out.read_text(encoding="utf-8")

    assert "Привет" in text and "И тебе привет" in text and "Начнём" in text
    assert "**[00:00] Я:**" in text                # владелец опознан по имени
    assert "Собеседник 2" in text                  # второй голос не потерян


def test_owner_filtering_still_applies_to_mac_sessions(tmp_path: Path, monkeypatch) -> None:
    """Двухдорожечные записи Мака работают по-старому: микрофон = «Я»."""
    session = tmp_path / "2026-08-11 15-00-00"
    session.mkdir()
    (session / "mic.m4a").write_bytes(b"\x00")
    (session / "meeting.json").write_text(json.dumps({"title": "Мак"}), encoding="utf-8")

    monkeypatch.delenv("HF_TOKEN", raising=False)
    monkeypatch.setattr(transcribe, "_asr_cached", lambda *a, **k: [(0.0, 1.0, "Моя реплика")])

    out = transcribe.build_transcript(session, "large-v3", "ru", do_diarize=True)
    assert "**[00:00] Я:** Моя реплика" in out.read_text(encoding="utf-8")
