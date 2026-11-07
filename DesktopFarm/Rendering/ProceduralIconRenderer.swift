import AppKit

/// Renders an `IconSpec` into a crisp 512 pt icon image.
enum ProceduralIconRenderer {
    static let canvas = CGSize(width: 512, height: 512)

    static func image(for spec: IconSpec) -> NSImage {
        NSImage(size: canvas, flipped: false) { bounds in
            draw(spec, in: bounds)
            return true
        }
    }

    /// Renders straight into a bitmap context; safe to call off the main thread.
    static func cgImage(for spec: IconSpec, pixels: Int = 512) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scale = CGFloat(pixels) / canvas.width
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(spec, in: CGRect(origin: .zero, size: canvas))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func draw(_ spec: IconSpec, in bounds: CGRect) {
        let card = bounds.insetBy(dx: 28, dy: 28)
        let c = IconPainter.color
        switch spec.body {
        case let .plant(emoji, moisture, growth, ripe, thirsty, tree, fruit):
            IconPainter.card(card, top: c(tree ? 0xBFE6A8 : 0xCDEFB8, 1), bottom: c(0x8BC56E, 1))
            let soil = CGRect(x: card.minX + 26, y: card.minY + 92, width: card.width - 52, height: 70)
            c(0x7A5236, 1).setFill()
            NSBezierPath(roundedRect: soil, xRadius: 35, yRadius: 35).fill()
            IconPainter.emoji(emoji, in: CGRect(x: card.minX, y: card.minY + 120, width: card.width, height: card.height - 130), size: tree ? 250 : 220)
            if let fruit {
                for (dx, dy) in [(-80.0, 70.0), (70.0, 90.0), (0.0, 140.0)] {
                    IconPainter.emoji(fruit, in: CGRect(x: card.midX + dx - 40, y: card.midY + dy - 40, width: 80, height: 80), size: 64)
                }
            }
            IconPainter.bar(CGRect(x: card.minX + 30, y: card.minY + 50, width: card.width - 60, height: 30), fraction: Double(moisture) / 20, fill: c(0x3A9BFF, 1))
            IconPainter.bar(CGRect(x: card.minX + 30, y: card.minY + 14, width: card.width - 60, height: 30), fraction: Double(growth) / 20, fill: c(0x45C445, 1))
            if ripe {
                IconPainter.badge("收获", center: CGPoint(x: card.maxX - 70, y: card.maxY - 40), color: c(0xF59E0B, 1))
            } else if thirsty {
                IconPainter.emoji("💧", in: CGRect(x: card.maxX - 110, y: card.maxY - 100, width: 90, height: 90), size: 74)
            }

        case let .seed(emoji, tree):
            IconPainter.card(card, top: c(0xF6E7C8, 1), bottom: c(0xD9B98A, 1))
            let packet = CGRect(x: card.minX + 70, y: card.minY + 60, width: card.width - 140, height: card.height - 120)
            c(0xFFF8EC, 1).setFill()
            NSBezierPath(roundedRect: packet, xRadius: 24, yRadius: 24).fill()
            IconPainter.emoji(emoji, in: packet.insetBy(dx: 0, dy: 40), size: 170)
            IconPainter.emoji(tree ? "🌱" : "🌰", in: CGRect(x: card.minX + 20, y: card.minY + 20, width: 110, height: 110), size: 84)
            IconPainter.text(tree ? "树苗" : "种子", in: CGRect(x: packet.minX, y: packet.minY + 10, width: packet.width, height: 60), size: 44, color: c(0x8A5A2B, 1))

        case let .item(emoji, quality, processed):
            IconPainter.card(card, top: c(processed ? 0xE9DDFF : 0xFFF5DA, 1), bottom: c(processed ? 0xB9A2F0 : 0xF3D58D, 1))
            IconPainter.emoji(emoji, in: card.insetBy(dx: 20, dy: 20), size: 280)
            if quality >= 2 {
                let fill = quality >= 3 ? c(0xFFC21A, 1) : c(0xB8C4D6, 1)
                IconPainter.star(center: CGPoint(x: card.maxX - 64, y: card.maxY - 64), radius: 54, fill: fill)
                if quality >= 3 {
                    IconPainter.star(center: CGPoint(x: card.maxX - 140, y: card.maxY - 50), radius: 34, fill: fill)
                }
            }

        case .clone:
            IconPainter.card(card, top: c(0xC9C9C9, 1), bottom: c(0x7D7D7D, 1))
            IconPainter.emoji("🥀", in: card.insetBy(dx: 30, dy: 30), size: 260, alpha: 0.85)
            IconPainter.cracks(in: card)
            IconPainter.badge("克隆", center: CGPoint(x: card.midX, y: card.minY + 48), color: c(0x6B6B6B, 1))

        case let .pet(emoji, hungry, ready):
            IconPainter.card(card, top: c(0xFFE3EC, 1), bottom: c(0xF4A9C0, 1))
            IconPainter.emoji(emoji, in: card.insetBy(dx: 20, dy: 20), size: 270)
            if hungry {
                IconPainter.emoji("🍽️", in: CGRect(x: card.maxX - 120, y: card.maxY - 120, width: 100, height: 100), size: 80)
            } else if ready {
                IconPainter.emoji("✨", in: CGRect(x: card.maxX - 120, y: card.maxY - 120, width: 100, height: 100), size: 80)
            } else {
                IconPainter.emoji("💖", in: CGRect(x: card.maxX - 110, y: card.maxY - 110, width: 90, height: 90), size: 64)
            }

        case let .tool(emoji):
            IconPainter.card(card, top: c(0xD7F0FF, 1), bottom: c(0x7FC3F2, 1))
            IconPainter.emoji(emoji, in: card.insetBy(dx: 20, dy: 20), size: 270)

        case let .crate(fill, emojis, count):
            drawCrate(card: card, fill: fill, emojis: emojis, count: count)

        case let .machine(emoji, status, progress, phase, ready):
            IconPainter.card(card, top: c(0xD9DEE6, 1), bottom: c(0x8D99AE, 1))
            let center = CGPoint(x: card.midX, y: card.midY + 10)
            IconPainter.gear(center: CGPoint(x: card.minX + 110, y: card.minY + 110), radius: 64, angle: CGFloat(phase) * 22.5, color: c(0xF2B134, 1))
            IconPainter.gear(center: CGPoint(x: card.maxX - 100, y: card.maxY - 100), radius: 46, teeth: 8, angle: -CGFloat(phase) * 30, color: c(0xC9CED6, 1))
            switch status {
            case .working:
                IconPainter.ring(center: center, radius: 140, width: 30, fraction: Double(progress) / 100, color: c(0x4ADE80, 1))
                IconPainter.emoji(emoji, in: CGRect(x: center.x - 110, y: center.y - 110, width: 220, height: 220), size: 170)
                IconPainter.badge("\(progress)%", center: CGPoint(x: card.midX, y: card.minY + 46), color: c(0x2563EB, 1))
            case .ready:
                IconPainter.ring(center: center, radius: 140, width: 30, fraction: 1, color: c(0xFACC15, 1))
                IconPainter.emoji(emoji, in: CGRect(x: center.x - 110, y: center.y - 110, width: 220, height: 220), size: 170)
                IconPainter.emoji("✨", in: CGRect(x: card.maxX - 150, y: card.midY - 20, width: 110, height: 110), size: 90)
                IconPainter.badge("待收取 \(ready)", center: CGPoint(x: card.midX, y: card.minY + 46), color: c(0xF59E0B, 1))
            case .idle:
                IconPainter.emoji(emoji, in: CGRect(x: center.x - 120, y: center.y - 120, width: 240, height: 240), size: 190)
                IconPainter.badge("空闲", center: CGPoint(x: card.midX, y: card.minY + 46), color: c(0x64748B, 1))
            }

        case let .shippingBin(value, count):
            IconPainter.card(card, top: c(0xFFE7A3, 1), bottom: c(0xE0A526, 1))
            IconPainter.emoji(count > 0 ? "💰" : "🗳️", in: card.insetBy(dx: 30, dy: 50), size: 250)
            if count > 0 {
                IconPainter.badge("\(value)💰", center: CGPoint(x: card.midX, y: card.minY + 50), color: c(0x16A34A, 1), height: 64)
            }

        case let .orderBox(count):
            IconPainter.card(card, top: c(0xFDF4E3, 1), bottom: c(0xD6B98C, 1))
            IconPainter.emoji("📋", in: card.insetBy(dx: 30, dy: 30), size: 250)
            if count > 0 {
                IconPainter.badge("\(count)", center: CGPoint(x: card.maxX - 60, y: card.maxY - 50), color: c(0xDC2626, 1))
            }

        case let .trough(count, emoji):
            IconPainter.card(card, top: c(0xE8D5B5, 1), bottom: c(0xA9845A, 1))
            IconPainter.emoji("🥣", in: card.insetBy(dx: 30, dy: 50), size: 240)
            if let emoji, count > 0 {
                IconPainter.emoji(emoji, in: CGRect(x: card.midX - 60, y: card.midY + 40, width: 120, height: 120), size: 96)
            }
            IconPainter.badge(count > 0 ? "×\(count)" : "空", center: CGPoint(x: card.midX, y: card.minY + 46), color: count > 0 ? c(0x16A34A, 1) : c(0x9CA3AF, 1))
        }
    }

