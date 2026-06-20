import SwiftUI

struct MetricCard<Content: View>: View {
    let title: String
    let value: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            content
        }
        .padding(16)
        .stellarGlassSurface(radius: 16)
        .frame(minHeight: 132, alignment: .topLeading)
    }
}

extension View {
    func stellarGlassSurface(radius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(StellarGlassSurfaceModifier(radius: radius, interactive: interactive))
    }
}

private struct StellarRenderEffectsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var stellarRenderEffectsEnabled: Bool {
        get { self[StellarRenderEffectsEnabledKey.self] }
        set { self[StellarRenderEffectsEnabledKey.self] = newValue }
    }
}

private struct StellarGlassSurfaceModifier: ViewModifier {
    @Environment(\.stellarRenderEffectsEnabled) private var effectsEnabled
    let radius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if effectsEnabled {
            liquidGlass(content: content, shape: shape)
        } else {
            content
                .background {
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                }
                .clipShape(shape)
                .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
        }
    }

    @ViewBuilder
    private func liquidGlass(content: Content, shape: RoundedRectangle) -> some View {
        let wash = LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.18, blue: 0.30).opacity(0.78),
                Color(red: 0.03, green: 0.08, blue: 0.14).opacity(0.50),
                Color(red: 0.02, green: 0.04, blue: 0.07).opacity(0.70)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let rim = LinearGradient(
            colors: [
                Color(red: 0.42, green: 0.72, blue: 1.0).opacity(0.48),
                .white.opacity(0.13),
                Color(red: 0.16, green: 0.36, blue: 0.68).opacity(0.28)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
                    .glassEffect(.regular.interactive(interactive), in: shape)
                    .background {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(wash)
                        shape.fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.25, green: 0.62, blue: 1.0).opacity(0.22),
                                    .clear
                                ],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: 340
                            )
                        )
                        shape.fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.02, green: 0.42, blue: 0.88).opacity(0.14),
                                    .clear
                                ],
                                center: .bottomTrailing,
                                startRadius: 20,
                                endRadius: 360
                            )
                        )
                    }
                    .clipShape(shape)
                    .overlay(shape.stroke(rim, lineWidth: 1))
                    .shadow(color: Color(red: 0.02, green: 0.20, blue: 0.45).opacity(0.20), radius: 22, x: 0, y: 12)
                    .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 8)
            }
        } else {
            content
                .background {
                    shape.fill(.thinMaterial)
                    shape.fill(wash)
                    shape.fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.25, green: 0.62, blue: 1.0).opacity(0.18),
                                .clear
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 320
                        )
                    )
                }
                .clipShape(shape)
                .overlay(shape.stroke(rim, lineWidth: 1))
                .shadow(color: Color(red: 0.02, green: 0.20, blue: 0.45).opacity(0.18), radius: 20, x: 0, y: 10)
                .shadow(color: .black.opacity(0.20), radius: 14, x: 0, y: 7)
        }
    }
}
