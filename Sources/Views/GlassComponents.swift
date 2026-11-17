import SwiftUI
import UIKit

// MARK: - Color Helpers

extension Color {
    init?(hexInt64: Int64) {
        guard hexInt64 >= 0 else { return nil }
        let a = Double((hexInt64 >> 24) & 0xFF) / 255.0
        let r = Double((hexInt64 >> 16) & 0xFF) / 255.0
        let g = Double((hexInt64 >> 8) & 0xFF) / 255.0
        let b = Double(hexInt64 & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a > 0 ? a : 1.0)
    }

    init(hexRGB: UInt32, alpha: Double = 1.0) {
        let r = Double((hexRGB >> 16) & 0xFF) / 255.0
        let g = Double((hexRGB >> 8) & 0xFF) / 255.0
        let b = Double(hexRGB & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    func toStoredHexInt64() -> Int64 {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ai = Int64(max(0, min(255, Int((a * 255.0).rounded()))))
        let ri = Int64(max(0, min(255, Int((r * 255.0).rounded()))))
        let gi = Int64(max(0, min(255, Int((g * 255.0).rounded()))))
        let bi = Int64(max(0, min(255, Int((b * 255.0).rounded()))))
        return (ai << 24) | (ri << 16) | (gi << 8) | bi
    }

    var hexString: String {
        let argb = toStoredHexInt64()
        let a = (argb >> 24) & 0xFF
        if a == 255 {
            return String(format: "#%06X", argb & 0xFFFFFF)
        } else {
            return String(format: "#%08X", argb)
        }
    }

    var relativeLuminance: Double {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linearize(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(Double(r)) + 0.7152 * linearize(Double(g)) + 0.0722 * linearize(Double(b))
    }

    var contrastingTextColor: Color {
        relativeLuminance > 0.44 ? Color(hexRGB: 0x111827) : Color(hexRGB: 0xECEEF3)
    }

    var contrastingSecondaryTextColor: Color {
        relativeLuminance > 0.44 ? Color(hexRGB: 0x6B7280) : Color(hexRGB: 0x9CA3AF)
    }

    static func fromHexString(_ raw: String) -> Color? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard trimmed.count == 6 || trimmed.count == 8, let val = UInt64(trimmed, radix: 16) else {
            return nil
        }
        let argb: Int64 = trimmed.count == 6 ? Int64(0xFF000000 | val) : Int64(val)
        return Color(hexInt64: argb)
    }
}

// MARK: - 7-Theme Liquid Glass Palette

struct AppThemePalette {
    let mode: AppThemeMode
    let accent: Color
    let backgroundBase: Color
    let surfaceTint: Color
    let nestedTint: Color
    let secondaryAccent: Color
    let previewColor: Color
    let isLight: Bool

    static func resolve(mode: AppThemeMode, systemScheme: ColorScheme) -> AppThemePalette {
        switch mode {
        case .dynamic:
            if systemScheme == .dark {
                return AppThemePalette(
                    mode: .dynamic,
                    accent: Color(hexRGB: 0x60A5FA),
                    backgroundBase: Color(.systemGroupedBackground),
                    surfaceTint: Color(hexRGB: 0x191E28),
                    nestedTint: Color(hexRGB: 0x222834),
                    secondaryAccent: .purple,
                    previewColor: Color(hexRGB: 0x2563EB),
                    isLight: false
                )
            } else {
                return AppThemePalette(
                    mode: .dynamic,
                    accent: Color(hexRGB: 0x2563EB),
                    backgroundBase: Color(.systemGroupedBackground),
                    surfaceTint: .white,
                    nestedTint: Color(hexRGB: 0xECEFF4),
                    secondaryAccent: .indigo,
                    previewColor: Color(hexRGB: 0x2563EB),
                    isLight: true
                )
            }
        case .light:
            return AppThemePalette(
                mode: .light,
                accent: Color(hexRGB: 0x2563EB),
                backgroundBase: Color(hexRGB: 0xF6F7FA),
                surfaceTint: .white,
                nestedTint: Color(hexRGB: 0xEEF1F6),
                secondaryAccent: Color(hexRGB: 0x0D9488),
                previewColor: Color(hexRGB: 0xFAFAFC),
                isLight: true
            )
        case .dark:
            return AppThemePalette(
                mode: .dark,
                accent: Color(hexRGB: 0x60A5FA),
                backgroundBase: Color(hexRGB: 0x0D1015),
                surfaceTint: Color(hexRGB: 0x171C26),
                nestedTint: Color(hexRGB: 0x222834),
                secondaryAccent: Color(hexRGB: 0x2DD4BF),
                previewColor: Color(hexRGB: 0x0E1116),
                isLight: false
            )
        case .sepia:
            return AppThemePalette(
                mode: .sepia,
                accent: Color(hexRGB: 0x9A4C00),
                backgroundBase: Color(hexRGB: 0xF6EEDB),
                surfaceTint: Color(hexRGB: 0xFAF3E3),
                nestedTint: Color(hexRGB: 0xEDE0C8),
                secondaryAccent: Color(hexRGB: 0xB46927),
                previewColor: Color(hexRGB: 0xF6EEDB),
                isLight: true
            )
        case .sage:
            return AppThemePalette(
                mode: .sage,
                accent: Color(hexRGB: 0x2A623D),
                backgroundBase: Color(hexRGB: 0xE6EFE6),
                surfaceTint: Color(hexRGB: 0xEEF5EE),
                nestedTint: Color(hexRGB: 0xD5E2D6),
                secondaryAccent: Color(hexRGB: 0x4E6354),
                previewColor: Color(hexRGB: 0xE6EFE6),
                isLight: true
            )
        case .slate:
            return AppThemePalette(
                mode: .slate,
                accent: Color(hexRGB: 0x5B9BD5),
                backgroundBase: Color(hexRGB: 0x16202C),
                surfaceTint: Color(hexRGB: 0x1F2B3A),
                nestedTint: Color(hexRGB: 0x293748),
                secondaryAccent: Color(hexRGB: 0x647D99),
                previewColor: Color(hexRGB: 0x2A5684),
                isLight: false
            )
        case .amoled:
            return AppThemePalette(
                mode: .amoled,
                accent: Color(hexRGB: 0x9ECAFF),
                backgroundBase: Color(hexRGB: 0x040507),
                surfaceTint: Color(hexRGB: 0x0D1016),
                nestedTint: Color(hexRGB: 0x171D26),
                secondaryAccent: Color(hexRGB: 0x3B82F6),
                previewColor: Color(hexRGB: 0x07090D),
                isLight: false
            )
        }
    }
}

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue: AppThemePalette = .resolve(mode: .dynamic, systemScheme: .light)
}

extension EnvironmentValues {
    var appPalette: AppThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

// MARK: - Unified Motion Presets (Synced with Android AppMotion)

enum AppMotion {
    static let panelSpring = Animation.spring(response: 0.34, dampingFraction: 0.84)
    static let cardSpring = Animation.spring(response: 0.30, dampingFraction: 0.80)
    static let pressSpring = Animation.spring(response: 0.24, dampingFraction: 0.72)
    static let bookSpring = Animation.spring(response: 0.36, dampingFraction: 0.90)
    static let tabSpring = Animation.spring(response: 0.30, dampingFraction: 0.84)

