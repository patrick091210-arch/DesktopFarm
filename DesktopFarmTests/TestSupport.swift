import Foundation
import XCTest
@testable import DesktopHarvest

/// Shared fixtures: an isolated farm root + save directory per test.
@MainActor
class FarmTestCase: XCTestCase {
    var tempRoot: URL!
    var farmRoot: URL { tempRoot.appendingPathComponent("DesktopFarm", isDirectory: true) }
    var supportDir: URL { tempRoot.appendingPathComponent("Support", isDirectory: true) }
    let signer = ItemSigner(keyData: Data(repeating: 7, count: 32))

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesktopHarvestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    func makeEngine(now: Date = Date()) throws -> GameEngine {
        let engine = try GameEngine(root: farmRoot, saveManager: SaveManager(directory: supportDir), signer: signer)
        engine.start(now: now, startTimers: false)
        return engine
    }

    func folder(_ engine: GameEngine, role: FolderRole, crate: CrateCategory? = nil) throws -> URL {
        let match = engine.scan.folders(role: role).first { crate == nil || $0.marker?.crateCategory == crate }
        return try XCTUnwrap(match?.url, "missing folder for role \(role)")
    }

    @discardableResult
    func makeItem(_ engine: GameEngine, _ type: ItemType, in directory: URL, quality: Quality = .normal) throws -> URL {
        let url = try XCTUnwrap(engine.createItem(type, quality: quality, in: directory, grantProductionXP: false))
        engine.reconcile()
        return url
    }

    func files(_ engine: GameEngine, of type: ItemType) -> [ScannedFile] {
        engine.scan.files.filter { $0.payload.itemValue == type }
    }
}
