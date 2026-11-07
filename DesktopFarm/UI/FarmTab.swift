import SwiftUI

/// Plants, animals, machines, quick actions and the activity log.
struct FarmTab: View {
    @ObservedObject var engine: GameEngine
    @EnvironmentObject private var coordinator: GameCoordinator

    var body: some View {
        VStack(spacing: 10) {
            quickActions
            plantsSection
            petsSection
            machinesSection
            activitySection
        }
    }

    private var quickActions: some View {
        let ripe = engine.game.plants.filter(\.isRipeCrop).count
        let seeds = engine.seedFiles.filter { $0.role == .field }.count
        let loose = engine.looseItems.count
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ActionButton(title: "全部浇水", systemImage: "drop.fill") { engine.waterAll() }
                ActionButton(title: ripe > 0 ? "一键收获 (\(ripe))" : "一键收获", systemImage: "basket.fill", prominent: ripe > 0) { engine.harvestAll() }
                ActionButton(title: seeds > 0 ? "全部播种 (\(seeds))" : "全部播种", systemImage: "leaf.arrow.triangle.circlepath") { engine.plantAllSeeds() }
            }
            HStack(spacing: 6) {
                ActionButton(title: loose > 0 ? "一键整理桌面 (\(loose))" : "一键整理桌面", systemImage: "sparkles") { engine.tidyDesktop() }
                ActionButton(title: "打开农场文件夹", systemImage: "folder.fill") { coordinator.openFarmFolder() }
            }
        }
    }

    private var plantsSection: some View {
        let plants = engine.plantedFiles
        return CardSection(title: "🌱 作物与果树", trailing: "\(plants.count) 株") {
            if plants.isEmpty {
                EmptyHint(text: "还没有植物。双击 .seed 种子文件或点「全部播种」。")
            }
            ForEach(plants, id: \.0.id) { plant, file in
                PlantRow(plant: plant, fileName: file.name, speed: engine.speed,
                         water: { engine.water(plant.id) },
                         harvest: { engine.harvest(plant.id) })
            }
        }
    }

    private var petsSection: some View {
        CardSection(title: "🐾 动物", trailing: "\(engine.game.pets.count) 只") {
            if engine.game.pets.isEmpty {
                EmptyHint(text: "去商店领养一只小鸡吧！")
            }
            ForEach(engine.game.pets) { pet in
                PetRow(pet: pet, behavior: coordinator.director?.actors[pet.id]?.behavior) {
                    engine.feedPetFromStock(pet.id)
                }
            }
        }
    }

    private var machinesSection: some View {
        let machines = engine.machineViews
        return CardSection(title: "⚙️ 加工机械", trailing: "\(machines.count) 台") {
            if machines.isEmpty {
                EmptyHint(text: "在商店购买加工机械文件夹。")
            }
            ForEach(machines) { machine in
                MachineRow(machine: machine, open: { NSWorkspace.shared.open(machine.url) })
            }
        }
    }

    private var activitySection: some View {
        CardSection(title: "📜 农场日志") {
            if engine.game.activity.isEmpty { EmptyHint(text: "暂无记录") }
            ForEach(engine.game.activity.prefix(12)) { entry in
                HStack(alignment: .top, spacing: 6) {
                    Text(entry.icon).font(.system(size: 11))
                    Text(entry.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(Formatters.time(entry.date)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PlantRow: View {
    var plant: PlantState
    var fileName: String
    var speed: Double
    var water: () -> Void
    var harvest: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            EmojiBadge(emoji: plant.species.emoji(for: plant.stage), size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(plant.species.displayName).font(.system(size: 12, weight: .bold))
                    Chip(text: plant.stage.displayName, tint: plant.isRipeCrop ? Theme.gold : Theme.leaf)
                    Spacer()
                    Text(statusText).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "drop.fill").font(.system(size: 9)).foregroundStyle(Theme.water)
                    MeterBar(value: plant.moistureFraction, tint: Theme.water, height: 5)
                }
                HStack(spacing: 4) {
                    Image(systemName: "leaf.fill").font(.system(size: 9)).foregroundStyle(Theme.leaf)
                    MeterBar(value: plant.displayProgress, tint: Theme.leaf, height: 5)
                }
            }
            if plant.isRipeCrop {
                Button("收获", action: harvest).buttonStyle(.borderedProminent).tint(Theme.gold).controlSize(.small)
            } else {
                Button(action: water) { Image(systemName: "drop.fill") }
                    .buttonStyle(.bordered).tint(Theme.water).controlSize(.small)
                    .help("浇水 +\(Int(PlantState.wateringAmount))")
            }
        }
        .help(fileName)
    }

    private var statusText: String {
        if plant.isRipeCrop { return "可收获" }
        if !plant.canGrow { return "缺水暂停生长" }
        let seconds = plant.secondsToNextMilestone / max(speed, 0.1)
        if plant.isGrownTree { return "下次结果 \(Formatters.duration(seconds))" }
        return "成熟还需 \(Formatters.duration(seconds))"
    }
}

private struct PetRow: View {
    var pet: PetState
    var behavior: PetBehavior?
    var feed: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            EmojiBadge(emoji: pet.species.emoji, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(pet.name).font(.system(size: 12, weight: .bold))
                    Text(pet.species.displayName).font(.system(size: 10)).foregroundStyle(.secondary)
                    if let behavior { Chip(text: behavior.label, tint: pet.isHungry ? .red : Theme.leaf) }
                    Spacer()
                    Text("产出 \(pet.species.product.emoji) \(Formatters.percent(pet.productionProgress))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("🍽").font(.system(size: 9))
                    MeterBar(value: pet.satietyFraction, tint: pet.isHungry ? .red : .orange, height: 5)
                    Text("💖").font(.system(size: 9))
                    MeterBar(value: pet.affectionFraction, tint: .pink, height: 5)
                }
            }
            Button("喂食", action: feed).buttonStyle(.bordered).controlSize(.small)
                .help("从食槽 / 桌面 / 木筐里找\(pet.species.displayName)爱吃的食物")
        }
    }
}

private struct MachineRow: View {
    var machine: MachineView
    var open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            EmojiBadge(emoji: machine.type.emoji, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(machine.name).font(.system(size: 12, weight: .bold))
                    Chip(text: machine.status.label, tint: machine.status == .working ? Theme.leaf : (machine.status == .ready ? Theme.gold : .secondary))
                    Spacer()
                }
                if let job = machine.job {
                    HStack(spacing: 4) {
                        Text("\(job.output.emoji)\(job.output.displayName)").font(.system(size: 10))
                        MeterBar(value: job.progress, tint: Theme.leaf, height: 5)
                        Text(Formatters.percent(job.progress)).font(.system(size: 10)).monospacedDigit()
                    }
                } else {
                    Text(machine.type.recipes.map(\.summary).joined(separator: "\n"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !machine.inputCounts.isEmpty {
                    Text("原料：" + machine.inputCounts.map { "\($0.key.emoji)×\($0.value)" }.sorted().joined(separator: " "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Button(action: open) { Image(systemName: "folder") }.buttonStyle(.bordered).controlSize(.small)
                .help("打开机器文件夹，拖入原料 / 取出成品")
        }
    }
}
