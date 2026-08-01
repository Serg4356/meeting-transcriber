"""Саммари встречи + action items через ЛЛМ — модель-агностик.

Отличие от clean_llm: это ГЕНЕРАЦИЯ (модель возвращает готовый Markdown саммари),
а не список правок. Но правила приватности те же — они вшиты в рубрику
(summary_rubric.md): саммари делается из СЫРОГО транскрипта (полнота фактов), но
в текст не попадает токсичность на людей и приватное. Плюс ПД по форме снимаем
redact.py до ЛЛМ, как в очистке.

Плумбинг вызова ЛЛМ (from_env / anthropic_call) переиспользуется из clean_llm —
контракт (system, user) -> text общий.
"""
from __future__ import annotations

from pathlib import Path

import redact
from clean_llm import LLMCall, anthropic_call, from_env  # noqa: F401  (реэкспорт)

RUBRIC_PATH = Path(__file__).parent / "summary_rubric.md"


def build_messages(transcript: str) -> tuple[str, str]:
    system = RUBRIC_PATH.read_text(encoding="utf-8")
    user = ("Транскрипт встречи:\n\n" + transcript
            + "\n\nСделай саммари и action items по инструкции.")
    return system, user


def summarize(transcript: str, call_llm: LLMCall) -> str:
    """Сырой транскрипт → ПД по форме снимаем → ЛЛМ с рубрикой → Markdown саммари."""
    form_text, _ = redact.redact(transcript)
    system, user = build_messages(form_text)
    return call_llm(system, user).strip() + "\n"


if __name__ == "__main__":
    import sys
    src = Path(sys.argv[1]).read_text(encoding="utf-8")
    llm = from_env()
    if llm is None:
        sys.exit("Саммари не настроено: нет ANTHROPIC_API_KEY / пакета anthropic")
    sys.stdout.write(summarize(src, llm))
