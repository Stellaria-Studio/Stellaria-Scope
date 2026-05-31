import Foundation
import IOKit

private enum SMCCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case readIndex = 8
    case readKeyInfo = 9
}

private struct SMCParamStruct {
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private struct SMCConnection {
    let connection: io_connect_t

    init() throws {
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        } else {
            mainPort = kIOMasterPortDefault
        }

        let service = IOServiceGetMatchingService(mainPort, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw ProbeError("AppleSMC service not found")
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard result == kIOReturnSuccess else {
            throw ProbeError("IOServiceOpen AppleSMC failed: 0x\(String(result, radix: 16))")
        }
        connection = conn
    }

    func close() {
        IOServiceClose(connection)
    }

    func read(_ key: String) throws -> SMCReadResult {
        var infoParam = SMCParamStruct()
        infoParam.key = try fourCharCode(key)
        infoParam.data8 = SMCCommand.readKeyInfo.rawValue
        let info = try call(infoParam)
        guard info.result == 0 else {
            throw ProbeError("SMC key info \(key) failed: firmware 0x\(String(info.result, radix: 16))")
        }

        var readParam = SMCParamStruct()
        readParam.key = infoParam.key
        readParam.keyInfo.dataSize = info.keyInfo.dataSize
        readParam.data8 = SMCCommand.readBytes.rawValue
        let output = try call(readParam)
        guard output.result == 0 else {
            throw ProbeError("SMC read \(key) failed: firmware 0x\(String(output.result, radix: 16))")
        }

        let size = min(Int(info.keyInfo.dataSize), 32)
        let raw = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        let type = dataTypeString(info.keyInfo.dataType)
        return SMCReadResult(key: key, type: type, size: size, attributes: info.keyInfo.dataAttributes, raw: raw)
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var inStruct = SMCParamStruct()
        inStruct.key = input.key
        inStruct.keyInfo.dataSize = input.keyInfo.dataSize
        inStruct.data8 = input.data8
        inStruct.data32 = input.data32
        inStruct.bytes = input.bytes

        var outStruct = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCCommand.kernelIndex.rawValue),
            &inStruct,
            MemoryLayout<SMCParamStruct>.stride,
            &outStruct,
            &outSize
        )
        guard result == kIOReturnSuccess else {
            throw ProbeError("IOConnectCallStructMethod failed: 0x\(String(result, radix: 16))")
        }
        return outStruct
    }
}

private struct SMCReadResult {
    let key: String
    let type: String
    let size: Int
    let attributes: UInt8
    let raw: [UInt8]

    var rawHex: String {
        raw.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    var decoded: Any? {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ui8":
            return raw.first.map { Int($0) }
        case "ui16":
            guard raw.count >= 2 else { return nil }
            return Int(UInt16(raw[0]) << 8 | UInt16(raw[1]))
        case "ui32":
            guard raw.count >= 4 else { return nil }
            return Int(UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3]))
        case "flt":
            guard raw.count >= 4 else { return nil }
            return raw.withUnsafeBytes { Double($0.loadUnaligned(as: Float.self)) }
        case "fpe2":
            guard raw.count >= 2 else { return nil }
            let fixed = UInt16(raw[0]) << 8 | UInt16(raw[1])
            return Double(fixed) / 4.0
        default:
            if key.hasPrefix("F"), ["Ac", "Mn", "Mx", "Tg"].contains(String(key.suffix(2))) {
                if raw.count >= 4 {
                    return raw.withUnsafeBytes { Double($0.loadUnaligned(as: Float.self)) }
                }
                if raw.count >= 2 {
                    let fixed = UInt16(raw[0]) << 8 | UInt16(raw[1])
                    return Double(fixed) / 4.0
                }
            }
            let printable = raw.filter { $0 >= 0x20 && $0 < 0x7f }
            if !printable.isEmpty {
                return String(bytes: printable, encoding: .utf8)
            }
            return nil
        }
    }
}

private struct ProbeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func fourCharCode(_ string: String) throws -> UInt32 {
    let bytes = Array(string.utf8)
    guard bytes.count == 4 else { throw ProbeError("SMC key must be 4 bytes: \(string)") }
    return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private func dataTypeString(_ value: UInt32) -> String {
    let big = value.bigEndian
    return withUnsafeBytes(of: big) {
        String(bytes: $0, encoding: .ascii) ?? "????"
    }
}

private func emit(_ object: [String: Any], exitCode: Int32) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(exitCode)
}

private func fieldDictionary(_ result: SMCReadResult) -> [String: Any] {
    var field: [String: Any] = [
        "type": result.type,
        "size": result.size,
        "attributes": result.attributes,
        "raw_hex": result.rawHex
    ]
    if let decoded = result.decoded {
        field["value"] = decoded
    }
    return field
}

private func readOptional(_ key: String, using connection: SMCConnection, into fields: inout [String: Any]) -> SMCReadResult? {
    do {
        let result = try connection.read(key)
        fields[key] = fieldDictionary(result)
        return result
    } catch {
        fields[key] = ["error": error.localizedDescription]
        return nil
    }
}

let requested = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
let defaultKeys = ["FNum", "F0Ac", "F0Mn", "F0Mx", "F0ID", "F1Ac", "F1Mn", "F1Mx", "F1ID"]
let explicitKeys = requested.isEmpty ? defaultKeys : Array(requested)

do {
    let smc = try SMCConnection()
    defer { smc.close() }

    var fields: [String: Any] = [:]
    let fanCountResult = readOptional("FNum", using: smc, into: &fields)
    let fanCount = max(0, min(8, (fanCountResult?.decoded as? Int) ?? 2))
    let indexes = fanCount > 0 ? Array(0..<fanCount) : [0, 1]

    if requested.isEmpty {
        for index in indexes {
            for suffix in ["Ac", "Mn", "Mx", "ID"] {
                _ = readOptional("F\(index)\(suffix)", using: smc, into: &fields)
            }
        }
    } else {
        for key in explicitKeys where key != "FNum" {
            _ = readOptional(key, using: smc, into: &fields)
        }
    }

    var fans: [[String: Any]] = []
    for index in indexes {
        var fan: [String: Any] = ["index": index]
        if let actual = (fields["F\(index)Ac"] as? [String: Any])?["value"] {
            fan["rpm"] = actual
        }
        if let minimum = (fields["F\(index)Mn"] as? [String: Any])?["value"] {
            fan["min_rpm"] = minimum
        }
        if let maximum = (fields["F\(index)Mx"] as? [String: Any])?["value"] {
            fan["max_rpm"] = maximum
        }
        if let label = (fields["F\(index)ID"] as? [String: Any])?["value"] {
            fan["label"] = label
        }
        if fan.keys.count > 1 {
            fans.append(fan)
        }
    }

    emit([
        "ok": true,
        "service": "AppleSMC",
        "method": "IOConnectCallStructMethod selector 2, read-only command 5",
        "fan_count": fanCountResult?.decoded ?? NSNull(),
        "fans": fans,
        "fields": fields
    ], exitCode: 0)
} catch {
    emit([
        "ok": false,
        "service": "AppleSMC",
        "error": error.localizedDescription,
        "fields": [:]
    ], exitCode: 2)
}
