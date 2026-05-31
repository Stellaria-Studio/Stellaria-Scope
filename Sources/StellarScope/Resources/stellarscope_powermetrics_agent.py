#!/usr/bin/env python3
"""
StellarScope optional hardware sampler.

v8 goals:
- keep GUI unprivileged
- update the JSON as close to the requested interval as possible
- use powermetrics for power/frequency/residency/thermal pressure
- opportunistically merge macmon, if installed, for Apple Silicon temperature data
- expose failures in `flat` instead of silently showing blanks
"""
from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

OUT = Path("/tmp/stellarscope-powermetrics.json")
CONTROL_PATH = Path("/tmp/stellarscope-control.json")
INTERVAL_MS = int(os.environ.get("STELLARSCOPE_INTERVAL_MS", "1000"))
SAMPLE_MS = max(250, INTERVAL_MS)
PROFILE = os.environ.get("STELLARSCOPE_PROFILE", "live").lower()
AGENT_SCHEMA_VERSION = 5
AGENT_FEATURES = "dynamic_sensors,smc_fan,display,storage,audio,bus,runtime_control,promotion_vrr,environment_motion"
SLOW_CACHE: dict[str, dict[str, Any]] = {}

# Apple Silicon community tools often install here. We do not require them.
MACMON_CANDIDATES = [
    "/opt/homebrew/bin/macmon",
    "/usr/local/bin/macmon",
    "/opt/local/bin/macmon",
    "/usr/bin/macmon",
]

SENSOR_TITLES = {
    "cpu_power_mw": ("CPU Power", "Power", "mW", "cpu_power_mw"),
    "gpu_power_mw": ("GPU Power", "Power", "mW", "gpu_power_mw"),
    "ane_power_mw": ("ANE Power", "Power", "mW", "ane_power_mw"),
    "combined_power_mw": ("Combined Power", "Power", "mW", "combined_power_mw"),
    "package_power_mw": ("Package Power", "Power", "mW", "package_power_mw"),
    "dram_power_mw": ("DRAM Power", "Power", "mW", "dram_power_mw"),
    "e_cluster_power_mw": ("E-cluster Power", "Power", "mW", "e_cluster_power_mw"),
    "p_cluster_power_mw": ("P-cluster Power", "Power", "mW", "p_cluster_power_mw"),
    "cpu_frequency_hz": ("CPU Frequency", "Frequency", "Hz", "cpu_frequency_hz"),
    "e_cluster_frequency_hz": ("E-cluster Frequency", "Frequency", "Hz", "e_cluster_frequency_hz"),
    "p_cluster_frequency_hz": ("P-cluster Frequency", "Frequency", "Hz", "p_cluster_frequency_hz"),
    "gpu_frequency_hz": ("GPU Frequency", "Frequency", "Hz", "gpu_frequency_hz"),
    "gpu_residency_percent": ("GPU Residency", "Frequency", "%", "gpu_residency_percent"),
    "cpu_die_temperature_c": ("CPU Die Temperature", "Temperature", "C", "cpu_die_temperature_c"),
    "gpu_die_temperature_c": ("GPU Die Temperature", "Temperature", "C", "gpu_die_temperature_c"),
    "cpu_thermal_level": ("CPU Thermal Level", "Thermal", "", "cpu_thermal_level"),
    "gpu_thermal_level": ("GPU Thermal Level", "Thermal", "", "gpu_thermal_level"),
    "fan_rpm": ("Fan RPM", "Fan", "rpm", "fan_rpm"),
    "thermal_pressure": ("Thermal Pressure", "Thermal", "", "thermal_pressure"),
}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def flatten(obj: Any, prefix: str = "") -> dict[str, Any]:
    out: dict[str, Any] = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = f"{prefix}.{k}" if prefix else str(k)
            out.update(flatten(v, key))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            key = f"{prefix}[{i}]" if prefix else f"[{i}]"
            out.update(flatten(v, key))
    else:
        out[prefix] = obj
    return out


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(tmp, 0o644)
    tmp.replace(path)


def clamp_int(value: Any, default: int, minimum: int, maximum: int) -> int:
    try:
        parsed = int(float(value))
    except Exception:
        return default
    return max(minimum, min(maximum, parsed))


def apply_runtime_control() -> None:
    global INTERVAL_MS, SAMPLE_MS, PROFILE
    if not CONTROL_PATH.exists():
        return
    try:
        data = json.loads(CONTROL_PATH.read_text(encoding="utf-8"))
    except Exception:
        return
    if not isinstance(data, dict):
        return
    INTERVAL_MS = clamp_int(data.get("helper_interval_ms"), INTERVAL_MS, 250, 10_000)
    SAMPLE_MS = max(250, INTERVAL_MS)
    profile = str(data.get("profile", PROFILE)).lower()
    if profile in {"quiet", "live", "bench"}:
        PROFILE = profile


def cadence(name: str) -> int:
    tables = {
        "quiet": {"smc": 10, "debug": 30, "system": 90},
        "live": {"smc": 5, "debug": 15, "system": 30},
        "bench": {"smc": 3, "debug": 8, "system": 12},
    }
    return tables.get(PROFILE, tables["live"]).get(name, 30)


def cached_collect(name: str, loop_index: int, every: int, collector: Any) -> dict[str, Any]:
    cached = SLOW_CACHE.get(name)
    if cached is None or loop_index % max(1, every) == 0:
        cached = collector()
        cached.setdefault("flat", {})[f"{name}.cache_refreshed_loop"] = loop_index
        cached.setdefault("flat", {})[f"{name}.cache_profile"] = PROFILE
        SLOW_CACHE[name] = cached
    return cached


def numeric(value: Any) -> float | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    s = metric_text(value).replace(",", "")
    m = re.search(r"[-+]?\d+(?:\.\d+)?", s)
    if not m:
        return None
    return float(m.group(0))


def metric_text(value: Any) -> str:
    s = str(value)
    for sep in (":", "="):
        if sep in s:
            return s.split(sep, 1)[1].strip()
    return s.strip()


def value_to_mw(value: Any) -> float | None:
    n = numeric(value)
    if n is None:
        return None
    s = metric_text(value).lower()
    if "uw" in s or "µw" in s:
        return n / 1000.0
    if re.search(r"(^|\s)w($|\s)", s) and "mw" not in s:
        return n * 1000.0
    return n


def watts_to_mw(value: Any) -> float | None:
    n = numeric(value)
    return None if n is None else n * 1000.0


def value_to_hz(value: Any) -> float | None:
    n = numeric(value)
    if n is None:
        return None
    s = metric_text(value).lower()
    if "ghz" in s:
        return n * 1_000_000_000.0
    if "mhz" in s:
        return n * 1_000_000.0
    if "khz" in s:
        return n * 1_000.0
    return n


def mhz_to_hz(value: Any) -> float | None:
    n = numeric(value)
    return None if n is None else n * 1_000_000.0


def ratio_to_percent(value: Any) -> float | None:
    n = numeric(value)
    if n is None:
        return None
    return n * 100.0 if n <= 1.0 else n


def make_sensor(
    sensor_id: str,
    title: str,
    category: str,
    value: Any,
    unit: str,
    source: str,
    quality: str = "ok",
    raw_key: str | None = None,
    is_experimental: bool = False,
) -> dict[str, Any] | None:
    if value is None:
        return None
    return {
        "id": sensor_id,
        "title": title,
        "category": category,
        "value": value,
        "unit": unit,
        "source": source,
        "quality": quality,
        "rawKey": raw_key or sensor_id,
        "timestamp": now_iso(),
        "isExperimental": is_experimental,
    }


def append_sensor(sensors: list[dict[str, Any]], *args: Any, **kwargs: Any) -> None:
    sensor = make_sensor(*args, **kwargs)
    if sensor is not None:
        sensors.append(sensor)


def sensors_from_summary(summary: dict[str, Any], source: str, prefix: str = "summary") -> list[dict[str, Any]]:
    sensors: list[dict[str, Any]] = []
    for key, value in summary.items():
        meta = SENSOR_TITLES.get(key)
        if not meta:
            continue
        title, category, unit, raw_key = meta
        append_sensor(sensors, f"{prefix}.{key}", title, category, value, unit, source, raw_key=raw_key)
    return sensors


def merge_sensors(dst: list[dict[str, Any]], src: list[dict[str, Any]]) -> None:
    seen = {str(item.get("id")) for item in dst}
    for item in src:
        sid = str(item.get("id"))
        if sid and sid not in seen:
            dst.append(item)
            seen.add(sid)


def safe_id(text: Any) -> str:
    clean = re.sub(r"[^a-z0-9]+", "_", str(text).lower()).strip("_")
    return clean[:72] or "unknown"


def system_profiler_json(types: list[str], timeout: float = 8.0) -> dict[str, Any]:
    cmd = ["/usr/sbin/system_profiler", *types, "-json"]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(err or f"system_profiler exited {proc.returncode}")
    data = json.loads(proc.stdout.decode("utf-8", errors="replace"))
    if not isinstance(data, dict):
        raise RuntimeError("system_profiler returned non-object JSON")
    return data


