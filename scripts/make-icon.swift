// LightTable app icon: an ivory light table with two slide mounts, the front one holding a
// small dusk landscape. Light, quiet, readable at 16 px. Run scripts/make-icon.sh.
import AppKit

let S: CGFloat = 1024
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ ctx: CGContext, _ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, locations: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func squircle(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)
}
func canvas(_ size: CGFloat, _ draw: (CGContext, CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / S, y: size / S)
    draw(ctx, size / S)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func base(_ ctx: CGContext, top: UInt32, bottom: UInt32) {
    // Soft outer shadow like Big Sur icons, then the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0x000000, 0.18))
    ctx.addPath(squircle(body)); ctx.setFillColor(c(bottom)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle(body)); ctx.clip()
    gradient(ctx, [c(top), c(bottom)], CGPoint(x: 512, y: 924), CGPoint(x: 512, y: 100))
    ctx.restoreGState()
}

/// A: two slide mounts with a dusk landscape.
func slide(_ ctx: CGContext, center: CGPoint, angle: CGFloat, size: CGFloat, picture: Bool, shade: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let mount = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: c(0x5A4A3A, 0.22))
    ctx.addPath(CGPath(roundedRect: mount, cornerWidth: size * 0.07, cornerHeight: size * 0.07, transform: nil))
    ctx.setFillColor(c(0xFFFFFF)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Paper tone so the mount reads against the ivory body.
    ctx.addPath(CGPath(roundedRect: mount, cornerWidth: size * 0.07, cornerHeight: size * 0.07, transform: nil))
    ctx.clip()
    gradient(ctx, [c(0xFFFFFF), c(0xF1EEE9)], CGPoint(x: 0, y: size / 2), CGPoint(x: 0, y: -size / 2))
    ctx.resetClip()
    let window = CGRect(x: -size * 0.34, y: -size * 0.25, width: size * 0.68, height: size * 0.5)
    let windowPath = CGPath(roundedRect: window, cornerWidth: size * 0.035, cornerHeight: size * 0.035, transform: nil)
    ctx.addPath(windowPath); ctx.clip()
    if picture {
        gradient(ctx, [c(0x7FA3CF), c(0xE9A6A0), c(0xF6C58F)], CGPoint(x: 0, y: window.maxY), CGPoint(x: 0, y: window.minY),
                 locations: [0, 0.6, 1])
        // Sun
        ctx.setFillColor(c(0xFFF4DF, 0.95))
        ctx.fillEllipse(in: CGRect(x: window.midX + size * 0.05, y: window.minY + size * 0.12, width: size * 0.12, height: size * 0.12))
        // Two mountain layers
        let far = CGMutablePath()
        far.move(to: CGPoint(x: window.minX, y: window.minY + size * 0.12))
        far.addLine(to: CGPoint(x: window.minX + size * 0.2, y: window.minY + size * 0.26))
        far.addLine(to: CGPoint(x: window.minX + size * 0.38, y: window.minY + size * 0.14))
        far.addLine(to: CGPoint(x: window.minX + size * 0.52, y: window.minY + size * 0.22))
        far.addLine(to: CGPoint(x: window.maxX, y: window.minY + size * 0.1))
        far.addLine(to: CGPoint(x: window.maxX, y: window.minY))
        far.addLine(to: CGPoint(x: window.minX, y: window.minY))
        ctx.addPath(far); ctx.setFillColor(c(0x8A7FA6, 0.75)); ctx.fillPath()
        let near = CGMutablePath()
        near.move(to: CGPoint(x: window.minX, y: window.minY + size * 0.05))
        near.addCurve(to: CGPoint(x: window.maxX, y: window.minY + size * 0.08),
                      control1: CGPoint(x: window.minX + size * 0.25, y: window.minY + size * 0.16),
                      control2: CGPoint(x: window.maxX - size * 0.2, y: window.minY - size * 0.02))
        near.addLine(to: CGPoint(x: window.maxX, y: window.minY))
        near.addLine(to: CGPoint(x: window.minX, y: window.minY))
        ctx.addPath(near); ctx.setFillColor(c(0x4E5A7A)); ctx.fillPath()
    } else {
        gradient(ctx, [c(0xFBF6EE), c(0xEDE3D6)], CGPoint(x: 0, y: window.maxY), CGPoint(x: 0, y: window.minY))
    }
    ctx.resetClip()
    // Inner bevel of the window
    ctx.addPath(windowPath); ctx.setStrokeColor(c(0x000000, 0.08)); ctx.setLineWidth(size * 0.006); ctx.strokePath()
    ctx.restoreGState()
    _ = shade
}

func iconA(_ ctx: CGContext, _ s: CGFloat) {
    base(ctx, top: 0xFBF8F3, bottom: 0xEDE6DB)
    ctx.saveGState(); ctx.addPath(squircle(body)); ctx.clip()
    // Light-table glow behind the slides.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c(0xFFFFFF, 0.9), c(0xFFFFFF, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0, endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])
    slide(ctx, center: CGPoint(x: 560, y: 560), angle: 0.16, size: 470, picture: false, shade: 0)
    slide(ctx, center: CGPoint(x: 480, y: 480), angle: -0.08, size: 500, picture: true, shade: 0)
    ctx.restoreGState()
}

// Writes every size of an .iconset; scripts/make-icon.sh turns it into Resources/AppIcon.icns.
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! canvas(CGFloat(base * scale), iconA).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
