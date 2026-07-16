"""Тесты дедупа протечки системного звука в микрофон."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from transcribe import Segment, _norm, dedupe_bleed  # noqa: E402


def test_norm_strips_punct_and_case():
    assert _norm("Привет, МИР!!!  ") == "привет мир"


def test_drops_mic_duplicate_of_system():
    segs = [
        Segment(0.0, 2.0, "Давайте разберём это видео", "Собеседник 1"),
        Segment(0.1, 2.1, "давайте разберем это видео", "Я"),  # эхо из динамиков
    ]
    kept = dedupe_bleed(segs)
    assert len(kept) == 1
    assert kept[0].speaker == "Собеседник 1"


def test_keeps_genuine_mic_line():
    segs = [
        Segment(0.0, 2.0, "Комбат Дилси Откровения", "Собеседник 1"),
        Segment(5.0, 6.0, "Как слышно?", "Я"),  # настоящая реплика — не дубль
    ]
    kept = dedupe_bleed(segs)
    assert len(kept) == 2


def test_no_drop_when_time_far_apart():
    segs = [
        Segment(0.0, 2.0, "одинаковый текст полностью", "Собеседник 1"),
        Segment(30.0, 32.0, "одинаковый текст полностью", "Я"),  # далеко по времени
    ]
    kept = dedupe_bleed(segs, time_tol=4.0)
    assert len(kept) == 2


def test_no_system_track_keeps_all():
    segs = [
        Segment(0.0, 2.0, "только микрофон", "Я"),
        Segment(3.0, 4.0, "ещё микрофон", "Я"),
    ]
    assert len(dedupe_bleed(segs)) == 2
