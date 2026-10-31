#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CoreText

let width: CGFloat = 1200
let height: CGFloat = 630
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "public/og-image.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil,
    width: Int(width),
    height: Int(height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create context\n", stderr)
    exit(1)
}

// Palette: Sophiie www design tokens (src/styles/global.css).
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}
let surfacePrimary = hex(0xffffff)  // --color-surface-primary
let midnight = hex(0x140934)        // --color-midnight / --color-text-primary
let textMuted = hex(0x65696f)       // --color-text-muted
let brandSky = 0x69c7fb as UInt32   // --color-brand-sky
let glowSky = 0xc7efff as UInt32    // --color-what-we-do-glow

// Calm white canvas with a soft sky aura, like the site hero.
ctx.setFillColor(surfacePrimary)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

func aura(_ color: UInt32, _ alpha: CGFloat, center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: colorSpace, colors: [hex(color, alpha), hex(color, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}
aura(glowSky, 0.9, center: CGPoint(x: 220, y: height / 2), radius: 420)
aura(brandSky, 0.28, center: CGPoint(x: width - 140, y: 60), radius: 520)

// Fonts: the site's self-hosted Schibsted Grotesk and Inter, with system fallbacks.
for file in ["public/fonts/schibsted-grotesk-latin-wght-normal.woff2", "public/fonts/inter-latin-wght-normal.woff2"] {
    CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: file) as CFURL, .process, nil)
}
func font(_ family: String, size: CGFloat, weight: CGFloat) -> NSFont {
    // Variable fonts: set the wght axis directly (0x77676874 is the "wght" tag).
    let desc = NSFontDescriptor(fontAttributes: [
        .family: family,
        NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [0x77676874: weight],
    ])
    if let f = NSFont(descriptor: desc, size: size), f.familyName == family { return f }
    return NSFont.systemFont(ofSize: size, weight: weight >= 600 ? .semibold : (weight >= 500 ? .medium : .regular))
}

// Draw app icon (left side, large)
let iconPath = "Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png"
if let iconData = try? Data(contentsOf: URL(fileURLWithPath: iconPath)),
   let iconImage = NSImage(data: iconData),
   let iconCG = iconImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let iconSize: CGFloat = 260
    let iconRect = CGRect(
        x: 90,
        y: (height - iconSize) / 2,
        width: iconSize,
        height: iconSize
    )
    // Soft shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -16),
        blur: 40,
        color: hex(0x140934, 0.22)
    )
    ctx.draw(iconCG, in: iconRect)
    ctx.restoreGState()
}

// Text
func drawText(_ text: String, at point: CGPoint, font: NSFont, color: CGColor, letterSpacing: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color) ?? NSColor.black,
        .kern: letterSpacing
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

let heading = "Schibsted Grotesk"
let body = "Inter"
let textX: CGFloat = 410
drawText("Whispur", at: CGPoint(x: textX, y: height - 262), font: font(heading, size: 92, weight: 650), color: midnight, letterSpacing: -2)
drawText("Voice dictation for macOS.", at: CGPoint(x: textX, y: height - 328), font: font(heading, size: 40, weight: 550), color: midnight, letterSpacing: -1)
drawText("Free and open source \u{00B7} Bring your own keys", at: CGPoint(x: textX, y: height - 384), font: font(body, size: 26, weight: 400), color: textMuted)

// Footer: URL plus the Sophiie mark.
drawText("whispur.app", at: CGPoint(x: textX, y: 72), font: font(body, size: 22, weight: 500), color: textMuted)
if let logo = NSImage(contentsOfFile: "public/brand/sophiie.svg"),
   let logoCG = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let h: CGFloat = 28
    let w = h * logo.size.width / logo.size.height
    drawText("by", at: CGPoint(x: width - 90 - w - 36, y: 72), font: font(body, size: 22, weight: 400), color: textMuted)
    ctx.draw(logoCG, in: CGRect(x: width - 90 - w, y: 66, width: w, height: h))
}

// Save to PNG
guard let cgImage = ctx.makeImage() else {
    fputs("Failed to make image\n", stderr)
    exit(1)
}
let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
guard let tiffData = nsImage.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
