import Foundation
import StellarScopeNative

final class NativeAdvancedCollector: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.lmz.StellarScope.NativeAdvancedCollector.state")
    private var cachedSensors: [SensorMetric] = []
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false

    func sample(maxAge: TimeInterval = 5.0) -> [SensorMetric] {
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
        let capacity = 512
        var rows = [SSNativeMetric](repeating: SSNativeMetric(), count: capacity)
        let count = rows.withUnsafeMutableBufferPointer { buffer in
            StellarScopeCollectNativeAdvanced(buffer.baseAddress, Int32(capacity))
        }
        let timestamp = Date()
        return rows.prefix(Int(count)).compactMap { row -> SensorMetric? in
            var copy = row
            let hasValue = copy.hasValue != 0
            let numericValue = copy.value
            let isExperimental = copy.isExperimental != 0
            return withUnsafePointer(to: &copy) { pointer -> SensorMetric? in
                let id = string(StellarScopeNativeMetricID(pointer))
                guard !id.isEmpty else { return nil }
                return SensorMetric(
                    id: id,
                    title: string(StellarScopeNativeMetricTitle(pointer)),
                    category: string(StellarScopeNativeMetricCategory(pointer)),
                    value: hasValue ? String(format: "%.2f", numericValue) : string(StellarScopeNativeMetricText(pointer)),
                    unit: string(StellarScopeNativeMetricUnit(pointer)),
                    source: string(StellarScopeNativeMetricSource(pointer)),
                    quality: "best_effort",
                    rawKey: string(StellarScopeNativeMetricRawKey(pointer)),
                    timestamp: timestamp,
                    isExperimental: isExperimental
                )
            }
        }
    }

    private func string(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }
}
