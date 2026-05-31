import SwiftUI

private enum MonitorSection: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case compute = "Compute"
    case thermalFans = "Thermal & Fans"
    case powerBattery = "Power & Battery"
    case display = "Displays"
    case storage = "Storage"
    case audio = "Audio"
    case bus = "Bus & I/O"
    case environment = "Environment"
    case sensors = "Sensors"
    case helperLogs = "Helper & Logs"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .compute: return "cpu"
        case .thermalFans: return "fan"
        case .powerBattery: return "bolt.batteryblock"
        case .display: return "display"
        case .storage: return "internaldrive"
        case .audio: return "speaker.wave.2"
        case .bus: return "cable.connector"
        case .environment: return "sensor"
        case .sensors: return "sensor"
        case .helperLogs: return "terminal"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Live Apple Silicon status at a glance."
        case .compute: return "CPU, GPU, ANE, memory, clocks and residency."
        case .thermalFans: return "Thermal pressure, die temperatures and experimental fan reads."
        case .powerBattery: return "SoC rails, adapter telemetry and battery health."
        case .display: return "Displays, GPU identity, Retina scale and refresh state."
        case .storage: return "Volumes, NVMe identity, free space and SMART state."
        case .audio: return "CoreAudio devices, defaults, sample rates and channel counts."
        case .bus: return "USB, Thunderbolt / USB4, PCI and network service inventory."
        case .environment: return "Ambient light, motion, lid and SPU-exposed sensor state."
        case .sensors: return "Dynamic catalog of every metric the helper can expose."
        case .helperLogs: return "Helper lifecycle, raw fields and diagnostics."
        }
    }
}

struct DashboardView: View {
    @StateObject private var store = TelemetryStore()
    @StateObject private var helper = PrivilegedHelperController()
    @State private var section: MonitorSection? = .overview
    @State private var preset: SamplingPreset = .live
    @State private var sensorFilter = ""
    @State private var sensorCategory = "All"
    @State private var sensorSource = "All"
    @State private var onlyAvailable = true
    @State private var showRaw = false

    private var snapshot: SystemSnapshot { store.snapshot }
    private var sensors: [SensorMetric] { snapshot.powermetrics.sensors }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Monitor") {
                    ForEach(MonitorSection.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("StellarScope")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    page(for: section ?? .overview)
                }
                .padding(24)
                .frame(maxWidth: 1240, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .background {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color.accentColor.opacity(0.07),
                        Color(nsColor: .windowBackgroundColor)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Sampling", selection: $preset) {
                        ForEach(SamplingPreset.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .onChange(of: preset, perform: { store.setPreset($0) })

                    Button { helper.refreshDiagnosis() } label: {
                        Label("Check", systemImage: "stethoscope")
                    }
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 760)
        .onAppear {
            store.setPreset(preset)
            store.start()
        }
        .onDisappear { store.stop() }
    }

    @ViewBuilder
    private func page(for section: MonitorSection) -> some View {
        switch section {
        case .overview: overviewPage
        case .compute: computePage
        case .thermalFans: thermalFansPage
        case .powerBattery: powerBatteryPage
        case .display: displayPage
        case .storage: storagePage
        case .audio: audioPage
        case .bus: busPage
        case .environment: environmentPage
        case .sensors: sensorsPage
        case .helperLogs: helperLogsPage
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text((section ?? .overview).rawValue)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Spacer()
                StatusBadge(text: feedStatusText, systemImage: feedStatusIcon)
            }
            Text((section ?? .overview).subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: metricColumns(minimum: 210), spacing: 14) {
                MetricCard(title: "CPU", value: snapshot.cpuActiveAverage.percentText, subtitle: "\(snapshot.cores.count) logical cores") {
                    SparklineView(values: store.cpuHistory).frame(height: 42)
                    MeterBar(value: snapshot.cpuActiveAverage)
                }
                MetricCard(title: "Memory", value: snapshot.memory.usedBytes.humanBytes, subtitle: "swap \(snapshot.memory.swapUsedBytes.humanBytes)") {
                    SparklineView(values: store.memoryHistory).frame(height: 42)
                    MeterBar(value: snapshot.memory.usedRatio)
                }
                MetricCard(title: "GPU", value: gpuValueText, subtitle: powerSubtitle) {
                    MeterBar(value: min(1, (snapshot.powermetrics.gpuResidencyPercent ?? 0) / 100.0))
                }
                MetricCard(title: "Thermal", value: snapshot.thermal.label, subtitle: thermalOverviewSubtitle) {
                    MeterBar(value: Double(snapshot.thermal.rawValue) / 3.0)
                }
                MetricCard(title: "Battery", value: sensorDisplay("battery.charge_percent") ?? "—", subtitle: sensorDisplay("adapter.watts").map { "adapter \($0)" } ?? "adapter —") {
                    MeterBar(value: (numberSensor("battery.charge_percent") ?? 0) / 100.0)
                }
                MetricCard(title: "Sensors", value: "\(sensors.count)", subtitle: "\(availableSensors.count) available, \(experimentalSensors.count) experimental") {
                    HStack(spacing: 8) {
                        StatusBadge(text: snapshot.powermetrics.source ?? "local", systemImage: "waveform.path.ecg")
                    }
                }
            }

            SectionBox(title: "System Pulse", subtitle: "Key state distilled from the dynamic sensor catalog.") {
                adaptiveKeyValues([
                    ("CPU user / system / idle", "\(snapshot.cpuUserAverage.percentText) / \(snapshot.cpuSystemAverage.percentText) / \(snapshot.cpuIdleAverage.percentText)"),
                    ("P / E frequency", "\(freq(snapshot.powermetrics.pClusterFrequencyHz)) / \(freq(snapshot.powermetrics.eClusterFrequencyHz))"),
                    ("CPU / GPU die", "\(celsius(snapshot.powermetrics.cpuDieTemperatureC)) / \(celsius(snapshot.powermetrics.gpuDieTemperatureC))"),
                    ("Fan readout", rpm(snapshot.powermetrics.fanRPM)),
                    ("Battery voltage", sensorDisplay("battery.voltage_mv") ?? "—"),
                    ("System input", sensorDisplay("system.input_power_mw") ?? "—")
                ])
            }
        }
    }

