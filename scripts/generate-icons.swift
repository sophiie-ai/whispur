#!/usr/bin/swift

import AppKit
import Foundation

struct IconFile {
    let filename: String
    let pixelSize: Int
}

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let assetCatalogURL = rootURL.appendingPathComponent("Resources/Assets.xcassets", isDirectory: true)
let appIconSetURL = assetCatalogURL.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
let menuBarSetURL = assetCatalogURL.appendingPathComponent("MenuBarGlyph.imageset", isDirectory: true)
let volumeIconURL = rootURL.appendingPathComponent("Resources/VolumeIcon.icns")

let appIconFiles = [
    IconFile(filename: "icon_16x16.png", pixelSize: 16),
    IconFile(filename: "icon_16x16@2x.png", pixelSize: 32),
    IconFile(filename: "icon_32x32.png", pixelSize: 32),
    IconFile(filename: "icon_32x32@2x.png", pixelSize: 64),
    IconFile(filename: "icon_128x128.png", pixelSize: 128),
    IconFile(filename: "icon_128x128@2x.png", pixelSize: 256),
    IconFile(filename: "icon_256x256.png", pixelSize: 256),
    IconFile(filename: "icon_256x256@2x.png", pixelSize: 512),
    IconFile(filename: "icon_512x512.png", pixelSize: 512),
    IconFile(filename: "icon_512x512@2x.png", pixelSize: 1024)
]

let menuBarFiles = [
    IconFile(filename: "menu-bar-glyph.png", pixelSize: 16),
    IconFile(filename: "menu-bar-glyph@2x.png", pixelSize: 32)
]

func ensureDirectory(_ url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
}

func removeIfExists(_ url: URL) throws {
    if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
    }
}

func point(_ x: CGFloat, _ y: CGFloat, in size: CGFloat) -> CGPoint {
    CGPoint(x: x * size, y: y * size)
}

func makeMainWavePath(size: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: point(0.225, 0.338, in: size))
    path.curve(
        to: point(0.445, 0.708, in: size),
        controlPoint1: point(0.252, 0.605, in: size),
        controlPoint2: point(0.335, 0.815, in: size)
    )
    path.curve(
        to: point(0.582, 0.455, in: size),
        controlPoint1: point(0.496, 0.645, in: size),
        controlPoint2: point(0.534, 0.446, in: size)
    )
    path.curve(
        to: point(0.788, 0.598, in: size),
        controlPoint1: point(0.636, 0.486, in: size),
        controlPoint2: point(0.716, 0.738, in: size)
    )
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

func makeWhisperArcPath(size: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: point(0.27, 0.593, in: size))
    path.curve(
        to: point(0.588, 0.69, in: size),
        controlPoint1: point(0.33, 0.785, in: size),
        controlPoint2: point(0.48, 0.826, in: size)
    )
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

func drawRoundedRect(in rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func applyShadow(color: NSColor, blur: CGFloat, x: CGFloat = 0, y: CGFloat = 0) {
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: x, height: y)
    shadow.set()
}

func clearShadow() {
    NSShadow().set()
}

func makeBitmap(size: Int, draw: (CGFloat) -> Void) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "ai.sophiie.whispur", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap for \(size)x\(size) icon"])
    }

    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

func writePNG(rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ai.sophiie.whispur", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG for \(url.lastPathComponent)"])
    }
    try png.write(to: url)
}

