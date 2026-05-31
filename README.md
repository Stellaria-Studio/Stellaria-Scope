# StellarScope

StellarScope is a native SwiftUI monitor for Apple Silicon Macs. It focuses on
fast local telemetry, a Liquid Glass-inspired dashboard, and a dynamic sensor
catalog that shows every metric the current machine and macOS build exposes.

The app itself does not run as root. Optional privileged sampling is handled by a
LaunchDaemon helper that writes JSON and logs under `/tmp`.

## Features

- CPU core load, P/E cluster frequency, CPU power and thermal pressure.
- Unified memory usage, compression, cache estimate and swap usage.
- GPU residency, GPU frequency, GPU power and ProMotion refresh telemetry.
- CPU/GPU die temperature where exposed by `macmon` or `powermetrics`.
- Experimental read-only AppleSMC fan probing for RPM, min/max and labels.
- Battery, adapter and system input power via AppleSmartBattery/IORegistry.
- Display, storage, audio, USB/Thunderbolt/PCI/network inventory panels.
- Environment and motion sensors through IORegistry, including ambient light,
  accelerometer, gyroscope, Hall/lid state and SPU temperature metadata.
- Dynamic Sensors table with category/source filters and raw-key visibility.
- macOS 26 Liquid Glass support with material fallback on macOS 13-25.

Some low-level Apple Silicon fields are private or version-dependent. When macOS
does not expose a value, StellarScope keeps the UI stable and shows the raw
diagnostic status instead of pretending the metric exists.

## Requirements

- macOS 13 or newer.
- Xcode or Xcode Command Line Tools with Swift 5.9+.
- Apple Silicon Mac recommended.
- Optional: [`macmon`](https://github.com/vladkens/macmon) for additional
  temperature, power and frequency data.

## Build And Run

```bash
./scripts/build_and_run.command
```

The script builds a release binary, creates:

```text
Build/StellarScope.app
```

and opens the app.

You can also build directly with SwiftPM:

```bash
swift build -c release
```

## Advanced Helper

For powermetrics, SMC fan probing and some slower diagnostic sources, start the
advanced helper from the `Helper & Logs` page, or run:

```bash
./scripts/start_advanced_helper.command
```

The helper writes:

```text
/tmp/stellarscope-powermetrics.json
/tmp/stellarscope-powermetrics-agent.log
/tmp/stellarscope-powermetrics.pid
```

The sampling preset in the app can adjust the helper interval:

- Quiet: 2 seconds
- Live: 1 second
- Bench: 250 milliseconds

## Fan RPM Notes

StellarScope only attempts read-only fan access. It may read AppleSMC keys such
as `FNum`, `F0Ac`, `F0Mn`, `F0Mx` and `F0ID` when the platform allows it.

It does not write fan target, mode or test keys, and it does not take over
thermal control.

## Tests

```bash
python3 -B Tests/test_powermetrics_agent.py
swift build -c release
```

## Repository Layout

```text
Sources/StellarScope/              SwiftUI app and collectors
Sources/StellarScopeSMCProbe/      Read-only AppleSMC probe executable
Sources/StellarScope/Resources/    Python advanced helper
Tests/                             Helper parser tests
scripts/                           Build, install and helper scripts
Bundle/                            App bundle metadata
```

## License

MIT License. See [LICENSE](LICENSE).
