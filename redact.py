"""Детерминированная очистка транскрипта от ПД ПО ФОРМЕ — без LLM.

Снимает то, что опознаётся по форме с почти нулём ложных срабатываний: почты,
телефоны, номера карт (с проверкой Луна). Это дешёвый первый слой перед заливкой
в общую БД. Смысловое (токсичность на человека, приватное без формальных маркеров,
суммы-в-контексте) этот слой НЕ трогает — то отдельный LLM-слой (см.
docs/VOICEPRINT_SHARING.md по инфраструктуре и решение про сторону обработки).

Заменяет найденное на метку `[тип]`, структуру и таймкоды не ломает. Возвращает
очищенный текст и список того, что убрано (для прозрачности/лога) — БЕЗ значений.

    python redact.py <transcript.md>        # печатает очищенное в stdout
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Почта: обычная форма, край — не буква/цифра/точка, чтобы не рвать домены.
EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}\b")

# Телефон: +/цифры/пробелы/скобки/дефисы, 10–15 цифр всего. Край — не цифра и не
# двоеточие, чтобы НЕ ловить таймкоды [00:14:32] и последовательности вроде годов.
PHONE_RE = re.compile(r"(?<![\d:+])\+?\d[\d\s()‐-―-]{8,}\d(?![\d:])")

# Карта: 13–19 цифр, возможно группами по пробелам/дефисам. Сепаратор — только
# МЕЖДУ цифр (иначе съедается пробел после числа). Луна отсекает случайные длинные
# числа (артикулы, id), которые в рабочем разговоре не редкость.
CARD_RE = re.compile(r"(?<![\d.])\d(?:[ ‐-―-]?\d){12,18}(?![\d.])")


def _luhn_ok(digits: str) -> bool:
    total, alt = 0, False
    for ch in reversed(digits):
        d = ord(ch) - 48
        if alt:
            d *= 2
            if d > 9:
                d -= 9
        total += d
        alt = not alt
    return total % 10 == 0


def _count_digits(s: str) -> int:
    return sum(c.isdigit() for c in s)


def redact(text: str) -> tuple[str, list[str]]:
    """Возвращает (очищенный текст, список категорий убранного). Значения не отдаёт."""
    removed: list[str] = []

    def sub(pattern: re.Pattern, label: str, guard=None):
        def repl(m: re.Match) -> str:
            if guard and not guard(m.group(0)):
                return m.group(0)
            removed.append(label)
            return f"[{label}]"
        return pattern.sub(repl, text)

    # Порядок важен: карта раньше телефона (длинная числовая форма поглотила бы
    # телефонную), почта раньше всего (в ней тоже цифры).
    text = sub(EMAIL_RE, "email")
    text = sub(CARD_RE, "карта",
               guard=lambda s: 13 <= _count_digits(s) <= 19 and _luhn_ok(
                   "".join(c for c in s if c.isdigit())))
    text = sub(PHONE_RE, "телефон",
               guard=lambda s: 10 <= _count_digits(s) <= 15)
    return text, removed


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("использование: python redact.py <transcript.md>")
    src = Path(sys.argv[1])
    clean, removed = redact(src.read_text(encoding="utf-8"))
    counts: dict[str, int] = {}
    for r in removed:
        counts[r] = counts.get(r, 0) + 1
    if counts:
        summary = ", ".join(f"{k}: {v}" for k, v in sorted(counts.items()))
        print(f"# убрано по форме — {summary}\n", file=sys.stderr)
    sys.stdout.write(clean)


if __name__ == "__main__":
    main()
