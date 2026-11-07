import Darwin
import Foundation
import XCTest
@testable import DesktopHarvest

/// Regression tests for audit findings C1–C5 (machine recovery, offline bounds, persistence).
@MainActor
final class RecoveryTests: FarmTestCase {
    private func startJam(_ engine: GameEngine) throws -> MachineView {
        let machine = try XCTUnwrap(engine.machineViews.first { $0.type == .jamMaker })
        try makeItem(engine, .apple, in: machine.url)
        try makeItem(engine, .apple, in: machine.url)
        let working = try XCTUnwrap(engine.machineViews.first { $0.id == machine.id })
        XCTAssertEqual(working.status, .working)
        return working
    }

    private func processingURL(_ machine: MachineView) -> URL {
        machine.url.appendingPathComponent(".processing")
    }

    // C1: crash after inputs were staged but before the job was saved.
    func testOrphanedStagedInputsAreReturnedAfterCrash() throws {
        let engine = try makeEngine()
        let machine = try startJam(engine)
        let index = try XCTUnwrap(engine.game.machineIndex(machine.id))
        engine.game.machines[index].job = nil // the save never recorded the job

        engine.reconcile()
        // Inputs came back to the machine folder and, satisfying the recipe, restarted it.
        let view = try XCTUnwrap(engine.machineViews.first { $0.id == machine.id })
        XCTAssertEqual(view.status, .working)
        XCTAssertEqual(engine.scan.files(inFolder: machine.id, role: .processing).count, 2)
        XCTAssertEqual(files(engine, of: .apple).count, 2, "no input lost")
    }

    // C2: the player pulls one locked input out mid-job.
    func testRemovingAStagedInputCancelsAndReturnsTheRest() throws {
        let engine = try makeEngine()
        let machine = try startJam(engine)
        let staged = engine.scan.files(inFolder: machine.id, role: .processing)
        let taken = farmRoot.appendingPathComponent(staged[0].name)
        try FileManager.default.moveItem(at: staged[0].url, to: taken)

        engine.reconcile()
        let view = try XCTUnwrap(engine.machineViews.first { $0.id == machine.id })
        XCTAssertEqual(view.status, .idle)
        XCTAssertNil(engine.game.machines.first { $0.id == machine.id }?.job)
        XCTAssertTrue(engine.scan.files(inFolder: machine.id, role: .processing).isEmpty)
        XCTAssertEqual(view.inputCounts[.apple], 1, "the remaining apple is back in the machine folder")
        XCTAssertEqual(files(engine, of: .apple).count, 2, "nothing was destroyed")
        engine.advanceWorld(dt: 60, now: Date(), offline: false)
        XCTAssertEqual(files(engine, of: .appleJam).count, 0, "no product without inputs")
    }

    // C3: crash after the product was written but before inputs were consumed / saved.
    func testCompletionIsIdempotentAcrossACrash() throws {
        let engine = try makeEngine()
        let machine = try startJam(engine)
        let index = try XCTUnwrap(engine.game.machineIndex(machine.id))
        let job = try XCTUnwrap(engine.game.machines[index].job)
        let outputID = try XCTUnwrap(job.outputID)
        // Simulate step 1 having landed: the product with the pre-assigned id exists.
        XCTAssertNotNil(engine.createItem(.appleJam, quality: .normal, in: machine.url, grantProductionXP: false, id: outputID))
        engine.game.machines[index].job?.elapsed = job.duration
        engine.rescan()

        engine.reconcile() // restart: recovery completes the finished job
        XCTAssertEqual(files(engine, of: .appleJam).count, 1, "product not duplicated")
        XCTAssertEqual(files(engine, of: .apple).count, 0, "inputs consumed exactly once")
        XCTAssertNil(engine.game.machines[index].job)
        XCTAssertTrue(job.inputIDs.allSatisfy { engine.game.spentIDs.contains($0) })
    }

