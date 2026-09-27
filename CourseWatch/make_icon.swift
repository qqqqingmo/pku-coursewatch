import AppKit
import SwiftUI

try MainActor.assumeIsolated {
guard CommandLine.arguments.count > 1 else { fatalError("Pass the CourseWatch source directory") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Match the bell.badge.fill mark and teal background in DashboardView.sidebar.
let artwork = ZStack {
    RoundedRectangle(cornerRadius: 273)
        .fill(LinearGradient(
            colors: [Color(red: 0.05, green: 0.46, blue: 0.47),
                     Color(red: 0.08, green: 0.55, blue: 0.54)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
        .frame(width: 864, height: 864)
    Image(systemName: "bell.badge.fill")
        .symbolRenderingMode(.monochrome)
        .font(.system(size: 510, weight: .regular))
        .foregroundStyle(.white)
        .frame(width: 864, height: 864)
}
.frame(width: 1024, height: 1024)

let renderer = ImageRenderer(content: artwork)
renderer.scale = 1
guard let image = renderer.nsImage,
      image.tiffRepresentation != nil else {
    fatalError("Unable to render app icon")
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let resized = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: resized) else {
            fatalError("Unable to resize app icon")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                   operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(size)x\(size)\(suffix).png"
        guard let data = resized.representation(using: .png, properties: [:]) else {
            fatalError("Unable to write \(filename)")
        }
        try data.write(to: iconset.appendingPathComponent(filename))
    }
}
}