def ioreg_plist(class_name: str, timeout: float = 4.0) -> list[Any]:
    proc = subprocess.run(["/usr/sbin/ioreg", "-r", "-c", class_name, "-a"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(err or f"ioreg {class_name} exited {proc.returncode}")
    if not proc.stdout.strip():
        return []
    data = plistlib.loads(proc.stdout)
    return data if isinstance(data, list) else []


def mach_timebase() -> tuple[float, float]:
    try:
        import ctypes

        class TimebaseInfo(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

        info = TimebaseInfo()
        ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(info))
        if info.numer and info.denom:
            return float(info.numer), float(info.denom)
    except Exception:
        pass
    return 1.0, 1.0


def mach_interval_to_hz(ticks: Any) -> float | None:
    n = numeric(ticks)
    if not n or n <= 0:
        return None
    numer, denom = mach_timebase()
    seconds = (n * numer / denom) / 1_000_000_000.0
    return 1.0 / seconds if seconds > 0 else None


def parse_resolution(text: Any) -> tuple[float | None, float | None]:
    m = re.search(r"(\d+)\s*x\s*(\d+)", str(text))
    if not m:
        return None, None
    return float(m.group(1)), float(m.group(2))


def parse_refresh_hz(text: Any) -> float | None:
    m = re.search(r"@\s*([-+]?\d+(?:\.\d+)?)\s*Hz", str(text), re.I)
    return float(m.group(1)) if m else None


def add_flat_scalars(flat: dict[str, Any], prefix: str, value: Any, limit: int = 180) -> None:
    added = 0
    for key, raw in flatten(value, prefix).items():
        if added >= limit:
            break
        if isinstance(raw, (str, int, float, bool)):
            flat[key] = raw
            added += 1


def parse_ioreg_value(raw: str) -> Any:
    value = raw.strip().rstrip(",")
    if value in {"Yes", "No"}:
        return value == "Yes"
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    if re.fullmatch(r"[-+]?\d+", value):
        try:
            return int(value)
        except ValueError:
            return value
    if re.fullmatch(r"[-+]?\d+\.\d+", value):
        try:
            return float(value)
        except ValueError:
            return value
    return value


def apple_battery_temp_c(value: Any) -> float | None:
    n = numeric(value)
    if n is None:
        return None
    if n > 1000:
        return n / 10.0 - 273.15
    if n > 200:
        return n / 10.0
    return n


def first_matching(flat: dict[str, Any], *needles: str) -> Any | None:
    lowered = [(k.lower(), v) for k, v in flat.items()]
    for needle in needles:
        n = needle.lower()
        for k, v in lowered:
            if n in k:
                return v
    return None


def mentions_p_cluster(text: str) -> bool:
    return bool(re.search(r"\bp(?:erformance)?[ -]?\d*[ -]?cluster\b", text))


def mentions_e_cluster(text: str) -> bool:
    return bool(re.search(r"\be(?:fficiency)?[ -]?\d*[ -]?cluster\b", text))


def summary_from_flat(flat: dict[str, Any]) -> dict[str, Any]:
    # powermetrics plist key names are not stable between macOS releases.
    cpu_power = first_matching(flat, "cpu_power", "processor_power", "cpu power")
    gpu_power = first_matching(flat, "gpu_power", "gpu power")
    ane_power = first_matching(flat, "ane_power", "ane power", "neural")
    combined = first_matching(flat, "combined_power", "combined power", "package_power", "package power")
    dram = first_matching(flat, "dram_power", "dram power", "memory_power", "memory power")
    e_power = first_matching(flat, "e-cluster power", "e0-cluster power", "e_cluster_power", "e cluster power", "efficiency cluster power")
    p_power = first_matching(flat, "p-cluster power", "p0-cluster power", "p_cluster_power", "p cluster power", "performance cluster power")

    gpu_freq = first_matching(flat, "gpu_frequency", "gpu active frequency", "gpu_active_frequency", "gpu hw active frequency")
    gpu_res = first_matching(flat, "gpu_residency", "gpu active residency", "gpu_active_residency")
    cpu_freq = first_matching(flat, "cpu_frequency", "cpu active frequency", "cpu_active_frequency")
    e_freq = first_matching(flat, "e-cluster hw active frequency", "e0-cluster hw active frequency", "e_cluster_frequency", "e cluster frequency")
    p_freq = first_matching(flat, "p-cluster hw active frequency", "p0-cluster hw active frequency", "p_cluster_frequency", "p cluster frequency")

    cpu_temp = first_matching(flat, "cpu die temperature", "cpu temperature", "cpu_temp", "cpu temp")
    gpu_temp = first_matching(flat, "gpu die temperature", "gpu temperature", "gpu_temp", "gpu temp")
    fan = first_matching(flat, "fan rpm", "fan speed", "fan0", "f0ac")
    pressure = first_matching(flat, "thermal_pressure", "current pressure level", "pressure_level", "current pressure")

    return {
        "cpu_power_mw": value_to_mw(cpu_power),
        "gpu_power_mw": value_to_mw(gpu_power),
        "ane_power_mw": value_to_mw(ane_power),
        "combined_power_mw": value_to_mw(combined),
        "package_power_mw": value_to_mw(combined),
        "dram_power_mw": value_to_mw(dram),
        "e_cluster_power_mw": value_to_mw(e_power),
        "p_cluster_power_mw": value_to_mw(p_power),
        "cpu_frequency_hz": value_to_hz(cpu_freq),
        "e_cluster_frequency_hz": value_to_hz(e_freq),
        "p_cluster_frequency_hz": value_to_hz(p_freq),
        "gpu_frequency_hz": value_to_hz(gpu_freq),
        "gpu_residency_percent": ratio_to_percent(gpu_res),
        "thermal_pressure": str(pressure) if pressure is not None else None,
        "cpu_die_temperature_c": numeric(cpu_temp),
        "gpu_die_temperature_c": numeric(gpu_temp),
        "fan_rpm": numeric(fan),
    }


def merge_summary(dst: dict[str, Any], src: dict[str, Any], prefer_new: bool = True) -> None:
    for k, v in src.items():
        if v is None:
            continue
        if prefer_new or dst.get(k) is None:
            dst[k] = v


def parse_powermetrics_text(text: str, prefix: str = "text") -> tuple[dict[str, Any], dict[str, Any]]:
    flat: dict[str, Any] = {}
    summary: dict[str, Any] = {}

    def set_if_empty(key: str, value: Any) -> None:
        if value is not None and summary.get(key) is None:
            summary[key] = value

    for idx, raw in enumerate(text.splitlines()):
        line = raw.strip()
        if not line:
            continue
        if ":" in line and len(line) < 220:
            k, v = line.split(":", 1)
            key = re.sub(r"\s+", " ", k.strip())
            val = v.strip()
            if key and val:
                base_key = f"{prefix}.{key}"
                final_key = base_key
                suffix = 2
                while final_key in flat:
                    final_key = f"{base_key} #{suffix}"
                    suffix += 1
                flat[final_key] = val

        lower = line.lower()
        metric = metric_text(line)
        if "cpu power" in lower and "ane" not in lower:
            set_if_empty("cpu_power_mw", value_to_mw(metric))
        if "gpu power" in lower:
            set_if_empty("gpu_power_mw", value_to_mw(metric))
        if "ane power" in lower or "neural engine power" in lower:
            set_if_empty("ane_power_mw", value_to_mw(metric))
        if "combined power" in lower or "package power" in lower or "all power" in lower:
            mw = value_to_mw(metric)
            set_if_empty("combined_power_mw", mw)
            set_if_empty("package_power_mw", mw)
        if "dram power" in lower or "memory power" in lower or "ram power" in lower:
            set_if_empty("dram_power_mw", value_to_mw(metric))
        if mentions_e_cluster(lower) and "power" in lower:
            set_if_empty("e_cluster_power_mw", value_to_mw(metric))
        if mentions_p_cluster(lower) and "power" in lower:
            set_if_empty("p_cluster_power_mw", value_to_mw(metric))
        if "gpu" in lower and "frequency" in lower:
            set_if_empty("gpu_frequency_hz", value_to_hz(metric))
        if "gpu" in lower and ("resid" in lower or "active" in lower):
            if "frequency" not in lower:
                set_if_empty("gpu_residency_percent", ratio_to_percent(metric))
        if mentions_e_cluster(lower) and "frequency" in lower:
            set_if_empty("e_cluster_frequency_hz", value_to_hz(metric))
        if mentions_p_cluster(lower) and "frequency" in lower:
            set_if_empty("p_cluster_frequency_hz", value_to_hz(metric))
        if "cpu" in lower and "frequency" in lower:
            set_if_empty("cpu_frequency_hz", value_to_hz(metric))
        if "cpu" in lower and "temperature" in lower:
            set_if_empty("cpu_die_temperature_c", numeric(metric))
        if "gpu" in lower and "temperature" in lower:
            set_if_empty("gpu_die_temperature_c", numeric(metric))
        if "cpu thermal level" in lower:
            set_if_empty("cpu_thermal_level", numeric(metric))
        if "gpu thermal level" in lower:
            set_if_empty("gpu_thermal_level", numeric(metric))
        if "fan" in lower and ("rpm" in lower or "speed" in lower):
            set_if_empty("fan_rpm", numeric(metric))
        if "current pressure level" in lower or "pressure level" in lower:
            summary["thermal_pressure"] = metric
        elif "thermal pressure" in lower and ":" in line:
            summary.setdefault("thermal_pressure", metric)

        if idx < 180:
            flat[f"{prefix}.raw.line.{idx:03d}"] = line

    return summary, flat


def run_powermetrics_variant(cmd: list[str], fmt: str, samplers: str, timeout_s: float) -> tuple[dict[str, Any], dict[str, Any]]:
    proc = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout_s)
    if fmt == "plist":
        data = plistlib.loads(proc.stdout)
        flat = {k: v for k, v in flatten(data).items() if isinstance(v, (str, int, float, bool))}
        summary = summary_from_flat(flat)
        return summary, flat
    text = proc.stdout.decode("utf-8", errors="replace")
    return parse_powermetrics_text(text, prefix=f"powermetrics.{samplers}")


def power_command_variants() -> list[tuple[list[str], str, str]]:
    base = ["/usr/bin/powermetrics", "-n", "1", "-i", str(SAMPLE_MS)]
    # Keep this fallback small. Thermal is sampled separately, and unsupported
    # sampler combinations can block long enough to make the helper look stale.
    return [
        (base + ["--samplers", "cpu_power,gpu_power", "--show-usage-summary", "-f", "plist"], "plist", "cpu_power,gpu_power"),
        (base + ["--samplers", "cpu_power,gpu_power", "--show-usage-summary"], "text", "cpu_power,gpu_power"),
        (base + ["--samplers", "cpu_power", "--show-usage-summary"], "text", "cpu_power"),
    ]


def collect_power_once() -> dict[str, Any]:
    macmon = collect_macmon_once()
    if macmon.get("summary"):
        return {
            "timestamp": now_iso(),
            "status": "running",
            "source": "macmon",
            "samplers": "macmon pipe",
            "pid": os.getpid(),
            "summary": macmon.get("summary", {}),
            "flat": macmon.get("flat", {}),
            "sensors": macmon.get("sensors", []),
        }

    last_error = None
    timeout_s = max(12.0, SAMPLE_MS / 1000.0 + 8.0)
    for cmd, fmt, samplers in power_command_variants():
        try:
            summary, flat = run_powermetrics_variant(cmd, fmt, samplers, timeout_s=timeout_s)
            flat.update(macmon.get("flat", {}))
            flat["agent.power_command"] = " ".join(cmd)
            return {
                "timestamp": now_iso(),
                "status": "running",
                "source": f"powermetrics:{fmt}",
                "samplers": samplers,
                "pid": os.getpid(),
                "summary": {k: v for k, v in summary.items() if v is not None},
                "flat": flat,
                "sensors": sensors_from_summary(summary, f"powermetrics:{fmt}", prefix="powermetrics"),
            }
        except Exception as exc:  # noqa: BLE001
            last_error = f"{' '.join(cmd)} -> {type(exc).__name__}: {exc}"
            continue
    return {
        "timestamp": now_iso(),
        "status": "error",
        "source": "powermetrics",
        "pid": os.getpid(),
        "summary": {},
        "flat": {"agent.power_error": last_error or "unknown powermetrics error", **macmon.get("flat", {})},
        "sensors": macmon.get("sensors", []),
        "error": last_error or "unknown powermetrics error",
    }


def collect_thermal_pressure_once() -> dict[str, Any]:
    # Fast fallback for thermal pressure only. Useful when combined sampler variants do not include it.
    variants = [
        ["/usr/bin/powermetrics", "-n", "1", "-i", "250", "--samplers", "thermal"],
        ["/usr/bin/powermetrics", "-n", "1", "-i", "250", "-s", "thermal"],
    ]
    last_error = None
    for cmd in variants:
        try:
            proc = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4)
            text = proc.stdout.decode("utf-8", errors="replace")
            summary, flat = parse_powermetrics_text(text, prefix="thermal")
            flat["thermal.command"] = " ".join(cmd)
            return {"summary": summary, "flat": flat, "sensors": sensors_from_summary(summary, "powermetrics:thermal", prefix="thermal")}
        except Exception as exc:  # noqa: BLE001
            last_error = f"{' '.join(cmd)} -> {type(exc).__name__}: {exc}"
    return {"summary": {}, "flat": {"thermal.error": last_error or "thermal sampler unavailable"}, "sensors": []}