    private var computePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: metricColumns(minimum: 220), spacing: 14) {
                MetricCard(title: "Average Load", value: snapshot.cpuActiveAverage.percentText, subtitle: "user + system + nice") {
                    MeterBar(value: snapshot.cpuActiveAverage)
                }
                MetricCard(title: "P Cluster", value: freq(snapshot.powermetrics.pClusterFrequencyHz), subtitle: mw(snapshot.powermetrics.pClusterPowerMW)) {
                    MeterBar(value: min(1, (snapshot.powermetrics.pClusterFrequencyHz ?? 0) / 5_000_000_000))
                }
                MetricCard(title: "E Cluster", value: freq(snapshot.powermetrics.eClusterFrequencyHz), subtitle: mw(snapshot.powermetrics.eClusterPowerMW)) {
                    MeterBar(value: min(1, (snapshot.powermetrics.eClusterFrequencyHz ?? 0) / 3_000_000_000))
                }
                MetricCard(title: "GPU Runtime", value: percent(snapshot.powermetrics.gpuResidencyPercent), subtitle: "\(freq(snapshot.powermetrics.gpuFrequencyHz)) · \(mw(snapshot.powermetrics.gpuPowerMW))") {
                    MeterBar(value: min(1, (snapshot.powermetrics.gpuResidencyPercent ?? 0) / 100.0))
                }
            }

            SectionBox(title: "Per-Core Load", subtitle: "Logical core activity from Mach tick deltas.") {
                CoreGridView(cores: snapshot.cores)
            }

            sensorStrip(categories: ["Frequency", "Power"], title: "Compute Sensors")
        }
    }

    private var thermalFansPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: metricColumns(minimum: 220), spacing: 14) {
                MetricCard(title: "Thermal State", value: snapshot.thermal.label, subtitle: snapshot.powermetrics.thermalPressure ?? "ProcessInfo") {
                    MeterBar(value: Double(snapshot.thermal.rawValue) / 3.0)
                }
                MetricCard(title: "CPU Die", value: celsius(snapshot.powermetrics.cpuDieTemperatureC), subtitle: "macmon / helper") {
                    MeterBar(value: min(1, (snapshot.powermetrics.cpuDieTemperatureC ?? 0) / 105.0))
                }
                MetricCard(title: "GPU Die", value: celsius(snapshot.powermetrics.gpuDieTemperatureC), subtitle: "macmon / helper") {
                    MeterBar(value: min(1, (snapshot.powermetrics.gpuDieTemperatureC ?? 0) / 105.0))
                }
                MetricCard(title: "Fan RPM", value: rpm(snapshot.powermetrics.fanRPM), subtitle: fanStatusText) {
                    MeterBar(value: min(1, (snapshot.powermetrics.fanRPM ?? 0) / 6500.0))
                }
            }

            SectionBox(title: "Fan Probe", subtitle: "Experimental read-only SMC path. No control keys are written.") {
                adaptiveKeyValues([
                    ("Fan count", sensorDisplay("smc.fan_count") ?? "—"),
                    ("Fan 0 RPM", sensorDisplay("smc.fan0.rpm") ?? rpm(snapshot.powermetrics.fanRPM)),
                    ("Fan 0 min / max", "\(sensorDisplay("smc.fan0.min_rpm") ?? "—") / \(sensorDisplay("smc.fan0.max_rpm") ?? "—")"),
                    ("Fan 0 label", sensorDisplay("smc.fan0.label") ?? "—"),
                    ("SMC endpoint", rawValue("smc_read.endpoint_present") ?? "—"),
                    ("SMC status", rawValue("smc_read.error") ?? "ok")
                ])
            }

            sensorStrip(categories: ["Temperature", "Fan", "Thermal"], title: "Thermal Sensors")
        }
    }

    private var powerBatteryPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: metricColumns(minimum: 220), spacing: 14) {
                MetricCard(title: "CPU Power", value: mw(snapshot.powermetrics.cpuPowerMW), subtitle: clusterPowerText) {
                    MeterBar(value: min(1, (snapshot.powermetrics.cpuPowerMW ?? 0) / 35_000))
                }
                MetricCard(title: "GPU Power", value: mw(snapshot.powermetrics.gpuPowerMW), subtitle: "GPU RAM \(sensorDisplay("macmon.gpu_ram_power_mw") ?? "—")") {
                    MeterBar(value: min(1, (snapshot.powermetrics.gpuPowerMW ?? 0) / 35_000))
                }
                MetricCard(title: "System Input", value: sensorDisplay("system.input_power_mw") ?? "—", subtitle: sensorDisplay("adapter.watts").map { "adapter \($0)" } ?? "adapter —") {
                    MeterBar(value: min(1, (numberSensor("system.input_power_mw") ?? 0) / 100_000))
                }
                MetricCard(title: "Battery Health", value: sensorDisplay("battery.cycle_count") ?? "—", subtitle: sensorDisplay("battery.temperature_c").map { "battery \($0)" } ?? "battery —") {
                    MeterBar(value: min(1, (numberSensor("battery.cycle_count") ?? 0) / 1000))
                }
            }

            SectionBox(title: "Battery & Adapter", subtitle: "IORegistry fields from AppleSmartBattery and power telemetry.") {
                adaptiveKeyValues([
                    ("Charge", sensorDisplay("battery.charge_percent") ?? "—"),
                    ("Raw / max capacity", "\(sensorDisplay("battery.raw_capacity_mah") ?? "—") / \(sensorDisplay("battery.max_capacity_mah") ?? "—")"),
                    ("Design capacity", sensorDisplay("battery.design_capacity_mah") ?? "—"),
                    ("Battery voltage", sensorDisplay("battery.voltage_mv") ?? "—"),
                    ("Adapter voltage / current", "\(sensorDisplay("adapter.voltage_mv") ?? "—") / \(sensorDisplay("adapter.current_ma") ?? "—")"),
                    ("DRAM power", mw(snapshot.powermetrics.dramPowerMW))
                ])
            }

            sensorStrip(categories: ["Power", "Battery"], title: "Power Sensors")
        }
    }

    private var displayPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            helperUpgradeNotice
            LazyVGrid(columns: metricColumns(minimum: 220), spacing: 14) {
                MetricCard(title: "Displays", value: sensorDisplay("display.count") ?? "—", subtitle: sensorDisplay("display.0.name") ?? "panel inventory") {
                    MeterBar(value: min(1, (numberSensor("display.count") ?? 0) / 4.0))
                }
                MetricCard(title: "ProMotion", value: displayRefreshText, subtitle: displayRefreshSubtitle) {
                    MeterBar(value: min(1, (snapshot.displayRefresh.measuredHz ?? snapshot.displayRefresh.modeHz ?? 0) / 120.0))
                }
                MetricCard(title: "Resolution", value: displayResolutionText, subtitle: displayVRRRangeText) {
                    MeterBar(value: min(1, (numberSensor("display.refresh0.vrr_max_hz") ?? snapshot.displayRefresh.modeHz ?? 0) / 120.0))
                }
                MetricCard(title: "GPU", value: sensorDisplay("display.gpu0.name") ?? "—", subtitle: sensorDisplay("display.gpu0.cores").map { "\($0) cores" } ?? "cores —") {
                    MeterBar(value: min(1, (numberSensor("display.gpu0.cores") ?? 0) / 40.0))
                }
                MetricCard(title: "Metal", value: sensorDisplay("display.gpu0.metal") ?? "—", subtitle: sensorDisplay("display.0.type") ?? "display type —") {
                    StatusBadge(text: sensorDisplay("display.0.connection") ?? "connection —", systemImage: "display")
                }
            }

            SectionBox(title: "Primary Display", subtitle: "Resolution, mode, connection and panel state.") {
                adaptiveKeyValues([
                    ("Name", sensorDisplay("display.0.name") ?? "—"),
                    ("Physical pixels", displayResolutionText),
                    ("Logical mode", "\(sensorDisplay("display.0.logical_width_px") ?? "—") x \(sensorDisplay("display.0.logical_height_px") ?? "—")"),
                    ("Measured refresh", displayRefreshText),
                    ("Mode refresh", sensorDisplay("display.0.refresh_hz") ?? hz(snapshot.displayRefresh.modeHz)),
                    ("VRR range", displayVRRRangeText),
                    ("Connection", sensorDisplay("display.0.connection") ?? "—"),
                    ("Online / main", "\(sensorDisplay("display.0.online") ?? "—") / \(sensorDisplay("display.0.main") ?? "—")")
                ])
            }

            sensorStrip(categories: ["Display"], title: "Display Sensors")
        }
    }

    private var storagePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            helperUpgradeNotice
            LazyVGrid(columns: metricColumns(minimum: 220), spacing: 14) {
                MetricCard(title: "Volumes", value: sensorDisplay("storage.volume_count") ?? "—", subtitle: sensorDisplay("storage.nvme_count").map { "NVMe \($0)" } ?? "NVMe —") {
                    MeterBar(value: min(1, (numberSensor("storage.volume_count") ?? 0) / 8.0))
                }
                MetricCard(title: "Data Free", value: sensorDisplay("storage.volume0.free_bytes") ?? "—", subtitle: sensorDisplay("storage.volume0.used_percent").map { "used \($0)" } ?? "used —") {
                    MeterBar(value: min(1, (numberSensor("storage.volume0.used_percent") ?? 0) / 100.0))
                }
                MetricCard(title: "Internal SSD", value: sensorDisplay("storage.nvme0.model") ?? sensorDisplay("storage.volume0.drive") ?? "—", subtitle: sensorDisplay("storage.nvme0.size_bytes") ?? "size —") {
                    StatusBadge(text: sensorDisplay("storage.nvme0.smart") ?? "SMART —", systemImage: "checkmark.seal")
                }
                MetricCard(title: "Protocol", value: sensorDisplay("storage.volume0.protocol") ?? "—", subtitle: sensorDisplay("storage.nvme0.trim").map { "TRIM \($0)" } ?? "TRIM —") {
                    StatusBadge(text: sensorDisplay("storage.volume0.filesystem") ?? "filesystem —", systemImage: "internaldrive")
                }
            }

            SectionBox(title: "Primary Volume", subtitle: "Capacity and media details from Storage and NVMe system profiler.") {
                adaptiveKeyValues([
                    ("Name", sensorDisplay("storage.volume0.name") ?? "—"),
                    ("Mount", sensorDisplay("storage.volume0.mount") ?? "—"),
                    ("Size / free", "\(sensorDisplay("storage.volume0.size_bytes") ?? "—") / \(sensorDisplay("storage.volume0.free_bytes") ?? "—")"),
                    ("Used", sensorDisplay("storage.volume0.used_percent") ?? "—"),
                    ("Drive", sensorDisplay("storage.volume0.drive") ?? "—"),
                    ("SMART", sensorDisplay("storage.volume0.smart") ?? sensorDisplay("storage.nvme0.smart") ?? "—")
                ])
            }

            sensorStrip(categories: ["Storage"], title: "Storage Sensors")
        }
    }

    private var audioPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            helperUpgradeNotice
            LazyVGrid(columns: metricColumns(minimum: 220), spacing: 14) {
                MetricCard(title: "Audio Devices", value: sensorDisplay("audio.device_count") ?? "—", subtitle: "CoreAudio") {
                    MeterBar(value: min(1, (numberSensor("audio.device_count") ?? 0) / 12.0))
                }
                MetricCard(title: "Default Output", value: sensorDisplay("audio.default_output") ?? "—", subtitle: sensorDisplay("audio.device0.sample_rate_hz") ?? "sample rate —") {
                    StatusBadge(text: sensorDisplay("audio.device0.transport") ?? "transport —", systemImage: "speaker.wave.2")
                }
                MetricCard(title: "Default Input", value: sensorDisplay("audio.default_input") ?? "—", subtitle: "input route") {
                    StatusBadge(text: "CoreAudio", systemImage: "mic")
                }
                MetricCard(title: "Channels", value: "\(sensorDisplay("audio.device0.inputs") ?? "—") / \(sensorDisplay("audio.device0.outputs") ?? "—")", subtitle: "input / output") {
                    MeterBar(value: min(1, ((numberSensor("audio.device0.inputs") ?? 0) + (numberSensor("audio.device0.outputs") ?? 0)) / 8.0))
                }
            }

            SectionBox(title: "Default Routes", subtitle: "Current default input/output plus visible CoreAudio devices.") {
                adaptiveKeyValues([
                    ("Default input", sensorDisplay("audio.default_input") ?? "—"),
                    ("Default output", sensorDisplay("audio.default_output") ?? "—"),
                    ("Device 0", sensorDisplay("audio.device0.name") ?? "—"),
                    ("Sample rate", sensorDisplay("audio.device0.sample_rate_hz") ?? "—"),
                    ("Transport", sensorDisplay("audio.device0.transport") ?? "—"),
                    ("Manufacturer", sensorDisplay("audio.device0.manufacturer") ?? "—")
                ])
            }

            sensorStrip(categories: ["Audio"], title: "Audio Sensors")
        }
    }

    private var busPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            helperUpgradeNotice
            LazyVGrid(columns: metricColumns(minimum: 220), spacing: 14) {
                MetricCard(title: "Thunderbolt / USB4", value: sensorDisplay("bus.thunderbolt_bus_count") ?? "—", subtitle: sensorDisplay("bus.thunderbolt0.receptacle_1_tag.speed") ?? "speed —") {
                    MeterBar(value: min(1, (numberSensor("bus.thunderbolt_bus_count") ?? 0) / 4.0))
                }
                MetricCard(title: "USB Roots", value: sensorDisplay("bus.usb_root_count") ?? "—", subtitle: "system profiler") {
                    MeterBar(value: min(1, (numberSensor("bus.usb_root_count") ?? 0) / 8.0))
                }
                MetricCard(title: "PCI Devices", value: sensorDisplay("bus.pci_device_count") ?? "—", subtitle: "PCI inventory") {
                    MeterBar(value: min(1, (numberSensor("bus.pci_device_count") ?? 0) / 12.0))
                }
                MetricCard(title: "Network", value: sensorDisplay("bus.network_service_count") ?? "—", subtitle: sensorDisplay("bus.network0.interface") ?? "interfaces") {
                    MeterBar(value: min(1, (numberSensor("bus.network_service_count") ?? 0) / 16.0))
                }
            }

            SectionBox(title: "I/O Overview", subtitle: "External buses and network services. Addresses are kept in raw diagnostics.") {
                adaptiveKeyValues([
                    ("Thunderbolt bus 0", sensorDisplay("bus.thunderbolt0.name") ?? "—"),
                    ("Port speed", sensorDisplay("bus.thunderbolt0.receptacle_1_tag.speed") ?? "—"),
                    ("Port status", sensorDisplay("bus.thunderbolt0.receptacle_1_tag.status") ?? "—"),
                    ("Network 0", sensorDisplay("bus.network0.name") ?? "—"),
                    ("Network 0 interface", sensorDisplay("bus.network0.interface") ?? "—"),
                    ("Network 0 type", sensorDisplay("bus.network0.type") ?? "—")
                ])
            }

            sensorStrip(categories: ["Bus"], title: "Bus Sensors")
        }
    }

    private var environmentPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            helperUpgradeNotice
            LazyVGrid(columns: metricColumns(minimum: 220), spacing: 14) {
                MetricCard(title: "Ambient Light", value: sensorDisplay("environment.ambient_lux") ?? "—", subtitle: sensorDisplay("environment.als_transport") ?? "ALS sensor") {
                    MeterBar(value: min(1, (numberSensor("environment.ambient_lux") ?? 0) / 1000.0))
                }
                MetricCard(title: "Accelerometer", value: sensorDisplay("motion.accelerometer.available") ?? "—", subtitle: sensorDisplay("motion.accelerometer.model") ?? "model —") {
                    StatusBadge(text: sensorDisplay("motion.accelerometer.rates") ?? "rates —", systemImage: "move.3d")
                }
                MetricCard(title: "Gyroscope", value: sensorDisplay("motion.gyroscope.available") ?? "—", subtitle: sensorDisplay("motion.gyroscope.model") ?? "model —") {
                    StatusBadge(text: sensorDisplay("motion.gyroscope.rates") ?? "rates —", systemImage: "gyroscope")
                }
                MetricCard(title: "Lid / Hall", value: sensorDisplay("environment.clamshell_closed") ?? "—", subtitle: sensorDisplay("motion.hall.model") ?? "hall sensor") {
                    MeterBar(value: (sensorDisplay("environment.clamshell_closed") == "yes") ? 1 : 0)
                }
            }

            SectionBox(title: "Environment & Motion", subtitle: "Values are read from SPU/ALS/IOPM services. Raw motion axes may be privacy-gated; this page shows exposed state and counters.") {
                adaptiveKeyValues([
                    ("Ambient lux", sensorDisplay("environment.ambient_lux") ?? "—"),
                    ("ALS events", sensorDisplay("environment.als_events") ?? "—"),
                    ("Accelerometer model", sensorDisplay("motion.accelerometer.model") ?? "—"),
                    ("Accelerometer events", sensorDisplay("motion.accelerometer.events") ?? "—"),
                    ("Gyroscope model", sensorDisplay("motion.gyroscope.model") ?? "—"),
                    ("Gyroscope events", sensorDisplay("motion.gyroscope.events") ?? "—"),
                    ("Hall model", sensorDisplay("motion.hall.model") ?? "—"),
                    ("Wake reason", sensorDisplay("environment.wake_reason") ?? "—")
                ])
            }

            sensorStrip(categories: ["Environment", "Motion"], title: "Environment Sensors")
        }
    }

    private var sensorsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionBox(title: "Sensor Catalog", subtitle: "Filter by category, source, availability, or raw key.") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        TextField("Search sensors", text: $sensorFilter)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220, maxWidth: 360)

                        Picker("Category", selection: $sensorCategory) {
                            ForEach(sensorCategories, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 170)

                        Picker("Source", selection: $sensorSource) {
                            ForEach(sensorSources, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 180)

                        Toggle("Available", isOn: $onlyAvailable)
                            .toggleStyle(.switch)
                    }

                    SensorTableView(rows: filteredSensors)
                }
            }
        }
    }

    private var helperLogsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            helperControls(compact: false)

            SectionBox(title: "Diagnostics", subtitle: "Raw helper output remains available for reverse engineering and support.") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Show raw fields", isOn: $showRaw)
                    if showRaw {
                        SensorRawTable(rows: filteredRawRows)
                    } else {
                        adaptiveKeyValues([
                            ("Output", PrivilegedHelperLauncher.outputPath),
                            ("Log", PrivilegedHelperLauncher.logPath),
                            ("LaunchDaemon", PrivilegedHelperLauncher.launchdLabel),
                            ("Source", snapshot.powermetrics.source ?? "—"),
                            ("Samplers", snapshot.powermetrics.samplers ?? "—"),
                            ("Raw fields", "\(snapshot.powermetrics.rawCount)")
                        ])
                    }
                }
            }
        }
    }

    private func helperControls(compact: Bool) -> some View {
        SectionBox(title: "Advanced Helper", subtitle: "LaunchDaemon sampler; the app only reads /tmp JSON and logs.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { helper.start(intervalMS: Int(preset.interval * 1000)) } label: {
                        Label("Start", systemImage: "lock.open")
                    }
                    .disabled(helper.isBusy)

                    Button { helper.stop() } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .disabled(helper.isBusy)

                    Button { helper.refreshDiagnosis() } label: {
                        Label("Check", systemImage: "stethoscope")
                    }

                    Button { helper.openLog() } label: {
                        Label("Open Log", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Text(helper.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let status = snapshot.powermetrics.status {
                    Text("JSON status: \(status) · sensors: \(sensors.count) · raw fields: \(snapshot.powermetrics.rawCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let error = snapshot.powermetrics.error, !snapshot.powermetrics.available {
                    Text("Helper JSON error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !compact {
                    adaptiveKeyValues([
                        ("UI interval", String(format: "%.2fs", preset.interval)),
                        ("Advanced interval", String(format: "%.2fs", Double(preset.helperIntervalMS) / 1000.0)),
                        ("Helper schema", rawValue("agent.schema_version") ?? "old / unknown"),
                        ("Helper profile", rawValue("agent.profile") ?? preset.profileName),
                        ("Control file", rawValue("agent.control_path") ?? "/tmp/stellarscope-control.json"),
                        ("CPU source", "Mach host_processor_info"),
                        ("Memory source", "host_statistics64 + vm.swapusage"),
                        ("Advanced source", "macmon / powermetrics / IORegistry / system_profiler / SMC probe")
                    ])
                }
            }
        }
    }

    @ViewBuilder
    private var helperUpgradeNotice: some View {
        if helperNeedsRestartForExtendedPanels {
            SectionBox(title: "Helper Restart Required", subtitle: "The app UI is newer than the running LaunchDaemon helper, so these panels are still reading the old JSON schema.") {
                HStack(spacing: 12) {
                    Button { helper.start(intervalMS: preset.helperIntervalMS) } label: {
                        Label("Restart Advanced Helper", systemImage: "arrow.clockwise")
                    }
                    .disabled(helper.isBusy)

                    Text("After the administrator prompt, Display / Storage / Audio / Bus sensors will populate on the next samples.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func sensorStrip(categories: Set<String>, title: String) -> some View {
        SectionBox(title: title, subtitle: "Values shown only when the active backend exposes them.") {
            SensorTableView(rows: sensors.filter { categories.contains($0.category) }.prefixArray(12))
        }
    }

    private func metricColumns(minimum: CGFloat) -> [GridItem] {
        [GridItem(.adaptive(minimum: minimum), spacing: 14)]
    }

    private func adaptiveKeyValues(_ rows: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .leading)], alignment: .leading, spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0).font(.caption).foregroundStyle(.secondary)
                    Text(row.1).font(.body.monospacedDigit()).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var filteredRawRows: [RawMetric] {
        snapshot.powermetrics.rawFields
    }

    private var filteredSensors: [SensorMetric] {
        let filter = sensorFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sensors.filter { sensor in
            let categoryOK = sensorCategory == "All" || sensor.category == sensorCategory
            let sourceOK = sensorSource == "All" || sensor.source == sensorSource
            let availableOK = !onlyAvailable || sensor.value != "—"
            let filterOK = filter.isEmpty
                || sensor.title.lowercased().contains(filter)
                || sensor.rawKey.lowercased().contains(filter)
                || sensor.source.lowercased().contains(filter)
                || sensor.value.lowercased().contains(filter)
            return categoryOK && sourceOK && availableOK && filterOK
        }
    }

    private var sensorCategories: [String] {
        ["All"] + Array(Set(sensors.map(\.category))).sorted()
    }

    private var sensorSources: [String] {
        ["All"] + Array(Set(sensors.map(\.source))).sorted()
    }

    private var availableSensors: [SensorMetric] {
        sensors.filter { $0.value != "—" }
    }

    private var experimentalSensors: [SensorMetric] {
        sensors.filter(\.isExperimental)
    }

    private var helperNeedsRestartForExtendedPanels: Bool {
        guard snapshot.powermetrics.available else { return false }
        let schema = numberRaw("agent.schema_version") ?? 0
        return schema < 5 && !hasExtendedPanelSensors
    }

    private var hasExtendedPanelSensors: Bool {
        sensors.contains { ["Display", "Storage", "Audio", "Bus", "Environment", "Motion"].contains($0.category) }
    }

    private var feedStatusText: String {
        if helperNeedsRestartForExtendedPanels { return "Restart helper for new panels" }
        return snapshot.powermetrics.available ? "Advanced feed live" : "Advanced feed waiting"
    }

    private var feedStatusIcon: String {
        if helperNeedsRestartForExtendedPanels { return "arrow.clockwise.circle.fill" }
        return snapshot.powermetrics.available ? "checkmark.circle.fill" : "clock"
    }

    private func sensorDisplay(_ id: String) -> String? {
        sensors.first { $0.id == id }?.displayValue
    }

    private func numberSensor(_ id: String) -> Double? {
        guard let value = sensors.first(where: { $0.id == id })?.value else { return nil }
        return Double(value)
    }

    private func rawValue(_ key: String) -> String? {
        snapshot.powermetrics.rawFields.first { $0.key == key }?.value
    }

    private func numberRaw(_ key: String) -> Double? {
        guard let value = rawValue(key) else { return nil }
        return Double(value)
    }

    private var thermalOverviewSubtitle: String {
        if let cpu = snapshot.powermetrics.cpuDieTemperatureC { return "CPU die \(celsius(cpu))" }
        return snapshot.powermetrics.thermalPressure ?? "public thermal state"
    }

    private var gpuValueText: String {
        if let r = snapshot.powermetrics.gpuResidencyPercent { return String(format: "%.0f%%", r) }
        if let p = snapshot.powermetrics.gpuPowerMW { return mw(p) }
        return "—"
    }

    private var powerSubtitle: String {
        if let f = snapshot.powermetrics.gpuFrequencyHz { return "GPU freq \(freq(f))" }
        if let p = snapshot.powermetrics.gpuPowerMW { return "GPU power \(mw(p))" }
        return "advanced helper off"
    }

    private var fanStatusText: String {
        if snapshot.powermetrics.fanRPM != nil { return "SMC read-only" }
        return rawValue("smc_read.error") ?? "unavailable"
    }

    private var clusterPowerText: String {
        "P \(mw(snapshot.powermetrics.pClusterPowerMW)) · E \(mw(snapshot.powermetrics.eClusterPowerMW))"
    }

    private var displayResolutionText: String {
        let fallbackWidth = snapshot.displayRefresh.pixelWidth > 0 ? "\(snapshot.displayRefresh.pixelWidth)" : nil
        let fallbackHeight = snapshot.displayRefresh.pixelHeight > 0 ? "\(snapshot.displayRefresh.pixelHeight)" : nil
        guard let width = sensorDisplay("display.0.width_px") ?? fallbackWidth,
              let height = sensorDisplay("display.0.height_px") ?? fallbackHeight else {
            return "—"
        }
        return "\(width) x \(height)"
    }

    private var displayRefreshText: String {
        hz(snapshot.displayRefresh.measuredHz ?? snapshot.displayRefresh.actualHz ?? snapshot.displayRefresh.modeHz)
    }

    private var displayRefreshSubtitle: String {
        if snapshot.displayRefresh.measuredHz != nil { return "CVDisplayLink measured" }
        if snapshot.displayRefresh.modeHz != nil { return "mode refresh" }
        return "waiting for display link"
    }

    private var displayVRRRangeText: String {
        guard let min = sensorDisplay("display.refresh0.vrr_min_hz"),
              let max = sensorDisplay("display.refresh0.vrr_max_hz") else {
            return "VRR range —"
        }
        return "\(min) - \(max)"
    }

    private func mw(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1000 { return String(format: "%.2f W", value / 1000.0) }
        return String(format: "%.0f mW", value)
    }

    private func freq(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value > 1_000_000_000 { return String(format: "%.2f GHz", value / 1_000_000_000) }
        if value > 1_000_000 { return String(format: "%.0f MHz", value / 1_000_000) }
        if value > 1_000 { return String(format: "%.0f kHz", value / 1_000) }
        return String(format: "%.0f Hz", value)
    }

    private func hz(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f Hz", value)
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value)
    }

    private func celsius(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f C", value)
    }

    private func celsius(_ value: Double) -> String {
        String(format: "%.1f C", value)
    }

    private func rpm(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f rpm", value)
    }
}

private struct StatusBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .stellarGlassSurface(radius: 12, interactive: true)
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            content
        }
        .padding(18)
        .stellarGlassSurface(radius: 18)
    }
}

