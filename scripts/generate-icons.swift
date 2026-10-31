#!/usr/bin/swift

// Generates every raster of the Whispur app icon and menu bar glyph.
//
// The source of truth is the "speak to cursor" master SVG embedded below
// (APP_ICON_MASTER_SVG). The draw functions are a hand port of that SVG to
// Core Graphics, in the SVG's own 1024 coordinate space, so no SVG renderer
// or Node tooling is needed. If you change the art, change the SVG and the
// matching draw code together.
//
// Usage (from the repo root):  swift scripts/generate-icons.swift
//
// Writes:
//   Resources/Assets.xcassets/AppIcon.appiconset/*.png  (every size in Contents.json)
//   Resources/Assets.xcassets/AppIcon.appiconset/app-icon-master.svg
//   Resources/Assets.xcassets/MenuBarGlyph.imageset/menu-bar-glyph{,@2x}.png  (black template)
//   Resources/VolumeIcon.icns  (DMG volume icon, via iconutil)
//   public/icon.png, public/icon-512.png, public/apple-touch-icon.png, public/favicon.png
//   public/favicon.svg  (the master, cropped to the tile)

import AppKit
import CoreGraphics
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
let publicURL = rootURL.appendingPathComponent("public", isDirectory: true)

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

// The SwiftUI menu bar item shows the glyph in a 16pt frame.
let menuBarFiles = [
    IconFile(filename: "menu-bar-glyph.png", pixelSize: 16),
    IconFile(filename: "menu-bar-glyph@2x.png", pixelSize: 32)
]

// Site copies of the app icon: public file name -> app icon set file it mirrors.
let siteIconCopies = [
    ("icon.png", "icon_256x256.png"),
    ("icon-512.png", "icon_512x512.png"),
    ("apple-touch-icon.png", "icon_128x128@2x.png"),
    ("favicon.png", "icon_32x32@2x.png")
]

// MARK: - Tokens (Sophiie palette, see Sources/UI/Theme/SophiieTheme.swift)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: srgb,
        components: [
            CGFloat((value >> 16) & 0xff) / 255,
            CGFloat((value >> 8) & 0xff) / 255,
            CGFloat(value & 0xff) / 255,
            alpha
        ]
    )!
}

let midnight: UInt32 = 0x140934 // Palette.midnight, the tile
let navy: UInt32 = 0x151587     // Palette.navy, the radial glow
let sky: UInt32 = 0x69C7FB      // Palette.sky, the voice bars
let white: UInt32 = 0xFFFFFF    // caret, rim and sheen

// MARK: - Master SVG (keep in sync with the draw code below)

