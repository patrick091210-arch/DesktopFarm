import SwiftUI

/// Shipping bin overview and settlement.
struct ShippingTab: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        let files = engine.shippingFiles
        VStack(spacing: 10) {
            CardSection(title: "💰 出货箱", trailing: "\(files.count) 件") {
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("待结算金额").font(.system(size: 12))
                        Spacer()
                        Text("\(engine.shippingValue) 💰").font(.system(size: 22, weight: .heavy)).monospacedDigit()
                    }
                    Text("预计获得 \(Progression.shippingXP(coins: engine.shippingValue)) XP · 每天 0 点自动结算")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        ActionButton(title: "打开出货箱", systemImage: "folder") {
                            if let folder = engine.scan.folders(role: .shippingBin).first { NSWorkspace.shared.open(folder.url) }
                        }
                        ActionButton(title: "立即出货", systemImage: "dollarsign.circle.fill", prominent: true) { engine.shipNow() }
                            .disabled(files.isEmpty)
                    }
                }
            }
            CardSection(title: "📦 箱内明细") {
                if files.isEmpty { EmptyHint(text: "把任意 .item 文件拖进「💰出货箱」文件夹即可出售") }
                ForEach(files) { file in
                    if let type = file.payload.itemValue {
                        let quality = file.payload.qualityValue
                        HStack {
                            Text("\(type.emoji) \(type.displayName)").font(.system(size: 12))
                            if quality != .normal { Chip(text: "\(quality.label)\(quality.stars)", tint: Theme.gold) }
                            Spacer()
                            Text("\(type.price(quality: quality)) 💰").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
            }
            CardSection(title: "💹 今日行情") {
                let rows = ItemType.allCases.filter { $0 != .witheredClone }
                ForEach(rows) { type in
                    HStack {
                        Text("\(type.emoji) \(type.displayName)").font(.system(size: 11))
                        Spacer()
                        Text("\(type.basePrice) / 银 \(type.price(quality: .silver)) / 金 \(type.price(quality: .gold))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}
