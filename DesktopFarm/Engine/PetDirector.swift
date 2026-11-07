import AppKit
import Foundation

/// AI behaviour states of a desktop animal.
enum PetBehavior: String, Sendable {
    case idle, wander, hungry, seekFood, eating, sleeping, producing, held

    var label: String {
        switch self {
        case .idle: return "发呆"
        case .wander: return "散步"
        case .hungry: return "饿了"
        case .seekFood: return "觅食中"
        case .eating: return "进食"
        case .sleeping: return "打盹"
        case .producing: return "产出中"
        case .held: return "被抱起"
        }
    }
}

/// Transient, per-frame state of one animal on the desktop.
struct PetActor: Sendable {
    var id: UUID
    var species: AnimalSpecies
    var position: CGPoint
    var target: CGPoint?
    var behavior: PetBehavior
    var stateUntil: Date
    var facingLeft: Bool
    var foodID: UUID?
    var screenIndex: Int
    var walkPhase: Double = 0
    var lastVoiceAt: Date = .distantPast
}

/// Headless AI director for all animals: Idle / Wander / Hungry / SeekFood / Eating /
/// Sleeping / Producing. Runs at ~15 Hz whether or not the overlay is visible.
@MainActor
final class PetDirector {
    private weak var engine: GameEngine?
    private let layout: WorldLayout
    private(set) var actors: [UUID: PetActor] = [:]
    private var reservations: [UUID: UUID] = [:]
    private var timer: Timer?
    private var lastStep = Date()

    /// Called when an actor changes behaviour (for sounds / effects).
    var onBehaviorChange: ((PetActor, PetBehavior) -> Void)?

    init(engine: GameEngine, layout: WorldLayout) {
        self.engine = engine
        self.layout = layout
    }

