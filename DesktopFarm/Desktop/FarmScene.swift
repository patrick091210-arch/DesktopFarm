import AppKit
import SpriteKit

/// Delegate receiving pointer interactions from a desktop scene.
@MainActor
protocol FarmSceneDelegate: AnyObject {
    func scene(_ scene: FarmScene, didActivate target: HitTarget, rightClick: Bool)
    func scene(_ scene: FarmScene, beganHolding petID: UUID)
    func scene(_ scene: FarmScene, movedHeld petID: UUID, toGlobal point: CGPoint)
    func scene(_ scene: FarmScene, endedHolding petID: UUID, moved: Bool)
}

/// The transparent SpriteKit layer drawn on one screen at desktop-icon level + 1.
@MainActor
final class FarmScene: SKScene {
    weak var interactionDelegate: FarmSceneDelegate?
    var director: PetDirector?
    /// Global origin of the screen this scene covers.
    var screenOrigin: CGPoint = .zero
    var isGardenScreen = false

    private(set) var model = SceneModel()
    private var plotNodes: [UUID: PlotNode] = [:]
    private var machineNodes: [UUID: MachineNode] = [:]
    private var troughNodes: [UUID: SKNode] = [:]
    private var foodNodes: [UUID: SKSpriteNode] = [:]
    private var petNodes: [UUID: PetNode] = [:]
    private let gardenLayer = SKNode()
    private let petLayer = SKNode()
    let effectLayer = SKNode()
    private var spriteHelper: SKSpriteNode?
    private var heldPet: UUID?
    private var holdMoved = false
    private var mouseDownTarget: HitTarget?

    override init(size: CGSize) {
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        anchorPoint = .zero
        addChild(gardenLayer)
        petLayer.zPosition = 100
        addChild(petLayer)
        effectLayer.zPosition = 500
        addChild(effectLayer)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    func local(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - screenOrigin.x, y: global.y - screenOrigin.y)
    }

