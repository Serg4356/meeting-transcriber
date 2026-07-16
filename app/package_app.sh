#!/usr/bin/env bash
# Собирает MeetingTranscriber.app из SPM-бинарника: Info.plist + иконка из
# logo.svg + ad-hoc подпись. Ставит в /Applications и кладёт ярлык на рабочий стол.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MeetingTranscriber"
BUNDLE_ID="com.serg.meeting-transcriber"
BIN_SRC=".build/release/MeetingRecorder"     # имя SPM-таргета
BUILD_DIR="/tmp/mt-build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "→ Сборка release-бинарника…"
swift build -c release

echo "→ Каркас бандла…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_SRC" "$APP/Contents/MacOS/$APP_NAME"

echo "→ Иконка из logo.svg (прозрачный фон через rsvg-convert)…"
ICONSET="$BUILD_DIR/$APP_NAME.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
BASE="$BUILD_DIR/logo1024.png"
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1024 -h 1024 logo.svg -o "$BASE"
else
  echo "  rsvg-convert не найден (brew install librsvg) — фон может быть непрозрачным"
  qlmanage -t -s 1024 -o "$BUILD_DIR" logo.svg >/dev/null 2>&1
  BASE="$BUILD_DIR/logo.svg.png"
fi
for s in 16 32 128 256 512; do
  sips -z $s $s "$BASE" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$BASE" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Info.plist…"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Meeting Transcriber</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>MTProjectRoot</key><string>$(cd .. && pwd)</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Для записи вашего голоса на встрече.</string>
  <key>NSHumanReadableCopyright</key><string>Meeting Transcriber</string>
</dict>
</plist>
PLIST

SIGN_ID="Meeting Transcriber Self"
echo "→ Подпись…"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  # Стабильный self-signed сертификат → подпись не меняется между пересборками →
  # macOS-разрешения (Screen Recording, Microphone) держатся вечно.
  codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 \
    && echo "  подписано стабильным сертификатом ($SIGN_ID)" \
    || echo "  ОШИБКА подписи сертификатом"
else
  echo "  ⚠ сертификат '$SIGN_ID' не найден — ad-hoc (разрешения будут слетать при пересборке)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1
fi

echo "→ Установка в /Applications…"
DEST="/Applications/$APP_NAME.app"
if rm -rf "$DEST" 2>/dev/null && cp -R "$APP" "$DEST" 2>/dev/null; then
  echo "  установлено: $DEST"
else
  DEST="$HOME/Applications/$APP_NAME.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"; cp -R "$APP" "$DEST"
  echo "  нет доступа к /Applications → установлено: $DEST"
fi

echo "→ Ярлык на рабочий стол…"
# ВАЖНО: только ${VAR} в фигурных скобках. На bash 3.2 (дефолт macOS) под
# UTF-8-локалью `$VAR` вплотную перед многобайтовым символом (напр. кавычкой-
# ёлочкой) утягивает его лид-байт в имя переменной -> «unbound variable».
# Скобки чинят это железно. Не плодим дубли перед созданием свежего ярлыка.
LABEL="Meeting Transcriber"
MADE=""
rm -f "${HOME}/Desktop/${APP_NAME}" "${HOME}/Desktop/${LABEL}" \
      "${HOME}/Desktop/Псевдоним ${APP_NAME}"* 2>/dev/null || true
# 1) Finder-алиас (красивый, с иконкой). Требует разрешения управлять Finder.
if osascript -e "tell application \"Finder\" to make alias file to POSIX file \"${DEST}\" at desktop" \
     -e "tell application \"Finder\" to set name of result to \"${LABEL}\"" >/dev/null 2>&1; then
  MADE="алиас"
# 2) Фолбэк - симлинк: без разрешений, двойной клик так же открывает приложение.
elif ln -sfn "${DEST}" "${HOME}/Desktop/${LABEL}" 2>/dev/null; then
  MADE="символическая ссылка"
fi
if [ -n "${MADE}" ]; then
  echo "  ярлык на рабочем столе создан: ${LABEL} (${MADE})"
else
  echo "  ярлык не создан - перетащи ${DEST} на рабочий стол вручную"
fi

echo ""
echo "✓ Готово. Приложение: $DEST"
echo "  Двойной клик по ярлыку на рабочем столе запускает Meeting Transcriber."
echo "  При первом запуске выдай Screen Recording + Microphone заново (новый бандл)."
