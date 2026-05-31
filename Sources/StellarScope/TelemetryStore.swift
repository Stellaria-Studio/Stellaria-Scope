import Foundation
import SwiftUI

@MainActor
final class TelemetryStore: ObservableObject {
    @Published var snapshot = SystemSnapshot()
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var samplingInterval: TimeInterval = 1.0

    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let thermal = ThermalCollector()
    private let powermetrics = PowerMetricsCollector()
    private let displayRefresh = DisplayRefreshCollector()
    private let environment = EnvironmentCollector()
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce()
                let ns = UInt64((self?.samplingInterval ?? 1.0) * 1_000_000_000)
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

    private func writeAdvancedSamplingControl(_ preset: SamplingPreset) {
        let payload: [String: Any] = [
            "profile": preset.profileName,
            "helper_interval_ms": preset.helperIntervalMS,
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
        var pm = powermetrics.sample()
        mergeLocalEnvironmentSensors(into: &pm)
        let refresh = displayRefresh.sample()
        let snap = SystemSnapshot(timestamp: Date(), cores: cores, memory: mem, thermal: therm, powermetrics: pm, displayRefresh: refresh)
        snapshot = snap
        push(&cpuHistory, value: snap.cpuActiveAverage, limit: 120)
        push(&memoryHistory, value: snap.memory.usedRatio, limit: 120)
    }

    private func mergeLocalEnvironmentSensors(into powermetrics: inout PowerMetricsSnapshot) {
        let localSensors = environment.sample()
        guard !localSensors.isEmpty else { return }
        var existingIDs = Set(powermetrics.sensors.map(\.id))
        for sensor in localSensors where !existingIDs.contains(sensor.id) {
            powermetrics.sensors.append(sensor)
            existingIDs.insert(sensor.id)
        }
    }

    private func push(_ array: inout [Double], value: Double, limit: Int) {
        array.append(value)
        if array.count > limit { array.removeFirst(array.count - limit) }
    }
}

enum SamplingPreset: String, CaseIterable, Identifiable {
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
        case .quiet: return 2_000
        case .live: return 1_000
        case .bench: return 250
        }
    }

    var profileName: String { rawValue.lowercased() }
}
