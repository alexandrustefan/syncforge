// Renders SyncForge's app icon (1024 px master) with CoreGraphics. Usage: swift scripts/make-icon.swift out.png
import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824 px rounded square centred in 1024.
let inset = 100.0
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let gradient = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.13, green: 0.10, blue: 0.36, alpha: 1),
    CGColor(red: 0.20, green: 0.25, blue: 0.70, alpha: 1),
    CGColor(red: 0.10, green: 0.62, blue: 0.78, alpha: 1),
] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])

// Two out-of-phase waves (left: faint) converging into one aligned wave (bright).
func wave(phase: Double, amplitude: Double, alpha: Double, width: Double, from x0: Double, to x1: Double) {
    let path = CGMutablePath()
    var first = true
    var x = x0
    while x <= x1 {
        let t = (x - x0) / (x1 - x0)
        let env = pow(sin(Double.pi * t), 0.8)
        let y = size / 2 + amplitude * env * sin((x - rect.minX) / 62 + phase)
        if first { path.move(to: CGPoint(x: x, y: y)); first = false } else { path.addLine(to: CGPoint(x: x, y: y)) }
        x += 2
    }
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}
wave(phase: 1.6, amplitude: 150, alpha: 0.28, width: 26, from: rect.minX + 90, to: rect.maxX - 90)
wave(phase: 0.0, amplitude: 150, alpha: 1.0, width: 34, from: rect.minX + 90, to: rect.maxX - 90)

// Alignment marks.
for dx in [-1.0, 0, 1] {
    let x = size / 2 + dx * 195
    let bar = CGRect(x: x - 9, y: size / 2 - 250, width: 18, height: 500)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: dx == 0 ? 0.55 : 0.22))
    ctx.fillPath()
}
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
