#!/usr/bin/env python3
"""Read development bar data without credentials, refresh jobs or personal writes."""

import json
import math
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

MAXIMUM_JSON_BYTES = 1024 * 1024


def read_json(path):
    try:
        with path.open("rb") as source:
            data = source.read(MAXIMUM_JSON_BYTES + 1)
        return json.loads(data, parse_constant=lambda _: None) if len(data) <= MAXIMUM_JSON_BYTES else None
    except (OSError, ValueError):
        return None


def gpu_metrics():
    if sys.platform != "darwin":
        return {"error": "GPU sampling requires macOS IOAccelerator statistics."}

    try:
        result = subprocess.run(
            ["ioreg", "-a", "-r", "-c", "IOAccelerator", "-d", "1"],
            capture_output=True,
            check=True,
            timeout=1,
        )
        devices = []
        for entry in plistlib.loads(result.stdout):
            stats = entry.get("PerformanceStatistics", {})
            percent = stats.get("Device Utilization %", stats.get("GPU Activity(%)"))
            if not isinstance(percent, (int, float)) or not math.isfinite(percent) or not 0 <= percent <= 100:
                continue

            model = entry.get("model", entry.get("IORegistryEntryName", "GPU"))
            if isinstance(model, bytes):
                model = model.rstrip(b"\0").decode("utf-8", errors="replace")
            device = {"model": str(model), "percent": percent, "sampled_at": time.time()}
            for source, target in (
                ("Renderer Utilization %", "renderer_percent"),
                ("Tiler Utilization %", "tiler_percent"),
                ("In use system memory", "memory_used_bytes"),
            ):
                value = stats.get(source)
                if isinstance(value, (int, float)) and math.isfinite(value) and value >= 0:
                    device[target] = value
            devices.append(device)

        return max(devices, key=lambda device: device["percent"]) if devices else {"error": "No GPU utilization reported."}
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return {"error": "GPU sample unavailable: " + str(error)}


def usage_data():
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "telar/bar"
    settings = read_json(Path.home() / ".pi/agent/settings.json")
    keys = ("defaultProvider", "defaultModel", "defaultThinkingLevel")
    pi = {key: settings[key] for key in keys if isinstance(settings.get(key), str)} if isinstance(settings, dict) else None
    return {"claude": read_json(cache / "claude.json"), "codex": read_json(cache / "codex.json"), "pi": pi}


def main():
    if "--demo" in sys.argv or os.environ.get("TELAR_DEV_BAR_DEMO") == "1":
        state = {
            "gpu": {"model": "Demo GPU", "percent": 69, "sampled_at": time.time()},
            "claude": {"limits": [{"kind": "session", "percent": 100}, {"kind": "weekly_all", "percent": 20}]},
            "codex": [{"provider": "codex", "usage": {"primary": {"windowMinutes": 10080, "usedPercent": 28}}}],
            "pi": {"defaultProvider": "demo", "defaultModel": "Demo model", "defaultThinkingLevel": "high"},
        }
    elif "--gpu" in sys.argv:
        state = {"gpu": gpu_metrics()}
    else:
        state = usage_data()
    print(json.dumps(state, separators=(",", ":"), allow_nan=False))


if __name__ == "__main__":
    main()
