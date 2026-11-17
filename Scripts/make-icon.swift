#!/usr/bin/env swift
// Renders the Limiar app icon (vector, CoreGraphics) into an .iconset, then builds AppIcon.icns.
// Usage: swift Scripts/make-icon.swift   (run from the repository root)
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let icnsOut = root.appendingPathComponent("Resources/AppIcon.icns")
let logoOut = root.appendingPathComponent("docs/logo.png")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Superellipse ("squircle") close to Apple's continuous-corner icon shape.
func squircle(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Draws the icon in a 1024×1024 coordinate space (origin bottom-left).
func drawIcon(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    // Drop shadow + background gradient.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0B2F2A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    linearGradient(ctx, [color(0x147060), color(0x0B2F2A)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Soft top highlight.
    let radial = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(radial, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 900), endRadius: 560, options: [])
    ctx.restoreGState()

    // Battery capsule.
    let capsule = CGRect(x: 512 - 150, y: 210, width: 300, height: 520)
    let stroke: CGFloat = 28
    let capsulePath = CGPath(roundedRect: capsule, cornerWidth: 86, cornerHeight: 86, transform: nil)

    // Fill up to 80% of the inner height.
    let inner = capsule.insetBy(dx: stroke / 2 + 22, dy: stroke / 2 + 22)
    let fillLevel: CGFloat = 0.8
    let fillRect = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * fillLevel)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 58, cornerHeight: 58, transform: nil))
    ctx.clip()
    ctx.clip(to: fillRect)
    linearGradient(ctx, [color(0x2BCB86), color(0xA6F7CB)], from: CGPoint(x: 512, y: inner.minY), to: CGPoint(x: 512, y: fillRect.maxY))
    ctx.restoreGState()

    ctx.addPath(capsulePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.92))
    ctx.setLineWidth(stroke)
    ctx.strokePath()

    // Terminal nub.
    let nub = CGRect(x: 512 - 62, y: capsule.maxY + 22, width: 124, height: 42)
    ctx.addPath(CGPath(roundedRect: nub, cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.setFillColor(color(0xFFFFFF, 0.92))
    ctx.fillPath()

    // The threshold: a glowing line crossing the capsule at the fill level.
    let y = fillRect.maxY
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36, color: color(0xC6FF6B, 0.85))
    ctx.setStrokeColor(color(0xC6FF6B))
    ctx.setLineWidth(24)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 512 - 250, y: y))
    ctx.addLine(to: CGPoint(x: 512 + 250, y: y))
    ctx.strokePath()
    ctx.restoreGState()
}

func renderPNG(size: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "icon", code: 1)
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    drawIcon(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: icnsOut.deletingLastPathComponent(), withIntermediateDirectories: true)
try fm.createDirectory(at: logoOut.deletingLastPathComponent(), withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try renderPNG(size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try renderPNG(size: 512, to: logoOut)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsOut.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(icnsOut.path) and \(logoOut.path)")
