import Foundation

/// Where a scanned file currently lives.
enum ContainerRole: String, Sendable, Equatable {
    case field
    case crate
    case machine
    case processing
    case shippingBin
    case orderBox
    case trough

    init(folderRole: FolderRole) {
        switch folderRole {
        case .crate: self = .crate
        case .machine: self = .machine
        case .shippingBin: self = .shippingBin
        case .orderBox: self = .orderBox
        case .trough: self = .trough
        }
    }
}

/// One game file found on disk.
struct ScannedFile: Sendable, Identifiable, Equatable {
    var url: URL
    var relativePath: String
    /// Relative path of the containing directory ("" for the farm root).
    var directory: String
    var payload: GameFilePayload
    var inode: UInt64
    var signatureValid: Bool
    var role: ContainerRole
    /// Marker id of the managed folder that contains the file, if any.
    var folderID: UUID?
    var creationDate: Date

    var id: String { relativePath }
    var name: String { url.lastPathComponent }
}

/// One top-level folder found in the farm.
struct ScannedFolder: Sendable, Identifiable, Equatable {
    var url: URL
    var name: String
    var marker: FolderMarker?
    /// True when another folder already uses the same marker id (a Finder copy).
    var isDuplicate: Bool
    /// Plain folder whose name looks like a crate ("筐" / "crate"), waiting for a marker.
    var wantsCrateMarker: Bool

    var id: String { url.path }
    var role: FolderRole? { isDuplicate ? nil : marker?.role }
}

struct FarmScan: Sendable, Equatable {
    var files: [ScannedFile]
    var folders: [ScannedFolder]
    var malformed: [String]
    var scannedAt: Date

    static let empty = FarmScan(files: [], folders: [], malformed: [], scannedAt: .distantPast)

    func folder(id: UUID) -> ScannedFolder? {
        folders.first { $0.marker?.id == id && !$0.isDuplicate }
    }

    func files(inFolder id: UUID, role: ContainerRole? = nil) -> [ScannedFile] {
        files.filter { $0.folderID == id && (role == nil || $0.role == role) }
    }

    func folders(role: FolderRole) -> [ScannedFolder] {
        folders.filter { $0.role == role }
    }

    func file(id: UUID) -> ScannedFile? {
        files.first { $0.payload.id == id }
    }
}

/// Walks the farm root and decodes every game file and managed folder.
struct FarmScanner: Sendable {
    let fileSystem: FarmFileSystem
    var maxFieldDepth = 2

    private var sandbox: FarmSandbox { fileSystem.sandbox }

    func scan(now: Date = Date()) -> FarmScan {
        var result = FarmScan(files: [], folders: [], malformed: [], scannedAt: now)
        let root = sandbox.root
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return result
        }
        var seenMarkerIDs = Set<UUID>()
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            if Self.isIgnoredName(name) || sandbox.isSymlink(child) { continue }
            if sandbox.isDirectory(child) {
                let marker = fileSystem.readMarker(in: child).flatMap { fileSystem.signer.isValid($0) ? $0 : nil }
                var duplicate = false
                if let marker {
                    duplicate = seenMarkerIDs.contains(marker.id)
                    seenMarkerIDs.insert(marker.id)
                }
                let lower = name.lowercased()
                let wantsCrate = marker == nil && (name.contains("筐") || lower.contains("crate"))
                let folder = ScannedFolder(url: child, name: name, marker: marker, isDuplicate: duplicate, wantsCrateMarker: wantsCrate)
                result.folders.append(folder)
                if let role = folder.role, let marker {
                    collect(in: child, role: ContainerRole(folderRole: role), folderID: marker.id, depth: 0, maxDepth: 0, into: &result)
                    if role == .machine {
                        let processing = child.appendingPathComponent(".processing")
                        if sandbox.isDirectory(processing) {
                            collect(in: processing, role: .processing, folderID: marker.id, depth: 0, maxDepth: 0, into: &result)
                        }
                    }
                } else if !wantsCrate {
                    collect(in: child, role: .field, folderID: nil, depth: 1, maxDepth: maxFieldDepth, into: &result)
                }
            } else {
                appendFile(child, role: .field, folderID: nil, into: &result)
            }
        }
        return result
    }

    private func collect(
        in directory: URL,
        role: ContainerRole,
        folderID: UUID?,
        depth: Int,
        maxDepth: Int,
        into result: inout FarmScan
    ) {
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            if Self.isIgnoredName(name) || sandbox.isSymlink(child) { continue }
            if sandbox.isDirectory(child) {
                if depth < maxDepth && role == .field {
                    collect(in: child, role: .field, folderID: nil, depth: depth + 1, maxDepth: maxDepth, into: &result)
                }
            } else {
                appendFile(child, role: role, folderID: folderID, into: &result)
            }
        }
    }

    private func appendFile(_ url: URL, role: ContainerRole, folderID: UUID?, into result: inout FarmScan) {
        guard GameFileKind.allExtensions.contains(url.pathExtension.lowercased()) else { return }
        guard let relative = sandbox.relativePath(for: url) else { return }
        guard let (payload, identity) = try? sandbox.validatedGameFile(url) else {
            result.malformed.append(relative)
            return
        }
        let directory = (relative as NSString).deletingLastPathComponent
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = (attributes?[.creationDate] as? Date) ?? Date()
        let file = ScannedFile(
            url: url,
            relativePath: relative,
            directory: directory,
            payload: payload,
            // Inode of the exact descriptor that was read, not a second racy lookup.
            inode: identity.inode,
            signatureValid: fileSystem.signer.isValid(payload),
            role: role,
            folderID: folderID,
            creationDate: created
        )
        result.files.append(file)
    }

    static func isIgnoredName(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "Icon\r"
    }
}
