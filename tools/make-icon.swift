// Draws Resources/AppIcon.icns: the panel's charcoal as a macOS-style rounded square with the
// eye symbol in the panel's cyan. Run from the repo root: swift tools/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
// Apple's icon grid: the shape is 824 pt inside the 1024 canvas, corner radius ~185.
let shapeInset: CGFloat = 100
let cornerRadius: CGFloat = 185
let background = NSColor(red: 0.08, green: 0.085, blue: 0.095, alpha: 1)
let edge = NSColor.white.withAlphaComponent(0.10)
let tint = NSColor(red: 0.35, green: 0.80, blue: 0.95, alpha: 1)

func render() -> NSImage {
    NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        let rect = NSRect(x: shapeInset, y: shapeInset, width: canvas - 2 * shapeInset, height: canvas - 2 * shapeInset)
        let shape = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        background.setFill()
        shape.fill()
        edge.setStroke()
        shape.lineWidth = 6
        shape.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
            .applying(.init(paletteColors: [tint]))
        guard let symbol = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return false }
        let s = symbol.size
        symbol.draw(in: NSRect(x: (canvas - s.width) / 2, y: (canvas - s.height) / 2, width: s.width, height: s.height))
        return true
    }
}

func png(_ image: NSImage, side: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let image = render()
for base in [16, 32, 128, 256, 512] {
    try png(image, side: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(image, side: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run()
p.waitUntilExit()
try png(image, side: 512).write(to: URL(fileURLWithPath: "Resources/AppIcon-preview.png"))
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
