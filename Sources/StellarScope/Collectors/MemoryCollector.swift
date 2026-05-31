import Foundation
import Darwin

final class MemoryCollector {
    private var cachedSwap: (used: UInt64, total: UInt64) = (0, 0)
    private var lastSwapRead = Date.distantPast

    func sample() -> MemorySnapshot {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result: kern_return_t = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        let pageSize = UInt64(vm_kernel_page_size)
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)

        var snapshot = MemorySnapshot(totalBytes: total, timestamp: Date())
        if result == KERN_SUCCESS {
            snapshot.freeBytes = UInt64(vmStats.free_count) * pageSize
            snapshot.activeBytes = UInt64(vmStats.active_count) * pageSize
            snapshot.inactiveBytes = UInt64(vmStats.inactive_count) * pageSize
            snapshot.wiredBytes = UInt64(vmStats.wire_count) * pageSize
            snapshot.compressedBytes = UInt64(vmStats.compressor_page_count) * pageSize
            snapshot.purgeableBytes = UInt64(vmStats.purgeable_count) * pageSize
        }

        let swap = cachedSwapUsage()
        snapshot.swapUsedBytes = swap.used
        snapshot.swapTotalBytes = swap.total
        return snapshot
    }

    private func cachedSwapUsage() -> (used: UInt64, total: UInt64) {
        if Date().timeIntervalSince(lastSwapRead) < 5.0 {
            return cachedSwap
        }
        cachedSwap = readSwapUsage()
        lastSwapRead = Date()
        return cachedSwap
    }

    private func readSwapUsage() -> (used: UInt64, total: UInt64) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        task.arguments = ["vm.swapusage"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return (0, 0) }
            return parseSwapUsage(text)
        } catch {
            return (0, 0)
        }
    }

    private func parseSwapUsage(_ text: String) -> (used: UInt64, total: UInt64) {
        // Example: vm.swapusage: total = 2048.00M  used = 0.00M  free = 2048.00M
        func value(after key: String) -> UInt64 {
            guard let range = text.range(of: key) else { return 0 }
            let tail = text[range.upperBound...]
            let parts = tail.split(separator: " ", maxSplits: 1)
            guard let raw = parts.first else { return 0 }
            return bytesFromSwapToken(String(raw))
        }
        return (used: value(after: "used = "), total: value(after: "total = "))
    }

    private func bytesFromSwapToken(_ token: String) -> UInt64 {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = Double(trimmed.dropLast()) ?? 0
        if trimmed.hasSuffix("G") { return UInt64(number * 1024 * 1024 * 1024) }
        if trimmed.hasSuffix("M") { return UInt64(number * 1024 * 1024) }
        if trimmed.hasSuffix("K") { return UInt64(number * 1024) }
        return UInt64(number)
    }
}
