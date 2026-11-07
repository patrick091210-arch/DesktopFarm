import Foundation

/// Allowed game file suffixes. Anything else in the farm is never touched.
enum GameFileKind: String, Codable, CaseIterable, Sendable {
    case seed, crop, tree, item, pet, tool

    var fileExtension: String { rawValue }

    static let allExtensions: Set<String> = Set(allCases.map(\.fileExtension))
}

/// Strongly typed meaning of a payload's `itemType` field.
enum GameSubject: Sendable, Equatable {
    case seed(PlantSpecies)
    case plant(PlantSpecies)
    case item(ItemType)
    case pet(AnimalSpecies)
    case tool(ToolType)

    var emoji: String {
        switch self {
        case .seed(let species): return species.seedEmoji
        case .plant(let species): return species.emoji(for: .seed)
        case .item(let type): return type.emoji
        case .pet(let species): return species.emoji
        case .tool(let tool): return tool.emoji
        }
    }

    var displayName: String {
        switch self {
        case .seed(let species): return "\(species.displayName)种子"
        case .plant(let species): return species.displayName
        case .item(let type): return type.displayName
        case .pet(let species): return species.displayName
        case .tool(let tool): return tool.displayName
        }
    }
}

/// The JSON body of every game file (`.seed .crop .tree .item .pet .tool`).
/// The file is the *identity* of a game object; dynamic state lives in the save.
struct GameFilePayload: Codable, Sendable, Equatable {
    static let formatTag = "DesktopHarvest/1"

    var format: String
    var id: UUID
    var kind: GameFileKind
    var itemType: String
    var quality: Int
    var timestamp: TimeInterval
    var hmacSignature: String
    /// Informational only, not covered by the signature.
    var displayName: String?

    init(
        id: UUID = UUID(),
        kind: GameFileKind,
        itemType: String,
        quality: Int = 1,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        hmacSignature: String = "",
        displayName: String? = nil
    ) {
        self.format = GameFilePayload.formatTag
        self.id = id
        self.kind = kind
        self.itemType = itemType
        self.quality = quality
        self.timestamp = timestamp
        self.hmacSignature = hmacSignature
        self.displayName = displayName
    }

    /// Canonical byte string that the HMAC covers.
    var signingMessage: String {
        "\(format)|\(id.uuidString)|\(kind.rawValue)|\(itemType)|\(quality)|\(String(format: "%.3f", timestamp))"
    }

    var subject: GameSubject? {
        switch kind {
        case .seed: return PlantSpecies(rawValue: itemType).map(GameSubject.seed)
        case .crop:
            guard let species = PlantSpecies(rawValue: itemType), !species.isTree else { return nil }
            return .plant(species)
        case .tree:
            guard let species = PlantSpecies(rawValue: itemType), species.isTree else { return nil }
            return .plant(species)
        case .item: return ItemType(rawValue: itemType).map(GameSubject.item)
        case .pet: return AnimalSpecies(rawValue: itemType).map(GameSubject.pet)
        case .tool: return ToolType(rawValue: itemType).map(GameSubject.tool)
        }
    }

    var qualityValue: Quality { Quality.clamped(quality) }

    var itemValue: ItemType? {
        guard kind == .item else { return nil }
        return ItemType(rawValue: itemType)
    }
}

/// Role of a managed folder inside the farm.
enum FolderRole: String, Codable, Sendable, CaseIterable {
    case crate
    case machine
    case shippingBin
    case orderBox
    case trough

    var displayName: String {
        switch self {
        case .crate: return "木筐"
        case .machine: return "加工机械"
        case .shippingBin: return "出货箱"
        case .orderBox: return "订单交付箱"
        case .trough: return "动物食槽"
        }
    }
}

/// Hidden marker file stored inside each managed folder.
struct FolderMarker: Codable, Sendable, Equatable {
    static let fileName = ".desktopharvest"

    var format: String
    var id: UUID
    var role: FolderRole
    var machineType: MachineType?
    var crateCategory: CrateCategory?
    var timestamp: TimeInterval
    var hmacSignature: String

    init(
        id: UUID = UUID(),
        role: FolderRole,
        machineType: MachineType? = nil,
        crateCategory: CrateCategory? = nil,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        hmacSignature: String = ""
    ) {
        self.format = GameFilePayload.formatTag
        self.id = id
        self.role = role
        self.machineType = machineType
        self.crateCategory = crateCategory
        self.timestamp = timestamp
        self.hmacSignature = hmacSignature
    }

    var signingMessage: String {
        "\(format)|folder|\(id.uuidString)|\(role.rawValue)|\(machineType?.rawValue ?? "-")|\(crateCategory?.rawValue ?? "-")|\(String(format: "%.3f", timestamp))"
    }
}

/// Default folder names created in a fresh farm.
enum StarterFolder {
    static let produceCrate = "📦果蔬收集筐"
    static let ranchCrate = "📦牧场副产品筐"
    static let shippingBin = "💰出货箱"
    static let orderBox = "📋订单交付箱"
    static let trough = "🥣动物食槽"
}
