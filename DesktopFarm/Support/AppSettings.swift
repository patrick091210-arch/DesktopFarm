import Combine
import Foundation

enum Formatters {
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(secs)秒" }
        return "\(secs)秒"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// User preferences backed by UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "dh.sound") } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: "dh.volume") } }
    @Published var overlayEnabled: Bool { didSet { defaults.set(overlayEnabled, forKey: "dh.overlay") } }
    @Published var gardenVisible: Bool { didSet { defaults.set(gardenVisible, forKey: "dh.garden") } }
    @Published var finderBridgeEnabled: Bool { didSet { defaults.set(finderBridgeEnabled, forKey: "dh.finderBridge") } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "dh.speed") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        soundEnabled = defaults.object(forKey: "dh.sound") as? Bool ?? true
        volume = defaults.object(forKey: "dh.volume") as? Double ?? 0.35
        overlayEnabled = defaults.object(forKey: "dh.overlay") as? Bool ?? true
        gardenVisible = defaults.object(forKey: "dh.garden") as? Bool ?? true
        finderBridgeEnabled = defaults.object(forKey: "dh.finderBridge") as? Bool ?? true
        speed = defaults.object(forKey: "dh.speed") as? Double ?? 1
    }
}
