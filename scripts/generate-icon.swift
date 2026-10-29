// Original Raptor mark. Generates local icon assets without network access.
import AppKit

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: generate-icon OUTPUT.iconset")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                                      pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                     xRadius: 200, yRadius: 200).fill()
        // Angular bird head, beak, and neck, with a bright eye.
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 270, y: 240))
        head.line(to: NSPoint(x: 350, y: 565))
        head.line(to: NSPoint(x: 275, y: 770))
        head.line(to: NSPoint(x: 665, y: 705))
        head.line(to: NSPoint(x: 810, y: 495))
        head.line(to: NSPoint(x: 580, y: 515))
        head.line(to: NSPoint(x: 540, y: 240))
        head.close()
        NSColor(calibratedRed: 0.2, green: 0.86, blue: 0.67, alpha: 1).setFill()
        head.fill()
        NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 555, y: 605, width: 54, height: 54)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