def collect_smc_once() -> dict[str, Any]:
    # On many Apple Silicon + macOS builds, `smc` is not exposed via powermetrics.
    # We still try it because it may expose fan RPM / die temperatures on some machines.
    variants = [
        ["/usr/bin/powermetrics", "-n", "1", "-i", "500", "--samplers", "smc"],
        ["/usr/bin/powermetrics", "-n", "1", "-i", "500", "-s", "smc"],
    ]
    last_error = None
    for cmd in variants:
        try:
            proc = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            text = proc.stdout.decode("utf-8", errors="replace")
            summary, flat = parse_powermetrics_text(text, prefix="smc")
            flat["smc.command"] = " ".join(cmd)
            return {"summary": summary, "flat": flat, "sensors": sensors_from_summary(summary, "powermetrics:smc", prefix="smc")}
        except Exception as exc:  # noqa: BLE001
            last_error = f"{' '.join(cmd)} -> {type(exc).__name__}: {exc}"
    return {"summary": {}, "flat": {"smc.error": last_error or "smc sampler unavailable"}, "sensors": []}


def find_macmon() -> str | None:
    for p in MACMON_CANDIDATES:
        if Path(p).exists() and os.access(p, os.X_OK):
            return p
    return shutil.which("macmon")


def find_smc_probe() -> str | None:
    script_dir = Path(__file__).resolve().parent
    candidates = [
        script_dir / "StellarScopeSMCProbe",
        script_dir.parent.parent / "MacOS" / "StellarScopeSMCProbe",
        Path.cwd() / "agent" / "StellarScopeSMCProbe",
        Path.cwd() / ".build" / "release" / "StellarScopeSMCProbe",
    ]
    for path in candidates:
        if path.exists() and os.access(path, os.X_OK):
            return str(path)
    return shutil.which("StellarScopeSMCProbe")


def last_json_object(stdout: str) -> dict[str, Any] | None:
    # macmon pipe may output one JSON object per line or a pretty JSON object.
    lines = [ln.strip() for ln in stdout.splitlines() if ln.strip()]
    for line in reversed(lines):
        if line.startswith("{") and line.endswith("}"):
            try:
                obj = json.loads(line)
                if isinstance(obj, dict):
                    return obj
            except json.JSONDecodeError:
                pass
    try:
        obj = json.loads(stdout)
        return obj if isinstance(obj, dict) else None
    except json.JSONDecodeError:
        return None


def collect_macmon_once() -> dict[str, Any]:
    macmon = find_macmon()
    if not macmon:
        return {"summary": {}, "flat": {"macmon.status": "not found; install with `brew install macmon` if you want native Apple Silicon temp backend"}, "sensors": []}
    cmd = [macmon, "pipe", "-s", "1", "-i", str(max(250, min(SAMPLE_MS, 1000)))]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=max(12.0, SAMPLE_MS / 1000.0 + 9.0))
        stdout = proc.stdout.decode("utf-8", errors="replace")
        stderr = proc.stderr.decode("utf-8", errors="replace").strip()
        if proc.returncode != 0:
            return {"summary": {}, "flat": {"macmon.error": f"exit {proc.returncode}: {stderr}"}}
        obj = last_json_object(stdout)
        if not obj:
            return {"summary": {}, "flat": {"macmon.error": "no JSON parsed", "macmon.stdout.sample": stdout[:1200], "macmon.stderr": stderr}}

        flat = {f"macmon.{k}": v for k, v in flatten(obj).items() if isinstance(v, (str, int, float, bool))}
        summary: dict[str, Any] = {}
        temp = obj.get("temp") if isinstance(obj.get("temp"), dict) else {}
        memory = obj.get("memory") if isinstance(obj.get("memory"), dict) else {}

        # macmon units per README: temp Celsius, power Watts, freq MHz, usage 0..1.
        summary["cpu_die_temperature_c"] = numeric(temp.get("cpu_temp_avg"))
        summary["gpu_die_temperature_c"] = numeric(temp.get("gpu_temp_avg"))
        summary["cpu_power_mw"] = watts_to_mw(obj.get("cpu_power"))
        summary["gpu_power_mw"] = watts_to_mw(obj.get("gpu_power"))
        summary["ane_power_mw"] = watts_to_mw(obj.get("ane_power"))
        summary["combined_power_mw"] = watts_to_mw(obj.get("all_power"))
        summary["package_power_mw"] = watts_to_mw(obj.get("all_power"))
        summary["dram_power_mw"] = watts_to_mw(obj.get("ram_power"))

        gpu_usage = obj.get("gpu_usage")
        if isinstance(gpu_usage, list) and len(gpu_usage) >= 2:
            summary["gpu_frequency_hz"] = mhz_to_hz(gpu_usage[0])
            summary["gpu_residency_percent"] = ratio_to_percent(gpu_usage[1])
        ecpu_usage = obj.get("ecpu_usage")
        pcpu_usage = obj.get("pcpu_usage")
        if isinstance(ecpu_usage, list) and ecpu_usage:
            summary["e_cluster_frequency_hz"] = mhz_to_hz(ecpu_usage[0])
        if isinstance(pcpu_usage, list) and pcpu_usage:
            summary["p_cluster_frequency_hz"] = mhz_to_hz(pcpu_usage[0])

        # Put macmon memory in raw fields only; GUI uses its Mach memory collector.
        if isinstance(memory, dict):
            flat["macmon.memory.ram_usage"] = memory.get("ram_usage", "")
            flat["macmon.memory.swap_usage"] = memory.get("swap_usage", "")
        flat["macmon.command"] = " ".join(cmd)
        clean_summary = {k: v for k, v in summary.items() if v is not None}
        sensors = sensors_from_summary(clean_summary, "macmon", prefix="macmon")
        append_sensor(sensors, "macmon.cpu_usage", "CPU Usage", "Frequency", ratio_to_percent(obj.get("cpu_usage_pct")), "%", "macmon", raw_key="macmon.cpu_usage_pct")
        append_sensor(sensors, "macmon.ecpu_usage", "E-cluster Usage", "Frequency", ratio_to_percent(ecpu_usage[1]) if isinstance(ecpu_usage, list) and len(ecpu_usage) > 1 else None, "%", "macmon", raw_key="macmon.ecpu_usage[1]")
        append_sensor(sensors, "macmon.pcpu_usage", "P-cluster Usage", "Frequency", ratio_to_percent(pcpu_usage[1]) if isinstance(pcpu_usage, list) and len(pcpu_usage) > 1 else None, "%", "macmon", raw_key="macmon.pcpu_usage[1]")
        append_sensor(sensors, "macmon.sys_power_mw", "System Power", "Power", watts_to_mw(obj.get("sys_power")), "mW", "macmon", raw_key="macmon.sys_power")
        append_sensor(sensors, "macmon.gpu_ram_power_mw", "GPU RAM Power", "Power", watts_to_mw(obj.get("gpu_ram_power")), "mW", "macmon", raw_key="macmon.gpu_ram_power")
        return {"summary": clean_summary, "flat": flat, "sensors": sensors}
    except Exception as exc:  # noqa: BLE001
        return {"summary": {}, "flat": {"macmon.error": f"{type(exc).__name__}: {exc}", "macmon.command": " ".join(cmd)}, "sensors": []}