    static let panelTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    )

    static let cardTransition: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.95)),
        removal: .opacity.combined(with: .scale(scale: 0.96))
    )

    static let bookTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .trailing).combined(with: .opacity)
    )
}

// MARK: - Liquid Glass Containers

struct GlassPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .animation(AppMotion.pressSpring, value: configuration.isPressed)
    }
}

/// Apple Liquid-Glass inspired surface container
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 22
    var tintColor: Color? = nil
    var customFill: Color? = nil
    @Environment(\.appPalette) private var palette
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), customFill == nil {
            let effectiveTint: Color? = tintColor ?? (palette.mode != .dynamic ? palette.surfaceTint.opacity(palette.isLight ? 0.24 : 0.28) : nil)
            let glass: Glass = effectiveTint != nil ? .regular.tint(effectiveTint!) : .regular
            content()
                .glassEffect(glass, in: shape)
        } else {
            legacyGlassBody(shape: shape)
        }
        #else
        legacyGlassBody(shape: shape)
        #endif
    }

    @ViewBuilder
    private func legacyGlassBody(shape: RoundedRectangle) -> some View {
        content()
            .background {
                ZStack {
                    if let customFill {
                        shape.fill(customFill)
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(customFill.relativeLuminance > 0.44 ? 0.24 : 0.07),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                    } else {
                        shape.fill(.regularMaterial)
                        if let tintColor {
                            shape.fill(tintColor)
                        } else if palette.mode != .dynamic {
                            shape.fill(palette.surfaceTint.opacity(palette.isLight ? 0.34 : 0.26))
                        }
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(palette.isLight ? 0.30 : 0.09),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(customFill != nil ? 0.28 : (palette.isLight ? 0.68 : 0.24)),
                            .white.opacity(palette.isLight ? 0.14 : 0.07),
                            .white.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
            }
            .shadow(color: .black.opacity(palette.isLight ? 0.048 : 0.20), radius: 14, x: 0, y: 6)
    }
}

struct GlassGroupedCard<Content: View>: View {
    let index: Int
    let count: Int
    var outerRadius: CGFloat = 22
    var innerRadius: CGFloat = 8
    var tintColor: Color? = nil
    @Environment(\.appPalette) private var palette
    @ViewBuilder var content: () -> Content

    private var shape: UnevenRoundedRectangle {
        let topR: CGFloat = (count <= 1 || index == 0) ? outerRadius : innerRadius
        let botR: CGFloat = (count <= 1 || index == count - 1) ? outerRadius : innerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: topR,
            bottomLeadingRadius: botR,
            bottomTrailingRadius: botR,
            topTrailingRadius: topR,
            style: .continuous
        )
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let effectiveTint: Color? = tintColor ?? (palette.mode != .dynamic ? palette.surfaceTint.opacity(palette.isLight ? 0.20 : 0.24) : nil)
            let glass: Glass = effectiveTint != nil ? .regular.tint(effectiveTint!) : .regular
            content()
                .glassEffect(glass, in: shape)
        } else {
            legacyGroupedBody
        }
        #else
        legacyGroupedBody
        #endif
    }

    @ViewBuilder
    private var legacyGroupedBody: some View {
        content()
            .background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tintColor {
                        shape.fill(tintColor)
                    } else if palette.mode != .dynamic {
                        shape.fill(palette.surfaceTint.opacity(palette.isLight ? 0.30 : 0.24))
                    }
                    shape.fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(palette.isLight ? 0.24 : 0.07),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(palette.isLight ? 0.60 : 0.22),
                            .white.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.55
                )
            }
            .shadow(color: .black.opacity(palette.isLight ? 0.025 : 0.14), radius: 6, x: 0, y: 2)
    }
}

