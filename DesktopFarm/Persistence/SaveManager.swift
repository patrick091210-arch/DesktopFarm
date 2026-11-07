import Foundation

/// JSON coding helpers shared by game files and the save.
enum GameJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Persists the game to `~/Library/Application Support/DesktopHarvest/savegame.json`
/// with an atomic write and a one-generation backup.
struct SaveManager: Sendable {
    let directory: URL

    var saveURL: URL { directory.appendingPathComponent("savegame.json") }
    var backupURL: URL { directory.appendingPathComponent("savegame.backup.json") }
    var keyURL: URL { directory.appendingPathComponent("signing.key") }

    static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["DESKTOP_HARVEST_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DesktopHarvest", isDirectory: true)
    }

    init(directory: URL = SaveManager.defaultDirectory()) {
        self.directory = directory
    }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads the primary save, falling back to the backup if it is corrupt.
    func load() -> SaveGame? {
        for url in [saveURL, backupURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let game = try? GameJSON.decoder().decode(SaveGame.self, from: data),
               game.version <= SaveGame.currentVersion {
                return game
            }
        }
        return nil
    }

    func save(_ game: SaveGame) throws {
        try ensureDirectory()
        let data = try GameJSON.encoder().encode(game)
        let fm = FileManager.default
        if fm.fileExists(atPath: saveURL.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: saveURL, to: backupURL)
        }
        try data.write(to: saveURL, options: .atomic)
    }

    func deleteSave() {
        try? FileManager.default.removeItem(at: saveURL)
        try? FileManager.default.removeItem(at: backupURL)
    }
}
