import AppKit

/// Pulls a small, glow-friendly palette out of album art.
enum Palette {
    private struct Bin {
        var weight: Double = 0
        var r = 0.0, g = 0.0, b = 0.0
        var count = 0
    }

    /// Returns 2–4 vivid colors ordered by prominence. Grayscale covers get a soft, cool white palette
    /// tinted by whatever faint hue the art has.
    static func extract(from image: NSImage) -> [NSColor] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let side = 40
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        let hueBins = 18
        var bins = [Bin](repeating: Bin(), count: hueBins)
        var vivid = 0.0, total = 0.0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
            let (h, s, v) = hsv(r, g, b)
            let chroma = s * v
            total += 1
            // Greys and near-blacks don't make good light.
            guard chroma > 0.12, v > 0.18 else { continue }
            vivid += chroma
            // Vivid, bright pixels dominate; dull ones barely count.
            let w = chroma * chroma * (0.5 + 0.5 * v)
            let k = min(Int(h * Double(hueBins)), hueBins - 1)
            bins[k].weight += w
            bins[k].r += r * w; bins[k].g += g * w; bins[k].b += b * w
            bins[k].count += 1
        }

        let colorful = bins.enumerated()
            .filter { $0.element.count >= 3 }
            .sorted { $0.element.weight > $1.element.weight }

        var picked: [(hue: Double, color: NSColor)] = []
        let strongest = colorful.first?.element.weight ?? 0
        for (_, bin) in colorful {
            guard bin.weight > strongest * 0.08 else { break }
            let r = bin.r / bin.weight, g = bin.g / bin.weight, b = bin.b / bin.weight
            var (h, s, v) = hsv(r, g, b)
            // Distinct hues only (at least ~30° apart).
            if picked.contains(where: { hueDistance($0.hue, h) < 0.085 }) { continue }
            // Neon: strongly saturated and at full brightness.
            s = min(1, max(s * 1.3, 0.82))
            v = 1
            picked.append((h, NSColor(hue: h, saturation: s, brightness: v, alpha: 1)))
            if picked.count == 4 { break }
        }

        if picked.isEmpty || vivid / max(total, 1) < 0.02 {
            let tint = picked.first?.hue ?? 0.62
            // Monochrome cover: cool neon in the cover's faint hue (blue-violet if there is none).
            return [
                NSColor(hue: tint, saturation: 0.55, brightness: 1, alpha: 1),
                NSColor(hue: fmod(tint + 0.06, 1), saturation: 0.7, brightness: 1, alpha: 1),
                NSColor(hue: fmod(tint + 0.95, 1), saturation: 0.45, brightness: 1, alpha: 1),
            ]
        }
        if picked.count == 1 {
            // A single-hue cover: build a gentle analogous gradient around it.
            let h = picked[0].hue
            let base = picked[0].color
            return [
                base,
                NSColor(hue: fmod(h + 0.06, 1), saturation: 0.75, brightness: 1, alpha: 1),
                NSColor(hue: fmod(h + 0.97, 1), saturation: 0.9, brightness: 0.95, alpha: 1),
            ]
        }
        return picked.map(\.color)
    }

    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let delta = mx - mn
        var h = 0.0
        if delta > 0 {
            if mx == r { h = (g - b) / delta }
            else if mx == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : delta / mx, mx)
    }
}
