"""Библиотека голосовых отпечатков.

Пороги не выдуманы, а измерены на реальных записях (см. README):
тот же человек в разных кусках встречи — 0.928, разные люди — максимум 0.470.
Порог 0.75 стоит между ними с запасом в обе стороны.
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import voiceprints as vp  # noqa: E402


def _voice(seed: int, base=None, noise=0.15):
    r = random.Random(seed)
    if base is None:
        return [r.gauss(0, 1) for _ in range(256)]
    return [x + r.gauss(0, noise) for x in base]


def test_same_voice_matches():
    base = _voice(1)
    lib = vp.enroll({}, "Иван", _voice(2, base))
    who, score = vp.match(lib, _voice(3, base))
    assert who == "Иван"
    assert score >= vp.MATCH_THRESHOLD


def test_different_voice_is_rejected():
    lib = vp.enroll({}, "Иван", _voice(1))
    who, score = vp.match(lib, _voice(99))
    assert who is None, "чужой голос не должен получать чужое имя"
    assert score < vp.MATCH_THRESHOLD


def test_enroll_averages_and_counts():
    base = _voice(1)
    lib = vp.enroll({}, "Аня", _voice(2, base))
    lib = vp.enroll(lib, "Аня", _voice(3, base))
    assert lib["Аня"]["n"] == 2
    assert abs(sum(x * x for x in lib["Аня"]["vec"]) - 1.0) < 1e-6, "вектор должен быть единичным"


def test_gate_allows_only_clean_one_on_one():
    assert vp.can_enroll(["Иван"], 1, 90) is True
    # на «встрече на двоих» два голоса — подключился третий, запоминать нельзя
    assert vp.can_enroll(["Иван"], 2, 90) is False
    # слишком мало речи — отпечаток непредставительный
    assert vp.can_enroll(["Иван"], 1, 10) is False
    # групповая встреча — кто из них говорил, неизвестно
    assert vp.can_enroll(["А", "Б", "В"], 1, 90) is False
    # встреча без списка участников
    assert vp.can_enroll([], 1, 90) is False


def test_save_load_roundtrip(tmp_path):
    p = tmp_path / "vp.json"
    lib = vp.enroll({}, "Гоша", _voice(5))
    vp.save(lib, p)
    assert vp.load(p)["Гоша"]["n"] == 1


def test_broken_library_does_not_crash(tmp_path):
    p = tmp_path / "vp.json"
    p.write_text("{сломано", encoding="utf-8")
    assert vp.load(p) == {}
