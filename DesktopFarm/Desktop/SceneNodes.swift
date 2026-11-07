import AppKit
import SpriteKit

/// Snapshot of the farm handed to scenes once per world change (~1 Hz).
struct SceneModel {
    var stations: [Station] = []
    var plants: [UUID: PlantState] = [:]
    var machines: [UUID: MachineView] = [:]
    var troughs: [UUID: (count: Int, emoji: String?)] = [:]
    var food: [(id: UUID, item: ItemType, point: CGPoint)] = []
    var pets: [UUID: PetState] = [:]
    var showGarden = true
    var spriteHelper = false
}

/// Something the pointer can interact with on the desktop layer.
enum HitTarget: Equatable {
    case pet(UUID)
    case waterBubble(UUID)
    case harvestBubble(UUID)
    case plot(UUID)
    case machine(UUID)
    case trough(UUID)
}

/// Visual node for a plant station.
@MainActor
final class PlotNode: SKNode {
    let plantSprite = SKSpriteNode()
    let soil = SKSpriteNode(texture: TextureCache.shared.soil, size: CGSize(width: 78, height: 26))
    let moistureTrack = SKSpriteNode(color: NSColor.black.withAlphaComponent(0.45), size: CGSize(width: 62, height: 6))
    let moistureFill = SKSpriteNode(color: NSColor(srgbRed: 0.23, green: 0.6, blue: 1, alpha: 1), size: CGSize(width: 60, height: 4))
    let growthTrack = SKSpriteNode(color: NSColor.black.withAlphaComponent(0.45), size: CGSize(width: 62, height: 6))
    let growthFill = SKSpriteNode(color: NSColor(srgbRed: 0.27, green: 0.77, blue: 0.27, alpha: 1), size: CGSize(width: 60, height: 4))
    let bubble = SKSpriteNode()
    let fruitLayer = SKNode()
    private var currentEmoji = ""
    private var currentBubble = ""

    override init() {
        super.init()
        addChild(soil)
        plantSprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        plantSprite.position = CGPoint(x: 0, y: -2)
        addChild(plantSprite)
        plantSprite.addChild(fruitLayer)
        for (track, fill, y) in [(moistureTrack, moistureFill, -20.0), (growthTrack, growthFill, -28.0)] {
            track.position = CGPoint(x: 0, y: y)
            addChild(track)
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            fill.position = CGPoint(x: -30, y: 0)
            track.addChild(fill)
        }
        bubble.size = CGSize(width: 34, height: 38)
        bubble.position = CGPoint(x: 26, y: 92)
        bubble.zPosition = 10
        bubble.run(.repeatForever(.sequence([.moveBy(x: 0, y: 4, duration: 0.6), .moveBy(x: 0, y: -4, duration: 0.6)])))
        addChild(bubble)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ plant: PlantState) {
        let stage = plant.stage
        let emoji = plant.species.emoji(for: stage)
        let size: CGFloat
        switch stage {
        case .seed: size = 26
        case .sprout: size = 34
        case .growing: size = 44
        case .ripe: size = 50
        case .sapling: size = 54
        case .grown, .fruiting: size = 78
        }
        if emoji != currentEmoji || plantSprite.size.width != size {
            currentEmoji = emoji
            plantSprite.texture = TextureCache.shared.emoji(emoji, size: 64)
            plantSprite.size = CGSize(width: size, height: size)
        }
        let showFruit = stage == .fruiting
        if showFruit && fruitLayer.children.isEmpty {
            let texture = TextureCache.shared.emoji(plant.species.produce.emoji, size: 32)
            for (dx, dy) in [(-18.0, 44.0), (16.0, 52.0), (2.0, 64.0)] {
                let fruit = SKSpriteNode(texture: texture, size: CGSize(width: 16, height: 16))
                fruit.position = CGPoint(x: dx, y: dy)
                fruit.zPosition = 2
                fruitLayer.addChild(fruit)
            }
        } else if !showFruit && !fruitLayer.children.isEmpty {
            fruitLayer.removeAllChildren()
        }
        moistureFill.size.width = max(0.5, 60 * plant.moistureFraction)
        growthFill.size.width = max(0.5, 60 * plant.displayProgress)
        let bubbleEmoji = plant.isRipeCrop ? "🧺" : (plant.isThirsty ? "💧" : "")
        if bubbleEmoji != currentBubble {
            currentBubble = bubbleEmoji
            bubble.isHidden = bubbleEmoji.isEmpty
            if !bubbleEmoji.isEmpty { bubble.texture = TextureCache.shared.bubble(bubbleEmoji) }
        }
        bubble.name = plant.isRipeCrop ? "harvest" : (plant.isThirsty ? "water" : nil)
    }
}

/// Visual node for a processing machine station.
@MainActor
final class MachineNode: SKNode {
    let body = SKSpriteNode()
    let gear = SKSpriteNode(texture: TextureCache.shared.emoji("⚙️", size: 32), size: CGSize(width: 22, height: 22))
    let ring = SKShapeNode()
    let readyBubble = SKSpriteNode(texture: TextureCache.shared.bubble("✨"), size: CGSize(width: 34, height: 38))
    private var steam: SKEmitterNode?
    private var lastProgress = -1