struct AppleIconBadge: View {
    let systemImage: String
    var color: Color? = nil
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 9
    var filled: Bool = false

    @Environment(\.appPalette) private var palette

    var body: some View {
        let baseColor = color ?? palette.accent
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(filled ? Color.white : baseColor)
            .frame(width: size, height: size)
            .background {
                if filled {
                    shape.fill(
                        LinearGradient(
                            colors: [baseColor, baseColor.opacity(0.80)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(baseColor.opacity(palette.isLight ? 0.13 : 0.22))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(filled ? 0.45 : (palette.isLight ? 0.65 : 0.24)),
                            .white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.55
                )
            }
    }
}

struct CollapsibleGlassSection<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var expanded: Bool
    @Environment(\.appPalette) private var palette
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassCard(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(AppMotion.panelSpring) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        AppleIconBadge(systemImage: systemImage, size: 34, cornerRadius: 10, filled: true)

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
                    .transition(AppMotion.panelTransition)
                }
            }
            .clipped()
        }
    }
}

/// Soft ambient gradient backdrop adapting smoothly across all 7 themes
struct AmbientGlassBackdrop: View {
    var themeMode: AppThemeMode = .dynamic
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = AppThemePalette.resolve(mode: themeMode, systemScheme: scheme)
        ZStack {
            palette.backgroundBase
            RadialGradient(
                colors: [
                    palette.accent.opacity(palette.isLight ? 0.14 : 0.22),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 460
            )
            RadialGradient(
                colors: [
                    palette.secondaryAccent.opacity(palette.isLight ? 0.08 : 0.16),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Book Cover & Visual Components

private let modernCoverPalettes: [(Color, Color)] = [
    (Color(hexRGB: 0x334155), Color(hexRGB: 0x1E293B)),
    (Color(hexRGB: 0x1D4ED8), Color(hexRGB: 0x1E3A8A)),
    (Color(hexRGB: 0x0F766E), Color(hexRGB: 0x115E59)),
    (Color(hexRGB: 0x3F6212), Color(hexRGB: 0x365314)),
    (Color(hexRGB: 0x4338CA), Color(hexRGB: 0x312E81)),
    (Color(hexRGB: 0x6D28D9), Color(hexRGB: 0x4C1D95)),
    (Color(hexRGB: 0x475569), Color(hexRGB: 0x0F172A)),
    (Color(hexRGB: 0x9A3412), Color(hexRGB: 0x7C2D12))
]

struct BookCoverArtwork: View {
    let book: BookItem
    var compact: Bool = false

    @State private var coverImage: UIImage?

    private var paletteIndex: Int {
        var h = 0
        for scalar in book.title.unicodeScalars {
            h = 31 &* h &+ Int(scalar.value)
        }
        return abs(h) % modernCoverPalettes.count
    }

    private var firstGlyph: String {
        for ch in book.title.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch.isLetter || ch.isNumber {
                return String(ch).uppercased()
            }
        }
        return "书"
    }

    var body: some View {
        let corner: CGFloat = compact ? 8 : 10
        let pair = modernCoverPalettes[paletteIndex]

        ZStack {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [pair.0, pair.1],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                HStack(spacing: 0) {
                    Color.clear.frame(width: compact ? 4 : 6)
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1)
                    Spacer()
                }

                Text(firstGlyph)
                    .font(.system(size: compact ? 15 : 21, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.white.opacity(0.92))

                if !compact {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(book.format.uppercased().prefix(4))
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(Color.white.opacity(0.75))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
        }
        .task(id: book.filePathHint) {
            coverImage = await BookCache.getCoverImage(for: book)
        }
    }
}

struct MinimalTagPill: View {
    let text: String
    var tintColor: Color? = nil
    var textColor: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill((tintColor ?? Color.secondary.opacity(0.14)))
                }
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.6)
            }
    }
}

// MARK: - Apple Liquid Glass Interactive Controls

extension View {
    @ViewBuilder
    func adaptiveGlassNavBar() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
        } else {
            self.toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        #else
        self.toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        #endif
    }

