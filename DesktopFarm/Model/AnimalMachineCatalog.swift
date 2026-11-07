import Foundation

/// Desktop pet / livestock species. Anchored by a real `.pet` file.
enum AnimalSpecies: String, Codable, CaseIterable, Sendable, Identifiable {
    case chicken, cow, sheep

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chicken: return "小鸡"
        case .cow: return "奶牛"
        case .sheep: return "绵羊"
        }
    }

    var emoji: String {
        switch self {
        case .chicken: return "🐔"
        case .cow: return "🐄"
        case .sheep: return "🐑"
        }
    }

    var babyEmoji: String {
        switch self {
        case .chicken: return "🐣"
        case .cow: return "🐮"
        case .sheep: return "🐑"
        }
    }

    var fileStem: String {
        switch self {
        case .chicken: return "Chicken"
        case .cow: return "Cow"
        case .sheep: return "Sheep"
        }
    }

    var product: ItemType {
        switch self {
        case .chicken: return .egg
        case .cow: return .milk
        case .sheep: return .wool
        }
    }

    /// Satiety restored per food item. Apples are a treat for everyone.
    var diet: [ItemType: Double] {
        switch self {
        case .chicken: return [.wheat: 45, .apple: 30, .strawberry: 30]
        case .cow: return [.wheat: 35, .hay: 40, .apple: 25, .carrot: 30]
        case .sheep: return [.hay: 45, .wheat: 25, .apple: 25, .carrot: 25]
        }
    }

    var favoriteFood: ItemType {
        switch self {
        case .chicken: return .wheat
        case .cow: return .hay
        case .sheep: return .hay
        }
    }

    /// Seconds of well-fed time per product.
    var productionCycle: Double {
        switch self {
        case .chicken: return 120
        case .cow: return 180
        case .sheep: return 200
        }
    }

    var hungerDrain: Double {
        switch self {
        case .chicken: return 0.15
        case .cow: return 0.12
        case .sheep: return 0.11
        }
    }

    /// Wander speed in points per second.
    var walkSpeed: Double {
        switch self {
        case .chicken: return 46
        case .cow: return 28
        case .sheep: return 34
        }
    }

    var price: Int {
        switch self {
        case .chicken: return 40
        case .cow: return 120
        case .sheep: return 100
        }
    }

    var unlockLevel: Int {
        switch self {
        case .chicken: return 1
        case .sheep: return 2
        case .cow: return 3
        }
    }

    var spriteSize: Double {
        switch self {
        case .chicken: return 40
        case .cow: return 58
        case .sheep: return 50
        }
    }

    static let names: [String] = ["豆豆", "团子", "麦芽", "布丁", "芝麻", "可可", "奶糖", "小满", "棉花", "汤圆", "花卷", "年糕"]

    static let hungryThreshold: Double = 35
}

/// Tool files (`.tool`).
enum ToolType: String, Codable, CaseIterable, Sendable, Identifiable {
    case wateringCan
    case sprinkler

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wateringCan: return "水壶"
        case .sprinkler: return "自动洒水器"
        }
    }

    var emoji: String {
        switch self {
        case .wateringCan: return "💧"
        case .sprinkler: return "⚙️"
        }
    }

    var fileStem: String {
        switch self {
        case .wateringCan: return "💧水壶"
        case .sprinkler: return "⚙️自动洒水器"
        }
    }

    var price: Int {
        switch self {
        case .wateringCan: return 10
        case .sprinkler: return 120
        }
    }

    var unlockLevel: Int {
        switch self {
        case .wateringCan: return 1
        case .sprinkler: return 2
        }
    }
}

/// A crafting recipe for a processing machine.
struct Recipe: Sendable, Equatable, Identifiable {
    var inputs: [ItemType: Int]
    var output: ItemType
    var duration: Double

    var id: String { output.rawValue }

    var summary: String {
        let lhs = inputs.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value)×\($0.key.emoji)\($0.key.displayName)" }
            .joined(separator: " + ")
        return "\(lhs) → \(output.emoji)\(output.displayName) (\(Int(duration))秒)"
    }
}

/// Processing machines; each lives as a real folder in the farm.
enum MachineType: String, Codable, CaseIterable, Sendable, Identifiable {
    case jamMaker, bakery, dairy, loom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jamMaker: return "果酱加工机"
        case .bakery: return "烘焙面包房"
        case .dairy: return "乳品发酵桶"
        case .loom: return "纺织机"
        }
    }

    var folderName: String { "⚙️" + displayName }

    var emoji: String {
        switch self {
        case .jamMaker: return "🫙"
        case .bakery: return "🥖"
        case .dairy: return "🪣"
        case .loom: return "🧵"
        }
    }

    var recipes: [Recipe] {
        switch self {
        case .jamMaker:
            return [
                Recipe(inputs: [.apple: 2], output: .appleJam, duration: 20),
                Recipe(inputs: [.strawberry: 2], output: .strawberryJam, duration: 20),
                Recipe(inputs: [.cherry: 2], output: .cherryJam, duration: 20)
            ]
        case .bakery:
            return [Recipe(inputs: [.wheat: 2, .egg: 1], output: .cake, duration: 25)]
        case .dairy:
            return [Recipe(inputs: [.milk: 1], output: .cheese, duration: 20)]
        case .loom:
            return [Recipe(inputs: [.wool: 1], output: .sweater, duration: 15)]
        }
    }

    var price: Int {
        switch self {
        case .jamMaker: return 150
        case .bakery: return 250
        case .dairy: return 200
        case .loom: return 220
        }
    }

    var unlockLevel: Int {
        switch self {
        case .jamMaker: return 1
        case .bakery: return 3
        case .dairy: return 3
        case .loom: return 4
        }
    }

    /// First recipe whose inputs are fully covered by `available` counts.
    func firstSatisfiedRecipe(available: [ItemType: Int]) -> Recipe? {
        recipes.first { recipe in
            recipe.inputs.allSatisfy { available[$0.key, default: 0] >= $0.value }
        }
    }
}

/// Automation upgrades purchasable in the market.
enum UpgradeType: String, Codable, CaseIterable, Sendable, Identifiable {
    case harvestSprite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .harvestSprite: return "收获小精灵"
        }
    }

    var emoji: String { "🤖" }

    var detail: String {
        switch self {
        case .harvestSprite: return "自动收获成熟作物，并把散落的果实归拢到对应木筐。"
        }
    }

    var price: Int { 300 }
    var unlockLevel: Int { 4 }
}
