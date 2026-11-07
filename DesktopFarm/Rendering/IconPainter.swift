import AppKit

/// Low-level CoreGraphics / AppKit drawing helpers for procedural icons.
enum IconPainter {
    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Rounded card with vertical gradient, inner highlight and soft border.
    static func card(_ rect: CGRect, top: NSColor, bottom: NSColor, radius: CGFloat = 46) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        bottom.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
        let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: radius - 6, yRadius: radius - 6)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        highlight.lineWidth = 3
        highlight.stroke()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    /// Draws an emoji centred in `rect`.
    static func emoji(_ text: String, in rect: CGRect, size: CGFloat, alpha: CGFloat = 1) {
        let font = NSFont(name: "Apple Color Emoji", size: size) ?? NSFont.systemFont(ofSize: size)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let bounds = attributed.size()
        let origin = CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2)
        if alpha < 1 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            attributed.draw(at: origin)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            attributed.draw(at: origin)
        }
    }

    static func text(_ string: String, in rect: CGRect, size: CGFloat, color: NSColor = .white, weight: NSFont.Weight = .heavy) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        let attributed = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .shadow: shadow
        ])
        let height = attributed.size().height
        attributed.draw(in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
    }

    /// Horizontal capsule progress bar.
    static func bar(_ rect: CGRect, fraction: Double, fill: NSColor, track: NSColor = NSColor.black.withAlphaComponent(0.32)) {
        let radius = rect.height / 2
        track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let clamped = CGFloat(min(max(fraction, 0), 1))
        guard clamped > 0 else { return }
        let inner = rect.insetBy(dx: 3, dy: 3)
        let width = max(inner.height, inner.width * clamped)
        let filled = CGRect(x: inner.minX, y: inner.minY, width: width, height: inner.height)
        NSGradient(starting: fill.highlight(withLevel: 0.35) ?? fill, ending: fill)?
            .draw(in: NSBezierPath(roundedRect: filled, xRadius: inner.height / 2, yRadius: inner.height / 2), angle: -90)
    }

    /// Circular progress ring.
    static func ring(center: CGPoint, radius: CGFloat, width: CGFloat, fraction: Double, color: NSColor) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        NSColor.black.withAlphaComponent(0.3).setStroke()
        track.stroke()
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - CGFloat(clamped) * 360, clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    /// Simple toothed gear rotated by `angle` degrees.
    static func gear(center: CGPoint, radius: CGFloat, teeth: Int = 10, angle: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        let inner = radius * 0.78
        let steps = teeth * 4
        for index in 0..<steps {
            let theta = (CGFloat(index) / CGFloat(steps)) * 2 * .pi + angle * .pi / 180
            let r = (index % 4 == 0 || index % 4 == 1) ? radius : inner
            let point = CGPoint(x: center.x + cos(theta) * r, y: center.y + sin(theta) * r)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        color.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 2
        path.stroke()
        let hole = NSBezierPath(ovalIn: CGRect(x: center.x - radius * 0.3, y: center.y - radius * 0.3, width: radius * 0.6, height: radius * 0.6))
        IconPainter.color(0x3B4252).setFill()
        hole.fill()
    }

    /// Pill badge with text, e.g. a counter or value.
    static func badge(_ string: String, center: CGPoint, color: NSColor, height: CGFloat = 54) {
        let font = NSFont.systemFont(ofSize: height * 0.56, weight: .black)
        let width = max(height, (string as NSString).size(withAttributes: [.font: font]).width + height * 0.6)
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        color.setFill()
        path.fill()
        NSColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
        text(string, in: rect, size: height * 0.56)
    }

    /// Five-point star for quality badges.
    static func star(center: CGPoint, radius: CGFloat, fill: NSColor) {
        let path = NSBezierPath()
        for index in 0..<10 {
            let r = index % 2 == 0 ? radius : radius * 0.45
            let theta = CGFloat(index) * .pi / 5 + .pi / 2
            let point = CGPoint(x: center.x + cos(theta) * r, y: center.y + sin(theta) * r)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        fill.setFill()
        path.fill()
        NSColor.white.setStroke()
        path.lineWidth = 4
        path.stroke()
    }

    /// Jagged crack lines for withered clones.
    static func cracks(in rect: CGRect) {
        let lines: [[CGPoint]] = [
            [CGPoint(x: 0.5, y: 0.95), CGPoint(x: 0.44, y: 0.74), CGPoint(x: 0.56, y: 0.6), CGPoint(x: 0.42, y: 0.4), CGPoint(x: 0.52, y: 0.18)],
            [CGPoint(x: 0.56, y: 0.6), CGPoint(x: 0.74, y: 0.52), CGPoint(x: 0.86, y: 0.58)],
            [CGPoint(x: 0.42, y: 0.4), CGPoint(x: 0.26, y: 0.34), CGPoint(x: 0.14, y: 0.42)]
        ]
        for line in lines {
            let path = NSBezierPath()
            for (index, point) in line.enumerated() {
                let p = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
                if index == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.lineWidth = 9
            path.lineJoinStyle = .miter
            NSColor.white.withAlphaComponent(0.7).setStroke()
            path.stroke()
            path.lineWidth = 5
            color(0x2E2E2E).setStroke()
            path.stroke()
        }
    }
}