def collect_battery_once() -> dict[str, Any]:
    cmd = ["/usr/sbin/ioreg", "-rn", "AppleSmartBattery", "-l"]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
        text = proc.stdout.decode("utf-8", errors="replace")
        flat: dict[str, Any] = {"battery.command": " ".join(cmd)}
        for key, raw in re.findall(r'"([^"]+)"\s=\s([^\n]+)', text):
            value = parse_ioreg_value(raw)
            if isinstance(value, (str, int, float, bool)):
                flat[f"battery.{key}"] = value

        adapter = re.search(r'"AdapterDetails"\s=\s\{([^}]+)\}', text)
        if adapter:
            for key, raw in re.findall(r'"([^"]+)"=([^,}]+)', adapter.group(1)):
                flat[f"battery.AdapterDetails.{key}"] = parse_ioreg_value(raw)

        telemetry = re.search(r'"PowerTelemetryData"\s=\s\{([^}]+)\}', text)
        if telemetry:
            for key, raw in re.findall(r'"([^"]+)"=([^,}]+)', telemetry.group(1)):
                flat[f"battery.PowerTelemetryData.{key}"] = parse_ioreg_value(raw)

        sensors: list[dict[str, Any]] = []
        append_sensor(sensors, "battery.charge_percent", "Battery Charge", "Battery", numeric(flat.get("battery.CurrentCapacity")), "%", "AppleSmartBattery", raw_key="battery.CurrentCapacity")
        append_sensor(sensors, "battery.raw_capacity_mah", "Battery Raw Capacity", "Battery", numeric(flat.get("battery.AppleRawCurrentCapacity")), "mAh", "AppleSmartBattery", raw_key="battery.AppleRawCurrentCapacity")
        append_sensor(sensors, "battery.max_capacity_mah", "Battery Max Capacity", "Battery", numeric(flat.get("battery.AppleRawMaxCapacity")), "mAh", "AppleSmartBattery", raw_key="battery.AppleRawMaxCapacity")
        append_sensor(sensors, "battery.design_capacity_mah", "Battery Design Capacity", "Battery", numeric(flat.get("battery.DesignCapacity")), "mAh", "AppleSmartBattery", raw_key="battery.DesignCapacity")
        append_sensor(sensors, "battery.cycle_count", "Battery Cycles", "Battery", numeric(flat.get("battery.CycleCount")), "", "AppleSmartBattery", raw_key="battery.CycleCount")
        append_sensor(sensors, "battery.voltage_mv", "Battery Voltage", "Battery", numeric(flat.get("battery.AppleRawBatteryVoltage") or flat.get("battery.Voltage")), "mV", "AppleSmartBattery", raw_key="battery.AppleRawBatteryVoltage")
        append_sensor(sensors, "battery.amperage_ma", "Battery Amperage", "Battery", numeric(flat.get("battery.InstantAmperage") or flat.get("battery.Amperage")), "mA", "AppleSmartBattery", raw_key="battery.InstantAmperage")
        append_sensor(sensors, "battery.temperature_c", "Battery Temperature", "Temperature", apple_battery_temp_c(flat.get("battery.Temperature")), "C", "AppleSmartBattery", raw_key="battery.Temperature")
        append_sensor(sensors, "battery.virtual_temperature_c", "Battery Virtual Temperature", "Temperature", apple_battery_temp_c(flat.get("battery.VirtualTemperature")), "C", "AppleSmartBattery", raw_key="battery.VirtualTemperature", is_experimental=True)
        append_sensor(sensors, "adapter.watts", "Adapter Rating", "Battery", numeric(flat.get("battery.AdapterDetails.Watts")), "W", "AppleSmartBattery", raw_key="battery.AdapterDetails.Watts")
        append_sensor(sensors, "adapter.voltage_mv", "Adapter Voltage", "Battery", numeric(flat.get("battery.AdapterDetails.AdapterVoltage")), "mV", "AppleSmartBattery", raw_key="battery.AdapterDetails.AdapterVoltage")
        append_sensor(sensors, "adapter.current_ma", "Adapter Current", "Battery", numeric(flat.get("battery.AdapterDetails.Current")), "mA", "AppleSmartBattery", raw_key="battery.AdapterDetails.Current")
        append_sensor(sensors, "system.input_power_mw", "System Input Power", "Power", numeric(flat.get("battery.PowerTelemetryData.SystemPowerIn")), "mW", "AppleSmartBattery", raw_key="battery.PowerTelemetryData.SystemPowerIn")
        return {"summary": {}, "flat": flat, "sensors": sensors}
    except Exception as exc:  # noqa: BLE001
        return {"summary": {}, "flat": {"battery.error": f"{type(exc).__name__}: {exc}", "battery.command": " ".join(cmd)}, "sensors": []}


