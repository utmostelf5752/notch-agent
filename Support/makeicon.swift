// Generates Support/AppIcon.icns. Run: swift Support/makeicon.swift
// Dark macOS-style squircle, notch silhouette at top, white sparkle glyph.
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// Squircle inset per Apple's icon grid (~100pt margin at 1024).
let iconRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: iconRect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedWhite: 0.16, alpha: 1),
    NSColor(calibratedWhite: 0.04, alpha: 1),
])!.draw(in: squircle, angle: -90)

squircle.addClip()

// Notch silhouette hanging from the top edge.
let notchWidth: CGFloat = 340
let notchHeight: CGFloat = 96
let notchRect = NSRect(
    x: iconRect.midX - notchWidth / 2,
    y: iconRect.maxY - notchHeight,
    width: notchWidth,
    height: notchHeight
)
let radius: CGFloat = 40
let notch = NSBezierPath()
notch.move(to: NSPoint(x: notchRect.minX, y: notchRect.maxY))
notch.line(to: NSPoint(x: notchRect.minX, y: notchRect.minY + radius))
notch.appendArc(
    withCenter: NSPoint(x: notchRect.minX + radius, y: notchRect.minY + radius),
    radius: radius, startAngle: 180, endAngle: 270, clockwise: false
)
notch.line(to: NSPoint(x: notchRect.maxX - radius, y: notchRect.minY))
notch.appendArc(
    withCenter: NSPoint(x: notchRect.maxX - radius, y: notchRect.minY + radius),
    radius: radius, startAngle: 270, endAngle: 0, clockwise: false
)
notch.line(to: NSPoint(x: notchRect.maxX, y: notchRect.maxY))
notch.close()
NSColor.black.setFill()
notch.fill()
NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
notch.lineWidth = 5
notch.stroke()

// White sparkle glyph, centered in the space below the notch.
if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 340, weight: .medium)
    if let sized = symbol.withSymbolConfiguration(config) {
        let tinted = NSImage(size: sized.size)
        tinted.lockFocus()
        sized.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: sized.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let scale: CGFloat = 440 / max(tinted.size.width, tinted.size.height)
        let drawSize = NSSize(width: tinted.size.width * scale, height: tinted.size.height * scale)
        let origin = NSPoint(
            x: iconRect.midX - drawSize.width / 2,
            y: iconRect.minY + (iconRect.height - notchHeight) / 2 - drawSize.height / 2
        )
        tinted.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: .zero, operation: .sourceOver, fraction: 0.95
        )
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}
let out = URL(fileURLWithPath: "Support/icon-1024.png")
try! png.write(to: out)
print("wrote \(out.path)")
