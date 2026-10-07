import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let width = 800
let height = 480
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 20, y: y, width: 760, height: size + 14),
        withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph])
}
let ink = NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.20, alpha: 1)
let secondary = NSColor(calibratedRed: 0.37, green: 0.43, blue: 0.53, alpha: 1)
text("Fn Mute", y: 394, size: 34, weight: .semibold, color: ink)
text("Keep your music. Clear your dictation.", y: 360, size: 17, weight: .regular, color: secondary)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 345, y: 260))
arrow.line(to: NSPoint(x: 452, y: 260))
arrow.move(to: NSPoint(x: 429, y: 281))
arrow.line(to: NSPoint(x: 453, y: 260))
arrow.line(to: NSPoint(x: 429, y: 239))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedRed: 0.35, green: 0.57, blue: 0.83, alpha: 1).setStroke()
arrow.stroke()
text("Drag Fn Mute into Applications", y: 151, size: 18, weight: .medium, color: ink)
text("Free and open source · MIT License", y: 9, size: 12, weight: .regular, color: secondary)
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