def collect_smc_fan_readonly_once() -> dict[str, Any]:
    keys = ["FNum", "F0Ac", "F0Mn", "F0Mx", "F0ID", "F1Ac", "F1Mn", "F1Mx", "F1ID"]
    flat: dict[str, Any] = {"smc_read.keys_requested": ",".join(keys)}
    sensors: list[dict[str, Any]] = []

    probe = find_smc_probe()
    if probe:
        try:
            proc = subprocess.run([probe], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
            stdout = proc.stdout.decode("utf-8", errors="replace")
            stderr = proc.stderr.decode("utf-8", errors="replace").strip()
            flat["smc_read.command"] = probe
            if stderr:
                flat["smc_read.stderr"] = stderr[:1200]
            try:
                data = json.loads(stdout)
            except json.JSONDecodeError:
                data = {}
                flat["smc_read.error"] = f"probe returned non-JSON output: {stdout[:1200]}"
            if isinstance(data, dict):
                flat["smc_read.ok"] = bool(data.get("ok"))
                flat["smc_read.service"] = data.get("service")
                flat["smc_read.method"] = data.get("method")
                if data.get("error"):
                    flat["smc_read.error"] = data.get("error")
                fan_count = numeric(data.get("fan_count"))
                append_sensor(sensors, "smc.fan_count", "Fan Count", "Fan", fan_count, "", "StellarScopeSMCProbe", raw_key="FNum", is_experimental=True)

                fields = data.get("fields") if isinstance(data.get("fields"), dict) else {}
                for key, value in fields.items():
                    if not isinstance(value, dict):
                        continue
                    for prop in ("type", "size", "attributes", "raw_hex", "error"):
                        if prop in value:
                            flat[f"smc_read.{key}.{prop}"] = value[prop]
                    if "value" in value:
                        flat[f"smc_read.{key}.value"] = value["value"]

                fans = data.get("fans") if isinstance(data.get("fans"), list) else []
                for fan in fans:
                    if not isinstance(fan, dict):
                        continue
                    index = int(numeric(fan.get("index")) or 0)
                    source = "StellarScopeSMCProbe"
                    label = fan.get("label")
                    if label:
                        append_sensor(sensors, f"smc.fan{index}.label", f"Fan {index} Label", "Fan", str(label), "", source, raw_key=f"F{index}ID", is_experimental=True)
                    append_sensor(sensors, f"smc.fan{index}.rpm", f"Fan {index} RPM", "Fan", numeric(fan.get("rpm")), "rpm", source, raw_key=f"F{index}Ac", is_experimental=True)
                    append_sensor(sensors, f"smc.fan{index}.min_rpm", f"Fan {index} Min", "Fan", numeric(fan.get("min_rpm")), "rpm", source, raw_key=f"F{index}Mn", is_experimental=True)
                    append_sensor(sensors, f"smc.fan{index}.max_rpm", f"Fan {index} Max", "Fan", numeric(fan.get("max_rpm")), "rpm", source, raw_key=f"F{index}Mx", is_experimental=True)
                rpm = numeric(next((s.get("value") for s in sensors if str(s.get("id", "")).endswith(".rpm")), None))
                if sensors:
                    return {"summary": {"fan_rpm": rpm} if rpm is not None else {}, "flat": flat, "sensors": sensors}
        except Exception as exc:  # noqa: BLE001
            flat["smc_read.probe_error"] = f"{type(exc).__name__}: {exc}"

    # Fall back to installed read-only SMC CLIs if the user already has one. Do
    # not issue writes or unlock/test-mode keys from StellarScope.
    for exe in (shutil.which("iSMC"), shutil.which("ismc"), shutil.which("smc"), shutil.which("smckit")):
        if not exe:
            continue
        for key in keys:
            try:
                proc = subprocess.run([exe, "-k", key], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2)
                out = proc.stdout.decode("utf-8", errors="replace").strip()
                err = proc.stderr.decode("utf-8", errors="replace").strip()
                flat[f"smc_read.{key}.command"] = f"{exe} -k {key}"
                if proc.returncode != 0:
                    flat[f"smc_read.{key}.error"] = err or out or f"exit {proc.returncode}"
                    continue
                flat[f"smc_read.{key}.output"] = out
                value = numeric(out)
                if key.endswith("Ac"):
                    fan_index = key[1]
                    append_sensor(sensors, f"smc.fan{fan_index}.rpm", f"Fan {fan_index} RPM", "Fan", value, "rpm", Path(exe).name, raw_key=key, is_experimental=True)
                elif key.endswith("Mn"):
                    fan_index = key[1]
                    append_sensor(sensors, f"smc.fan{fan_index}.min_rpm", f"Fan {fan_index} Min", "Fan", value, "rpm", Path(exe).name, raw_key=key, is_experimental=True)
                elif key.endswith("Mx"):
                    fan_index = key[1]
                    append_sensor(sensors, f"smc.fan{fan_index}.max_rpm", f"Fan {fan_index} Max", "Fan", value, "rpm", Path(exe).name, raw_key=key, is_experimental=True)
                elif key == "FNum":
                    append_sensor(sensors, "smc.fan_count", "Fan Count", "Fan", value, "", Path(exe).name, raw_key=key, is_experimental=True)
                elif key.endswith("ID") and out:
                    fan_index = key[1]
                    append_sensor(sensors, f"smc.fan{fan_index}.label", f"Fan {fan_index} Label", "Fan", out.splitlines()[-1], "", Path(exe).name, raw_key=key, is_experimental=True)
            except Exception as exc:  # noqa: BLE001
                flat[f"smc_read.{key}.error"] = f"{type(exc).__name__}: {exc}"
        if sensors:
            return {"summary": {"fan_rpm": numeric(next((s.get("value") for s in sensors if str(s.get("id", "")).endswith(".rpm")), None))}, "flat": flat, "sensors": sensors}

    # Last resort: record that AppleSMC exists but no callable read method was
    # available. This keeps the UI honest instead of pretending RPM is zero.
    cmd = ["/usr/sbin/ioreg", "-r", "-c", "AppleSMCKeysEndpoint", "-l"]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2)
        text = proc.stdout.decode("utf-8", errors="replace")
        flat["smc_read.command"] = " ".join(cmd)
        flat["smc_read.endpoint_present"] = "AppleSMCKeysEndpoint" in text
        flat["smc_read.error"] = "AppleSMC endpoint is present, but no bundled direct SMC reader is installed in this build."
    except Exception as exc:  # noqa: BLE001
        flat["smc_read.error"] = f"{type(exc).__name__}: {exc}"
    return {"summary": {}, "flat": flat, "sensors": sensors}


def collect_display_once() -> dict[str, Any]:
    try:
        data = system_profiler_json(["SPDisplaysDataType"], timeout=8)
        flat: dict[str, Any] = {"display.command": "system_profiler SPDisplaysDataType -json"}
        sensors: list[dict[str, Any]] = []
        gpus = data.get("SPDisplaysDataType") if isinstance(data.get("SPDisplaysDataType"), list) else []
        append_sensor(sensors, "display.gpu_count", "GPU Entries", "Display", len(gpus), "", "system_profiler", raw_key="SPDisplaysDataType")
        display_count = 0
        for gpu_index, gpu in enumerate(gpus):
            if not isinstance(gpu, dict):
                continue
            add_flat_scalars(flat, f"display.gpu{gpu_index}", gpu, limit=80)
            gpu_name = gpu.get("_name") or gpu.get("sppci_model") or f"GPU {gpu_index}"
            append_sensor(sensors, f"display.gpu{gpu_index}.name", f"GPU {gpu_index} Name", "Display", gpu_name, "", "system_profiler", raw_key=f"SPDisplaysDataType[{gpu_index}]._name")
            append_sensor(sensors, f"display.gpu{gpu_index}.cores", f"GPU {gpu_index} Cores", "Display", numeric(gpu.get("sppci_cores")), "", "system_profiler", raw_key="sppci_cores")
            append_sensor(sensors, f"display.gpu{gpu_index}.metal", f"GPU {gpu_index} Metal", "Display", gpu.get("spdisplays_mtlgpufamilysupport"), "", "system_profiler", raw_key="spdisplays_mtlgpufamilysupport")
            displays = gpu.get("spdisplays_ndrvs") if isinstance(gpu.get("spdisplays_ndrvs"), list) else []
            for display in displays:
                if not isinstance(display, dict):
                    continue
                display_count += 1
                idx = display_count - 1
                name = display.get("_name") or f"Display {idx}"
                width, height = parse_resolution(display.get("_spdisplays_pixels") or display.get("spdisplays_pixelresolution") or "")
                logical_w, logical_h = parse_resolution(display.get("_spdisplays_resolution") or "")
                refresh = parse_refresh_hz(display.get("_spdisplays_resolution") or "")
                prefix = f"display.{idx}"
                append_sensor(sensors, f"{prefix}.name", f"Display {idx} Name", "Display", name, "", "system_profiler", raw_key="_name")
                append_sensor(sensors, f"{prefix}.width_px", f"Display {idx} Width", "Display", width, "px", "system_profiler", raw_key="_spdisplays_pixels")
                append_sensor(sensors, f"{prefix}.height_px", f"Display {idx} Height", "Display", height, "px", "system_profiler", raw_key="_spdisplays_pixels")
                append_sensor(sensors, f"{prefix}.logical_width_px", f"Display {idx} Logical Width", "Display", logical_w, "px", "system_profiler", raw_key="_spdisplays_resolution")
                append_sensor(sensors, f"{prefix}.logical_height_px", f"Display {idx} Logical Height", "Display", logical_h, "px", "system_profiler", raw_key="_spdisplays_resolution")
                append_sensor(sensors, f"{prefix}.refresh_hz", f"Display {idx} Refresh", "Display", refresh, "Hz", "system_profiler", raw_key="_spdisplays_resolution")
                append_sensor(sensors, f"{prefix}.type", f"Display {idx} Type", "Display", display.get("spdisplays_display_type"), "", "system_profiler", raw_key="spdisplays_display_type")
                append_sensor(sensors, f"{prefix}.connection", f"Display {idx} Connection", "Display", display.get("spdisplays_connection_type"), "", "system_profiler", raw_key="spdisplays_connection_type")
                append_sensor(sensors, f"{prefix}.main", f"Display {idx} Main", "Display", display.get("spdisplays_main"), "", "system_profiler", raw_key="spdisplays_main")
                append_sensor(sensors, f"{prefix}.online", f"Display {idx} Online", "Display", display.get("spdisplays_online"), "", "system_profiler", raw_key="spdisplays_online")
        append_sensor(sensors, "display.count", "Display Count", "Display", display_count, "", "system_profiler", raw_key="spdisplays_ndrvs")
        fb = collect_framebuffer_refresh_once()
        flat.update(fb.get("flat", {}))
        merge_sensors(sensors, fb.get("sensors", []))
        return {"summary": {}, "flat": flat, "sensors": sensors}
    except Exception as exc:  # noqa: BLE001
        return {"summary": {}, "flat": {"display.error": f"{type(exc).__name__}: {exc}"}, "sensors": []}


