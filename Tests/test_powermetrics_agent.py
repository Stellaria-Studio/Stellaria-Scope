import importlib.util
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


if __name__ == "__main__":
    test_powermetrics_pressure_and_cluster_parse()
    test_battery_temperature_conversion()
    test_sensor_shape_from_summary()
    test_smc_probe_reports_status_without_writing()
    test_system_profiler_helpers_parse_display_mode()
    test_motion_usage_names()
    print("agent fixture tests passed")
