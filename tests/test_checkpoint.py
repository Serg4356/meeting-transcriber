"""Чекпойнт шагов транскрипции: пережить зависание, не пересчитывая сделанное."""
import json

import transcribe as t


def test_cache_roundtrip(tmp_path):
    cache = tmp_path / ".asr_mic.json"
    sig = {"mtime": 1.0, "size": 10}
    assert t._load_cache(cache, sig) is None          # пусто
    t._save_cache(cache, sig, [[0.0, 1.0, "привет"]])
    assert t._load_cache(cache, sig) == [[0.0, 1.0, "привет"]]


def test_cache_invalidates_on_sig_change(tmp_path):
    cache = tmp_path / ".asr_mic.json"
    t._save_cache(cache, {"mtime": 1.0, "size": 10}, [[0.0, 1.0, "a"]])
    assert t._load_cache(cache, {"mtime": 2.0, "size": 10}) is None  # файл сменился
    assert t._load_cache(cache, {"mtime": 1.0, "size": 99}) is None  # размер сменился


def test_corrupt_cache_recomputes(tmp_path):
    cache = tmp_path / ".asr_mic.json"
    cache.write_text("{битый json", encoding="utf-8")   # оборвано на зависании
    assert t._load_cache(cache, {"mtime": 1.0, "size": 10}) is None


def test_asr_cached_skips_second_call(tmp_path, monkeypatch):
    audio = tmp_path / "mic.wav"
    audio.write_bytes(b"x" * 100)
    calls = {"n": 0}

    def fake(repo, path, language):
        calls["n"] += 1
        return [(0.0, 1.0, "раз")]

    monkeypatch.setattr(t, "transcribe_track", fake)
    a = t._asr_cached(tmp_path, "mic", "repo-x", audio, "ru")
    b = t._asr_cached(tmp_path, "mic", "repo-x", audio, "ru")   # из кеша
    assert a == b == [(0.0, 1.0, "раз")]
    assert calls["n"] == 1, "второй вызов должен взять из кеша, не считать заново"


def test_asr_cached_recomputes_on_model_change(tmp_path, monkeypatch):
    audio = tmp_path / "mic.wav"
    audio.write_bytes(b"x" * 100)
    calls = {"n": 0}
    monkeypatch.setattr(t, "transcribe_track",
                        lambda r, p, l: (calls.__setitem__("n", calls["n"] + 1), [(0.0, 1.0, "y")])[1])
    t._asr_cached(tmp_path, "mic", "small", audio, "ru")
    t._asr_cached(tmp_path, "mic", "large-v3", audio, "ru")     # другая модель → пересчёт
    assert calls["n"] == 2


def test_diar_cached_roundtrip_and_skip(tmp_path, monkeypatch):
    audio = tmp_path / "system.wav"
    audio.write_bytes(b"x" * 100)
    calls = {"n": 0}

    def fake(path, hf, num, mx):
        calls["n"] += 1
        return [(0.0, 2.0, "SPEAKER_00")], {"SPEAKER_00": [0.1, 0.2]}

    monkeypatch.setattr(t, "diarize", fake)
    turns1, vecs1 = t._diar_cached(tmp_path, audio, "tok", None, 3)
    turns2, vecs2 = t._diar_cached(tmp_path, audio, "tok", None, 3)   # из кеша
    assert turns1 == turns2 == [(0.0, 2.0, "SPEAKER_00")]
    assert vecs1 == vecs2 == {"SPEAKER_00": [0.1, 0.2]}
    assert calls["n"] == 1


def test_clear_checkpoints(tmp_path):
    (tmp_path / ".asr_mic.json").write_text("{}", encoding="utf-8")
    (tmp_path / ".asr_system.json").write_text("{}", encoding="utf-8")
    (tmp_path / ".diar_system.json").write_text("{}", encoding="utf-8")
    t._clear_checkpoints(tmp_path)
    assert not list(tmp_path.glob(".asr_*.json"))
    assert not (tmp_path / ".diar_system.json").exists()


def test_save_cache_atomic_no_tmp_left(tmp_path):
    cache = tmp_path / ".asr_mic.json"
    t._save_cache(cache, {"mtime": 1.0, "size": 1}, [[0.0, 1.0, "z"]])
    assert cache.exists()
    assert not (tmp_path / ".asr_mic.json.tmp").exists()   # tmp переименован, не оставлен
    assert json.loads(cache.read_text())["data"] == [[0.0, 1.0, "z"]]