    @ViewBuilder
    func appleLiquidGlassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let base: Glass = tint != nil ? .regular.tint(tint!) : .regular
            let glass: Glass = interactive ? base.interactive() : base
            self.glassEffect(glass, in: Capsule())
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.7))
        }
        #else
        self
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.7))
        #endif
    }

    @ViewBuilder
    func appleLiquidGlassRect(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let base: Glass = tint != nil ? .regular.tint(tint!) : .regular
            let glass: Glass = interactive ? base.interactive() : base
            self.glassEffect(glass, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.7))
        }
        #else
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.7))
        #endif
    }

    @ViewBuilder
    func adaptiveGlassSheetBackground(palette: AppThemePalette) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self
        } else {
            self.presentationBackground {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    if palette.mode != .dynamic {
                        Rectangle().fill(palette.surfaceTint.opacity(palette.isLight ? 0.28 : 0.24))
                    }
                    LinearGradient(
                        colors: [
                            .white.opacity(palette.isLight ? 0.28 : 0.08),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                }
            }
        }
        #else
        self.presentationBackground {
            ZStack {
                Rectangle().fill(.regularMaterial)
                if palette.mode != .dynamic {
                    Rectangle().fill(palette.surfaceTint.opacity(palette.isLight ? 0.28 : 0.24))
                }
                LinearGradient(
                    colors: [
                        .white.opacity(palette.isLight ? 0.28 : 0.08),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        }
        #endif
    }
}

struct GlassSegmentedControl<Option: Hashable>: View {
    let options: [(value: Option, title: String)]
    @Binding var selection: Option
    var compact: Bool = false

    @Namespace private var glassNamespace
    @Environment(\.appPalette) private var palette

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            segmentRow(useNativeGlass: true)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            legacySegmentedBody
        }
        #else
        legacySegmentedBody
        #endif
    }

    @ViewBuilder
    private func segmentRow(useNativeGlass: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { item in
                let isSelected = selection == item.value
                Button {
                    if selection != item.value {
                        withAnimation(AppMotion.tabSpring) {
                            selection = item.value
                        }
                    }
                } label: {
                    Text(item.title)
                        .font(compact ? .caption.weight(isSelected ? .semibold : .medium) : .subheadline.weight(isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(isSelected ? palette.accent : .primary.opacity(0.68))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, compact ? 9 : 12)
                        .padding(.vertical, compact ? 5 : 7)
                        .background {
                            if isSelected {
                                if useNativeGlass {
                                    Capsule()
                                        .fill(palette.isLight ? Color.white.opacity(0.76) : palette.accent.opacity(0.28))
                                        .overlay {
                                            Capsule().strokeBorder(
                                                .white.opacity(palette.isLight ? 0.90 : 0.36),
                                                lineWidth: 0.65
                                            )
                                        }
                                        .shadow(color: .black.opacity(palette.isLight ? 0.08 : 0.22), radius: 5, x: 0, y: 2)
                                        .matchedGeometryEffect(id: "glassSegmentIndicator", in: glassNamespace)
                                } else {
                                    Capsule()
                                        .fill(.regularMaterial)
                                        .overlay {
                                            Capsule().fill(
                                                LinearGradient(
                                                    colors: [
                                                        .white.opacity(palette.isLight ? 0.62 : 0.24),
                                                        palette.accent.opacity(palette.isLight ? 0.12 : 0.22)
                                                    ],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                        }
                                        .overlay {
                                            Capsule().strokeBorder(
                                                LinearGradient(
                                                    colors: [
                                                        .white.opacity(palette.isLight ? 0.85 : 0.38),
                                                        palette.accent.opacity(0.32)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                ),
                                                lineWidth: 0.85
                                            )
                                        }
                                        .shadow(color: .black.opacity(palette.isLight ? 0.08 : 0.24), radius: 5, x: 0, y: 2)
                                        .matchedGeometryEffect(id: "glassSegmentIndicator", in: glassNamespace)
                                }
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
    }

    @ViewBuilder
    private var legacySegmentedBody: some View {
        segmentRow(useNativeGlass: false)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(palette.surfaceTint.opacity(palette.isLight ? 0.26 : 0.30))
                }
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(palette.isLight ? 0.60 : 0.24),
                            .white.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            }
            .shadow(color: .black.opacity(palette.isLight ? 0.05 : 0.18), radius: 6, x: 0, y: 2)
    }
}

extension GlassSegmentedControl where Option == Int {
    init(titles: [String], selection: Binding<Int>, compact: Bool = false) {
        self.options = titles.enumerated().map { ($0.offset, $0.element) }
        self._selection = selection
        self.compact = compact
    }
}

struct GlassCircleIconButton: View {
    let systemImage: String
    var size: CGFloat = 34
    var iconFont: Font = .subheadline.weight(.semibold)
    var isActive: Bool = false
    var tintColor: Color? = nil
    var action: () -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        let activeTint = tintColor ?? palette.accent
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let glass: Glass = isActive
                ? .regular.tint(activeTint.opacity(0.24)).interactive()
                : .regular.interactive()
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(iconFont)
                    .foregroundStyle(isActive ? activeTint : .primary)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(glass, in: Circle())
        } else {
            legacyCircleBody(activeTint: activeTint)
        }
        #else
        legacyCircleBody(activeTint: activeTint)
        #endif
    }

    @ViewBuilder
    private func legacyCircleBody(activeTint: Color) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(iconFont)
                .foregroundStyle(isActive ? activeTint : .primary)
                .frame(width: size, height: size)
                .background {
                    ZStack {
                        Circle().fill(.ultraThinMaterial)
                        if isActive {
                            Circle().fill(activeTint.opacity(palette.isLight ? 0.16 : 0.24))
                        } else if palette.mode != .dynamic {
                            Circle().fill(palette.surfaceTint.opacity(palette.isLight ? 0.32 : 0.26))
                        }
                    }
                }
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(palette.isLight ? 0.68 : 0.28),
                                (isActive ? activeTint.opacity(0.35) : .white.opacity(0.08))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.85
                    )
                }
                .shadow(color: .black.opacity(palette.isLight ? 0.06 : 0.20), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(GlassPressButtonStyle())
    }
}

struct GlassCapsuleChip: View {
    let title: String
    var systemImage: String? = nil
    var selected: Bool = false
    var tintColor: Color? = nil
    var action: () -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        let activeTint = tintColor ?? palette.accent
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let glass: Glass = selected
                ? .regular.tint(activeTint.opacity(0.24)).interactive()
                : .regular.interactive()
            Button(action: action) {
                HStack(spacing: 4) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.caption2.weight(.semibold))
                    }
                    Text(title)
                        .font(.caption.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(selected ? activeTint : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(glass, in: Capsule())
        } else {
            legacyCapsuleBody(activeTint: activeTint)
        }
        #else
        legacyCapsuleBody(activeTint: activeTint)
        #endif
    }

    @ViewBuilder
    private func legacyCapsuleBody(activeTint: Color) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? activeTint : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                ZStack {
                    Capsule().fill(selected ? .regularMaterial : .ultraThinMaterial)
                    if selected {
                        Capsule().fill(activeTint.opacity(palette.isLight ? 0.16 : 0.24))
                    } else if palette.mode != .dynamic {
                        Capsule().fill(palette.surfaceTint.opacity(palette.isLight ? 0.26 : 0.22))
                    }
                }
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(palette.isLight ? 0.65 : 0.28),
                            selected ? activeTint.opacity(0.45) : .white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: selected ? 0.95 : 0.75
                )
            }
            .shadow(color: .black.opacity(palette.isLight ? (selected ? 0.07 : 0.04) : 0.18), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(GlassPressButtonStyle())
    }
}

