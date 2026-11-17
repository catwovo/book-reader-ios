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

struct GlassPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

/// Apple Liquid-Glass inspired surface container
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
                                .white.opacity(0.45),
                                .white.opacity(0.12),
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

/// Grouped asymmetric corner radius matching expressive grouped cards
struct GroupedCardShape: Shape {
    let index: Int
    let count: Int
    var outerRadius: CGFloat = 20
    var innerRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let tl: CGFloat = (count <= 1 || index == 0) ? outerRadius : innerRadius
        let tr: CGFloat = (count <= 1 || index == 0) ? outerRadius : innerRadius
        let bl: CGFloat = (count <= 1 || index == count - 1) ? outerRadius : innerRadius
        let br: CGFloat = (count <= 1 || index == count - 1) ? outerRadius : innerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: tl,
            bottomLeadingRadius: bl,
            bottomTrailingRadius: br,
            topTrailingRadius: tr,
            style: .continuous
        ).path(in: rect)
    }
}

struct GlassGroupedCard<Content: View>: View {
    let index: Int
    let count: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = GroupedCardShape(index: index, count: count)
        content()
            .background {
                shape.fill(.ultraThinMaterial)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
    }
}

struct CollapsibleGlassSection<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var expanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: systemImage)
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    Divider()
                        .padding(.horizontal, 16)
                    VStack(alignment: .leading, spacing: 14) {
                        content()
                    }
                    .padding(16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
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
                    Color.accentColor.opacity(scheme == .dark ? 0.24 : 0.15),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 440
            )
            RadialGradient(
                colors: [
                    Color.purple.opacity(scheme == .dark ? 0.18 : 0.09),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
    }
}
