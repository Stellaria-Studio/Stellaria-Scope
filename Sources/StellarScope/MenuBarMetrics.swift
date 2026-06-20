import Foundation

enum MenuBarMetric: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case swap
    case thermal
    case battery
    case cpuPower
    case gpu
    case fan
    case heartRate
    case refresh
    case sensors

    static let defaults: [MenuBarMetric] = [.cpu, .memory]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .swap: return "Swap"
        case .thermal: return "Thermal"
        case .battery: return "Battery"
        case .cpuPower: return "CPU Power"
        case .gpu: return "GPU"
        case .fan: return "Fan"
        case .heartRate: return "Heart Rate"
        case .refresh: return "Refresh"
        case .sensors: return "Sensors"
        }
    }

    var shortTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "M"
        case .swap: return "S"
        case .thermal: return "T"
        case .battery: return "B"
        case .cpuPower: return "W"
        case .gpu: return "G"
        case .fan: return "F"
        case .heartRate: return "HR"
        case .refresh: return "Hz"
        case .sensors: return "#"
        }
    }

    var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .swap: return "arrow.triangle.2.circlepath"
        case .thermal: return "thermometer.medium"
        case .battery: return "battery.100percent"
        case .cpuPower: return "bolt"
        case .gpu: return "display"
        case .fan: return "fan"
        case .heartRate: return "heart.text.square"
        case .refresh: return "gauge.with.dots.needle.67percent"
        case .sensors: return "sensor"
        }
    }

    func menuBarValue(from snapshot: SystemSnapshot) -> String {
        switch self {
        case .cpu:
            return String(format: "%.0f%%", snapshot.cpuActiveAverage * 100)
        case .memory:
            return snapshot.memory.usedBytes.humanBytes
        case .swap:
            return snapshot.memory.swapUsedBytes.humanBytes
        case .thermal:
            return snapshot.thermal.label
        case .battery:
            return sensor("battery.charge_percent", in: snapshot)?.displayValue.replacingOccurrences(of: ".0%", with: "%") ?? "—"
        case .cpuPower:
            return watts(snapshot.powermetrics.cpuPowerMW)
        case .gpu:
            if let residency = snapshot.powermetrics.gpuResidencyPercent {
                return String(format: "%.0f%%", residency)
            }
            return watts(snapshot.powermetrics.gpuPowerMW)
        case .fan:
            guard let fan = snapshot.powermetrics.fanRPM else { return "—" }
            return String(format: "%.0f rpm", fan)
        case .heartRate:
            return heartRate(in: snapshot)
        case .refresh:
            let hz = snapshot.displayRefresh.measuredHz ?? snapshot.displayRefresh.actualHz ?? snapshot.displayRefresh.modeHz
            guard let hz else { return "—" }
            return String(format: "%.0f Hz", hz)
        case .sensors:
            return "\(snapshot.powermetrics.sensors.count)"
        }
    }

    func value(from snapshot: SystemSnapshot) -> String {
        switch self {
        case .cpu:
            return snapshot.cpuActiveAverage.percentText
        case .memory:
            return snapshot.memory.usedBytes.humanBytes
        case .swap:
            return snapshot.memory.swapUsedBytes.humanBytes
        case .thermal:
            return snapshot.thermal.label
        case .battery:
            return sensor("battery.charge_percent", in: snapshot)?.displayValue ?? "—"
        case .cpuPower:
            return watts(snapshot.powermetrics.cpuPowerMW)
        case .gpu:
            if let residency = snapshot.powermetrics.gpuResidencyPercent {
                return String(format: "%.0f%%", residency)
            }
            return watts(snapshot.powermetrics.gpuPowerMW)
        case .fan:
            guard let fan = snapshot.powermetrics.fanRPM else { return "—" }
            return String(format: "%.0f rpm", fan)
        case .heartRate:
            return heartRate(in: snapshot)
        case .refresh:
            let hz = snapshot.displayRefresh.measuredHz ?? snapshot.displayRefresh.actualHz ?? snapshot.displayRefresh.modeHz
            guard let hz else { return "—" }
            return String(format: "%.0f Hz", hz)
        case .sensors:
            return "\(snapshot.powermetrics.sensors.count)"
        }
    }

    private func sensor(_ id: String, in snapshot: SystemSnapshot) -> SensorMetric? {
        snapshot.powermetrics.sensors.first { $0.id == id }
    }

    private func heartRate(in snapshot: SystemSnapshot) -> String {
        sensor("motion.bcg_heart_rate_bpm", in: snapshot)?.displayValue ?? "—"
    }

    private func watts(_ milliwatts: Double?) -> String {
        guard let milliwatts else { return "—" }
        if milliwatts >= 1000 {
            return String(format: "%.1f W", milliwatts / 1000.0)
        }
        return String(format: "%.0f mW", milliwatts)
    }

    private func compactWatts(_ milliwatts: Double?) -> String {
        guard let milliwatts else { return "—" }
        if milliwatts >= 1000 {
            return String(format: "%.1fW", milliwatts / 1000.0)
        }
        return String(format: "%.0fmW", milliwatts)
    }

    private func compactBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        if gib >= 10 {
            return String(format: "%.0fG", gib)
        }
        if gib >= 1 {
            return String(format: "%.1fG", gib)
        }
        let mib = Double(bytes) / 1024.0 / 1024.0
        return String(format: "%.0fM", mib)
    }

    private func compactThermal(_ label: String) -> String {
        switch label.lowercased() {
        case "nominal": return "nom"
        case "fair": return "fair"
        case "serious": return "hot"
        case "critical": return "crit"
        default: return label
        }
    }
}

struct MenuBarMetricSelection {
    private static let separator = ","

    static var defaultRawValue: String {
        MenuBarMetric.defaults.map(\.rawValue).joined(separator: separator)
    }

    static func metrics(from rawValue: String) -> [MenuBarMetric] {
        let parsed = rawValue
            .split(separator: Character(separator))
            .compactMap { MenuBarMetric(rawValue: String($0)) }
        return parsed.isEmpty ? MenuBarMetric.defaults : parsed
    }

    static func contains(_ metric: MenuBarMetric, in rawValue: String) -> Bool {
        metrics(from: rawValue).contains(metric)
    }

    static func rawValue(_ rawValue: String, setting metric: MenuBarMetric, enabled: Bool) -> String {
        var metrics = Self.metrics(from: rawValue)
        if enabled {
            if !metrics.contains(metric) {
                metrics.append(metric)
            }
        } else {
            metrics.removeAll { $0 == metric }
        }
        if metrics.isEmpty {
            metrics = [.cpu]
        }
        return metrics.map(\.rawValue).joined(separator: separator)
    }
}
