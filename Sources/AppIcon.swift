import AppKit

/// Draws Rimshot's icons in code: the menu bar template image and the Dock / app icon, each in an
/// on and an off state. `tools/make-icon/main.swift` uses `dockImage` to produce AppIcon.icns at build time.
enum AppIcon {
    /// 18 pt template image: a screen outline that's lit (thick, with an inner glow line) when on and
    /// dashed when off.
    static func menuBarImage(on: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let screen = NSRect(x: 2, y: 3.5, width: 14, height: 11)
            NSColor.black.setStroke()
            if on {
                let outer = NSBezierPath(roundedRect: screen, xRadius: 3, yRadius: 3)
                outer.lineWidth = 2.2
                outer.stroke()
                let inner = NSBezierPath(roundedRect: screen.insetBy(dx: 2.6, dy: 2.6), xRadius: 1.2, yRadius: 1.2)
                inner.lineWidth = 0.8
                NSColor.black.withAlphaComponent(0.55).setStroke()
                inner.stroke()
            } else {
                let outer = NSBezierPath(roundedRect: screen.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
                outer.lineWidth = 1.2
                outer.setLineDash([2.2, 1.6], count: 2, phase: 0)
                outer.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = on ? "Rimshot on" : "Rimshot off"
        return image
    }

    /// Square app icon: a dark tile holding a screen whose rim glows in pink, violet and blue.
    static func dockImage(on: Bool, size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = size / 1024
            ctx.scaleBy(x: s, y: s)

            // macOS icon grid: an 824 pt tile centred in 1024 with ~185 pt corners.
            let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
            let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(tilePath)
            ctx.setFillColor(NSColor(hex: 0x0B0912).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(tilePath)
            ctx.clip()
            let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
                NSColor(hex: 0x1D1630).cgColor, NSColor(hex: 0x07060B).cgColor,
            ] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

            // The screen and its rim light.
            let screen = CGRect(x: 232, y: 300, width: 560, height: 400)
            let screenPath = CGPath(roundedRect: screen, cornerWidth: 46, cornerHeight: 46, transform: nil)
            let colors: [NSColor] = on
                ? [NSColor(hex: 0xFF4FB8), NSColor(hex: 0x8B5CFF), NSColor(hex: 0x2CC8FF)]
                : [NSColor(hex: 0x4A4658), NSColor(hex: 0x3A3747), NSColor(hex: 0x45505C)]
            let rim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                 colors: colors.map(\.cgColor) as CFArray, locations: [0, 0.5, 1])!

            if on {
                // Soft outer bloom.
                for (blur, alpha) in [(90.0, 0.55), (40.0, 0.8)] {
                    ctx.saveGState()
                    ctx.setShadow(offset: .zero, blur: blur, color: NSColor(hex: 0x9D5CFF).withAlphaComponent(alpha).cgColor)
                    ctx.addPath(screenPath)
                    ctx.setLineWidth(26)
                    ctx.setStrokeColor(NSColor(hex: 0xB56CFF).withAlphaComponent(0.9).cgColor)
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
            ctx.addPath(screenPath)
            ctx.setFillColor(NSColor(hex: 0x050408).cgColor)
            ctx.fillPath()

            // Gradient-coloured rim, and the light it throws onto the inside of the screen.
            ctx.saveGState()
            ctx.addPath(screenPath)
            ctx.setLineWidth(on ? 22 : 14)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(rim, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
            ctx.restoreGState()
            if on {
                ctx.saveGState()
                ctx.addPath(screenPath)
                ctx.clip()
                for inset in stride(from: 10.0, through: 70.0, by: 12.0) {
                    let r = screen.insetBy(dx: inset, dy: inset)
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: max(46 - inset, 8), cornerHeight: max(46 - inset, 8), transform: nil))
                    ctx.setLineWidth(12)
                    ctx.setStrokeColor(NSColor(hex: 0x9D5CFF).withAlphaComponent(0.16 * (1 - inset / 80)).cgColor)
                    ctx.strokePath()
                }
                ctx.restoreGState()
            }
            ctx.restoreGState()
            return true
        }
    }
}
