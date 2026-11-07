import Darwin
import Foundation

enum FarmFileError: LocalizedError, Equatable {
    case outsideFarm(String)
    case notGameFile(String)
    case symbolicLink(String)
    case unreadable(String)
    case notAFolder(String)
    case nameCollision(String)
    case tooLarge(String)
    case changedDuringOperation(String)
    case systemError(String, Int32)

    var errorDescription: String? {
        switch self {
        case .outsideFarm(let path): return "拒绝操作农场目录之外的文件：\(path)"
        case .notGameFile(let path): return "不是合法的游戏文件，已拒绝操作：\(path)"
        case .symbolicLink(let path): return "拒绝操作符号链接：\(path)"
        case .unreadable(let path): return "无法读取文件：\(path)"
        case .notAFolder(let path): return "不是农场内的文件夹：\(path)"
        case .nameCollision(let path): return "文件名冲突：\(path)"
        case .tooLarge(let path): return "文件过大，拒绝读取：\(path)"
        case .changedDuringOperation(let path): return "文件在操作过程中被替换，已中止：\(path)"
        case let .systemError(path, code): return "文件操作失败（\(String(cString: strerror(code)))）：\(path)"
        }
    }
}

/// Device + inode pair that pins "the exact file we validated".
struct FileIdentity: Hashable, Sendable {
    var device: UInt64
    var inode: UInt64

    init(_ info: stat) {
        device = UInt64(bitPattern: Int64(info.st_dev))
        inode = UInt64(info.st_ino)
    }

    /// Identity of the directory entry at `path` without following symlinks.
    static func of(_ path: String) -> (identity: FileIdentity, mode: mode_t)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return (FileIdentity(info), info.st_mode & S_IFMT)
    }
}

/// Bounded, symlink-refusing, non-blocking file reader.
///
/// `open(O_NOFOLLOW | O_NONBLOCK)` + `fstat` on the *same descriptor* removes the
/// check-then-read race: a file swapped for a symlink, FIFO, device or a multi-GB
/// blob between "check" and "read" is rejected, and at most `maxBytes + 1` bytes
/// are ever read into memory.
enum SafeFileReader {
    static func read(_ path: String, maxBytes: Int) throws -> (data: Data, identity: FileIdentity) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ELOOP { throw FarmFileError.symbolicLink(path) }
            throw FarmFileError.unreadable(path)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw FarmFileError.unreadable(path) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw FarmFileError.notGameFile(path) }
        guard info.st_size <= off_t(maxBytes) else { throw FarmFileError.tooLarge(path) }

        let capacity = maxBytes + 1
        var buffer = [UInt8](repeating: 0, count: capacity)
        var total = 0
        while total < capacity {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress! + total, capacity - total)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FarmFileError.unreadable(path)
            }
            if count == 0 { break }
            total += count
        }
        guard total <= maxBytes else { throw FarmFileError.tooLarge(path) }
        return (Data(buffer[0..<total]), FileIdentity(info))
    }
}

/// The single safety guard for every destructive file operation.
///
/// A file may only be rewritten, renamed, moved or deleted when:
/// 1. its symlink-resolved path is strictly inside the farm root,
/// 2. it is a regular file (never a symlink),
/// 3. it carries one of the game suffixes (`.seed .crop .tree .item .pet .tool`),
/// 4. it decodes as a `DesktopHarvest/1` JSON payload.
///
/// Destructive primitives (`unlinkValidated`, `renameValidated`) re-check that the
/// directory entry is still the exact file that was validated (device + inode) and
/// use `unlink(2)` / `renamex_np(2)`, which never recurse into directories and never
/// follow symlinks.
struct FarmSandbox: Sendable {
    static let maxGameFileSize = 64 * 1024
    static let maxMarkerSize = 16 * 1024

    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func defaultRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["DESKTOP_HARVEST_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        return desktop.appendingPathComponent("DesktopFarm", isDirectory: true)
    }

    private var rootPrefix: String { root.path.hasSuffix("/") ? root.path : root.path + "/" }

