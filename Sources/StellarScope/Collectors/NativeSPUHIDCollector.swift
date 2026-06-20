import Foundation
import IOKit
import IOKit.hid

final class NativeSPUHIDCollector: @unchecked Sendable {
    private enum Constants {
        static let vendorPage = 0xFF00
        static let sensorPage = 0x0020
        static let accelerometerUsage = 3
        static let ambientLightUsage = 4
        static let lidUsage = 138
        static let reportBufferSize = 4096
    }

    func sample(timeout: TimeInterval = 0.12) -> [SensorMetric] {
        let timestamp = Date()
        let box = SPUHIDSampleBox()
        var devices: [IOHIDDevice] = []
        var buffers: [UnsafeMutablePointer<UInt8>] = []

        wakeSPUSensors()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            let usagePage = registryInt(service, key: "PrimaryUsagePage") ?? 0
            let usage = registryInt(service, key: "PrimaryUsage") ?? 0
            let callbackKind: SPUHIDSampleBox.Kind?
            if usagePage == Constants.vendorPage && usage == Constants.ambientLightUsage {
                callbackKind = .ambientLight
            } else if usagePage == Constants.sensorPage && usage == Constants.lidUsage {
                callbackKind = .lid
            } else {
                callbackKind = nil
            }

            guard let callbackKind else { continue }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            register(device: device, kind: callbackKind, box: box, devices: &devices, buffers: &buffers)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !(box.lidAngleDegrees != nil && box.ambientLight != nil) {
            CFRunLoopRunInMode(.defaultMode, 0.03, false)
        }

        close(devices: devices, buffers: buffers)

        var sensors: [SensorMetric] = []
        if let angle = box.lidAngleDegrees {
            append(&sensors, id: "motion.lid_angle_degrees", title: "Lid Angle", category: "Motion", value: angle, unit: "deg", source: "NativeSPUHID", rawKey: "AppleSPUHIDDevice.lid", timestamp: timestamp)
        }
        if let ambient = box.ambientLight {
            append(&sensors, id: "environment.spu_ambient_lux", title: "SPU Ambient Light", category: "Environment", value: ambient.lux, unit: "lx", source: "NativeSPUHID", rawKey: "AppleSPUHIDDevice.als_lux", timestamp: timestamp)
            for (index, value) in ambient.channels.enumerated() {
                append(&sensors, id: "environment.als_color_channel_\(index)", title: "ALS Color Channel \(index)", category: "Color", value: value, unit: "", source: "NativeSPUHID", rawKey: "AppleSPUHIDDevice.als_channel_\(index)", timestamp: timestamp, isExperimental: true)
            }
            for (index, value) in ambient.chroma.enumerated() {
                append(&sensors, id: "environment.als_chroma_\(index)", title: "ALS Chroma \(index)", category: "Color", value: value * 100.0, unit: "%", source: "NativeSPUHID", rawKey: "AppleSPUHIDDevice.als_chroma_\(index)", timestamp: timestamp, isExperimental: true)
            }
        }
        if !sensors.isEmpty {
            append(&sensors, id: "native.spu_hid.live", title: "Native SPU Live", category: "Raw", value: true, unit: "", source: "NativeSPUHID", rawKey: "native.spu_hid.live", timestamp: timestamp)
        }
        return sensors
    }

    func sampleBCG(timeout: TimeInterval = 5.0) -> [SensorMetric] {
        let timestamp = Date()
        let box = SPUHIDSampleBox()
        var devices: [IOHIDDevice] = []
        var buffers: [UnsafeMutablePointer<UInt8>] = []

        wakeSPUSensors(reportInterval: 50_000)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDevice"), &iterator) == KERN_SUCCESS else {
            return bcgStatusSensors(status: "SPU HID unavailable", timestamp: timestamp)
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            let usagePage = registryInt(service, key: "PrimaryUsagePage") ?? 0
            let usage = registryInt(service, key: "PrimaryUsage") ?? 0
            guard usagePage == Constants.vendorPage, usage == Constants.accelerometerUsage else { continue }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            register(device: device, kind: .accelerometer, box: box, devices: &devices, buffers: &buffers)
        }

