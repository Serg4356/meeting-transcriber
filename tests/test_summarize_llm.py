"""Саммари встречи: модель получает рубрику приватности, ПД по форме снимаются до ЛЛМ."""
import summarize_llm


def test_form_pii_stripped_before_llm():
    # телефон должен уйти в [телефон] ДО того, как транскрипт попадёт модели
    seen = {}
    def spy(system, user):
        seen["user"] = user
        return "## Саммари\n- ок\n\n## Action items\n- нет\n"
    text = "**[00:05] Иванов:** звони +7 916 123-45-67 по задаче."
    summarize_llm.summarize(text, spy)
    assert "[телефон]" in seen["user"] and "916" not in seen["user"]


def test_rubric_passed_as_system():
    seen = {}
    def spy(system, user):
        seen["system"] = system
        return "## Саммари\n- ок\n\n## Action items\n- нет\n"
    summarize_llm.summarize("**[00:01] Иванов:** привет.", spy)
    # система = рубрика с правилами приватности
    assert "action items" in seen["system"].lower()
    assert "приват" in seen["system"].lower() or "личн" in seen["system"].lower()


def test_returns_model_markdown_trimmed():
    out = summarize_llm.summarize(
        "**[00:01] Иванов:** привет.",
        lambda s, u: "  ## Саммари\n- поздоровались\n\n## Action items\n- нет  ",
    )
    assert out.startswith("## Саммари")
    assert out.endswith("\n")             # ровно один финальный перевод строки
