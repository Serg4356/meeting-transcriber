"""Смысловая очистка транскрипта через ЛЛМ — модель-агностик.

Второй слой после redact.py (тот снимает ПД по форме). Здесь — то, что видит
только смысл: токсичность на человека, приватное без формальных маркеров.

Модель-агностик намеренно: вызов ЛЛМ инжектируется как callable (system, user)
-> raw_text. Любой провайдер (Anthropic, корп-ключ, локальная модель) подходит —
меняется только адаптер, рубрика и логика общие. Так «любая ЛЛМ подхватит».

Архитектура — «список правок», не переписывание: ЛЛМ возвращает JSON со спанами
на вырез, применяем детерминированно. Дешевле по токенам и надёжнее — модель не
может случайно уронить или переписать окружающий текст.

Гейт уверенности: правки confidence=high применяются автоматом; low (и те, чей
`quote` не нашёлся в тексте) — НЕ применяются, а возвращаются в `held` на решение
автора встречи. Двусмысленное не режем и не пропускаем вслепую.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import redact

RUBRIC_PATH = Path(__file__).parent / "cleaning_rubric.md"

# (system, user) -> сырой ответ модели (ожидается JSON, возможно в ```-заборе).
LLMCall = Callable[[str, str], str]


@dataclass
class Redaction:
    quote: str
    category: str
    confidence: str
    replacement: str = ""
    applied: bool = False
    reason: str = ""  # почему в held (low_confidence / quote_not_found)


@dataclass
class CleanResult:
    text: str                        # очищенный транскрипт
    applied: list[Redaction] = field(default_factory=list)   # вырезано автоматом
    held: list[Redaction] = field(default_factory=list)      # решает автор
    form_removed: list[str] = field(default_factory=list)    # категории из redact.py

    def summary(self) -> str:
        """Строка для лога — БЕЗ значений (сам вырезанный текст не печатаем)."""
        def by_cat(items: list[Redaction]) -> str:
            c: dict[str, int] = {}
            for r in items:
                c[r.category] = c.get(r.category, 0) + 1
            return ", ".join(f"{k}: {v}" for k, v in sorted(c.items())) or "—"
        form = ", ".join(sorted(set(self.form_removed))) or "—"
        return (f"по форме [{form}] | вырезано авто [{by_cat(self.applied)}] | "
                f"на проверку автору [{by_cat(self.held)}]")


def build_messages(transcript: str) -> tuple[str, str]:
    system = RUBRIC_PATH.read_text(encoding="utf-8")
    user = ("Транскрипт для очистки:\n\n" + transcript
            + "\n\nВерни JSON по схеме из инструкции.")
    return system, user


def parse_redactions(raw: str) -> list[dict]:
    """Достаёт список правок из ответа модели, терпимо к ```-забору и тексту вокруг."""
    m = re.search(r"\{.*\}", raw, re.S)  # первый JSON-объект
    if not m:
        return []
    try:
        data = json.loads(m.group(0))
    except ValueError:
        return []
    items = data.get("redactions") if isinstance(data, dict) else None
    return items if isinstance(items, list) else []


def apply_redactions(text: str, items: list[dict], cut_low: bool = False
                     ) -> tuple[str, list[Redaction], list[Redaction]]:
    """Применяет правки. cut_low=False — двусмысленные (confidence!=high) держим
    в `held` на решение автора. cut_low=True — режем и их (для готового-к-шерингу
    файла: пере-чистить безопаснее, чем оставить сомнительное; сырой транскрипт
    рядом сохраняет полную точность)."""
    applied: list[Redaction] = []
    held: list[Redaction] = []
    for it in items:
        if not isinstance(it, dict):
            continue
        quote = (it.get("quote") or "").strip()
        category = it.get("category") or "?"
        confidence = (it.get("confidence") or "low").strip().lower()
        replacement = it.get("replacement") or f"[убрано: {category}]"
        r = Redaction(quote, category, confidence, replacement)
        if not quote:
            continue
        if confidence != "high" and not cut_low:
            r.reason = "low_confidence"
            held.append(r)
            continue
        if quote not in text:
            # модель перефразировала спан — применить нельзя, отдаём человеку
            r.reason = "quote_not_found"
            held.append(r)
            continue
        text = text.replace(quote, replacement)
        r.applied = True
        applied.append(r)
    return text, applied, held


def clean(transcript: str, call_llm: LLMCall, cut_low: bool = False) -> CleanResult:
    """Полный пайплайн: ПД по форме → смысловой слой ЛЛМ → применение + гейт."""
    form_text, form_removed = redact.redact(transcript)
    system, user = build_messages(form_text)
    raw = call_llm(system, user)
    items = parse_redactions(raw)
    clean_text, applied, held = apply_redactions(form_text, items, cut_low=cut_low)
    return CleanResult(clean_text, applied, held, form_removed)


def from_env(default_model: str = "claude-sonnet-5") -> LLMCall | None:
    """LLM-вызов из окружения, или None если не настроено (тогда очистку пропускаем).

    Нужны: пакет `anthropic` + `ANTHROPIC_API_KEY`. Модель — `CLEAN_MODEL`
    (по умолчанию Sonnet 5). В проде здесь подменяется корп-клиент — контракт
    (system, user) -> text тот же."""
    import os
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return None
    try:
        import anthropic  # noqa: F401
    except ImportError:
        return None
    return anthropic_call(os.environ.get("CLEAN_MODEL", default_model))


# --- Пример адаптера под Anthropic (не импортируется, если ключа нет) ----------
# В проде клиент меняется на корп-ключ; рубрика и пайплайн те же.
def anthropic_call(model: str = "claude-sonnet-5") -> LLMCall:
    import anthropic
    client = anthropic.Anthropic()

    def call(system: str, user: str) -> str:
        resp = client.messages.create(
            model=model, max_tokens=4096, system=system,
            messages=[{"role": "user", "content": user}],
        )
        return "".join(b.text for b in resp.content if b.type == "text")
    return call


if __name__ == "__main__":
    import sys
    src = Path(sys.argv[1]).read_text(encoding="utf-8")
    res = clean(src, anthropic_call())
    sys.stderr.write(res.summary() + "\n")
    if res.held:
        sys.stderr.write(f"на проверку автору: {len(res.held)} фрагментов\n")
    sys.stdout.write(res.text)
