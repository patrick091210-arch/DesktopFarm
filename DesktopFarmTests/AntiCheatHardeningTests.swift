import Darwin
import Foundation
import XCTest
@testable import DesktopHarvest

/// Regression tests for audit findings S4–S7.
@MainActor
final class AntiCheatHardeningTests: FarmTestCase {
    // S4: a copy that appears before the debounced reconcile must not steal the identity.
    func testRescanBeforeReconcileDoesNotPunishTheOriginal() throws {
        let engine = try makeEngine()
        let original = try makeItem(engine, .apple, in: farmRoot)
        let copy = farmRoot.appendingPathComponent("Apple copy.item")
        try FileManager.default.copyItem(at: original, to: copy)

        engine.rescan() // e.g. a tick harvesting something while the watcher is still debouncing
        engine.reconcile()

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "original stays genuine")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the copy withers")
        XCTAssertEqual(files(engine, of: .apple).map(\.url.lastPathComponent), [original.lastPathComponent])
    }

    func testRescanFollowsGenuineMoves() throws {
        let engine = try makeEngine()
        let crate = try folder(engine, role: .crate, crate: .produce)
        let item = try makeItem(engine, .apple, in: farmRoot)
        let id = try XCTUnwrap(engine.fs.readPayload(at: item)?.id)
        _ = try engine.fs.move(item, into: crate)
        engine.rescan()
        XCTAssertTrue(try XCTUnwrap(engine.game.ledger.first { $0.id == id }).relativePath.hasPrefix(crate.lastPathComponent))
    }

    // S5: resurrection of a sold item is caught even after the spent-id list forgot it.
    func testResurrectedItemWithersEvenWithoutSpentIDs() throws {
        let engine = try makeEngine()
        let bin = try folder(engine, role: .shippingBin)
        let url = try makeItem(engine, .milk, in: bin)
        let backup = tempRoot.appendingPathComponent("milk-backup.item")
        try FileManager.default.copyItem(at: url, to: backup)
        XCTAssertGreaterThan(engine.shipNow(), 0)
        engine.game.spentIDs.removeAll() // simulate the fast-path list having been trimmed
        engine.save()
        // Model a later autosave: the window only covers files older than (lastSave - 5 s).
        engine.game.lastSavedAt = Date().addingTimeInterval(10)

        try FileManager.default.copyItem(at: backup, to: farmRoot.appendingPathComponent("Milk_restored.item"))
        engine.reconcile()
        XCTAssertEqual(files(engine, of: .milk).count, 0)
        XCTAssertEqual(files(engine, of: .witheredClone).count, 1)
    }

    func testItemsFromBeforeThisSaveAreStillAdopted() throws {
        // A save lost/reset while files remain: files older than the save are adopted.
        let oldPayload = signer.sign(GameFilePayload(
            kind: .item, itemType: ItemType.egg.rawValue, timestamp: Date().addingTimeInterval(-86_400).timeIntervalSince1970))
        try FileManager.default.createDirectory(at: farmRoot, withIntermediateDirectories: true)
        try GameJSON.encoder().encode(oldPayload).write(to: farmRoot.appendingPathComponent("Egg_OLD1.item"))
        let engine = try makeEngine()
        XCTAssertEqual(files(engine, of: .egg).count, 1)
        XCTAssertEqual(files(engine, of: .witheredClone).count, 0)
    }

    func testFileTakenOutAndBroughtBackStaysGenuine() throws {
        let engine = try makeEngine()
        let item = try makeItem(engine, .apple, in: farmRoot)
        engine.save()
        let outside = tempRoot.appendingPathComponent(item.lastPathComponent)
        try FileManager.default.moveItem(at: item, to: outside)
        engine.reconcile()
        XCTAssertEqual(files(engine, of: .apple).count, 0)
        try FileManager.default.moveItem(at: outside, to: item)
        engine.reconcile()
        XCTAssertEqual(files(engine, of: .apple).count, 1, "remembered in the ledger, not treated as resurrected")
        XCTAssertEqual(files(engine, of: .witheredClone).count, 0)
    }

    // S6: icon writes never change the inode, so they can never trigger clone punishment.
    func testIconWriteKeepsInodeAndGenuineness() throws {
        let engine = try makeEngine()
        let item = try makeItem(engine, .apple, in: farmRoot)
        let before = engine.fs.inode(of: item)
        let image = try XCTUnwrap(ProceduralIconRenderer.cgImage(for: IconSpec(body: .item(emoji: "🍎", quality: 1, processed: false))))
        XCTAssertTrue(IconWriter.apply(icns: try XCTUnwrap(IconWriter.icnsData(from: image)), to: item.path))
        XCTAssertEqual(engine.fs.inode(of: item), before)
        engine.reconcile()
        XCTAssertEqual(files(engine, of: .apple).count, 1)
        XCTAssertEqual(engine.game.stats.clonesCaught, 0)
    }

    // S7: our own writes never wake the watcher (no icon → FSEvents → rescan loop);
    // writes by another process do.
    func testWatcherIgnoresSelfWritesButSeesExternalOnes() async throws {
        try FileManager.default.createDirectory(at: farmRoot, withIntermediateDirectories: true)
        let watcher = DirectoryWatcher(debounceInterval: 0.1)
        var hits = 0
        XCTAssertTrue(watcher.start(root: farmRoot) { hits += 1 })
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let ownFile = farmRoot.appendingPathComponent("Own.item")
        try Data("{}".utf8).write(to: ownFile)
        let image = try XCTUnwrap(ProceduralIconRenderer.cgImage(for: IconSpec(body: .clone)))
        _ = IconWriter.apply(icns: try XCTUnwrap(IconWriter.icnsData(from: image)), to: ownFile.path)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(hits, 0, "self-generated events are ignored")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = [farmRoot.appendingPathComponent("External.item").path]
        try process.run()
        process.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        while hits == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(hits, 0, "external changes are delivered")
    }
}
