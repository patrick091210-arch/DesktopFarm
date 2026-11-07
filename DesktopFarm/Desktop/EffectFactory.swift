import AppKit
import SpriteKit

/// Caches SpriteKit textures generated from emoji and simple shapes.
@MainActor
final class TextureCache {
    static let shared = TextureCache()

    private var emojiCache: [String: SKTexture] = [:]
    private var bubbleCache: [String: SKTexture] = [:]
    private var dotTexture: SKTexture?
    private var dropTexture: SKTexture?
    private var soilTexture: SKTexture?

    func emoji(_ text: String, size: CGFloat = 64) -> SKTexture {
        let key = "\(text)#\(Int(size))"
        if let cached = emojiCache[key] { return cached }
        let canvas = CGSize(width: size * 1.25, height: size * 1.25)
        let image = NSImage(size: canvas, flipped: false) { rect in
            IconPainter.emoji(text, in: rect, size: size)
            return true
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        emojiCache[key] = texture
        return texture
    }

    /// Emoji inside a white speech bubble (used for clickable hints).
    func bubble(_ text: String) -> SKTexture {
        if let cached = bubbleCache[text] { return cached }
        let canvas = CGSize(width: 56, height: 62)
        let image = NSImage(size: canvas, flipped: false) { _ in
            let body = CGRect(x: 3, y: 12, width: 50, height: 47)
            let path = NSBezierPath(roundedRect: body, xRadius: 23, yRadius: 23)
            let tail = NSBezierPath()
            tail.move(to: CGPoint(x: 22, y: 14))
            tail.line(to: CGPoint(x: 28, y: 2))
            tail.line(to: CGPoint(x: 34, y: 14))
            tail.close()
            NSColor.white.withAlphaComponent(0.96).setFill()
            path.fill()
            tail.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1.5
            path.stroke()
            IconPainter.emoji(text, in: body, size: 28)
            return true
        }
        let texture = SKTexture(image: image)
        bubbleCache[text] = texture
        return texture
    }

    var dot: SKTexture {
        if let dotTexture { return dotTexture }
        let image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            let gradient = NSGradient(colors: [NSColor.white, NSColor.white.withAlphaComponent(0)])
            gradient?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
            return true
        }
        let texture = SKTexture(image: image)
        dotTexture = texture
        return texture
    }

    var drop: SKTexture {
        if let dropTexture { return dropTexture }
        let image = NSImage(size: CGSize(width: 8, height: 16), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 4, y: 16))
            path.curve(to: CGPoint(x: 4, y: 0), controlPoint1: CGPoint(x: 9, y: 6), controlPoint2: CGPoint(x: 8, y: 0))
            path.curve(to: CGPoint(x: 4, y: 16), controlPoint1: CGPoint(x: 0, y: 0), controlPoint2: CGPoint(x: -1, y: 6))
            NSColor(srgbRed: 0.35, green: 0.68, blue: 1, alpha: 1).setFill()
            path.fill()
            return true
        }
        let texture = SKTexture(image: image)
        dropTexture = texture
        return texture
    }

    var soil: SKTexture {
        if let soilTexture { return soilTexture }
        let image = NSImage(size: CGSize(width: 84, height: 30), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSGradient(starting: NSColor(srgbRed: 0.55, green: 0.36, blue: 0.22, alpha: 0.95),
                       ending: NSColor(srgbRed: 0.38, green: 0.24, blue: 0.14, alpha: 0.95))?.draw(in: path, angle: -90)
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.stroke()
            return true
        }
        let texture = SKTexture(image: image)
        soilTexture = texture
        return texture
    }
}

/// Builds one-shot and looping visual effects.
@MainActor
enum EffectFactory {
    /// Upper bound of live effect nodes per layer. When the overlay is occluded (e.g. by a
    /// full-screen app) SpriteKit pauses, cleanup actions stop running, and events would
    /// otherwise keep stacking nodes forever during long idle sessions.
    static let maxLiveNodes = 160

    static func hasCapacity(_ parent: SKNode) -> Bool {
        parent.children.count < maxLiveNodes
    }

    static func rain(at point: CGPoint, in parent: SKNode) {
        guard hasCapacity(parent) else { return }
        let emitter = SKEmitterNode()
        emitter.particleTexture = TextureCache.shared.drop
        emitter.particleBirthRate = 70
        emitter.numParticlesToEmit = 36
        emitter.particleLifetime = 0.6
        emitter.particlePositionRange = CGVector(dx: 54, dy: 6)
        emitter.position = CGPoint(x: point.x, y: point.y + 70)
        emitter.emissionAngle = -.pi / 2
        emitter.particleSpeed = 160
        emitter.particleSpeedRange = 40
        emitter.particleAlphaSpeed = -1.2
        emitter.particleScale = 0.9
        emitter.particleScaleRange = 0.3
        emitter.zPosition = 50
        parent.addChild(emitter)
        emitter.run(.sequence([.wait(forDuration: 1.4), .removeFromParent()]))
    }

    static func burst(_ emoji: String, at point: CGPoint, in parent: SKNode, count: Int = 8, spread: CGFloat = 70) {
        guard hasCapacity(parent) else { return }
        let texture = TextureCache.shared.emoji(emoji, size: 40)
        for index in 0..<count {
            let node = SKSpriteNode(texture: texture, size: CGSize(width: 22, height: 22))
            node.position = point
            node.zPosition = 60
            parent.addChild(node)
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi + .random(in: -0.3...0.3)
            let distance = spread * .random(in: 0.6...1.0)
            let move = SKAction.moveBy(x: cos(angle) * distance, y: sin(angle) * distance + 20, duration: 0.7)
            move.timingMode = .easeOut
            node.run(.sequence([.group([move, .fadeOut(withDuration: 0.8), .scale(to: 0.4, duration: 0.8)]), .removeFromParent()]))
        }
    }

