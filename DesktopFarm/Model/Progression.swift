import Foundation

/// XP curve and level helpers.
enum Progression {
    static let maxLevel = 30

    /// Total XP required to *reach* `level` (level 1 needs 0).
    static func xpRequired(forLevel level: Int) -> Int {
        guard level > 1 else { return 0 }
        let n = Double(level - 1)
        return Int((60 * pow(n, 1.55)).rounded())
    }

    static func level(forXP xp: Int) -> Int {
        var level = 1
        while level < maxLevel && xp >= xpRequired(forLevel: level + 1) {
            level += 1
        }
        return level
    }

    /// Fraction of progress inside the current level, 0...1.
    static func levelProgress(xp: Int) -> Double {
        let level = level(forXP: xp)
        guard level < maxLevel else { return 1 }
        let low = xpRequired(forLevel: level)
        let high = xpRequired(forLevel: level + 1)
        return Double(xp - low) / Double(max(high - low, 1))
    }

    /// XP earned from shipping goods for `coins`.
    static func shippingXP(coins: Int) -> Int { max(0, coins / 8) }
}

/// Something purchasable in the market store.
enum ShopProduct: Hashable, Sendable, Identifiable {
    case seed(PlantSpecies)
    case animal(AnimalSpecies)
    case machine(MachineType)
    case tool(ToolType)
    case trough
    case crate
    case upgrade(UpgradeType)

    enum Category: String, CaseIterable, Sendable, Identifiable {
        case seeds = "种子与树苗"
        case animals = "动物幼崽"
        case machines = "加工机械"
        case equipment = "农具设施"
        case upgrades = "科技升级"

        var id: String { rawValue }
    }

    var id: String {
        switch self {
        case .seed(let species): return "seed.\(species.rawValue)"
        case .animal(let species): return "animal.\(species.rawValue)"
        case .machine(let type): return "machine.\(type.rawValue)"
        case .tool(let tool): return "tool.\(tool.rawValue)"
        case .trough: return "trough"
        case .crate: return "crate"
        case .upgrade(let upgrade): return "upgrade.\(upgrade.rawValue)"
        }
    }

    static var all: [ShopProduct] {
        PlantSpecies.allCases.map(ShopProduct.seed)
            + AnimalSpecies.allCases.map(ShopProduct.animal)
            + MachineType.allCases.map(ShopProduct.machine)
            + ToolType.allCases.map(ShopProduct.tool)
            + [.trough, .crate]
            + UpgradeType.allCases.map(ShopProduct.upgrade)
    }

    var category: Category {
        switch self {
        case .seed: return .seeds
        case .animal: return .animals
        case .machine: return .machines
        case .tool, .trough, .crate: return .equipment
        case .upgrade: return .upgrades
        }
    }

    var price: Int {
        switch self {
        case .seed(let species): return species.seedPrice
        case .animal(let species): return species.price
        case .machine(let type): return type.price
        case .tool(let tool): return tool.price
        case .trough: return 30
        case .crate: return 25
        case .upgrade(let upgrade): return upgrade.price
        }
    }

    var unlockLevel: Int {
        switch self {
        case .seed(let species): return species.unlockLevel
        case .animal(let species): return species.unlockLevel
        case .machine(let type): return type.unlockLevel
        case .tool(let tool): return tool.unlockLevel
        case .trough, .crate: return 1
        case .upgrade(let upgrade): return upgrade.unlockLevel
        }
    }

    var emoji: String {
        switch self {
        case .seed(let species): return species.isTree ? "🌱" : species.produce.emoji
        case .animal(let species): return species.babyEmoji
        case .machine: return "⚙️"
        case .tool(let tool): return tool.emoji
        case .trough: return "🥣"
        case .crate: return "📦"
        case .upgrade(let upgrade): return upgrade.emoji
        }
    }

    var displayName: String {
        switch self {
        case .seed(let species): return species.isTree ? "\(species.displayName)苗" : "\(species.displayName)种子"
        case .animal(let species): return "\(species.displayName)幼崽"
        case .machine(let type): return type.displayName
        case .tool(let tool): return tool.displayName
        case .trough: return "动物食槽"
        case .crate: return "自定义木筐"
        case .upgrade(let upgrade): return upgrade.displayName
        }
    }

    var detail: String {
        switch self {
        case .seed(let species):
            if species.isTree {
                return "多年生果树：长成后每 \(Int(species.fruitCycle)) 秒掉落 2~4 个\(species.produce.displayName)。"
            }
            return "\(Int(species.growDuration)) 秒成熟，收获 \(species.yieldRange.lowerBound)~\(species.yieldRange.upperBound) 个\(species.produce.displayName)。"
        case .animal(let species):
            let foods = species.diet.keys.sorted { $0.rawValue < $1.rawValue }.map(\.emoji).joined()
            return "吃 \(foods)，每 \(Int(species.productionCycle)) 秒产出 \(species.product.emoji)\(species.product.displayName)。"
        case .machine(let type):
            return type.recipes.map(\.summary).joined(separator: "\n")
        case .tool(.wateringCan):
            return "拖到植物上浇水，或在 Finder 中把它移到植物旁边。"
        case .tool(.sprinkler):
            return "放在植物同一目录，自动保持周围植物水分充足。"
        case .trough:
            return "真实文件夹：放入饲料，饥饿的动物会自己过来吃。"
        case .crate:
            return "额外的收纳木筐，实时统计里面的物品。"
        case .upgrade(let upgrade):
            return upgrade.detail
        }
    }
}
