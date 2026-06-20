import Foundation
import SwiftUI

struct CoreLoad: Identifiable, Hashable {
    let id: Int
    let user: Double
    let system: Double
    let nice: Double
    let idle: Double

    var active: Double { max(0, min(1, user + system + nice)) }
    var label: String { "C\(id)" }
}

struct RawMetric: Identifiable, Hashable, Equatable {
    var id: String { key }
    let key: String
    let value: String
}

struct SensorMetric: Identifiable, Hashable, Equatable {
    let id: String
    let title: String
    let category: String
    let value: String
    let unit: String
    let source: String
    let quality: String
    let rawKey: String
    let timestamp: Date
    let isExperimental: Bool

    var displayValue: String {
        guard let number = Double(value) else {
            return unit.isEmpty ? value : "\(value) \(unit)"
        }
        switch unit {
        case "mW":
            return number >= 1000 ? String(format: "%.2f W", number / 1000.0) : String(format: "%.0f mW", number)
        case "Hz":
            if number >= 1_000_000_000 { return String(format: "%.2f GHz", number / 1_000_000_000) }
            if number >= 1_000_000 { return String(format: "%.0f MHz", number / 1_000_000) }
            if number >= 1_000 { return String(format: "%.0f kHz", number / 1_000) }
            return String(format: "%.0f Hz", number)
        case "mV":
            return number >= 1000 ? String(format: "%.2f V", number / 1000.0) : String(format: "%.0f mV", number)
        case "mA":
            return number >= 1000 ? String(format: "%.2f A", number / 1000.0) : String(format: "%.0f mA", number)
        case "B":
            return UInt64(max(0, number)).humanBytes
        case "C":
            return String(format: "%.1f C", number)
        case "%":
            return String(format: "%.1f%%", number)
        case "rpm":
            return String(format: "%.0f rpm", number)
        case "bpm":
            return String(format: "%.0f bpm", number)
        case "px":
            return String(format: "%.0f", number)
        case "ch":
            return String(format: "%.0f ch", number)
        case "lx":
            return String(format: "%.0f lx", number)
        case "us":
            return String(format: "%.0f us", number)
        default:
            return unit.isEmpty ? value : "\(value) \(unit)"
        }
    }
}

struct DisplayRefreshSnapshot: Equatable {
    var measuredHz: Double?
    var nominalHz: Double?
    var actualHz: Double?
    var modeHz: Double?
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var logicalWidth: Int = 0
    var logicalHeight: Int = 0
    var timestamp = Date()
}

struct MemorySnapshot: Equatable {
    var totalBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var activeBytes: UInt64 = 0
    var inactiveBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var purgeableBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var timestamp = Date()

    var usedBytes: UInt64 {
        // Not exactly Activity Monitor's formula; designed for trend monitoring.
        min(totalBytes, activeBytes + wiredBytes + compressedBytes)
    }

    var appLikeBytes: UInt64 {
        activeBytes
    }

    var cacheEstimateBytes: UInt64 {
        inactiveBytes + purgeableBytes
    }

    var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    var swapRatio: Double {
        guard swapTotalBytes > 0 else { return 0 }
        return Double(swapUsedBytes) / Double(swapTotalBytes)
    }
}

struct PublicThermalSnapshot: Equatable {
    var rawValue: Int
    var label: String
    var timestamp = Date()
}

struct PowerMetricsSnapshot: Equatable {
    var available: Bool = false
    var timestamp: Date = Date()
    var source: String?
    var samplers: String?
    var status: String?
    var error: String?
    var pid: Int?

    var cpuPowerMW: Double?
    var gpuPowerMW: Double?
    var anePowerMW: Double?
    var combinedPowerMW: Double?
    var packagePowerMW: Double?
    var dramPowerMW: Double?
    var eClusterPowerMW: Double?
    var pClusterPowerMW: Double?

    var cpuFrequencyHz: Double?
    var eClusterFrequencyHz: Double?
    var pClusterFrequencyHz: Double?
    var gpuFrequencyHz: Double?
    var gpuResidencyPercent: Double?

    var thermalPressure: String?
    var cpuDieTemperatureC: Double?
    var gpuDieTemperatureC: Double?
    var cpuThermalLevel: Double?
    var gpuThermalLevel: Double?
    var fanRPM: Double?

    var rawCount: Int = 0
    var rawFields: [RawMetric] = []
    var sensors: [SensorMetric] = []
}

struct SystemSnapshot: Equatable {
    var timestamp = Date()
    var cores: [CoreLoad] = []
    var memory = MemorySnapshot()
    var thermal = PublicThermalSnapshot(rawValue: 0, label: "nominal")
    var powermetrics = PowerMetricsSnapshot()
    var displayRefresh = DisplayRefreshSnapshot()

    var cpuActiveAverage: Double {
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0) { $0 + $1.active } / Double(cores.count)
    }

    var cpuUserAverage: Double {
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0) { $0 + $1.user } / Double(cores.count)
    }

    var cpuSystemAverage: Double {
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0) { $0 + $1.system } / Double(cores.count)
    }

    var cpuIdleAverage: Double {
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0) { $0 + $1.idle } / Double(cores.count)
    }
}

extension UInt64 {
    var humanBytes: String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(self)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index <= 1 { return "\(Int(value)) \(units[index])" }
        return String(format: "%.1f %@", value, units[index])
    }
}

extension Double {
    var percentText: String { String(format: "%.0f%%", self * 100) }
    var oneDecimal: String { String(format: "%.1f", self) }
}
