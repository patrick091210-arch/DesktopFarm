import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case farm = "农场"
    case inventory = "仓库"
    case orders = "订单"
    case shop = "商店"
    case shipping = "出货"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .farm: return "leaf.fill"
        case .inventory: return "shippingbox.fill"
        case .orders: return "list.clipboard.fill"
        case .shop: return "cart.fill"
        case .shipping: return "dollarsign.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// The menu-bar control panel: HUD header, tabs and toasts.
struct ControlPanelView: View {
    @EnvironmentObject private var coordinator: GameCoordinator

    var body: some View {
        Group {
            if let engine = coordinator.engine {
                PanelContent(engine: engine)
            } else if let error = coordinator.startupError {
                VStack(spacing: 12) {
                    Text("🥀").font(.system(size: 40))
                    Text(error).multilineTextAlignment(.center).font(.system(size: 12))
                    Button("退出") { NSApp.terminate(nil) }
                }
                .padding(24)
            } else {
                ProgressView("农场加载中…").padding(40)
            }
        }
        .frame(width: 430, height: 620)
    }
}

private struct PanelContent: View {
    @ObservedObject var engine: GameEngine
    @State private var tab: PanelTab = .farm

    var body: some View {
        VStack(spacing: 0) {
            HUDHeader(engine: engine)
            Picker("", selection: $tab) {
                ForEach(PanelTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .farm: FarmTab(engine: engine)
                    case .inventory: InventoryTab(engine: engine)
                    case .orders: OrdersTab(engine: engine)
                    case .shop: ShopTab(engine: engine)
                    case .shipping: ShippingTab(engine: engine)
                    case .settings: SettingsTab(engine: engine)
                    }
                }
                .padding(10)
            }
            if let toast = engine.toast {
                ToastBar(toast: toast) { engine.toast = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: engine.toast)
    }
}

private struct HUDHeader: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        let level = engine.game.level
        let progress = Progression.levelProgress(xp: engine.game.xp)
        let next = Progression.xpRequired(forLevel: level + 1)
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("🌾").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text("桌面牧场 DesktopHarvest").font(.system(size: 14, weight: .heavy))
                    Text(engine.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("💰 \(engine.game.coins)").font(.system(size: 15, weight: .heavy)).monospacedDigit()
                    let pending = engine.shippingValue
                    if pending > 0 {
                        Text("待结算 +\(pending)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.leaf)
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Lv.\(level)").font(.system(size: 12, weight: .black)).foregroundStyle(Theme.gold)
                MeterBar(value: progress, tint: Theme.gold, height: 8)
                Text(level >= Progression.maxLevel ? "MAX" : "\(engine.game.xp)/\(next) XP")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(12)
    }
}

private struct ToastBar: View {
    var toast: Toast
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(toast.icon)
            Text(toast.text).font(.system(size: 11, weight: .medium)).lineLimit(3)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
