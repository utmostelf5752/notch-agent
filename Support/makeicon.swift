// Generates the app, website, and menu-bar icon assets.
// Run from the repository root: swift Support/makeicon.swift
import AppKit
import Foundation

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
private let support = root.appendingPathComponent("Support", isDirectory: true)
private let docs = root.appendingPathComponent("docs", isDirectory: true)
private let appSourceURL = support.appendingPathComponent("AppIcon-source.png")
private let menuBarSourceURL = support.appendingPathComponent("MenuBarIcon-master.png")

private func bitmap(width: Int, height: Int, draw: () -> Void) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("failed to create \(width)x\(height) bitmap")
    }

    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

private func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("failed to encode \(url.lastPathComponent)")
    }
    do {
        try data.write(to: url)
    } catch {
        fatalError("failed to write \(url.path): \(error)")
    }
}

guard let appSource = NSImage(contentsOf: appSourceURL) else {
    fatalError("missing selected icon source at \(appSourceURL.path)")
}

// The selected concept already contains the graphite squircle, half-height
// notch panel, terminal prompt, and blue lower halo. The source generation had
// an opaque black canvas, so clip it to the icon's visible squircle here rather
// than redrawing or approximating the selected artwork.
private func renderAppIcon(size: Int) -> NSBitmapImageRep {
    bitmap(width: size, height: size) {
        let side = CGFloat(size)
        let inset = side * (100.0 / 1024.0)
        let iconRect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        let mask = NSBezierPath(
            roundedRect: iconRect,
            xRadius: side * (185.0 / 1024.0),
            yRadius: side * (185.0 / 1024.0)
        )
        mask.addClip()
        appSource.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: NSRect(origin: .zero, size: appSource.size),
            operation: .copy,
            fraction: 1
        )
    }
}

try? fileManager.createDirectory(at: docs, withIntermediateDirectories: true)
writePNG(renderAppIcon(size: 1024), to: support.appendingPathComponent("icon-1024.png"))
writePNG(renderAppIcon(size: 256), to: docs.appendingPathComponent("icon.png"))
writePNG(renderAppIcon(size: 180), to: docs.appendingPathComponent("apple-touch-icon.png"))

// Build a complete .icns so Finder, Spotlight, and the app bundle all use the
// selected artwork at the correct native resolutions.
let iconsetURL = fileManager.temporaryDirectory
    .appendingPathComponent("Eave-\(UUID().uuidString).iconset", isDirectory: true)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconsetURL) }

let iconsetSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (name, size) in iconsetSizes {
    writePNG(renderAppIcon(size: size), to: iconsetURL.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns",
    iconsetURL.path,
    "--output", support.appendingPathComponent("AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}

guard let menuBarSource = NSImage(contentsOf: menuBarSourceURL) else {
    fatalError("missing menu-bar source at \(menuBarSourceURL.path)")
}

// The master is the generated cleanup of the user's sketch, optically arranged
// for small sizes. Render it into an 18pt menu-bar-safe frame at 2x.
let menuBarIcon = bitmap(width: 36, height: 36) {
    menuBarSource.draw(
        in: NSRect(x: 0, y: 0, width: 36, height: 36),
        from: NSRect(origin: .zero, size: menuBarSource.size),
        operation: .sourceOver,
        fraction: 1
    )
}
writePNG(menuBarIcon, to: support.appendingPathComponent("MenuBarIcon.png"))
writePNG(menuBarIcon, to: docs.appendingPathComponent("menu-bar-icon.png"))

print("wrote Support/icon-1024.png")
print("wrote Support/AppIcon.icns")
print("wrote Support/MenuBarIcon.png")
print("wrote docs/icon.png, docs/apple-touch-icon.png, and docs/menu-bar-icon.png")
