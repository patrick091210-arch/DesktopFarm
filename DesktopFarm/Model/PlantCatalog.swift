import Foundation

/// Visual / logical growth stage of a planted `.crop` or `.tree` file.
enum PlantStage: String, Codable, Sendable {
    case seed
    case sprout
    case growing
    case ripe
    case sapling
    case grown
    case fruiting

    var displayName: String {
        switch self {
        case .seed: return "种子"
        case .sprout: return "幼苗"
        case .growing: return "生长中"
        case .ripe: return "成熟"
        case .sapling: return "树苗"
        case .grown: return "大树(冷却期)"
        case .fruiting: return "结果期"
        }
    }
}

/// Every plantable species. Annual crops become `.crop` files, perennials `.tree` files.
enum PlantSpecies: String, Codable, CaseIterable, Sendable, Identifiable {
    case wheat, carrot, strawberry, hay
    case appleTree, cherryTree

    var id: String { rawValue }

    var isTree: Bool { self == .appleTree || self == .cherryTree }

    var displayName: String {
        switch self {
        case .wheat: return "小麦"
        case .carrot: return "胡萝卜"
        case .strawberry: return "草莓"
        case .hay: return "牧草"
        case .appleTree: return "苹果树"
        case .cherryTree: return "樱桃树"
        }
    }

    var fileStem: String {
        switch self {
        case .wheat: return "Wheat"
        case .carrot: return "Carrot"
        case .strawberry: return "Strawberry"
        case .hay: return "Hay"
        case .appleTree: return "AppleTree"
        case .cherryTree: return "CherryTree"
        }
    }

    var produce: ItemType {
        switch self {
        case .wheat: return .wheat
        case .carrot: return .carrot
        case .strawberry: return .strawberry
        case .hay: return .hay
        case .appleTree: return .apple
        case .cherryTree: return .cherry
        }
    }

    /// Seconds (at full moisture) from seed to ripe crop, or to a grown tree.
    var growDuration: Double {
        switch self {
        case .wheat: return 90
        case .carrot: return 150
        case .strawberry: return 240
        case .hay: return 60
        case .appleTree: return 300
        case .cherryTree: return 420
        }
    }

    /// Trees only: seconds per fruiting cycle once grown.
    var fruitCycle: Double {
        switch self {
        case .appleTree: return 180
        case .cherryTree: return 240
        default: return 0
        }
    }

    var yieldRange: ClosedRange<Int> {
        switch self {
        case .wheat: return 2...3
        case .carrot: return 2...2
        case .strawberry: return 2...3
        case .hay: return 3...3
        case .appleTree, .cherryTree: return 2...4
        }
    }

    /// Moisture points lost per second.
    var moistureDrain: Double { isTree ? 0.22 : 0.4 }

    var seedPrice: Int {
        switch self {
        case .wheat: return 5
        case .carrot: return 8
        case .strawberry: return 15
        case .hay: return 3
        case .appleTree: return 60
        case .cherryTree: return 120
        }
    }

    var unlockLevel: Int {
        switch self {
        case .wheat, .hay, .appleTree: return 1
        case .carrot: return 2
        case .strawberry: return 3
        case .cherryTree: return 4
        }
    }

    var fileKind: GameFileKind { isTree ? .tree : .crop }

    func stage(growth: Double, fruitProgress: Double) -> PlantStage {
        if isTree {
            if growth < 0.2 { return .seed }
            if growth < 1 { return .sapling }
            return fruitProgress >= 0.6 ? .fruiting : .grown
        }
        if growth < 0.2 { return .seed }
        if growth < 0.55 { return .sprout }
        if growth < 1 { return .growing }
        return .ripe
    }

    func emoji(for stage: PlantStage) -> String {
        switch stage {
        case .seed: return "🌰"
        case .sprout: return "🌱"
        case .sapling: return "🌿"
        case .growing:
            switch self {
            case .wheat, .hay: return "🌿"
            case .carrot: return "🥬"
            default: return "☘️"
            }
        case .ripe: return produce.emoji
        case .grown: return self == .cherryTree ? "🌸" : "🌳"
        case .fruiting: return "🌳"
        }
    }

    var seedEmoji: String { isTree ? "🌱" : "🌰" }
}