        guard !devices.isEmpty else {
            return bcgStatusSensors(status: "accelerometer HID unavailable", timestamp: timestamp)
        }

        let deadline = Date().addingTimeInterval(max(1.0, timeout))
        while Date() < deadline && box.accelerometerSamples.count < 180 {
            CFRunLoopRunInMode(.defaultMode, 0.08, false)
        }

        close(devices: devices, buffers: buffers)

        let estimate = estimateBCGHeartRate(samples: box.accelerometerSamples)
        var sensors: [SensorMetric] = []
        append(&sensors, id: "motion.bcg_samples", title: "BCG Samples", category: "Motion", value: box.accelerometerSamples.count, unit: "", source: "NativeSPUHID", rawKey: "native.spu_hid.bcg_samples", timestamp: timestamp)
        if let sampleRate = estimate.sampleRate {
            append(&sensors, id: "motion.bcg_sample_rate_hz", title: "BCG Sample Rate", category: "Motion", value: sampleRate, unit: "Hz", source: "NativeSPUHID", rawKey: "native.spu_hid.bcg_sample_rate_hz", timestamp: timestamp)
        }
        append(&sensors, id: "motion.bcg_confidence", title: "BCG Confidence", category: "Motion", value: estimate.confidence, unit: "", source: "NativeSPUHID", rawKey: "native.spu_hid.bcg_confidence", timestamp: timestamp)
        if let bpm = estimate.bpm {
            let quality = estimate.status == "ok" ? "ok" : "low_confidence"
            append(&sensors, id: "motion.bcg_heart_rate_bpm", title: "BCG Heart Rate", category: "Motion", value: bpm, unit: "bpm", source: "NativeSPUHID", rawKey: "native.spu_hid.bcg_bpm", timestamp: timestamp, quality: quality)
        }
        append(&sensors, id: "motion.bcg_heart_rate_status", title: "BCG Heart Rate Status", category: "Motion", value: statusText(for: estimate), unit: "", source: "NativeSPUHID", rawKey: "native.spu_hid.bcg_status", timestamp: timestamp)
        return sensors
    }

    private func register(
        device: IOHIDDevice,
        kind: SPUHIDSampleBox.Kind,
        box: SPUHIDSampleBox,
        devices: inout [IOHIDDevice],
        buffers: inout [UnsafeMutablePointer<UInt8>]
    ) {
        box.kinds[UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())] = kind
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Constants.reportBufferSize)
        buffer.initialize(repeating: 0, count: Constants.reportBufferSize)
        buffers.append(buffer)
        devices.append(device)

        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            device,
            buffer,
            Constants.reportBufferSize,
            nativeSPUHIDReportCallback,
            Unmanaged.passUnretained(box).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func close(devices: [IOHIDDevice], buffers: [UnsafeMutablePointer<UInt8>]) {
        for device in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for buffer in buffers {
            buffer.deinitialize(count: Constants.reportBufferSize)
            buffer.deallocate()
        }
    }

    private func wakeSPUSensors(reportInterval: Int32 = 100_000) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            setRegistryInt(service, key: "SensorPropertyReportingState", value: 1)
            setRegistryInt(service, key: "SensorPropertyPowerState", value: 1)
            setRegistryInt(service, key: "ReportInterval", value: reportInterval)
            IOObjectRelease(service)
        }
    }

    private func registryInt(_ service: io_object_t, key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func setRegistryInt(_ service: io_object_t, key: String, value: Int32) {
        let number = value as CFNumber
        IORegistryEntrySetCFProperty(service, key as CFString, number)
    }

    private func append(
        _ sensors: inout [SensorMetric],
        id: String,
        title: String,
        category: String,
        value: Any,
        unit: String,
        source: String,
        rawKey: String,
        timestamp: Date,
        isExperimental: Bool = true,
        quality: String = "ok"
    ) {
        sensors.append(SensorMetric(
            id: id,
            title: title,
            category: category,
            value: valueString(value),
            unit: unit,
            source: source,
            quality: quality,
            rawKey: rawKey,
            timestamp: timestamp,
            isExperimental: isExperimental
        ))
    }

    private func bcgStatusSensors(status: String, timestamp: Date) -> [SensorMetric] {
        var sensors: [SensorMetric] = []
        append(&sensors, id: "motion.bcg_heart_rate_status", title: "BCG Heart Rate Status", category: "Motion", value: status, unit: "", source: "NativeSPUHID", rawKey: "native.spu_hid.bcg_status", timestamp: timestamp)
        return sensors
    }

    private func statusText(for estimate: BCGEstimate) -> String {
        var parts = [estimate.status]
        parts.append(String(format: "confidence %.2f", estimate.confidence))
        if let sampleRate = estimate.sampleRate {
            parts.append(String(format: "%.0f Hz", sampleRate))
        }
        return parts.joined(separator: ", ")
    }

    private func estimateBCGHeartRate(samples: [SPUHIDSampleBox.AccelerometerSample]) -> BCGEstimate {
        guard samples.count >= 120 else {
            return BCGEstimate(status: "not enough samples", bpm: nil, confidence: 0, sampleRate: nil)
        }
        let duration = samples.last!.time - samples.first!.time
        guard duration > 1.0 else {
            return BCGEstimate(status: "sample window too short", bpm: nil, confidence: 0, sampleRate: nil)
        }
        let sampleRate = Double(samples.count) / duration
        guard sampleRate >= 20 else {
            return BCGEstimate(status: "sample rate too low", bpm: nil, confidence: 0, sampleRate: sampleRate)
        }

        let highPassAlpha = sampleRate / (sampleRate + 2.0 * .pi * 0.8)
        let lowPassAlpha = 2.0 * .pi * 3.0 / (2.0 * .pi * 3.0 + sampleRate)
        var previousInput: Double?
        var previousOutput = 0.0
        var lowPass = 0.0
        var filtered: [Double] = []
        filtered.reserveCapacity(samples.count)

        for sample in samples {
            let magnitude = sqrt(sample.x * sample.x + sample.y * sample.y + sample.z * sample.z)
            guard let input = previousInput else {
                previousInput = magnitude
                continue
            }
            let highPass = highPassAlpha * (previousOutput + magnitude - input)
            previousInput = magnitude
            previousOutput = highPass
            lowPass = lowPassAlpha * highPass + (1.0 - lowPassAlpha) * lowPass
            filtered.append(lowPass)
        }

        guard filtered.count >= Int(sampleRate * 4) else {
            return BCGEstimate(status: "not enough filtered data", bpm: nil, confidence: 0, sampleRate: sampleRate)
        }

        let windowCount = min(filtered.count, Int(sampleRate * 10))
        let window = Array(filtered.suffix(windowCount))
        let mean = window.reduce(0, +) / Double(window.count)
        let centered = window.map { $0 - mean }
        let variance = centered.reduce(0) { $0 + $1 * $1 }
        guard variance >= 1e-20 else {
            return BCGEstimate(status: "no usable BCG signal", bpm: nil, confidence: 0, sampleRate: sampleRate)
        }

        let lagLow = max(1, Int(sampleRate * 0.3))
        let lagHigh = min(Int(sampleRate), centered.count / 2)
        guard lagLow < lagHigh else {
            return BCGEstimate(status: "window too short for heart-rate lag", bpm: nil, confidence: 0, sampleRate: sampleRate)
        }

        var bestCorrelation = -1.0
        var bestLag = lagLow
        for lag in lagLow..<lagHigh {
            var correlation = 0.0
            for index in 0..<(centered.count - lag) {
                correlation += centered[index] * centered[index + lag]
            }
            correlation /= variance
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        let bpm = 60.0 / (Double(bestLag) / sampleRate)
        let confidence = min(1.0, max(0.0, bestCorrelation))
        if confidence < 0.15 {
            return BCGEstimate(status: "low confidence", bpm: bpm, confidence: confidence, sampleRate: sampleRate)
        }
        return BCGEstimate(status: "ok", bpm: bpm, confidence: confidence, sampleRate: sampleRate)
    }

    private func valueString(_ value: Any) -> String {
        if let value = value as? Double { return String(format: "%.2f", value) }
        if let value = value as? Float { return String(format: "%.2f", Double(value)) }
        if let value = value as? Bool { return value ? "yes" : "no" }
        return "\(value)"
    }
}

private final class SPUHIDSampleBox {
    enum Kind {
        case ambientLight
        case lid
        case accelerometer
    }

    struct AmbientLight {
        let lux: Double
        let channels: [Double]
        let chroma: [Double]
    }

    struct AccelerometerSample {
        let time: TimeInterval
        let x: Double
        let y: Double
        let z: Double
    }

    var kinds: [UInt: Kind] = [:]
    var ambientLight: AmbientLight?
    var lidAngleDegrees: Double?
    var accelerometerSamples: [AccelerometerSample] = []
}

private struct BCGEstimate {
    let status: String
    let bpm: Double?
    let confidence: Double
    let sampleRate: Double?
}

private let nativeSPUHIDReportCallback: IOHIDReportWithTimeStampCallback = { context, _, sender, _, _, report, reportLength, _ in
    guard let context, let sender else { return }
    let box = Unmanaged<SPUHIDSampleBox>.fromOpaque(context).takeUnretainedValue()
    guard let kind = box.kinds[UInt(bitPattern: sender)] else { return }

    let bytes = UnsafeBufferPointer(start: report, count: reportLength)
    let byteArray = Array(bytes)
    switch kind {
    case .ambientLight:
        guard reportLength >= 44 else { return }
        let channels = NativeSPUHIDParser.alsChannelOffsets.map { offset -> Double in
            Double(NativeSPUHIDParser.uint32(byteArray, offset: offset))
        }
        let total = channels.reduce(0, +)
        let chroma = channels.map { total > 0 ? $0 / total : 0 }
        box.ambientLight = SPUHIDSampleBox.AmbientLight(
            lux: Double(NativeSPUHIDParser.float32(byteArray, offset: NativeSPUHIDParser.alsLuxOffset)),
            channels: channels,
            chroma: chroma
        )
    case .lid:
        guard reportLength >= NativeSPUHIDParser.lidReportLength, bytes[0] == 1 else { return }
        let raw = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        box.lidAngleDegrees = Double(raw & 0x01FF)
    case .accelerometer:
        guard reportLength >= NativeSPUHIDParser.imuReportLength,
              box.accelerometerSamples.count < 8_000,
              let sample = NativeSPUHIDParser.accelerometerSample(byteArray) else {
            return
        }
        box.accelerometerSamples.append(sample)
    }
}

private enum NativeSPUHIDParser {
    static let lidReportLength = 3
    static let imuReportLength = 22
    static let imuDataOffset = 6
    static let accelScale = 65_536.0
    static let alsLuxOffset = 40
    static let alsChannelOffsets = [20, 24, 28, 32]

    static func uint32(_ bytes: [UInt8], offset: Int) -> UInt32 {
        guard bytes.count >= offset + 4 else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    static func float32(_ bytes: [UInt8], offset: Int) -> Float {
        Float(bitPattern: uint32(bytes, offset: offset))
    }

    static func int32(_ bytes: [UInt8], offset: Int) -> Int32 {
        Int32(bitPattern: uint32(bytes, offset: offset))
    }

    static func accelerometerSample(_ bytes: [UInt8]) -> SPUHIDSampleBox.AccelerometerSample? {
        guard bytes.count >= imuReportLength else { return nil }
        let x = Double(int32(bytes, offset: imuDataOffset)) / accelScale
        let y = Double(int32(bytes, offset: imuDataOffset + 4)) / accelScale
        let z = Double(int32(bytes, offset: imuDataOffset + 8)) / accelScale
        return SPUHIDSampleBox.AccelerometerSample(time: ProcessInfo.processInfo.systemUptime, x: x, y: y, z: z)
    }
}