    static func sparkle(at point: CGPoint, in parent: SKNode, color: NSColor = .systemYellow) {
        guard hasCapacity(parent) else { return }
        let emitter = SKEmitterNode()
        emitter.particleTexture = TextureCache.shared.dot
        emitter.particleBirthRate = 200
        emitter.numParticlesToEmit = 40
        emitter.particleLifetime = 0.8
        emitter.particleLifetimeRange = 0.3
        emitter.emissionAngleRange = 2 * .pi
        emitter.particleSpeed = 110
        emitter.particleSpeedRange = 60
        emitter.particleAlphaSpeed = -1.2
        emitter.particleScale = 0.6
        emitter.particleScaleRange = 0.4
        emitter.particleColor = color
        emitter.particleColorBlendFactor = 1
        emitter.particleBlendMode = .add
        emitter.position = point
        emitter.zPosition = 55
        parent.addChild(emitter)
        emitter.run(.sequence([.wait(forDuration: 1.3), .removeFromParent()]))
    }

    /// Fruits fly out in parabolas from `origin`.
    static func fruitArc(_ emoji: String, count: Int, from origin: CGPoint, in parent: SKNode) {
        guard hasCapacity(parent) else { return }
        let texture = TextureCache.shared.emoji(emoji, size: 48)
        for index in 0..<max(1, count) {
            let node = SKSpriteNode(texture: texture, size: CGSize(width: 30, height: 30))
            node.position = origin
            node.zPosition = 70
            parent.addChild(node)
            let direction: CGFloat = index % 2 == 0 ? 1 : -1
            let end = CGPoint(x: origin.x + direction * CGFloat.random(in: 40...110), y: origin.y - CGFloat.random(in: 10...40))
            let control = CGPoint(x: (origin.x + end.x) / 2, y: origin.y + CGFloat.random(in: 90...150))
            let path = CGMutablePath()
            path.move(to: origin)
            path.addQuadCurve(to: end, control: control)
            let follow = SKAction.follow(path, asOffset: false, orientToPath: false, duration: 0.75)
            follow.timingMode = .easeIn
            let spin = SKAction.rotate(byAngle: direction * .pi * 2, duration: 0.75)
            let bounce = SKAction.sequence([.moveBy(x: 0, y: 14, duration: 0.12), .moveBy(x: 0, y: -14, duration: 0.12)])
            node.run(.sequence([
                .wait(forDuration: Double(index) * 0.12),
                .group([follow, spin]),
                bounce,
                .wait(forDuration: 0.6),
                .group([.fadeOut(withDuration: 0.4), .scale(to: 0.3, duration: 0.4)]),
                .removeFromParent()
            ]))
        }
    }

    static func floatingText(_ text: String, at point: CGPoint, in parent: SKNode, color: NSColor = .white) {
        guard hasCapacity(parent) else { return }
        let label = SKLabelNode(text: text)
        label.fontName = NSFont.systemFont(ofSize: 15, weight: .heavy).fontName
        label.fontSize = 15
        label.fontColor = color
        label.position = point
        label.zPosition = 80
        let shadow = SKLabelNode(text: text)
        shadow.fontName = label.fontName
        shadow.fontSize = 15
        shadow.fontColor = NSColor.black.withAlphaComponent(0.55)
        shadow.position = CGPoint(x: 1, y: -1.5)
        shadow.zPosition = -1
        label.addChild(shadow)
        parent.addChild(label)
        let rise = SKAction.moveBy(x: 0, y: 46, duration: 1.4)
        rise.timingMode = .easeOut
        label.run(.sequence([.group([rise, .sequence([.wait(forDuration: 0.9), .fadeOut(withDuration: 0.5)])]), .removeFromParent()]))
    }

    /// Looping steam puffs, attached to a working machine.
    static func steam() -> SKEmitterNode {
        let emitter = SKEmitterNode()
        emitter.particleTexture = TextureCache.shared.dot
        emitter.particleBirthRate = 9
        emitter.particleLifetime = 1.6
        emitter.particlePositionRange = CGVector(dx: 16, dy: 0)
        emitter.emissionAngle = .pi / 2
        emitter.emissionAngleRange = 0.5
        emitter.particleSpeed = 34
        emitter.particleSpeedRange = 10
        emitter.particleAlpha = 0.7
        emitter.particleAlphaSpeed = -0.45
        emitter.particleScale = 1.2
        emitter.particleScaleSpeed = 1.1
        emitter.particleColor = .white
        emitter.particleColorBlendFactor = 1
        emitter.zPosition = 20
        return emitter
    }

    static func zzz(at point: CGPoint, in parent: SKNode) {
        guard hasCapacity(parent) else { return }
        let label = SKLabelNode(text: "z")
        label.fontName = NSFont.systemFont(ofSize: 14, weight: .black).fontName
        label.fontSize = CGFloat.random(in: 11...16)
        label.fontColor = NSColor(srgbRed: 0.55, green: 0.6, blue: 1, alpha: 1)
        label.position = point
        label.zPosition = 40
        parent.addChild(label)
        label.run(.sequence([
            .group([.moveBy(x: 18, y: 30, duration: 1.6), .sequence([.wait(forDuration: 1), .fadeOut(withDuration: 0.6)])]),
            .removeFromParent()
        ]))
    }

    static func shards(at point: CGPoint, in parent: SKNode) {
        burst("🥀", at: point, in: parent, count: 6, spread: 50)
        sparkle(at: point, in: parent, color: .systemGray)
    }
}
