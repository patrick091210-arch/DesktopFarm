import Foundation

/// Normalised 2D point (0...1) relative to a screen's visible frame.
struct UnitPoint2D: Codable, Sendable, Equatable {
    var x: Double
    var y: Double

    static let center = UnitPoint2D(x: 0.5, y: 0.25)

    func clamped() -> UnitPoint2D {
        UnitPoint2D(x: min(max(x, 0.02), 0.98), y: min(max(y, 0.02), 0.98))
    }
}

/// Dynamic state of a planted `.crop` / `.tree` file.
struct PlantState: Codable, Sendable, Equatable, Identifiable {
    static let maxMoisture: Double = 100
    static let wateringAmount: Double = 50
    /// Plants only grow when moisture is above this level ("水分充足").
    static let growthMoistureThreshold: Double = 15

    var id: UUID
    var species: PlantSpecies
    var plantedAt: Date
    var moisture: Double
    /// 0...1 progress from seed to ripe crop / grown tree.
    var growth: Double
    /// Trees only: 0...1 progress of the current fruiting cycle.
    var fruitProgress: Double
    var harvestCount: Int
    /// Running average of moisture while growing; drives harvest quality.
    var careScore: Double
    var careSamples: Int
    var lastWateredAt: Date?

    init(id: UUID, species: PlantSpecies, plantedAt: Date, moisture: Double = 60) {
        self.id = id
        self.species = species
        self.plantedAt = plantedAt
        self.moisture = moisture
        self.growth = 0
        self.fruitProgress = 0
        self.harvestCount = 0
        self.careScore = 0.6
        self.careSamples = 1
        self.lastWateredAt = nil
    }

    var stage: PlantStage { species.stage(growth: growth, fruitProgress: fruitProgress) }
    var moistureFraction: Double { min(max(moisture / PlantState.maxMoisture, 0), 1) }
    var isThirsty: Bool { moisture < 30 }
    var canGrow: Bool { moisture > PlantState.growthMoistureThreshold }
    var isRipeCrop: Bool { !species.isTree && growth >= 1 }
    var isGrownTree: Bool { species.isTree && growth >= 1 }

    /// Progress shown on the green bar: growth, then fruit cycle for trees.
    var displayProgress: Double {
        if species.isTree && growth >= 1 { return min(max(fruitProgress, 0), 1) }
        return min(max(growth, 0), 1)
    }

    /// Wall-clock seconds (speed 1) until the next milestone, assuming moisture holds.
    var secondsToNextMilestone: Double {
        if species.isTree && growth >= 1 {
            return max(0, (1 - fruitProgress) * species.fruitCycle)
        }
        return max(0, (1 - growth) * species.growDuration)
    }
}

/// Persistent stats of an animal. Transient AI state lives in `PetDirector`.
struct PetState: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var species: AnimalSpecies
    var name: String
    var satiety: Double
    var affection: Double
    var productionProgress: Double
    var position: UnitPoint2D
    var screenIndex: Int
    var productsMade: Int
    var bornAt: Date
    var napUntil: Date?
    var lastFedAt: Date?

    init(id: UUID, species: AnimalSpecies, name: String, position: UnitPoint2D, bornAt: Date) {
        self.id = id
        self.species = species
        self.name = name
        self.satiety = 70
        self.affection = 40
        self.productionProgress = 0
        self.position = position
        self.screenIndex = 0
        self.productsMade = 0
        self.bornAt = bornAt
        self.napUntil = nil
        self.lastFedAt = nil
    }

    var isHungry: Bool { satiety < AnimalSpecies.hungryThreshold }
    var readyToProduce: Bool { productionProgress >= 1 }
    var satietyFraction: Double { min(max(satiety / 100, 0), 1) }
    var affectionFraction: Double { min(max(affection / 100, 0), 1) }
}

