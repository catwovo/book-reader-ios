import SwiftUI

extension Color {
    init?(hexInt64: Int64) {
        guard hexInt64 >= 0 else { return nil }
        let a = Double((hexInt64 >> 24) & 0xFF) / 255.0
        let r = Double((hexInt64 >> 16) & 0xFF) / 255.0
        let g = Double((hexInt64 >> 8) & 0xFF) / 255.0
        let b = Double(hexInt64 & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a > 0 ? a : 1.0)
    }
}

/// Apple Liquid-Glass inspired surface container (iOS 18+ ultraThinMaterial + specular highlight border)
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var tintColor: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    if let tintColor {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tintColor.opacity(0.65))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.42),
                                .white.opacity(0.10),
                                .white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 6)
    }
}

/// Soft ambient gradient backdrop that makes translucent glass layers pop
struct AmbientGlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.14),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 420
            )
            RadialGradient(
                colors: [
                    Color.purple.opacity(scheme == .dark ? 0.16 : 0.08),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }
}
