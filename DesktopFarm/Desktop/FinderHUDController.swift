import AppKit
import SpriteKit

/// What the Finder HUD should draw above one real icon.
struct HUDBadge: Equatable {
    enum Kind: Equatable {
        case plant(moisture: Double, growth: Double, bubble: String?)
        case machine(progress: Double?, ready: Bool)
        case pet(bubble: String?)
    }

    var id: UUID
    var name: String
    var kind: Kind
}

/// Scene drawn in a transparent panel glued above the farm's Finder window.
@MainActor
final class FinderHUDScene: SKScene {
    private var nodes: [String: SKNode] = [:]
    let effectLayer = SKNode()
    var windowOrigin: CGPoint = .zero
    private(set) var bubbleFrames: [(UUID, String, CGRect)] = []
    var onBubbleClick: ((UUID, String) -> Void)?

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
        effectLayer.zPosition = 100
        addChild(effectLayer)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func local(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - windowOrigin.x, y: global.y - windowOrigin.y)
    }

    func apply(badges: [HUDBadge], snapshot: FinderSnapshot) {
        let alive = Set(badges.map(\.name))
        for (name, node) in nodes where !alive.contains(name) {
            node.removeFromParent()
            nodes[name] = nil
        }
        bubbleFrames.removeAll()
        let half = snapshot.iconSize / 2
        for badge in badges {
            // Skip icons projected outside the icon area (scrolled window, under the toolbar).
            guard let center = snapshot.icons[badge.name],
                  snapshot.contentFrame.contains(CGPoint(x: center.x, y: center.y + half)) else {
                nodes[badge.name]?.removeFromParent()
                nodes[badge.name] = nil
                continue
            }
            let node = nodes[badge.name] ?? {
                let created = SKNode()
                addChild(created)
                nodes[badge.name] = created
                return created
            }()
            node.removeAllChildren()
            let anchor = local(CGPoint(x: center.x, y: center.y + half + 6))
            node.position = anchor
            switch badge.kind {
            case let .plant(moisture, growth, bubble):
                addBar(to: node, y: 8, fraction: moisture, color: NSColor(srgbRed: 0.23, green: 0.6, blue: 1, alpha: 1))
                addBar(to: node, y: 1, fraction: growth, color: NSColor(srgbRed: 0.27, green: 0.77, blue: 0.27, alpha: 1))
                if let bubble { addBubble(bubble, to: node, badge: badge) }
            case let .machine(progress, ready):
                if let progress {
                    let ring = SKShapeNode()
                    let path = CGMutablePath()
                    path.addArc(center: .zero, radius: 10, startAngle: .pi / 2, endAngle: .pi / 2 - CGFloat(progress) * 2 * .pi, clockwise: true)
                    ring.path = path
                    ring.lineWidth = 4
                    ring.strokeColor = NSColor(srgbRed: 0.29, green: 0.87, blue: 0.5, alpha: 1)
                    ring.position = CGPoint(x: 0, y: 12)
                    node.addChild(ring)
                    let label = SKLabelNode(text: "\(Int(progress * 100))%")
                    label.fontName = NSFont.systemFont(ofSize: 10, weight: .heavy).fontName
                    label.fontSize = 10
                    label.fontColor = .white
                    label.position = CGPoint(x: 26, y: 8)
                    node.addChild(label)
                } else if ready {
                    let sparkle = SKSpriteNode(texture: TextureCache.shared.bubble("✨"), size: CGSize(width: 26, height: 29))
                    sparkle.position = CGPoint(x: 0, y: 14)
                    node.addChild(sparkle)
                }
            case let .pet(bubble):
                if let bubble { addBubble(bubble, to: node, badge: badge) }
            }
        }
    }

    private func addBar(to node: SKNode, y: CGFloat, fraction: Double, color: NSColor) {
        let track = SKSpriteNode(color: NSColor.black.withAlphaComponent(0.5), size: CGSize(width: 46, height: 5))
        track.position = CGPoint(x: 0, y: y)
        node.addChild(track)
        let fill = SKSpriteNode(color: color, size: CGSize(width: max(0.5, 44 * CGFloat(min(max(fraction, 0), 1))), height: 3))
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.position = CGPoint(x: -22, y: 0)
        track.addChild(fill)
    }

    private func addBubble(_ emoji: String, to node: SKNode, badge: HUDBadge) {
        let sprite = SKSpriteNode(texture: TextureCache.shared.bubble(emoji), size: CGSize(width: 28, height: 31))
        sprite.position = CGPoint(x: 30, y: 16)
        node.addChild(sprite)
        let frame = CGRect(x: node.position.x + 16, y: node.position.y, width: 28, height: 32)
        bubbleFrames.append((badge.id, emoji, frame))
    }

    func bubble(atLocal point: CGPoint) -> (UUID, String)? {
        bubbleFrames.first { $0.2.contains(point) }.map { ($0.0, $0.1) }
    }

    override func mouseDown(with event: NSEvent) {
        if let hit = bubble(atLocal: event.location(in: self)) {
            onBubbleClick?(hit.0, hit.1)
        }
    }
}

