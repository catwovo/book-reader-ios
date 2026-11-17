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

struct IconThemeSpec {
    let assetName: String
    let previewName: String
    let bgTop: UInt32
    let bgBottom: UInt32
    let cradleHex: UInt32
    let shadowHex: UInt32
    let heartTop: UInt32
    let heartBottom: UInt32
}

let iconSpecs: [IconThemeSpec] = [
    IconThemeSpec(
        assetName: "AppIcon",
        previewName: "IconPreviewDefault",
        bgTop: 0xFFFFB840,
        bgBottom: 0xFFF25521,
        cradleHex: 0xFFB3320D,
        shadowHex: 0xFF6E1A00,
        heartTop: 0xFFFF7A59,
        heartBottom: 0xFFE8462A
    ),
    IconThemeSpec(
        assetName: "AppIconNight",
        previewName: "IconPreviewNight",
        bgTop: 0xFF3B82F6,
        bgBottom: 0xFF1E293B,
        cradleHex: 0xFF0F172A,
        shadowHex: 0xFF090E1A,
        heartTop: 0xFF60A5FA,
        heartBottom: 0xFF2563EB
    ),
    IconThemeSpec(
        assetName: "AppIconSage",
        previewName: "IconPreviewSage",
        bgTop: 0xFF34D399,
        bgBottom: 0xFF0F766E,
        cradleHex: 0xFF064E3B,
        shadowHex: 0xFF022C22,
        heartTop: 0xFFFF8A65,
        heartBottom: 0xFFE65100
    ),
    IconThemeSpec(
        assetName: "AppIconInk",
        previewName: "IconPreviewInk",
        bgTop: 0xFF27272A,
        bgBottom: 0xFF09090B,
        cradleHex: 0xFF000000,
        shadowHex: 0xFF000000,
        heartTop: 0xFFF59E0B,
        heartBottom: 0xFFD97706
    ),
    IconThemeSpec(
        assetName: "AppIconSakura",
        previewName: "IconPreviewSakura",
        bgTop: 0xFFFB7185,
        bgBottom: 0xFFBE185D,
        cradleHex: 0xFF881337,
        shadowHex: 0xFF4C0519,
        heartTop: 0xFFFDE047,
        heartBottom: 0xFFF59E0B
    )
]

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

    // Flip to top-left origin 108x108 coordinate space
    ctx.translateBy(x: 0, y: CGFloat(iconSize))
    ctx.scaleBy(x: CGFloat(iconSize) / 108.0, y: -CGFloat(iconSize) / 108.0)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // 1. Background linear gradient
    let bgGrad = makeLinearGradient([color(spec.bgTop), color(spec.bgBottom)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addRect(CGRect(x: 0, y: 0, width: 108, height: 108))
    ctx.clip()
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 108), options: [])
    ctx.restoreGState()

    // 2. Top sunlit radial highlight
    let glowGrad = makeLinearGradient([color(0x47FFFFFF), color(0x00FFFFFF)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: CGPoint(x: 54, y: 20),
        startRadius: 0,
        endCenter: CGPoint(x: 54, y: 20),
        endRadius: 58,
        options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // 3. Foreground winged open book + sitting coffee cat (~1.2x larger: 0.86 * 1.2 ≈ 1.03)
    ctx.saveGState()
    ctx.translateBy(x: 54, y: 54)
    ctx.scaleBy(x: 1.03, y: 1.03)
    ctx.translateBy(x: -54, y: -54)

    // Soft drop shadow under winged book
    ctx.setFillColor(color(spec.shadowHex, alpha: 0.24))
    ctx.fillEllipse(in: CGRect(x: 22, y: 77.5, width: 64, height: 7.5))

    // Hardcover cradle
    let cradlePath = CGMutablePath()
    cradlePath.move(to: CGPoint(x: 19, y: 45))
    cradlePath.addCurve(to: CGPoint(x: 54, y: 49), control1: CGPoint(x: 20, y: 39.5), control2: CGPoint(x: 36, y: 41))
    cradlePath.addCurve(to: CGPoint(x: 89, y: 45), control1: CGPoint(x: 72, y: 41), control2: CGPoint(x: 88, y: 39.5))
    cradlePath.addLine(to: CGPoint(x: 86.2, y: 75.5))
    cradlePath.addCurve(to: CGPoint(x: 80.5, y: 78.5), control1: CGPoint(x: 85.8, y: 78.2), control2: CGPoint(x: 83.2, y: 79.2))
    cradlePath.addCurve(to: CGPoint(x: 54, y: 81.2), control1: CGPoint(x: 68.5, y: 75.5), control2: CGPoint(x: 58.5, y: 78))
    cradlePath.addCurve(to: CGPoint(x: 27.5, y: 78.5), control1: CGPoint(x: 49.5, y: 78), control2: CGPoint(x: 39.5, y: 75.5))
    cradlePath.addCurve(to: CGPoint(x: 21.8, y: 75.5), control1: CGPoint(x: 24.8, y: 79.2), control2: CGPoint(x: 22.2, y: 78.2))
    cradlePath.closeSubpath()
    ctx.addPath(cradlePath)
    ctx.setFillColor(color(spec.cradleHex, alpha: 0.38))
    ctx.fillPath()

    // Stepped fanned page edges
    let fanPath = CGMutablePath()
    fanPath.move(to: CGPoint(x: 20.5, y: 43.2))
    fanPath.addCurve(to: CGPoint(x: 54, y: 47.6), control1: CGPoint(x: 21.5, y: 38.2), control2: CGPoint(x: 36.5, y: 39.8))
    fanPath.addCurve(to: CGPoint(x: 87.5, y: 43.2), control1: CGPoint(x: 71.5, y: 39.8), control2: CGPoint(x: 86.5, y: 38.2))
    fanPath.addLine(to: CGPoint(x: 84.8, y: 73.6))
    fanPath.addCurve(to: CGPoint(x: 79.5, y: 76.2), control1: CGPoint(x: 84.4, y: 76), control2: CGPoint(x: 82, y: 76.8))
    fanPath.addCurve(to: CGPoint(x: 54, y: 79.2), control1: CGPoint(x: 68, y: 73.5), control2: CGPoint(x: 58, y: 75.8))
    fanPath.addCurve(to: CGPoint(x: 28.5, y: 76.2), control1: CGPoint(x: 50, y: 75.8), control2: CGPoint(x: 40, y: 73.5))
    fanPath.addCurve(to: CGPoint(x: 23.2, y: 73.6), control1: CGPoint(x: 26, y: 76.8), control2: CGPoint(x: 23.6, y: 76))
    fanPath.closeSubpath()
    ctx.addPath(fanPath)
    ctx.setFillColor(color(0xFFE7DDD0))
    ctx.fillPath()

    // Left winged page
    let leftPage = CGMutablePath()
    leftPage.move(to: CGPoint(x: 22.2, y: 41.8))
    leftPage.addCurve(to: CGPoint(x: 54, y: 46.8), control1: CGPoint(x: 22.8, y: 37.5), control2: CGPoint(x: 37.5, y: 39))
    leftPage.addLine(to: CGPoint(x: 54, y: 77.2))
    leftPage.addCurve(to: CGPoint(x: 26.2, y: 73.5), control1: CGPoint(x: 48, y: 73), control2: CGPoint(x: 36, y: 71.2))
    leftPage.addCurve(to: CGPoint(x: 23, y: 70.8), control1: CGPoint(x: 24.2, y: 74), control2: CGPoint(x: 23.2, y: 72.8))
    leftPage.closeSubpath()

    let leftGrad = makeLinearGradient([color(0xFFFFFFFF), color(0xFFF6EFE7)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(leftPage)
    ctx.clip()
    ctx.drawLinearGradient(leftGrad, start: CGPoint(x: 54, y: 38), end: CGPoint(x: 54, y: 77), options: [])
    ctx.restoreGState()

    // Right winged page
    let rightPage = CGMutablePath()
    rightPage.move(to: CGPoint(x: 54, y: 46.8))
    rightPage.addCurve(to: CGPoint(x: 85.8, y: 41.8), control1: CGPoint(x: 70.5, y: 39), control2: CGPoint(x: 85.2, y: 37.5))
    rightPage.addLine(to: CGPoint(x: 85, y: 70.8))
    rightPage.addCurve(to: CGPoint(x: 81.8, y: 73.5), control1: CGPoint(x: 84.8, y: 72.8), control2: CGPoint(x: 83.8, y: 74))
    rightPage.addCurve(to: CGPoint(x: 54, y: 77.2), control1: CGPoint(x: 72, y: 71.2), control2: CGPoint(x: 60, y: 73))
    rightPage.closeSubpath()

    let rightGrad = makeLinearGradient([color(0xFFFAF4EC), color(0xFFEBE0D4)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(rightPage)
    ctx.clip()
    ctx.drawLinearGradient(rightGrad, start: CGPoint(x: 54, y: 38), end: CGPoint(x: 54, y: 77), options: [])
    ctx.restoreGState()

    // Spine gutter & cat contact shadow clipped to pages
    let combinedPages = CGMutablePath()
    combinedPages.addPath(leftPage)
    combinedPages.addPath(rightPage)
    ctx.saveGState()
    ctx.addPath(combinedPages)
    ctx.clip()

    let gutterGrad = makeLinearGradient(
        [color(0x009C7B5E), color(0x339C7B5E), color(0x009C7B5E)],
        locations: [0.0, 0.5, 1.0]
    )
    ctx.saveGState()
    ctx.addRect(CGRect(x: 46, y: 44, width: 16, height: 35))
    ctx.clip()
    ctx.drawLinearGradient(gutterGrad, start: CGPoint(x: 46, y: 54), end: CGPoint(x: 62, y: 54), options: [])
    ctx.restoreGState()

    ctx.setFillColor(color(0xFF8C5332, alpha: 0.16))
    ctx.fillEllipse(in: CGRect(x: 38, y: 66.5, width: 32, height: 5.2))
    ctx.restoreGState()

    // Center spine crease
    ctx.setStrokeColor(color(0xFFD5C4B2))
    ctx.setLineWidth(1.1)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 54, y: 46.8))
    ctx.addLine(to: CGPoint(x: 54, y: 77.2))
    ctx.strokePath()

    // Back ear
    let earPath = CGMutablePath()
    earPath.move(to: CGPoint(x: 51.96, y: 31.88))
    earPath.addCurve(to: CGPoint(x: 57.06, y: 26.48), control1: CGPoint(x: 54.00, y: 28.64), control2: CGPoint(x: 55.79, y: 26.75))
    earPath.addCurve(to: CGPoint(x: 57.37, y: 28.91), control1: CGPoint(x: 57.67, y: 26.37), control2: CGPoint(x: 57.77, y: 27.24))
    earPath.addLine(to: CGPoint(x: 56.30, y: 33.50))
    earPath.closeSubpath()
    ctx.addPath(earPath)
    ctx.setFillColor(color(0xFF281B18))
    ctx.fillPath()
    ctx.addPath(earPath)
    ctx.setStrokeColor(color(0xFF231613))
    ctx.setLineWidth(1.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Curled tail
    let tailPath = CGMutablePath()
    tailPath.move(to: CGPoint(x: 59.10, y: 68.33))
    tailPath.addCurve(to: CGPoint(x: 69.30, y: 60.61), control1: CGPoint(x: 64.97, y: 69.68), control2: CGPoint(x: 68.89, y: 66.44))
    tailPath.addCurve(to: CGPoint(x: 63.79, y: 45.11), control1: CGPoint(x: 69.71, y: 54.67), control2: CGPoint(x: 63.59, y: 50.24))
    tailPath.addCurve(to: CGPoint(x: 72.46, y: 41.33), control1: CGPoint(x: 63.95, y: 40.25), control2: CGPoint(x: 69.05, y: 38.63))
    tailPath.addCurve(to: CGPoint(x: 71.24, y: 49.43), control1: CGPoint(x: 75.17, y: 43.49), control2: CGPoint(x: 74.50, y: 48.35))
    tailPath.addCurve(to: CGPoint(x: 67.26, y: 47.11), control1: CGPoint(x: 69.20, y: 50.02), control2: CGPoint(x: 67.52, y: 48.73))

    ctx.addPath(tailPath)
    ctx.setStrokeColor(color(0xFF231613))
    ctx.setLineWidth(4.2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    ctx.addPath(tailPath)
    ctx.setStrokeColor(color(0xFF342420))
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Cat body
    let bodyPath = CGMutablePath()
    bodyPath.move(to: CGPoint(x: 51.04, y: 24.43))
    bodyPath.addCurve(to: CGPoint(x: 51.86, y: 31.07), control1: CGPoint(x: 51.55, y: 26.75), control2: CGPoint(x: 51.65, y: 29.45))
    bodyPath.addCurve(to: CGPoint(x: 59.41, y: 36.85), control1: CGPoint(x: 56.30, y: 31.99), control2: CGPoint(x: 59.00, y: 34.47))
    bodyPath.addCurve(to: CGPoint(x: 60.73, y: 39.87), control1: CGPoint(x: 60.83, y: 37.93), control2: CGPoint(x: 61.40, y: 38.90))
    bodyPath.addCurve(to: CGPoint(x: 52.57, y: 41.60), control1: CGPoint(x: 59.61, y: 41.49), control2: CGPoint(x: 56.04, y: 41.82))
    bodyPath.addCurve(to: CGPoint(x: 61.40, y: 53.21), control1: CGPoint(x: 52.98, y: 44.84), control2: CGPoint(x: 57.32, y: 48.62))
    bodyPath.addCurve(to: CGPoint(x: 64.46, y: 67.79), control1: CGPoint(x: 65.48, y: 57.80), control2: CGPoint(x: 67.01, y: 64.01))
    bodyPath.addCurve(to: CGPoint(x: 52.22, y: 68.92), control1: CGPoint(x: 62.42, y: 69.68), control2: CGPoint(x: 56.81, y: 69.79))
    bodyPath.addCurve(to: CGPoint(x: 38.96, y: 60.77), control1: CGPoint(x: 46.61, y: 69.68), control2: CGPoint(x: 41.00, y: 66.98))
    bodyPath.addCurve(to: CGPoint(x: 42.02, y: 36.47), control1: CGPoint(x: 36.92, y: 54.29), control2: CGPoint(x: 37.94, y: 44.84))
    bodyPath.addCurve(to: CGPoint(x: 51.04, y: 24.43), control1: CGPoint(x: 44.82, y: 30.80), control2: CGPoint(x: 48.39, y: 26.48))
    bodyPath.closeSubpath()

    let catGrad = makeLinearGradient([color(0xFF47342E), color(0xFF2B1E1A)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(catGrad, start: CGPoint(x: 54, y: 23), end: CGPoint(x: 54, y: 70), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    ctx.addPath(bodyPath)
    ctx.setStrokeColor(color(0xFF231613))
    ctx.setLineWidth(1.0)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Inner heart
    let heartPath = CGMutablePath()
    heartPath.move(to: CGPoint(x: 52.37, y: 68.38))
    heartPath.addCurve(to: CGPoint(x: 46.76, y: 57.37), control1: CGPoint(x: 47.27, y: 65.47), control2: CGPoint(x: 45.43, y: 60.61))
    heartPath.addCurve(to: CGPoint(x: 52.37, y: 57.58), control1: CGPoint(x: 47.88, y: 54.67), control2: CGPoint(x: 51.04, y: 54.88))
    heartPath.addCurve(to: CGPoint(x: 57.98, y: 57.37), control1: CGPoint(x: 53.69, y: 54.88), control2: CGPoint(x: 56.86, y: 54.67))
    heartPath.addCurve(to: CGPoint(x: 52.37, y: 68.38), control1: CGPoint(x: 59.30, y: 60.61), control2: CGPoint(x: 57.47, y: 65.47))
    heartPath.closeSubpath()

    let heartGrad = makeLinearGradient([color(spec.heartTop), color(spec.heartBottom)], locations: [0.0, 1.0])
    ctx.saveGState()
    ctx.addPath(heartPath)
    ctx.clip()
    ctx.drawLinearGradient(heartGrad, start: CGPoint(x: 54, y: 54), end: CGPoint(x: 54, y: 70), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    ctx.addPath(heartPath)
    ctx.setStrokeColor(color(0xFFFFE5CF, alpha: 0.90))
    ctx.setLineWidth(1.2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    // Signature throat swoosh
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 54.26, y: 41.60))
    ctx.addCurve(to: CGPoint(x: 39.01, y: 55.37), control1: CGPoint(x: 48.14, y: 41.87), control2: CGPoint(x: 42.53, y: 47.27))
    ctx.setStrokeColor(color(0xFFFFE5CF, alpha: 0.90))
    ctx.setLineWidth(1.3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    ctx.restoreGState()

    // Render onto opaque RGBX bitmap so Apple AppIcon has zero alpha channel
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
