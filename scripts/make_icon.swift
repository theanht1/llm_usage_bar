// Generates Resources/AppIcon.icns for LLMUsageBar.
// Design: two concentric gauge arcs (coral = Claude, teal = Codex)
// on a deep-indigo squircle — the app's dual-usage readout as an icon.
// Run: swift scripts/make_icon.swift

import AppKit

let canvas: CGFloat = 1024

func drawIcon(scale: CGFloat) {
    func pt(_ v: CGFloat) -> CGFloat { v * scale }

    // Full-bleed macOS-style rounded square with transparent margin.
    let inset = pt(100)
    let squircle = NSRect(x: inset, y: inset, width: pt(canvas) - 2 * inset, height: pt(canvas) - 2 * inset)
    let radius = squircle.width * 0.2237
    let background = NSBezierPath(roundedRect: squircle, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.16, green: 0.12, blue: 0.38, alpha: 1),
        ending: NSColor(calibratedRed: 0.07, green: 0.06, blue: 0.18, alpha: 1)
    )!
    gradient.draw(in: background, angle: -70)

    // Soft glow behind the gauges.
    let glow = NSGradient(
        starting: NSColor(calibratedRed: 0.45, green: 0.35, blue: 0.9, alpha: 0.35),
        ending: NSColor(calibratedRed: 0.45, green: 0.35, blue: 0.9, alpha: 0)
    )!
    NSGraphicsContext.current?.saveGraphicsState()
    background.addClip()
    glow.draw(
        fromCenter: NSPoint(x: pt(512), y: pt(470)), radius: 0,
        toCenter: NSPoint(x: pt(512), y: pt(470)), radius: pt(430),
        options: []
    )
    NSGraphicsContext.current?.restoreGraphicsState()

    let center = NSPoint(x: pt(512), y: pt(480))
    let gaugeStart: CGFloat = 225   // bottom-left
    let gaugeSweep: CGFloat = 270   // clockwise through the top

    func arc(radius: CGFloat, width: CGFloat, fraction: CGFloat, color: NSColor) {
        // Track
        let track = NSBezierPath()
        track.appendArc(
            withCenter: center, radius: pt(radius),
            startAngle: gaugeStart, endAngle: gaugeStart - gaugeSweep, clockwise: true
        )
        track.lineWidth = pt(width)
        track.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.13).setStroke()
        track.stroke()

        // Fill
        let fill = NSBezierPath()
        fill.appendArc(
            withCenter: center, radius: pt(radius),
            startAngle: gaugeStart, endAngle: gaugeStart - gaugeSweep * fraction, clockwise: true
        )
        fill.lineWidth = pt(width)
        fill.lineCapStyle = .round
        color.setStroke()
        fill.stroke()

        // Bright tip dot for a lively finish.
        let tipAngle = (gaugeStart - gaugeSweep * fraction) * .pi / 180
        let tip = NSPoint(
            x: center.x + pt(radius) * cos(tipAngle),
            y: center.y + pt(radius) * sin(tipAngle)
        )
        let dotRadius = pt(width) * 0.28
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: tip.x - dotRadius, y: tip.y - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2
        )).fill()
    }

    arc(radius: 265, width: 88, fraction: 0.68,
        color: NSColor(calibratedRed: 0.91, green: 0.51, blue: 0.35, alpha: 1))  // coral — Claude
    arc(radius: 152, width: 88, fraction: 0.42,
        color: NSColor(calibratedRed: 0.31, green: 0.82, blue: 0.77, alpha: 1))  // teal — Codex
}

func render(pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(scale: CGFloat(pixels) / canvas)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let projectDir = scriptDir.deletingLastPathComponent()
let iconset = projectDir.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in entries {
    render(pixels: pixels, to: iconset.appendingPathComponent("\(name).png"))
}

let output = projectDir.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