func drawAppIcon(size dimension: CGFloat) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(origin: .zero, size: NSSize(width: dimension, height: dimension)))

    let cardRect = CGRect(x: dimension * 0.085, y: dimension * 0.085, width: dimension * 0.83, height: dimension * 0.83)
    let cardRadius = dimension * 0.215
    let cardPath = drawRoundedRect(in: cardRect, radius: cardRadius)

    ctx.saveGState()
    applyShadow(color: NSColor(calibratedWhite: 0.0, alpha: 0.26), blur: dimension * 0.08, y: -dimension * 0.018)
    NSColor.black.withAlphaComponent(0.12).setFill()
    cardPath.fill()
    clearShadow()
    ctx.restoreGState()

    ctx.saveGState()
    cardPath.addClip()

    let backgroundGradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.06, green: 0.13, blue: 0.36, alpha: 1), 0.0),
        (NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.67, alpha: 1), 0.52),
        (NSColor(calibratedRed: 0.26, green: 0.82, blue: 0.74, alpha: 1), 1.0)
    )!
    backgroundGradient.draw(in: cardPath, angle: 312)

    let accentOrb = NSBezierPath(ovalIn: CGRect(
        x: dimension * 0.49,
        y: dimension * 0.50,
        width: dimension * 0.36,
        height: dimension * 0.36
    ))
    let accentGradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.66, green: 0.49, blue: 1.0, alpha: 0.58), 0.0),
        (NSColor(calibratedRed: 0.66, green: 0.49, blue: 1.0, alpha: 0.0), 1.0)
    )!
    accentGradient.draw(in: accentOrb, relativeCenterPosition: NSPoint(x: 0.08, y: 0.1))

    let highlightOrb = NSBezierPath(ovalIn: CGRect(
        x: dimension * 0.15,
        y: dimension * 0.60,
        width: dimension * 0.42,
        height: dimension * 0.32
    ))
    let highlightGradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedWhite: 1.0, alpha: 0.18), 0.0),
        (NSColor(calibratedWhite: 1.0, alpha: 0.0), 1.0)
    )!
    highlightGradient.draw(in: highlightOrb, relativeCenterPosition: NSPoint(x: -0.35, y: 0.55))

    let rimPath = drawRoundedRect(in: cardRect.insetBy(dx: dimension * 0.004, dy: dimension * 0.004), radius: cardRadius - dimension * 0.004)
    NSColor(calibratedWhite: 1.0, alpha: 0.16).setStroke()
    rimPath.lineWidth = dimension * 0.008
    rimPath.stroke()

    let mainWave = makeMainWavePath(size: dimension)
    let whisperArc = makeWhisperArcPath(size: dimension)

    applyShadow(color: NSColor(calibratedWhite: 0.0, alpha: 0.14), blur: dimension * 0.022, y: -dimension * 0.012)
    NSColor(calibratedRed: 0.985, green: 0.99, blue: 1.0, alpha: 0.98).setStroke()
    mainWave.lineWidth = dimension * 0.118
    mainWave.stroke()
    whisperArc.lineWidth = dimension * 0.076
    whisperArc.stroke()
    clearShadow()

    NSColor(calibratedRed: 0.72, green: 0.98, blue: 1.0, alpha: 0.3).setStroke()
    mainWave.lineWidth = dimension * 0.046
    mainWave.stroke()
    whisperArc.lineWidth = dimension * 0.03
    whisperArc.stroke()

    let sparkle = NSBezierPath()
    let sparkleCenter = point(0.73, 0.73, in: dimension)
    let sparkleRadius = dimension * 0.03
    sparkle.move(to: CGPoint(x: sparkleCenter.x, y: sparkleCenter.y + sparkleRadius))
    sparkle.line(to: CGPoint(x: sparkleCenter.x, y: sparkleCenter.y - sparkleRadius))
    sparkle.move(to: CGPoint(x: sparkleCenter.x - sparkleRadius, y: sparkleCenter.y))
    sparkle.line(to: CGPoint(x: sparkleCenter.x + sparkleRadius, y: sparkleCenter.y))
    sparkle.lineCapStyle = .round
    NSColor(calibratedWhite: 1.0, alpha: 0.72).setStroke()
    sparkle.lineWidth = dimension * 0.016
    sparkle.stroke()

    ctx.restoreGState()
}

func drawMenuBarGlyph(size dimension: CGFloat) {
    let mainWave = makeMainWavePath(size: dimension)
    let whisperArc = makeWhisperArcPath(size: dimension)
    NSColor.white.setStroke()

    mainWave.lineWidth = dimension * 0.18
    mainWave.stroke()

    whisperArc.lineWidth = dimension * 0.11
    whisperArc.stroke()

    let sparkle = NSBezierPath()
    let sparkleCenter = point(0.73, 0.73, in: dimension)
    let sparkleRadius = dimension * 0.05
    sparkle.move(to: CGPoint(x: sparkleCenter.x, y: sparkleCenter.y + sparkleRadius))
    sparkle.line(to: CGPoint(x: sparkleCenter.x, y: sparkleCenter.y - sparkleRadius))
    sparkle.move(to: CGPoint(x: sparkleCenter.x - sparkleRadius, y: sparkleCenter.y))
    sparkle.line(to: CGPoint(x: sparkleCenter.x + sparkleRadius, y: sparkleCenter.y))
    sparkle.lineCapStyle = .round
    sparkle.lineWidth = dimension * 0.03
    sparkle.stroke()
}

