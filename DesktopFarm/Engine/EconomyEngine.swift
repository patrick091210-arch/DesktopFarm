import Foundation

/// Pure economy rules: order generation, order fulfilment, shipping.
enum EconomyEngine {
    static let orderSlots = 3
    static let orderLifetime: TimeInterval = 6 * 60 * 60
    static let orderRespawnDelay: TimeInterval = 45
    static let orderRefreshCost = 10

    struct Villager: Sendable {
        var name: String
        var avatar: String
        var likes: [ItemType]
    }

    static let villagers: [Villager] = [
        Villager(name: "烘焙师玛莎", avatar: "👩‍🍳", likes: [.wheat, .egg, .milk, .cake, .strawberry]),
        Villager(name: "杂货商老王", avatar: "🧔", likes: [.carrot, .wheat, .apple, .egg, .hay]),
        Villager(name: "裁缝艾米", avatar: "🧵", likes: [.wool, .sweater, .cherry]),
        Villager(name: "果园婆婆", avatar: "👵", likes: [.apple, .cherry, .appleJam, .cherryJam, .strawberryJam]),
        Villager(name: "酒馆老板", avatar: "🍺", likes: [.cheese, .milk, .appleJam, .carrot]),
        Villager(name: "牧场主汤姆", avatar: "🤠", likes: [.hay, .wheat, .carrot, .milk, .wool])
    ]

    /// Items a player can realistically obtain at `level`.
    static func obtainableItems(level: Int) -> [ItemType] {
        var items: [ItemType] = []
        for species in PlantSpecies.allCases where species.unlockLevel <= level {
            items.append(species.produce)
        }
        for species in AnimalSpecies.allCases where species.unlockLevel <= level {
            items.append(species.product)
        }
        for machine in MachineType.allCases where machine.unlockLevel <= level {
            for recipe in machine.recipes {
                let inputsObtainable = recipe.inputs.keys.allSatisfy { items.contains($0) }
                if inputsObtainable { items.append(recipe.output) }
            }
        }
        var seen = Set<ItemType>()
        return items.filter { seen.insert($0).inserted }
    }

    static func generateOrder<G: RandomNumberGenerator>(level: Int, now: Date, using rng: inout G) -> FarmOrder {
        let pool = obtainableItems(level: level)
        let villager = villagers.randomElement(using: &rng) ?? villagers[0]
        var preferred = villager.likes.filter { pool.contains($0) }
        if preferred.isEmpty { preferred = pool }
        let lineCount = min(preferred.count, level >= 3 ? Int.random(in: 1...3, using: &rng) : Int.random(in: 1...2, using: &rng))
        var chosen: [ItemType] = []
        var candidates = preferred
        while chosen.count < lineCount, !candidates.isEmpty {
            let index = Int.random(in: 0..<candidates.count, using: &rng)
            chosen.append(candidates.remove(at: index))
        }
        let lines = chosen.map { item -> OrderLine in
            let maxQuantity = item.isProcessed ? 2 : (item.basePrice <= 5 ? 6 : 4)
            return OrderLine(item: item, quantity: Int.random(in: 1...maxQuantity, using: &rng))
        }
        let baseValue = lines.reduce(0) { $0 + $1.item.basePrice * $1.quantity }
        let premium = Double.random(in: 1.5...1.9, using: &rng)
        let coins = max(10, Int((Double(baseValue) * premium / 5).rounded()) * 5)
        return FarmOrder(
            id: UUID(),
            requester: villager.name,
            avatar: villager.avatar,
            lines: lines,
            rewardCoins: coins,
            rewardXP: max(8, coins / 3),
            createdAt: now,
            expiresAt: now.addingTimeInterval(orderLifetime)
        )
    }

    /// Chooses the item files that would fulfil `order` from `pool` (in priority order),
    /// preferring the lowest quality first. Returns nil if anything is missing.
    static func fulfilmentPlan(for order: FarmOrder, pool: [ScannedFile]) -> [ScannedFile]? {
        let usable = SmartCrateMonitor.sellableItems(pool)
        var picked: [ScannedFile] = []
        for line in order.lines {
            let matches = usable.enumerated()
                .filter { $0.element.payload.itemValue == line.item }
                .sorted { lhs, rhs in
                    if lhs.element.payload.quality != rhs.element.payload.quality {
                        return lhs.element.payload.quality < rhs.element.payload.quality
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
            guard matches.count >= line.quantity else { return nil }
            picked.append(contentsOf: matches.prefix(line.quantity))
        }
        return picked
    }

    /// How many of each requested item are currently available in `pool`.
    static func availability(for order: FarmOrder, pool: [ScannedFile]) -> [ItemType: Int] {
        var counts: [ItemType: Int] = [:]
        for file in SmartCrateMonitor.sellableItems(pool) {
            if let type = file.payload.itemValue { counts[type, default: 0] += 1 }
        }
        return counts
    }
}
