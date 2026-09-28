"""Приёмник записей с телефона.

iPhone-аппка Terminus пишет микрофон и шлёт сюда multipart POST /upload.
Сервер кладёт запись в recordings/<сессия>/ (тот же формат, что у мак-аппки)
и запускает transcribe.py в фоне — дальше работает обычный пайплайн.

Запуск:  python3 ingest_server.py [--port 8787] [--recordings DIR]
Проверка: curl http://<мак>:8787/health
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

from aiohttp import web

SESSION_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}$")
MAX_UPLOAD = 512 * 1024 * 1024  # ~8 часов записи в 32 кбит/с


def default_recordings_dir() -> Path:
    return Path(__file__).resolve().parent / "mac-capture" / "recordings"


def session_dir(root: Path, session_id: str) -> Path:
    """Папка сессии. Имя валидируем: оно приходит из сети и идёт в путь."""
    if not SESSION_RE.match(session_id):
        raise ValueError(f"неожиданное имя сессии: {session_id!r}")
    return root / session_id


def start_transcribe(session: Path, python: str = sys.executable) -> subprocess.Popen | None:
    """Фоновая расшифровка с пониженным приоритетом — Мак остаётся отзывчивым."""
    script = Path(__file__).resolve().parent / "transcribe.py"
    if not script.exists():
        return None
    cmd = ["taskpolicy", "-b", python, str(script), str(session)]
    log = (session / "transcribe.log").open("w", encoding="utf-8")
    return subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)


async def handle_upload(request: web.Request) -> web.Response:
    root: Path = request.app["recordings"]
    reader = await request.multipart()
    meta: dict = {}
    audio_name = "mic.m4a"
    audio_chunks: list[bytes] = []
    total = 0

    async for part in reader:
        if part.name == "meta":
            meta = json.loads((await part.read(decode=True)).decode("utf-8"))
        elif part.name == "audio":
            audio_name = Path(part.filename or "mic.m4a").name
            while chunk := await part.read_chunk():
                total += len(chunk)
                if total > MAX_UPLOAD:
                    return web.json_response({"error": "файл больше лимита"}, status=413)
                audio_chunks.append(chunk)

    if not audio_chunks:
        return web.json_response({"error": "нет аудио"}, status=400)

    session_id = request.headers.get("X-Session-Id") or meta.get("started", "")
    try:
        target = session_dir(root, session_id)
    except ValueError as e:
        return web.json_response({"error": str(e)}, status=400)

    target.mkdir(parents=True, exist_ok=True)
    (target / audio_name).write_bytes(b"".join(audio_chunks))
    (target / "meeting.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    started = start_transcribe(target) is not None
    print(f"← {session_id}: {total/1e6:.1f} МБ, расшифровка {'запущена' if started else 'НЕ запущена'}")
    return web.json_response({"session": session_id, "bytes": total, "transcribing": started})


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "recordings": str(request.app["recordings"])})


def make_app(recordings: Path) -> web.Application:
    recordings.mkdir(parents=True, exist_ok=True)
    app = web.Application(client_max_size=MAX_UPLOAD)
    app["recordings"] = recordings
    app.add_routes([web.post("/upload", handle_upload), web.get("/health", handle_health)])
    return app


def main() -> None:
    ap = argparse.ArgumentParser(description="Приёмник записей с телефона")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--recordings", type=Path, default=default_recordings_dir())
    args = ap.parse_args()
    print(f"Terminus ingest: http://0.0.0.0:{args.port} → {args.recordings}")
    web.run_app(make_app(args.recordings), port=args.port, print=None)


if __name__ == "__main__":
    main()