func appIconMasterSVG() -> String {
    """
    <svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
      <defs>
        <linearGradient id="bg" x1="120" y1="166" x2="892" y2="854" gradientUnits="userSpaceOnUse">
          <stop stop-color="#0F205E"/>
          <stop offset="0.52" stop-color="#1B6CA9"/>
          <stop offset="1" stop-color="#3DD1BD"/>
        </linearGradient>
        <radialGradient id="violet" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(704 328) rotate(90) scale(184)">
          <stop stop-color="#A67CFF" stop-opacity="0.58"/>
          <stop offset="1" stop-color="#A67CFF" stop-opacity="0"/>
        </radialGradient>
        <radialGradient id="shine" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(275 246) rotate(-34) scale(240 170)">
          <stop stop-color="white" stop-opacity="0.18"/>
          <stop offset="1" stop-color="white" stop-opacity="0"/>
        </radialGradient>
        <filter id="shadow" x="42" y="38" width="940" height="940" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
          <feDropShadow dx="0" dy="18" stdDeviation="34" flood-color="#000000" flood-opacity="0.24"/>
        </filter>
      </defs>

      <g filter="url(#shadow)">
        <rect x="87" y="87" width="850" height="850" rx="220" fill="url(#bg)"/>
        <rect x="91" y="91" width="842" height="842" rx="216" stroke="white" stroke-opacity="0.16" stroke-width="8"/>
        <circle cx="704" cy="328" r="184" fill="url(#violet)"/>
        <ellipse cx="356" cy="246" rx="205" ry="156" fill="url(#shine)"/>
      </g>

      <path d="M230 678C258 404 343 189 456 299C508 364 547 567 596 558C651 526 733 268 807 412" stroke="#FBFDFF" stroke-width="121" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M276 417C338 220 492 178 602 317" stroke="#FBFDFF" stroke-opacity="0.98" stroke-width="78" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M230 678C258 404 343 189 456 299C508 364 547 567 596 558C651 526 733 268 807 412" stroke="#B7FEFF" stroke-opacity="0.3" stroke-width="47" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M276 417C338 220 492 178 602 317" stroke="#B7FEFF" stroke-opacity="0.3" stroke-width="31" stroke-linecap="round" stroke-linejoin="round"/>
      <path d="M748 245V307M717 276H779" stroke="white" stroke-opacity="0.72" stroke-width="16" stroke-linecap="round"/>
    </svg>
    """
}

func generateAssets() throws {
    try ensureDirectory(assetCatalogURL)
    try ensureDirectory(appIconSetURL)
    try ensureDirectory(menuBarSetURL)

    for icon in appIconFiles {
        let rep = try makeBitmap(size: icon.pixelSize) { dimension in
            drawAppIcon(size: dimension)
        }
        try writePNG(rep: rep, to: appIconSetURL.appendingPathComponent(icon.filename))
    }

    for icon in menuBarFiles {
        let rep = try makeBitmap(size: icon.pixelSize) { dimension in
            drawMenuBarGlyph(size: dimension)
        }
        try writePNG(rep: rep, to: menuBarSetURL.appendingPathComponent(icon.filename))
    }

    try appIconMasterSVG().write(
        to: appIconSetURL.appendingPathComponent("app-icon-master.svg"),
        atomically: true,
        encoding: .utf8
    )

    let tempIconsetURL = rootURL.appendingPathComponent(".build/whispur-volume.iconset", isDirectory: true)
    try removeIfExists(tempIconsetURL)
    try ensureDirectory(tempIconsetURL)

    for icon in appIconFiles {
        let source = appIconSetURL.appendingPathComponent(icon.filename)
        let destination = tempIconsetURL.appendingPathComponent(icon.filename)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    try removeIfExists(volumeIconURL)

    let process = Process()
    process.currentDirectoryURL = rootURL
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", tempIconsetURL.path, "-o", volumeIconURL.path]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "ai.sophiie.whispur", code: 2, userInfo: [NSLocalizedDescriptionKey: "iconutil failed with exit code \(process.terminationStatus)"])
    }

    try removeIfExists(tempIconsetURL)
}

do {
    try generateAssets()
    print("Generated app icons, menu bar glyphs, and \(volumeIconURL.path)")
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
