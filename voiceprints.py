"""Библиотека голосовых отпечатков — чтобы «Собеседник 7» стал именем.

Идея в том, что размечать вручную ничего не надо: встречи один-на-один дают
разметку бесплатно. Календарь знает, что участников двое; если диаризация
нашла на записи ровно один чужой голос — он принадлежит тому единственному
человеку, который есть в приглашении кроме меня. Дальше этот отпечаток
узнаётся на больших встречах.

Хранилище намеренно лежит на виду (`~/Documents/Meeting Transcriber/`), а не в
недрах Library: это биометрические данные коллег, и человек должен видеть их и
уметь удалить одним движением.

Осторожность важнее охвата: неверно записанный отпечаток будет молча и уверенно
подписывать чужой репликой конкретного человека во всех будущих встречах.
Поэтому в библиотеку попадает только то, в чём мы уверены (см. can_enroll).
"""
from __future__ import annotations

import json
from pathlib import Path

# Порог косинусной близости. Подобран консервативно: лучше оставить
# «Собеседник N», чем уверенно подписать чужим именем.
MATCH_THRESHOLD = 0.75
# Сколько человек должен говорить, чтобы отпечаток считался представительным.
MIN_ENROLL_SECONDS = 60.0


def library_path() -> Path:
    return (Path.home() / "Documents" / "Meeting Transcriber" / "voiceprints.json")


def load(path: Path | None = None) -> dict:
    p = path or library_path()
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return {}


def save(lib: dict, path: Path | None = None) -> None:
    p = path or library_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(lib, ensure_ascii=False, indent=2), encoding="utf-8")


def _unit(vec) -> list[float]:
    """Нормируем: pyannote отдаёт ненормированные векторы (нормы ~1.2-1.3),
    а косинус требует единичной длины."""
    total = sum(x * x for x in vec) ** 0.5
    return [x / total for x in vec] if total else list(vec)


def cosine(a, b) -> float:
    ua, ub = _unit(a), _unit(b)
    return sum(x * y for x, y in zip(ua, ub))


def can_enroll(others: list[str], speaker_count: int, speech_seconds: float) -> bool:
    """Пускаем в библиотеку только безошибочный случай: встреча на двоих,
    на записи ровно один чужой голос, и он говорил достаточно долго.

    Если в «1:1» диаризация нашла двоих — значит подключился кто-то ещё или
    рядом сидел коллега. Тогда молча пропускаем: неверный отпечаток хуже,
    чем его отсутствие.
    """
    return (len(others) == 1
            and speaker_count == 1
            and speech_seconds >= MIN_ENROLL_SECONDS)


def enroll(lib: dict, name: str, vec) -> dict:
    """Добавляет наблюдение в библиотеку, усредняя с прежними (бегущее среднее)."""
    v = _unit(vec)
    cur = lib.get(name)
    if cur:
        n = cur.get("n", 1)
        merged = [(o * n + x) / (n + 1) for o, x in zip(cur["vec"], v)]
        lib[name] = {"vec": _unit(merged), "n": n + 1}
    else:
        lib[name] = {"vec": v, "n": 1}
    return lib


def match(lib: dict, vec, threshold: float = MATCH_THRESHOLD) -> tuple[str | None, float]:
    """Ищет ближайший отпечаток. Возвращает (имя или None, близость)."""
    best_name, best_score = None, 0.0
    for name, rec in lib.items():
        score = cosine(vec, rec["vec"])
        if score > best_score:
            best_name, best_score = name, score
    return (best_name, best_score) if best_score >= threshold else (None, best_score)
