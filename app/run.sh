#!/usr/bin/env bash
# Собирает и запускает menu-bar приложение.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release 2>/dev/null || swift build
exec swift run -c release MeetingRecorder 2>/dev/null || swift run MeetingRecorder
