import AppKit
import Foundation

// Usage: swift scripts/create-icon.swift Resources/YooTrack-logo-source.png ICONSET_DIR Resources/YooTrackMark.png
// The menu mark is a transparent, monochrome template derived from the supplied artwork.
guard CommandLine.arguments.count == 4,
      let sourceData = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let sourceBitmap = NSBitmapImageRep(data: sourceData),
      let sourceCG = sourceBitmap.cgImage else {
    fatalError("Expected source PNG, iconset directory, and menu mark destination")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let markURL = URL(fileURLWithPath: CommandLine.arguments[3])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

// Find the artwork, excluding the large white margin in the provided image.
var minX = sourceBitmap.pixelsWide, minY = sourceBitmap.pixelsHigh, maxX = 0, maxY = 0
for y in 0..<sourceBitmap.pixelsHigh {
    for x in 0..<sourceBitmap.pixelsWide {
        guard let color = sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(NSColorSpace.deviceRGB) else { continue }
        if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.5 {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
}
guard maxX > minX, maxY > minY,
      let cropped = sourceCG.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
    fatalError("No dark artwork found in source PNG")
}
let artwork = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
func bitmap(_ pixels: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}
let mark = bitmap(512)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: mark)
NSGraphicsContext.current?.imageInterpolation = .high
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 512, height: 512).fill()
let scale = min(480.0 / CGFloat(cropped.width), 480.0 / CGFloat(cropped.height))
let width = CGFloat(cropped.width) * scale, height = CGFloat(cropped.height) * scale
artwork.draw(in: NSRect(x: (512 - width) / 2, y: (512 - height) / 2, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
// A black-alpha template lets macOS tint the exact same mark for light and dark menu bars.
let bytes = mark.bitmapData!
for y in 0..<512 {
    for x in 0..<512 {
        let offset = y * mark.bytesPerRow + x * 4
        let luminance = (Int(bytes[offset]) * 2126 + Int(bytes[offset + 1]) * 7152 + Int(bytes[offset + 2]) * 722) / 10000
        let alpha = max(0, min(255, (245 - luminance) * 255 / 245))
        bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0; bytes[offset + 3] = UInt8(alpha)
    }
}
try mark.representation(using: .png, properties: [:])!.write(to: markURL)
let markImage = NSImage(size: NSSize(width: 512, height: 512)); markImage.addRepresentation(mark)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let icon = bitmap(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: icon)
    NSGraphicsContext.current?.imageInterpolation = .high
    let unit = CGFloat(pixels) / 1024
    let background = NSBezierPath(roundedRect: NSRect(x: 16 * unit, y: 16 * unit, width: 992 * unit, height: 992 * unit), xRadius: 220 * unit, yRadius: 220 * unit)
    NSColor.white.setFill(); background.fill()
    markImage.draw(in: NSRect(x: 112 * unit, y: 112 * unit, width: 800 * unit, height: 800 * unit))
    NSGraphicsContext.restoreGraphicsState()
    let data = icon.representation(using: .png, properties: [:])!
    if [16, 32, 128, 256, 512].contains(pixels) { try data.write(to: destination.appendingPathComponent("icon_\(pixels)x\(pixels).png")) }
    if [16, 32, 128, 256, 512].contains(pixels / 2) { try data.write(to: destination.appendingPathComponent("icon_\(pixels / 2)x\(pixels / 2)@2x.png")) }
}
