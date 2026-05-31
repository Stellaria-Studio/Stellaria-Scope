import SwiftUI

@main
struct StellarScopeApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardView()
        }

        MenuBarExtra("StellarScope", systemImage: "gauge.with.dots.needle.67percent") {
            MenuBarSummaryView()
        }
    }
}

struct MenuBarSummaryView: View {
    @StateObject private var store = TelemetryStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("StellarScope")
                .font(.headline)
            Divider()
            Text("CPU \(store.snapshot.cpuActiveAverage.percentText)")
            Text("Memory \(store.snapshot.memory.usedBytes.humanBytes)")
            Text("Swap \(store.snapshot.memory.swapUsedBytes.humanBytes)")
            Text("Thermal \(store.snapshot.thermal.label)")
            if store.snapshot.powermetrics.available {
                Text("GPU \(store.snapshot.powermetrics.gpuResidencyPercent.map { String(format: "%.0f%%", $0) } ?? "—")")
            }
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
    }
}
