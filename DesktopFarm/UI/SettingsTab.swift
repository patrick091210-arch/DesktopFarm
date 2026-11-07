import SwiftUI

/// Preferences, Finder bridge status, statistics and maintenance.
struct SettingsTab: View {
    @ObservedObject var engine: GameEngine
    @EnvironmentObject private var coordinator: GameCoordinator
    @EnvironmentObject private var settings: AppSettings
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 10) {
            CardSection(title: "🖥 桌面层") {
                Toggle("显示桌面精灵覆盖层", isOn: $settings.overlayEnabled)
                Toggle("显示桌面菜园 / 机器地块", isOn: $settings.gardenVisible)
                Toggle("同步 Finder 图标坐标（AppleScript）", isOn: $settings.finderBridgeEnabled)
                Text(coordinator.bridgeStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                ActionButton(title: "重新绘制全部图标", systemImage: "paintbrush.fill") { coordinator.refreshIcons() }
            }
            .toggleStyle(.switch)
            .font(.system(size: 12))

            CardSection(title: "🔊 音效") {
                Toggle("启用音效", isOn: $settings.soundEnabled).toggleStyle(.switch)
                HStack {
                    Image(systemName: "speaker.fill")
                    Slider(value: $settings.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill")
                }
                .disabled(!settings.soundEnabled)
            }
            .font(.system(size: 12))

            CardSection(title: "⏩ 游戏速度") {
                Picker("", selection: $settings.speed) {
                    Text("1×").tag(1.0)
                    Text("5×").tag(5.0)
                    Text("20×").tag(20.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("加速同样作用于作物、动物与加工机。").font(.system(size: 10)).foregroundStyle(.secondary)
            }

            CardSection(title: "📊 农场统计") {
                let stats = engine.game.stats
                VStack(alignment: .leading, spacing: 3) {
                    Text("收获作物 \(stats.cropsHarvested) · 果树掉落 \(stats.fruitsDropped) · 动物产出 \(stats.animalProducts)")
                    Text("加工成品 \(stats.goodsProcessed) · 出货 \(stats.itemsShipped) 件 · 完成订单 \(stats.ordersCompleted)")
                    Text("累计收入 \(stats.coinsEarned) 💰 · 拦截克隆 \(stats.clonesCaught)")
                }
                .font(.system(size: 11))
            }

            CardSection(title: "💾 存档") {
                Text(engine.saveManager.saveURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    ActionButton(title: "立即保存", systemImage: "square.and.arrow.down") { engine.save(); engine.toast = Toast(icon: "💾", text: "已保存") }
                    ActionButton(title: "显示存档", systemImage: "folder") { coordinator.revealSaveFolder() }
                    ActionButton(title: "重新扫描", systemImage: "arrow.clockwise") { engine.reconcile() }
                }
                ActionButton(title: "重置农场…", systemImage: "trash") { confirmReset = true }
                    .confirmationDialog("确定要重置农场吗？", isPresented: $confirmReset) {
                        Button("重置（只删除游戏文件）", role: .destructive) { engine.resetGame() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("会删除农场目录中所有带合法签名的游戏文件和空的游戏文件夹，你自己的文件不会被触碰。")
                    }
            }

            Button("退出桌面牧场") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }
}
