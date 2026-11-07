import SwiftUI

/// Live crate inventory (`🍎苹果 x12 | 🥕胡萝卜 x5 | 🥛牛奶 x3`), loose items and clones.
struct InventoryTab: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        VStack(spacing: 10) {
            let total = engine.crates.reduce(0) { $0 + $1.totalValue }
            CardSection(title: "📦 智能木筐", trailing: "总价值 \(total) 💰") {
                if engine.crates.isEmpty { EmptyHint(text: "没有木筐。名字含「筐」的文件夹会被自动识别。") }
                ForEach(engine.crates) { crate in
                    CrateRow(crate: crate)
                }
            }
            CardSection(title: "🍂 散落在农场里的物品", trailing: "\(engine.looseItems.count) 件") {
                let loose = groupCounts(engine.looseItems)
                if loose.isEmpty {
                    EmptyHint(text: "桌面很整洁")
                } else {
                    FlowChips(items: loose.map { "\($0.0.emoji)\($0.0.displayName) x\($0.1)" })
                    ActionButton(title: "一键整理进木筐", systemImage: "sparkles", prominent: true) { engine.tidyDesktop() }
                }
            }
            CardSection(title: "🌰 种子包", trailing: "\(engine.seedFiles.count) 包") {
                let seeds = Dictionary(grouping: engine.seedFiles) { $0.payload.itemType }
                if seeds.isEmpty { EmptyHint(text: "去商店买些种子吧") }
                FlowChips(items: seeds.keys.sorted().compactMap { key in
                    guard let species = PlantSpecies(rawValue: key) else { return nil }
                    return "\(species.seedEmoji)\(species.displayName) x\(seeds[key]?.count ?? 0)"
                })
            }
            CardSection(title: "🛡 防作弊盘点") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已登记文件：\(engine.game.ledger.count)  ·  已消费 ID：\(engine.game.spentIDs.count)")
                    Text("当前枯萎克隆果：\(engine.cloneCount)  ·  累计拦截复制：\(engine.game.stats.clonesCaught)")
                    if !engine.scan.malformed.isEmpty {
                        Text("无法识别的游戏文件：\(engine.scan.malformed.count)（不会被删除）").foregroundStyle(.orange)
                    }
                    Text("每个物品都带 UUID + HMAC 签名；Cmd+C/Cmd+V 复制或手动编辑的文件会变成 🥀枯萎的克隆果。")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
        }
    }

    private func groupCounts(_ files: [ScannedFile]) -> [(ItemType, Int)] {
        var counts: [ItemType: Int] = [:]
        for file in files { if let type = file.payload.itemValue { counts[type, default: 0] += 1 } }
        return counts.sorted { $0.value > $1.value }
    }
}

private struct CrateRow: View {
    var crate: CrateSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(crate.name).font(.system(size: 12, weight: .bold))
                Text(["空", "少量", "半满", "满满当当"][crate.fillLevel]).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("\(crate.totalCount) 件 · \(crate.totalValue) 💰").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                Button {
                    NSWorkspace.shared.open(crate.url)
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
            }
            Text(crate.inventoryLine).font(.system(size: 11)).foregroundStyle(crate.totalCount == 0 ? .secondary : .primary)
            MeterBar(value: Double(crate.fillLevel) / 3, tint: Theme.wood, height: 4)
        }
        .padding(.vertical, 2)
    }
}

/// Simple wrapping chip list.
struct FlowChips: View {
    var items: [String]

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    ForEach(rows[index], id: \.self) { Chip(text: $0) }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