    func resolved(_ url: URL) -> URL {
        // Resolve the parent so that the final component itself is not followed.
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent)
    }

    /// True when `url` is strictly inside the farm root (never the root itself).
    func contains(_ url: URL) -> Bool {
        resolved(url).path.hasPrefix(rootPrefix)
    }

    func relativePath(for url: URL) -> String? {
        let path = resolved(url).path
        guard path.hasPrefix(rootPrefix) else { return nil }
        return String(path.dropFirst(rootPrefix.count))
    }

    func isSymlink(_ url: URL) -> Bool {
        FileIdentity.of(url.path)?.mode == S_IFLNK
    }

    func isDirectory(_ url: URL) -> Bool {
        FileIdentity.of(url.path)?.mode == S_IFDIR
    }

    func isRegularFile(_ url: URL) -> Bool {
        FileIdentity.of(url.path)?.mode == S_IFREG
    }

    // MARK: - Validation

    /// Validates `url` as a mutable game file and returns its decoded payload.
    @discardableResult
    func validateGameFile(_ url: URL) throws -> GameFilePayload {
        try validatedGameFile(url).payload
    }

    /// Validates `url` and also returns the identity of the exact file that was read.
    func validatedGameFile(_ url: URL) throws -> (payload: GameFilePayload, identity: FileIdentity) {
        guard contains(url) else { throw FarmFileError.outsideFarm(url.path) }
        guard GameFileKind.allExtensions.contains(url.pathExtension.lowercased()) else {
            throw FarmFileError.notGameFile(url.path)
        }
        let path = resolved(url).path
        let (payload, identity) = try Self.decodePayloadWithIdentity(atPath: path)
        guard payload.kind.fileExtension == url.pathExtension.lowercased() else {
            throw FarmFileError.notGameFile(url.path)
        }
        return (payload, identity)
    }

    /// Validates `url` as a folder inside the farm (never the root itself).
    func validateFolder(_ url: URL) throws {
        guard contains(url) else { throw FarmFileError.outsideFarm(url.path) }
        guard !isSymlink(url), isDirectory(url) else { throw FarmFileError.notAFolder(url.path) }
    }

    /// Validates a directory that may receive new files: the root or a folder inside it.
    func validateDestination(_ url: URL) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == root.path { return }
        try validateFolder(url)
    }

    static func decodePayload(at url: URL) throws -> GameFilePayload {
        try decodePayloadWithIdentity(atPath: url.path).payload
    }

    static func decodePayloadWithIdentity(atPath path: String) throws -> (payload: GameFilePayload, identity: FileIdentity) {
        let (data, identity) = try SafeFileReader.read(path, maxBytes: maxGameFileSize)
        guard let payload = try? GameJSON.decoder().decode(GameFilePayload.self, from: data),
              payload.format == GameFilePayload.formatTag else {
            throw FarmFileError.notGameFile(path)
        }
        return (payload, identity)
    }

    // MARK: - Identity-pinned destructive primitives

    /// Throws unless the entry at `path` is still the regular file `identity`.
    func requireSame(_ path: String, _ identity: FileIdentity) throws {
        guard let current = FileIdentity.of(path), current.mode == S_IFREG, current.identity == identity else {
            throw FarmFileError.changedDuringOperation(path)
        }
    }

    /// Deletes a validated game file. `unlink(2)` can never remove a directory and
    /// never follows a symlink, so a swap after validation cannot cause collateral loss.
    func unlinkValidated(_ url: URL, identity: FileIdentity) throws {
        let path = resolved(url).path
        try requireSame(path, identity)
        guard unlink(path) == 0 else { throw FarmFileError.systemError(path, errno) }
    }

    /// Renames a validated game file to `target`, never overwriting an existing entry.
    func renameValidated(_ url: URL, identity: FileIdentity, to target: URL) throws {
        let source = resolved(url).path
        let destination = resolved(target).path
        guard destination.hasPrefix(rootPrefix) else { throw FarmFileError.outsideFarm(destination) }
        try requireSame(source, identity)
        guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw FarmFileError.nameCollision(destination) }
            throw FarmFileError.systemError(source, errno)
        }
    }
}