    func testFinishedJobIsCompletedOnNextLaunch() throws {
        let engine = try makeEngine()
        let machine = try startJam(engine)
        let index = try XCTUnwrap(engine.game.machineIndex(machine.id))
        engine.game.machines[index].job?.elapsed = 1_000 // finished, completion never ran
        engine.save()

        let reopened = try makeEngine()
        XCTAssertEqual(files(reopened, of: .appleJam).count, 1)
        XCTAssertEqual(files(reopened, of: .apple).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: machine.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: processingURL(machine).path), "staging folder cleaned up")
    }

    func testStrayFilesInProcessingAreReturned() throws {
        let engine = try makeEngine()
        let machine = try startJam(engine)
        let stray = try XCTUnwrap(engine.createItem(.egg, quality: .normal, in: processingURL(machine), grantProductionXP: false))
        engine.reconcile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertEqual(engine.machineViews.first { $0.id == machine.id }?.inputCounts[.egg], 1)
        XCTAssertEqual(engine.machineViews.first { $0.id == machine.id }?.status, .working, "the real job continues")
    }

    // C4: 72 h offline with a stocked trough never floods the desktop, and runs at 1×.
    func testLongOfflineIsBoundedAndRealTime() throws {
        let start = Date().addingTimeInterval(-72 * 3600)
        let engine = try makeEngine(now: start)
        engine.speed = 20
        let trough = try XCTUnwrap(engine.troughFolders.first?.url)
        for _ in 0..<60 { engine.createItem(.wheat, quality: .normal, in: trough, grantProductionXP: false) }
        let treeIndex = try XCTUnwrap(engine.game.plants.firstIndex { $0.species == .appleTree })
        engine.game.plants[treeIndex].growth = 1
        let sprinkler = signer.sign(GameFilePayload(kind: .tool, itemType: ToolType.sprinkler.rawValue))
        try GameJSON.encoder().encode(sprinkler).write(to: farmRoot.appendingPathComponent("Sprinkler.tool"))
        engine.reconcile()

        engine.settleOffline(from: start, to: start.addingTimeInterval(72 * 3600))
        let loose = engine.scan.files.filter { $0.role == .field && $0.directory.isEmpty && $0.payload.kind == .item }
        XCTAssertLessThanOrEqual(loose.count, GameEngine.looseItemCap + 4, "producers pause at the cap")
        XCTAssertGreaterThan(files(engine, of: .egg).count, 0)
        for plant in engine.game.plants {
            XCTAssertTrue((0...PlantState.maxMoisture).contains(plant.moisture))
            XCTAssertTrue((0...1).contains(plant.growth))
            XCTAssertTrue((0..<1).contains(plant.fruitProgress))
        }
        for pet in engine.game.pets {
            XCTAssertTrue((0...100).contains(pet.satiety))
            XCTAssertTrue((0...1).contains(pet.productionProgress))
        }
    }

    func testFruitCounterMatchesActualDrops() {
        var tree = PlantState(id: UUID(), species: .appleTree, plantedAt: Date(), moisture: 100)
        tree.growth = 1
        let tick = BotanyEngine.advance(&tree, dt: PlantSpecies.appleTree.fruitCycle * 7.5, sprinklered: true, fruitBlocked: false)
        XCTAssertEqual(tick.fruitDrops, 2)
        XCTAssertEqual(tree.harvestCount, 2)
    }

    // C5: economic transactions are persisted immediately.
    func testShippingIsPersistedImmediately() throws {
        let engine = try makeEngine()
        let bin = try folder(engine, role: .shippingBin)
        try makeItem(engine, .milk, in: bin)
        let coins = engine.shipNow()
        let onDisk = try XCTUnwrap(SaveManager(directory: supportDir).load())
        XCTAssertEqual(onDisk.coins, engine.game.coins)
        XCTAssertEqual(onDisk.coins, SaveGame.startingCoins + coins)
    }
}
