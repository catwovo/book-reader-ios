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
    var cornerRadius: CGFloat = 20
    var tintColor: Color? = nil
    @Environment(\.appPalette) private var palette
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    if let tintColor {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tintColor.opacity(0.68))
                    } else if palette.mode != .dynamic {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(palette.surfaceTint.opacity(palette.isLight ? 0.45 : 0.35))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(palette.isLight ? 0.55 : 0.28),
                                .white.opacity(palette.isLight ? 0.16 : 0.08),
                                .white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: .black.opacity(palette.isLight ? 0.06 : 0.22), radius: 12, x: 0, y: 5)
    }
}

struct GlassGroupedCard<Content: View>: View {
    let index: Int
    let count: Int
    var outerRadius: CGFloat = 20
    var innerRadius: CGFloat = 6
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
        content()
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tintColor {
                        shape.fill(tintColor.opacity(0.62))
                    } else if palette.mode != .dynamic {
                        shape.fill(palette.surfaceTint.opacity(palette.isLight ? 0.42 : 0.32))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(palette.isLight ? 0.50 : 0.24),
                            .white.opacity(0.07)
                        ],
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
                        Image(systemName: systemImage)
                            .font(.title3)
                            .foregroundStyle(palette.accent)
                            .frame(width: 34, height: 34)
                            .background(palette.accent.opacity(0.14))
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
            .background((tintColor ?? Color.secondary.opacity(0.14)))
            .clipShape(Capsule())
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
