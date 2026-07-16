#!/usr/bin/env bash
# Ставит Python 3.12 (brew), создаёт venv и зависимости.
set -euo pipefail
cd "$(dirname "$0")"

PY312="/opt/homebrew/bin/python3.12"

if [ ! -x "$PY312" ]; then
  echo "→ Устанавливаю python@3.12 через brew..."
  brew install python@3.12
fi

echo "→ Создаю venv на $($PY312 --version)..."
"$PY312" -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt

echo ""
echo "✓ Готово. Активируй: source .venv/bin/activate"
echo "  Запись:     python record_meeting.py"
echo "  Транскрипт: python transcribe.py recordings/<timestamp>"
