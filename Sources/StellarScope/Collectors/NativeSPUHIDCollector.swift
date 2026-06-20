import Foundation
import IOKit
import IOKit.hid

final class NativeSPUHIDCollector: @unchecked Sendable {
    private enum Constants {
        static let vendorPage = 0xFF00
        static let sensorPage = 0x0020
        static let ambientLightUsage = 4
        static let lidUsage = 138
        static let alsReportLength = 122
        static let lidReportLength = 3
        static let alsLuxOffset = 40
        static let alsChannelOffsets = [20, 24, 28, 32]
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

            box.kinds[UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())] = callbackKind
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

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !(box.lidAngleDegrees != nil && box.ambientLight != nil) {
            CFRunLoopRunInMode(.defaultMode, 0.03, false)
        }

        for device in devices {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        for buffer in buffers {
            buffer.deinitialize(count: Constants.reportBufferSize)
            buffer.deallocate()
        }

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

    private func wakeSPUSensors() {
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
            setRegistryInt(service, key: "ReportInterval", value: 100_000)
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
        isExperimental: Bool = true
    ) {
        sensors.append(SensorMetric(
            id: id,
            title: title,
            category: category,
            value: valueString(value),
            unit: unit,
            source: source,
            quality: "ok",
            rawKey: rawKey,
            timestamp: timestamp,
            isExperimental: isExperimental
        ))
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
    }

    struct AmbientLight {
        let lux: Double
        let channels: [Double]
        let chroma: [Double]
    }

    var kinds: [UInt: Kind] = [:]
    var ambientLight: AmbientLight?
    var lidAngleDegrees: Double?
}

private let nativeSPUHIDReportCallback: IOHIDReportWithTimeStampCallback = { context, _, sender, _, _, report, reportLength, _ in
    guard let context, let sender else { return }
    let box = Unmanaged<SPUHIDSampleBox>.fromOpaque(context).takeUnretainedValue()
    guard let kind = box.kinds[UInt(bitPattern: sender)] else { return }

    let bytes = UnsafeBufferPointer(start: report, count: reportLength)
    switch kind {
    case .ambientLight:
        guard reportLength >= 44 else { return }
        let channels = NativeSPUHIDParser.alsChannelOffsets.map { offset -> Double in
            Double(NativeSPUHIDParser.uint32(Array(bytes), offset: offset))
        }
        let total = channels.reduce(0, +)
        let chroma = channels.map { total > 0 ? $0 / total : 0 }
        box.ambientLight = SPUHIDSampleBox.AmbientLight(
            lux: Double(NativeSPUHIDParser.float32(Array(bytes), offset: NativeSPUHIDParser.alsLuxOffset)),
            channels: channels,
            chroma: chroma
        )
    case .lid:
        guard reportLength >= NativeSPUHIDParser.lidReportLength, bytes[0] == 1 else { return }
        let raw = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        box.lidAngleDegrees = Double(raw & 0x01FF)
    }
}

private enum NativeSPUHIDParser {
    static let lidReportLength = 3
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
}
