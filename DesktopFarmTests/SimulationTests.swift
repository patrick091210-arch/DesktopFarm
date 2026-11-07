import Foundation
import XCTest
@testable import DesktopHarvest

@MainActor
final class SimulationTests: FarmTestCase {
    func testCropGrowsOnlyWhileMoist() {
        var crop = PlantState(id: UUID(), species: .wheat, plantedAt: Date(), moisture: 100)
        _ = BotanyEngine.advance(&crop, dt: 30, sprinklered: false, fruitBlocked: false)
        XCTAssertEqual(crop.growth, 30 / PlantSpecies.wheat.growDuration, accuracy: 0.001)

        var dry = PlantState(id: UUID(), species: .wheat, plantedAt: Date(), moisture: 10)
        _ = BotanyEngine.advance(&dry, dt: 60, sprinklered: false, fruitBlocked: false)
        XCTAssertEqual(dry.growth, 0, "no growth below the moisture threshold")

        XCTAssertEqual(dry.moisture, 0, accuracy: 0.001, "moisture drained to zero")
        var watered = dry
        BotanyEngine.water(&watered, now: Date())
        XCTAssertEqual(watered.moisture, PlantState.wateringAmount, accuracy: 0.001)
    }

    func testCropBecomesRipe() {
        var crop = PlantState(id: UUID(), species: .hay, plantedAt: Date(), moisture: 100)
        let tick = BotanyEngine.advance(&crop, dt: 70, sprinklered: true, fruitBlocked: false)
        XCTAssertTrue(tick.becameRipe)
        XCTAssertTrue(crop.isRipeCrop)
        XCTAssertEqual(crop.stage, .ripe)
    }

    func testTreeFruitsRepeatedlyWithSprinkler() {
        var tree = PlantState(id: UUID(), species: .appleTree, plantedAt: Date(), moisture: 100)
        tree.growth = 1
        var drops = 0
        for _ in 0..<40 {
            drops += BotanyEngine.advance(&tree, dt: 20, sprinklered: true, fruitBlocked: false).fruitDrops
        }
        XCTAssertEqual(drops, Int(800 / PlantSpecies.appleTree.fruitCycle))
        XCTAssertTrue(tree.isGrownTree, "a perennial stays a grown tree after fruiting")

        var blocked = tree
        let before = blocked.fruitProgress
        _ = BotanyEngine.advance(&blocked, dt: 60, sprinklered: true, fruitBlocked: true)
        XCTAssertEqual(blocked.fruitProgress, before, accuracy: 0.0001)
    }

    func testAnimalHungerAndProduction() {
        var pet = PetState(id: UUID(), species: .chicken, name: "测试", position: .center, bornAt: Date())
        pet.satiety = 100
        pet.affection = 100
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        var ready = false
        for _ in 0..<20 where !ready {
            ready = HusbandryEngine.advance(&pet, dt: 10, now: noon)
        }
        XCTAssertTrue(pet.readyToProduce)

        pet.satiety = 10
        pet.productionProgress = 0
        HusbandryEngine.advance(&pet, dt: 60, now: noon)
        XCTAssertEqual(pet.productionProgress, 0, "hungry animals do not produce")
        XCTAssertTrue(HusbandryEngine.feed(&pet, food: .wheat, now: noon))
        XCTAssertFalse(pet.isHungry)
        XCTAssertFalse(HusbandryEngine.feed(&pet, food: .wool, now: noon))
    }

    func testPlantingAndHarvestTransformsRealFiles() throws {
        let engine = try makeEngine()
        let seed = try XCTUnwrap(engine.seedFiles.first { $0.payload.itemType == PlantSpecies.wheat.rawValue })
        let plantID = try XCTUnwrap(engine.plant(seedFileID: seed.payload.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: seed.url.path))
        let cropFile = try XCTUnwrap(engine.scan.file(id: plantID))
        XCTAssertEqual(cropFile.url.pathExtension, "crop")

        let index = try XCTUnwrap(engine.game.plantIndex(plantID))
        engine.game.plants[index].growth = 1
        let harvested = engine.harvest(plantID)
        XCTAssertGreaterThanOrEqual(harvested, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cropFile.url.path))
        XCTAssertEqual(files(engine, of: .wheat).filter { $0.role == .field }.count, harvested)
        XCTAssertNil(engine.game.plantIndex(plantID))
    }

    func testTreeDropsRealFruitFiles() throws {
        let engine = try makeEngine()
        let index = try XCTUnwrap(engine.game.plants.firstIndex { $0.species == .appleTree })
        engine.game.plants[index].growth = 1
        engine.game.plants[index].fruitProgress = 0.99
        engine.game.plants[index].moisture = 100
        engine.advanceWorld(dt: 5, now: Date(), offline: false)
        let apples = files(engine, of: .apple)
        XCTAssertTrue((2...4).contains(apples.count))
        XCTAssertTrue(apples.allSatisfy { $0.url.lastPathComponent.hasPrefix("Apple_") })
        XCTAssertNotNil(engine.game.plantIndex(engine.game.plants[index].id), "tree survives the harvest")
    }

    func testPetEatsFromTroughAndProduces() throws {
        let engine = try makeEngine()
        let pet = try XCTUnwrap(engine.game.pets.first)
        let troughFood = engine.foodTargets(for: pet.species).filter { $0.troughID != nil }
        XCTAssertFalse(troughFood.isEmpty, "starter trough holds wheat")
        XCTAssertTrue(engine.petEat(pet.id, foodFileID: troughFood[0].id))
        XCTAssertEqual(engine.foodTargets(for: pet.species).filter { $0.troughID != nil }.count, troughFood.count - 1)

        let index = try XCTUnwrap(engine.game.petIndex(pet.id))
        engine.game.pets[index].productionProgress = 1
        XCTAssertEqual(engine.petProduce(pet.id), .egg)
        XCTAssertEqual(files(engine, of: .egg).count, 1)
    }

    func testOfflineSettlementProducesFruit() throws {
        let start = Date().addingTimeInterval(-3600)
        let engine = try makeEngine(now: start)
        let index = try XCTUnwrap(engine.game.plants.firstIndex { $0.species == .appleTree })
        engine.game.plants[index].growth = 1
        let sprinkler = signer.sign(GameFilePayload(kind: .tool, itemType: ToolType.sprinkler.rawValue))
        try GameJSON.encoder().encode(sprinkler).write(to: farmRoot.appendingPathComponent("Sprinkler.tool"))
        engine.reconcile()
        engine.settleOffline(from: start, to: start.addingTimeInterval(900))
        XCTAssertGreaterThanOrEqual(files(engine, of: .apple).count, 4)
    }
}