    func global(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + screenOrigin.x, y: local.y + screenOrigin.y)
    }

    // MARK: - Model sync

    func apply(_ model: SceneModel) {
        self.model = model
        gardenLayer.isHidden = !(model.showGarden && isGardenScreen)
        guard isGardenScreen else { return }
        syncPlots()
        syncMachines()
        syncTroughs()
        syncFood()
        syncSpriteHelper()
    }

    private func syncPlots() {
        let plantStations = model.stations.filter { $0.kind == .plant }
        let ids = Set(plantStations.map(\.id))
        for (id, node) in plotNodes where !ids.contains(id) {
            node.run(.sequence([.group([.fadeOut(withDuration: 0.3), .scale(to: 0.3, duration: 0.3)]), .removeFromParent()]))
            plotNodes[id] = nil
        }
        for station in plantStations {
            guard let plant = model.plants[station.id] else { continue }
            let node: PlotNode
            if let existing = plotNodes[station.id] {
                node = existing
            } else {
                node = PlotNode()
                node.setScale(0.2)
                node.run(.scale(to: 1, duration: 0.35))
                gardenLayer.addChild(node)
                plotNodes[station.id] = node
            }
            node.name = "plot:\(station.id.uuidString)"
            node.position = local(station.center)
            node.apply(plant)
        }
    }

    private func syncMachines() {
        let stations = model.stations.filter { $0.kind == .machine }
        let ids = Set(stations.map(\.id))
        for (id, node) in machineNodes where !ids.contains(id) {
            node.removeFromParent()
            machineNodes[id] = nil
        }
        for station in stations {
            guard let view = model.machines[station.id] else { continue }
            let node = machineNodes[station.id] ?? {
                let created = MachineNode(type: view.type)
                gardenLayer.addChild(created)
                machineNodes[station.id] = created
                return created
            }()
            node.name = "machine:\(station.id.uuidString)"
            node.position = local(station.center)
            node.apply(view)
        }
    }

    private func syncTroughs() {
        let stations = model.stations.filter { $0.kind == .trough }
        let ids = Set(stations.map(\.id))
        for (id, node) in troughNodes where !ids.contains(id) {
            node.removeFromParent()
            troughNodes[id] = nil
        }
        for station in stations {
            let info = model.troughs[station.id] ?? (0, nil)
            let node = troughNodes[station.id] ?? {
                let created = SKNode()
                let bowl = SKSpriteNode(texture: TextureCache.shared.emoji("🥣", size: 64), size: CGSize(width: 50, height: 50))
                bowl.position = CGPoint(x: 0, y: 24)
                created.addChild(bowl)
                let food = SKSpriteNode()
                food.name = "food"
                food.size = CGSize(width: 22, height: 22)
                food.position = CGPoint(x: 0, y: 46)
                created.addChild(food)
                let label = SKLabelNode()
                label.name = "count"
                label.fontName = NSFont.systemFont(ofSize: 11, weight: .heavy).fontName
                label.fontSize = 11
                label.fontColor = .white
                label.position = CGPoint(x: 0, y: -10)
                created.addChild(label)
                gardenLayer.addChild(created)
                troughNodes[station.id] = created
                return created
            }()
            node.name = "trough:\(station.id.uuidString)"
            node.position = local(station.center)
            if let food = node.childNode(withName: "food") as? SKSpriteNode {
                food.isHidden = info.count == 0 || info.emoji == nil
                if let emoji = info.emoji { food.texture = TextureCache.shared.emoji(emoji, size: 32) }
            }
            (node.childNode(withName: "count") as? SKLabelNode)?.text = info.count > 0 ? "食槽 ×\(info.count)" : "食槽空了"
        }
    }

    private func syncFood() {
        let ids = Set(model.food.map(\.id))
        for (id, node) in foodNodes where !ids.contains(id) {
            node.run(.sequence([.scale(to: 0, duration: 0.2), .removeFromParent()]))
            foodNodes[id] = nil
        }
        for food in model.food where foodNodes[food.id] == nil {
            let node = SKSpriteNode(texture: TextureCache.shared.emoji(food.item.emoji, size: 40), size: CGSize(width: 24, height: 24))
            node.position = local(food.point)
            node.zPosition = 5
            node.setScale(0)
            node.run(.sequence([.scale(to: 1, duration: 0.25), .repeatForever(.sequence([.moveBy(x: 0, y: 3, duration: 0.8), .moveBy(x: 0, y: -3, duration: 0.8)]))]))
            gardenLayer.addChild(node)
            foodNodes[food.id] = node
        }
    }

    private func syncSpriteHelper() {
        if model.spriteHelper && spriteHelper == nil {
            let helper = SKSpriteNode(texture: TextureCache.shared.emoji("🤖", size: 48), size: CGSize(width: 30, height: 30))
            helper.zPosition = 300
            gardenLayer.addChild(helper)
            spriteHelper = helper
            patrol(helper)
        } else if !model.spriteHelper, let helper = spriteHelper {
            helper.removeFromParent()
            spriteHelper = nil
        }
    }

    private func patrol(_ helper: SKSpriteNode) {
        let points = model.stations.map { local($0.center) }
        let target = (points.randomElement() ?? CGPoint(x: 120, y: 120))
        let destination = CGPoint(x: target.x + .random(in: -30...30), y: target.y + .random(in: 60...110))
        let distance = hypot(destination.x - helper.position.x, destination.y - helper.position.y)
        let move = SKAction.move(to: destination, duration: max(0.6, Double(distance) / 90))
        move.timingMode = .easeInEaseOut
        helper.run(.sequence([move, .wait(forDuration: 1.2)])) { [weak self, weak helper] in
            MainActor.assumeIsolated {
                guard let self, let helper else { return }
                self.patrol(helper)
            }
        }
    }

    // MARK: - Frame update

    override func update(_ currentTime: TimeInterval) {
        guard let director else { return }
        let actors = director.actors
        let frame = CGRect(origin: screenOrigin, size: size)
        for (id, node) in petNodes where actors[id] == nil || !frame.contains(actors[id]?.position ?? .zero) {
            if actors[id] == nil {
                EffectFactory.burst("💨", at: node.position, in: effectLayer, count: 5, spread: 30)
            }
            node.removeFromParent()
            petNodes[id] = nil
        }
        for (id, actor) in actors where frame.contains(actor.position) {
            guard let pet = model.pets[id] else { continue }
            let node = petNodes[id] ?? {
                let created = PetNode(species: pet.species, name: pet.name)
                petLayer.addChild(created)
                petNodes[id] = created
                return created
            }()
            node.name = "pet:\(id.uuidString)"
            node.apply(actor: actor, pet: pet, localPosition: local(actor.position), scene: effectLayer)
        }
    }

    // MARK: - Hit testing

    /// Interactive target under a global point, used for smart click-through.
    func hitTarget(atGlobal point: CGPoint) -> HitTarget? {
        let p = local(point)
        guard p.x >= 0, p.y >= 0, p.x <= size.width, p.y <= size.height else { return nil }
        for (id, node) in petNodes {
            // Fixed-size box from position + sprite size: no node-tree walk per poll.
            let size = node.sprite.size
            let frame = CGRect(x: node.position.x - size.width / 2 - 4, y: node.position.y - 4,
                               width: size.width + 8, height: size.height + 8)
            if frame.contains(p) { return .pet(id) }
        }
        guard isGardenScreen && !gardenLayer.isHidden else { return nil }
        for (id, node) in plotNodes {
            if !node.bubble.isHidden {
                let bubbleFrame = CGRect(
                    x: node.position.x + node.bubble.position.x - 18,
                    y: node.position.y + node.bubble.position.y - 20,
                    width: 36, height: 40
                )
                if bubbleFrame.contains(p) {
                    return node.bubble.name == "harvest" ? .harvestBubble(id) : .waterBubble(id)
                }
            }
            let plotFrame = CGRect(x: node.position.x - 40, y: node.position.y - 32, width: 80, height: 110)
            if plotFrame.contains(p) { return .plot(id) }
        }
        for (id, node) in machineNodes {
            let frame = CGRect(x: node.position.x - 36, y: node.position.y - 6, width: 72, height: 110)
            if frame.contains(p) { return .machine(id) }
        }
        for (id, node) in troughNodes {
            let frame = CGRect(x: node.position.x - 30, y: node.position.y - 14, width: 60, height: 74)
            if frame.contains(p) { return .trough(id) }
        }
        return nil
    }

    func localPosition(ofStation id: UUID) -> CGPoint? {
        if let node = plotNodes[id] { return node.position }
        if let node = machineNodes[id] { return node.position }
        if let node = troughNodes[id] { return node.position }
        return nil
    }

    func localPosition(ofPet id: UUID) -> CGPoint? { petNodes[id]?.position }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let target = hitTarget(atGlobal: global(event.location(in: self)))
        mouseDownTarget = target
        holdMoved = false
        if case .pet(let id) = target {
            heldPet = id
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = heldPet else { return }
        if !holdMoved {
            holdMoved = true
            interactionDelegate?.scene(self, beganHolding: id)
        }
        interactionDelegate?.scene(self, movedHeld: id, toGlobal: global(event.location(in: self)))
    }

    override func mouseUp(with event: NSEvent) {
        if let id = heldPet {
            interactionDelegate?.scene(self, endedHolding: id, moved: holdMoved)
            heldPet = nil
            if holdMoved { return }
        }
        if let target = mouseDownTarget {
            interactionDelegate?.scene(self, didActivate: target, rightClick: false)
        }
        mouseDownTarget = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if let target = hitTarget(atGlobal: global(event.location(in: self))) {
            interactionDelegate?.scene(self, didActivate: target, rightClick: true)
        }
    }
}
