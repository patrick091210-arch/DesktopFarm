import Darwin
import Foundation

/// Every create / rewrite / move / rename / delete of a farm file goes through here,
/// and every destructive call is validated by `FarmSandbox` first.
struct FarmFileSystem: Sendable {
    let sandbox: FarmSandbox
    let signer: ItemSigner

    var root: URL { sandbox.root }

    // MARK: - Reading

    func readPayload(at url: URL) -> GameFilePayload? {
        try? FarmSandbox.decodePayload(at: url)
    }

    func inode(of url: URL) -> UInt64 {
        FileIdentity.of(url.path)?.identity.inode ?? 0
    }

    func readMarker(in folder: URL) -> FolderMarker? {
        let path = folder.appendingPathComponent(FolderMarker.fileName).path
        guard let (data, _) = try? SafeFileReader.read(path, maxBytes: FarmSandbox.maxMarkerSize) else { return nil }
        return try? GameJSON.decoder().decode(FolderMarker.self, from: data)
    }

    // MARK: - Creation

    /// Creates a new signed game file in `directory` (root or a folder inside it).
    @discardableResult
    func createGameFile(
        _ payload: GameFilePayload,
        stem: String,
        in directory: URL,
        preferBareName: Bool = false
    ) throws -> (url: URL, payload: GameFilePayload) {
        try sandbox.validateDestination(directory)
        let signed = signer.sign(payload)
        let url = uniqueURL(stem: stem, id: signed.id, ext: signed.kind.fileExtension, in: directory, preferBare: preferBareName)
        let data = try GameJSON.encoder().encode(signed)
        // `.withoutOverwriting` = O_CREAT|O_EXCL: fails on any existing entry, including symlinks.
        try data.write(to: url, options: .withoutOverwriting)
        return (url, signed)
    }