def collect_framebuffer_refresh_once() -> dict[str, Any]:
    try:
        items = ioreg_plist("IOMobileFramebuffer", timeout=4)
        flat: dict[str, Any] = {"display_refresh.command": "ioreg -r -c IOMobileFramebuffer -a"}
        sensors: list[dict[str, Any]] = []
        for idx, item in enumerate(items[:4]):
            if not isinstance(item, dict):
                continue
            prefix = f"display.refresh{idx}"
            refresh = item.get("IOMFBDisplayRefresh") if isinstance(item.get("IOMFBDisplayRefresh"), dict) else {}
            width = numeric(item.get("DisplayWidth"))
            height = numeric(item.get("DisplayHeight"))
            min_hz = mach_interval_to_hz(refresh.get("displayMaxRefreshIntervalMachTime"))
            max_hz = mach_interval_to_hz(refresh.get("displayMinRefreshIntervalMachTime"))
            step_hz = mach_interval_to_hz(refresh.get("displayRefreshStepMachTime"))
            add_flat_scalars(flat, prefix, {
                "DisplayWidth": width,
                "DisplayHeight": height,
                "ALSSSupported": item.get("ALSSSupported"),
                "IOMFBDisplayRefresh": refresh,
                "PixelClock": item.get("PixelClock"),
            }, limit=40)
            append_sensor(sensors, f"{prefix}.width_px", f"Framebuffer {idx} Width", "Display", width, "px", "IORegistry", raw_key="DisplayWidth")
            append_sensor(sensors, f"{prefix}.height_px", f"Framebuffer {idx} Height", "Display", height, "px", "IORegistry", raw_key="DisplayHeight")
            append_sensor(sensors, f"{prefix}.vrr_min_hz", f"ProMotion {idx} Minimum", "Display", min_hz, "Hz", "IORegistry", raw_key="IOMFBDisplayRefresh.displayMaxRefreshIntervalMachTime")
            append_sensor(sensors, f"{prefix}.vrr_max_hz", f"ProMotion {idx} Maximum", "Display", max_hz, "Hz", "IORegistry", raw_key="IOMFBDisplayRefresh.displayMinRefreshIntervalMachTime")
            append_sensor(sensors, f"{prefix}.vrr_step_hz", f"ProMotion {idx} Step", "Display", step_hz, "Hz", "IORegistry", raw_key="IOMFBDisplayRefresh.displayRefreshStepMachTime", is_experimental=True)
            append_sensor(sensors, f"{prefix}.alss_supported", f"Display {idx} ALS Support", "Environment", item.get("ALSSSupported"), "", "IORegistry", raw_key="ALSSSupported")
        return {"summary": {}, "flat": flat, "sensors": sensors}
    except Exception as exc:  # noqa: BLE001
        return {"summary": {}, "flat": {"display_refresh.error": f"{type(exc).__name__}: {exc}"}, "sensors": []}


def collect_storage_once() -> dict[str, Any]:
    try:
        data = system_profiler_json(["SPStorageDataType", "SPNVMeDataType"], timeout=8)
        flat: dict[str, Any] = {"storage.command": "system_profiler SPStorageDataType SPNVMeDataType -json"}
        sensors: list[dict[str, Any]] = []
        volumes = data.get("SPStorageDataType") if isinstance(data.get("SPStorageDataType"), list) else []
        append_sensor(sensors, "storage.volume_count", "Volume Count", "Storage", len(volumes), "", "system_profiler", raw_key="SPStorageDataType")
        for idx, vol in enumerate(volumes[:12]):
            if not isinstance(vol, dict):
                continue
            add_flat_scalars(flat, f"storage.volume{idx}", vol, limit=70)
            name = vol.get("_name") or vol.get("mount_point") or f"Volume {idx}"
            size = numeric(vol.get("size_in_bytes"))
            free = numeric(vol.get("free_space_in_bytes"))
            used_percent = ((size - free) / size * 100.0) if size and free is not None and size > 0 else None
            prefix = f"storage.volume{idx}"
            append_sensor(sensors, f"{prefix}.name", f"Volume {idx} Name", "Storage", name, "", "system_profiler", raw_key="_name")
            append_sensor(sensors, f"{prefix}.size_bytes", f"{name} Size", "Storage", size, "B", "system_profiler", raw_key="size_in_bytes")
            append_sensor(sensors, f"{prefix}.free_bytes", f"{name} Free", "Storage", free, "B", "system_profiler", raw_key="free_space_in_bytes")
            append_sensor(sensors, f"{prefix}.used_percent", f"{name} Used", "Storage", used_percent, "%", "system_profiler", raw_key="free_space_in_bytes")
            append_sensor(sensors, f"{prefix}.filesystem", f"{name} File System", "Storage", vol.get("file_system"), "", "system_profiler", raw_key="file_system")
            append_sensor(sensors, f"{prefix}.mount", f"{name} Mount", "Storage", vol.get("mount_point"), "", "system_profiler", raw_key="mount_point")
            drive = vol.get("physical_drive") if isinstance(vol.get("physical_drive"), dict) else {}
            append_sensor(sensors, f"{prefix}.drive", f"{name} Drive", "Storage", drive.get("device_name"), "", "system_profiler", raw_key="physical_drive.device_name")
            append_sensor(sensors, f"{prefix}.protocol", f"{name} Protocol", "Storage", drive.get("protocol"), "", "system_profiler", raw_key="physical_drive.protocol")
            append_sensor(sensors, f"{prefix}.smart", f"{name} SMART", "Storage", drive.get("smart_status"), "", "system_profiler", raw_key="physical_drive.smart_status")

        nvme_sections = data.get("SPNVMeDataType") if isinstance(data.get("SPNVMeDataType"), list) else []
        device_index = 0
        for section in nvme_sections:
            items = section.get("_items") if isinstance(section, dict) and isinstance(section.get("_items"), list) else []
            for item in items:
                if not isinstance(item, dict):
                    continue
                prefix = f"storage.nvme{device_index}"
                append_sensor(sensors, f"{prefix}.model", f"NVMe {device_index} Model", "Storage", item.get("device_model") or item.get("_name"), "", "system_profiler", raw_key="device_model")
                append_sensor(sensors, f"{prefix}.size_bytes", f"NVMe {device_index} Size", "Storage", numeric(item.get("size_in_bytes")), "B", "system_profiler", raw_key="size_in_bytes")
                append_sensor(sensors, f"{prefix}.smart", f"NVMe {device_index} SMART", "Storage", item.get("smart_status"), "", "system_profiler", raw_key="smart_status")
                append_sensor(sensors, f"{prefix}.trim", f"NVMe {device_index} TRIM", "Storage", item.get("spnvme_trim_support"), "", "system_profiler", raw_key="spnvme_trim_support")
                device_index += 1
        append_sensor(sensors, "storage.nvme_count", "NVMe Device Count", "Storage", device_index, "", "system_profiler", raw_key="SPNVMeDataType")
        return {"summary": {}, "flat": flat, "sensors": sensors}
    except Exception as exc:  # noqa: BLE001
        return {"summary": {}, "flat": {"storage.error": f"{type(exc).__name__}: {exc}"}, "sensors": []}


def collect_audio_once() -> dict[str, Any]:
    try:
        data = system_profiler_json(["SPAudioDataType"], timeout=8)
        flat: dict[str, Any] = {"audio.command": "system_profiler SPAudioDataType -json"}
        sensors: list[dict[str, Any]] = []
        sections = data.get("SPAudioDataType") if isinstance(data.get("SPAudioDataType"), list) else []
        devices: list[dict[str, Any]] = []
        for section in sections:
            if isinstance(section, dict) and isinstance(section.get("_items"), list):
                devices.extend([x for x in section["_items"] if isinstance(x, dict)])
        append_sensor(sensors, "audio.device_count", "Audio Device Count", "Audio", len(devices), "", "system_profiler", raw_key="SPAudioDataType._items")
        default_input = next((d.get("_name") for d in devices if d.get("coreaudio_default_audio_input_device")), None)
        default_output = next((d.get("_name") for d in devices if d.get("coreaudio_default_audio_output_device")), None)
        append_sensor(sensors, "audio.default_input", "Default Input", "Audio", default_input, "", "system_profiler", raw_key="coreaudio_default_audio_input_device")
        append_sensor(sensors, "audio.default_output", "Default Output", "Audio", default_output, "", "system_profiler", raw_key="coreaudio_default_audio_output_device")
        for idx, dev in enumerate(devices[:16]):
            add_flat_scalars(flat, f"audio.device{idx}", dev, limit=30)
            name = dev.get("_name") or f"Audio {idx}"
            prefix = f"audio.device{idx}"
            append_sensor(sensors, f"{prefix}.name", f"Audio {idx} Name", "Audio", name, "", "system_profiler", raw_key="_name")
            append_sensor(sensors, f"{prefix}.sample_rate_hz", f"{name} Sample Rate", "Audio", numeric(dev.get("coreaudio_device_srate")), "Hz", "system_profiler", raw_key="coreaudio_device_srate")
            append_sensor(sensors, f"{prefix}.inputs", f"{name} Inputs", "Audio", numeric(dev.get("coreaudio_device_input")), "ch", "system_profiler", raw_key="coreaudio_device_input")
            append_sensor(sensors, f"{prefix}.outputs", f"{name} Outputs", "Audio", numeric(dev.get("coreaudio_device_output")), "ch", "system_profiler", raw_key="coreaudio_device_output")
            append_sensor(sensors, f"{prefix}.transport", f"{name} Transport", "Audio", dev.get("coreaudio_device_transport"), "", "system_profiler", raw_key="coreaudio_device_transport")
            append_sensor(sensors, f"{prefix}.manufacturer", f"{name} Manufacturer", "Audio", dev.get("coreaudio_device_manufacturer"), "", "system_profiler", raw_key="coreaudio_device_manufacturer")
        return {"summary": {}, "flat": flat, "sensors": sensors}
    except Exception as exc:  # noqa: BLE001
        return {"summary": {}, "flat": {"audio.error": f"{type(exc).__name__}: {exc}"}, "sensors": []}


