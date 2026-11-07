import Foundation

/// Keeps every farm icon in sync with its `IconSpec`.
///
/// - Rendering, icns encoding and the disk write run on a background queue, so the
///   main thread (SpriteKit layer, menu panel) never blocks on icon work.
/// - Icons are written in place by `IconWriter` (no delete/re-create flicker).
/// - Cosmetic-only changes (progress bars, counters, gear phase) are rate-limited;
///   meaningful changes (stage, ripe, status, fill level) are applied immediately.
/// - Each pass verifies the icon is really on disk (and that the inode is the one we
///   wrote), so icons lost to resets, Finder copies or external tools self-heal.
@MainActor
final class IconUpdateScheduler {
    private struct Entry {
        var spec: IconSpec
        var inode: UInt64
        var appliedAt: Date
        var verifiedAt: Date
    }

    private var applied: [String: Entry] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "DesktopHarvest.icons", qos: .utility)
    var budgetPerPass = 12
    var isEnabled = true
    /// Minimum seconds between cosmetic-only redraws of the same item.
    var cosmeticInterval: TimeInterval = 3
    /// Working machines redraw their gear / progress ring every second.
    var machineInterval: TimeInterval = 1
    /// How often an unchanged icon is re-checked on disk (xattr reads) for self-healing.
    var verifyInterval: TimeInterval = 10
    /// Number of icons actually written to disk (diagnostics / tests).
    private(set) var writeCount = 0
    var isIdle: Bool { inFlight.isEmpty }

    func apply(_ specs: [(URL, IconSpec)], now: Date = Date()) {
        guard isEnabled else { return }
        let alive = Set(specs.map(\.0.path))
        applied = applied.filter { alive.contains($0.key) }

        var pending: [(path: String, spec: IconSpec, inode: UInt64)] = []
        for (url, spec) in specs {
            let path = url.path
            guard !inFlight.contains(path) else { continue }
            let inode = Self.inode(of: path)
            guard inode != 0 else { continue }
            if var entry = applied[path], entry.inode == inode {
                // Identical visual state: skip, re-verifying the disk only occasionally.
                if entry.spec == spec {
                    if now.timeIntervalSince(entry.verifiedAt) < verifyInterval { continue }
                    if IconWriter.hasCustomIcon(at: path) {
                        entry.verifiedAt = now
                        applied[path] = entry
                        continue
                    }
                } else if IconWriter.hasCustomIcon(at: path) {
                    let interval = spec.isWorkingMachine ? machineInterval : cosmeticInterval
                    if entry.spec.majorKey == spec.majorKey && now.timeIntervalSince(entry.appliedAt) < interval { continue }
                }
            }
            pending.append((path, spec, inode))
        }
        pending.sort { priority($0.spec) > priority($1.spec) }

        for job in pending.prefix(budgetPerPass) {
            inFlight.insert(job.path)
            let path = job.path
            let spec = job.spec
            queue.async { [weak self] in
                let ok = Self.renderAndWrite(spec, to: path)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.finish(path: path, spec: spec, ok: ok)
                    }
                }
            }
        }
    }

    func invalidateAll() {
        applied.removeAll()
    }

    private func finish(path: String, spec: IconSpec, ok: Bool) {
        inFlight.remove(path)
        if ok {
            writeCount += 1
            let now = Date()
            applied[path] = Entry(spec: spec, inode: Self.inode(of: path), appliedAt: now, verifiedAt: now)
        } else {
            applied[path] = nil
        }
    }

    nonisolated private static func renderAndWrite(_ spec: IconSpec, to path: String) -> Bool {
        guard let image = ProceduralIconRenderer.cgImage(for: spec),
              let icns = IconWriter.icnsData(from: image) else { return false }
        return IconWriter.apply(icns: icns, to: path)
    }

    nonisolated private static func inode(of path: String) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return UInt64(info.st_ino)
    }

    private func priority(_ spec: IconSpec) -> Int {
        switch spec.body {
        case .machine(_, .working, _, _, _): return 3
        case .clone, .crate, .shippingBin, .orderBox, .trough: return 2
        default: return 1
        }
    }
}

extension IconSpec {
    var isWorkingMachine: Bool {
        if case .machine(_, .working, _, _, _) = body { return true }
        return false
    }

    /// The spec with purely cosmetic, fast-changing details removed. Two specs with the
    /// same major key differ only in bars / counters / animation phase.
    var majorKey: IconSpec {
        switch body {
        case let .plant(emoji, _, _, ripe, thirsty, tree, fruit):
            return IconSpec(body: .plant(emoji: emoji, moisture: 0, growth: 0, ripe: ripe, thirsty: thirsty, tree: tree, fruit: fruit))
        case let .machine(emoji, status, _, _, ready):
            return IconSpec(body: .machine(emoji: emoji, status: status, progress: 0, phase: 0, ready: min(ready, 1)))
        case let .crate(fill, emojis, count):
            return IconSpec(body: .crate(fill: fill, emojis: emojis, count: min(count, 1)))
        case let .shippingBin(_, count):
            return IconSpec(body: .shippingBin(value: 0, count: min(count, 1)))
        case let .orderBox(count):
            return IconSpec(body: .orderBox(count: min(count, 1)))
        case let .trough(count, emoji):
            return IconSpec(body: .trough(count: min(count, 1), emoji: emoji))
        case let .pet(emoji, hungry, ready):
            return IconSpec(body: .pet(emoji: emoji, hungry: hungry, ready: ready))
        default:
            return self
        }
    }
}
