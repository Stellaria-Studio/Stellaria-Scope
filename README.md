# StellarScope

StellarScope is a native SwiftUI monitor for Apple Silicon Macs. It focuses on
fast local telemetry, a Liquid Glass-inspired dashboard, and a dynamic sensor
catalog that shows every metric the current machine and macOS build exposes.

The app itself does not run as root. Low-power realtime SPU, IORegistry,
AppleSMC and IOReport readings are native Swift/C++ collectors inside the app.
Optional privileged sampling is handled by a Python LaunchDaemon helper that
writes JSON and logs under `/tmp`.

## Features

- CPU core load, native IOReport P/E cluster frequency, GPU frequency/residency
  and best-effort CPU/GPU power where the current macOS build exposes it.
- Unified memory usage, compression, cache estimate and swap usage.
- GPU residency, GPU frequency, GPU power and ProMotion refresh telemetry.
- CPU/GPU die temperature where exposed by AppleSMC, `macmon` or
  `powermetrics`.
- Experimental read-only AppleSMC fan probing for RPM and min/max.
- Battery, adapter and system input power via AppleSmartBattery/IORegistry.
- Native Display, storage, audio, USB/Thunderbolt/PCI/network inventory panels.
- Environment and motion sensors through IORegistry, including ambient light,
  accelerometer, gyroscope, Hall/lid state and SPU temperature metadata.
- Sensor Lab page for native SPU HID toys: MacBook lid angle,
  ambient-light color channels, live trace charts and an explicit BCG
  heart-rate opt-in switch.
- Customizable menu bar readout for CPU, memory, power, thermal, battery,
  refresh and other key metrics.
- Dynamic Sensors table with category/source filters and raw-key visibility.
- macOS 26 Liquid Glass support with material fallback on macOS 13-25.

Some low-level Apple Silicon fields are private or version-dependent. When macOS
does not expose a value, StellarScope keeps the UI stable and shows the raw
diagnostic status instead of pretending the metric exists.

## Requirements

- macOS 13 or newer.
- Apple Silicon Mac recommended.
- For source builds: Xcode or Xcode Command Line Tools with Swift 5.9+.
- Optional: [`macmon`](https://github.com/vladkens/macmon) for additional
  temperature, power and frequency data.

## Download And Install

Download the latest `StellarScope-*.dmg` from GitHub Releases, open it, and drag
`StellarScope.app` into `Applications`.

The release DMG is ad-hoc signed but not notarized. If macOS Gatekeeper blocks
the first launch, right-click `StellarScope.app`, choose `Open`, and confirm once.

The release also includes `StellarScope-*.app.zip` for users who prefer a direct
app archive.

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

StellarScope works without the Python helper for local CPU, memory, thermal,
display refresh, battery/adapter telemetry, IOReport energy/frequency counters,
AppleSMC fan probing, PMGR DVFS state metadata, native inventory panels and
native SPU realtime sensors. Enable `Python Advanced Backend` in
`Helper & Logs` only when you want powermetrics/macmon fallback data for fields
still hidden on this macOS build, or experimental BCG heart-rate sampling. Then
start the advanced helper from the same page, or run:

```bash
./scripts/start_advanced_helper.command
```

The helper writes:

```text
/tmp/stellarscope-powermetrics.json
/tmp/stellarscope-powermetrics-agent.log
/tmp/stellarscope-powermetrics.pid
```

The sampling preset keeps native Swift collectors responsive while throttling
expensive optional sources such as `powermetrics`, `system_profiler` and SMC
reads:

- Quiet: local UI every 2 seconds, advanced helper every 15 seconds.
- Live: local UI every 1 second, advanced helper every 5 seconds.
- Bench: local UI every 250 milliseconds, advanced helper every 1 second.

The helper can still read slow inventory panels as a fallback, but the app now
has native Swift collectors for display, storage, audio and bus metadata. Native
IOReport uses in-process delta samples instead of launching `powermetrics` for
the common GPU power/residency and PMU frequency path. Native SPU lid angle and
ambient-light color update in-app without waiting for this JSON backend.

## Fan RPM Notes

StellarScope only attempts read-only fan access. It may read AppleSMC keys such
as `FNum`, `F0Ac`, `F0Mn`, `F0Mx` and `F0ID` when the platform allows it.

It does not write fan target, mode or test keys, and it does not take over
thermal control.

## SPU Motion Notes

StellarScope reads low-rate SPU HID snapshots for lid angle and ambient-light
color channels through a native Swift/IOKit path. These playful, exploratory
sensors live on the Sensor Lab page instead of the regular Environment page,
with rolling trace charts for lid angle, ambient lux, ALS chroma and BCG
readings.

High-rate accelerometer/gyroscope streaming and BCG heart-rate detection are not
enabled by default because they keep the SPU active. The Sensor Lab page exposes
a separate BCG heart-rate opt-in switch. Turning it on automatically enables the
Python advanced backend and starts the bundled LaunchDaemon helper when needed;
turn it off after short experiments to return to low-power monitoring.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for MIT attribution to the
apple-silicon-accelerometer project that documented these report formats.

## Tests

```bash
python3 -B Tests/test_powermetrics_agent.py
swift build -c release
```

## Repository Layout

```text
Sources/StellarScope/              SwiftUI app and collectors
Sources/StellarScopeNative/        C++ IOReport/IOKit native telemetry bridge
Sources/StellarScopeSMCProbe/      Read-only AppleSMC probe executable
Sources/StellarScope/Resources/    Python advanced helper
Tests/                             Helper parser tests
scripts/                           Build, install and helper scripts
Bundle/                            App bundle metadata and icon
```

## License

MIT License. See [LICENSE](LICENSE).
