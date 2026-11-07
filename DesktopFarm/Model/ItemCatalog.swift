import Foundation

/// Which storage crate an item naturally belongs to.
enum CrateCategory: String, Codable, Sendable, CaseIterable {
    case produce
    case ranch
}

/// Every collectible / sellable item that can exist as a real `.item` file.
enum ItemType: String, Codable, CaseIterable, Sendable, Identifiable {
    case wheat, carrot, strawberry, hay
    case apple, cherry
    case egg, milk, wool
    case appleJam, strawberryJam, cherryJam, cake, cheese, sweater
    case witheredClone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wheat: return "小麦"
        case .carrot: return "胡萝卜"
        case .strawberry: return "草莓"
        case .hay: return "牧草"
        case .apple: return "苹果"
        case .cherry: return "樱桃"
        case .egg: return "鸡蛋"
        case .milk: return "牛奶"
        case .wool: return "羊毛"
        case .appleJam: return "苹果酱"
        case .strawberryJam: return "草莓酱"
        case .cherryJam: return "樱桃酱"
        case .cake: return "农庄蛋糕"
        case .cheese: return "香浓奶酪"
        case .sweater: return "羊毛衫"
        case .witheredClone: return "枯萎的克隆果"
        }
    }

    var emoji: String {
        switch self {
        case .wheat: return "🌾"
        case .carrot: return "🥕"
        case .strawberry: return "🍓"
        case .hay: return "🌿"
        case .apple: return "🍎"
        case .cherry: return "🍒"
        case .egg: return "🥚"
        case .milk: return "🥛"
        case .wool: return "🧶"
        case .appleJam: return "🫙"
        case .strawberryJam: return "🍯"
        case .cherryJam: return "🥫"
        case .cake: return "🎂"
        case .cheese: return "🧀"
        case .sweater: return "🧥"
        case .witheredClone: return "🥀"
        }
    }

    /// English stem used for real file names, e.g. `Apple_3F2A.item`.
    var fileStem: String {
        switch self {
        case .wheat: return "Wheat"
        case .carrot: return "Carrot"
        case .strawberry: return "Strawberry"
        case .hay: return "Hay"
        case .apple: return "Apple"
        case .cherry: return "Cherry"
        case .egg: return "Egg"
        case .milk: return "Milk"
        case .wool: return "Wool"
        case .appleJam: return "AppleJam"
        case .strawberryJam: return "StrawberryJam"
        case .cherryJam: return "CherryJam"
        case .cake: return "Cake"
        case .cheese: return "Cheese"
        case .sweater: return "Sweater"
        case .witheredClone: return "WitheredClone"
        }
    }

    var basePrice: Int {
        switch self {
        case .wheat: return 4
        case .carrot: return 9
        case .strawberry: return 14
        case .hay: return 2
        case .apple: return 8
        case .cherry: return 12
        case .egg: return 10
        case .milk: return 18
        case .wool: return 22
        case .appleJam: return 36
        case .strawberryJam: return 60
        case .cherryJam: return 54
        case .cake: return 70
        case .cheese: return 45
        case .sweater: return 65
        case .witheredClone: return 0
        }
    }

    var isProcessed: Bool {
        switch self {
        case .appleJam, .strawberryJam, .cherryJam, .cake, .cheese, .sweater: return true
        default: return false
        }
    }

    var crateCategory: CrateCategory {
        switch self {
        case .wheat, .carrot, .strawberry, .hay, .apple, .cherry: return .produce
        default: return .ranch
        }
    }

    /// XP granted when this item is produced on the farm.
    var productionXP: Int {
        switch self {
        case .witheredClone: return 0
        case .hay: return 1
        case .wheat, .apple: return 3
        case .carrot, .cherry, .egg: return 4
        case .strawberry, .milk, .wool: return 6
        default: return 10
        }
    }

    func price(quality: Quality) -> Int {
        Int((Double(basePrice) * quality.priceMultiplier).rounded())
    }

    static func from(fileStem: String) -> ItemType? {
        allCases.first { $0.fileStem.lowercased() == fileStem.lowercased() }
    }
}

/// Item quality: normal, silver star, gold star.
enum Quality: Int, Codable, Sendable, CaseIterable, Comparable {
    case normal = 1
    case silver = 2
    case gold = 3

    static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }

    var priceMultiplier: Double {
        switch self {
        case .normal: return 1.0
        case .silver: return 1.25
        case .gold: return 1.5
        }
    }

    var label: String {
        switch self {
        case .normal: return "普通"
        case .silver: return "银星"
        case .gold: return "金星"
        }
    }

    var stars: String {
        switch self {
        case .normal: return ""
        case .silver: return "★"
        case .gold: return "★★"
        }
    }

    /// Rolls a quality from a 0...1 "care score" (moisture average, affection...).
    static func roll<G: RandomNumberGenerator>(care: Double, using rng: inout G) -> Quality {
        let score = min(max(care, 0), 1)
        let goldChance = 0.04 + 0.16 * score
        let silverChance = 0.12 + 0.28 * score
        let roll = Double.random(in: 0..<1, using: &rng)
        if roll < goldChance { return .gold }
        if roll < goldChance + silverChance { return .silver }
        return .normal
    }

    static func clamped(_ raw: Int) -> Quality {
        Quality(rawValue: min(max(raw, 1), 3)) ?? .normal
    }
}
