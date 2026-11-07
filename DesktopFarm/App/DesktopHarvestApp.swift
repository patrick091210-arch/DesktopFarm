import SwiftUI

@main
struct DesktopHarvestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = GameCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            ControlPanelView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.settings)
        } label: {
            MenuBarLabel(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Status-bar label: wheat icon plus live coin balance.
struct MenuBarLabel: View {
    @ObservedObject var coordinator: GameCoordinator

    var body: some View {
        if let engine = coordinator.engine {
            MenuBarCoins(engine: engine)
        } else {
            Text("🌾")
        }
    }
}

private struct MenuBarCoins: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        let pending = engine.shippingValue
        Text(pending > 0 ? "🌾 \(engine.game.coins) (+\(pending))" : "🌾 \(engine.game.coins)")
            .monospacedDigit()
    }
}
