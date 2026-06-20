import AppKit
import CoreAudio
import Foundation
import IOKit
import Metal

final class NativeInventoryCollector: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.lmz.StellarScope.NativeInventoryCollector.state")
    private var cachedSensors: [SensorMetric] = []
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false

    func sample(maxAge: TimeInterval = 60.0) -> [SensorMetric] {
        let state = stateQueue.sync { () -> (sensors: [SensorMetric], shouldRefresh: Bool) in
            let shouldRefresh = !isRefreshing && Date().timeIntervalSince(lastRefresh) > maxAge
            if shouldRefresh {
                isRefreshing = true
            }
            return (cachedSensors, shouldRefresh)
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

        return state.sensors
    }

    private func collectFreshSample() -> [SensorMetric] {
        let timestamp = Date()
        return collectDisplays(timestamp: timestamp)
            + collectStorage(timestamp: timestamp)
            + collectAudio(timestamp: timestamp)
            + collectBus(timestamp: timestamp)
    }

    private func collectDisplays(timestamp: Date) -> [SensorMetric] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let displays = Array(ids.prefix(Int(count)))
        var sensors: [SensorMetric] = []

        append(&sensors, id: "display.count", title: "Display Count", category: "Display", value: displays.count, unit: "", source: "NativeCoreGraphics", rawKey: "CGGetOnlineDisplayList", timestamp: timestamp)
        append(&sensors, id: "display.gpu_count", title: "GPU Entries", category: "Display", value: 1, unit: "", source: "NativeCoreGraphics", rawKey: "native.gpu_count", timestamp: timestamp)
        let gpu = MTLCreateSystemDefaultDevice()
        append(&sensors, id: "display.gpu0.name", title: "GPU 0 Name", category: "Display", value: gpu?.name ?? nativeGPUName(), unit: "", source: "NativeMetal", rawKey: "MTLCreateSystemDefaultDevice.name", timestamp: timestamp)
        append(&sensors, id: "display.gpu0.metal", title: "GPU 0 Metal", category: "Display", value: "supported", unit: "", source: "NativeMetal", rawKey: "MTLCreateSystemDefaultDevice", timestamp: timestamp)
        append(&sensors, id: "display.gpu0.unified_memory", title: "GPU Unified Memory", category: "Display", value: gpu?.hasUnifiedMemory, unit: "", source: "NativeMetal", rawKey: "MTLDevice.hasUnifiedMemory", timestamp: timestamp)
        append(&sensors, id: "display.gpu0.recommended_working_set_bytes", title: "GPU Recommended Working Set", category: "Display", value: gpu.map { Int64($0.recommendedMaxWorkingSetSize) }, unit: "B", source: "NativeMetal", rawKey: "MTLDevice.recommendedMaxWorkingSetSize", timestamp: timestamp)

        for (index, displayID) in displays.enumerated() {
            let prefix = "display.\(index)"
            let mode = CGDisplayCopyDisplayMode(displayID)
            let bounds = CGDisplayBounds(displayID)
            let isMain = displayID == CGMainDisplayID()
            let name = displayName(displayID) ?? (isMain ? "Main Display" : "Display \(index)")
            append(&sensors, id: "\(prefix).name", title: "Display \(index) Name", category: "Display", value: name, unit: "", source: "NativeCoreGraphics", rawKey: "CGDisplay", timestamp: timestamp)
            append(&sensors, id: "\(prefix).width_px", title: "Display \(index) Width", category: "Display", value: CGDisplayPixelsWide(displayID), unit: "px", source: "NativeCoreGraphics", rawKey: "CGDisplayPixelsWide", timestamp: timestamp)
            append(&sensors, id: "\(prefix).height_px", title: "Display \(index) Height", category: "Display", value: CGDisplayPixelsHigh(displayID), unit: "px", source: "NativeCoreGraphics", rawKey: "CGDisplayPixelsHigh", timestamp: timestamp)
            append(&sensors, id: "\(prefix).logical_width_px", title: "Display \(index) Logical Width", category: "Display", value: Int(bounds.width), unit: "px", source: "NativeCoreGraphics", rawKey: "CGDisplayBounds.width", timestamp: timestamp)
            append(&sensors, id: "\(prefix).logical_height_px", title: "Display \(index) Logical Height", category: "Display", value: Int(bounds.height), unit: "px", source: "NativeCoreGraphics", rawKey: "CGDisplayBounds.height", timestamp: timestamp)
            append(&sensors, id: "\(prefix).refresh_hz", title: "Display \(index) Refresh", category: "Display", value: mode?.refreshRate, unit: "Hz", source: "NativeCoreGraphics", rawKey: "CGDisplayMode.refreshRate", timestamp: timestamp)
            append(&sensors, id: "\(prefix).connection", title: "Display \(index) Connection", category: "Display", value: CGDisplayIsBuiltin(displayID) != 0 ? "built-in" : "external", unit: "", source: "NativeCoreGraphics", rawKey: "CGDisplayIsBuiltin", timestamp: timestamp)
            append(&sensors, id: "\(prefix).type", title: "Display \(index) Type", category: "Display", value: CGDisplayIsBuiltin(displayID) != 0 ? "Built-in" : "External", unit: "", source: "NativeCoreGraphics", rawKey: "CGDisplayIsBuiltin", timestamp: timestamp)
            append(&sensors, id: "\(prefix).main", title: "Display \(index) Main", category: "Display", value: isMain, unit: "", source: "NativeCoreGraphics", rawKey: "CGMainDisplayID", timestamp: timestamp)
            append(&sensors, id: "\(prefix).online", title: "Display \(index) Online", category: "Display", value: true, unit: "", source: "NativeCoreGraphics", rawKey: "CGGetOnlineDisplayList", timestamp: timestamp)
        }
        return sensors
    }

    private func collectStorage(timestamp: Date) -> [SensorMetric] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeURLKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        var sensors: [SensorMetric] = []
        append(&sensors, id: "storage.volume_count", title: "Volume Count", category: "Storage", value: urls.count, unit: "", source: "NativeFoundation", rawKey: "mountedVolumeURLs", timestamp: timestamp)

        for (index, url) in urls.prefix(12).enumerated() {
            let values = try? url.resourceValues(forKeys: keys)
            let total = values?.volumeTotalCapacity.map(Double.init)
            let free = values?.volumeAvailableCapacity.map(Double.init)
            let usedPercent = total.flatMap { total -> Double? in
                guard total > 0, let free else { return nil }
                return max(0, min(100, (1.0 - free / total) * 100.0))
            }
            let prefix = "storage.volume\(index)"
            append(&sensors, id: "\(prefix).name", title: "Volume \(index) Name", category: "Storage", value: values?.volumeName ?? url.lastPathComponent, unit: "", source: "NativeFoundation", rawKey: "volumeName", timestamp: timestamp)
            append(&sensors, id: "\(prefix).mount", title: "Volume \(index) Mount", category: "Storage", value: url.path, unit: "", source: "NativeFoundation", rawKey: "volumeURL", timestamp: timestamp)
            append(&sensors, id: "\(prefix).size_bytes", title: "Volume \(index) Size", category: "Storage", value: total, unit: "B", source: "NativeFoundation", rawKey: "volumeTotalCapacity", timestamp: timestamp)
            append(&sensors, id: "\(prefix).free_bytes", title: "Volume \(index) Free", category: "Storage", value: free, unit: "B", source: "NativeFoundation", rawKey: "volumeAvailableCapacity", timestamp: timestamp)
            append(&sensors, id: "\(prefix).used_percent", title: "Volume \(index) Used", category: "Storage", value: usedPercent, unit: "%", source: "NativeFoundation", rawKey: "derived.used_percent", timestamp: timestamp)
            append(&sensors, id: "\(prefix).filesystem", title: "Volume \(index) Filesystem", category: "Storage", value: values?.volumeLocalizedFormatDescription, unit: "", source: "NativeFoundation", rawKey: "volumeLocalizedFormatDescription", timestamp: timestamp)
            append(&sensors, id: "\(prefix).protocol", title: "Volume \(index) Protocol", category: "Storage", value: values?.volumeIsInternal == true ? "internal" : "external", unit: "", source: "NativeFoundation", rawKey: "volumeIsInternal", timestamp: timestamp)
            append(&sensors, id: "\(prefix).drive", title: "Volume \(index) Drive", category: "Storage", value: values?.volumeIsInternal == true ? "Internal Storage" : "External Storage", unit: "", source: "NativeFoundation", rawKey: "volumeIsInternal", timestamp: timestamp)
        }

        let nvmeCount = ioServiceCount(className: "IONVMeController")
        let disks = wholeDisks()
        append(&sensors, id: "storage.disk_count", title: "Whole Disk Count", category: "Storage", value: disks.count, unit: "", source: "NativeIORegistry", rawKey: "IOMedia.Whole", timestamp: timestamp)
        append(&sensors, id: "storage.nvme_count", title: "NVMe Device Count", category: "Storage", value: max(nvmeCount, disks.filter(\.internalDisk).count), unit: "", source: "NativeIORegistry", rawKey: "IONVMeController/IOMedia", timestamp: timestamp)
        if let disk = disks.first(where: \.internalDisk) ?? disks.first {
            append(&sensors, id: "storage.nvme0.model", title: "Internal Storage Model", category: "Storage", value: disk.name, unit: "", source: "NativeIORegistry", rawKey: "IOMedia", timestamp: timestamp)
            append(&sensors, id: "storage.nvme0.size_bytes", title: "Internal Storage Size", category: "Storage", value: disk.sizeBytes, unit: "B", source: "NativeIORegistry", rawKey: "IOMedia.Size", timestamp: timestamp)
            append(&sensors, id: "storage.nvme0.smart", title: "Internal Storage SMART", category: "Storage", value: "native unavailable", unit: "", source: "NativeIORegistry", rawKey: "SMART", timestamp: timestamp)
        }
        for (index, disk) in disks.prefix(8).enumerated() {
            let prefix = "storage.disk\(index)"
            append(&sensors, id: "\(prefix).name", title: "Disk \(index) Name", category: "Storage", value: disk.name, unit: "", source: "NativeIORegistry", rawKey: "IOMedia.BSD Name", timestamp: timestamp)
            append(&sensors, id: "\(prefix).size_bytes", title: "Disk \(index) Size", category: "Storage", value: disk.sizeBytes, unit: "B", source: "NativeIORegistry", rawKey: "IOMedia.Size", timestamp: timestamp)
            append(&sensors, id: "\(prefix).internal", title: "Disk \(index) Internal", category: "Storage", value: disk.internalDisk, unit: "", source: "NativeIORegistry", rawKey: "IOMedia.OSInternal", timestamp: timestamp)
        }
        return sensors
    }

    private func collectAudio(timestamp: Date) -> [SensorMetric] {
        var sensors: [SensorMetric] = []
        let devices = audioDeviceIDs()
        append(&sensors, id: "audio.device_count", title: "Audio Device Count", category: "Audio", value: devices.count, unit: "", source: "NativeCoreAudio", rawKey: "kAudioHardwarePropertyDevices", timestamp: timestamp)
        let defaultInput = defaultAudioDevice(scope: kAudioDevicePropertyScopeInput)
        let defaultOutput = defaultAudioDevice(scope: kAudioDevicePropertyScopeOutput)
        append(&sensors, id: "audio.default_input", title: "Default Input", category: "Audio", value: defaultInput.flatMap(audioDeviceName), unit: "", source: "NativeCoreAudio", rawKey: "kAudioHardwarePropertyDefaultInputDevice", timestamp: timestamp)
        append(&sensors, id: "audio.default_output", title: "Default Output", category: "Audio", value: defaultOutput.flatMap(audioDeviceName), unit: "", source: "NativeCoreAudio", rawKey: "kAudioHardwarePropertyDefaultOutputDevice", timestamp: timestamp)

        for (index, id) in devices.prefix(16).enumerated() {
            let prefix = "audio.device\(index)"
            append(&sensors, id: "\(prefix).name", title: "Audio \(index) Name", category: "Audio", value: audioDeviceName(id), unit: "", source: "NativeCoreAudio", rawKey: "kAudioObjectPropertyName", timestamp: timestamp)
            append(&sensors, id: "\(prefix).sample_rate_hz", title: "Audio \(index) Sample Rate", category: "Audio", value: audioSampleRate(id), unit: "Hz", source: "NativeCoreAudio", rawKey: "kAudioDevicePropertyNominalSampleRate", timestamp: timestamp)
            append(&sensors, id: "\(prefix).inputs", title: "Audio \(index) Inputs", category: "Audio", value: audioChannelCount(id, scope: kAudioDevicePropertyScopeInput), unit: "ch", source: "NativeCoreAudio", rawKey: "input.streamConfiguration", timestamp: timestamp)
            append(&sensors, id: "\(prefix).outputs", title: "Audio \(index) Outputs", category: "Audio", value: audioChannelCount(id, scope: kAudioDevicePropertyScopeOutput), unit: "ch", source: "NativeCoreAudio", rawKey: "output.streamConfiguration", timestamp: timestamp)
            append(&sensors, id: "\(prefix).transport", title: "Audio \(index) Transport", category: "Audio", value: audioTransport(id), unit: "", source: "NativeCoreAudio", rawKey: "kAudioDevicePropertyTransportType", timestamp: timestamp)
            append(&sensors, id: "\(prefix).manufacturer", title: "Audio \(index) Manufacturer", category: "Audio", value: audioManufacturer(id), unit: "", source: "NativeCoreAudio", rawKey: "kAudioObjectPropertyManufacturer", timestamp: timestamp)
        }
        return sensors
    }

    private func collectBus(timestamp: Date) -> [SensorMetric] {
        var sensors: [SensorMetric] = []
        let usbCount = ioServiceCount(className: "IOUSBHostDevice")
        let thunderboltCount = ioServiceCount(className: "IOThunderboltController")
        let pciCount = ioServiceCount(className: "IOPCIDevice")
        let network = networkInterfaces()

        append(&sensors, id: "bus.usb_root_count", title: "USB Device Count", category: "Bus", value: usbCount, unit: "", source: "NativeIORegistry", rawKey: "IOUSBHostDevice", timestamp: timestamp)
        append(&sensors, id: "bus.thunderbolt_bus_count", title: "Thunderbolt / USB4 Buses", category: "Bus", value: thunderboltCount, unit: "", source: "NativeIORegistry", rawKey: "IOThunderboltController", timestamp: timestamp)
        append(&sensors, id: "bus.pci_device_count", title: "PCI Device Count", category: "Bus", value: pciCount, unit: "", source: "NativeIORegistry", rawKey: "IOPCIDevice", timestamp: timestamp)
        append(&sensors, id: "bus.network_service_count", title: "Network Services", category: "Bus", value: network.count, unit: "", source: "NativeBSD", rawKey: "getifaddrs", timestamp: timestamp)
        if thunderboltCount > 0 {
            append(&sensors, id: "bus.thunderbolt0.name", title: "Thunderbolt 0 Name", category: "Bus", value: "Thunderbolt / USB4", unit: "", source: "NativeIORegistry", rawKey: "IOThunderboltController", timestamp: timestamp)
        }
        for (index, item) in network.prefix(12).enumerated() {
            append(&sensors, id: "bus.network\(index).name", title: "Network \(index) Name", category: "Bus", value: item.name, unit: "", source: "NativeBSD", rawKey: "ifaddrs.name", timestamp: timestamp)
            append(&sensors, id: "bus.network\(index).interface", title: "Network \(index) Interface", category: "Bus", value: item.name, unit: "", source: "NativeBSD", rawKey: "ifaddrs.name", timestamp: timestamp)
            append(&sensors, id: "bus.network\(index).type", title: "Network \(index) Type", category: "Bus", value: item.type, unit: "", source: "NativeBSD", rawKey: "ifaddrs.family", timestamp: timestamp)
        }
        return sensors
    }

    private func append(_ sensors: inout [SensorMetric], id: String, title: String, category: String, value: Any?, unit: String, source: String, rawKey: String, timestamp: Date) {
        guard let text = valueString(value) else { return }
        sensors.append(SensorMetric(id: id, title: title, category: category, value: text, unit: unit, source: source, quality: "ok", rawKey: rawKey, timestamp: timestamp, isExperimental: false))
    }

    private func valueString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let value = value as? Bool { return value ? "yes" : "no" }
        if let value = value as? Double { return String(format: "%.2f", value) }
        if let value = value as? Float { return String(format: "%.2f", Double(value)) }
        if let value = value as? Int { return "\(value)" }
        if let value = value as? Int64 { return "\(value)" }
        if let value = value as? UInt64 { return "\(value)" }
        if let value = value as? UInt { return "\(value)" }
        let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func displayName(_ displayID: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.localizedName
    }

    private func nativeGPUName() -> String {
        if let name = registryName(className: "IOAccelerator") { return name }
        if let name = registryName(className: "IOAccelerator2") { return name }
        return "Apple GPU"
    }

    private struct DiskInfo {
        let name: String
        let sizeBytes: Int64
        let internalDisk: Bool
    }

    private func wholeDisks() -> [DiskInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var disks: [DiskInfo] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let props = registryProperties(service),
                  bool(props["Whole"]) == true else {
                continue
            }
            let name = (props["BSD Name"] as? String) ?? (props["IOName"] as? String) ?? "disk\(disks.count)"
            let size = int64(props["Size"]) ?? 0
            let internalDisk = bool(props["OSInternal"]) ?? stringContainsInternal(props["IOMediaIcon"])
            disks.append(DiskInfo(name: name, sizeBytes: size, internalDisk: internalDisk))
        }
        return disks.sorted { lhs, rhs in
            if lhs.internalDisk != rhs.internalDisk { return lhs.internalDisk && !rhs.internalDisk }
            return lhs.name < rhs.name
        }
    }

    private func registryProperties(_ service: io_object_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let retained = properties?.takeRetainedValue() else {
            return nil
        }
        return retained as NSDictionary as? [String: Any]
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            let lower = value.lowercased()
            if ["yes", "true", "1"].contains(lower) { return true }
            if ["no", "false", "0"].contains(lower) { return false }
        }
        return nil
    }

    private func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? UInt64 { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        return nil
    }

    private func stringContainsInternal(_ value: Any?) -> Bool {
        String(describing: value).localizedCaseInsensitiveContains("Internal")
    }

    private func registryName(className: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        if let name = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
            return String(data: name, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        }
        return IORegistryEntryCreateCFProperty(service, "IOName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private func ioServiceCount(className: String) -> Int {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var count = 0
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            count += 1
            IOObjectRelease(service)
        }
        return count
    }

    private func audioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private func defaultAudioDevice(scope: AudioObjectPropertyScope) -> AudioDeviceID? {
        let selector = scope == kAudioDevicePropertyScopeInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private func audioDeviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioObjectPropertyName)
    }

    private func audioManufacturer(_ id: AudioDeviceID) -> String? {
        stringProperty(id, selector: kAudioObjectPropertyManufacturer)
    }

    private func audioSampleRate(_ id: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return Double(rate)
    }

    private func audioTransport(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        default: return "0x\(String(value, radix: 16))"
        }
    }

    private func audioChannelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return 0 }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<CFString>.size, alignment: MemoryLayout<CFString>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return nil }
        let value = storage.load(as: CFString.self)
        return value as String
    }

    private func networkInterfaces() -> [(name: String, type: String)] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var seen = Set<String>()
        var result: [(String, String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let flags = Int32(item.pointee.ifa_flags)
            let name = String(cString: item.pointee.ifa_name)
            if (flags & IFF_UP) != 0, !seen.contains(name) {
                seen.insert(name)
                let family = item.pointee.ifa_addr?.pointee.sa_family
                let type = family == UInt8(AF_INET) || family == UInt8(AF_INET6) ? "IP" : "link"
                result.append((name, type))
            }
            cursor = item.pointee.ifa_next
        }
        return result.sorted { (lhs: (name: String, type: String), rhs: (name: String, type: String)) in
            lhs.name < rhs.name
        }
    }
}
