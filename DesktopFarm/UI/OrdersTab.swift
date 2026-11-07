import SwiftUI

/// Dream-farm style villager order board.
struct OrdersTab: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("把物品拖进「📋订单交付箱」或放在木筐里，凑齐即可交付。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("刷新 (\(EconomyEngine.orderRefreshCost)💰)") { engine.refreshOrders() }
                    .controlSize(.small)
            }
            let pool = engine.orderPool
            ForEach(engine.game.orders) { order in
                OrderCard(order: order, availability: EconomyEngine.availability(for: order, pool: pool),
                          canFulfil: engine.canFulfil(order)) {
                    engine.completeOrder(order.id)
                }
            }
            if engine.game.orders.count < EconomyEngine.orderSlots {
                CardSection(title: "🕊 新订单路上") {
                    if let next = engine.game.nextOrderAt {
                        Text("约 \(Formatters.duration(next.timeIntervalSinceNow)) 后有村民上门").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("马上就到").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            CardSection(title: "📋 交付箱内容", trailing: "\(engine.orderBoxFiles.count) 件") {
                let counts = Dictionary(grouping: engine.orderBoxFiles.compactMap(\.payload.itemValue)) { $0 }
                if counts.isEmpty { EmptyHint(text: "交付箱是空的") }
                FlowChips(items: counts.keys.sorted { $0.rawValue < $1.rawValue }.map { "\($0.emoji)\($0.displayName) x\(counts[$0]?.count ?? 0)" })
            }
        }
    }
}

private struct OrderCard: View {
    var order: FarmOrder
    var availability: [ItemType: Int]
    var canFulfil: Bool
    var deliver: () -> Void

    var body: some View {
        CardSection(title: order.title, trailing: "剩余 \(Formatters.duration(order.expiresAt.timeIntervalSinceNow))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(order.lines, id: \.self) { line in
                    let have = availability[line.item, default: 0]
                    HStack {
                        Text("\(line.item.emoji) \(line.item.displayName)").font(.system(size: 12))
                        Spacer()
                        Text("\(min(have, line.quantity))/\(line.quantity)")
                            .font(.system(size: 12, weight: .bold)).monospacedDigit()
                            .foregroundStyle(have >= line.quantity ? Theme.leaf : .secondary)
                    }
                    MeterBar(value: Double(have) / Double(max(line.quantity, 1)), tint: have >= line.quantity ? Theme.leaf : .orange, height: 4)
                }
                HStack {
                    Chip(text: "💰 \(order.rewardCoins)", tint: Theme.gold)
                    Chip(text: "⭐️ \(order.rewardXP) XP", tint: .purple)
                    Spacer()
                    Button("交付订单", action: deliver)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.leaf)
                        .controlSize(.small)
                        .disabled(!canFulfil)
                }
            }
        }
    }
}
