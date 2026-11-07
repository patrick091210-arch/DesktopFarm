import Foundation
import XCTest
@testable import DesktopHarvest

@MainActor
final class SecurityTests: FarmTestCase {
    func testSignatureRoundTripAndTamperDetection() {
        let payload = signer.sign(GameFilePayload(kind: .item, itemType: ItemType.apple.rawValue, quality: 2))
        XCTAssertTrue(signer.isValid(payload))

        var forged = payload
        forged.quality = 3
        XCTAssertFalse(signer.isValid(forged), "editing quality must break the HMAC")

        var retyped = payload
        retyped.itemType = ItemType.cake.rawValue
        XCTAssertFalse(signer.isValid(retyped))

        let otherSigner = ItemSigner(keyData: Data(repeating: 9, count: 32))
        XCTAssertFalse(otherSigner.isValid(payload), "another install's key must not validate")
    }

    func testCopiedItemWithersIntoClone() throws {
        let engine = try makeEngine()
        let original = try makeItem(engine, .apple, in: farmRoot)
        let copy = farmRoot.appendingPathComponent("Apple copy.item")
        try FileManager.default.copyItem(at: original, to: copy)
        engine.reconcile()

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "the original keeps its identity")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "the copy is rewritten")
        XCTAssertEqual(files(engine, of: .apple).count, 1)
        XCTAssertEqual(files(engine, of: .witheredClone).count, 1)
        XCTAssertEqual(engine.game.stats.clonesCaught, 1)
    }

    func testEditedItemWithersAndMovedItemStaysGenuine() throws {
        let engine = try makeEngine()
        let crate = try folder(engine, role: .crate, crate: .produce)
        let edited = try makeItem(engine, .carrot, in: farmRoot)
        let moved = try makeItem(engine, .apple, in: farmRoot)

        var payload = try XCTUnwrap(engine.fs.readPayload(at: edited))
        payload.quality = 3
        try GameJSON.encoder().encode(payload).write(to: edited)
        let movedTarget = crate.appendingPathComponent(moved.lastPathComponent)
        try FileManager.default.moveItem(at: moved, to: movedTarget)
        engine.reconcile()

        XCTAssertEqual(files(engine, of: .carrot).count, 0)
        XCTAssertEqual(files(engine, of: .witheredClone).count, 1)
        XCTAssertEqual(files(engine, of: .apple).first?.role, .crate)
        XCTAssertEqual(engine.crates.first { $0.category == .produce }?.counts[.apple], 1)
    }

    func testSpentItemCannotBeResurrected() throws {
        let engine = try makeEngine()
        let bin = try folder(engine, role: .shippingBin)
        let url = try makeItem(engine, .egg, in: bin)
        let backup = tempRoot.appendingPathComponent("egg-backup.item")
        try FileManager.default.copyItem(at: url, to: backup)
        XCTAssertGreaterThan(engine.shipNow(), 0)
        try FileManager.default.copyItem(at: backup, to: farmRoot.appendingPathComponent("restored.item"))
        engine.reconcile()
        XCTAssertEqual(files(engine, of: .egg).count, 0)
        XCTAssertEqual(files(engine, of: .witheredClone).count, 1)
    }

    func testSandboxRejectsForeignFiles() throws {
        let engine = try makeEngine()
        let outside = tempRoot.appendingPathComponent("outside.item")
        let signed = signer.sign(GameFilePayload(kind: .item, itemType: ItemType.apple.rawValue))
        try GameJSON.encoder().encode(signed).write(to: outside)
        XCTAssertThrowsError(try engine.fs.delete(outside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        let userFile = farmRoot.appendingPathComponent("My Notes.txt")
        try Data("hello".utf8).write(to: userFile)
        XCTAssertThrowsError(try engine.fs.delete(userFile))

        let fakeItem = farmRoot.appendingPathComponent("Fake.item")
        try Data("not json".utf8).write(to: fakeItem)
        XCTAssertThrowsError(try engine.fs.delete(fakeItem))

        let link = farmRoot.appendingPathComponent("Link.item")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try engine.fs.delete(link))

        engine.resetGame()
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path), "reset never touches user files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakeItem.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
