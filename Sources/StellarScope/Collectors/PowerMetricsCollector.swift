import Foundation

final class PowerMetricsCollector {
    private let url = URL(fileURLWithPath: "/tmp/stellarscope-powermetrics.json")
    private var cachedModificationDate: Date?
    private var cachedFileSize: UInt64 = 0
    private var cachedSnapshot: PowerMetricsSnapshot?

    func sample() -> PowerMetricsSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PowerMetricsSnapshot(available: false, error: "Advanced helper has not produced /tmp/stellarscope-powermetrics.json yet.")
        }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let modDate = attrs[.modificationDate] as? Date
            let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            if cachedModificationDate == modDate,
               cachedFileSize == fileSize,
               let cachedSnapshot {
                return cachedSnapshot
            }

            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let json else { return PowerMetricsSnapshot(available: false, error: "Invalid JSON from advanced helper.") }

            let summary = json["summary"] as? [String: Any] ?? [:]
            let flat = json["flat"] as? [String: Any] ?? [:]
            let sensors = makeSensors(from: json["sensors"] as? [[String: Any]] ?? [], fallbackDate: parseDate(json["timestamp"] as? String) ?? Date())
            let rawFields = makeRawFields(from: flat)
            let error = json["error"] as? String
            let hasUsableData = !summary.isEmpty || !sensors.isEmpty || (error == nil && !flat.isEmpty)

            let snapshot = PowerMetricsSnapshot(
                available: hasUsableData,
                timestamp: parseDate(json["timestamp"] as? String) ?? Date(),
                source: json["source"] as? String,
                samplers: json["samplers"] as? String,
                status: json["status"] as? String,
                error: error,
                pid: number(json["pid"]).map { Int($0) },
                cpuPowerMW: number(summary["cpu_power_mw"]),
                gpuPowerMW: number(summary["gpu_power_mw"]),
                anePowerMW: number(summary["ane_power_mw"]),
                combinedPowerMW: number(summary["combined_power_mw"]),
                packagePowerMW: number(summary["package_power_mw"]),
                dramPowerMW: number(summary["dram_power_mw"]),
                eClusterPowerMW: number(summary["e_cluster_power_mw"]),
                pClusterPowerMW: number(summary["p_cluster_power_mw"]),
                cpuFrequencyHz: number(summary["cpu_frequency_hz"]),
                eClusterFrequencyHz: number(summary["e_cluster_frequency_hz"]),
                pClusterFrequencyHz: number(summary["p_cluster_frequency_hz"]),
                gpuFrequencyHz: number(summary["gpu_frequency_hz"]),
                gpuResidencyPercent: number(summary["gpu_residency_percent"]),
                thermalPressure: summary["thermal_pressure"] as? String ?? string(summary["thermal_pressure"]),
                cpuDieTemperatureC: number(summary["cpu_die_temperature_c"]),
                gpuDieTemperatureC: number(summary["gpu_die_temperature_c"]),
                cpuThermalLevel: number(summary["cpu_thermal_level"]),
                gpuThermalLevel: number(summary["gpu_thermal_level"]),
                fanRPM: number(summary["fan_rpm"]),
                rawCount: flat.count,
                rawFields: rawFields,
                sensors: sensors
            )
            cachedModificationDate = modDate
            cachedFileSize = fileSize
            cachedSnapshot = snapshot
            return snapshot
        } catch {
            return PowerMetricsSnapshot(available: false, error: error.localizedDescription)
        }
    }

    private func makeRawFields(from flat: [String: Any]) -> [RawMetric] {
        flat.keys.sorted().prefix(500).map { key in
            RawMetric(key: key, value: string(flat[key]) ?? "")
        }
    }

    private func makeSensors(from rows: [[String: Any]], fallbackDate: Date) -> [SensorMetric] {
        rows.compactMap { row in
            guard let id = string(row["id"]), !id.isEmpty else { return nil }
            let rawTimestamp = parseDate(string(row["timestamp"])) ?? fallbackDate
            return SensorMetric(
                id: id,
                title: string(row["title"]) ?? id,
                category: string(row["category"]) ?? "Raw",
                value: displayString(row["value"]),
                unit: string(row["unit"]) ?? "",
                source: string(row["source"]) ?? "unknown",
                quality: string(row["quality"]) ?? "ok",
                rawKey: string(row["rawKey"]) ?? string(row["raw_key"]) ?? "",
                timestamp: rawTimestamp,
                isExperimental: bool(row["isExperimental"]) ?? bool(row["is_experimental"]) ?? false
            )
        }
    }

    private func number(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Float { return Double(v) }
        if let v = value as? Int { return Double(v) }
        if let v = value as? Int64 { return Double(v) }
        if let v = value as? UInt64 { return Double(v) }
        if let v = value as? String { return numberFromString(v) }
        return nil
    }

    private func numberFromString(_ text: String) -> Double? {
        let pattern = "[-+]?[0-9]*\\.?[0-9]+"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return Double(text[range])
    }

    private func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let value = value as? String { return value }
        return "\(value)"
    }

    private func displayString(_ value: Any?) -> String {
        guard let value else { return "—" }
        if let v = value as? Double { return String(format: "%.2f", v) }
        if let v = value as? Float { return String(format: "%.2f", Double(v)) }
        if let v = value as? Int { return "\(v)" }
        if let v = value as? Int64 { return "\(v)" }
        if let v = value as? UInt64 { return "\(v)" }
        if let v = value as? Bool { return v ? "yes" : "no" }
        return "\(value)"
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