struct GlassHorizontalPager<PageContent: View>: View {
    @Binding var selection: Int
    let pageCount: Int
    var fillHeight: Bool = true
    @ViewBuilder var pageContent: (Int) -> PageContent

    @State private var scrollPage: Int? = 0
    @State private var measuredWidth: CGFloat = 0

    var body: some View {
        Group {
            if fillHeight {
                GeometryReader { geo in
                    let pageW = max(1, geo.size.width)
                    let pageH = max(1, geo.size.height)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(0..<pageCount, id: \.self) { idx in
                                pageContent(idx)
                                    .frame(width: pageW, height: pageH, alignment: .top)
                                    .id(idx)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(0, for: .scrollContent)
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $scrollPage)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(0..<pageCount, id: \.self) { idx in
                            Group {
                                if measuredWidth > 1 {
                                    pageContent(idx)
                                        .frame(width: measuredWidth)
                                } else {
                                    pageContent(idx)
                                        .containerRelativeFrame(.horizontal)
                                }
                            }
                            .id(idx)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(0, for: .scrollContent)
                .fixedSize(horizontal: false, vertical: true)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollPage)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                    if w > 1, abs(measuredWidth - w) > 0.5 {
                        measuredWidth = w
                    }
                }
            }
        }
        .onAppear {
            scrollPage = selection
        }
        .onChange(of: selection) { _, newValue in
            if scrollPage != newValue {
                withAnimation(AppMotion.tabSpring) {
                    scrollPage = newValue
                }
            }
        }
        .onChange(of: scrollPage) { _, newPage in
            if let newPage, newPage != selection {
                withAnimation(AppMotion.tabSpring) {
                    selection = newPage
                }
            }
        }
    }
}

