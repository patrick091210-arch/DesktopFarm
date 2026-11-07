import Foundation
import XCTest
@testable import DesktopHarvest

@MainActor
final class IconWriterTests: FarmTestCase {
    private func icns() throws -> Data {
        let spec = IconSpec(body: .crate(fill: 2, emojis: ["🍎"], count: 6))
        let image = try XCTUnwrap(ProceduralIconRenderer.cgImage(for: spec))
        return try XCTUnwrap(IconWriter.icnsData(from: image))
    }

    func testResourceForkLayout() throws {
        let body = Data("icns-body".utf8)
        let fork = IconWriter.resourceFork(icns: body)
        XCTAssertEqual(fork.count, 256 + 4 + body.count + 50)
        let mapOffset = fork[4..<8].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(mapOffset, 256 + 4 + body.count)
        XCTAssertEqual(String(data: fork[(mapOffset + 30)..<(mapOffset + 34)], encoding: .ascii), "icns")
        XCTAssertEqual(fork[(mapOffset + 38)..<(mapOffset + 40)], Data([0xBF, 0xB9]), "resource id -16455")
    }

    func testFileIconIsWrittenInPlace() throws {
        try FileManager.default.createDirectory(at: farmRoot, withIntermediateDirectories: true)
        let file = farmRoot.appendingPathComponent("Tree.tree")
        try Data("{}".utf8).write(to: file)
        XCTAssertFalse(IconWriter.hasCustomIcon(at: file.path))
        let data = try icns()
        XCTAssertTrue(IconWriter.apply(icns: data, to: file.path))
        XCTAssertTrue(IconWriter.hasCustomIcon(at: file.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8), "data fork untouched")
    }

    func testFolderIconReusesIconFile() throws {
        let folder = farmRoot.appendingPathComponent("📦木筐", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try icns()
        XCTAssertTrue(IconWriter.apply(icns: data, to: folder.path))
        let iconFile = folder.appendingPathComponent("Icon\r").path
        let firstInode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: iconFile)[.systemFileNumber] as? NSNumber)
        XCTAssertTrue(IconWriter.apply(icns: data, to: folder.path))
        let secondInode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: iconFile)[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(firstInode, secondInode, "Icon\\r is never deleted and re-created")
        XCTAssertTrue(IconWriter.hasCustomIcon(at: folder.path))
    }

    func testCosmeticChangesShareMajorKey() {
        let a = IconSpec(body: .plant(emoji: "🌳", moisture: 10, growth: 3, ripe: false, thirsty: false, tree: true, fruit: nil))
        let b = IconSpec(body: .plant(emoji: "🌳", moisture: 9, growth: 4, ripe: false, thirsty: false, tree: true, fruit: nil))
        let fruiting = IconSpec(body: .plant(emoji: "🌳", moisture: 9, growth: 4, ripe: false, thirsty: false, tree: true, fruit: "🍎"))
        XCTAssertEqual(a.majorKey, b.majorKey)
        XCTAssertNotEqual(a.majorKey, fruiting.majorKey)

        let crateFew = IconSpec(body: .crate(fill: 1, emojis: ["🍎"], count: 2))
        let crateMore = IconSpec(body: .crate(fill: 1, emojis: ["🍎"], count: 3))
        let crateEmpty = IconSpec(body: .crate(fill: 0, emojis: [], count: 0))
        XCTAssertEqual(crateFew.majorKey, crateMore.majorKey)
        XCTAssertNotEqual(crateFew.majorKey, crateEmpty.majorKey)
    }

    func testSchedulerHealsMissingFolderIcon() async throws {
        let folder = farmRoot.appendingPathComponent("💰出货箱", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scheduler = IconUpdateScheduler()
        scheduler.verifyInterval = 0 // re-verify on every pass for the test
        let spec = IconSpec(body: .shippingBin(value: 0, count: 0))
        scheduler.apply([(folder, spec)])
        try await waitUntil { IconWriter.hasCustomIcon(at: folder.path) }

        // Simulate the icon being lost (reset, external tool): same spec, so a
        // spec-only cache would never repaint it.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Icon\r"))
        XCTAssertFalse(IconWriter.hasCustomIcon(at: folder.path))
        scheduler.apply([(folder, spec)])
        try await waitUntil { IconWriter.hasCustomIcon(at: folder.path) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
