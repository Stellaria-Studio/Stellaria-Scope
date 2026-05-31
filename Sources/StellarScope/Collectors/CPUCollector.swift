import Foundation
import Darwin

final class CPUCollector {
    private var previousTicks: [[UInt64]] = []

    func sample() -> [CoreLoad] {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCpuInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo else { return [] }
        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }

        let statesPerCPU = Int(CPU_STATE_MAX)
        let cpuCount = Int(numCPUs)
        let buffer = UnsafeBufferPointer(start: cpuInfo, count: Int(numCpuInfo))

        var currentTicks: [[UInt64]] = []
        currentTicks.reserveCapacity(cpuCount)
        for cpu in 0..<cpuCount {
            let base = cpu * statesPerCPU
            var ticks: [UInt64] = []
            for state in 0..<statesPerCPU {
                ticks.append(UInt64(max(0, buffer[base + state])))
            }
            currentTicks.append(ticks)
        }

        if previousTicks.count != currentTicks.count {
            previousTicks = currentTicks
            return currentTicks.enumerated().map { idx, _ in
                CoreLoad(id: idx, user: 0, system: 0, nice: 0, idle: 1)
            }
        }

        let loads = currentTicks.enumerated().map { idx, ticks -> CoreLoad in
            let prev = previousTicks[idx]
            let deltas = zip(ticks, prev).map { now, old in now >= old ? now - old : 0 }
            let total = Double(max(1, deltas.reduce(0, +)))
            let user = Double(deltas[Int(CPU_STATE_USER)]) / total
            let system = Double(deltas[Int(CPU_STATE_SYSTEM)]) / total
            let nice = Double(deltas[Int(CPU_STATE_NICE)]) / total
            let idle = Double(deltas[Int(CPU_STATE_IDLE)]) / total
            return CoreLoad(id: idx, user: user, system: system, nice: nice, idle: idle)
        }

        previousTicks = currentTicks
        return loads
    }
}
