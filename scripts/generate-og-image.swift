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

// Background gradient (deep teal → cyan)
let locations: [CGFloat] = [0.0, 1.0]
let colors = [
    CGColor(red: 7/255, green: 20/255, blue: 28/255, alpha: 1),
    CGColor(red: 17/255, green: 60/255, blue: 78/255, alpha: 1)
]
if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
}

// Accent radial glow (top-left)
let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 46/255, green: 209/255, blue: 195/255, alpha: 0.35),
        CGColor(red: 46/255, green: 209/255, blue: 195/255, alpha: 0)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 200, y: height - 120), startRadius: 0,
                       endCenter: CGPoint(x: 200, y: height - 120), endRadius: 450, options: [])

let glow2 = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 95/255, green: 184/255, blue: 255/255, alpha: 0.25),
        CGColor(red: 95/255, green: 184/255, blue: 255/255, alpha: 0)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(glow2, startCenter: CGPoint(x: width - 180, y: 180), startRadius: 0,
                       endCenter: CGPoint(x: width - 180, y: 180), endRadius: 400, options: [])

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
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.4)
    )
    ctx.draw(iconCG, in: iconRect)
    ctx.restoreGState()
}

// Text
func drawText(_ text: String, at point: CGPoint, fontSize: CGFloat, weight: NSFont.Weight, color: CGColor, letterSpacing: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color) ?? NSColor.white,
        .kern: letterSpacing,
        .paragraphStyle: paragraph
    ]
    let attr = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

// Flip coordinate system to draw text upright (CoreText y-up)
let textX: CGFloat = 410
drawText(
    "Whispur",
    at: CGPoint(x: textX, y: height - 260),
    fontSize: 88,
    weight: .bold,
    color: CGColor(red: 232/255, green: 246/255, blue: 250/255, alpha: 1),
    letterSpacing: -2
)

drawText(
    "Voice dictation for macOS.",
    at: CGPoint(x: textX, y: height - 320),
    fontSize: 36,
    weight: .medium,
    color: CGColor(red: 46/255, green: 209/255, blue: 195/255, alpha: 1),
    letterSpacing: -0.5
)

drawText(
    "Open source · Bring your own keys · Free",
    at: CGPoint(x: textX, y: height - 380),
    fontSize: 24,
    weight: .regular,
    color: CGColor(red: 155/255, green: 181/255, blue: 192/255, alpha: 1)
)

// URL footer
drawText(
    "whispur.app",
    at: CGPoint(x: textX, y: 70),
    fontSize: 22,
    weight: .medium,
    color: CGColor(red: 155/255, green: 181/255, blue: 192/255, alpha: 1)
)

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
