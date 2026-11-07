import SwiftUI

/// Market store: seeds, animals, machines, equipment and automation upgrades.
struct ShopTab: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        VStack(spacing: 10) {
            ForEach(ShopProduct.Category.allCases) { category in
                let products = ShopProduct.all.filter { $0.category == category }
                CardSection(title: category.rawValue) {
                    ForEach(products) { product in
                        ProductRow(product: product, engine: engine)
                    }
                }
            }
        }
    }
}

private struct ProductRow: View {
    var product: ShopProduct
    @ObservedObject var engine: GameEngine

    var body: some View {
        let locked = engine.game.level < product.unlockLevel
        let owned: Bool = {
            if case .upgrade(let upgrade) = product { return engine.game.hasUpgrade(upgrade) }
            return false
        }()
        HStack(alignment: .top, spacing: 8) {
            EmojiBadge(emoji: product.emoji, size: 34)
                .opacity(locked ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(product.displayName).font(.system(size: 12, weight: .bold))
                    if locked { Chip(text: "🔒 Lv.\(product.unlockLevel)", tint: .secondary) }
                }
                Text(product.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if owned {
                Chip(text: "已拥有", tint: Theme.leaf)
            } else {
                Button("💰 \(product.price)") { engine.buy(product) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!engine.canBuy(product))
            }
        }
        .padding(.vertical, 2)
    }
}
