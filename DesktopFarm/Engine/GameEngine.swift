import Combine
import Foundation

/// Gameplay events consumed by the overlay (effects) and sound manager.
enum FarmEvent: Sendable, Equatable {
    case watered(plantID: UUID)
    case ripened(plantID: UUID)
    case harvested(plantID: UUID, item: ItemType, count: Int)
    case fruitDropped(plantID: UUID, item: ItemType, count: Int)
    case planted(plantID: UUID)
    case petAdded(petID: UUID)
    case petRemoved(petID: UUID)
    case petAte(petID: UUID, food: ItemType)
    case petProduced(petID: UUID, item: ItemType)
    case machineStarted(machineID: UUID)
    case machineFinished(machineID: UUID, item: ItemType)
    case shipped(coins: Int)
    case orderCompleted(coins: Int)
    case purchased(name: String)
    case cloneDetected(name: String)
    case levelUp(level: Int)
    case tidied(count: Int)
    case failure(message: String)
}

struct Toast: Identifiable, Equatable, Sendable {
    var id = UUID()
    var icon: String
    var text: String
}

/// The orchestrator: owns the save, the latest disk scan and the 1 s simulation tick.
@MainActor
final class GameEngine: ObservableObject {
    let fs: FarmFileSystem
    let saveManager: SaveManager
    let scanner: FarmScanner
    let watcher = DirectoryWatcher()

    @Published var game: SaveGame
    @Published private(set) var scan: FarmScan = .empty
    @Published private(set) var crates: [CrateSummary] = []
    @Published var speed: Double = 1
    @Published var toast: Toast?

    let events = PassthroughSubject<FarmEvent, Never>()

    /// Live pet positions from the AI director, written into the save on persist.
    var petPositionProvider: (() -> [UUID: (UnitPoint2D, Int)])?
    /// Called after every tick / reconcile so icons and overlays can refresh.
    var onWorldChanged: (() -> Void)?

    var rng = SystemRandomNumberGenerator()
    private var tickTimer: Timer?
    var dirty = false
    private var lastSaveAt = Date()
    var lastSpriteRunAt = Date.distantPast
    var produceRequestedAt: [UUID: Date] = [:]
    private(set) var isRunning = false

    var root: URL { fs.root }

    init(root: URL = FarmSandbox.defaultRoot(), saveManager: SaveManager = SaveManager()) throws {
        try saveManager.ensureDirectory()
        let signer = try ItemSigner.loadOrCreate(at: saveManager.keyURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = FarmFileSystem(sandbox: FarmSandbox(root: root), signer: signer)
        self.fs = fs
        self.saveManager = saveManager
        self.scanner = FarmScanner(fileSystem: fs)
        self.game = saveManager.load() ?? SaveGame.fresh(at: Date())
    }

    /// Test / tooling initialiser with an explicit signer.
    init(root: URL, saveManager: SaveManager, signer: ItemSigner) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fs = FarmFileSystem(sandbox: FarmSandbox(root: root), signer: signer)
        self.fs = fs
        self.saveManager = saveManager
        self.scanner = FarmScanner(fileSystem: fs)
        self.game = saveManager.load() ?? SaveGame.fresh(at: Date())
    }

    // MARK: - Lifecycle

