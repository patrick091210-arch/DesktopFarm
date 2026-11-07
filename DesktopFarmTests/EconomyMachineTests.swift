import Foundation
import XCTest
@testable import DesktopHarvest

@MainActor
final class EconomyMachineTests: FarmTestCase {
    func testJamMakerProcessesDroppedApples() throws {
        let engine = try makeEngine()
        let machine = try XCTUnwrap(engine.machineViews.first { $0.type == .jamMaker })
        try makeItem(engine, .apple, in: machine.url, quality: .gold)
        try makeItem(engine, .apple, in: machine.url, quality: .silver)

        let working = try XCTUnwrap(engine.machineViews.first { $0.id == machine.id })
        XCTAssertEqual(working.status, .working)
        XCTAssertEqual(engine.scan.files(inFolder: machine.id, role: .processing).count, 2, "inputs are locked in .processing")

        engine.advanceWorld(dt: 25, now: Date(), offline: false)
        let done = try XCTUnwrap(engine.machineViews.first { $0.id == machine.id })
        XCTAssertEqual(done.status, .ready)
        XCTAssertEqual(files(engine, of: .apple).count, 0, "raw apples destroyed")
        let jam = try XCTUnwrap(files(engine, of: .appleJam).first)
        XCTAssertEqual(jam.payload.quality, 3, "average of gold+silver rounds to gold")
    }

    func testRecipesCoverSpec() {
        XCTAssertEqual(MachineType.bakery.firstSatisfiedRecipe(available: [.wheat: 2, .egg: 1])?.output, .cake)
        XCTAssertNil(MachineType.bakery.firstSatisfiedRecipe(available: [.wheat: 2]))
        XCTAssertEqual(MachineType.dairy.firstSatisfiedRecipe(available: [.milk: 1])?.output, .cheese)
        XCTAssertEqual(MachineType.loom.firstSatisfiedRecipe(available: [.wool: 1])?.output, .sweater)
        XCTAssertEqual(MachineType.jamMaker.firstSatisfiedRecipe(available: [.strawberry: 2])?.output, .strawberryJam)
    }

    func testShippingBinSellsAndClears() throws {
        let engine = try makeEngine()
        let bin = try folder(engine, role: .shippingBin)
        try makeItem(engine, .milk, in: bin)
        try makeItem(engine, .apple, in: bin, quality: .gold)
        let expected = ItemType.milk.basePrice + ItemType.apple.price(quality: .gold)
        XCTAssertEqual(engine.shippingValue, expected)
        let coins = engine.game.coins
        XCTAssertEqual(engine.shipNow(), expected)
        XCTAssertEqual(engine.game.coins, coins + expected)
        XCTAssertTrue(engine.shippingFiles.isEmpty)
    }

    func testOrderFulfilmentConsumesFromBoxAndCrates() throws {
        let engine = try makeEngine()
        let box = try folder(engine, role: .orderBox)
        let crate = try folder(engine, role: .crate, crate: .produce)
        let order = FarmOrder(id: UUID(), requester: "测试村民", avatar: "🧑‍🌾",
                              lines: [OrderLine(item: .apple, quantity: 3)],
                              rewardCoins: 50, rewardXP: 20, createdAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        engine.game.orders = [order]
        try makeItem(engine, .apple, in: box)
        try makeItem(engine, .apple, in: crate)
        XCTAssertFalse(engine.canFulfil(order))
        try makeItem(engine, .apple, in: crate)
        XCTAssertTrue(engine.canFulfil(order))
        let coins = engine.game.coins
        XCTAssertTrue(engine.completeOrder(order.id))
        XCTAssertEqual(engine.game.coins, coins + 50)
        XCTAssertEqual(files(engine, of: .apple).count, 0)
        XCTAssertEqual(engine.game.stats.ordersCompleted, 1)
    }

    func testShopPurchasesCreateRealFilesAndFolders() throws {
        let engine = try makeEngine()
        engine.game.coins = 1000
        XCTAssertTrue(engine.buy(.seed(.wheat)))
        XCTAssertTrue(engine.buy(.trough))
        XCTAssertFalse(engine.buy(.machine(.loom)), "level-gated")
        engine.game.xp = Progression.xpRequired(forLevel: 4)
        XCTAssertTrue(engine.buy(.machine(.loom)))
        XCTAssertTrue(engine.buy(.animal(.cow)))
        XCTAssertTrue(engine.machineViews.contains { $0.type == .loom })
        XCTAssertEqual(engine.troughFolders.count, 2)
        XCTAssertEqual(engine.game.pets.filter { $0.species == .cow }.count, 1)
        XCTAssertTrue(engine.scan.files.contains { $0.payload.kind == .pet && $0.payload.itemType == "cow" })
    }

    func testTidyMovesLooseItemsIntoMatchingCrates() throws {
        let engine = try makeEngine()
        try makeItem(engine, .apple, in: farmRoot)
        try makeItem(engine, .egg, in: farmRoot)
        XCTAssertEqual(engine.tidyDesktop(), 2)
        XCTAssertEqual(engine.crates.first { $0.category == .produce }?.counts[.apple], 1)
        XCTAssertEqual(engine.crates.first { $0.category == .ranch }?.counts[.egg], 1)
        XCTAssertTrue(engine.looseItems.isEmpty)
    }

    func testOrderGenerationUsesObtainableItems() {
        var rng = SystemRandomNumberGenerator()
        let pool = Set(EconomyEngine.obtainableItems(level: 1))
        for _ in 0..<50 {
            let order = EconomyEngine.generateOrder(level: 1, now: Date(), using: &rng)
            XCTAssertFalse(order.lines.isEmpty)
            XCTAssertTrue(order.lines.allSatisfy { pool.contains($0.item) })
            XCTAssertGreaterThan(order.rewardCoins, order.lines.reduce(0) { $0 + $1.item.basePrice * $1.quantity })
        }
    }

    func testSaveRoundTrip() throws {
        let engine = try makeEngine()
        engine.game.coins = 777
        engine.save()
        let reloaded = try XCTUnwrap(SaveManager(directory: supportDir).load())
        XCTAssertEqual(reloaded.coins, 777)
        XCTAssertEqual(reloaded.plants.count, engine.game.plants.count)
        XCTAssertEqual(reloaded.pets.count, engine.game.pets.count)
    }

    func testIconRendererProducesImages() {
        let specs: [IconSpec] = [
            IconSpec(body: .plant(emoji: "🌳", moisture: 10, growth: 15, ripe: false, thirsty: true, tree: true, fruit: "🍎")),
            IconSpec(body: .clone),
            IconSpec(body: .crate(fill: 3, emojis: ["🍎", "🥕"], count: 20)),
            IconSpec(body: .machine(emoji: "🫙", status: .working, progress: 40, phase: 3, ready: 0))
        ]
        for spec in specs {
            let image = ProceduralIconRenderer.image(for: spec)
            XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }
}
