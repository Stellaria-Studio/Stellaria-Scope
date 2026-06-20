import importlib.util
import json
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / "Sources" / "StellarScope" / "Resources" / "stellarscope_powermetrics_agent.py"


def load_agent():
    spec = importlib.util.spec_from_file_location("agent", AGENT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_powermetrics_pressure_and_cluster_parse():
    agent = load_agent()
    summary, _ = agent.parse_powermetrics_text(
        "\n".join(
            [
                "**** Thermal pressure ****",
                "Current pressure level: Nominal",
                "P0-Cluster HW active frequency: 3.20 GHz",
                "E0-Cluster HW active frequency: 1.40 GHz",
                "GPU active residency: 20.2%",
            ]
        )
    )
    assert summary["thermal_pressure"] == "Nominal"
    assert summary["p_cluster_frequency_hz"] == 3_200_000_000
    assert summary["e_cluster_frequency_hz"] == 1_400_000_000
    assert summary["gpu_residency_percent"] == 20.2


def test_battery_temperature_conversion():
    agent = load_agent()
    assert round(agent.apple_battery_temp_c(3071), 1) == 34.0


def test_sensor_shape_from_summary():
    agent = load_agent()
    sensors = agent.sensors_from_summary(
        {"cpu_power_mw": 1234, "thermal_pressure": "Nominal"},
        "fixture",
        prefix="fixture",
    )
    assert sensors[0]["id"] == "fixture.cpu_power_mw"
    assert sensors[0]["category"] == "Power"
    assert sensors[1]["value"] == "Nominal"


def test_smc_probe_reports_status_without_writing():
    agent = load_agent()
    probe = agent.collect_smc_fan_readonly_once()
    assert "smc_read.keys_requested" in probe["flat"]
    assert "F0Ac" in probe["flat"]["smc_read.keys_requested"]
    assert isinstance(probe["sensors"], list)


def test_system_profiler_helpers_parse_display_mode():
    agent = load_agent()
    assert agent.parse_resolution("3024 x 1964") == (3024.0, 1964.0)
    assert agent.parse_resolution("1512 x 982 @ 120.00Hz") == (1512.0, 982.0)
    assert agent.parse_refresh_hz("1512 x 982 @ 120.00Hz") == 120.0


def test_motion_usage_names():
    agent = load_agent()
    assert agent.usage_name({"DeviceUsagePairs": [{"DeviceUsagePage": 65280, "DeviceUsage": 3}]}) == "Accelerometer"
    assert agent.usage_name({"DeviceUsagePairs": [{"DeviceUsagePage": 65280, "DeviceUsage": 9}]}) == "Gyroscope"
    assert agent.usage_name({"DeviceUsagePairs": [{"DeviceUsagePage": 32, "DeviceUsage": 138}]}) == "Hall / Lid Angle"


def test_zero_cadence_caches_once():
    agent = load_agent()
    agent.SLOW_CACHE.clear()
    calls = {"count": 0}

    def collector():
        calls["count"] += 1
        return {"summary": {}, "flat": {"value": calls["count"]}, "sensors": []}

    first = agent.cached_collect("fixture_once", 0, 0, collector)
    second = agent.cached_collect("fixture_once", 99, 0, collector)
    assert first["flat"]["value"] == 1
    assert second["flat"]["value"] == 1
    assert calls["count"] == 1


def test_upsert_sensors_replaces_existing_rows():
    agent = load_agent()
    rows = [
        {"id": "motion.lid_angle_degrees", "value": 90},
        {"id": "environment.spu_ambient_lux", "value": 100},
    ]
    agent.upsert_sensors(rows, [
        {"id": "motion.lid_angle_degrees", "value": 110},
        {"id": "environment.als_chroma_0", "value": 20},
    ])

    assert rows[0]["value"] == 110
    assert rows[1]["value"] == 100
    assert rows[2]["id"] == "environment.als_chroma_0"


def test_spu_lid_and_als_report_parsers():
    import struct

    agent = load_agent()
    assert agent.parse_spu_lid_report(bytes([1, 123, 0])) == 123.0
    assert agent.parse_spu_lid_report(bytes([0, 123, 0])) is None

    raw = bytearray(agent.SPU_ALS_REPORT_LEN)
    for idx, offset in enumerate(agent.SPU_ALS_CH_OFFSETS):
        struct.pack_into("<I", raw, offset, (idx + 1) * 100)
    struct.pack_into("<f", raw, agent.SPU_ALS_LUX_OFF, 0.75)

    parsed = agent.parse_spu_als_report(bytes(raw))
    assert round(parsed["lux"], 2) == 0.75
    assert parsed["channels"] == [100, 200, 300, 400]
    assert parsed["dominant"] == 3

    accel = bytearray(agent.SPU_IMU_REPORT_LEN)
    struct.pack_into("<i", accel, agent.SPU_IMU_DATA_OFF, 65536)
    struct.pack_into("<i", accel, agent.SPU_IMU_DATA_OFF + 4, -32768)
    struct.pack_into("<i", accel, agent.SPU_IMU_DATA_OFF + 8, 0)
    assert agent.parse_spu_accel_report(bytes(accel)) == (1.0, -0.5, 0.0)


def test_bcg_estimator_on_synthetic_signal():
    import math

    agent = load_agent()
    fs = 100.0
    bpm = 72.0
    freq = bpm / 60.0
    samples = []
    for idx in range(int(fs * 8)):
        t = idx / fs
        wobble = 0.02 * math.sin(2 * math.pi * freq * t)
        samples.append((t, 0.0, 0.0, 1.0 + wobble))

    result = agent.estimate_bcg_heart_rate(samples)
    assert result["status"] == "ok"
    assert abs(result["bpm"] - bpm) < 3.0


def test_bool_control_parser():
    agent = load_agent()
    assert agent.bool_control(True) is True
    assert agent.bool_control("true") is True
    assert agent.bool_control("false") is False
    assert agent.bool_control(0) is False
    assert agent.bool_control("unknown", default=True) is True


def test_bcg_control_invalidates_environment_cache():
    agent = load_agent()
    old_control_path = agent.CONTROL_PATH
    old_bcg_enabled = agent.BCG_HEART_RATE_ENABLED
    old_helper_enabled = agent.HELPER_ENABLED
    old_cache = dict(agent.SLOW_CACHE)

    try:
        with tempfile.TemporaryDirectory() as directory:
            agent.CONTROL_PATH = Path(directory) / "control.json"
            agent.HELPER_ENABLED = True
            agent.BCG_HEART_RATE_ENABLED = False
            agent.SLOW_CACHE.clear()
            agent.SLOW_CACHE["environment"] = {
                "summary": {},
                "flat": {
                    "spu_hid.bcg_heart_rate_enabled": False,
                    "spu_hid.bcg_status": "disabled for low-power monitoring",
                },
                "sensors": [],
            }
            agent.CONTROL_PATH.write_text(json.dumps({"bcg_heart_rate_enabled": True}), encoding="utf-8")

            agent.apply_runtime_control()

            assert agent.BCG_HEART_RATE_ENABLED is True
            assert "environment" not in agent.SLOW_CACHE
    finally:
        agent.CONTROL_PATH = old_control_path
        agent.BCG_HEART_RATE_ENABLED = old_bcg_enabled
        agent.HELPER_ENABLED = old_helper_enabled
        agent.SLOW_CACHE.clear()
        agent.SLOW_CACHE.update(old_cache)


def test_helper_disable_control_forces_standby_and_blocks_live_tick():
    agent = load_agent()
    old_control_path = agent.CONTROL_PATH
    old_bcg_enabled = agent.BCG_HEART_RATE_ENABLED
    old_helper_enabled = agent.HELPER_ENABLED
    old_interval = agent.INTERVAL_MS
    old_profile = agent.PROFILE
    old_cache = dict(agent.SLOW_CACHE)

    try:
        with tempfile.TemporaryDirectory() as directory:
            agent.CONTROL_PATH = Path(directory) / "control.json"
            agent.HELPER_ENABLED = True
            agent.BCG_HEART_RATE_ENABLED = True
            agent.INTERVAL_MS = 2_000
            agent.PROFILE = "bench"
            agent.SLOW_CACHE.clear()
            agent.SLOW_CACHE["environment"] = {"summary": {}, "flat": {}, "sensors": []}
            agent.CONTROL_PATH.write_text(
                json.dumps({"helper_enabled": False, "helper_interval_ms": 5_000, "bcg_heart_rate_enabled": True}),
                encoding="utf-8",
            )

            agent.apply_runtime_control()

            assert agent.HELPER_ENABLED is False
            assert agent.BCG_HEART_RATE_ENABLED is False
            assert agent.INTERVAL_MS == 60_000
            assert agent.PROFILE == "quiet"
            assert "environment" not in agent.SLOW_CACHE
            assert agent.live_sensor_interval_s() == 60.0
            assert agent.merge_live_sensor_tick({"summary": {}, "flat": {}, "sensors": []}, 1) is None

            payload = agent.standby_payload(7)
            assert payload["status"] == "disabled"
            assert payload["flat"]["agent.helper_enabled"] is False
            assert payload["flat"]["agent.loop_index"] == 7
    finally:
        agent.CONTROL_PATH = old_control_path
        agent.BCG_HEART_RATE_ENABLED = old_bcg_enabled
        agent.HELPER_ENABLED = old_helper_enabled
        agent.INTERVAL_MS = old_interval
        agent.PROFILE = old_profile
        agent.SLOW_CACHE.clear()
        agent.SLOW_CACHE.update(old_cache)


if __name__ == "__main__":
    test_powermetrics_pressure_and_cluster_parse()
    test_battery_temperature_conversion()
    test_sensor_shape_from_summary()
    test_smc_probe_reports_status_without_writing()
    test_system_profiler_helpers_parse_display_mode()
    test_motion_usage_names()
    test_zero_cadence_caches_once()
    test_upsert_sensors_replaces_existing_rows()
    test_spu_lid_and_als_report_parsers()
    test_bcg_estimator_on_synthetic_signal()
    test_bool_control_parser()
    test_bcg_control_invalidates_environment_cache()
    test_helper_disable_control_forces_standby_and_blocks_live_tick()
    print("agent fixture tests passed")
