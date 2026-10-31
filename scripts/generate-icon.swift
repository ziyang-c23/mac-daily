// Run with: swift -module-cache-path tmp/icons/modules scripts/generate-icon.swift tmp/icons/MacDaily.iconset
import AppKit
import Foundation
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        let base = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 194, yRadius: 194)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -9)
        shadow.set()
        NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.65, alpha: 1).setFill()
        base.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [
            NSColor(calibratedRed: 0.08, green: 0.69, blue: 0.65, alpha: 1),
            NSColor(calibratedRed: 0.14, green: 0.43, blue: 0.78, alpha: 1),
            NSColor(calibratedRed: 0.25, green: 0.28, blue: 0.67, alpha: 1)
        ])!.draw(in: base, angle: -60)
        let edge = NSBezierPath(roundedRect: NSRect(x: 83, y: 83, width: 858, height: 858), xRadius: 191, yRadius: 191)
        NSColor.white.withAlphaComponent(0.20).setStroke()
        edge.lineWidth = 3
        edge.stroke()

        // Four panels share the menu-bar entry's grid silhouette. The warm
        // upper-right panel adds a distinct daily-tool identity at small sizes.
        let panels: [(NSRect, NSColor)] = [
            (NSRect(x: 246, y: 532, width: 244, height: 244), .white),
            (NSRect(x: 534, y: 532, width: 244, height: 244), NSColor(calibratedRed: 1.0, green: 0.81, blue: 0.40, alpha: 1)),
            (NSRect(x: 246, y: 244, width: 244, height: 244), NSColor(calibratedWhite: 1, alpha: 0.88)),
            (NSRect(x: 534, y: 244, width: 244, height: 244), NSColor(calibratedWhite: 1, alpha: 0.73))
        ]
        for (rect, color) in panels {
            NSGraphicsContext.saveGraphicsState()
            let panelShadow = NSShadow()
            panelShadow.shadowColor = NSColor(calibratedRed: 0.06, green: 0.14, blue: 0.32, alpha: 0.18)
            panelShadow.shadowBlurRadius = 9
            panelShadow.shadowOffset = NSSize(width: 0, height: -5)
            panelShadow.set()
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 52, yRadius: 52).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