let appIconMasterSVG = """
<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <filter id="shadow" x="0" y="0" width="1024" height="1024" filterUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
      <feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000000" flood-opacity="0.28"/>
    </filter>
    <linearGradient id="sheen" x1="512" y1="100" x2="512" y2="560" gradientUnits="userSpaceOnUse">
      <stop stop-color="#ffffff" stop-opacity="0.09"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="body"><path d="M628.00 100.00 c103.61 0 155.41 0 194.99 20.16 a185 185 0 0 1 80.85 80.85 c20.16 39.57 20.16 91.38 20.16 194.99 L924.00 628.00 c0 103.61 0 155.41 -20.16 194.99 a185 185 0 0 1 -80.85 80.85 c-39.57 20.16 -91.38 20.16 -194.99 20.16 L396.00 924.00 c-103.61 0 -155.41 0 -194.99 -20.16 a185 185 0 0 1 -80.85 -80.85 c-20.16 -39.57 -20.16 -91.38 -20.16 -194.99 L100.00 396.00 c0 -103.61 0 -155.41 20.16 -194.99 a185 185 0 0 1 80.85 -80.85 c39.57 -20.16 91.38 -20.16 194.99 -20.16 Z"/></clipPath>
    <radialGradient id="glowC" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(512 900) scale(560 380)">
      <stop stop-color="#151587" stop-opacity="0.9"/>
      <stop offset="1" stop-color="#151587" stop-opacity="0"/>
    </radialGradient>
    <filter id="caretGlowC" x="0" y="0" width="1024" height="1024" filterUnits="userSpaceOnUse">
      <feGaussianBlur stdDeviation="22" result="b"/>
      <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <g filter="url(#shadow)">
    <path d="M628.00 100.00 c103.61 0 155.41 0 194.99 20.16 a185 185 0 0 1 80.85 80.85 c20.16 39.57 20.16 91.38 20.16 194.99 L924.00 628.00 c0 103.61 0 155.41 -20.16 194.99 a185 185 0 0 1 -80.85 80.85 c-39.57 20.16 -91.38 20.16 -194.99 20.16 L396.00 924.00 c-103.61 0 -155.41 0 -194.99 -20.16 a185 185 0 0 1 -80.85 -80.85 c-20.16 -39.57 -20.16 -91.38 -20.16 -194.99 L100.00 396.00 c0 -103.61 0 -155.41 20.16 -194.99 a185 185 0 0 1 80.85 -80.85 c39.57 -20.16 91.38 -20.16 194.99 -20.16 Z" fill="#000" fill-opacity="0.001"/>
    <g clip-path="url(#body)">
      <path d="M628.00 100.00 c103.61 0 155.41 0 194.99 20.16 a185 185 0 0 1 80.85 80.85 c20.16 39.57 20.16 91.38 20.16 194.99 L924.00 628.00 c0 103.61 0 155.41 -20.16 194.99 a185 185 0 0 1 -80.85 80.85 c-39.57 20.16 -91.38 20.16 -194.99 20.16 L396.00 924.00 c-103.61 0 -155.41 0 -194.99 -20.16 a185 185 0 0 1 -80.85 -80.85 c-20.16 -39.57 -20.16 -91.38 -20.16 -194.99 L100.00 396.00 c0 -103.61 0 -155.41 20.16 -194.99 a185 185 0 0 1 80.85 -80.85 c39.57 -20.16 91.38 -20.16 194.99 -20.16 Z" fill="#140934"/>
      <path d="M628.00 100.00 c103.61 0 155.41 0 194.99 20.16 a185 185 0 0 1 80.85 80.85 c20.16 39.57 20.16 91.38 20.16 194.99 L924.00 628.00 c0 103.61 0 155.41 -20.16 194.99 a185 185 0 0 1 -80.85 80.85 c-39.57 20.16 -91.38 20.16 -194.99 20.16 L396.00 924.00 c-103.61 0 -155.41 0 -194.99 -20.16 a185 185 0 0 1 -80.85 -80.85 c-20.16 -39.57 -20.16 -91.38 -20.16 -194.99 L100.00 396.00 c0 -103.61 0 -155.41 20.16 -194.99 a185 185 0 0 1 80.85 -80.85 c39.57 -20.16 91.38 -20.16 194.99 -20.16 Z" fill="url(#glowC)"/>
      <path d="M628.00 100.00 c103.61 0 155.41 0 194.99 20.16 a185 185 0 0 1 80.85 80.85 c20.16 39.57 20.16 91.38 20.16 194.99 L924.00 628.00 c0 103.61 0 155.41 -20.16 194.99 a185 185 0 0 1 -80.85 80.85 c-39.57 20.16 -91.38 20.16 -194.99 20.16 L396.00 924.00 c-103.61 0 -155.41 0 -194.99 -20.16 a185 185 0 0 1 -80.85 -80.85 c-20.16 -39.57 -20.16 -91.38 -20.16 -194.99 L100.00 396.00 c0 -103.61 0 -155.41 20.16 -194.99 a185 185 0 0 1 80.85 -80.85 c39.57 -20.16 91.38 -20.16 194.99 -20.16 Z" fill="url(#sheen)"/>
    </g>
  </g>
  <path d="M629.80 103.00 c101.93 0 152.89 0 191.83 19.84 a182 182 0 0 1 79.54 79.54 c19.84 38.93 19.84 89.90 19.84 191.83 L921.00 629.80 c0 101.93 0 152.89 -19.84 191.83 a182 182 0 0 1 -79.54 79.54 c-38.93 19.84 -89.90 19.84 -191.83 19.84 L394.20 921.00 c-101.93 0 -152.89 0 -191.83 -19.84 a182 182 0 0 1 -79.54 -79.54 c-19.84 -38.93 -19.84 -89.90 -19.84 -191.83 L103.00 394.20 c0 -101.93 0 -152.89 19.84 -191.83 a182 182 0 0 1 79.54 -79.54 c38.93 -19.84 89.90 -19.84 191.83 -19.84 Z" stroke="#ffffff" stroke-opacity="0.12" stroke-width="6"/>
  <g>
    <rect x="226.0" y="424.0" width="76" height="176" rx="38.0" fill="#69c7fb" fill-opacity="1"/>
    <rect x="354.0" y="332.0" width="76" height="360" rx="38.0" fill="#69c7fb" fill-opacity="1"/>
    <rect x="482.0" y="388.0" width="76" height="248" rx="38.0" fill="#69c7fb" fill-opacity="1"/>
  </g>
  <g filter="url(#caretGlowC)">
    <rect x="655.0" y="262.0" width="70" height="500" rx="35.0" fill="#ffffff" fill-opacity="1"/><rect x="592.0" y="262.0" width="196" height="64" rx="32.0" fill="#ffffff" fill-opacity="1"/><rect x="592.0" y="698.0" width="196" height="64" rx="32.0" fill="#ffffff" fill-opacity="1"/>
  </g>
</svg>
""" + "\n"