def collect_bus_once() -> dict[str, Any]:
    try:
        data = system_profiler_json(["SPUSBDataType", "SPThunderboltDataType", "SPPCIDataType", "SPNetworkDataType"], timeout=10)
        flat: dict[str, Any] = {"bus.command": "system_profiler SPUSBDataType SPThunderboltDataType SPPCIDataType SPNetworkDataType -json"}
        sensors: list[dict[str, Any]] = []
        usb = data.get("SPUSBDataType") if isinstance(data.get("SPUSBDataType"), list) else []
        thunderbolt = data.get("SPThunderboltDataType") if isinstance(data.get("SPThunderboltDataType"), list) else []
        pci = data.get("SPPCIDataType") if isinstance(data.get("SPPCIDataType"), list) else []
        network = data.get("SPNetworkDataType") if isinstance(data.get("SPNetworkDataType"), list) else []
        append_sensor(sensors, "bus.usb_root_count", "USB Root Count", "Bus", len(usb), "", "system_profiler", raw_key="SPUSBDataType")
        append_sensor(sensors, "bus.thunderbolt_bus_count", "Thunderbolt / USB4 Buses", "Bus", len(thunderbolt), "", "system_profiler", raw_key="SPThunderboltDataType")
        append_sensor(sensors, "bus.pci_device_count", "PCI Device Count", "Bus", len(pci), "", "system_profiler", raw_key="SPPCIDataType")
        append_sensor(sensors, "bus.network_service_count", "Network Services", "Bus", len(network), "", "system_profiler", raw_key="SPNetworkDataType")
        for idx, item in enumerate(thunderbolt[:12]):
            if not isinstance(item, dict):
                continue
            add_flat_scalars(flat, f"bus.thunderbolt{idx}", item, limit=50)
            name = item.get("_name") or item.get("device_name_key") or f"Thunderbolt {idx}"
            append_sensor(sensors, f"bus.thunderbolt{idx}.name", f"Thunderbolt {idx} Name", "Bus", name, "", "system_profiler", raw_key="_name")
            for key, value in item.items():
                if isinstance(value, dict) and "current_speed_key" in value:
                    port = safe_id(key)
                    append_sensor(sensors, f"bus.thunderbolt{idx}.{port}.speed", f"{name} {key} Speed", "Bus", value.get("current_speed_key"), "", "system_profiler", raw_key=f"{key}.current_speed_key")
                    append_sensor(sensors, f"bus.thunderbolt{idx}.{port}.status", f"{name} {key} Status", "Bus", value.get("receptacle_status_key"), "", "system_profiler", raw_key=f"{key}.receptacle_status_key")
        for idx, item in enumerate(network[:18]):
            if not isinstance(item, dict):
                continue
            prefix = f"bus.network{idx}"
            name = item.get("_name") or item.get("interface") or f"Network {idx}"
            append_sensor(sensors, f"{prefix}.name", f"Network {idx} Name", "Bus", name, "", "system_profiler", raw_key="_name")
            append_sensor(sensors, f"{prefix}.interface", f"{name} Interface", "Bus", item.get("interface"), "", "system_profiler", raw_key="interface")
            append_sensor(sensors, f"{prefix}.type", f"{name} Type", "Bus", item.get("type") or item.get("hardware"), "", "system_profiler", raw_key="type")
            addresses = item.get("ip_address") if isinstance(item.get("ip_address"), list) else []
            append_sensor(sensors, f"{prefix}.ip_count", f"{name} IP Count", "Bus", len(addresses), "", "system_profiler", raw_key="ip_address")
        for idx, item in enumerate(pci[:12]):
            if not isinstance(item, dict):
                continue
            append_sensor(sensors, f"bus.pci{idx}.name", f"PCI {idx} Name", "Bus", item.get("_name"), "", "system_profiler", raw_key="_name")
        return {"summary": {}, "flat": flat, "sensors": sensors}
    except Exception as exc:  # noqa: BLE001
        return {"summary": {}, "flat": {"bus.error": f"{type(exc).__name__}: {exc}"}, "sensors": []}


def usage_name(device: dict[str, Any]) -> str:
    pairs = device.get("DeviceUsagePairs") if isinstance(device.get("DeviceUsagePairs"), list) else []
    first = pairs[0] if pairs and isinstance(pairs[0], dict) else {}
    page = first.get("DeviceUsagePage")
    usage = first.get("DeviceUsage")
    if page == 65280 and usage == 3:
        return "Accelerometer"
    if page == 65280 and usage == 9:
        return "Gyroscope"
    if page == 65280 and usage == 4:
        return "Ambient Light"
    if page == 32 and usage == 138:
        return "Hall / Lid Angle"
    if page == 65280 and usage == 5:
        return "Temperature"
    return f"Usage {page}:{usage}"


def first_spu_device(devices: list[Any], name: str) -> dict[str, Any] | None:
    for item in devices:
        if isinstance(item, dict) and usage_name(item) == name:
            return item
    return None


def collect_environment_motion_once() -> dict[str, Any]:
    flat: dict[str, Any] = {"environment.command": "ioreg SPU/ALS/IOPMrootDomain"}
    sensors: list[dict[str, Any]] = []
    try:
        spu_devices = ioreg_plist("AppleSPUHIDDriver", timeout=4)
        als_devices = ioreg_plist("AppleALSColorSensor", timeout=4)
        root_domain = ioreg_plist("IOPMrootDomain", timeout=3)
        append_sensor(sensors, "motion.spu_device_count", "SPU HID Device Count", "Motion", len(spu_devices), "", "IORegistry", raw_key="AppleSPUHIDDriver")

        for friendly, prefix in (
            ("Accelerometer", "motion.accelerometer"),
            ("Gyroscope", "motion.gyroscope"),
            ("Hall / Lid Angle", "motion.hall"),
            ("Temperature", "motion.spu_temperature"),
        ):
            dev = first_spu_device(spu_devices, friendly)
            if not dev:
                append_sensor(sensors, f"{prefix}.available", f"{friendly} Available", "Motion", False, "", "IORegistry", raw_key="DeviceUsagePairs")
                continue
            debug = dev.get("DebugState") if isinstance(dev.get("DebugState"), dict) else {}
            voltage = dev.get("AppleVoltageDictionary") if isinstance(dev.get("AppleVoltageDictionary"), dict) else {}
            add_flat_scalars(flat, prefix, {
                "usage": friendly,
                "model": dev.get("model"),
                "manufacturer": dev.get("manufacturer") or dev.get("Manufacturer"),
                "sensor_rates": dev.get("sensor_rates"),
                "calibration_state": dev.get("calibration_state"),
                "motionRestrictedService": dev.get("motionRestrictedService"),
                "HIDRMDeviceState": dev.get("HIDRMDeviceState"),
                "ReportInterval": dev.get("ReportInterval"),
                "DebugState": debug,
                "AppleVoltageDictionary": voltage,
            }, limit=60)
            append_sensor(sensors, f"{prefix}.available", f"{friendly} Available", "Motion", True, "", "IORegistry", raw_key="DeviceUsagePairs")
            append_sensor(sensors, f"{prefix}.model", f"{friendly} Model", "Motion", dev.get("model"), "", "IORegistry", raw_key="model")
            append_sensor(sensors, f"{prefix}.manufacturer", f"{friendly} Manufacturer", "Motion", dev.get("manufacturer") or dev.get("Manufacturer"), "", "IORegistry", raw_key="manufacturer")
            append_sensor(sensors, f"{prefix}.rates", f"{friendly} Rates", "Motion", dev.get("sensor_rates"), "", "IORegistry", raw_key="sensor_rates")
            append_sensor(sensors, f"{prefix}.calibration", f"{friendly} Calibration", "Motion", numeric(dev.get("calibration_state")), "", "IORegistry", raw_key="calibration_state")
            append_sensor(sensors, f"{prefix}.restricted", f"{friendly} Restricted", "Motion", dev.get("motionRestrictedService"), "", "IORegistry", raw_key="motionRestrictedService")
            append_sensor(sensors, f"{prefix}.events", f"{friendly} Events", "Motion", numeric(debug.get("_num_events")), "", "IORegistry", raw_key="DebugState._num_events")
            append_sensor(sensors, f"{prefix}.report_interval_us", f"{friendly} Report Interval", "Motion", numeric(dev.get("ReportInterval")), "us", "IORegistry", raw_key="ReportInterval")
            for temp_key, temp_value in voltage.items():
                append_sensor(sensors, f"{prefix}.{safe_id(temp_key)}", f"{friendly} {temp_key}", "Motion", numeric(temp_value), "", "IORegistry", raw_key=f"AppleVoltageDictionary.{temp_key}", is_experimental=True)

        als = first_spu_device(spu_devices, "Ambient Light")
        if als is None:
            als = als_devices[0] if als_devices and isinstance(als_devices[0], dict) else None
        if als:
            debug = als.get("DebugState") if isinstance(als.get("DebugState"), dict) else {}
            add_flat_scalars(flat, "environment.als", als, limit=70)
            append_sensor(sensors, "environment.ambient_lux", "Ambient Light", "Environment", numeric(als.get("CurrentLux")), "lx", "AppleALSColorSensor", raw_key="CurrentLux")
            append_sensor(sensors, "environment.als_sensor_type", "ALS Sensor Type", "Environment", numeric(als.get("ALSSensorType")), "", "AppleALSColorSensor", raw_key="ALSSensorType")
            append_sensor(sensors, "environment.als_report_interval_us", "ALS Report Interval", "Environment", numeric(als.get("ReportInterval")), "us", "AppleALSColorSensor", raw_key="ReportInterval")
            append_sensor(sensors, "environment.als_calibration", "ALS Calibration", "Environment", numeric(als.get("CalibrationResult") or als.get("calibration_state")), "", "AppleALSColorSensor", raw_key="CalibrationResult")
            append_sensor(sensors, "environment.als_events", "ALS Events", "Environment", numeric(debug.get("_num_events")), "", "AppleALSColorSensor", raw_key="DebugState._num_events")
            append_sensor(sensors, "environment.als_transport", "ALS Transport", "Environment", als.get("Transport"), "", "AppleALSColorSensor", raw_key="Transport")
        else:
            append_sensor(sensors, "environment.als_available", "Ambient Light Available", "Environment", False, "", "IORegistry", raw_key="AppleALSColorSensor")

        root = root_domain[0] if root_domain and isinstance(root_domain[0], dict) else {}
        add_flat_scalars(flat, "environment.power", root, limit=50)
        append_sensor(sensors, "environment.clamshell_closed", "Clamshell Closed", "Environment", root.get("AppleClamshellState"), "", "IOPMrootDomain", raw_key="AppleClamshellState")
        append_sensor(sensors, "environment.clamshell_causes_sleep", "Clamshell Causes Sleep", "Environment", root.get("AppleClamshellCausesSleep"), "", "IOPMrootDomain", raw_key="AppleClamshellCausesSleep")
        append_sensor(sensors, "environment.wake_reason", "Wake Reason", "Environment", root.get("Wake Reason"), "", "IOPMrootDomain", raw_key="Wake Reason")
        return {"summary": {}, "flat": flat, "sensors": sensors}
    except Exception as exc:  # noqa: BLE001
        return {"summary": {}, "flat": {"environment.error": f"{type(exc).__name__}: {exc}", **flat}, "sensors": sensors}


