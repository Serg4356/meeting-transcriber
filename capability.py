"""Мощность машины → подбор модели whisper, чтобы на слабом Маке транскрипция
не отжирала все ресурсы и не тормозила передний план.

Единая точка для transcribe.py и live_transcribe.py (без дублирования — R5).

Пороги подобраны так, что 16 ГБ+ RAM → large-v3 (полное качество),
10–16 ГБ → large-v3-turbo (легче/быстрее), 8–10 ГБ → medium, <8 → small.
"""
from __future__ import annotations

import os
import subprocess

# Лестница моделей от лёгкой к тяжёлой — ключи совпадают с MLX_REPOS в transcribe.py.
LADDER = ["small", "medium", "large-v3-turbo", "large-v3"]


def _sysctl_int(key: str) -> int:
    try:
        r = subprocess.run(["sysctl", "-n", key],
                           capture_output=True, text=True, timeout=5)
        return int(r.stdout.strip())
    except (ValueError, subprocess.SubprocessError):
        return 0


def probe() -> dict:
    """Железо: чип, arm64?, ядра, RAM (ГБ)."""
    try:
        chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except subprocess.SubprocessError:
        chip = ""
    ram_bytes = _sysctl_int("hw.memsize")
    return {
        "chip": chip or "?",
        "arm64": os.uname().machine == "arm64",
        "cores": os.cpu_count() or _sysctl_int("hw.ncpu") or 1,
        "ram_gb": round(ram_bytes / (1024 ** 3)) if ram_bytes else 0,
    }


def pick_model(mode: str = "auto", info: dict | None = None) -> str:
    """Ключ модели под железо. mode: auto|low|high.

    low  — на ступень легче авто (ещё бережнее к ресурсам);
    high — форсировать максимум (large-v3) независимо от железа.
    """
    info = info or probe()
    ram = info["ram_gb"]
    if ram >= 16:
        base = "large-v3"
    elif ram >= 10:
        base = "large-v3-turbo"
    elif ram >= 8:
        base = "medium"
    else:
        base = "small"

    idx = LADDER.index(base)
    if mode == "low":
        idx = max(0, idx - 1)
    elif mode == "high":
        idx = len(LADDER) - 1
    return LADDER[idx]


def apply_nice(delta: int = 5) -> None:
    """Понижает приоритет процесса, чтобы уступать переднему плану (Zoom и т.п.).
    Тихо игнорит сбой (например, на не-UNIX). Дополняет background-QoS,
    который выставляет Swift-приложение через `taskpolicy -b`."""
    try:
        os.nice(delta)
    except (OSError, AttributeError):
        pass


def describe(mode: str = "auto") -> str:
    """Однострочное описание выбора — для лога транскрипции."""
    info = probe()
    model = pick_model(mode, info)
    return (f"машина: {info['chip']}, {info['ram_gb']} ГБ, {info['cores']} ядер "
            f"→ модель {model} (режим {mode})")


if __name__ == "__main__":
    import json
    p = probe()
    print(json.dumps(p, ensure_ascii=False))
    for m in ("low", "auto", "high"):
        print(f"  {m:>4} → {pick_model(m, p)}")
