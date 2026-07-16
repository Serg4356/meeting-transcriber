# mac-capture (Фаза 1 — прототип захвата)

Swift-утилита: пишет системный звук (любое приложение — Zoom.app, Teams,
браузер) + микрофон через **ScreenCaptureKit** (macOS 15+). Без BlackHole,
без перезагрузки — только разрешения.

Два файла на выходе: `system.caf` (собеседники) + `mic.caf` (я).

## Сборка и запуск

```bash
cd mac-capture
swift build            # соберёт .build/debug/capture
swift run capture      # запись в ./recordings/<timestamp>/, стоп — Enter
```

Первый запуск запросит разрешения:
- **Screen & System Audio Recording** — для звука приложений
- **Microphone** — для микрофона

Дай оба (Системные настройки → Приватность → …), перезапусти `swift run capture`.

## Проверка результата

```bash
# длительность и что записалось
ffprobe recordings/<timestamp>/system.caf
open recordings/<timestamp>/            # послушать в Finder

# транскрипт (из корня проекта, venv активен)
python ../transcribe.py mac-capture/recordings/<timestamp>
```

## Статус

- ✅ Компилируется (API ScreenCaptureKit macOS 15 верны)
- ⬜ Рантайм на реальном Zoom-звонке — не проверен (нужны разрешения + звонок)

## Дальше (не сделано)

- Фаза 2: транскрипция (облако vs whisper.cpp on-device)
- Фаза 3: menu-bar UI + подпись/нотаризация + .dmg (нужен Apple Developer $99)