private struct SensorTableView: View {
    let rows: [SensorMetric]

    var body: some View {
        if rows.isEmpty {
            Text("No sensors are available for this filter.")
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    tableHeader("Sensor")
                    tableHeader("Value")
                    tableHeader("Source")
                    tableHeader("Raw")
                }
                ForEach(rows) { item in
                    GridRow {
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: item.category))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(1)
                                Text(item.category).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(item.displayValue)
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(item.source)
                            .font(.caption)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if item.isExperimental {
                                Text("EXP")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                            }
                            Text(item.rawKey)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tableHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func icon(for category: String) -> String {
        switch category {
        case "Temperature", "Thermal": return "thermometer.medium"
        case "Fan": return "fan"
        case "Power", "Battery": return "bolt"
        case "Frequency": return "waveform.path.ecg"
        case "Memory": return "memorychip"
        case "Display": return "display"
        case "Environment": return "sun.max"
        case "Motion": return "move.3d"
        default: return "sensor"
        }
    }
}

private struct SensorRawTable: View {
    let rows: [RawMetric]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow {
                Text("Key").foregroundStyle(.secondary)
                Text("Value").foregroundStyle(.secondary)
            }
            ForEach(Array(rows.prefix(180))) { item in
                GridRow {
                    Text(item.key)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(item.value)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private extension Array where Element == SensorMetric {
    func prefixArray(_ maxLength: Int) -> [SensorMetric] {
        Array(prefix(maxLength))
    }
}
