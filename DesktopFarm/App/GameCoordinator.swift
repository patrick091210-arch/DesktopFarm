import AppKit
import Combine
import SwiftUI

/// Composition root: wires engine, AI director, overlay, Finder bridge, icons and sound.
@MainActor
final class GameCoordinator: ObservableObject {
    static let shared = GameCoordinator()

    let settings = AppSettings()
    let sound = SoundManager()
    let layout = WorldLayout()
    let icons = IconUpdateScheduler()

    @Published private(set) var engine: GameEngine?
    @Published private(set) var startupError: String?
    @Published private(set) var bridgeStatus = "未启用"
    @Published private(set) var alertMessage: String?

    private(set) var director: PetDirector?
    private(set) var overlay: DesktopOverlayController?
    private(set) var bridge: DesktopIconBridge?
    private(set) var hud: FinderHUDController?
    private var cancellables = Set<AnyCancellable>()
    private var wateringCooldown: [UUID: Date] = [:]
    private var canRestPosition: CGPoint?
    private var pendingOpenURLs: [URL] = []

    private init() {}

    // MARK: - Lifecycle

    func bootstrap() {
        guard engine == nil else { return }
        do {
            let engine = try GameEngine()
            engine.speed = settings.speed
            let director = PetDirector(engine: engine, layout: layout)
            let overlay = DesktopOverlayController(engine: engine, director: director, layout: layout, sound: sound)
            let hud = FinderHUDController(engine: engine)
            let bridge = DesktopIconBridge(root: engine.root)

            engine.petPositionProvider = { [weak director] in director?.positions() ?? [:] }
            engine.onWorldChanged = { [weak self] in self?.worldChanged() }
            engine.events
                .receive(on: RunLoop.main)
                .sink { [weak self] event in self?.handle(event) }
                .store(in: &cancellables)
            bridge.onUpdate = { [weak self] snapshot in self?.bridgeUpdated(snapshot) }

            self.engine = engine
            self.director = director
            self.overlay = overlay
            self.hud = hud
            self.bridge = bridge

            observeSettings()
            engine.start()
            director.start()
            if settings.overlayEnabled { overlay.show() }
            overlay.showGarden = settings.gardenVisible
            if settings.finderBridgeEnabled { bridge.start() }
            worldChanged()
            let pending = pendingOpenURLs
            pendingOpenURLs.removeAll()
            if !pending.isEmpty { handleOpen(pending) }
        } catch {
            startupError = "无法启动农场：\(error.localizedDescription)"
        }
    }

    func shutdown() {
        director?.stop()
        overlay?.hide()
        bridge?.stop()
        hud?.hide()
        engine?.stop()
    }

    private func observeSettings() {
        settings.$soundEnabled.sink { [weak self] in self?.sound.isEnabled = $0 }.store(in: &cancellables)
        settings.$volume.sink { [weak self] in self?.sound.volume = Float($0) }.store(in: &cancellables)
        settings.$speed.sink { [weak self] in self?.engine?.speed = $0 }.store(in: &cancellables)
        settings.$overlayEnabled.dropFirst().sink { [weak self] enabled in
            if enabled { self?.overlay?.show() } else { self?.overlay?.hide() }
        }.store(in: &cancellables)
        settings.$gardenVisible.dropFirst().sink { [weak self] in self?.overlay?.showGarden = $0 }.store(in: &cancellables)
        settings.$finderBridgeEnabled.dropFirst().sink { [weak self] enabled in
            if enabled { self?.bridge?.start() } else { self?.bridge?.stop(); self?.hud?.hide() }
            self?.bridgeStatus = self?.bridge?.status ?? ""
        }.store(in: &cancellables)
    }

    // MARK: - World updates

    private var worldUpdateScheduled = false

    /// Coalesces the many `onWorldChanged` calls of one run-loop turn (tick, reconcile,
    /// rescans, actions) into a single icon / overlay / HUD refresh.
    private func worldChanged() {
        guard !worldUpdateScheduled else { return }
        worldUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flushWorldUpdate() }
        }
    }

    private func flushWorldUpdate() {
        worldUpdateScheduled = false
        guard let engine else { return }
        icons.apply(engine.iconSpecs())
        overlay?.refreshModel()
        hud?.refresh()
    }

    private func handle(_ event: FarmEvent) {
        sound.play(for: event)
        overlay?.handle(event)
        switch event {
        case .watered(let id), .ripened(let id), .planted(let id):
            hud?.playEffect(forFileID: id, event: event)
        case .harvested(let id, _, _), .fruitDropped(let id, _, _):
            hud?.playEffect(forFileID: id, event: event)
        case .machineStarted(let id), .machineFinished(let id, _):
            hud?.playEffect(forFileID: id, event: event)
        default:
            break
        }
    }

    // MARK: - Finder bridge

    private func bridgeUpdated(_ snapshot: FinderSnapshot?) {
        bridgeStatus = bridge?.status ?? ""
        hud?.update(snapshot: snapshot)
        if let snapshot { checkWateringCan(snapshot) }
    }

    /// Moving `💧水壶.tool` next to a plant icon in Finder waters it, then the can returns.
    private func checkWateringCan(_ snapshot: FinderSnapshot) {
        guard let engine,
              let can = engine.scan.files.first(where: { $0.directory.isEmpty && $0.payload.subject == .tool(.wateringCan) }),
              let canPoint = snapshot.icons[can.name] else { return }
        let reach = max(60, snapshot.iconSize * 1.1)
        let now = Date()
        var wateredAny = false
        for (plant, file) in engine.plantedFiles where file.directory.isEmpty {
            guard let plantPoint = snapshot.icons[file.name], hypot(plantPoint.x - canPoint.x, plantPoint.y - canPoint.y) < reach else { continue }
            if let last = wateringCooldown[plant.id], now.timeIntervalSince(last) < 4 { continue }
            wateringCooldown[plant.id] = now
            engine.useWateringCan(on: plant.id)
            wateredAny = true
        }
        if wateredAny {
            if let rest = canRestPosition { bridge?.setRawPosition(of: can.name, to: rest) }
        } else {
            canRestPosition = snapshot.rawPositions[can.name]
        }
    }

    // MARK: - Commands

    func handleOpen(_ urls: [URL]) {
        guard let engine else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        let messages = urls.map { engine.handleOpen($0) }
        if let last = messages.last { engine.toast = Toast(icon: "📄", text: last) }
    }

    func openFarmFolder() {
        guard let engine else { return }
        if settings.finderBridgeEnabled, let bridge {
            bridge.openFarmWindow()
        } else {
            NSWorkspace.shared.open(engine.root)
        }
    }

    func revealSaveFolder() {
        guard let engine else { return }
        NSWorkspace.shared.activateFileViewerSelecting([engine.saveManager.saveURL])
    }

    func refreshIcons() {
        icons.invalidateAll()
        worldChanged()
    }
}
