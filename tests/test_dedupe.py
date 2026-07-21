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


def test_echo_with_different_words_removed_when_session_is_echo_dominated():
    """Без наушников whisper слышит эхо ИНАЧЕ, чем оригинал (звук из динамиков
    хуже), поэтому по словам оно не ловится. Спасает одновременность: живая речь
    идёт в паузах чужой, эхо — поверх неё. Реальный случай: 413 чужих реплик,
    помеченных как «Я», при выключенном микрофоне."""
    segs = []
    for i in range(8):  # явные дубли → сессия опознаётся как «без наушников»
        t = i * 10.0
        segs.append(Segment(t, t + 2, f"обсуждаем пункт номер {i} подробно", "Собеседник 1"))
        segs.append(Segment(t + 0.5, t + 2.5, f"обсуждаем пункт номер {i} подробно", "Я"))
    # искажённое эхо: слова другие, но звучит ОДНОВРЕМЕННО с чужой речью
    segs.append(Segment(100.0, 102.0, "своевременная приёмка товара", "Собеседник 1"))
    segs.append(Segment(100.4, 102.4, "который работает на козлов", "Я"))

    kept = dedupe_bleed(segs)
    assert not [s for s in kept if s.speaker == "Я"]


def test_interjection_kept_when_session_is_clean():
    """В наушниках эха мало — агрессивное правило НЕ включается, и живая
    перебивка поверх чужой речи остаётся в транскрипте."""
    segs = [Segment(i * 10.0, i * 10.0 + 2.0, f"чужая реплика номер {i}", "Собеседник 1")
            for i in range(8)]
    segs.append(Segment(20.5, 21.0, "да согласен полностью", "Я"))

    kept = dedupe_bleed(segs)
    assert [s for s in kept if s.speaker == "Я"], "чистую сессию трогать нельзя"