    init(type: MachineType) {
        super.init()
        let base = SKSpriteNode(texture: TextureCache.shared.emoji("🏭", size: 64), size: CGSize(width: 58, height: 58))
        base.position = CGPoint(x: 0, y: 30)
        base.alpha = 0.92
        addChild(base)
        body.texture = TextureCache.shared.emoji(type.emoji, size: 48)
        body.size = CGSize(width: 30, height: 30)
        body.position = CGPoint(x: 18, y: 62)
        addChild(body)
        gear.position = CGPoint(x: -22, y: 60)
        addChild(gear)
        ring.position = CGPoint(x: 0, y: 34)
        ring.lineWidth = 4
        ring.strokeColor = NSColor(srgbRed: 0.29, green: 0.87, blue: 0.5, alpha: 1)
        ring.lineCap = .round
        addChild(ring)
        readyBubble.position = CGPoint(x: 26, y: 96)
        readyBubble.run(.repeatForever(.sequence([.scale(to: 1.12, duration: 0.5), .scale(to: 1, duration: 0.5)])))
        addChild(readyBubble)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ view: MachineView) {
        let working = view.status == .working
        if working && gear.action(forKey: "spin") == nil {
            gear.run(.repeatForever(.rotate(byAngle: -.pi, duration: 0.8)), withKey: "spin")
        } else if !working {
            gear.removeAction(forKey: "spin")
        }
        if working && steam == nil {
            let emitter = EffectFactory.steam()
            emitter.position = CGPoint(x: -10, y: 64)
            addChild(emitter)
            steam = emitter
        } else if !working, let steam {
            steam.particleBirthRate = 0
            steam.run(.sequence([.wait(forDuration: 1.6), .removeFromParent()]))
            self.steam = nil
        }
        let progress = Int(((view.job?.progress ?? 0) * 100).rounded())
        if progress != lastProgress {
            lastProgress = progress
            if working {
                let path = CGMutablePath()
                path.addArc(center: .zero, radius: 34, startAngle: .pi / 2, endAngle: .pi / 2 - CGFloat(progress) / 100 * 2 * .pi, clockwise: true)
                ring.path = path
            } else {
                ring.path = nil
            }
        }
        readyBubble.isHidden = view.status != .ready
    }
}

/// Visual node for a desktop animal.
@MainActor
final class PetNode: SKNode {
    let sprite = SKSpriteNode()
    let shadow = SKShapeNode(ellipseOf: CGSize(width: 34, height: 9))
    let bubble = SKSpriteNode()
    let nameLabel = SKLabelNode()
    private var currentBubble = ""
    private var lastZzz = Date.distantPast

    init(species: AnimalSpecies, name: String) {
        super.init()
        shadow.fillColor = NSColor.black.withAlphaComponent(0.22)
        shadow.strokeColor = .clear
        addChild(shadow)
        let size = CGFloat(species.spriteSize)
        sprite.texture = TextureCache.shared.emoji(species.emoji, size: 64)
        sprite.size = CGSize(width: size, height: size)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0.05)
        addChild(sprite)
        bubble.size = CGSize(width: 32, height: 36)
        bubble.position = CGPoint(x: size * 0.45, y: size + 8)
        bubble.zPosition = 5
        addChild(bubble)
        nameLabel.text = name
        nameLabel.fontName = NSFont.systemFont(ofSize: 10, weight: .bold).fontName
        nameLabel.fontSize = 10
        nameLabel.fontColor = .white
        nameLabel.position = CGPoint(x: 0, y: -14)
        nameLabel.alpha = 0.85
        addChild(nameLabel)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(actor: PetActor, pet: PetState, localPosition: CGPoint, scene: SKNode) {
        position = localPosition
        zPosition = 100 + (2000 - localPosition.y) / 100
        sprite.xScale = actor.facingLeft ? 1 : -1
        let moving = actor.behavior == .wander || actor.behavior == .seekFood || actor.behavior == .hungry
        sprite.position.y = moving ? CGFloat(abs(sin(actor.walkPhase))) * 4 : 0
        switch actor.behavior {
        case .eating:
            sprite.zRotation = CGFloat(sin(Date().timeIntervalSince1970 * 14)) * 0.18
        case .sleeping:
            sprite.zRotation = 0.12
            if Date().timeIntervalSince(lastZzz) > 0.9 {
                lastZzz = Date()
                EffectFactory.zzz(at: CGPoint(x: position.x + 12, y: position.y + sprite.size.height), in: scene)
            }
        case .producing:
            sprite.zRotation = 0
            sprite.yScale = 1 + CGFloat(sin(Date().timeIntervalSince1970 * 18)) * 0.08
        case .held:
            sprite.zRotation = CGFloat(sin(Date().timeIntervalSince1970 * 8)) * 0.12
        default:
            sprite.zRotation = 0
            sprite.yScale = 1
        }
        let bubbleEmoji: String
        switch actor.behavior {
        case .hungry, .seekFood: bubbleEmoji = pet.species.favoriteFood.emoji
        case .sleeping: bubbleEmoji = "💤"
        case .producing: bubbleEmoji = pet.species.product.emoji
        case .eating: bubbleEmoji = "😋"
        default: bubbleEmoji = ""
        }
        if bubbleEmoji != currentBubble {
            currentBubble = bubbleEmoji
            bubble.isHidden = bubbleEmoji.isEmpty
            if !bubbleEmoji.isEmpty { bubble.texture = TextureCache.shared.bubble(bubbleEmoji) }
        }
        nameLabel.text = pet.name
    }
}
