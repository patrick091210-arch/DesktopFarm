import Darwin
import Foundation
import XCTest
@testable import DesktopHarvest

/// Regression tests for audit findings S1–S3 (bounded reads, FIFO hangs, TOCTOU deletes).
@MainActor
final class SandboxHardeningTests: FarmTestCase {
    private var sandbox: FarmSandbox { FarmSandbox(root: farmRoot) }
    private var fs: FarmFileSystem { FarmFileSystem(sandbox: sandbox, signer: signer) }

    override func setUp() async throws {
        try await super.setUp()
        try FileManager.default.createDirectory(at: farmRoot, withIntermediateDirectories: true)
    }

    private func signedItem(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? farmRoot).appendingPathComponent(name)
        let payload = signer.sign(GameFilePayload(kind: .item, itemType: ItemType.apple.rawValue))
        try GameJSON.encoder().encode(payload).write(to: url)
        return url
    }

    // S1: oversized files are rejected by fstat on the open descriptor, never read whole.
    func testOversizedGameFileIsRejectedWithoutReading() throws {
        let huge = farmRoot.appendingPathComponent("Huge.item")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024) // 4 GB sparse file
        try handle.close()

        XCTAssertThrowsError(try sandbox.validateGameFile(huge)) { error in
            XCTAssertEqual(error as? FarmFileError, .tooLarge(huge.path))
        }
        let scan = FarmScanner(fileSystem: fs).scan()
        XCTAssertEqual(scan.malformed, ["Huge.item"])
        XCTAssertThrowsError(try fs.delete(huge), "reset/cleanup must refuse it too")
        XCTAssertTrue(FileManager.default.fileExists(atPath: huge.path))
    }

    // S1/S2: FIFOs (as a game file or as a folder marker) must not block the scanner.
    func testFifosNeverBlockTheScanner() throws {
        let fifoItem = farmRoot.appendingPathComponent("Pipe.item")
        XCTAssertEqual(mkfifo(fifoItem.path, 0o644), 0)
        let folder = farmRoot.appendingPathComponent("📦木筐")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(folder.appendingPathComponent(FolderMarker.fileName).path, 0o644), 0)

        let started = Date()
        let scan = FarmScanner(fileSystem: fs).scan()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "scan returned promptly")
        XCTAssertEqual(scan.malformed, ["Pipe.item"])
        XCTAssertNil(fs.readMarker(in: folder))
        XCTAssertThrowsError(try fs.delete(fifoItem))
    }

    func testSymlinkedGameFileIsNeverRead() throws {
        let outside = try signedItem("outside.item", in: tempRoot)
        let link = farmRoot.appendingPathComponent("Link.item")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try sandbox.validateGameFile(link)) { error in
            XCTAssertEqual(error as? FarmFileError, .symbolicLink(link.path))
        }
    }

    // S3: a file swapped for a directory after validation is never deleted recursively.
    func testSwapToDirectoryAfterValidationCannotDeleteUserData() throws {
        let item = try signedItem("Apple_AAAA.item")
        let (_, identity) = try sandbox.validatedGameFile(item)

        try FileManager.default.removeItem(at: item)
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: false)
        let precious = item.appendingPathComponent("thesis.docx")
        try Data("user data".utf8).write(to: precious)

        XCTAssertThrowsError(try sandbox.unlinkValidated(item, identity: identity)) { error in
            XCTAssertEqual(error as? FarmFileError, .changedDuringOperation(item.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path))
    }

    func testSwapToAnotherFileAfterValidationIsDetected() throws {
        let item = try signedItem("Apple_BBBB.item")
        let (_, identity) = try sandbox.validatedGameFile(item)
        try FileManager.default.removeItem(at: item)
        try Data("replacement".utf8).write(to: item)
        XCTAssertThrowsError(try sandbox.unlinkValidated(item, identity: identity))
        XCTAssertThrowsError(try sandbox.renameValidated(item, identity: identity, to: farmRoot.appendingPathComponent("x.item")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testMoveNeverOverwritesAnExistingEntry() throws {
        let folder = farmRoot.appendingPathComponent("Box")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let item = try signedItem("Apple_CCCC.item")
        let squatter = folder.appendingPathComponent("Apple_CCCC.item")
        try Data("user file".utf8).write(to: squatter)

        let (_, identity) = try sandbox.validatedGameFile(item)
        XCTAssertThrowsError(try sandbox.renameValidated(item, identity: identity, to: squatter)) { error in
            XCTAssertEqual(error as? FarmFileError, .nameCollision(squatter.path))
        }
        let moved = try fs.move(item, into: folder)
        XCTAssertNotEqual(moved.lastPathComponent, squatter.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: squatter), Data("user file".utf8))
    }

    // S3: folder cleanup never recurses, even into an `Icon\r` that is really a directory.
    func testFolderCleanupNeverRecurses() throws {
        let folder = farmRoot.appendingPathComponent("💰出货箱")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent(FolderMarker.fileName))
        let fakeIcon = folder.appendingPathComponent("Icon\r")
        try FileManager.default.createDirectory(at: fakeIcon, withIntermediateDirectories: true)
        let hidden = fakeIcon.appendingPathComponent(".secret")
        try Data("user".utf8).write(to: hidden)

        fs.removeManagedFolderIfEmpty(folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hidden.path))

        // A genuinely empty managed folder (marker + icon file only) is removed.
        let empty = farmRoot.appendingPathComponent("📋订单交付箱")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: empty.appendingPathComponent(FolderMarker.fileName))
        try Data().write(to: empty.appendingPathComponent("Icon\r"))
        fs.removeManagedFolderIfEmpty(empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))

        // A hidden user file keeps the folder alive.
        let kept = farmRoot.appendingPathComponent("📦木筐")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("u".utf8).write(to: kept.appendingPathComponent(".my-notes"))
        fs.removeManagedFolderIfEmpty(kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.appendingPathComponent(".my-notes").path))
    }
}