def collect_macmon_debug_once() -> dict[str, Any]:
    macmon = find_macmon()
    if not macmon:
        return {"summary": {}, "flat": {"macmon_debug.status": "macmon not found"}, "sensors": []}
    cmd = [macmon, "debug"]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4)
        text = proc.stdout.decode("utf-8", errors="replace")
        flat: dict[str, Any] = {"macmon_debug.command": " ".join(cmd)}
        sensors: list[dict[str, Any]] = []
        energy_count = 0
        voltage_count = 0
        for line in text.splitlines():
            clean = line.strip()
            if not clean:
                continue
            energy = re.search(r"Energy Model .*?::\s+([^=]+?)\s+\(mJ\)\s+=\s+([-+]?\d+(?:\.\d+)?)W", clean)
            if energy and energy_count < 40:
                name = re.sub(r"\s+", " ", energy.group(1).strip())
                value = watts_to_mw(energy.group(2))
                key = "macmon_debug.energy." + re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
                flat[key] = f"{energy.group(2)} W"
                append_sensor(sensors, key, name, "Power", value, "mW", "macmon debug", raw_key=key, is_experimental=True)
                energy_count += 1
                continue
            voltage = re.search(r"voltage-states(\d+(?:-sram)?):\s+\(([vf])\)\s+(.+)", clean)
            if voltage and voltage_count < 36:
                state = voltage.group(1)
                kind = voltage.group(2)
                numbers = [numeric(x) for x in voltage.group(3).split()]
                values = [x for x in numbers if x is not None and x > 1]
                if not values:
                    continue
                unit = "mV" if kind == "v" else "Hz"
                multiplier = 1 if kind == "v" else 1
                max_value = max(values) * multiplier
                title = f"Voltage State {state} Max {'Voltage' if kind == 'v' else 'Frequency'}"
                key = f"macmon_debug.voltage_states.{state}.{kind}.max"
                flat[key] = max_value
                append_sensor(sensors, key, title, "Raw", max_value, unit, "macmon debug", raw_key=key, is_experimental=True)
                voltage_count += 1
        if not sensors:
            flat["macmon_debug.status"] = "no parsable debug sensors"
        return {"summary": {}, "flat": flat, "sensors": sensors}
    except Exception as exc:  # noqa: BLE001
        return {"summary": {}, "flat": {"macmon_debug.error": f"{type(exc).__name__}: {exc}", "macmon_debug.command": " ".join(cmd)}, "sensors": []}


def merge_auxiliary(payload: dict[str, Any], loop_index: int) -> dict[str, Any]:
    apply_runtime_control()
    payload.setdefault("summary", {})
    payload.setdefault("flat", {})
    payload.setdefault("sensors", [])
    payload["flat"]["agent.interval_ms"] = INTERVAL_MS
    payload["flat"]["agent.sample_ms"] = SAMPLE_MS
    payload["flat"]["agent.loop_index"] = loop_index
    payload["flat"]["agent.profile"] = PROFILE
    payload["flat"]["agent.control_path"] = str(CONTROL_PATH)
    payload["flat"]["agent.schema_version"] = AGENT_SCHEMA_VERSION
    payload["flat"]["agent.features"] = AGENT_FEATURES

    # Thermal pressure is cheap and useful; refresh each loop.
    thermal = collect_thermal_pressure_once()
    merge_summary(payload["summary"], thermal.get("summary", {}), prefer_new=True)
    payload["flat"].update(thermal.get("flat", {}))
    merge_sensors(payload["sensors"], thermal.get("sensors", []))

    battery = collect_battery_once()
    payload["flat"].update(battery.get("flat", {}))
    merge_sensors(payload["sensors"], battery.get("sensors", []))

    smc_fan = collect_smc_fan_readonly_once()
    merge_summary(payload["summary"], smc_fan.get("summary", {}), prefer_new=True)
    payload["flat"].update(smc_fan.get("flat", {}))
    merge_sensors(payload["sensors"], smc_fan.get("sensors", []))

    # SMC via powermetrics is noisy/unavailable on many Apple Silicon builds.
    smc = cached_collect("smc_powermetrics", loop_index, cadence("smc"), collect_smc_once)
    merge_summary(payload["summary"], smc.get("summary", {}), prefer_new=True)
    payload["flat"].update(smc.get("flat", {}))
    merge_sensors(payload["sensors"], smc.get("sensors", []))

    debug = cached_collect("macmon_debug", loop_index, cadence("debug"), collect_macmon_debug_once)
    payload["flat"].update(debug.get("flat", {}))
    merge_sensors(payload["sensors"], debug.get("sensors", []))

    for name, collector in (
        ("display", collect_display_once),
        ("storage", collect_storage_once),
        ("audio", collect_audio_once),
        ("bus", collect_bus_once),
        ("environment", collect_environment_motion_once),
    ):
        block = cached_collect(name, loop_index, cadence("system"), collector)
        payload["flat"].update(block.get("flat", {}))
        merge_sensors(payload["sensors"], block.get("sensors", []))

    merge_sensors(payload["sensors"], sensors_from_summary(payload["summary"], str(payload.get("source", "summary")), prefix="summary"))
    return payload


def main() -> int:
    atomic_write_json(OUT, {
        "timestamp": now_iso(),
        "status": "starting",
        "source": "powermetrics+optional-macmon",
        "pid": os.getpid(),
        "summary": {},
        "sensors": [],
        "flat": {
            "agent.message": "helper process started",
            "agent.interval_ms": INTERVAL_MS,
            "agent.schema_version": AGENT_SCHEMA_VERSION,
            "agent.features": AGENT_FEATURES,
        },
    })

    if os.geteuid() != 0:
        atomic_write_json(OUT, {
            "timestamp": now_iso(),
            "status": "error",
            "source": "powermetrics",
            "pid": os.getpid(),
            "summary": {},
            "sensors": [],
            "flat": {},
            "error": "This helper must run with administrator privileges.",
        })
        print("This helper must run with sudo/admin privileges.", file=sys.stderr)
        return 1

    Path("/tmp/stellarscope-powermetrics.pid").write_text(str(os.getpid()), encoding="utf-8")
    os.chmod("/tmp/stellarscope-powermetrics.pid", 0o644)
    print(f"StellarScope v8 agent pid={os.getpid()} interval={INTERVAL_MS}ms writing {OUT}", flush=True)

    loop_index = 0
    while True:
        start = time.monotonic()
        apply_runtime_control()
        payload = collect_power_once()
        payload = merge_auxiliary(payload, loop_index)
        payload["timestamp"] = now_iso()
        payload["status"] = "running" if payload.get("summary") else payload.get("status", "running")
        atomic_write_json(OUT, payload)

        s = payload.get("summary", {})
        print(
            f"{payload['timestamp']} CPU={s.get('cpu_power_mw')} GPU={s.get('gpu_power_mw')} "
            f"GPUfreq={s.get('gpu_frequency_hz')} CPUtemp={s.get('cpu_die_temperature_c')} "
            f"GPUtemp={s.get('gpu_die_temperature_c')} fan={s.get('fan_rpm')} pressure={s.get('thermal_pressure')}",
            flush=True,
        )
        loop_index += 1

        elapsed = time.monotonic() - start
        target = INTERVAL_MS / 1000.0
        # If the OS commands finish faster than requested, maintain the cadence.
        if elapsed < target:
            time.sleep(target - elapsed)


if __name__ == "__main__":
    raise SystemExit(main())