// MARK: - Geometry

/// The rounded-square tile from the master SVG. Each corner is a cubic lead-in,
/// a circular arc of radius 185 * k and a cubic lead-out, spanning 296 * k
/// along each edge. The body uses k = 1; the inset rim uses k = 182 / 185.
func squirclePath(minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat, k: CGFloat) -> CGPath {
    let path = CGMutablePath()
    // Corners in SVG order (y down, clockwise on screen): corner point, incoming edge direction, outgoing edge direction.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: maxX, y: minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: maxX, y: maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: minX, y: maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: minX, y: minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0))
    ]
    func at(_ origin: CGPoint, _ a: CGVector, _ alongA: CGFloat, _ b: CGVector, _ alongB: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x + (a.dx * alongA + b.dx * alongB) * k,
            y: origin.y + (a.dy * alongA + b.dy * alongB) * k
        )
    }
    for (index, (corner, a, b)) in corners.enumerated() {
        let start = at(corner, a, -296, b, 0)
        if index == 0 {
            path.move(to: start)
        } else {
            path.addLine(to: start)
        }
        let arcStart = at(corner, a, -296 + 194.99, b, 20.16)
        path.addCurve(
            to: arcStart,
            control1: at(corner, a, -296 + 103.61, b, 0),
            control2: at(corner, a, -296 + 155.41, b, 0)
        )
        let center = at(corner, a, -185, b, 185)
        let arcEnd = at(corner, a, -20.16, b, 296 - 194.99)
        path.addArc(
            center: center,
            radius: 185 * k,
            startAngle: atan2(arcStart.y - center.y, arcStart.x - center.x),
            endAngle: atan2(arcEnd.y - center.y, arcEnd.x - center.x),
            clockwise: false
        )
        path.addCurve(
            to: at(corner, a, 0, b, 296),
            control1: at(corner, a, -20.16 + 20.16, b, 296 - 194.99 + 39.57),
            control2: at(corner, a, -20.16 + 20.16, b, 296 - 194.99 + 91.38)
        )
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: x, y: y, width: width, height: height),
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
}

let tileBody = squirclePath(minX: 100, minY: 100, maxX: 924, maxY: 924, k: 1)
let tileRim = squirclePath(minX: 103, minY: 103, maxX: 921, maxY: 921, k: 182.0 / 185.0)

/// The voice bars leading into the caret.
let voiceBars = [
    roundedRect(226, 424, 76, 176, 38),
    roundedRect(354, 332, 76, 360, 38),
    roundedRect(482, 388, 76, 248, 38)
]

/// The I-beam caret: stem plus top and bottom serifs.
let caretParts = [
    roundedRect(655, 262, 70, 500, 35),
    roundedRect(592, 262, 196, 64, 32),
    roundedRect(592, 698, 196, 64, 32)
]

/// The 18 x 18 menu bar glyph: three bars and a caret, same composition.
let glyphParts = [
    roundedRect(1.1, 6.5, 2, 5.0, 1.0),
    roundedRect(4.4, 4.0, 2, 10.0, 1.0),
    roundedRect(7.7, 5.5, 2, 7.0, 1.0),
    roundedRect(12.6, 1.5, 2, 15, 1.0),
    roundedRect(10.6, 1.5, 6, 1.9, 0.95),
    roundedRect(10.6, 14.6, 6, 1.9, 0.95)
]

// MARK: - Rendering

func ensureDirectory(_ url: URL) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
}

func removeIfExists(_ url: URL) throws {
    if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
    }
}

/// Renders into a transparent sRGB bitmap whose user space matches an SVG
/// viewBox of `viewBox` x `viewBox` (origin top left, y down).
func render(pixels: Int, viewBox: CGFloat, draw: (CGContext, CGFloat) -> Void) throws -> CGImage {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "ai.sophiie.whispur", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create a \(pixels)x\(pixels) bitmap"])
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))

    let scale = CGFloat(pixels) / viewBox
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx, scale)

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "ai.sophiie.whispur", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to finish a \(pixels)x\(pixels) bitmap"])
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ai.sophiie.whispur", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG for \(url.lastPathComponent)"])
    }
    try png.write(to: url)
}

