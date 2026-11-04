import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Parrot/Assets.xcassets")
let check = CommandLine.arguments.dropFirst() == ["--check"]
if !CommandLine.arguments.dropFirst().isEmpty && !check { fatalError("Usage: swift scripts/generate-icon.swift [--check]") }

func render(width: Int, height: Int, menu: Bool, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else {
        fatalError("Cannot create bitmap")
    }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: CGFloat(width), y: CGFloat(height))
    if !menu {
        context.setFillColor(CGColor(red: 0.96, green: 0.80, blue: 0.68, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80), cornerWidth: 0.19, cornerHeight: 0.19, transform: nil))
        context.fillPath()
    }
    context.saveGState()
    if menu {
        context.translateBy(x: -0.16, y: -0.04)
        context.scaleBy(x: 1.32, y: 1.08)
    }
    context.setStrokeColor(menu ? CGColor(gray: 0, alpha: 1) : CGColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1))
    context.setLineWidth(0.115)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 0.70, y: 0.72))
    context.addLine(to: CGPoint(x: 0.46, y: 0.72))
    context.addCurve(to: CGPoint(x: 0.34, y: 0.56), control1: CGPoint(x: 0.32, y: 0.72), control2: CGPoint(x: 0.28, y: 0.63))
    context.addLine(to: CGPoint(x: 0.66, y: 0.44))
    context.addCurve(to: CGPoint(x: 0.54, y: 0.28), control1: CGPoint(x: 0.72, y: 0.37), control2: CGPoint(x: 0.68, y: 0.28))
    context.addLine(to: CGPoint(x: 0.30, y: 0.28))
    context.strokePath()
    context.restoreGState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
    if check {
        guard try Data(contentsOf: url) == png else { fatalError("Icon differs: \(url.path)") }
    } else {
        try png.write(to: url, options: .atomic)
    }
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(width: size * scale, height: size * scale, menu: false,
                   to: assets.appendingPathComponent("AppIcon.appiconset/icon_\(size)\(suffix).png"))
    }
}
for scale in [1, 2] {
    let suffix = scale == 2 ? "@2x" : ""
    try render(width: 14 * scale, height: 18 * scale, menu: true,
               to: assets.appendingPathComponent("MenuBarIcon.imageset/menubar\(suffix).png"))
}

if check { print("All icon assets match the generator.") }
