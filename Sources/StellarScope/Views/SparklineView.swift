import SwiftUI

struct SparklineView: View {
    var values: [Double]
    var lineWidth: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                let width = proxy.size.width
                let height = proxy.size.height
                let step = width / CGFloat(max(1, values.count - 1))
                for (idx, value) in values.enumerated() {
                    let clamped = max(0, min(1, value))
                    let point = CGPoint(x: CGFloat(idx) * step, y: height * (1 - clamped))
                    if idx == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(.primary.opacity(0.85), lineWidth: lineWidth)
        }
    }
}

struct MeterBar: View {
    @Environment(\.stellarRenderEffectsEnabled) private var effectsEnabled
    var value: Double
    var height: CGFloat = 8
    @State private var displayedValue: Double = 0

    private var clampedValue: Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * displayedValue
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.07))
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.40, green: 0.86, blue: 1.0),
                                Color(red: 0.20, green: 0.50, blue: 1.0),
                                Color(red: 0.36, green: 0.42, blue: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(displayedValue > 0 ? height : 0, width))
                    .shadow(color: effectsEnabled ? Color(red: 0.14, green: 0.48, blue: 1.0).opacity(0.35) : .clear, radius: effectsEnabled ? 6 : 0, x: 0, y: 0)
            }
        }
        .frame(height: height)
        .onAppear {
            displayedValue = clampedValue
        }
        .onChange(of: value) { _ in
            if effectsEnabled {
                withAnimation(.interactiveSpring(response: 0.55, dampingFraction: 0.86, blendDuration: 0.18)) {
                    displayedValue = clampedValue
                }
            } else {
                displayedValue = clampedValue
            }
        }
        .onChange(of: effectsEnabled) { enabled in
            if !enabled {
                displayedValue = clampedValue
            }
        }
    }
}