/// Core Graphics shadows take a blur in device pixels, unaffected by the CTM;
/// a blur of 2 * sigma matches an SVG Gaussian of stdDeviation sigma.
func gaussianBlur(stdDeviation: CGFloat, scale: CGFloat) -> CGFloat {
    2 * stdDeviation * scale
}

/// Ports the master SVG element by element. `scale` is device pixels per SVG unit.
func drawAppIcon(_ ctx: CGContext, scale: CGFloat) {
    // Tile group with its drop shadow (feDropShadow dy 12, stdDeviation 14, black 0.28).
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12 * scale),
        blur: gaussianBlur(stdDeviation: 14, scale: scale),
        color: hex(0x000000, 0.28)
    )
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(tileBody)
    ctx.clip()

    ctx.setFillColor(hex(midnight))
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    // Navy radial glow rising from the bottom edge: centre (512, 900), radii 560 x 380.
    let glow = CGGradient(
        colorsSpace: srgb,
        colors: [hex(navy, 0.9), hex(navy, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 900)
    ctx.scaleBy(x: 560, y: 380)
    ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // White top sheen, 0.09 at y 100 fading out by y 560.
    let sheen = CGGradient(
        colorsSpace: srgb,
        colors: [hex(white, 0.09), hex(white, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: 512, y: 100),
        end: CGPoint(x: 512, y: 560),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Hairline rim.
    ctx.addPath(tileRim)
    ctx.setStrokeColor(hex(white, 0.12))
    ctx.setLineWidth(6)
    ctx.strokePath()

    // Sky voice bars.
    ctx.setFillColor(hex(sky))
    for bar in voiceBars {
        ctx.addPath(bar)
        ctx.fillPath()
    }

    // White caret with a soft bloom (feGaussianBlur stdDeviation 22 merged under the source).
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: gaussianBlur(stdDeviation: 22, scale: scale), color: hex(white))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(hex(white))
    for part in caretParts {
        ctx.addPath(part)
        ctx.fillPath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// Pure black on transparent so AppKit can tint it as a template image.
func drawMenuBarGlyph(_ ctx: CGContext) {
    ctx.setFillColor(hex(0x000000))
    for part in glyphParts {
        ctx.addPath(part)
        ctx.fillPath()
    }
}

/// The master SVG with its viewBox cropped to the tile, for the site's SVG favicon.
func faviconSVG() -> String {
    appIconMasterSVG.replacingOccurrences(
        of: #"<svg width="1024" height="1024" viewBox="0 0 1024 1024""#,
        with: #"<svg width="824" height="824" viewBox="100 100 824 824""#
    )
}

func generateAssets() throws {
    try ensureDirectory(assetCatalogURL)
    try ensureDirectory(appIconSetURL)
    try ensureDirectory(menuBarSetURL)

    for icon in appIconFiles {
        let image = try render(pixels: icon.pixelSize, viewBox: 1024) { ctx, scale in
            drawAppIcon(ctx, scale: scale)
        }
        try writePNG(image, to: appIconSetURL.appendingPathComponent(icon.filename))
    }

    for icon in menuBarFiles {
        let image = try render(pixels: icon.pixelSize, viewBox: 18) { ctx, _ in
            drawMenuBarGlyph(ctx)
        }
        try writePNG(image, to: menuBarSetURL.appendingPathComponent(icon.filename))
    }

    try appIconMasterSVG.write(
        to: appIconSetURL.appendingPathComponent("app-icon-master.svg"),
        atomically: true,
        encoding: .utf8
    )

    if fileManager.fileExists(atPath: publicURL.path) {
        for (siteName, sourceName) in siteIconCopies {
            let destination = publicURL.appendingPathComponent(siteName)
            try removeIfExists(destination)
            try fileManager.copyItem(at: appIconSetURL.appendingPathComponent(sourceName), to: destination)
        }
        try faviconSVG().write(
            to: publicURL.appendingPathComponent("favicon.svg"),
            atomically: true,
            encoding: .utf8
        )
    }

    let tempIconsetURL = rootURL.appendingPathComponent(".build/whispur-volume.iconset", isDirectory: true)
    try removeIfExists(tempIconsetURL)
    try ensureDirectory(tempIconsetURL)

    for icon in appIconFiles {
        try fileManager.copyItem(
            at: appIconSetURL.appendingPathComponent(icon.filename),
            to: tempIconsetURL.appendingPathComponent(icon.filename)
        )
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
    print("Generated app icons, menu bar glyphs, site icons, and \(volumeIconURL.path)")
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
