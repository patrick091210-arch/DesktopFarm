import Foundation

/// A hashable description of a file / folder icon. Icons are only re-rendered
/// and re-applied when the spec changes, so values are quantised.
struct IconSpec: Hashable, Sendable {
    enum Body: Hashable, Sendable {
        case plant(emoji: String, moisture: Int, growth: Int, ripe: Bool, thirsty: Bool, tree: Bool, fruit: String?)
        case seed(emoji: String, tree: Bool)
        case item(emoji: String, quality: Int, processed: Bool)
        case clone
        case pet(emoji: String, hungry: Bool, ready: Bool)
        case tool(emoji: String)
        case crate(fill: Int, emojis: [String], count: Int)
        case machine(emoji: String, status: MachineStatusKey, progress: Int, phase: Int, ready: Int)
        case shippingBin(value: Int, count: Int)
        case orderBox(count: Int)
        case trough(count: Int, emoji: String?)
    }

    enum MachineStatusKey: String, Hashable, Sendable {
        case idle, working, ready
    }

    var body: Body

    /// Quantises a 0...1 fraction into 0...20 steps (5 %).
    static func step(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 20).rounded())
    }
}

/// Computes the desired icon for every game file and managed folder.
extension GameEngine {
    func iconSpecs(now: Date = Date()) -> [(URL, IconSpec)] {
        var result: [(URL, IconSpec)] = []
        let plants = Dictionary(game.plants.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pets = Dictionary(game.pets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for file in scan.files where file.role != .processing {
            let payload = file.payload
            switch payload.subject {
            case .plant(let species):
                guard let plant = plants[payload.id] else { continue }
                let stage = plant.stage
                let fruit: String? = species.isTree && stage == .fruiting ? species.produce.emoji : nil
                result.append((file.url, IconSpec(body: .plant(
                    emoji: species.emoji(for: stage),
                    moisture: IconSpec.step(plant.moistureFraction),
                    growth: IconSpec.step(plant.displayProgress),
                    ripe: plant.isRipeCrop,
                    thirsty: plant.isThirsty,
                    tree: species.isTree,
                    fruit: fruit
                ))))
            case .seed(let species):
                result.append((file.url, IconSpec(body: .seed(emoji: species.produce.emoji, tree: species.isTree))))
            case .item(let type):
                if type == .witheredClone {
                    result.append((file.url, IconSpec(body: .clone)))
                } else {
                    result.append((file.url, IconSpec(body: .item(emoji: type.emoji, quality: payload.quality, processed: type.isProcessed))))
                }
            case .pet(let species):
                let pet = pets[payload.id]
                result.append((file.url, IconSpec(body: .pet(emoji: species.emoji, hungry: pet?.isHungry ?? false, ready: pet?.readyToProduce ?? false))))
            case .tool(let tool):
                result.append((file.url, IconSpec(body: .tool(emoji: tool == .wateringCan ? "🚿" : "⚙️"))))
            case .none:
                continue
            }
        }

        for crate in crates {
            let emojis = crate.sortedCounts.prefix(3).map(\.0.emoji)
            result.append((crate.url, IconSpec(body: .crate(fill: crate.fillLevel, emojis: Array(emojis), count: crate.totalCount))))
        }
        for machine in machineViews {
            let key: IconSpec.MachineStatusKey
            switch machine.status {
            case .idle: key = .idle
            case .working: key = .working
            case .ready: key = .ready
            }
            let progress = Int(((machine.job?.progress ?? 0) * 100).rounded())
            let phase = machine.status == .working ? Int(now.timeIntervalSince1970) % 8 : 0
            result.append((machine.url, IconSpec(body: .machine(emoji: machine.type.emoji, status: key, progress: progress, phase: phase, ready: machine.readyOutputs))))
        }
        for folder in scan.folders(role: .shippingBin) {
            guard let id = folder.marker?.id else { continue }
            let files = scan.files(inFolder: id)
            result.append((folder.url, IconSpec(body: .shippingBin(value: SmartCrateMonitor.value(of: files), count: files.count))))
        }
        for folder in scan.folders(role: .orderBox) {
            guard let id = folder.marker?.id else { continue }
            result.append((folder.url, IconSpec(body: .orderBox(count: scan.files(inFolder: id).count))))
        }
        for folder in scan.folders(role: .trough) {
            guard let id = folder.marker?.id else { continue }
            let files = scan.files(inFolder: id).filter { $0.payload.kind == .item }
            result.append((folder.url, IconSpec(body: .trough(count: files.count, emoji: files.first?.payload.itemValue?.emoji))))
        }
        return result
    }
}
