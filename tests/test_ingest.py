"""Приёмник записей с телефона: приём, валидация, запуск расшифровки.

Асинхронные вызовы гоняем через asyncio.run + тест-утилиты aiohttp —
плагины pytest-aiohttp/pytest-asyncio для этого не нужны.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path

import pytest
from aiohttp import FormData
from aiohttp.test_utils import TestClient, TestServer

import ingest_server


def test_session_dir_rejects_path_traversal(tmp_path: Path) -> None:
    # имя приходит из сети и идёт в путь — обход каталога недопустим
    with pytest.raises(ValueError):
        ingest_server.session_dir(tmp_path, "../../etc/passwd")


def test_session_dir_rejects_garbage(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        ingest_server.session_dir(tmp_path, "")


def test_session_dir_accepts_stamp(tmp_path: Path) -> None:
    assert ingest_server.session_dir(tmp_path, "2026-08-11 14-05-33") == \
        tmp_path / "2026-08-11 14-05-33"


@pytest.fixture
def app(tmp_path, monkeypatch):
    """Приложение с заглушкой расшифровки — тесты не гоняют Whisper."""
    started: list[Path] = []

    def fake_start(session, **kw):
        started.append(session)
        return object()

    monkeypatch.setattr(ingest_server, "start_transcribe", fake_start)
    application = ingest_server.make_app(tmp_path / "recordings")
    application["started"] = started
    return application


def call(app, coro_fn):
    """Поднимает тестовый сервер и выполняет сценарий."""
    async def runner():
        async with TestClient(TestServer(app)) as client:
            return await coro_fn(client)
    return asyncio.run(runner())


def upload_form(meta: dict | None, audio: bytes | None) -> FormData:
    form = FormData()
    if meta is not None:
        form.add_field("meta", json.dumps(meta), filename="meeting.json",
                       content_type="application/json")
    if audio is not None:
        form.add_field("audio", audio, filename="mic.m4a", content_type="audio/m4a")
    return form


def test_upload_saves_session_and_starts_transcribe(app) -> None:
    async def scenario(client):
        resp = await client.post(
            "/upload",
            data=upload_form({"title": "Планёрка", "single_track": True}, b"audiobytes"),
            headers={"X-Session-Id": "2026-08-11 14-05-33"})
        return resp.status, await resp.json()

    status, body = call(app, scenario)
    assert status == 200
    assert body["transcribing"] is True

    session = app["recordings"] / "2026-08-11 14-05-33"
    assert (session / "mic.m4a").read_bytes() == b"audiobytes"
    meta = json.loads((session / "meeting.json").read_text(encoding="utf-8"))
    assert meta["single_track"] is True          # флаг доезжает до пайплайна
    assert app["started"] == [session]


def test_upload_rejects_bad_session_id(app) -> None:
    async def scenario(client):
        resp = await client.post("/upload", data=upload_form({"title": "x"}, b"\x00"),
                                 headers={"X-Session-Id": "../escape"})
        return resp.status

    assert call(app, scenario) == 400
    assert not app["started"]
    assert not list((app["recordings"]).iterdir())


def test_upload_without_audio_is_rejected(app) -> None:
    async def scenario(client):
        resp = await client.post("/upload", data=upload_form({"title": "x"}, None),
                                 headers={"X-Session-Id": "2026-08-11 14-05-33"})
        return resp.status

    assert call(app, scenario) == 400
    assert not app["started"]


def test_health(app) -> None:
    async def scenario(client):
        resp = await client.get("/health")
        return resp.status, await resp.json()

    status, body = call(app, scenario)
    assert status == 200
    assert body["ok"] is True
