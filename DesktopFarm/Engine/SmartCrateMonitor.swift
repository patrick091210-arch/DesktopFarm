import Foundation

/// Outcome of the UUID / inode / HMAC identity check over a full scan.
struct IdentityResolution: Sendable, Equatable {
    /// Files accepted as the one genuine copy of their id.
    var genuine: [ScannedFile] = []
    /// Genuine files that were not yet registered (adopt into the ledger).
    var adopted: [ScannedFile] = []
    /// Copies, forgeries and resurrected spent items.
    var clones: [ScannedFile] = []
    /// Ledger ids with no file on disk anymore.
    var missingIDs: [UUID] = []
}

/// Anti-cheat rules:
/// - invalid HMAC (edited / forged) → clone;
/// - id already consumed or sold → clone;
/// - unregistered file whose signed timestamp lies inside `registeredWindow` → clone
///   (every genuine file created in that window was registered before the last save,
///   so an unknown one is a resurrected backup of a spent item);
/// - several files share one id → the one whose inode matches the ledger is genuine
///   (Finder moves keep the inode, Cmd+C/Cmd+V creates a new inode); others are clones.
enum AntiCheat {
    static func resolve(
        files: [ScannedFile],
        ledger: [LedgerEntry],
        spent: Set<UUID>,
        registeredWindow: ClosedRange<TimeInterval>? = nil
    ) -> IdentityResolution {
        var result = IdentityResolution()
        let ledgerByID = Dictionary(ledger.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [UUID: [ScannedFile]] = [:]
        for file in files {
            if file.payload.itemType == ItemType.witheredClone.rawValue && file.payload.kind == .item && file.signatureValid {
                // Already-withered clones are genuine junk items with their own id.
                groups[file.payload.id, default: []].append(file)
                continue
            }
            if !file.signatureValid || spent.contains(file.payload.id) {
                result.clones.append(file)
                continue
            }
            if ledgerByID[file.payload.id] == nil, let window = registeredWindow, window.contains(file.payload.timestamp) {
                result.clones.append(file)
                continue
            }
            groups[file.payload.id, default: []].append(file)
        }

        for (id, group) in groups {
            let sorted = group.sorted { lhs, rhs in
                if lhs.creationDate != rhs.creationDate { return lhs.creationDate < rhs.creationDate }
                return lhs.relativePath < rhs.relativePath
            }
            var genuine: ScannedFile
            if let entry = ledgerByID[id] {
                genuine = sorted.first { $0.inode == entry.inode && entry.inode != 0 }
                    ?? sorted.first { $0.relativePath == entry.relativePath }
                    ?? sorted[0]
                result.genuine.append(genuine)
            } else {
                genuine = sorted[0]
                result.genuine.append(genuine)
                result.adopted.append(genuine)
            }
            for file in sorted where file.relativePath != genuine.relativePath {
                result.clones.append(file)
            }
        }

        let present = Set(groups.keys)
        result.missingIDs = ledger.map(\.id).filter { !present.contains($0) }
        return result
    }
}

/// Live summary of a crate folder.
struct CrateSummary: Sendable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var url: URL
    var category: CrateCategory?
    var counts: [ItemType: Int]
    var totalValue: Int
    var totalCount: Int

    /// 0 empty, 1 a few, 2 half, 3 full.
    var fillLevel: Int {
        switch totalCount {
        case 0: return 0
        case 1...4: return 1
        case 5...14: return 2
        default: return 3
        }
    }

    var sortedCounts: [(ItemType, Int)] {
        counts.filter { $0.value > 0 }.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.rawValue < rhs.key.rawValue
        }
    }

    /// e.g. `🍎苹果 x12 | 🥕胡萝卜 x5 | 🥛牛奶 x3`
    var inventoryLine: String {
        let parts = sortedCounts.map { "\($0.0.emoji)\($0.0.displayName) x\($0.1)" }
        return parts.isEmpty ? "空空如也" : parts.joined(separator: " | ")
    }
}

/// Real-time crate bookkeeping on top of a scan.
enum SmartCrateMonitor {
    static func summaries(scan: FarmScan) -> [CrateSummary] {
        scan.folders(role: .crate).compactMap { folder -> CrateSummary? in
            guard let marker = folder.marker else { return nil }
            let items = scan.files(inFolder: marker.id).filter { $0.payload.kind == .item && $0.signatureValid }
            var counts: [ItemType: Int] = [:]
            var value = 0
            for file in items {
                guard let type = file.payload.itemValue else { continue }
                counts[type, default: 0] += 1
                value += type.price(quality: file.payload.qualityValue)
            }
            return CrateSummary(
                id: marker.id,
                name: folder.name,
                url: folder.url,
                category: marker.crateCategory,
                counts: counts,
                totalValue: value,
                totalCount: items.count
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// Valid, non-junk item files in a set.
    static func sellableItems(_ files: [ScannedFile]) -> [ScannedFile] {
        files.filter { $0.payload.kind == .item && $0.signatureValid && $0.payload.itemValue != nil }
    }

    static func value(of files: [ScannedFile]) -> Int {
        sellableItems(files).reduce(0) { total, file in
            guard let type = file.payload.itemValue else { return total }
            return total + type.price(quality: file.payload.qualityValue)
        }
    }
}

/// Recipe planning for machine folders.
enum ProcessingMachineEngine {
    struct Plan: Sendable, Equatable {
        var recipe: Recipe
        var inputs: [ScannedFile]
        var quality: Quality
    }

    /// Picks the first satisfiable recipe from the folder's loose (non-processing) items.
    static func plan(for type: MachineType, available files: [ScannedFile]) -> Plan? {
        let items = SmartCrateMonitor.sellableItems(files).filter { $0.payload.itemValue != .witheredClone }
        var counts: [ItemType: Int] = [:]
        for file in items { if let type = file.payload.itemValue { counts[type, default: 0] += 1 } }
        guard let recipe = type.firstSatisfiedRecipe(available: counts) else { return nil }
        var chosen: [ScannedFile] = []
        for (input, quantity) in recipe.inputs.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let candidates = items.filter { $0.payload.itemValue == input }
                .sorted { $0.creationDate < $1.creationDate }
            chosen.append(contentsOf: candidates.prefix(quantity))
        }
        let avg = Double(chosen.map(\.payload.quality).reduce(0, +)) / Double(max(chosen.count, 1))
        return Plan(recipe: recipe, inputs: chosen, quality: Quality.clamped(Int(avg.rounded())))
    }

    /// Advances a running job. Returns true when the job just finished.
    static func advance(_ machine: inout MachineState, dt: Double) -> Bool {
        guard var job = machine.job, !job.isFinished else { return false }
        job.elapsed = min(job.duration, job.elapsed + dt)
        machine.job = job
        return job.isFinished
    }
}
