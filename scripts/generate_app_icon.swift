import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha overrideAlpha: CGFloat? = nil) -> CGColor {
    let a = overrideAlpha ?? CGFloat((hex >> 24) & 0xFF) / 255.0
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func makeLinearGradient(_ colors: [CGColor], locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

enum IconStyleKind {
    case warmOrange
    case pearlWhite
    case midnightBlue
}

struct IconThemeSpec {
    let assetName: String
    let previewName: String
    let kind: IconStyleKind
}

let iconSpecs: [IconThemeSpec] = [
    IconThemeSpec(
        assetName: "AppIcon",
        previewName: "IconPreviewWarmOrange",
        kind: .warmOrange
    ),
    IconThemeSpec(
        assetName: "AppIconPearl",
        previewName: "IconPreviewPearlWhite",
        kind: .pearlWhite
    ),
    IconThemeSpec(
        assetName: "AppIconMidnight",
        previewName: "IconPreviewMidnightBlue",
        kind: .midnightBlue
    )
]

func drawColoredProfileCat(
    in ctx: CGContext,
    bodyTop: UInt32,
    bodyBottom: UInt32,
    backEar: UInt32,
    tail: UInt32,
    heartTop: UInt32,
    heartBottom: UInt32,
    lineColor: CGColor,
    outerStroke: CGColor
) {
    func cx(_ u: CGFloat) -> CGFloat { 28.5 + u * 0.51 }
    func cy(_ v: CGFloat) -> CGFloat { 20.0 + v * 0.54 }

    // Back ear
    let earPath = CGMutablePath()
    earPath.move(to: CGPoint(x: cx(46), y: cy(22)))
    earPath.addCurve(to: CGPoint(x: cx(56.0), y: cy(12.0)), control1: CGPoint(x: cx(50), y: cy(16)), control2: CGPoint(x: cx(53.5), y: cy(12.5)))
    earPath.addCurve(to: CGPoint(x: cx(56.6), y: cy(16.5)), control1: CGPoint(x: cx(57.2), y: cy(11.8)), control2: CGPoint(x: cx(57.4), y: cy(13.4)))
    earPath.addLine(to: CGPoint(x: cx(54.5), y: cy(25.0)))
    earPath.closeSubpath()
    ctx.addPath(earPath)
    ctx.setFillColor(color(backEar))
    ctx.fillPath()
    ctx.addPath(earPath)
    ctx.setStrokeColor(outerStroke)
    ctx.setLineWidth(1.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Curled tail
    let tailPath = CGMutablePath()
    tailPath.move(to: CGPoint(x: cx(60.0), y: cy(89.5)))
    tailPath.addCurve(to: CGPoint(x: cx(80.0), y: cy(75.2)), control1: CGPoint(x: cx(71.5), y: cy(92.0)), control2: CGPoint(x: cx(79.2), y: cy(86.0)))
    tailPath.addCurve(to: CGPoint(x: cx(69.2), y: cy(46.5)), control1: CGPoint(x: cx(80.8), y: cy(64.2)), control2: CGPoint(x: cx(68.8), y: cy(56.0)))
    tailPath.addCurve(to: CGPoint(x: cx(86.2), y: cy(39.5)), control1: CGPoint(x: cx(69.5), y: cy(37.5)), control2: CGPoint(x: cx(79.5), y: cy(34.5)))
    tailPath.addCurve(to: CGPoint(x: cx(83.8), y: cy(54.5)), control1: CGPoint(x: cx(91.5), y: cy(43.5)), control2: CGPoint(x: cx(90.2), y: cy(52.5)))
    tailPath.addCurve(to: CGPoint(x: cx(76.0), y: cy(50.2)), control1: CGPoint(x: cx(79.8), y: cy(55.6)), control2: CGPoint(x: cx(76.5), y: cy(53.2)))

    ctx.addPath(tailPath)
    ctx.setStrokeColor(outerStroke)
    ctx.setLineWidth(4.2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    ctx.addPath(tailPath)
    ctx.setStrokeColor(color(tail))
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Cat body
    let bodyPath = CGMutablePath()
    bodyPath.move(to: CGPoint(x: cx(44.2), y: cy(8.2)))
    bodyPath.addCurve(to: CGPoint(x: cx(45.8), y: cy(20.5)), control1: CGPoint(x: cx(45.2), y: cy(12.5)), control2: CGPoint(x: cx(45.4), y: cy(17.5)))
    bodyPath.addCurve(to: CGPoint(x: cx(60.6), y: cy(31.2)), control1: CGPoint(x: cx(54.5), y: cy(22.2)), control2: CGPoint(x: cx(59.8), y: cy(26.8)))
    bodyPath.addCurve(to: CGPoint(x: cx(63.2), y: cy(36.8)), control1: CGPoint(x: cx(63.4), y: cy(33.2)), control2: CGPoint(x: cx(64.5), y: cy(35.0)))
    bodyPath.addCurve(to: CGPoint(x: cx(47.2), y: cy(40.0)), control1: CGPoint(x: cx(61.0), y: cy(39.8)), control2: CGPoint(x: cx(54.0), y: cy(40.4)))
    bodyPath.addCurve(to: CGPoint(x: cx(64.5), y: cy(61.5)), control1: CGPoint(x: cx(48.0), y: cy(46.0)), control2: CGPoint(x: cx(56.5), y: cy(53.0)))
    bodyPath.addCurve(to: CGPoint(x: cx(70.5), y: cy(88.5)), control1: CGPoint(x: cx(72.5), y: cy(70.0)), control2: CGPoint(x: cx(75.5), y: cy(81.5)))
    bodyPath.addCurve(to: CGPoint(x: cx(46.5), y: cy(90.6)), control1: CGPoint(x: cx(66.5), y: cy(92.0)), control2: CGPoint(x: cx(55.5), y: cy(92.2)))
    bodyPath.addCurve(to: CGPoint(x: cx(20.5), y: cy(75.5)), control1: CGPoint(x: cx(35.5), y: cy(92.0)), control2: CGPoint(x: cx(24.5), y: cy(87.0)))
    bodyPath.addCurve(to: CGPoint(x: cx(26.5), y: cy(30.5)), control1: CGPoint(x: cx(16.5), y: cy(63.5)), control2: CGPoint(x: cx(18.5), y: cy(46.0)))
    bodyPath.addCurve(to: CGPoint(x: cx(44.2), y: cy(8.2)), control1: CGPoint(x: cx(32.0), y: cy(20.0)), control2: CGPoint(x: cx(39.0), y: cy(12.0)))
    bodyPath.closeSubpath()

    let catGrad = makeLinearGradient([color(bodyTop), color(bodyBottom)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(catGrad, start: CGPoint(x: 54, y: 23), end: CGPoint(x: 54, y: 70), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    ctx.addPath(bodyPath)
    ctx.setStrokeColor(outerStroke)
    ctx.setLineWidth(1.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Inner heart
    let heartPath = CGMutablePath()
    heartPath.move(to: CGPoint(x: cx(46.8), y: cy(89.6)))
    heartPath.addCurve(to: CGPoint(x: cx(35.8), y: cy(69.2)), control1: CGPoint(x: cx(36.8), y: cy(84.2)), control2: CGPoint(x: cx(33.2), y: cy(75.2)))
    heartPath.addCurve(to: CGPoint(x: cx(46.8), y: cy(69.6)), control1: CGPoint(x: cx(38.0), y: cy(64.2)), control2: CGPoint(x: cx(44.2), y: cy(64.6)))
    heartPath.addCurve(to: CGPoint(x: cx(57.8), y: cy(69.2)), control1: CGPoint(x: cx(49.4), y: cy(64.6)), control2: CGPoint(x: cx(55.6), y: cy(64.2)))
    heartPath.addCurve(to: CGPoint(x: cx(46.8), y: cy(89.6)), control1: CGPoint(x: cx(60.4), y: cy(75.2)), control2: CGPoint(x: cx(56.8), y: cy(84.2)))
    heartPath.closeSubpath()

    let heartGrad = makeLinearGradient([color(heartTop), color(heartBottom)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(heartPath)
    ctx.clip()
    ctx.drawLinearGradient(heartGrad, start: CGPoint(x: 54, y: 54), end: CGPoint(x: 54, y: 70), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Signature throat swoosh
    ctx.beginPath()
    ctx.move(to: CGPoint(x: cx(50.5), y: cy(40.0)))
    ctx.addCurve(to: CGPoint(x: cx(20.6), y: cy(65.5)), control1: CGPoint(x: cx(38.5), y: cy(40.5)), control2: CGPoint(x: cx(27.5), y: cy(50.5)))
    ctx.setStrokeColor(lineColor)
    ctx.setLineWidth(1.3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    ctx.addPath(heartPath)
    ctx.setStrokeColor(lineColor)
    ctx.setLineWidth(1.2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

func renderWarmOrangeIcon(in ctx: CGContext) {
    // 1. Background linear gradient
    let bgGrad = makeLinearGradient([color(0xFFFFB840), color(0xFFF25521)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: 108, height: 108))
    ctx.clip()
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 108), options: [])
    ctx.restoreGState()

    let glowGrad = makeLinearGradient([color(0x47FFFFFF), color(0x00FFFFFF)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.drawRadialGradient(glowGrad, startCenter: CGPoint(x: 54, y: 20), startRadius: 0, endCenter: CGPoint(x: 54, y: 20), endRadius: 58, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // Foreground scaled ~1.2x (0.86 * 1.2 ≈ 1.03)
    ctx.saveGState()
    ctx.translateBy(x: 54, y: 54)
    ctx.scaleBy(x: 1.03, y: 1.03)
    ctx.translateBy(x: -54, y: -54)

    ctx.setFillColor(color(0xFF6E1A00, alpha: 0.22))
    ctx.fillEllipse(in: CGRect(x: 22, y: 77.5, width: 64, height: 7.5))

    let coverPath = CGMutablePath()
    coverPath.move(to: CGPoint(x: 19, y: 45))
    coverPath.addCurve(to: CGPoint(x: 54, y: 49), control1: CGPoint(x: 20, y: 39.5), control2: CGPoint(x: 36, y: 41))
    coverPath.addCurve(to: CGPoint(x: 89, y: 45), control1: CGPoint(x: 72, y: 41), control2: CGPoint(x: 88, y: 39.5))
    coverPath.addLine(to: CGPoint(x: 86.2, y: 75.5))
    coverPath.addCurve(to: CGPoint(x: 80.5, y: 78.5), control1: CGPoint(x: 85.8, y: 78.2), control2: CGPoint(x: 83.2, y: 79.2))
    coverPath.addCurve(to: CGPoint(x: 54, y: 81.2), control1: CGPoint(x: 68.5, y: 75.5), control2: CGPoint(x: 58.5, y: 78))
    coverPath.addCurve(to: CGPoint(x: 27.5, y: 78.5), control1: CGPoint(x: 49.5, y: 78), control2: CGPoint(x: 39.5, y: 75.5))
    coverPath.addCurve(to: CGPoint(x: 21.8, y: 75.5), control1: CGPoint(x: 24.8, y: 79.2), control2: CGPoint(x: 22.2, y: 78.2))
    coverPath.closeSubpath()
    ctx.addPath(coverPath)
    ctx.setFillColor(color(0xFFB3320D, alpha: 0.36))
    ctx.fillPath()

    let fanPages = CGMutablePath()
    fanPages.move(to: CGPoint(x: 20.5, y: 43.2))
    fanPages.addCurve(to: CGPoint(x: 54, y: 47.6), control1: CGPoint(x: 21.5, y: 38.2), control2: CGPoint(x: 36.5, y: 39.8))
    fanPages.addCurve(to: CGPoint(x: 87.5, y: 43.2), control1: CGPoint(x: 71.5, y: 39.8), control2: CGPoint(x: 86.5, y: 38.2))
    fanPages.addLine(to: CGPoint(x: 84.8, y: 73.6))
    fanPages.addCurve(to: CGPoint(x: 79.5, y: 76.2), control1: CGPoint(x: 84.4, y: 76), control2: CGPoint(x: 82, y: 76.8))
    fanPages.addCurve(to: CGPoint(x: 54, y: 79.2), control1: CGPoint(x: 68, y: 73.5), control2: CGPoint(x: 58, y: 75.8))
    fanPages.addCurve(to: CGPoint(x: 28.5, y: 76.2), control1: CGPoint(x: 50, y: 75.8), control2: CGPoint(x: 40, y: 73.5))
    fanPages.addCurve(to: CGPoint(x: 23.2, y: 73.6), control1: CGPoint(x: 26, y: 76.8), control2: CGPoint(x: 23.6, y: 76))
    fanPages.closeSubpath()
    ctx.addPath(fanPages)
    ctx.setFillColor(color(0xFFE7DDD0))
    ctx.fillPath()

    let leftWing = CGMutablePath()
    leftWing.move(to: CGPoint(x: 22.2, y: 41.8))
    leftWing.addCurve(to: CGPoint(x: 54, y: 46.8), control1: CGPoint(x: 22.8, y: 37.5), control2: CGPoint(x: 37.5, y: 39))
    leftWing.addLine(to: CGPoint(x: 54, y: 77.2))
    leftWing.addCurve(to: CGPoint(x: 26.2, y: 73.5), control1: CGPoint(x: 48, y: 73), control2: CGPoint(x: 36, y: 71.2))
    leftWing.addCurve(to: CGPoint(x: 23, y: 70.8), control1: CGPoint(x: 24.2, y: 74), control2: CGPoint(x: 23.2, y: 72.8))
    leftWing.closeSubpath()

    let rightWing = CGMutablePath()
    rightWing.move(to: CGPoint(x: 54, y: 46.8))
    rightWing.addCurve(to: CGPoint(x: 85.8, y: 41.8), control1: CGPoint(x: 70.5, y: 39), control2: CGPoint(x: 85.2, y: 37.5))
    rightWing.addLine(to: CGPoint(x: 85, y: 70.8))
    rightWing.addCurve(to: CGPoint(x: 81.8, y: 73.5), control1: CGPoint(x: 84.8, y: 72.8), control2: CGPoint(x: 83.8, y: 74))
    rightWing.addCurve(to: CGPoint(x: 54, y: 77.2), control1: CGPoint(x: 72, y: 71.2), control2: CGPoint(x: 60, y: 73))
    rightWing.closeSubpath()

    let leftGrad = makeLinearGradient([color(0xFFFFFFFF), color(0xFFF6EFE7)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(leftWing)
    ctx.clip()
    ctx.drawLinearGradient(leftGrad, start: CGPoint(x: 54, y: 38), end: CGPoint(x: 54, y: 77), options: [])
    ctx.restoreGState()

    let rightGrad = makeLinearGradient([color(0xFFFAF4EC), color(0xFFEBE0D4)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(rightWing)
    ctx.clip()
    ctx.drawLinearGradient(rightGrad, start: CGPoint(x: 54, y: 38), end: CGPoint(x: 54, y: 77), options: [])
    ctx.restoreGState()

    let wingsClip = CGMutablePath()
    wingsClip.addPath(leftWing)
    wingsClip.addPath(rightWing)
    ctx.saveGState()
    ctx.addPath(wingsClip)
    ctx.clip()
    let gutterGrad = makeLinearGradient([color(0x009C7B5E), color(0x339C7B5E), color(0x009C7B5E)], locations: [0.0, 0.5, 1.0])
    ctx.saveGState()
    ctx.addRect(CGRect(x: 46, y: 44, width: 16, height: 35))
    ctx.clip()
    ctx.drawLinearGradient(gutterGrad, start: CGPoint(x: 46, y: 54), end: CGPoint(x: 62, y: 54), options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(0xFF8C5332, alpha: 0.16))
    ctx.fillEllipse(in: CGRect(x: 38, y: 66.5, width: 32, height: 5.2))
    ctx.restoreGState()

    ctx.setStrokeColor(color(0xFFD5C4B2))
    ctx.setLineWidth(1.1)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 54, y: 46.8))
    ctx.addLine(to: CGPoint(x: 54, y: 77.2))
    ctx.strokePath()

    drawColoredProfileCat(
        in: ctx,
        bodyTop: 0xFF47342E,
        bodyBottom: 0xFF2B1E1A,
        backEar: 0xFF281B18,
        tail: 0xFF342420,
        heartTop: 0xFFFF7A59,
        heartBottom: 0xFFE8462A,
        lineColor: color(0xFFFFE5CF, alpha: 0.90),
        outerStroke: color(0xFF231613)
    )

    ctx.restoreGState()
}

func renderPearlWhiteIcon(in ctx: CGContext) {
    let bgGrad = makeLinearGradient([color(0xFFFFFFFF), color(0xFFF0F2F7)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: 108, height: 108))
    ctx.clip()
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 108), options: [])
    ctx.restoreGState()

    let glowGrad = makeLinearGradient([color(0x29FF9F43), color(0x00FF9F43)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.drawRadialGradient(glowGrad, startCenter: CGPoint(x: 54, y: 54), startRadius: 0, endCenter: CGPoint(x: 54, y: 54), endRadius: 50, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.translateBy(x: 54, y: 54)
    ctx.scaleBy(x: 1.03, y: 1.03)
    ctx.translateBy(x: -54, y: -54)

    ctx.setFillColor(color(0xFFB34416, alpha: 0.16))
    ctx.fillEllipse(in: CGRect(x: 24, y: 77.5, width: 60, height: 7.5))

    let cradleCover = CGMutablePath()
    cradleCover.move(to: CGPoint(x: 23.5, y: 36.5))
    cradleCover.addCurve(to: CGPoint(x: 25.0, y: 74.5), control1: CGPoint(x: 20.0, y: 48.0), control2: CGPoint(x: 19.5, y: 63.0))
    cradleCover.addCurve(to: CGPoint(x: 37.5, y: 78.0), control1: CGPoint(x: 27.0, y: 78.5), control2: CGPoint(x: 32.0, y: 79.2))
    cradleCover.addCurve(to: CGPoint(x: 54.0, y: 81.2), control1: CGPoint(x: 45.5, y: 76.2), control2: CGPoint(x: 50.5, y: 78.5))
    cradleCover.addCurve(to: CGPoint(x: 70.5, y: 78.0), control1: CGPoint(x: 57.5, y: 78.5), control2: CGPoint(x: 62.5, y: 76.2))
    cradleCover.addCurve(to: CGPoint(x: 83.0, y: 74.5), control1: CGPoint(x: 76.0, y: 79.2), control2: CGPoint(x: 81.0, y: 78.5))
    cradleCover.addCurve(to: CGPoint(x: 84.5, y: 36.5), control1: CGPoint(x: 88.5, y: 63.0), control2: CGPoint(x: 88.0, y: 48.0))
    cradleCover.addCurve(to: CGPoint(x: 78.2, y: 35.0), control1: CGPoint(x: 83.8, y: 34.2), control2: CGPoint(x: 81.0, y: 33.8))
    cradleCover.addCurve(to: CGPoint(x: 54.0, y: 47.5), control1: CGPoint(x: 68.5, y: 39.2), control2: CGPoint(x: 60.0, y: 43.2))
    cradleCover.addCurve(to: CGPoint(x: 29.8, y: 35.0), control1: CGPoint(x: 48.0, y: 43.2), control2: CGPoint(x: 39.5, y: 39.2))
    cradleCover.addCurve(to: CGPoint(x: 23.5, y: 36.5), control1: CGPoint(x: 27.0, y: 33.8), control2: CGPoint(x: 24.2, y: 34.2))
    cradleCover.closeSubpath()

    let coverGrad = makeLinearGradient([color(0xFFFF8844), color(0xFFE05224)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(cradleCover)
    ctx.clip()
    ctx.drawLinearGradient(coverGrad, start: CGPoint(x: 54, y: 34), end: CGPoint(x: 54, y: 81), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    let leftCradlePage = CGMutablePath()
    leftCradlePage.move(to: CGPoint(x: 26.2, y: 37.8))
    leftCradlePage.addCurve(to: CGPoint(x: 27.6, y: 72.2), control1: CGPoint(x: 23.2, y: 48.5), control2: CGPoint(x: 22.8, y: 61.5))
    leftCradlePage.addCurve(to: CGPoint(x: 37.5, y: 74.8), control1: CGPoint(x: 29.0, y: 75.0), control2: CGPoint(x: 33.0, y: 75.8))
    leftCradlePage.addCurve(to: CGPoint(x: 54.0, y: 77.8), control1: CGPoint(x: 45.2, y: 73.2), control2: CGPoint(x: 50.2, y: 75.2))
    leftCradlePage.addLine(to: CGPoint(x: 54.0, y: 48.8))
    leftCradlePage.addCurve(to: CGPoint(x: 29.8, y: 36.5), control1: CGPoint(x: 48.2, y: 44.8), control2: CGPoint(x: 40.0, y: 40.5))
    leftCradlePage.addCurve(to: CGPoint(x: 26.2, y: 37.8), control1: CGPoint(x: 28.0, y: 35.8), control2: CGPoint(x: 26.8, y: 36.2))
    leftCradlePage.closeSubpath()

    let rightCradlePage = CGMutablePath()
    rightCradlePage.move(to: CGPoint(x: 54.0, y: 48.8))
    rightCradlePage.addCurve(to: CGPoint(x: 78.2, y: 36.5), control1: CGPoint(x: 59.8, y: 44.8), control2: CGPoint(x: 68.0, y: 40.5))
    rightCradlePage.addCurve(to: CGPoint(x: 81.8, y: 37.8), control1: CGPoint(x: 80.0, y: 35.8), control2: CGPoint(x: 81.2, y: 36.2))
    rightCradlePage.addCurve(to: CGPoint(x: 80.4, y: 72.2), control1: CGPoint(x: 84.8, y: 48.5), control2: CGPoint(x: 85.2, y: 61.5))
    rightCradlePage.addCurve(to: CGPoint(x: 70.5, y: 74.8), control1: CGPoint(x: 79.0, y: 75.0), control2: CGPoint(x: 75.0, y: 75.8))
    rightCradlePage.addCurve(to: CGPoint(x: 54.0, y: 77.8), control1: CGPoint(x: 62.8, y: 73.2), control2: CGPoint(x: 57.8, y: 75.2))
    rightCradlePage.closeSubpath()

    let leftPageGrad = makeLinearGradient([color(0xFFFFFCF7), color(0xFFF4EBE0)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(leftCradlePage)
    ctx.clip()
    ctx.drawLinearGradient(leftPageGrad, start: CGPoint(x: 54, y: 36), end: CGPoint(x: 54, y: 78), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    let rightPageGrad = makeLinearGradient([color(0xFFFBF5EC), color(0xFFECE0D0)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(rightCradlePage)
    ctx.clip()
    ctx.drawLinearGradient(rightPageGrad, start: CGPoint(x: 54, y: 36), end: CGPoint(x: 54, y: 78), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    let pagesClip = CGMutablePath()
    pagesClip.addPath(leftCradlePage)
    pagesClip.addPath(rightCradlePage)
    ctx.saveGState()
    ctx.addPath(pagesClip)
    ctx.clip()
    let gutterGrad = makeLinearGradient([color(0x00B6906F), color(0x38B6906F), color(0x00B6906F)], locations: [0.0, 0.5, 1.0])
    ctx.saveGState()
    ctx.addRect(CGRect(x: 47, y: 44, width: 14, height: 35))
    ctx.clip()
    ctx.drawLinearGradient(gutterGrad, start: CGPoint(x: 47, y: 54), end: CGPoint(x: 61, y: 54), options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(0xFFC95A27, alpha: 0.16))
    ctx.fillEllipse(in: CGRect(x: 38, y: 66.5, width: 32, height: 5.2))
    ctx.restoreGState()

    ctx.setStrokeColor(color(0xFFD6C3AF))
    ctx.setLineWidth(1.1)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 54, y: 48.8))
    ctx.addLine(to: CGPoint(x: 54, y: 77.8))
    ctx.strokePath()

    drawColoredProfileCat(
        in: ctx,
        bodyTop: 0xFFFFB442,
        bodyBottom: 0xFFF15B25,
        backEar: 0xFFD94A1C,
        tail: 0xFFF26329,
        heartTop: 0xFFFFFFFF,
        heartBottom: 0xFFFFEBE3,
        lineColor: color(0xFFFFF5EB, alpha: 0.92),
        outerStroke: color(0xFFCD3F12)
    )

    ctx.restoreGState()
}

func renderMidnightBlueIcon(in ctx: CGContext) {
    let bgGrad = makeLinearGradient([color(0xFF243457), color(0xFF0E1628)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: 108, height: 108))
    ctx.clip()
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 108), options: [])
    ctx.restoreGState()

    let glowGrad = makeLinearGradient([color(0x426A94EC), color(0x006A94EC)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.drawRadialGradient(glowGrad, startCenter: CGPoint(x: 54, y: 28), startRadius: 0, endCenter: CGPoint(x: 54, y: 28), endRadius: 58, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.translateBy(x: 54, y: 54)
    ctx.scaleBy(x: 1.03, y: 1.03)
    ctx.translateBy(x: -54, y: -54)

    ctx.setFillColor(color(0xFF000000, alpha: 0.42))
    ctx.fillEllipse(in: CGRect(x: 20.5, y: 78.5, width: 67, height: 7.5))

    let folioCover = CGMutablePath()
    folioCover.move(to: CGPoint(x: 20.5, y: 45.0))
    folioCover.addCurve(to: CGPoint(x: 25.5, y: 40.8), control1: CGPoint(x: 20.5, y: 42.2), control2: CGPoint(x: 22.8, y: 40.5))
    folioCover.addLine(to: CGPoint(x: 48.0, y: 43.2))
    folioCover.addQuadCurve(to: CGPoint(x: 60.0, y: 43.2), control: CGPoint(x: 54.0, y: 45.2))
    folioCover.addLine(to: CGPoint(x: 82.5, y: 40.8))
    folioCover.addCurve(to: CGPoint(x: 87.5, y: 45.0), control1: CGPoint(x: 85.2, y: 40.5), control2: CGPoint(x: 87.5, y: 42.2))
    folioCover.addLine(to: CGPoint(x: 87.5, y: 74.5))
    folioCover.addCurve(to: CGPoint(x: 82.5, y: 78.6), control1: CGPoint(x: 87.5, y: 77.2), control2: CGPoint(x: 85.4, y: 79.0))
    folioCover.addLine(to: CGPoint(x: 59.2, y: 76.6))
    folioCover.addQuadCurve(to: CGPoint(x: 48.8, y: 76.6), control: CGPoint(x: 54.0, y: 81.0))
    folioCover.addLine(to: CGPoint(x: 25.5, y: 78.6))
    folioCover.addCurve(to: CGPoint(x: 20.5, y: 74.5), control1: CGPoint(x: 22.6, y: 79.0), control2: CGPoint(x: 20.5, y: 77.2))
    folioCover.closeSubpath()

    let coverGrad = makeLinearGradient([color(0xFF4766A0), color(0xFF2D436E)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(folioCover)
    ctx.clip()
    ctx.drawLinearGradient(coverGrad, start: CGPoint(x: 54, y: 40), end: CGPoint(x: 54, y: 81), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    let baseSheet = CGMutablePath()
    baseSheet.move(to: CGPoint(x: 22.8, y: 44.8))
    baseSheet.addCurve(to: CGPoint(x: 25.8, y: 42.6), control1: CGPoint(x: 22.8, y: 43.2), control2: CGPoint(x: 24.2, y: 42.4))
    baseSheet.addLine(to: CGPoint(x: 54.0, y: 46.2))
    baseSheet.addLine(to: CGPoint(x: 82.2, y: 42.6))
    baseSheet.addCurve(to: CGPoint(x: 85.2, y: 44.8), control1: CGPoint(x: 83.8, y: 42.4), control2: CGPoint(x: 85.2, y: 43.2))
    baseSheet.addLine(to: CGPoint(x: 85.2, y: 73.4))
    baseSheet.addCurve(to: CGPoint(x: 82.0, y: 76.0), control1: CGPoint(x: 85.2, y: 75.2), control2: CGPoint(x: 83.8, y: 76.2))
    baseSheet.addLine(to: CGPoint(x: 54.0, y: 76.2))
    baseSheet.addLine(to: CGPoint(x: 26.0, y: 76.0))
    baseSheet.addCurve(to: CGPoint(x: 22.8, y: 73.4), control1: CGPoint(x: 24.2, y: 76.2), control2: CGPoint(x: 22.8, y: 75.2))
    baseSheet.closeSubpath()
    ctx.addPath(baseSheet)
    ctx.setFillColor(color(0xFFC4CFE6))
    ctx.fillPath()

    let topTab = CGMutablePath()
    topTab.move(to: CGPoint(x: 28.0, y: 39.0))
    topTab.addQuadCurve(to: CGPoint(x: 29.6, y: 37.4), control: CGPoint(x: 28.0, y: 37.4))
    topTab.addLine(to: CGPoint(x: 32.4, y: 37.4))
    topTab.addQuadCurve(to: CGPoint(x: 34.0, y: 39.0), control: CGPoint(x: 34.0, y: 37.4))
    topTab.addLine(to: CGPoint(x: 34.0, y: 45.0))
    topTab.addLine(to: CGPoint(x: 28.0, y: 45.0))
    topTab.closeSubpath()
    ctx.addPath(topTab)
    ctx.setFillColor(color(0xFFFF9F38))
    ctx.fillPath()

    let leftFolioPage = CGMutablePath()
    leftFolioPage.move(to: CGPoint(x: 24.8, y: 43.2))
    leftFolioPage.addCurve(to: CGPoint(x: 54.0, y: 46.2), control1: CGPoint(x: 25.0, y: 41.2), control2: CGPoint(x: 38.5, y: 40.0))
    leftFolioPage.addLine(to: CGPoint(x: 54.0, y: 75.8))
    leftFolioPage.addCurve(to: CGPoint(x: 25.0, y: 73.5), control1: CGPoint(x: 39.0, y: 71.2), control2: CGPoint(x: 26.8, y: 73.5))
    leftFolioPage.addCurve(to: CGPoint(x: 24.4, y: 70.6), control1: CGPoint(x: 24.2, y: 73.5), control2: CGPoint(x: 24.4, y: 72.2))
    leftFolioPage.closeSubpath()

    let rightFolioPage = CGMutablePath()
    rightFolioPage.move(to: CGPoint(x: 54.0, y: 46.2))
    rightFolioPage.addCurve(to: CGPoint(x: 83.2, y: 43.2), control1: CGPoint(x: 69.5, y: 40.0), control2: CGPoint(x: 83.0, y: 41.2))
    rightFolioPage.addLine(to: CGPoint(x: 83.6, y: 70.6))
    rightFolioPage.addCurve(to: CGPoint(x: 83.0, y: 73.5), control1: CGPoint(x: 83.6, y: 72.2), control2: CGPoint(x: 83.8, y: 73.5))
    rightFolioPage.addCurve(to: CGPoint(x: 54.0, y: 75.8), control1: CGPoint(x: 81.2, y: 73.5), control2: CGPoint(x: 69.0, y: 71.2))
    rightFolioPage.closeSubpath()

    let leftPageGrad = makeLinearGradient([color(0xFFF3F7FF), color(0xFFDEE6F7)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(leftFolioPage)
    ctx.clip()
    ctx.drawLinearGradient(leftPageGrad, start: CGPoint(x: 54, y: 40), end: CGPoint(x: 54, y: 76), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    let rightPageGrad = makeLinearGradient([color(0xFFE9EFFC), color(0xFFD2DCEF)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(rightFolioPage)
    ctx.clip()
    ctx.drawLinearGradient(rightPageGrad, start: CGPoint(x: 54, y: 40), end: CGPoint(x: 54, y: 76), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    let pagesClip = CGMutablePath()
    pagesClip.addPath(leftFolioPage)
    pagesClip.addPath(rightFolioPage)
    ctx.saveGState()
    ctx.addPath(pagesClip)
    ctx.clip()
    let gutterGrad = makeLinearGradient([color(0x004F6694), color(0x424F6694), color(0x004F6694)], locations: [0.0, 0.5, 1.0])
    ctx.saveGState()
    ctx.addRect(CGRect(x: 47, y: 42, width: 14, height: 35))
    ctx.clip()
    ctx.drawLinearGradient(gutterGrad, start: CGPoint(x: 47, y: 54), end: CGPoint(x: 61, y: 54), options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(0xFF283C66, alpha: 0.22))
    ctx.fillEllipse(in: CGRect(x: 38, y: 66.5, width: 32, height: 5.2))
    ctx.restoreGState()

    ctx.setStrokeColor(color(0xFFA2B2CE))
    ctx.setLineWidth(1.1)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 54, y: 46.2))
    ctx.addLine(to: CGPoint(x: 54, y: 75.8))
    ctx.strokePath()

    drawColoredProfileCat(
        in: ctx,
        bodyTop: 0xFFFFFFFF,
        bodyBottom: 0xFFF5EEE4,
        backEar: 0xFFDFD6CA,
        tail: 0xFFF3ECE2,
        heartTop: 0xFFFF885B,
        heartBottom: 0xFFEB5030,
        lineColor: color(0xFF425270, alpha: 0.72),
        outerStroke: color(0xFF2E3D5C, alpha: 0.50)
    )

    ctx.restoreGState()
}

func renderIconImage(size iconSize: Int, spec: IconThemeSpec) -> CGImage {
    guard let ctx = CGContext(
        data: nil,
        width: iconSize,
        height: iconSize,
        bitsPerComponent: 8,
        bytesPerRow: iconSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create drawing CGContext")
    }

    ctx.translateBy(x: 0, y: CGFloat(iconSize))
    ctx.scaleBy(x: CGFloat(iconSize) / 108.0, y: -CGFloat(iconSize) / 108.0)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    switch spec.kind {
    case .warmOrange:
        renderWarmOrangeIcon(in: ctx)
    case .pearlWhite:
        renderPearlWhiteIcon(in: ctx)
    case .midnightBlue:
        renderMidnightBlueIcon(in: ctx)
    }

    guard let renderedImage = ctx.makeImage(),
          let opaqueCtx = CGContext(
              data: nil,
              width: iconSize,
              height: iconSize,
              bitsPerComponent: 8,
              bytesPerRow: iconSize * 4,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else {
        fatalError("Failed to create opaque output context")
    }

    opaqueCtx.draw(renderedImage, in: CGRect(x: 0, y: 0, width: iconSize, height: iconSize))
    guard let finalImage = opaqueCtx.makeImage() else {
        fatalError("Failed to create final CGImage")
    }
    return finalImage
}

func writePNG(_ image: CGImage, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        fatalError("Failed to finalize PNG at \(url.path)")
    }
}

let assetsRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Sources/Assets.xcassets", isDirectory: true)

for spec in iconSpecs {
    let appIconDir = assetsRoot.appendingPathComponent("\(spec.assetName).appiconset", isDirectory: true)
    let iconPngName = "\(spec.assetName)-1024.png"
    let iconImg = renderIconImage(size: 1024, spec: spec)
    try writePNG(iconImg, to: appIconDir.appendingPathComponent(iconPngName))

    let iconContents = """
    {
      "images" : [
        {
          "filename" : "\(iconPngName)",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try iconContents.write(to: appIconDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

    let previewDir = assetsRoot.appendingPathComponent("\(spec.previewName).imageset", isDirectory: true)
    let previewPngName = "\(spec.previewName).png"
    let previewImg = renderIconImage(size: 180, spec: spec)
    try writePNG(previewImg, to: previewDir.appendingPathComponent(previewPngName))

    let previewContents = """
    {
      "images" : [
        {
          "filename" : "\(previewPngName)",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try previewContents.write(to: previewDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("Generated \(spec.assetName) & \(spec.previewName)")
}
