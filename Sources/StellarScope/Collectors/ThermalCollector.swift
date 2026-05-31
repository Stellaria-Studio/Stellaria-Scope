import Foundation

final class ThermalCollector {
    func sample() -> PublicThermalSnapshot {
        let state = ProcessInfo.processInfo.thermalState
        return PublicThermalSnapshot(rawValue: state.rawValue, label: label(for: state), timestamp: Date())
    }

    private func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
