"""Гейт: в репозиторий не должны попадать реальные почты и внутренние адреса.

Появился после реального инцидента: при документировании функции нормализации
имён в докстринг попала настоящая рабочая почта коллеги, а в тесты — имена
участников встречи. Всё это уехало в публичный репозиторий, и историю пришлось
переписывать с удалением репозитория.

Проверка намеренно generic (домены и адреса, а не список фамилий) — иначе сам
тест стал бы местом утечки. Имена людей автоматически не ловятся: за них
отвечает правило «в примерах только вымышленные Иванов/Петров».
"""
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).parent.parent

# Домены, допустимые в примерах и документации.
ALLOWED_MAIL = re.compile(
    r"@(example\.(com|org|net)|localhost|users\.noreply\.github\.com|"
    r"meeting-transcriber\.local|huggingface\.co)\b")
ANY_MAIL = re.compile(r"\b[\w.+-]+@[\w-]+\.[a-zA-Z]{2,}\b")
# Внутренние адреса компаний — в открытом коде им не место.
INTERNAL_HOST = re.compile(r"\b[\w.-]*\.(internal|local|corp|intranet)\b[\w./-]*")

SUFFIXES = {".py", ".swift", ".md", ".sh", ".command", ".json", ".txt", ".yml", ".yaml"}
SKIP_DIRS = {".git", ".venv", "node_modules", "mac-capture", "__pycache__",
             ".pytest_cache", "docs"}


def _tracked_files() -> list[Path]:
    """Только то, что реально лежит в гите — локальные .env и записи не считаем."""
    try:
        out = subprocess.run(["git", "-C", str(ROOT), "ls-files"],
                             capture_output=True, text=True, timeout=30).stdout
    except (subprocess.SubprocessError, OSError):
        return []
    files = []
    for line in out.splitlines():
        p = ROOT / line
        if p.suffix.lower() in SUFFIXES and not (set(p.parts) & SKIP_DIRS) and p.exists():
            files.append(p)
    return files


def test_no_real_email_addresses():
    bad = []
    for f in _tracked_files():
        if f.name == "test_no_personal_data.py":
            continue
        text = f.read_text(encoding="utf-8", errors="ignore")
        for m in ANY_MAIL.finditer(text):
            if not ALLOWED_MAIL.search(m.group(0)):
                bad.append(f"{f.relative_to(ROOT)}: {m.group(0)}")
    assert not bad, (
        "Настоящие почты в репозитории — в примерах используй @example.com:\n  "
        + "\n  ".join(bad))


def test_no_internal_hostnames():
    bad = []
    for f in _tracked_files():
        if f.name == "test_no_personal_data.py":
            continue
        text = f.read_text(encoding="utf-8", errors="ignore")
        for m in INTERNAL_HOST.finditer(text):
            # meeting-transcriber.local — наш собственный плейсхолдер, он разрешён
            if "meeting-transcriber.local" in m.group(0):
                continue
            bad.append(f"{f.relative_to(ROOT)}: {m.group(0)}")
    assert not bad, (
        "Внутренние адреса в открытом коде:\n  " + "\n  ".join(bad))
