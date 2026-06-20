import AppKit
import Combine
import SwiftUI

@main
struct StellarScopeApp: App {
    @StateObject private var store = TelemetryStore.shared
    @StateObject private var statusBar = StatusBarController()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(store)
                .onAppear {
                    store.start()
                    statusBar.configure(store: store)
                }
        }
    }
}

struct MenuBarSummaryView: View {
    @EnvironmentObject private var store: TelemetryStore
    @AppStorage("menuBarMetricIDs") private var menuBarMetricIDs = MenuBarMetricSelection.defaultRawValue
    @AppStorage("samplingPreset") private var samplingPresetID = SamplingPreset.live.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("StellarScope")
                .font(.headline)
            Divider()

            ForEach(MenuBarMetric.allCases) { metric in
                Button {
                    toggle(metric)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(isSelected(metric) ? 1 : 0)
                            .frame(width: 14)

                        Image(systemName: metric.symbolName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text(metric.title)
                            .frame(width: 86, alignment: .leading)

                        Spacer(minLength: 8)

                        Text(metric.menuBarValue(from: store.snapshot))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: 22)
            }

            Divider()

            Picker("Sampling", selection: samplingPresetBinding) {
                ForEach(SamplingPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 252, alignment: .leading)
    }

    private func isSelected(_ metric: MenuBarMetric) -> Bool {
        MenuBarMetricSelection.contains(metric, in: menuBarMetricIDs)
    }

    private func toggle(_ metric: MenuBarMetric) {
        menuBarMetricIDs = MenuBarMetricSelection.rawValue(menuBarMetricIDs, setting: metric, enabled: !isSelected(metric))
    }

    private var samplingPresetBinding: Binding<SamplingPreset> {
        Binding {
            SamplingPreset(rawValue: samplingPresetID) ?? .live
        } set: { preset in
            samplingPresetID = preset.rawValue
            TelemetryStore.shared.setPreset(preset)
        }
    }
}

@MainActor
final class StatusBarController: NSObject, ObservableObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    private weak var store: TelemetryStore?
    private var lastMenuBarText = ""

    func configure(store: TelemetryStore) {
        guard statusItem == nil else { return }
        self.store = store

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.image = nil
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        let popup = NSPopover()
        popup.behavior = .transient
        popup.contentSize = NSSize(width: 252, height: 362)
        popup.contentViewController = NSHostingController(rootView: AnyView(MenuBarSummaryView().environmentObject(store)))
        popup.delegate = self
        popover = popup

        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateLength(snapshot: snapshot)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let snapshot = self.store?.snapshot else { return }
                self.store?.refreshMenuBarSelection()
                self.updateLength(snapshot: snapshot)
            }
            .store(in: &cancellables)

        updateLength(snapshot: store.snapshot)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
            store?.setMenuPopoverVisible(false)
        } else {
            store?.setMenuPopoverVisible(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.store?.setMenuPopoverVisible(false)
        }
    }

    private func updateLength(snapshot: SystemSnapshot) {
        guard let button = statusItem?.button else { return }
        let raw = UserDefaults.standard.string(forKey: "menuBarMetricIDs") ?? MenuBarMetricSelection.defaultRawValue
        let metrics = MenuBarMetricSelection.metrics(from: raw)
        let text = metrics
            .map { "\($0.shortTitle) \($0.menuBarValue(from: snapshot))" }
            .joined(separator: "  ")
        guard text != lastMenuBarText else { return }
        lastMenuBarText = text

        let image = renderMenuBarImage(metrics: metrics, snapshot: snapshot)
        button.image = image
        statusItem?.length = max(28, ceil(image.size.width) + 10)
    }

    private func renderMenuBarImage(metrics: [MenuBarMetric], snapshot: SystemSnapshot) -> NSImage {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let labelColor = NSColor.labelColor.withAlphaComponent(0.94)
        let symbolColor = NSColor.labelColor.withAlphaComponent(0.82)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: labelColor,
            .paragraphStyle: paragraph
        ]
        let fallbackAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .medium),
            .foregroundColor: symbolColor,
            .paragraphStyle: paragraph
        ]
        let values = metrics.map { $0.menuBarValue(from: snapshot) }
        let widths = zip(metrics, values).map { metric, value in
            let valueWidth = (value as NSString).size(withAttributes: valueAttributes).width
            let labelWidth = (metric.shortTitle as NSString).size(withAttributes: fallbackAttributes).width
            return max(26, ceil(max(valueWidth, labelWidth) + 8))
        }
        let spacing: CGFloat = 7
        let width = max(24, widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)))
        let height: CGFloat = 22
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()

        var x: CGFloat = 0
        for (index, metric) in metrics.enumerated() {
            let cellWidth = widths[index]
            let value = values[index]
            let symbolRect = NSRect(x: x + (cellWidth - 10) / 2, y: 12.5, width: 10, height: 9)
            if let symbol = NSImage(systemSymbolName: metric.symbolName, accessibilityDescription: metric.title) {
                let configured = symbol.withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) ?? symbol
                configured.isTemplate = true
                symbolColor.set()
                configured.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 0.88)
            } else {
                (metric.shortTitle as NSString).draw(in: NSRect(x: x, y: 12, width: cellWidth, height: 9), withAttributes: fallbackAttributes)
            }
            (value as NSString).draw(in: NSRect(x: x, y: 0, width: cellWidth, height: 11), withAttributes: valueAttributes)
            x += cellWidth + spacing
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