    func start(now: Date = Date(), startTimers: Bool = true) {
        guard !isRunning else { return }
        isRunning = true
        bootstrapLayout(now: now)
        reconcile(now: now)
        let gap = now.timeIntervalSince(game.lastTickAt)
        if gap > 5 {
            settleOffline(from: game.lastTickAt, to: now)
        }
        game.lastTickAt = now
        dailyRolloverIfNeeded(now: now)
        maintainOrders(now: now)
        if startTimers {
            _ = watcher.start(root: root) { [weak self] in
                self?.reconcile()
            }
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
        save()
        onWorldChanged?()
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        watcher.stop()
        save()
        isRunning = false
    }

    func save() {
        if let positions = petPositionProvider?() {
            for index in game.pets.indices {
                if let live = positions[game.pets[index].id] {
                    game.pets[index].position = live.0
                    game.pets[index].screenIndex = live.1
                }
            }
        }
        do {
            game.lastSavedAt = Date()
            try saveManager.save(game)
            dirty = false
            lastSaveAt = Date()
        } catch {
            report("存档失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Tick

    func tick(now: Date = Date()) {
        let gap = now.timeIntervalSince(game.lastTickAt)
        if gap > 30 {
            // Woke from sleep or the app was suspended: settle like an offline period.
            settleOffline(from: game.lastTickAt, to: now)
        } else if gap > 0 {
            advanceWorld(dt: gap * speed, now: now, offline: false)
        }
        game.lastTickAt = now
        dailyRolloverIfNeeded(now: now)
        maintainOrders(now: now)
        runHarvestSpriteIfNeeded(now: now)
        dirty = true
        if now.timeIntervalSince(lastSaveAt) > 10 { save() }
        onWorldChanged?()
    }

    /// Advances every simulated object. In offline mode pets also self-feed from troughs
    /// and produce immediately, because no AI director is running.
    @discardableResult
    func advanceWorld(dt: Double, now: Date, offline: Bool) -> OfflineReport {
        var report = OfflineReport()
        guard dt > 0 else { return report }
        var touchedFiles = false

        let sprinklerDirs = Set(scan.files.filter {
            $0.payload.kind == .tool && $0.payload.itemType == ToolType.sprinkler.rawValue && $0.role == .field
        }.map(\.directory))
        var looseCounts: [String: Int] = [:]
        for file in scan.files where file.role == .field && file.payload.kind == .item {
            looseCounts[file.directory, default: 0] += 1
        }

        for index in game.plants.indices {
            let plantID = game.plants[index].id
            guard let file = scan.file(id: plantID) else { continue }
            let blocked = looseCounts[file.directory, default: 0] >= GameEngine.looseItemCap
            let result = BotanyEngine.advance(&game.plants[index], dt: dt, sprinklered: sprinklerDirs.contains(file.directory), fruitBlocked: blocked)
            if result.becameRipe {
                events.send(.ripened(plantID: plantID))
                if !offline { log("🧺", "\(game.plants[index].species.displayName)成熟了，可以收获！") }
            }
            if result.becameGrownTree && !offline {
                log("🌳", "\(game.plants[index].species.displayName)长成大树了！")
            }
            for _ in 0..<result.fruitDrops {
                let created = dropFruit(plantIndex: index, file: file)
                report.add(game.plants[index].species.produce, created)
                looseCounts[file.directory, default: 0] += created
                touchedFiles = touchedFiles || created > 0
            }
        }

        for index in game.pets.indices {
            let becameReady = HusbandryEngine.advance(&game.pets[index], dt: dt, now: now)
            let petID = game.pets[index].id
            if becameReady { produceRequestedAt[petID] = now }
            if offline {
                if game.pets[index].isHungry, let food = troughFood(for: game.pets[index].species) {
                    if feedPet(petID, with: food, silent: true) { touchedFiles = true; rescan() }
                }
                if game.pets[index].readyToProduce, hasRoomForProduce, let made = petProduce(petID, silent: true) {
                    report.add(made, 1)
                    touchedFiles = true
                }
            } else if game.pets[index].readyToProduce, hasRoomForProduce,
                      let requested = produceRequestedAt[petID],
                      now.timeIntervalSince(requested) > 20 {
                // Safety net if the desktop director never got to play the animation.
                if petProduce(petID) != nil { touchedFiles = true }
            }
        }

        for index in game.machines.indices {
            let finishedNow = ProcessingMachineEngine.advance(&game.machines[index], dt: dt)
            // `isFinished` without `finishedNow` = an earlier completion attempt failed: retry.
            if finishedNow || game.machines[index].job?.isFinished == true {
                if let output = finishJob(machineIndex: index, silent: offline) {
                    report.add(output, 1)
                    touchedFiles = true
                }
            }
        }

        if touchedFiles {
            rescan()
            if processMachines(now: now) { rescan() }
        }
        return report
    }

    // MARK: - Reconcile

    /// Producers (trees, animals) pause once this many loose items lie in their folder,
    /// so long offline periods can never flood the desktop with files.
    static let looseItemCap = 24

    /// Animal products land in the farm root; true while it has room for more.
    var hasRoomForProduce: Bool {
        scan.files.filter { $0.role == .field && $0.directory.isEmpty && $0.payload.kind == .item }.count < GameEngine.looseItemCap
    }

    /// Creation-time window in which every genuine game file must already be in the ledger:
    /// from the start of this save to shortly before the last successful save. A signed but
    /// unregistered file stamped inside it was registered once and then spent or forgotten.
    var registeredWindow: ClosedRange<TimeInterval>? {
        guard let saved = game.lastSavedAt else { return nil }
        let lower = game.createdAt.timeIntervalSince1970
        let upper = saved.timeIntervalSince1970 - 5
        return lower <= upper ? lower...upper : nil
    }

    /// Full disk reconcile: identity / anti-cheat, adoption, removals, folder markers, machines.
    func reconcile(now: Date = Date()) {
        var current = scanner.scan(now: now)
        var mutated = false

        for folder in current.folders where folder.wantsCrateMarker {
            if (try? fs.writeMarker(FolderMarker(role: .crate), in: folder.url)) != nil {
                log("📦", "识别到新的自定义木筐「\(folder.name)」")
                mutated = true
            }
        }
        if mutated { current = scanner.scan(now: now); mutated = false }

        let resolution = AntiCheat.resolve(
            files: current.files,
            ledger: game.ledger,
            spent: Set(game.spentIDs),
            registeredWindow: registeredWindow
        )

        for clone in resolution.clones {
            witherClone(clone)
            mutated = true
        }
        let adoptedIDs = Set(resolution.adopted.map(\.payload.id))
        for file in resolution.genuine {
            if adoptedIDs.contains(file.payload.id) {
                register(payload: file.payload, url: file.url, inode: file.inode)
            } else if let index = game.ledgerIndex(file.payload.id) {
                game.ledger[index].inode = file.inode
                game.ledger[index].relativePath = file.relativePath
                game.ledger[index].missingSince = nil
            }
            ensureStateExists(for: file, now: now)
        }
        handleMissing(resolution.missingIDs, now: now)
        syncMachineStates(scan: current)

        if mutated { current = scanner.scan(now: now) }
        scan = current
        recoverMachines(now: now)
        if processMachines(now: now) { rescan() }
        crates = SmartCrateMonitor.summaries(scan: scan)
        dirty = true
        onWorldChanged?()
    }

    /// Quick rescan after our own file operations (identity already known).
    ///
    /// Only follows *moves* of the genuine file (same inode, new path). It never adopts a
    /// new inode: a Finder copy that appears before the debounced `reconcile()` must not
    /// be able to steal the ledger identity and turn the original into a clone.
    func rescan() {
        scan = scanner.scan()
        for file in scan.files {
            if let index = game.ledgerIndex(file.payload.id), game.ledger[index].inode == file.inode {
                game.ledger[index].relativePath = file.relativePath
                game.ledger[index].missingSince = nil
            }
        }
        crates = SmartCrateMonitor.summaries(scan: scan)
    }

    private func ensureStateExists(for file: ScannedFile, now: Date) {
        switch file.payload.subject {
        case .plant(let species):
            if game.plantIndex(file.payload.id) == nil {
                game.plants.append(PlantState(id: file.payload.id, species: species, plantedAt: now))
            }
        case .pet(let species):
            if game.petIndex(file.payload.id) == nil {
                let pet = PetState(id: file.payload.id, species: species, name: AnimalSpecies.names.randomElement(using: &rng) ?? "小可爱", position: randomPetPosition(), bornAt: now)
                game.pets.append(pet)
                events.send(.petAdded(petID: pet.id))
            }
        default:
            break
        }
    }

    private func handleMissing(_ ids: [UUID], now: Date) {
        for id in ids {
            guard let index = game.ledgerIndex(id) else { continue }
            let entry = game.ledger[index]
            // The ledger entry is kept (marked missing) for every kind, so a file that is
            // taken out of the farm and brought back is recognised instead of being treated
            // as an unregistered — and therefore resurrected — copy.
            if entry.missingSince == nil {
                game.ledger[index].missingSince = now
                switch entry.kind {
                case .crop, .tree:
                    if let plantIndex = game.plantIndex(id) {
                        log("🍂", "\(game.plants[plantIndex].species.displayName)的文件被移走了，它离开了农场")
                        game.plants.remove(at: plantIndex)
                    }
                case .pet:
                    if let petIndex = game.petIndex(id) {
                        log("👋", "\(game.pets[petIndex].name)的锚点文件不见了，它回森林去了")
                        game.pets.remove(at: petIndex)
                        events.send(.petRemoved(petID: id))
                    }
                default:
                    break
                }
            } else if let since = entry.missingSince, now.timeIntervalSince(since) > GameEngine.missingRetention {
                game.ledger.remove(at: index)
            }
        }
    }

    /// How long a missing file's ledger entry is remembered.
    static let missingRetention: TimeInterval = 30 * 24 * 3600

    private func syncMachineStates(scan: FarmScan) {
        let folders = scan.folders(role: .machine)
        for folder in folders {
            guard let marker = folder.marker, let type = marker.machineType else { continue }
            if game.machineIndex(marker.id) == nil {
                game.machines.append(MachineState(id: marker.id, type: type))
            }
        }
        let alive = Set(folders.compactMap { $0.marker?.id })
        let removed = game.machines.filter { !alive.contains($0.id) }
        for machine in removed {
            log("🔧", "\(machine.type.displayName)文件夹被移除了")
        }
        game.machines.removeAll { !alive.contains($0.id) }
    }

    // MARK: - Logging / feedback

    func log(_ icon: String, _ message: String, date: Date = Date()) {
        game.activity.insert(ActivityEntry(date: date, icon: icon, message: message), at: 0)
        if game.activity.count > 60 { game.activity.removeLast(game.activity.count - 60) }
    }

    func notify(_ icon: String, _ text: String) {
        toast = Toast(icon: icon, text: text)
        log(icon, text)
    }

    func report(_ message: String) {
        toast = Toast(icon: "⚠️", text: message)
        events.send(.failure(message: message))
    }

    func randomPetPosition() -> UnitPoint2D {
        UnitPoint2D(x: Double.random(in: 0.35...0.8, using: &rng), y: Double.random(in: 0.06...0.3, using: &rng))
    }
}

/// Aggregated production during an offline period.
struct OfflineReport: Sendable, Equatable {
    var produced: [ItemType: Int] = [:]

    mutating func add(_ item: ItemType, _ count: Int) {
        guard count > 0 else { return }
        produced[item, default: 0] += count
    }

    mutating func merge(_ other: OfflineReport) {
        for (item, count) in other.produced { produced[item, default: 0] += count }
    }

    var isEmpty: Bool { produced.isEmpty }

    var summary: String {
        produced.sorted { $0.value > $1.value }.map { "\($0.key.emoji)\($0.key.displayName)×\($0.value)" }.joined(separator: "  ")
    }
}
