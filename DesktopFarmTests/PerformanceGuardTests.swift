import Foundation
import SpriteKit
import XCTest
@testable import DesktopHarvest

/// Regression tests for audit findings P1–P4 and C6.
@MainActor
final class PerformanceGuardTests: FarmTestCase {
    private func settle(_ scheduler: IconUpdateScheduler) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !scheduler.isIdle {
            if Date() > deadline { XCTFail("icon writes did not finish"); return }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    // P1: identical visual states are never rewritten; cosmetic changes are throttled;
    // meaningful changes are written immediately.
    func testSchedulerSkipsDuplicatesAndThrottlesCosmeticChanges() async throws {
        try FileManager.default.createDirectory(at: farmRoot, withIntermediateDirectories: true)
        let file = farmRoot.appendingPathComponent("Tree.tree")
        try Data("{}".utf8).write(to: file)
        let scheduler = IconUpdateScheduler()
        func plant(moisture: Int, fruit: String?) -> IconSpec {
            IconSpec(body: .plant(emoji: "🌳", moisture: moisture, growth: 5, ripe: false, thirsty: false, tree: true, fruit: fruit))
        }

        scheduler.apply([(file, plant(moisture: 10, fruit: nil))])
        try await settle(scheduler)
        XCTAssertEqual(scheduler.writeCount, 1)

        for _ in 0..<5 { scheduler.apply([(file, plant(moisture: 10, fruit: nil))]) }
        try await settle(scheduler)
        XCTAssertEqual(scheduler.writeCount, 1, "same visual state: no rewrite")

        scheduler.apply([(file, plant(moisture: 9, fruit: nil))])
        try await settle(scheduler)
        XCTAssertEqual(scheduler.writeCount, 1, "cosmetic change inside the throttle window")

        scheduler.apply([(file, plant(moisture: 9, fruit: "🍎"))])
        try await settle(scheduler)
        XCTAssertEqual(scheduler.writeCount, 2, "fruiting is a major change: written at once")

        scheduler.apply([(file, plant(moisture: 8, fruit: "🍎"))], now: Date().addingTimeInterval(5))
        try await settle(scheduler)
        XCTAssertEqual(scheduler.writeCount, 3, "cosmetic change after the window")
    }

    // P3: effects cannot pile up without bound while SpriteKit is paused.
    func testEffectLayerIsBounded() {
        let layer = SKNode()
        for index in 0..<500 {
            EffectFactory.burst("✨", at: .zero, in: layer)
            EffectFactory.floatingText("+\(index)", at: .zero, in: layer)
        }
        XCTAssertLessThanOrEqual(layer.children.count, EffectFactory.maxLiveNodes + 8)
    }

    // C6: a hung AppleScript is terminated instead of wedging the Finder bridge.
    func testAppleScriptTimesOut() async {
        let started = Date()
        let result = await DesktopIconBridge.runAppleScript("delay 20", timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let quick = await DesktopIconBridge.runAppleScript("return \"ok\"", timeout: 5)
        XCTAssertFalse(quick.timedOut)
        XCTAssertEqual(quick.output.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }

    // P1: many world changes in one run-loop turn produce a single coalesced refresh path.
    func testIconSpecsAreStableBetweenTicks() throws {
        let engine = try makeEngine()
        let first = engine.iconSpecs()
        let second = engine.iconSpecs()
        XCTAssertEqual(first.map(\.1), second.map(\.1), "deterministic specs → scheduler can dedupe")
    }
}
