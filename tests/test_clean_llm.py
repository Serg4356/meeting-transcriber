"""Смысловая очистка транскрипта: применение правок, гейт уверенности, форма."""
import json

import clean_llm


def fake_llm(redactions):
    """Возвращает callable, отдающий заданный список правок как ответ модели."""
    payload = json.dumps({"redactions": redactions}, ensure_ascii=False)
    return lambda system, user: payload


def test_high_confidence_person_attack_applied():
    text = "**[00:12] Иванов:** Петров опять накодил херню. Давайте дальше."
    res = clean_llm.clean(text, fake_llm([
        {"quote": "Петров опять накодил херню", "category": "person_attack",
         "confidence": "high", "replacement": "к коду Петрова есть вопросы"},
    ]))
    assert "накодил херню" not in res.text
    assert "к коду Петрова есть вопросы" in res.text
    assert len(res.applied) == 1 and not res.held


def test_low_confidence_held_not_applied():
    text = "**[00:40] Иванов:** Ну Петров как всегда, конечно."
    res = clean_llm.clean(text, fake_llm([
        {"quote": "Ну Петров как всегда, конечно", "category": "person_attack",
         "confidence": "low", "replacement": ""},
    ]))
    assert "Ну Петров как всегда" in res.text          # НЕ вырезано
    assert len(res.held) == 1 and res.held[0].reason == "low_confidence"
    assert not res.applied


def test_quote_not_found_held():
    text = "**[00:01] Иванов:** всё нормально по проекту."
    res = clean_llm.clean(text, fake_llm([
        {"quote": "этой фразы в тексте нет", "category": "private",
         "confidence": "high", "replacement": ""},
    ]))
    assert res.text.endswith("по проекту.")            # текст не тронут
    assert len(res.held) == 1 and res.held[0].reason == "quote_not_found"


def test_idea_profanity_kept():
    # модель НЕ вернула правку на мат про артефакт → он остаётся
    text = "**[00:20] Петров:** Это решение — полное говно, переделываем."
    res = clean_llm.clean(text, fake_llm([]))
    assert "полное говно" in res.text
    assert not res.applied and not res.held


def test_form_pii_removed_before_llm():
    # redact.py снимает телефон ДО смыслового слоя; ЛЛМ ничего не возвращает
    text = "**[00:05] Иванов:** звони на +7 916 123-45-67 по вопросу."
    res = clean_llm.clean(text, fake_llm([]))
    assert "[телефон]" in res.text and "916" not in res.text
    assert "телефон" in res.form_removed


def test_parse_tolerates_code_fence():
    raw = ('вот правки:\n```json\n'
           '{"redactions": [{"quote": "x", "category": "private",'
           ' "confidence": "high"}]}\n```')
    items = clean_llm.parse_redactions(raw)
    assert len(items) == 1 and items[0]["category"] == "private"


def test_parse_garbage_returns_empty():
    assert clean_llm.parse_redactions("модель отказалась отвечать") == []


def test_default_replacement_marker_when_empty():
    text = "**[00:03] Сидоров:** у Петрова проблемы с деньгами, говорят."
    res = clean_llm.clean(text, fake_llm([
        {"quote": "у Петрова проблемы с деньгами, говорят", "category": "private",
         "confidence": "high"},   # replacement отсутствует
    ]))
    assert "[убрано: private]" in res.text
    assert "проблемы с деньгами" not in res.text


def test_cut_low_applies_ambiguous():
    # cut_low=True: спорное режем тоже (готовый-к-шерингу файл)
    text = "**[00:40] Иванов:** Ну Петров как всегда, конечно."
    res = clean_llm.clean(text, fake_llm([
        {"quote": "Ну Петров как всегда, конечно", "category": "person_attack",
         "confidence": "low", "replacement": ""},
    ]), cut_low=True)
    assert "Ну Петров как всегда" not in res.text
    assert len(res.applied) == 1 and not res.held


def test_cut_low_still_holds_quote_not_found():
    # даже при cut_low ненайденный спан применить нельзя → в held
    text = "**[00:01] Иванов:** всё по проекту нормально."
    res = clean_llm.clean(text, fake_llm([
        {"quote": "нет такой фразы", "category": "private", "confidence": "low"},
    ]), cut_low=True)
    assert res.held and res.held[0].reason == "quote_not_found"


def test_from_env_none_without_key(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert clean_llm.from_env() is None


def test_summary_masks_values():
    text = "**[00:12] Иванов:** Петров накодил херню."
    res = clean_llm.clean(text, fake_llm([
        {"quote": "Петров накодил херню", "category": "person_attack",
         "confidence": "high", "replacement": "к коду есть вопросы"},
    ]))
    s = res.summary()
    assert "person_attack" in s and "херню" not in s   # категории есть, значений нет
