import Foundation

enum MachineStatus: String, Sendable {
    case idle, working, ready

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .working: return "运转中"
        case .ready: return "✨待收取"
        }
    }
}

/// Read model of a machine folder for UI, icons and overlay.
struct MachineView: Identifiable, Sendable, Equatable {
    var id: UUID
    var type: MachineType
    var name: String
    var url: URL
    var job: MachineJob?
    var readyOutputs: Int
    var inputCounts: [ItemType: Int]

    var status: MachineStatus {
        if job != nil { return .working }
        return readyOutputs > 0 ? .ready : .idle
    }
}

/// A food file that a hungry animal may walk to.
struct FoodTarget: Identifiable, Sendable, Equatable {
    var id: UUID
    var item: ItemType
    var url: URL
    var name: String
    var troughID: UUID?
}

/// Read-only projections for the UI and the desktop layer.
extension GameEngine {
    var machineViews: [MachineView] {
        scan.folders(role: .machine).compactMap { folder -> MachineView? in
            guard let marker = folder.marker, let type = marker.machineType else { return nil }
            let state = game.machines.first { $0.id == marker.id }
            let loose = scan.files(inFolder: marker.id, role: .machine).filter { $0.payload.kind == .item && $0.signatureValid }
            let outputs = Set(type.recipes.map(\.output))
            var inputs: [ItemType: Int] = [:]
            var ready = 0
            for file in loose {
                guard let item = file.payload.itemValue else { continue }
                if outputs.contains(item) { ready += 1 } else { inputs[item, default: 0] += 1 }
            }
            return MachineView(id: marker.id, type: type, name: folder.name, url: folder.url, job: state?.job, readyOutputs: ready, inputCounts: inputs)
        }
        .sorted { $0.name < $1.name }
    }

    func foodTargets(for species: AnimalSpecies) -> [FoodTarget] {
        scan.files.compactMap { file -> FoodTarget? in
            guard file.signatureValid, file.role == .field || file.role == .trough,
                  let item = file.payload.itemValue, species.diet[item] != nil else { return nil }
            return FoodTarget(id: file.payload.id, item: item, url: file.url, name: file.name, troughID: file.role == .trough ? file.folderID : nil)
        }
    }

    var troughFolders: [ScannedFolder] { scan.folders(role: .trough) }

    func troughFoodCount(_ id: UUID) -> Int {
        scan.files(inFolder: id).filter { $0.payload.kind == .item && $0.signatureValid }.count
    }

    var plantedFiles: [(PlantState, ScannedFile)] {
        game.plants.compactMap { plant in scan.file(id: plant.id).map { (plant, $0) } }
            .sorted { $0.0.plantedAt < $1.0.plantedAt }
    }

    var seedFiles: [ScannedFile] {
        scan.files.filter { $0.payload.kind == .seed && $0.signatureValid }
    }

    var looseItems: [ScannedFile] {
        scan.files.filter { $0.role == .field && $0.payload.kind == .item && $0.signatureValid }
    }

    var orderBoxFiles: [ScannedFile] {
        scan.files.filter { $0.role == .orderBox && $0.payload.kind == .item && $0.signatureValid }
    }

    var cloneCount: Int {
        scan.files.filter { $0.payload.itemValue == .witheredClone }.count
    }

    func plant(_ id: UUID) -> PlantState? { game.plants.first { $0.id == id } }
    func pet(_ id: UUID) -> PetState? { game.pets.first { $0.id == id } }
}