/// Keeps a transparent panel ordered directly above the farm's Finder window.
@MainActor
final class FinderHUDController {
    private let engine: GameEngine
    private var panel: DesktopOverlayWindow?
    private var scene: FinderHUDScene?
    private var pollTimer: Timer?
    private(set) var snapshot: FinderSnapshot?

    init(engine: GameEngine) {
        self.engine = engine
    }

    func update(snapshot: FinderSnapshot?) {
        self.snapshot = snapshot
        guard let snapshot, let screen = NSScreen.screens.first(where: { $0.frame.intersects(snapshot.windowFrame) }) ?? NSScreen.screens.first else {
            hide()
            return
        }
        if panel == nil { build(screen: screen) }
        guard let panel, let scene else { return }
        panel.level = .normal
        panel.setFrame(snapshot.windowFrame, display: true)
        scene.size = snapshot.windowFrame.size
        scene.windowOrigin = snapshot.windowFrame.origin
        if let number = snapshot.windowNumber {
            panel.order(.above, relativeTo: number)
        } else {
            panel.orderFrontRegardless()
        }
        refresh()
    }

    func hide() {
        pollTimer?.invalidate()
        pollTimer = nil
        panel?.orderOut(nil)
        panel = nil
        scene = nil
    }

    private func build(screen: NSScreen) {
        let panel = DesktopOverlayWindow(screen: screen)
        let view = OverlaySKView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.preferredFramesPerSecond = 20
        let scene = FinderHUDScene(size: screen.frame.size)
        scene.onBubbleClick = { [weak self] id, emoji in
            guard let self else { return }
            if emoji == "🧺" { self.engine.harvest(id) } else if emoji == "💧" { self.engine.water(id) }
        }
        view.presentScene(scene)
        panel.contentView = view
        self.panel = panel
        self.scene = scene
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePassthrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func updatePassthrough() {
        guard let panel, let scene else { return }
        let mouse = NSEvent.mouseLocation
        let local = scene.local(mouse)
        let ignore = scene.bubble(atLocal: local) == nil
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    /// Rebuilds per-icon badges from the current engine state.
    func refresh() {
        guard let snapshot, let scene else { return }
        var badges: [HUDBadge] = []
        let plants = Dictionary(engine.game.plants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pets = Dictionary(engine.game.pets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for file in engine.scan.files where file.directory.isEmpty {
            if let plant = plants[file.payload.id] {
                let bubble = plant.isRipeCrop ? "🧺" : (plant.isThirsty ? "💧" : nil)
                badges.append(HUDBadge(id: plant.id, name: file.name, kind: .plant(moisture: plant.moistureFraction, growth: plant.displayProgress, bubble: bubble)))
            } else if let pet = pets[file.payload.id] {
                let bubble = pet.isHungry ? pet.species.favoriteFood.emoji : (pet.readyToProduce ? "✨" : nil)
                badges.append(HUDBadge(id: pet.id, name: file.name, kind: .pet(bubble: bubble)))
            }
        }
        for machine in engine.machineViews {
            badges.append(HUDBadge(id: machine.id, name: machine.url.lastPathComponent, kind: .machine(progress: machine.job?.progress, ready: machine.status == .ready)))
        }
        scene.apply(badges: badges, snapshot: snapshot)
    }

    /// Plays an effect above a real Finder icon, if that file is visible in the window.
    func playEffect(forFileID id: UUID, event: FarmEvent) {
        guard let snapshot, let scene else { return }
        let name: String?
        if let file = engine.scan.file(id: id) {
            name = file.name
        } else {
            name = engine.machineViews.first { $0.id == id }?.url.lastPathComponent
        }
        guard let name, let center = snapshot.icons[name], snapshot.contentFrame.contains(center) else { return }
        let point = scene.local(center)
        switch event {
        case .watered: EffectFactory.rain(at: point, in: scene.effectLayer)
        case .harvested(_, let item, let count), .fruitDropped(_, let item, let count):
            EffectFactory.fruitArc(item.emoji, count: count, from: point, in: scene.effectLayer)
            EffectFactory.sparkle(at: point, in: scene.effectLayer)
        case .machineStarted: EffectFactory.burst("⚙️", at: point, in: scene.effectLayer, count: 4, spread: 30)
        case .machineFinished: EffectFactory.sparkle(at: point, in: scene.effectLayer); EffectFactory.burst("✨", at: point, in: scene.effectLayer)
        case .ripened: EffectFactory.sparkle(at: point, in: scene.effectLayer, color: .systemGreen)
        default: break
        }
    }
}
