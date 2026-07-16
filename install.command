#!/usr/bin/env bash
# install.command — двойной клик в Finder ставит Meeting Transcriber «под ключ»:
# Homebrew, ffmpeg, Python-окружение, модели, сборка и установка .app.
# Рассчитан на технически неграмотного пользователя: запустил — прошёл шаги — готово.

cd "$(dirname "$0")" || exit 1

bold(){ printf "\n\033[1m%s\033[0m\n" "$1"; }
ok(){   printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn(){ printf "  \033[33m⚠\033[0m %s\n" "$1"; }
die(){  printf "\n\033[31m✗ %s\033[0m\n\n" "$1"; read -r -p "Нажми Enter, чтобы закрыть…" _; exit 1; }

clear
bold "Meeting Transcriber — установка"
echo "Займёт время: качается несколько ГБ (Python-пакеты и модели). Не закрывай окно."

# 1) Apple Silicon (MLX работает только на чипах Apple)
if [ "$(uname -m)" != "arm64" ]; then
  die "Нужен Mac с чипом Apple (M1/M2/M3/M4). На Intel-Маке движок распознавания не работает."
fi
ok "Чип Apple: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"

# 2) Xcode Command Line Tools (нужны для сборки приложения)
if ! xcode-select -p >/dev/null 2>&1; then
  bold "→ Ставлю инструменты разработчика Apple (откроется системное окно)…"
  xcode-select --install 2>/dev/null
  die "Заверши установку в открывшемся окне Apple, затем запусти install.command ещё раз."
fi
ok "Инструменты разработчика на месте"

# 3) Homebrew (менеджер пакетов)
if ! command -v brew >/dev/null 2>&1; then
  bold "→ Ставлю Homebrew (может спросить пароль от Мака)…"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Homebrew не установился. Проверь интернет и попробуй снова."
fi
# подхватить brew в текущую сессию
for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [ -x "$p" ] && eval "$("$p" shellenv)"
done
command -v brew >/dev/null 2>&1 || die "brew не в PATH после установки — перезапусти install.command."
ok "Homebrew: $(brew --version 2>/dev/null | head -1)"

# 4) ffmpeg (обработка звука) + librsvg (иконка приложения)
bold "→ Ставлю ffmpeg…"
brew list ffmpeg  >/dev/null 2>&1 || brew install ffmpeg  || die "ffmpeg не установился"
brew list librsvg >/dev/null 2>&1 || brew install librsvg >/dev/null 2>&1 || warn "librsvg не встал — иконка будет проще"
ok "ffmpeg готов"

# 5) Python-окружение + зависимости (torch/mlx — несколько ГБ)
bold "→ Готовлю Python-окружение и зависимости (это надолго)…"
./setup.sh || die "Не удалось поставить Python-окружение (см. ошибку выше)."
ok "Python-окружение готово"

# 6) Токен Hugging Face — для разделения спикеров (опционально)
if [ ! -f .env ] || ! grep -q "HF_TOKEN=" .env 2>/dev/null; then
  bold "Разделение спикеров (кто что сказал) — нужен бесплатный токен Hugging Face:"
  echo "  1) открой  https://huggingface.co/settings/tokens  → New token (тип: read)"
  echo "  2) прими условия  https://huggingface.co/pyannote/speaker-diarization-community-1"
  echo "  Можно пропустить (просто Enter) — тогда все собеседники будут помечены как «Собеседник»."
  printf "  Вставь токен и нажми Enter (или сразу Enter, чтобы пропустить): "
  read -r HFT
  if [ -n "$HFT" ]; then
    printf "HF_TOKEN=%s\n" "$HFT" >> .env
    ok "Токен сохранён"
  else
    warn "Без токена спикеры не разделяются (можно добавить позже в файл .env)"
  fi
fi

# 7) Сборка и установка приложения
bold "→ Собираю и устанавливаю приложение…"
( cd app && ./package_app.sh ) || die "Сборка приложения не удалась (см. ошибку выше)."

bold "Готово! 🎉"
echo "  • Приложение установлено в «Программы» (и ярлык на рабочем столе)."
echo "  • ПЕРВЫЙ запуск: правый клик по значку → «Открыть» → «Открыть» (обойти защиту один раз)."
echo "  • Разреши «Запись экрана» и «Микрофон», когда система попросит — без этого не запишет звук."
echo "  • Модель распознавания скачается при первой транскрипции (ещё несколько ГБ, один раз)."
echo
read -r -p "Нажми Enter, чтобы закрыть…" _