    func uniqueURL(stem: String, id: UUID, ext: String, in directory: URL, preferBare: Bool) -> URL {
        func free(_ url: URL) -> Bool { FileIdentity.of(url.path) == nil }
        if preferBare {
            let bare = directory.appendingPathComponent("\(stem).\(ext)")
            if free(bare) { return bare }
        }
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "")
        for length in [4, 6, 8, 12, 32] {
            let candidate = directory.appendingPathComponent("\(stem)_\(hex.prefix(length)).\(ext)")
            if free(candidate) { return candidate }
        }
        return directory.appendingPathComponent("\(stem)_\(UUID().uuidString).\(ext)")
    }

    // MARK: - Mutation (validated + identity-pinned)

    /// Replaces a game file with a new payload, possibly changing its suffix and stem.
    @discardableResult
    func transform(_ url: URL, into payload: GameFilePayload, stem: String) throws -> (url: URL, payload: GameFilePayload) {
        let (_, identity) = try sandbox.validatedGameFile(url)
        let directory = url.deletingLastPathComponent()
        let created = try createGameFile(payload, stem: stem, in: directory)
        do {
            try sandbox.unlinkValidated(url, identity: identity)
        } catch {
            unlink(created.url.path)
            throw error
        }
        return created
    }

    func delete(_ url: URL) throws {
        let (_, identity) = try sandbox.validatedGameFile(url)
        try sandbox.unlinkValidated(url, identity: identity)
    }

    /// Moves a game file into `folder`, keeping its name unless it collides.
    @discardableResult
    func move(_ url: URL, into folder: URL) throws -> URL {
        let (payload, identity) = try sandbox.validatedGameFile(url)
        try sandbox.validateDestination(folder)
        let stem = url.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(url.lastPathComponent)
        if FileIdentity.of(target.path) != nil {
            target = uniqueURL(stem: stem, id: payload.id, ext: url.pathExtension, in: folder, preferBare: false)
        }
        for _ in 0..<4 {
            do {
                try sandbox.renameValidated(url, identity: identity, to: target)
                return target
            } catch FarmFileError.nameCollision {
                // Someone created the target between the check and the rename: pick another name.
                target = uniqueURL(stem: stem, id: UUID(), ext: url.pathExtension, in: folder, preferBare: false)
            }
        }
        throw FarmFileError.nameCollision(target.path)
    }

    // MARK: - Folders

    /// Ensures a managed folder named `name` exists in the root with a valid marker.
    @discardableResult
    func ensureManagedFolder(named name: String, marker: FolderMarker) throws -> (url: URL, marker: FolderMarker) {
        let url = root.appendingPathComponent(name, isDirectory: true)
        if sandbox.isDirectory(url) {
            if let existing = readMarker(in: url), signer.isValid(existing) {
                return (url, existing)
            }
        } else if FileIdentity.of(url.path) != nil {
            throw FarmFileError.nameCollision(url.path)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let signed = try writeMarker(marker, in: url)
        return (url, signed)
    }

    /// Creates a brand-new managed folder with a unique name.
    func createManagedFolder(baseName: String, marker: FolderMarker) throws -> (url: URL, marker: FolderMarker) {
        var name = baseName
        var counter = 2
        while FileIdentity.of(root.appendingPathComponent(name).path) != nil {
            name = "\(baseName) \(counter)"
            counter += 1
        }
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let signed = try writeMarker(marker, in: url)
        return (url, signed)
    }

    @discardableResult
    func writeMarker(_ marker: FolderMarker, in folder: URL) throws -> FolderMarker {
        try sandbox.validateFolder(folder)
        let signed = signer.sign(marker)
        let data = try GameJSON.encoder().encode(signed)
        // Atomic write = temp file + rename(2): replaces a symlink entry, never writes through it.
        try data.write(to: folder.appendingPathComponent(FolderMarker.fileName), options: .atomic)
        return signed
    }

    /// Hidden staging folder inside a machine where locked inputs wait.
    func processingFolder(in machineFolder: URL) throws -> URL {
        try sandbox.validateFolder(machineFolder)
        let url = machineFolder.appendingPathComponent(".processing", isDirectory: true)
        if !sandbox.isDirectory(url) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        return url
    }

    /// Removes a machine's `.processing/` staging folder if (and only if) it is empty.
    func removeEmptyProcessingFolder(in machineFolder: URL) {
        guard (try? sandbox.validateFolder(machineFolder)) != nil else { return }
        let processing = (sandbox.resolved(machineFolder).path as NSString).appendingPathComponent(".processing")
        guard FileIdentity.of(processing)?.mode == S_IFDIR else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: processing)) ?? []
        if entries == [".DS_Store"] {
            let store = (processing as NSString).appendingPathComponent(".DS_Store")
            if FileIdentity.of(store)?.mode == S_IFREG { unlink(store) }
        }
        rmdir(processing)
    }

    /// Removes a managed folder only if nothing but our own marker/icon files remain.
    ///
    /// Never recursive: our own entries are removed with `unlink(2)` (regular files /
    /// symlinks only) and directories with `rmdir(2)`, which fails on anything non-empty.
    /// A user file of any kind — hidden, nested, or masquerading as `Icon\r` — survives.
    func removeManagedFolderIfEmpty(_ folder: URL) {
        guard (try? sandbox.validateFolder(folder)) != nil else { return }
        let path = sandbox.resolved(folder).path
        let processing = (path as NSString).appendingPathComponent(".processing")
        if FileIdentity.of(processing)?.mode == S_IFDIR {
            rmdir(processing)
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        let ours: Set<String> = [FolderMarker.fileName, "Icon\r", ".DS_Store"]
        guard contents.allSatisfy({ ours.contains($0) }) else { return }
        for name in contents {
            let entry = (path as NSString).appendingPathComponent(name)
            guard let mode = FileIdentity.of(entry)?.mode, mode == S_IFREG || mode == S_IFLNK else { continue }
            unlink(entry)
        }
        rmdir(path)
    }
}
