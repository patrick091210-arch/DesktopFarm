import Foundation

/// Result of advancing one plant.
struct BotanyTick: Sendable, Equatable {
    var becameRipe = false
    var becameGrownTree = false
    var fruitDrops = 0
}

/// Pure plant simulation: moisture, growth, perennial fruiting cycles.
enum BotanyEngine {
    /// Moisture points per second added by a sprinkler in the same directory.
    static let sprinklerRate: Double = 1.6

    static func water(_ plant: inout PlantState, amount: Double = PlantState.wateringAmount, now: Date) {
        plant.moisture = min(PlantState.maxMoisture, plant.moisture + amount)
        plant.lastWateredAt = now
    }

    /// Advances a plant by `dt` game-seconds.
    /// - Parameters:
    ///   - sprinklered: a sprinkler shares the plant's directory.
    ///   - fruitBlocked: too many loose fruits lie around; trees pause fruiting.
    static func advance(_ plant: inout PlantState, dt: Double, sprinklered: Bool, fruitBlocked: Bool) -> BotanyTick {
        var tick = BotanyTick()
        guard dt > 0 else { return tick }
        let threshold = PlantState.growthMoistureThreshold
        let netDrain = plant.species.moistureDrain - (sprinklered ? sprinklerRate : 0)

        // Seconds of this step during which moisture stays above the growth threshold.
        var growTime: Double
        if plant.moisture <= threshold && netDrain >= 0 {
            growTime = 0
        } else if netDrain > 0 {
            growTime = min(dt, max(0, (plant.moisture - threshold) / netDrain))
        } else if plant.moisture > threshold {
            growTime = dt
        } else {
            // Sprinkler refills a dry plant: growth resumes once above threshold.
            let refill = (threshold - plant.moisture) / -netDrain
            growTime = max(0, dt - refill)
        }
        plant.moisture = min(PlantState.maxMoisture, max(0, plant.moisture - netDrain * dt))

        guard growTime > 0 else { return tick }
        plant.careScore = (plant.careScore * Double(plant.careSamples) + plant.moistureFraction) / Double(plant.careSamples + 1)
        plant.careSamples = min(plant.careSamples + 1, 500)

        if plant.growth < 1 {
            let needed = (1 - plant.growth) * plant.species.growDuration
            if growTime >= needed {
                plant.growth = 1
                growTime -= needed
                if plant.species.isTree { tick.becameGrownTree = true } else { tick.becameRipe = true }
            } else {
                plant.growth += growTime / plant.species.growDuration
                growTime = 0
            }
        }

        if plant.species.isTree && plant.growth >= 1 && growTime > 0 && !fruitBlocked {
            plant.fruitProgress += growTime / plant.species.fruitCycle
            var cycles = 0
            while plant.fruitProgress >= 1 {
                plant.fruitProgress -= 1
                cycles += 1
            }
            // A single step never drops more than 2 batches of catch-up; the
            // harvest counter only counts batches that actually dropped.
            tick.fruitDrops = min(cycles, 2)
            plant.harvestCount += tick.fruitDrops
        }
        return tick
    }

    /// Qualities for one harvest (one entry per produced item).
    static func harvestQualities<G: RandomNumberGenerator>(for plant: PlantState, using rng: inout G) -> [Quality] {
        let count = Int.random(in: plant.species.yieldRange, using: &rng)
        return (0..<count).map { _ in Quality.roll(care: plant.careScore, using: &rng) }
    }

    /// Resets a perennial after harvest-drop (stays a grown tree, back to cooldown).
    static func resetAfterHarvest(_ plant: inout PlantState) {
        plant.careScore = max(0.4, plant.careScore * 0.8)
        plant.careSamples = 1
    }
}

/// Pure animal stat simulation: hunger, affection, production.
enum HusbandryEngine {
    static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 6
    }

    static func isSleeping(_ pet: PetState, now: Date) -> Bool {
        if let nap = pet.napUntil, nap > now { return true }
        return isNight(now) && !pet.isHungry
    }

    /// Advances stats by `dt` game-seconds. Returns true when the pet just became ready to produce.
    @discardableResult
    static func advance(_ pet: inout PetState, dt: Double, now: Date) -> Bool {
        guard dt > 0 else { return false }
        let sleeping = isSleeping(pet, now: now)
        let drain = pet.species.hungerDrain * (sleeping ? 0.5 : 1)
        let wasReady = pet.readyToProduce
        // Production only progresses for the part of the step spent well fed.
        let fedTime: Double
        if pet.satiety <= AnimalSpecies.hungryThreshold {
            fedTime = 0
        } else {
            fedTime = min(dt, (pet.satiety - AnimalSpecies.hungryThreshold) / max(drain, 0.0001))
        }
        pet.satiety = max(0, pet.satiety - drain * dt)
        if fedTime > 0 && !pet.readyToProduce {
            let rate = (0.8 + 0.4 * pet.affectionFraction) / pet.species.productionCycle
            pet.productionProgress = min(1, pet.productionProgress + fedTime * rate)
        }
        if pet.isHungry {
            pet.affection = max(0, pet.affection - 0.02 * dt)
        }
        return !wasReady && pet.readyToProduce
    }

    /// Feeds one food item. Returns false if the species does not eat it.
    @discardableResult
    static func feed(_ pet: inout PetState, food: ItemType, quality: Quality = .normal, now: Date) -> Bool {
        guard let value = pet.species.diet[food] else { return false }
        pet.satiety = min(100, pet.satiety + value * (1 + 0.1 * Double(quality.rawValue - 1)))
        var affectionGain = food == pet.species.favoriteFood ? 6.0 : 3.0
        if food == .apple { affectionGain += 3 }
        pet.affection = min(100, pet.affection + affectionGain)
        pet.lastFedAt = now
        if pet.satiety >= 95 {
            pet.napUntil = now.addingTimeInterval(25)
        }
        return true
    }

    static func pat(_ pet: inout PetState) {
        pet.affection = min(100, pet.affection + 1.5)
    }

    static func completeProduction<G: RandomNumberGenerator>(_ pet: inout PetState, using rng: inout G) -> Quality {
        pet.productionProgress = 0
        pet.satiety = max(0, pet.satiety - 10)
        pet.productsMade += 1
        return Quality.roll(care: pet.affectionFraction, using: &rng)
    }
}
