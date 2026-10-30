import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: pixels, height: pixels), xRadius: 220 * scale, yRadius: 220 * scale)
    NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.82, blue: 0.75, alpha: 1), ending: NSColor(calibratedRed: 0.015, green: 0.35, blue: 0.45, alpha: 1))!.draw(in: background, angle: -80)
    let bolt = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [(580, 910), (225, 450), (455, 450), (400, 110), (810, 600), (555, 600)]
    bolt.move(to: NSPoint(x: points[0].0 * scale, y: points[0].1 * scale))
    for point in points.dropFirst() { bolt.line(to: NSPoint(x: point.0 * scale, y: point.1 * scale)) }; bolt.close()
    NSColor.white.setFill(); bolt.fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    // iconutil's named 1x and 2x images use these exact pixel sizes.
    if [16, 32, 128, 256, 512].contains(pixels) { try data.write(to: destination.appendingPathComponent("icon_\(pixels)x\(pixels).png")) }
    if [16, 32, 128, 256, 512].contains(pixels / 2) { try data.write(to: destination.appendingPathComponent("icon_\(pixels / 2)x\(pixels / 2)@2x.png")) }
}