    func start() {
        stop()
        lastStep = Date()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Live positions for persisting into the save.
    func positions() -> [UUID: (UnitPoint2D, Int)] {
        var result: [UUID: (UnitPoint2D, Int)] = [:]
        for (id, actor) in actors {
            result[id] = layout.unitPoint(from: actor.position)
        }
        return result
    }

    /// Ground position of a food target (trough station or deterministic spot).
    func foodPosition(_ target: FoodTarget, stations: [Station]) -> CGPoint {
        if let trough = target.troughID, let station = stations.first(where: { $0.id == trough }) {
            return station.center
        }
        return layout.groundSpot(for: target.id)
    }

    // MARK: - User interaction

    func beginHold(_ id: UUID) {
        guard var actor = actors[id] else { return }
        release(actor)
        actor.behavior = .held
        actor.target = nil
        actor.foodID = nil
        actors[id] = actor
    }

    func moveHeld(_ id: UUID, to point: CGPoint) {
        guard var actor = actors[id], actor.behavior == .held else { return }
        actor.position = point
        actors[id] = actor
    }

    func endHold(_ id: UUID) {
        guard var actor = actors[id] else { return }
        actor.behavior = .idle
        actor.stateUntil = Date().addingTimeInterval(1.5)
        actors[id] = actor
    }

    // MARK: - Simulation

    func step(now: Date = Date()) {
        let dt = min(0.25, now.timeIntervalSince(lastStep))
        lastStep = now
        guard let engine else { return }
        sync(with: engine)
        let stations = currentStations(engine)
        for id in Array(actors.keys) {
            guard var actor = actors[id], let pet = engine.pet(id) else { continue }
            let before = actor.behavior
            update(&actor, pet: pet, engine: engine, stations: stations, dt: dt, now: now)
            actors[id] = actor
            if actor.behavior != before {
                onBehaviorChange?(actor, before)
            }
        }
    }

    func currentStations(_ engine: GameEngine) -> [Station] {
        layout.stations(
            plants: engine.plantedFiles.map(\.0.id),
            machines: engine.machineViews.map(\.id),
            troughs: engine.troughFolders.compactMap { $0.marker?.id }
        )
    }

    private func sync(with engine: GameEngine) {
        let pets = engine.game.pets
        let ids = Set(pets.map(\.id))
        for id in actors.keys where !ids.contains(id) {
            if let actor = actors[id] { release(actor) }
            actors[id] = nil
        }
        for pet in pets where actors[pet.id] == nil {
            let point = layout.globalPoint(from: pet.position, screenIndex: pet.screenIndex)
            actors[pet.id] = PetActor(
                id: pet.id,
                species: pet.species,
                position: point,
                target: nil,
                behavior: .idle,
                stateUntil: Date().addingTimeInterval(Double.random(in: 1...3)),
                facingLeft: Bool.random(),
                foodID: nil,
                screenIndex: pet.screenIndex
            )
        }
    }

    private func update(_ actor: inout PetActor, pet: PetState, engine: GameEngine, stations: [Station], dt: Double, now: Date) {
        switch actor.behavior {
        case .held:
            return
        case .eating:
            if now >= actor.stateUntil {
                if let food = actor.foodID { _ = engine.petEat(actor.id, foodFileID: food) }
                release(actor)
                actor.foodID = nil
                actor.behavior = .idle
                actor.stateUntil = now.addingTimeInterval(2)
            }
            return
        case .producing:
            if now >= actor.stateUntil {
                _ = engine.petProduce(actor.id)
                actor.behavior = .idle
                actor.stateUntil = now.addingTimeInterval(2)
            }
            return
        default:
            break
        }

        if HusbandryEngine.isSleeping(pet, now: now) {
            release(actor)
            actor.foodID = nil
            actor.target = nil
            actor.behavior = .sleeping
            return
        }
        if actor.behavior == .sleeping {
            actor.behavior = .idle
            actor.stateUntil = now.addingTimeInterval(1)
        }

        if pet.readyToProduce && engine.hasRoomForProduce && actor.behavior != .seekFood {
            actor.behavior = .producing
            actor.target = nil
            actor.stateUntil = now.addingTimeInterval(1.6)
            return
        }

        if pet.isHungry {
            let targets = engine.foodTargets(for: pet.species)
            if actor.behavior == .seekFood, let foodID = actor.foodID, let food = targets.first(where: { $0.id == foodID }) {
                let destination = foodPosition(food, stations: stations)
                actor.target = destination
                if move(&actor, speed: pet.species.walkSpeed * 1.6, dt: dt) {
                    actor.behavior = .eating
                    actor.stateUntil = now.addingTimeInterval(2.2)
                }
                return
            }
            release(actor)
            actor.foodID = nil
            let free = targets.filter { reservations[$0.id] == nil || reservations[$0.id] == actor.id }
            let nearest = free.min { lhs, rhs in
                distance(actor.position, foodPosition(lhs, stations: stations)) < distance(actor.position, foodPosition(rhs, stations: stations))
            }
            if let nearest {
                reservations[nearest.id] = actor.id
                actor.foodID = nearest.id
                actor.behavior = .seekFood
                actor.target = foodPosition(nearest, stations: stations)
                return
            }
            // Nothing to eat: wander slowly with a food bubble.
            if actor.behavior != .hungry || actor.target == nil {
                actor.behavior = .hungry
                actor.target = randomPoint(for: actor)
            }
            if move(&actor, speed: pet.species.walkSpeed * 0.45, dt: dt) {
                actor.target = randomPoint(for: actor)
            }
            return
        }

        switch actor.behavior {
        case .wander:
            if move(&actor, speed: pet.species.walkSpeed, dt: dt) {
                actor.behavior = .idle
                actor.stateUntil = now.addingTimeInterval(Double.random(in: 2...5))
            }
        case .idle:
            if now >= actor.stateUntil {
                actor.behavior = .wander
                actor.target = randomPoint(for: actor)
            }
        default:
            actor.behavior = .idle
            actor.target = nil
            actor.stateUntil = now.addingTimeInterval(Double.random(in: 1...3))
        }
    }

    /// Moves toward the target; returns true on arrival.
    private func move(_ actor: inout PetActor, speed: Double, dt: Double) -> Bool {
        guard let target = actor.target else { return true }
        let dx = target.x - actor.position.x
        let dy = target.y - actor.position.y
        let length = sqrt(dx * dx + dy * dy)
        if length < 6 {
            actor.position = target
            return true
        }
        let stepLength = min(length, CGFloat(speed * dt))
        actor.position.x += dx / length * stepLength
        actor.position.y += dy / length * stepLength
        if abs(dx) > 1 { actor.facingLeft = dx < 0 }
        actor.walkPhase += dt * speed / 10
        return false
    }

    private func randomPoint(for actor: PetActor) -> CGPoint {
        let area = layout.petArea(screenIndex: actor.screenIndex)
        return CGPoint(x: CGFloat.random(in: area.minX...area.maxX), y: CGFloat.random(in: area.minY...area.maxY))
    }

    private func release(_ actor: PetActor) {
        if let food = actor.foodID, reservations[food] == actor.id {
            reservations[food] = nil
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
