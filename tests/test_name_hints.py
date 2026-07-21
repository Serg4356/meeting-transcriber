"""Тесты вероятностной привязки имён к «Собеседникам» по обращениям."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from name_hints import apply, decide, score  # noqa: E402


def test_answer_to_vocative_wins():
    """Позвали по имени — ответил следующий. Это главный признак."""
    segs = [("Я", "Фёдор, ты с нами?"),
            ("Собеседник 1", "да, я тут"),
            ("Я", "Фёдор, покажи дашборд"),
            ("Собеседник 1", "сейчас покажу")]
    got = decide(score(segs, ["Фёдор"]))
    assert got["Собеседник 1"][0] == "Фёдор"


def test_no_guess_when_candidates_are_tied():
    """Ничья между именами — привязки быть не должно: «Собеседник N»
    честнее, чем неверное имя, которое потом молча разойдётся по базе."""
    segs = [("Я", "Фёдор, глянь"), ("Собеседник 1", "ага"),
            ("Я", "Пётр, глянь"), ("Собеседник 1", "ага")]
    assert decide(score(segs, ["Фёдор", "Пётр"])) == {}


def test_speaking_own_name_counts_against():
    """Своё имя вслух не называют: если кластер сам произносит имя,
    это довод против того, что он и есть этот человек."""
    segs = [("Собеседник 1", "у Фёдора там процесс"),
            ("Собеседник 1", "Фёдор это делает сам"),
            ("Собеседник 1", "спросите Фёдора")]
    sc = score(segs, ["Фёдор"])
    assert sc["Собеседник 1"]["Фёдор"] < 0


def test_one_name_never_goes_to_two_clusters():
    segs = [("Я", "Фёдор?"), ("Собеседник 1", "да"),
            ("Я", "Фёдор?"), ("Собеседник 1", "да"),
            ("Я", "Фёдор?"), ("Собеседник 2", "ага")]
    got = decide(score(segs, ["Фёдор"]))
    assert list(got.values()).count(("Фёдор", got.get("Собеседник 1", ("", 0))[1])) <= 1
    assert sum(1 for n, _ in got.values() if n == "Фёдор") == 1


def test_apply_renames_only_target_labels():
    text = ("**[00:01] Собеседник 1:** привет\n\n"
            "**[00:05] Собеседник 3:** ещё\n")
    out, n = apply(text, {"Собеседник 1": "A. Ivanov"})
    assert n == 1
    assert "A. Ivanov:**" in out
    assert "Собеседник 3:**" in out       # чужие метки не тронуты
