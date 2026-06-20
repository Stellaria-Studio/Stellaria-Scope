import Foundation
import IOKit

final class NativePowerCollector: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.lmz.StellarScope.NativePowerCollector.state")
    private var cachedSensors: [SensorMetric] = []
    private var lastRefresh = Date.distantPast

    func sample(maxAge: TimeInterval = 0.0) -> [SensorMetric] {
        if maxAge > 0 {
            let cached = stateQueue.sync { () -> [SensorMetric]? in
                Date().timeIntervalSince(lastRefresh) <= maxAge ? cachedSensors : nil
            }
            if let cached { return cached }
        }
        let fresh = collectFreshSample()
        stateQueue.sync {
            cachedSensors = fresh
            lastRefresh = Date()
        }
        return fresh
    }

    private func collectFreshSample() -> [SensorMetric] {
        guard let battery = registryProperties(for: "AppleSmartBattery") else { return [] }
        let timestamp = Date()
        var sensors: [SensorMetric] = []

        append(&sensors, id: "battery.charge_percent", title: "Battery Charge", category: "Battery", value: number(battery["CurrentCapacity"]), unit: "%", source: "NativeIORegistry", rawKey: "AppleSmartBattery.CurrentCapacity", timestamp: timestamp)
        append(&sensors, id: "battery.raw_capacity_mah", title: "Battery Raw Capacity", category: "Battery", value: number(battery["AppleRawCurrentCapacity"]), unit: "mAh", source: "NativeIORegistry", rawKey: "AppleSmartBattery.AppleRawCurrentCapacity", timestamp: timestamp)
        append(&sensors, id: "battery.max_capacity_mah", title: "Battery Max Capacity", category: "Battery", value: number(battery["AppleRawMaxCapacity"]), unit: "mAh", source: "NativeIORegistry", rawKey: "AppleSmartBattery.AppleRawMaxCapacity", timestamp: timestamp)
        append(&sensors, id: "battery.design_capacity_mah", title: "Battery Design Capacity", category: "Battery", value: number(battery["DesignCapacity"]), unit: "mAh", source: "NativeIORegistry", rawKey: "AppleSmartBattery.DesignCapacity", timestamp: timestamp)
        append(&sensors, id: "battery.cycle_count", title: "Battery Cycles", category: "Battery", value: number(battery["CycleCount"]), unit: "", source: "NativeIORegistry", rawKey: "AppleSmartBattery.CycleCount", timestamp: timestamp)
        append(&sensors, id: "battery.voltage_mv", title: "Battery Voltage", category: "Battery", value: number(battery["AppleRawBatteryVoltage"]) ?? number(battery["Voltage"]), unit: "mV", source: "NativeIORegistry", rawKey: "AppleSmartBattery.Voltage", timestamp: timestamp)
        append(&sensors, id: "battery.amperage_ma", title: "Battery Amperage", category: "Battery", value: number(battery["InstantAmperage"]) ?? number(battery["Amperage"]), unit: "mA", source: "NativeIORegistry", rawKey: "AppleSmartBattery.InstantAmperage", timestamp: timestamp)
        append(&sensors, id: "battery.temperature_c", title: "Battery Temperature", category: "Temperature", value: batteryTemperatureC(battery["Temperature"]), unit: "C", source: "NativeIORegistry", rawKey: "AppleSmartBattery.Temperature", timestamp: timestamp)
        append(&sensors, id: "battery.virtual_temperature_c", title: "Battery Virtual Temperature", category: "Temperature", value: batteryTemperatureC(battery["VirtualTemperature"]), unit: "C", source: "NativeIORegistry", rawKey: "AppleSmartBattery.VirtualTemperature", timestamp: timestamp, isExperimental: true)

        let adapter = dictionary(battery["AdapterDetails"])
        append(&sensors, id: "adapter.watts", title: "Adapter Rating", category: "Battery", value: number(adapter["Watts"]), unit: "W", source: "NativeIORegistry", rawKey: "AppleSmartBattery.AdapterDetails.Watts", timestamp: timestamp)
        append(&sensors, id: "adapter.voltage_mv", title: "Adapter Voltage", category: "Battery", value: number(adapter["AdapterVoltage"]), unit: "mV", source: "NativeIORegistry", rawKey: "AppleSmartBattery.AdapterDetails.AdapterVoltage", timestamp: timestamp)
        append(&sensors, id: "adapter.current_ma", title: "Adapter Current", category: "Battery", value: number(adapter["Current"]), unit: "mA", source: "NativeIORegistry", rawKey: "AppleSmartBattery.AdapterDetails.Current", timestamp: timestamp)

        let telemetry = dictionary(battery["PowerTelemetryData"])
        append(&sensors, id: "system.input_power_mw", title: "System Input Power", category: "Power", value: number(telemetry["SystemPowerIn"]), unit: "mW", source: "NativeIORegistry", rawKey: "AppleSmartBattery.PowerTelemetryData.SystemPowerIn", timestamp: timestamp)

        return sensors
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

    private func dictionary(_ value: Any?) -> [String: Any] {
        if let dict = value as? [String: Any] { return dict }
        if let dict = value as? NSDictionary { return dict as? [String: Any] ?? [:] }
        return [:]
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

    private func batteryTemperatureC(_ value: Any?) -> Double? {
        guard let raw = number(value) else { return nil }
        if raw > 1000 { return raw / 10.0 - 273.15 }
        if raw > 200 { return raw / 10.0 }
        return raw
    }

    private func append(
        _ sensors: inout [SensorMetric],
        id: String,
        title: String,
        category: String,
        value: Double?,
        unit: String,
        source: String,
        rawKey: String,
        timestamp: Date,
        isExperimental: Bool = false
    ) {
        guard let value else { return }
        sensors.append(SensorMetric(
            id: id,
            title: title,
            category: category,
            value: String(format: "%.2f", value),
            unit: unit,
            source: source,
            quality: "ok",
            rawKey: rawKey,
            timestamp: timestamp,
            isExperimental: isExperimental
        ))
    }
}