struct LiquidGlassTabItem: Identifiable {
    let id: Int
    let title: String
    let systemImage: String
    let selectedImage: String
}

struct LiquidGlassTabBar: View {
    let items: [LiquidGlassTabItem]
    @Binding var selectedTab: Int

    @Namespace private var tabNamespace
    @Environment(\.appPalette) private var palette

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                tabBarItemsRow(useNativeGlass: true)
                    .padding(5)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        } else {
            legacyTabBar
        }
        #else
        legacyTabBar
        #endif
    }

    @ViewBuilder
    private func tabBarItemsRow(useNativeGlass: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                let isSelected = selectedTab == item.id
                Button {
                    if selectedTab != item.id {
                        withAnimation(AppMotion.tabSpring) {
                            selectedTab = item.id
                        }
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: isSelected ? item.selectedImage : item.systemImage)
                            .font(.system(size: 18, weight: isSelected ? .semibold : .medium))
                            .symbolEffect(.bounce.byLayer, value: isSelected)
                        Text(item.title)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? palette.accent : .primary.opacity(0.68))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        if isSelected {
                            if useNativeGlass {
                                Capsule()
                                    .fill(palette.accent.opacity(palette.isLight ? 0.14 : 0.24))
                                    .overlay {
                                        Capsule().strokeBorder(
                                            .white.opacity(palette.isLight ? 0.72 : 0.32),
                                            lineWidth: 0.65
                                        )
                                    }
                                    .matchedGeometryEffect(id: "liquidGlassTabPill", in: tabNamespace)
                            } else {
                                Capsule()
                                    .fill(.regularMaterial)
                                    .overlay {
                                        Capsule().fill(
                                            LinearGradient(
                                                colors: [
                                                    .white.opacity(palette.isLight ? 0.65 : 0.22),
                                                    palette.accent.opacity(palette.isLight ? 0.14 : 0.24)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                    }
                                    .overlay {
                                        Capsule().strokeBorder(
                                            LinearGradient(
                                                colors: [
                                                    .white.opacity(palette.isLight ? 0.85 : 0.42),
                                                    palette.accent.opacity(0.35)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 0.9
                                        )
                                    }
                                    .shadow(color: palette.accent.opacity(palette.isLight ? 0.14 : 0.24), radius: 8, x: 0, y: 3)
                                    .matchedGeometryEffect(id: "liquidGlassTabPill", in: tabNamespace)
                            }
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(GlassPressButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var legacyTabBar: some View {
        tabBarItemsRow(useNativeGlass: false)
            .padding(5)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().fill(
                        LinearGradient(
                            colors: [
                                palette.surfaceTint.opacity(palette.isLight ? 0.42 : 0.48),
                                palette.surfaceTint.opacity(palette.isLight ? 0.24 : 0.30)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(palette.isLight ? 0.78 : 0.32),
                            .white.opacity(palette.isLight ? 0.22 : 0.08),
                            .white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
            }
            .shadow(color: .black.opacity(palette.isLight ? 0.12 : 0.36), radius: 18, x: 0, y: 8)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
    }
}

struct MinimalPagerDots: View {
    let pageCount: Int
    let currentPage: Int
    var onSelectPage: (Int) -> Void

    @Environment(\.appPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { idx in
                let isCurrent = idx == currentPage
                Capsule()
                    .fill(isCurrent ? palette.accent : Color.secondary.opacity(0.32))
                    .frame(width: isCurrent ? 16 : 5, height: 5)
                    .animation(.spring(response: 0.28, dampingFraction: 0.72), value: currentPage)
                    .onTapGesture {
                        if currentPage != idx {
                            onSelectPage(idx)
                        }
                    }
            }
        }
    }
}

struct SmoothLinearProgressBar: View {
    let progress: Double
    var height: CGFloat = 4
    var tintColor: Color? = nil
    @Environment(\.appPalette) private var palette

    var body: some View {
        let clamped = min(1.0, max(0.0, progress))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tintColor ?? palette.accent)
                    .frame(width: max(clamped > 0 ? height : 0, geo.size.width * clamped))
                    .animation(.easeOut(duration: 0.25), value: clamped)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Custom Reader Color Swatch Helper

enum ReaderColorTarget: String, CaseIterable, Identifiable {
    case background
    case focusUnit
    case bottomBar
    case sentenceCard
    case wordCard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: return "阅读背景"
        case .focusUnit: return "当前句卡"
        case .bottomBar: return "底部区域"
        case .sentenceCard: return "句子译文卡"
        case .wordCard: return "查词浮卡"
        }
    }

    var presetColors: [Color] {
        switch self {
        case .background:
            return [
                Color(hexRGB: 0xFAF8F5),
                Color(hexRGB: 0xF5ECD8),
                Color(hexRGB: 0xE6EFE6),
                Color(hexRGB: 0xEAEFF5),
                Color(hexRGB: 0x11141B),
                Color(hexRGB: 0x050608)
            ]
        case .focusUnit:
            return [
                Color(hexRGB: 0xFFFFFF),
                Color(hexRGB: 0xFBF3E0),
                Color(hexRGB: 0xEEF6EE),
                Color(hexRGB: 0xEFF4FA),
                Color(hexRGB: 0x1D2330),
                Color(hexRGB: 0x12151C)
            ]
        case .bottomBar:
            return [
                Color(hexRGB: 0xF3F5F8),
                Color(hexRGB: 0xEFE4CD),
                Color(hexRGB: 0xDCE7DC),
                Color(hexRGB: 0xDCE4EE),
                Color(hexRGB: 0x171C26),
                Color(hexRGB: 0x0B0D12)
            ]
        case .sentenceCard:
            return [
                Color(hexRGB: 0xFFFFFF),
                Color(hexRGB: 0xFAF0DA),
                Color(hexRGB: 0xEBF4EB),
                Color(hexRGB: 0xECF2F9),
                Color(hexRGB: 0x202736),
                Color(hexRGB: 0x141821)
            ]
        case .wordCard:
            return [
                Color(hexRGB: 0xFFFFFF),
                Color(hexRGB: 0xFCF5E5),
                Color(hexRGB: 0xEEF6EE),
                Color(hexRGB: 0xEDF3FA),
                Color(hexRGB: 0x242C3D),
                Color(hexRGB: 0x181D27)
            ]
        }
    }

    func value(in settings: ReaderSettings) -> Int64 {
        switch self {
        case .background: return settings.readerBgColorHex
        case .focusUnit: return settings.readerFocusColorHex
        case .bottomBar: return settings.readerBottomBgColorHex
        case .sentenceCard: return settings.readerSentenceCardColorHex
        case .wordCard: return settings.readerWordCardColorHex
        }
    }

    func update(_ hex: Int64, in settings: inout ReaderSettings) {
        switch self {
        case .background: settings.readerBgColorHex = hex
        case .focusUnit: settings.readerFocusColorHex = hex
        case .bottomBar: settings.readerBottomBgColorHex = hex
        case .sentenceCard: settings.readerSentenceCardColorHex = hex
        case .wordCard: settings.readerWordCardColorHex = hex
        }
    }
}
