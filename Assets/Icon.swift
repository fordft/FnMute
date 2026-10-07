import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.17, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 55, y: 55, width: 914, height: 914), xRadius: 200, yRadius: 200).fill()
    NSColor(calibratedRed: 0.32, green: 0.67, blue: 1, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 150, y: 210, width: 430, height: 540), xRadius: 100, yRadius: 100).fill()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 224, weight: .semibold),
        .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
    ("fn" as NSString).draw(in: NSRect(x: 150, y: 332, width: 430, height: 285), withAttributes: attributes)
    NSColor.white.setFill()
    let speaker = NSBezierPath()
    speaker.move(to: NSPoint(x: 620, y: 419))
    speaker.line(to: NSPoint(x: 680, y: 419))
    speaker.line(to: NSPoint(x: 770, y: 339))
    speaker.line(to: NSPoint(x: 770, y: 643))
    speaker.line(to: NSPoint(x: 680, y: 563))
    speaker.line(to: NSPoint(x: 620, y: 563))
    speaker.close()
    speaker.fill()
    let slash = NSBezierPath()
    slash.move(to: NSPoint(x: 609, y: 640))
    slash.line(to: NSPoint(x: 859, y: 364))
    slash.lineWidth = 39
    slash.lineCapStyle = .round
    NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.17, alpha: 1).setStroke()
    slash.stroke()
    slash.lineWidth = 21
    NSColor.white.setStroke()
    slash.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    for base in [16, 32, 128, 256, 512] {
        if size == base { try data.write(to: folder.appendingPathComponent("icon_\(base)x\(base).png")) }
        if size == base * 2 { try data.write(to: folder.appendingPathComponent("icon_\(base)x\(base)@2x.png")) }
    }
}
