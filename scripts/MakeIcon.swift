import AppKit

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
var frames = Data()
func integer(_ value: Int) -> Data {
    var bigEndian = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
// ICNS stores PNG frames in typed, length-prefixed chunks.
for (size, type) in [(128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let s = CGFloat(size)
    NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84),
        xRadius: s * 0.19, yRadius: s * 0.19).fill()
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: s * 0.5, y: s * 0.79))
    shield.line(to: NSPoint(x: s * 0.72, y: s * 0.69))
    shield.line(to: NSPoint(x: s * 0.70, y: s * 0.42))
    shield.curve(to: NSPoint(x: s * 0.5, y: s * 0.23), controlPoint1: NSPoint(x: s * 0.68, y: s * 0.33), controlPoint2: NSPoint(x: s * 0.57, y: s * 0.26))
    shield.curve(to: NSPoint(x: s * 0.30, y: s * 0.42), controlPoint1: NSPoint(x: s * 0.43, y: s * 0.26), controlPoint2: NSPoint(x: s * 0.32, y: s * 0.33))
    shield.line(to: NSPoint(x: s * 0.28, y: s * 0.69)); shield.close()
    NSColor(calibratedRed: 0.24, green: 0.84, blue: 0.43, alpha: 1).setFill(); shield.fill()
    let dark = NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.12, alpha: 1)
    dark.setStroke()
    let shackle = NSBezierPath(roundedRect: NSRect(x: s * 0.43, y: s * 0.50, width: s * 0.14, height: s * 0.15),
        xRadius: s * 0.07, yRadius: s * 0.07)
    shackle.lineWidth = s * 0.035; shackle.stroke()
    dark.setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.39, y: s * 0.39, width: s * 0.22, height: s * 0.17),
        xRadius: s * 0.03, yRadius: s * 0.03).fill()
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    frames.append(Data(type.utf8)); frames.append(integer(png.count + 8)); frames.append(png)
}
var icon = Data("icns".utf8)
icon.append(integer(frames.count + 8)); icon.append(frames)
try icon.write(to: outputURL, options: .atomic)
