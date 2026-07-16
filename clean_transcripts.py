"""Пост-чистка готовых transcript.md от типовых галлюцинаций whisper.

Удаляет реплики, чей текст целиком — известная фраза-артефакт
(«Продолжение следует…» и т.п.). Точное совпадение, не fuzzy — безопасно.

    python clean_transcripts.py <file.md> [<file2.md> ...]
    python clean_transcripts.py            # почистить все в recordings/ + Documents
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

HALLUCINATION_PHRASES = {
    "продолжение следует",
    "спасибо за просмотр",
    "спасибо за внимание",
    "подписывайтесь на канал",
    "спасибо что смотрите",
    "до новых встреч",
    "субтитры сделал dimatorzok",
    "субтитры создавал dimatorzok",
    "редактор субтитров а семкин корректор а егорова",
}

BLOCK_RE = re.compile(r"^\*\*\[[^\]]*\][^:]*:\*\*\s*(.*)$", re.S)

# Класс субтитр-артефактов whisper (варьируются именами): «Спасибо за субтитры X»,
# «Субтитры сделал/создал/редактор …».
HALLUCINATION_RE = re.compile(
    r"^(спасибо за субтитры|субтитры .{0,50}(сделал|создал|редактор|подготовил)"
    r"|редактор субтитров)")


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", text.lower())).strip()


def _is_junk(text: str) -> bool:
    n = _norm(text)
    return n in HALLUCINATION_PHRASES or bool(HALLUCINATION_RE.match(n))


def clean_file(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    blocks = text.split("\n\n")
    kept, dropped = [], 0
    for block in blocks:
        m = BLOCK_RE.match(block.strip())
        if m and _is_junk(m.group(1)):
            dropped += 1
            continue
        kept.append(block)
    if dropped:
        path.write_text("\n\n".join(kept), encoding="utf-8")
    return dropped


def main() -> None:
    if len(sys.argv) > 1:
        files = [Path(a) for a in sys.argv[1:]]
    else:
        root = Path(__file__).parent
        files = list((root / "mac-capture/recordings").glob("*/transcript.md"))
        docs = Path.home() / "Documents" / "Транскрипты встреч"
        if docs.exists():
            files += list(docs.glob("*.md"))

    total = 0
    for f in files:
        if f.exists():
            d = clean_file(f)
            total += d
            if d:
                print(f"  {f.name}: убрано {d} галлюцинаций")
    print(f"Готово. Всего убрано: {total}")


if __name__ == "__main__":
    main()
