import AppKit
import Combine
import SpriteKit

/// Owns one overlay window per screen, smart mouse click-through, drag & drop and effects.
@MainActor
final class DesktopOverlayController: FarmSceneDelegate {
    private let engine: GameEngine
    private let director: PetDirector
    private let layout: WorldLayout
    private let sound: SoundManager
    private var windows: [(window: DesktopOverlayWindow, view: OverlaySKView, scene: FarmScene)] = []
    private var pollTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private(set) var isVisible = false
    var showGarden = true { didSet { refreshModel() } }

    init(engine: GameEngine, director: PetDirector, layout: WorldLayout, sound: SoundManager) {
        self.engine = engine
        self.director = director
        self.layout = layout
        self.sound = sound
        director.onBehaviorChange = { [weak self] actor, previous in
            self?.behaviorChanged(actor, from: previous)
        }
    }

    // MARK: - Visibility

    func show() {
        guard !isVisible else { return }
        isVisible = true
        buildWindows()
        startPolling()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.buildWindows()
            }
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        pollTimer?.invalidate()
        pollTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for entry in windows { entry.window.orderOut(nil) }
        windows.removeAll()
    }

    private func buildWindows() {
        for entry in windows { entry.window.orderOut(nil) }
        windows.removeAll()
        for (index, screen) in NSScreen.screens.enumerated() {
            let window = DesktopOverlayWindow(screen: screen)
            let view = OverlaySKView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.preferredFramesPerSecond = 30
            view.ignoresSiblingOrder = true
            let scene = FarmScene(size: screen.frame.size)
            scene.screenOrigin = screen.frame.origin
            scene.isGardenScreen = index == 0
            scene.director = director
            scene.interactionDelegate = self
            view.presentScene(scene)
            view.dropValidator = { [weak self] urls, point in self?.dropAction(urls: urls, at: point, perform: false) ?? false }
            view.dropHandler = { [weak self] urls, point in self?.dropAction(urls: urls, at: point, perform: true) ?? false }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append((window, view, scene))
        }
        refreshModel()
    }

    // MARK: - Model

    func refreshModel() {
        guard isVisible else { return }
        let stations = director.currentStations(engine)
        var model = SceneModel()
        model.stations = stations
        model.plants = Dictionary(engine.game.plants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        model.machines = Dictionary(engine.machineViews.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for folder in engine.troughFolders {
            guard let id = folder.marker?.id else { continue }
            let files = engine.scan.files(inFolder: id).filter { $0.payload.kind == .item }
            model.troughs[id] = (files.count, files.first?.payload.itemValue?.emoji)
        }
        let edible = Set(AnimalSpecies.allCases.flatMap { $0.diet.keys })
        model.food = engine.scan.files.compactMap { file in
            guard file.role == .field, file.signatureValid, let item = file.payload.itemValue, edible.contains(item) else { return nil }
            return (file.payload.id, item, layout.groundSpot(for: file.payload.id))
        }
        .prefix(30)
        .map { $0 }
        model.pets = Dictionary(engine.game.pets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        model.showGarden = showGarden
        model.spriteHelper = engine.game.hasUpgrade(.harvestSprite)
        for entry in windows { entry.scene.apply(model) }
    }

    // MARK: - Smart click-through

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMousePassthrough() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private var lastMouse = CGPoint(x: -1, y: -1)
    private var idlePolls = 0

    /// 30 Hz click-through update. Cheap by construction: only the screen under the
    /// pointer is hit-tested, and while the pointer is still the test drops to ~10 Hz
    /// (animals can still walk under a resting pointer, so it never stops entirely).
    private func updateMousePassthrough() {
        let mouse = NSEvent.mouseLocation
        if mouse == lastMouse {
            idlePolls += 1
            if idlePolls % 3 != 0 { return }
        } else {
            lastMouse = mouse
            idlePolls = 0
        }
        for entry in windows {
            let interactive = entry.window.frame.contains(mouse) && entry.scene.hitTarget(atGlobal: mouse) != nil
            let ignore = !interactive
            if entry.window.ignoresMouseEvents != ignore {
                entry.window.ignoresMouseEvents = ignore
            }
        }
    }

    // MARK: - Drag & drop from Finder

    private func scene(containing point: CGPoint) -> FarmScene? {
        windows.first { $0.window.frame.contains(point) }?.scene
    }

    private func dropAction(urls: [URL], at point: CGPoint, perform: Bool) -> Bool {
        guard let scene = scene(containing: point), let target = scene.hitTarget(atGlobal: point) else { return false }
        let files = urls.compactMap { url -> ScannedFile? in
            guard let relative = engine.fs.sandbox.relativePath(for: url) else { return nil }
            return engine.scan.files.first { $0.relativePath == relative }
        }
        guard !files.isEmpty else { return false }
        var handled = false
        for file in files {
            switch (target, file.payload.subject) {
            case (.plot(let id), .tool(.wateringCan)), (.waterBubble(let id), .tool(.wateringCan)), (.harvestBubble(let id), .tool(.wateringCan)):
                if perform { engine.useWateringCan(on: id) }
                handled = true
            case (.pet(let id), .item(let item)):
                guard let pet = engine.pet(id), pet.species.diet[item] != nil else { continue }
                if perform { _ = engine.feedPet(id, with: file); engine.rescan() }
                handled = true
            case (.plot, .seed), (.waterBubble, .seed), (.harvestBubble, .seed):
                if perform { _ = engine.plant(seedFileID: file.payload.id) }
                handled = true
            case (.machine(let id), .item), (.trough(let id), .item):
                guard let folder = engine.scan.folder(id: id) else { continue }
                if perform { _ = try? engine.fs.move(file.url, into: folder.url) }
                handled = true
            default:
                continue
            }
        }
        if perform && handled { engine.reconcile() }
        return handled
    }

    // MARK: - FarmSceneDelegate

    func scene(_ scene: FarmScene, didActivate target: HitTarget, rightClick: Bool) {
        switch target {
        case .pet(let id):
            guard let pet = engine.pet(id) else { return }
            if rightClick {
                if engine.feedPetFromStock(id) { sound.play(.eat) }
            } else {
                engine.pat(id)
                sound.playVoice(pet.species)
                if let local = scene.localPosition(ofPet: id) {
                    EffectFactory.burst("❤️", at: CGPoint(x: local.x, y: local.y + 40), in: scene.effectLayer, count: 5, spread: 40)
                }
            }
        case .waterBubble(let id), .plot(let id):
            guard let plant = engine.plant(id) else { return }
            if plant.isRipeCrop && !rightClick {
                engine.harvest(id)
            } else {
                engine.water(id)
            }
        case .harvestBubble(let id):
            engine.harvest(id)
        case .machine(let id), .trough(let id):
            if let folder = engine.scan.folder(id: id) {
                NSWorkspace.shared.open(folder.url)
                sound.play(.click)
            }
        }
        refreshModel()
    }

    func scene(_ scene: FarmScene, beganHolding petID: UUID) {
        director.beginHold(petID)
        if let pet = engine.pet(petID) { sound.playVoice(pet.species) }
    }

    func scene(_ scene: FarmScene, movedHeld petID: UUID, toGlobal point: CGPoint) {
        director.moveHeld(petID, to: point)
    }

    func scene(_ scene: FarmScene, endedHolding petID: UUID, moved: Bool) {
        director.endHold(petID)
    }

    // MARK: - Effects

    private func behaviorChanged(_ actor: PetActor, from previous: PetBehavior) {
        guard isVisible else { return }
        if actor.behavior == .producing || actor.behavior == .hungry {
            sound.playVoice(actor.species)
        }
    }

    private func stationEffectPoint(_ id: UUID) -> (FarmScene, CGPoint)? {
        guard let scene = windows.first(where: { $0.scene.isGardenScreen })?.scene,
              let local = scene.localPosition(ofStation: id) else { return nil }
        return (scene, local)
    }

    private func petEffectPoint(_ id: UUID) -> (FarmScene, CGPoint)? {
        guard let actor = director.actors[id], let scene = scene(containing: actor.position) else { return nil }
        return (scene, scene.local(actor.position))
    }

    private var hudPoint: (FarmScene, CGPoint)? {
        guard let scene = windows.first(where: { $0.scene.isGardenScreen })?.scene else { return nil }
        let visible = layout.gardenFrame
        return (scene, scene.local(CGPoint(x: visible.maxX - 160, y: visible.maxY - 50)))
    }

    func handle(_ event: FarmEvent) {
        guard isVisible else { return }
        refreshModel()
        switch event {
        case .watered(let id):
            if let (scene, point) = stationEffectPoint(id) { EffectFactory.rain(at: CGPoint(x: point.x, y: point.y + 30), in: scene.effectLayer) }
        case .ripened(let id):
            if let (scene, point) = stationEffectPoint(id) { EffectFactory.sparkle(at: CGPoint(x: point.x, y: point.y + 40), in: scene.effectLayer, color: .systemGreen) }
        case .harvested(let id, let item, let count), .fruitDropped(let id, let item, let count):
            if let (scene, point) = stationEffectPoint(id) {
                EffectFactory.fruitArc(item.emoji, count: count, from: CGPoint(x: point.x, y: point.y + 60), in: scene.effectLayer)
                EffectFactory.sparkle(at: CGPoint(x: point.x, y: point.y + 50), in: scene.effectLayer)
                EffectFactory.floatingText("+\(count) \(item.displayName)", at: CGPoint(x: point.x, y: point.y + 100), in: scene.effectLayer)
            }
        case .planted(let id):
            if let (scene, point) = stationEffectPoint(id) { EffectFactory.burst("🌱", at: CGPoint(x: point.x, y: point.y + 20), in: scene.effectLayer, count: 6, spread: 40) }
        case .petAdded(let id):
            if let (scene, point) = petEffectPoint(id) { EffectFactory.sparkle(at: point, in: scene.effectLayer, color: .systemPink) }
        case .petRemoved:
            break
        case .petAte(let id, _):
            if let (scene, point) = petEffectPoint(id) { EffectFactory.burst("💗", at: CGPoint(x: point.x, y: point.y + 40), in: scene.effectLayer, count: 4, spread: 36) }
        case .petProduced(let id, let item):
            if let (scene, point) = petEffectPoint(id) {
                EffectFactory.fruitArc(item.emoji, count: 1, from: CGPoint(x: point.x, y: point.y + 20), in: scene.effectLayer)
                EffectFactory.floatingText("+1 \(item.displayName)", at: CGPoint(x: point.x, y: point.y + 70), in: scene.effectLayer)
            }
        case .machineStarted(let id):
            if let (scene, point) = stationEffectPoint(id) { EffectFactory.burst("⚙️", at: CGPoint(x: point.x, y: point.y + 50), in: scene.effectLayer, count: 4, spread: 30) }
        case .machineFinished(let id, let item):
            if let (scene, point) = stationEffectPoint(id) {
                EffectFactory.sparkle(at: CGPoint(x: point.x, y: point.y + 50), in: scene.effectLayer)
                EffectFactory.burst("✨", at: CGPoint(x: point.x, y: point.y + 60), in: scene.effectLayer)
                EffectFactory.floatingText("\(item.emoji) \(item.displayName) 完成!", at: CGPoint(x: point.x, y: point.y + 110), in: scene.effectLayer)
            }
        case .shipped(let coins), .orderCompleted(let coins):
            if let (scene, point) = hudPoint {
                EffectFactory.burst("🪙", at: point, in: scene.effectLayer, count: 10, spread: 80)
                EffectFactory.floatingText("+\(coins) 💰", at: point, in: scene.effectLayer, color: .systemYellow)
            }
        case .purchased(let name):
            if let (scene, point) = hudPoint { EffectFactory.floatingText("🛒 \(name)", at: point, in: scene.effectLayer) }
        case .cloneDetected:
            if let (scene, point) = hudPoint { EffectFactory.shards(at: point, in: scene.effectLayer) }
        case .levelUp(let level):
            if let (scene, point) = hudPoint {
                EffectFactory.sparkle(at: point, in: scene.effectLayer, color: .systemOrange)
                EffectFactory.floatingText("🎉 Lv.\(level)", at: point, in: scene.effectLayer, color: .systemOrange)
            }
        case .tidied(let count):
            if let (scene, point) = hudPoint { EffectFactory.floatingText("🧹 整理了 \(count) 件", at: point, in: scene.effectLayer) }
        case .failure:
            break
        }
    }
}
