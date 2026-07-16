"""Тесты подбора модели под мощность машины (capability.py)."""
import capability
import pytest


def test_probe_has_fields():
    info = capability.probe()
    assert set(info) >= {"chip", "arm64", "cores", "ram_gb"}
    assert info["cores"] >= 1
    assert info["ram_gb"] >= 0


@pytest.mark.parametrize("ram,expected", [
    (64, "large-v3"),
    (32, "large-v3"),
    (24, "large-v3"),      # M4 Pro владельца — НЕ должно деградировать
    (16, "large-v3"),
    (12, "large-v3-turbo"),
    (10, "large-v3-turbo"),
    (8, "medium"),
    (4, "small"),
])
def test_pick_model_by_ram(ram, expected):
    info = {"chip": "x", "arm64": True, "cores": 8, "ram_gb": ram}
    assert capability.pick_model("auto", info) == expected


def test_mode_low_steps_down():
    info = {"chip": "x", "arm64": True, "cores": 8, "ram_gb": 24}
    assert capability.pick_model("auto", info) == "large-v3"
    assert capability.pick_model("low", info) == "large-v3-turbo"


def test_mode_high_forces_max_even_on_weak():
    info = {"chip": "x", "arm64": True, "cores": 4, "ram_gb": 4}
    assert capability.pick_model("auto", info) == "small"
    assert capability.pick_model("high", info) == "large-v3"


def test_low_on_weakest_does_not_underflow():
    info = {"chip": "x", "arm64": True, "cores": 2, "ram_gb": 2}
    # small — самый лёгкий; low не должен уйти за границу лестницы
    assert capability.pick_model("low", info) == "small"


def test_pick_model_key_is_known():
    # выбранный ключ обязан существовать в MLX_REPOS transcribe.py
    from transcribe import MLX_REPOS
    for mode in ("auto", "low", "high"):
        assert capability.pick_model(mode) in MLX_REPOS


def test_apply_nice_does_not_raise():
    capability.apply_nice(0)  # не должно падать