    private static func drawCrate(card: CGRect, fill: Int, emojis: [String], count: Int) {
        let c = IconPainter.color
        let box = CGRect(x: card.minX + 20, y: card.minY + 30, width: card.width - 40, height: card.height * 0.55)
        // Fruits peeking over the rim, more rows as the crate fills up.
        let rows = fill >= 3 ? 2 : (fill >= 2 ? 1 : (fill >= 1 ? 1 : 0))
        for row in 0..<rows {
            let y = box.maxY - 60 + CGFloat(row) * 70
            let perRow = fill >= 1 && row == 0 && fill == 1 ? 2 : 4
            for column in 0..<perRow {
                let emoji = emojis.isEmpty ? "🍎" : emojis[(column + row) % emojis.count]
                let spacing = box.width / CGFloat(perRow + 1)
                let x = box.minX + spacing * CGFloat(column + 1)
                IconPainter.emoji(emoji, in: CGRect(x: x - 60, y: y - 30, width: 120, height: 120), size: 100)
            }
        }
        // Wooden planks.
        let plankColors: [UInt32] = [0xC48A4E, 0xB27A40, 0xC48A4E]
        let plankHeight = box.height / 3
        for index in 0..<3 {
            let plank = CGRect(x: box.minX, y: box.minY + CGFloat(index) * plankHeight, width: box.width, height: plankHeight - 4)
            let path = NSBezierPath(roundedRect: plank, xRadius: 12, yRadius: 12)
            c(plankColors[index], 1).setFill()
            path.fill()
            c(0x7C4A1E, 1).setStroke()
            path.lineWidth = 4
            path.stroke()
        }
        for x in [box.minX + 30, box.maxX - 30] {
            let post = CGRect(x: x - 16, y: box.minY - 6, width: 32, height: box.height + 12)
            c(0x8B5A2B, 1).setFill()
            NSBezierPath(roundedRect: post, xRadius: 8, yRadius: 8).fill()
        }
        if fill == 0 {
            IconPainter.text("空筐", in: CGRect(x: box.minX, y: box.maxY + 40, width: box.width, height: 120), size: 70, color: c(0x7C4A1E, 1))
        }
        if count > 0 {
            IconPainter.badge("\(count)", center: CGPoint(x: card.maxX - 50, y: card.maxY - 40), color: c(0xDC2626, 1))
        }
    }
}
