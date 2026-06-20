import Foundation

final class EnvironmentCollector: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.lmz.StellarScope.EnvironmentCollector.state")
    private let nativeSPU = NativeSPUHIDCollector()
    private var cachedSensors: [SensorMetric] = []
    private var liveSensors: [SensorMetric] = []
    private var bcgSensors: [SensorMetric] = []
    private var lastRefresh = Date.distantPast
    private var lastLiveRefresh = Date.distantPast
    private var lastBCGRefresh = Date.distantPast
    private var isRefreshing = false
    private var isLiveRefreshing = false
    private var isBCGRefreshing = false

    func sample(maxAge: TimeInterval = 8.0, liveMaxAge: TimeInterval = 1.0) -> [SensorMetric] {
        let bcgEnabled = UserDefaults.standard.bool(forKey: "bcgHeartRateEnabled")
        let state = stateQueue.sync { () -> (sensors: [SensorMetric], shouldRefresh: Bool, shouldRefreshLive: Bool, shouldRefreshBCG: Bool) in
            let shouldRefresh = !isRefreshing && Date().timeIntervalSince(lastRefresh) > maxAge
            let shouldRefreshLive = !isLiveRefreshing && Date().timeIntervalSince(lastLiveRefresh) > liveMaxAge
            let shouldRefreshBCG = bcgEnabled && !isBCGRefreshing && Date().timeIntervalSince(lastBCGRefresh) > 5.0
            if shouldRefresh {
                isRefreshing = true
            }
            if shouldRefreshLive {
                isLiveRefreshing = true
            }
            if shouldRefreshBCG {
                isBCGRefreshing = true
            }
            let withoutBCG = bcgEnabled ? bcgSensors : disabledBCGSensors()
            return (merged(merged(cachedSensors, replacingWith: liveSensors), replacingWith: withoutBCG), shouldRefresh, shouldRefreshLive, shouldRefreshBCG)
        }

        if state.shouldRefresh {
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let fresh = self.collectFreshSample()
                self.stateQueue.async {
                    self.cachedSensors = fresh
                    self.lastRefresh = Date()
                    self.isRefreshing = false
                }
            }
        }

        if state.shouldRefreshLive {
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let fresh = self.nativeSPU.sample()
                self.stateQueue.async {
                    self.liveSensors = fresh
                    self.lastLiveRefresh = Date()
                    self.isLiveRefreshing = false
                }
            }
        }

        if state.shouldRefreshBCG {
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let fresh = self.nativeSPU.sampleBCG()
                self.stateQueue.async {
                    self.bcgSensors = fresh
                    self.lastBCGRefresh = Date()
                    self.isBCGRefreshing = false
                }
            }
        }

        return state.sensors
    }

    private func disabledBCGSensors() -> [SensorMetric] {
        [SensorMetric(
            id: "motion.bcg_heart_rate_status",
            title: "BCG Heart Rate Status",
            category: "Motion",
            value: "disabled for low-power monitoring",
            unit: "",
            source: "NativeSPUHID",
            quality: "ok",
            rawKey: "native.spu_hid.bcg_status",
            timestamp: Date(),
            isExperimental: true
        )]
    }

    private func collectFreshSample() -> [SensorMetric] {
        let timestamp = Date()
        var sensors: [SensorMetric] = []
        let spuDevices = ioregPlist(className: "AppleSPUHIDDriver", timeout: 4)
        let alsDevices = ioregPlist(className: "AppleALSColorSensor", timeout: 4)
        let rootDomain = registryProperties(for: "IOPMrootDomain").map { [$0] } ?? ioregPlist(className: "IOPMrootDomain", timeout: 3)

        append(&sensors, id: "motion.spu_device_count", title: "SPU HID Device Count", category: "Motion", value: spuDevices.count, unit: "", source: "IORegistry", rawKey: "AppleSPUHIDDriver", timestamp: timestamp)

        for (friendly, prefix) in [
            ("Accelerometer", "motion.accelerometer"),
            ("Gyroscope", "motion.gyroscope"),
            ("Hall / Lid Angle", "motion.hall"),
            ("Temperature", "motion.spu_temperature")
        ] {
            guard let device = firstSPUDevice(in: spuDevices, named: friendly) else {
                append(&sensors, id: "\(prefix).available", title: "\(friendly) Available", category: "Motion", value: false, unit: "", source: "IORegistry", rawKey: "DeviceUsagePairs", timestamp: timestamp)
                continue
            }

            let debug = dictionary(device["DebugState"])
            let voltage = dictionary(device["AppleVoltageDictionary"])
            append(&sensors, id: "\(prefix).available", title: "\(friendly) Available", category: "Motion", value: true, unit: "", source: "IORegistry", rawKey: "DeviceUsagePairs", timestamp: timestamp)
            append(&sensors, id: "\(prefix).model", title: "\(friendly) Model", category: "Motion", value: device["model"], unit: "", source: "IORegistry", rawKey: "model", timestamp: timestamp)
            append(&sensors, id: "\(prefix).manufacturer", title: "\(friendly) Manufacturer", category: "Motion", value: device["manufacturer"] ?? device["Manufacturer"], unit: "", source: "IORegistry", rawKey: "manufacturer", timestamp: timestamp)
            append(&sensors, id: "\(prefix).rates", title: "\(friendly) Rates", category: "Motion", value: device["sensor_rates"], unit: "", source: "IORegistry", rawKey: "sensor_rates", timestamp: timestamp)
            append(&sensors, id: "\(prefix).calibration", title: "\(friendly) Calibration", category: "Motion", value: number(device["calibration_state"]), unit: "", source: "IORegistry", rawKey: "calibration_state", timestamp: timestamp)
            append(&sensors, id: "\(prefix).restricted", title: "\(friendly) Restricted", category: "Motion", value: device["motionRestrictedService"], unit: "", source: "IORegistry", rawKey: "motionRestrictedService", timestamp: timestamp)
            append(&sensors, id: "\(prefix).events", title: "\(friendly) Events", category: "Motion", value: number(debug["_num_events"]), unit: "", source: "IORegistry", rawKey: "DebugState._num_events", timestamp: timestamp)
            append(&sensors, id: "\(prefix).report_interval_us", title: "\(friendly) Report Interval", category: "Motion", value: number(device["ReportInterval"]), unit: "us", source: "IORegistry", rawKey: "ReportInterval", timestamp: timestamp)

            for (key, value) in voltage.sorted(by: { $0.key < $1.key }) {
                append(&sensors, id: "\(prefix).\(safeID(key))", title: "\(friendly) \(key)", category: "Motion", value: number(value), unit: "", source: "IORegistry", rawKey: "AppleVoltageDictionary.\(key)", timestamp: timestamp, isExperimental: true)
            }
        }

        let als = firstSPUDevice(in: spuDevices, named: "Ambient Light") ?? alsDevices.first
        if let als {
            let debug = dictionary(als["DebugState"])
            append(&sensors, id: "environment.ambient_lux", title: "Ambient Light", category: "Environment", value: number(als["CurrentLux"]), unit: "lx", source: "AppleALSColorSensor", rawKey: "CurrentLux", timestamp: timestamp)
            append(&sensors, id: "environment.als_sensor_type", title: "ALS Sensor Type", category: "Environment", value: number(als["ALSSensorType"]), unit: "", source: "AppleALSColorSensor", rawKey: "ALSSensorType", timestamp: timestamp)
            append(&sensors, id: "environment.als_report_interval_us", title: "ALS Report Interval", category: "Environment", value: number(als["ReportInterval"]), unit: "us", source: "AppleALSColorSensor", rawKey: "ReportInterval", timestamp: timestamp)
            append(&sensors, id: "environment.als_calibration", title: "ALS Calibration", category: "Environment", value: number(als["CalibrationResult"] ?? als["calibration_state"]), unit: "", source: "AppleALSColorSensor", rawKey: "CalibrationResult", timestamp: timestamp)
            append(&sensors, id: "environment.als_events", title: "ALS Events", category: "Environment", value: number(debug["_num_events"]), unit: "", source: "AppleALSColorSensor", rawKey: "DebugState._num_events", timestamp: timestamp)
            append(&sensors, id: "environment.als_transport", title: "ALS Transport", category: "Environment", value: als["Transport"], unit: "", source: "AppleALSColorSensor", rawKey: "Transport", timestamp: timestamp)
        } else {
            append(&sensors, id: "environment.als_available", title: "Ambient Light Available", category: "Environment", value: false, unit: "", source: "IORegistry", rawKey: "AppleALSColorSensor", timestamp: timestamp)
        }

        if let root = rootDomain.first {
            append(&sensors, id: "environment.clamshell_closed", title: "Clamshell Closed", category: "Environment", value: root["AppleClamshellState"], unit: "", source: "IOPMrootDomain", rawKey: "AppleClamshellState", timestamp: timestamp)
            append(&sensors, id: "environment.clamshell_causes_sleep", title: "Clamshell Causes Sleep", category: "Environment", value: root["AppleClamshellCausesSleep"], unit: "", source: "IOPMrootDomain", rawKey: "AppleClamshellCausesSleep", timestamp: timestamp)
            append(&sensors, id: "environment.wake_reason", title: "Wake Reason", category: "Environment", value: root["Wake Reason"], unit: "", source: "IOPMrootDomain", rawKey: "Wake Reason", timestamp: timestamp)
        }

        return sensors
    }

    private func merged(_ base: [SensorMetric], replacingWith live: [SensorMetric]) -> [SensorMetric] {
        guard !live.isEmpty else { return base }
        var result = base
        var positions: [String: Int] = [:]
        for (index, sensor) in result.enumerated() {
            positions[sensor.id] = index
        }
        for sensor in live {
            if let index = positions[sensor.id] {
                result[index] = sensor
            } else {
                positions[sensor.id] = result.count
                result.append(sensor)
            }
        }
        return result
    }

    private func append(
        _ sensors: inout [SensorMetric],
        id: String,
        title: String,
        category: String,
        value: Any?,
        unit: String,
        source: String,
        rawKey: String,
        timestamp: Date,
        isExperimental: Bool = false
    ) {
        guard let valueString = valueString(value) else { return }
        sensors.append(SensorMetric(
            id: id,
            title: title,
            category: category,
            value: valueString,
            unit: unit,
            source: source,
            quality: "ok",
            rawKey: rawKey,
            timestamp: timestamp,
            isExperimental: isExperimental
        ))
    }

    private func ioregPlist(className: String, timeout: TimeInterval) -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-c", className, "-a"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                return []
            }
            guard process.terminationStatus == 0 else { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty,
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] else {
                return []
            }
            return plist
        } catch {
            return []
        }
    }

    private func registryProperties(for className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let retained = properties?.takeRetainedValue() else {
            return nil
        }
        return retained as NSDictionary as? [String: Any]
    }

    private func firstSPUDevice(in devices: [[String: Any]], named name: String) -> [String: Any]? {
        devices.first { usageName($0) == name }
    }

    private func usageName(_ device: [String: Any]) -> String {
        let pairs = device["DeviceUsagePairs"] as? [[String: Any]] ?? []
        let first = pairs.first ?? [:]
        let page = int(first["DeviceUsagePage"])
        let usage = int(first["DeviceUsage"])
        if page == 65280, usage == 3 { return "Accelerometer" }
        if page == 65280, usage == 9 { return "Gyroscope" }
        if page == 65280, usage == 4 { return "Ambient Light" }
        if page == 32, usage == 138 { return "Hall / Lid Angle" }
        if page == 65280, usage == 5 { return "Temperature" }
        return "Usage \(page.map(String.init) ?? "nil"):\(usage.map(String.init) ?? "nil")"
    }

    private func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Float { return Double(value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Int64 { return Double(value) }
        if let value = value as? UInt64 { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            let pattern = "[-+]?[0-9]*\\.?[0-9]+"
            guard let range = value.range(of: pattern, options: .regularExpression) else { return nil }
            return Double(value[range])
        }
        return nil
    }

    private func valueString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? Bool { return value ? "yes" : "no" }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue ? "yes" : "no"
            }
            return "\(value)"
        }
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return "\(value)"
    }

    private func safeID(_ key: String) -> String {
        let lowered = key.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return String(mapped).split(separator: "_").joined(separator: "_")
    }
}
