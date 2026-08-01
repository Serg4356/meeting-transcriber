"""Детерминированная очистка ПД по форме. Главное — НЕ трогать безобидное."""
import redact


def test_email_redacted():
    out, rm = redact.redact("пиши на ivan.petrov@example.com завтра")
    assert "[email]" in out and "example.com" not in out
    assert rm == ["email"]


def test_phone_redacted():
    out, rm = redact.redact("мой номер +7 916 123-45-67 звони")
    assert "[телефон]" in out and "916" not in out
    assert rm == ["телефон"]


def test_card_luhn_redacted():
    # валидный по Луну тестовый номер
    out, rm = redact.redact("карта 4111 1111 1111 1111 списать")
    assert "[карта]" in out
    assert rm == ["карта"]


def test_timecode_not_touched():
    line = "**[00:14:32] Иван:** давай в три"
    out, rm = redact.redact(line)
    assert out == line and rm == []


def test_years_and_counts_not_touched():
    line = "в 2026 году сделали 15 релизов и 300 тестов"
    out, rm = redact.redact(line)
    assert out == line and rm == []


def test_random_long_number_not_card():
    # 16 цифр, НЕ проходит Луна (4111…1112 — валидная это …1111) — артикул, не карта
    line = "артикул 4111111111111112 на складе"
    out, rm = redact.redact(line)
    assert "[карта]" not in out and rm == []
    assert out == line  # пробелы вокруг числа не съедены


def test_short_number_not_phone():
    line = "нас было 12345 человек примерно"
    out, rm = redact.redact(line)
    assert "[телефон]" not in out and rm == []


def test_clean_text_unchanged():
    line = "**[01:02:03] Я:** это решение полное говно, переделываем архитектуру"
    out, rm = redact.redact(line)
    # мат на артефакт остаётся — это НЕ работа детерминированного слоя
    assert out == line and rm == []


def test_multiple_and_order():
    text = "звони +79161234567 или user@example.com, карта 4111111111111111"
    out, rm = redact.redact(text)
    assert "[телефон]" in out and "[email]" in out and "[карта]" in out
    assert set(rm) == {"телефон", "email", "карта"}


def test_email_with_digits_not_split_into_phone():
    out, rm = redact.redact("user2026@example.com")
    assert out == "[email]" and rm == ["email"]