/// A running job in a processing machine folder.
struct MachineJob: Codable, Sendable, Equatable {
    var output: ItemType
    var inputIDs: [UUID]
    var quality: Int
    var duration: Double
    var elapsed: Double
    var startedAt: Date
    /// Pre-assigned id of the product file, making completion idempotent: if the app dies
    /// after writing the product but before saving, the retry finds it instead of duplicating.
    var outputID: UUID?

    var progress: Double { min(max(elapsed / max(duration, 0.1), 0), 1) }
    var isFinished: Bool { elapsed >= duration }
}

struct MachineState: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var type: MachineType
    var job: MachineJob?
    var completedJobs: Int

    init(id: UUID, type: MachineType) {
        self.id = id
        self.type = type
        self.job = nil
        self.completedJobs = 0
    }
}

/// Registration record of a signed game file seen by the farm.
struct LedgerEntry: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var kind: GameFileKind
    var itemType: String
    var quality: Int
    var inode: UInt64
    var relativePath: String
    var registeredAt: Date
    var missingSince: Date?
}

struct OrderLine: Codable, Sendable, Equatable, Hashable {
    var item: ItemType
    var quantity: Int
}

/// A villager order on the farm order board.
struct FarmOrder: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var requester: String
    var avatar: String
    var lines: [OrderLine]
    var rewardCoins: Int
    var rewardXP: Int
    var createdAt: Date
    var expiresAt: Date

    var title: String { "\(avatar) \(requester)的订单" }
}

struct ActivityEntry: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var date: Date
    var icon: String
    var message: String

    init(id: UUID = UUID(), date: Date, icon: String, message: String) {
        self.id = id
        self.date = date
        self.icon = icon
        self.message = message
    }
}

struct FarmStats: Codable, Sendable, Equatable {
    var cropsHarvested = 0
    var fruitsDropped = 0
    var animalProducts = 0
    var goodsProcessed = 0
    var itemsShipped = 0
    var coinsEarned = 0
    var ordersCompleted = 0
    var clonesCaught = 0
}

/// The whole persisted game, written to Application Support/DesktopHarvest/savegame.json.
struct SaveGame: Codable, Sendable, Equatable {
    static let currentVersion = 1
    static let startingCoins = 120

    var version: Int
    var coins: Int
    var xp: Int
    var createdAt: Date
    var lastTickAt: Date
    var lastDailyRollover: String
    var plants: [PlantState]
    var pets: [PetState]
    var machines: [MachineState]
    var ledger: [LedgerEntry]
    var spentIDs: [UUID]
    var orders: [FarmOrder]
    var nextOrderAt: Date?
    var upgrades: [UpgradeType]
    var stats: FarmStats
    var activity: [ActivityEntry]
    var bootstrapped: Bool
    /// Time of the last successful save; anchors the anti-resurrection window.
    var lastSavedAt: Date?

    static func fresh(at now: Date) -> SaveGame {
        SaveGame(
            version: currentVersion,
            coins: startingCoins,
            xp: 0,
            createdAt: now,
            lastTickAt: now,
            lastDailyRollover: DayStamp.string(for: now),
            plants: [],
            pets: [],
            machines: [],
            ledger: [],
            spentIDs: [],
            orders: [],
            nextOrderAt: nil,
            upgrades: [],
            stats: FarmStats(),
            activity: [],
            bootstrapped: false,
            lastSavedAt: nil
        )
    }

    var level: Int { Progression.level(forXP: xp) }

    func plantIndex(_ id: UUID) -> Int? { plants.firstIndex { $0.id == id } }
    func petIndex(_ id: UUID) -> Int? { pets.firstIndex { $0.id == id } }
    func machineIndex(_ id: UUID) -> Int? { machines.firstIndex { $0.id == id } }
    func ledgerIndex(_ id: UUID) -> Int? { ledger.firstIndex { $0.id == id } }
    func hasUpgrade(_ upgrade: UpgradeType) -> Bool { upgrades.contains(upgrade) }
}

enum DayStamp {
    static func string(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
