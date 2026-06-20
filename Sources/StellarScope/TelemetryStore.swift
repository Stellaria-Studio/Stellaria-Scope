import Foundation
import SwiftUI

@MainActor
final class TelemetryStore: ObservableObject {
    static let shared = TelemetryStore()

    @Published var snapshot = SystemSnapshot()
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var lidAngleHistory: [Double] = []
    @Published var ambientLightHistory: [Double] = []
    @Published var alsChromaHistories: [[Double]] = Array(repeating: [], count: 4)
    @Published var bcgHeartRateHistory: [Double] = []
    @Published var samplingInterval: TimeInterval = 1.0

    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let thermal = ThermalCollector()
    private let nativeAdvanced = NativeAdvancedCollector()
    private let nativePower = NativePowerCollector()
    private let nativeInventory = NativeInventoryCollector()
    private let powermetrics = PowerMetricsCollector()
    private let displayRefresh = DisplayRefreshCollector()
    private let environment = EnvironmentCollector()
    private var task: Task<Void, Never>?
    private let pythonBackendKey = "pythonAdvancedBackendEnabled"
    private var appIsActive = true
    private var menuPopoverVisible = false
    private var visibleSectionID = "Overview"

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce()
                let ns = UInt64((self?.effectiveSamplingInterval ?? 1.0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func setPreset(_ preset: SamplingPreset) {
        samplingInterval = preset.interval
        writeAdvancedSamplingControl(preset)
    }

    func setBCGHeartRateEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "bcgHeartRateEnabled")
        writeAdvancedSamplingControl(currentPreset)
    }

    func setDisplayRefreshMeasurementEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "displayRefreshMeasurementEnabled")
    }

    func setPythonAdvancedBackendEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: pythonBackendKey)
        writeAdvancedSamplingControl(currentPreset)
    }

    func setUIContext(sectionID: String, appIsActive: Bool) {
        let shouldRewriteControl = self.appIsActive != appIsActive
        self.visibleSectionID = sectionID
        self.appIsActive = appIsActive
        if shouldRewriteControl {
            writeAdvancedSamplingControl(currentPreset)
        }
    }

    func setMenuPopoverVisible(_ visible: Bool) {
        guard menuPopoverVisible != visible else { return }
        menuPopoverVisible = visible
        writeAdvancedSamplingControl(currentPreset)
    }

    func refreshMenuBarSelection() {
        writeAdvancedSamplingControl(currentPreset)
    }

    private var liveConsumerActive: Bool {
        appIsActive || menuPopoverVisible
    }

    private var menuBarRefreshInterval: TimeInterval {
        switch currentPreset {
        case .quiet: return 5.0
        case .live: return 2.0
        case .bench: return 1.0
        }
    }

    private var menuSelectedMetrics: [MenuBarMetric] {
        let raw = UserDefaults.standard.string(forKey: "menuBarMetricIDs") ?? MenuBarMetricSelection.defaultRawValue
        return MenuBarMetricSelection.metrics(from: raw)
    }

    private var menuNeedsNativeAdvanced: Bool {
        menuPopoverVisible || menuSelectedMetrics.contains { metric in
            switch metric {
            case .thermal, .cpuPower, .gpu, .fan, .sensors:
                return true
            case .cpu, .memory, .swap, .battery, .heartRate, .refresh:
                return false
            }
        }
    }

    private var menuNeedsEnvironment: Bool {
        menuPopoverVisible || menuSelectedMetrics.contains(.heartRate)
    }

    private var menuNeedsDisplayRefresh: Bool {
        menuPopoverVisible || menuSelectedMetrics.contains(.refresh)
    }

    private var menuNeedsLiveRefresh: Bool {
        !appIsActive && !menuSelectedMetrics.isEmpty
    }

    private var helperConsumerActive: Bool {
        appIsActive || menuPopoverVisible
    }

    private func setHelperControlIfNeeded(previousActive: Bool, previousPopover: Bool) {
        if previousActive != appIsActive || previousPopover != menuPopoverVisible {
            writeAdvancedSamplingControl(currentPreset)
        }
    }

    private var currentPreset: SamplingPreset {
        SamplingPreset.allCases.first { $0.interval == samplingInterval } ?? .live
    }

    private var effectiveSamplingInterval: TimeInterval {
        if UserDefaults.standard.bool(forKey: "bcgHeartRateEnabled"), liveConsumerActive { return min(samplingInterval, 0.5) }
        if menuPopoverVisible { return max(samplingInterval, 1.0) }
        if !appIsActive { return menuNeedsLiveRefresh ? menuBarRefreshInterval : 60.0 }
        if isRealtimeDetailSection { return samplingInterval }
        return max(samplingInterval, 1.5)
    }

    private func writeAdvancedSamplingControl(_ preset: SamplingPreset) {
        let bcgEnabled = UserDefaults.standard.bool(forKey: "bcgHeartRateEnabled")
        let pythonEnabled = UserDefaults.standard.bool(forKey: pythonBackendKey)
        let helperEnabled = helperConsumerActive && pythonEnabled
        let helperIntervalMS = helperEnabled
            ? (bcgEnabled ? min(preset.helperIntervalMS, 2_000) : preset.helperIntervalMS)
            : 60_000
        let payload: [String: Any] = [
            "profile": helperEnabled ? preset.profileName : SamplingPreset.quiet.profileName,
            "helper_enabled": helperEnabled,
            "helper_interval_ms": helperIntervalMS,
            "bcg_heart_rate_enabled": helperEnabled && bcgEnabled,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: "/tmp/stellarscope-control.json"), options: [.atomic])
    }

    private func sampleOnce() async {
        let cores = cpu.sample()
        let mem = memory.sample()
        let therm = thermal.sample()
        let pythonEnabled = UserDefaults.standard.bool(forKey: pythonBackendKey)
        var pm = helperConsumerActive && pythonEnabled ? powermetrics.sample() : nativePowerMetricsSnapshot(maxAge: liveConsumerActive ? 0 : menuBarRefreshInterval)
        mergeNativeSensors(into: &pm, includePower: pythonEnabled)
        let refreshMeasurementEnabled = UserDefaults.standard.bool(forKey: "displayRefreshMeasurementEnabled")
        let refresh = displayRefresh.sample(active: appIsActive && refreshMeasurementEnabled && visibleSectionID == "Displays")
        let snap = SystemSnapshot(timestamp: Date(), cores: cores, memory: mem, thermal: therm, powermetrics: pm, displayRefresh: refresh)
        snapshot = snap
        if appIsActive {
            push(&cpuHistory, value: snap.cpuActiveAverage, limit: 120)
            push(&memoryHistory, value: snap.memory.usedRatio, limit: 120)
            pushOptional(&lidAngleHistory, value: sensorNumber("motion.lid_angle_degrees", in: snap).map { min(1, max(0, $0 / 135.0)) }, limit: 180)
            pushOptional(&ambientLightHistory, value: sensorNumber("environment.spu_ambient_lux", in: snap).map { min(1, max(0, $0 / 1000.0)) }, limit: 180)
            for index in 0..<alsChromaHistories.count {
                pushOptional(&alsChromaHistories[index], value: sensorNumber("environment.als_chroma_\(index)", in: snap).map { min(1, max(0, $0 / 100.0)) }, limit: 180)
            }
            pushOptional(&bcgHeartRateHistory, value: sensorNumber("motion.bcg_heart_rate_bpm", in: snap).map { min(1, max(0, $0 / 200.0)) }, limit: 180)
        }
    }

    private func mergeNativeSensors(into powermetrics: inout PowerMetricsSnapshot, includePower: Bool) {
        let localSensors: [SensorMetric]
        if appIsActive {
            localSensors = nativeAdvanced.sample(maxAge: nativeAdvancedMaxAge)
                + (includePower ? nativePower.sample() : [])
                + nativeInventory.sample(maxAge: nativeInventoryMaxAge)
                + environment.sample(liveMaxAge: nativeRealtimeMaxAge)
        } else if menuPopoverVisible {
            localSensors = nativeAdvanced.sample(maxAge: 5.0)
                + nativePower.sample(maxAge: 5.0)
                + nativeInventory.sample(maxAge: 60.0)
                + environment.sample(liveMaxAge: 3.0)
        } else if menuNeedsLiveRefresh {
            localSensors = nativePower.sample(maxAge: menuBarRefreshInterval)
                + (menuNeedsNativeAdvanced ? nativeAdvanced.sample(maxAge: max(5.0, menuBarRefreshInterval)) : [])
                + (menuNeedsEnvironment ? environment.sample(liveMaxAge: max(5.0, menuBarRefreshInterval)) : [])
        } else {
            localSensors = nativePower.sample(maxAge: 60.0)
        }
        guard !localSensors.isEmpty else { return }
        var positions: [String: Int] = [:]
        for (index, sensor) in powermetrics.sensors.enumerated() {
            positions[sensor.id] = index
        }
        for sensor in localSensors {
            if let index = positions[sensor.id] {
                powermetrics.sensors[index] = sensor
            } else {
                positions[sensor.id] = powermetrics.sensors.count
                powermetrics.sensors.append(sensor)
            }
        }
        applyNativeAdvancedSummary(from: powermetrics.sensors, to: &powermetrics)
    }

    private func applyNativeAdvancedSummary(from sensors: [SensorMetric], to snapshot: inout PowerMetricsSnapshot) {
        snapshot.cpuPowerMW = snapshot.cpuPowerMW ?? firstNumber(["native.ioreport.cpu_power_mw"], in: sensors)
        snapshot.gpuPowerMW = snapshot.gpuPowerMW ?? firstNumber(["native.ioreport.gpu_power_mw"], in: sensors)
        snapshot.anePowerMW = snapshot.anePowerMW ?? firstNumber(["native.ioreport.ane_power_mw"], in: sensors)
        snapshot.dramPowerMW = snapshot.dramPowerMW ?? firstNumber(["native.ioreport.dram_power_mw"], in: sensors)
        snapshot.eClusterPowerMW = snapshot.eClusterPowerMW ?? firstNumber(["native.ioreport.e_cluster_power_mw"], in: sensors)
        snapshot.pClusterPowerMW = snapshot.pClusterPowerMW ?? firstNumber(["native.ioreport.p_cluster_power_mw"], in: sensors)
        snapshot.packagePowerMW = snapshot.packagePowerMW ?? firstNumber(["native.ioreport.package_power_mw"], in: sensors)
        snapshot.combinedPowerMW = snapshot.combinedPowerMW ?? snapshot.packagePowerMW
        snapshot.cpuDieTemperatureC = snapshot.cpuDieTemperatureC
            ?? firstNumber(["native.smc.cpu_die_temperature_c", "native.smc.cpu_performance_temperature_c", "native.smc.cpu_proximity_temperature_c"], in: sensors)
            ?? bestTemperature(matching: ["cpu", "tc"], in: sensors)
            ?? bestTemperature(matching: ["soc", "tp"], in: sensors)
            ?? hottestTemperature(in: sensors)
        snapshot.gpuDieTemperatureC = snapshot.gpuDieTemperatureC
            ?? firstNumber(["native.smc.gpu_die_temperature_c", "native.smc.gpu_proximity_temperature_c"], in: sensors)
            ?? bestTemperature(matching: ["gpu", "tg"], in: sensors)
            ?? bestTemperature(matching: ["soc", "tp"], in: sensors)
            ?? hottestTemperature(in: sensors)
        snapshot.fanRPM = snapshot.fanRPM ?? firstNumber(["native.smc.fan_rpm", "smc.fan0.rpm"], in: sensors)
        snapshot.cpuFrequencyHz = snapshot.cpuFrequencyHz
            ?? firstNumber(["native.ioreport.cpu_frequency_hz", "native.sysctl.cpu_frequency_hz", "native.sysctl.cpu_frequency_max_hz"], in: sensors)
        snapshot.eClusterFrequencyHz = snapshot.eClusterFrequencyHz ?? firstNumber(["native.ioreport.e_cluster_frequency_hz"], in: sensors)
        snapshot.pClusterFrequencyHz = snapshot.pClusterFrequencyHz ?? firstNumber(["native.ioreport.p_cluster_frequency_hz"], in: sensors)
        snapshot.gpuFrequencyHz = snapshot.gpuFrequencyHz ?? firstNumber(["native.ioreport.gpu_frequency_hz"], in: sensors)
        snapshot.gpuResidencyPercent = snapshot.gpuResidencyPercent ?? firstNumber(["native.ioreport.gpu_residency_percent"], in: sensors)
    }

    private func nativePowerMetricsSnapshot(maxAge: TimeInterval = 0) -> PowerMetricsSnapshot {
        let timestamp = Date()
        let sensors = nativePower.sample(maxAge: maxAge)
        let systemInput = sensorNumber("system.input_power_mw", in: sensors)
        return PowerMetricsSnapshot(
            available: !sensors.isEmpty,
            timestamp: timestamp,
            source: "native",
            status: "Python advanced backend disabled",
            combinedPowerMW: systemInput,
            rawCount: 1,
            rawFields: [RawMetric(key: "backend.python.enabled", value: "false")],
            sensors: sensors
        )
    }

    private var nativeRealtimeMaxAge: TimeInterval {
        if !appIsActive { return 5.0 }
        if !isRealtimeDetailSection { return 3.0 }
        switch currentPreset {
        case .quiet: return 2.0
        case .live: return 1.0
        case .bench: return 0.5
        }
    }

    private var nativeInventoryMaxAge: TimeInterval {
        if !appIsActive { return 300.0 }
        switch visibleSectionID {
        case "Displays", "Storage", "Audio", "Bus & I/O":
            return 30.0
        default:
            return 180.0
        }
    }

    private var nativeAdvancedMaxAge: TimeInterval {
        if !appIsActive { return 15.0 }
        switch visibleSectionID {
        case "Thermal & Fans", "Power & Battery", "Compute", "Overview":
            return 3.0
        default:
            return 8.0
        }
    }

    private var isRealtimeDetailSection: Bool {
        visibleSectionID == "Sensor Lab" || visibleSectionID == "Environment" || visibleSectionID == "Power & Battery"
            || visibleSectionID == "Displays" || visibleSectionID == "Storage" || visibleSectionID == "Audio" || visibleSectionID == "Bus & I/O"
    }

    private func push(_ array: inout [Double], value: Double, limit: Int) {
        array.append(value)
        if array.count > limit { array.removeFirst(array.count - limit) }
    }

    private func pushOptional(_ array: inout [Double], value: Double?, limit: Int) {
        guard let value else { return }
        push(&array, value: value, limit: limit)
    }

    private func sensorNumber(_ id: String, in snapshot: SystemSnapshot) -> Double? {
        guard let value = snapshot.powermetrics.sensors.first(where: { $0.id == id })?.value else { return nil }
        return Double(value)
    }

    private func sensorNumber(_ id: String, in sensors: [SensorMetric]) -> Double? {
        guard let value = sensors.first(where: { $0.id == id })?.value else { return nil }
        return Double(value)
    }

    private func firstNumber(_ ids: [String], in sensors: [SensorMetric]) -> Double? {
        for id in ids {
            if let value = sensorNumber(id, in: sensors) { return value }
        }
        return nil
    }

    private func bestTemperature(matching needles: [String], in sensors: [SensorMetric]) -> Double? {
        let lowerNeedles = needles.map { $0.lowercased() }
        return temperatureCandidates(in: sensors)
            .filter { candidate in
                lowerNeedles.contains { needle in
                    candidate.id.contains(needle) || candidate.title.contains(needle) || candidate.rawKey.contains(needle)
                }
            }
            .map(\.value)
            .max()
    }

    private func hottestTemperature(in sensors: [SensorMetric]) -> Double? {
        temperatureCandidates(in: sensors).map(\.value).max()
    }

    private func temperatureCandidates(in sensors: [SensorMetric]) -> [(id: String, title: String, rawKey: String, value: Double)] {
        sensors.compactMap { sensor in
            let id = sensor.id.lowercased()
            let title = sensor.title.lowercased()
            let rawKey = sensor.rawKey.lowercased()
            guard sensor.category.localizedCaseInsensitiveContains("temperature")
                    || sensor.unit == "C"
                    || id.contains("temperature")
                    || title.contains("temperature") else {
                return nil
            }
            guard let value = Double(sensor.value), value >= 5, value < 140 else { return nil }
            return (id, title, rawKey, value)
        }
    }
}

enum SamplingPreset: String, CaseIterable, Identifiable, Hashable {
    case quiet = "Quiet"
    case live = "Live"
    case bench = "Bench"

    var id: String { rawValue }
    var interval: TimeInterval {
        switch self {
        case .quiet: return 2.0
        case .live: return 1.0
        case .bench: return 0.25
        }
    }

    var helperIntervalMS: Int {
        switch self {
        case .quiet: return 15_000
        case .live: return 5_000
        case .bench: return 1_000
        }
    }

    var profileName: String { rawValue.lowercased() }
}
