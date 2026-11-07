import AppKit
import Foundation

/// Asset-free sound effects: short chiptune cues synthesised into in-memory WAVs.
@MainActor
final class SoundManager {
    enum Cue: String, CaseIterable {
        case water, harvest, pop, coin, machineDone, machineStart
        case chicken, cow, sheep, eat, plant, crack, levelUp, error, click
    }

    var isEnabled = true
    var volume: Float = 0.35
    private var cache: [Cue: NSSound] = [:]
    private var lastPlayed: [Cue: Date] = [:]

    func play(_ cue: Cue) {
        guard isEnabled else { return }
        let now = Date()
        if let last = lastPlayed[cue], now.timeIntervalSince(last) < 0.08 { return }
        lastPlayed[cue] = now
        guard let sound = sound(for: cue) else { return }
        sound.volume = volume
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    func play(for event: FarmEvent) {
        switch event {
        case .watered: play(.water)
        case .ripened: play(.pop)
        case .harvested, .fruitDropped: play(.harvest)
        case .planted: play(.plant)
        case .petAdded(let id), .petProduced(let id, _):
            _ = id
            play(.pop)
        case .petRemoved: play(.click)
        case .petAte: play(.eat)
        case .machineStarted: play(.machineStart)
        case .machineFinished: play(.machineDone)
        case .shipped, .orderCompleted, .purchased: play(.coin)
        case .cloneDetected: play(.crack)
        case .levelUp: play(.levelUp)
        case .tidied: play(.click)
        case .failure: play(.error)
        }
    }

    func playVoice(_ species: AnimalSpecies) {
        switch species {
        case .chicken: play(.chicken)
        case .cow: play(.cow)
        case .sheep: play(.sheep)
        }
    }

    private func sound(for cue: Cue) -> NSSound? {
        if let cached = cache[cue] { return cached }
        guard let data = Synth.render(Synth.notes(for: cue)), let sound = NSSound(data: data) else { return nil }
        cache[cue] = sound
        return sound
    }
}

/// Tiny additive synthesiser (sine + square harmonic + noise, pitch slides, vibrato).
enum Synth {
    struct Note {
        var frequency: Double
        var duration: Double
        var gain: Double = 0.4
        var square: Double = 0.12
        var noise: Double = 0
        var slide: Double = 0
        var vibrato: Double = 0
    }

    static let sampleRate = 22_050

    static func notes(for cue: SoundManager.Cue) -> [Note] {
        switch cue {
        case .water:
            return [Note(frequency: 900, duration: 0.05, gain: 0.18, square: 0, noise: 0.5, slide: -400),
                    Note(frequency: 620, duration: 0.07, gain: 0.25, square: 0.02, noise: 0.25, slide: -260),
                    Note(frequency: 480, duration: 0.09, gain: 0.2, square: 0.02, noise: 0.2, slide: -200)]
        case .harvest:
            return [Note(frequency: 660, duration: 0.06), Note(frequency: 880, duration: 0.06), Note(frequency: 1320, duration: 0.12, gain: 0.32)]
        case .pop:
            return [Note(frequency: 520, duration: 0.07, gain: 0.35, square: 0.05, slide: 700)]
        case .coin:
            return [Note(frequency: 988, duration: 0.07, gain: 0.3, square: 0.25), Note(frequency: 1319, duration: 0.18, gain: 0.3, square: 0.25)]
        case .machineDone:
            return [Note(frequency: 784, duration: 0.09), Note(frequency: 1047, duration: 0.09), Note(frequency: 1319, duration: 0.09), Note(frequency: 1568, duration: 0.22, gain: 0.3)]
        case .machineStart:
            return [Note(frequency: 180, duration: 0.08, gain: 0.3, square: 0.4, noise: 0.15, slide: 120),
                    Note(frequency: 240, duration: 0.1, gain: 0.25, square: 0.4, noise: 0.1)]
        case .chicken:
            return [Note(frequency: 820, duration: 0.05, gain: 0.25, square: 0.4, slide: 300),
                    Note(frequency: 760, duration: 0.05, gain: 0.25, square: 0.4, slide: -200),
                    Note(frequency: 980, duration: 0.11, gain: 0.25, square: 0.4, slide: -500)]
        case .cow:
            return [Note(frequency: 150, duration: 0.18, gain: 0.4, square: 0.35, slide: 40, vibrato: 4),
                    Note(frequency: 175, duration: 0.42, gain: 0.35, square: 0.35, slide: -60, vibrato: 6)]
        case .sheep:
            return [Note(frequency: 420, duration: 0.45, gain: 0.3, square: 0.3, slide: -40, vibrato: 18)]
        case .eat:
            return [Note(frequency: 300, duration: 0.04, gain: 0.25, square: 0.1, noise: 0.6),
                    Note(frequency: 0, duration: 0.04, gain: 0),
                    Note(frequency: 280, duration: 0.04, gain: 0.25, square: 0.1, noise: 0.6)]
        case .plant:
            return [Note(frequency: 392, duration: 0.07, gain: 0.3), Note(frequency: 523, duration: 0.1, gain: 0.3)]
        case .crack:
            return [Note(frequency: 220, duration: 0.05, gain: 0.35, square: 0.2, noise: 0.8, slide: -150),
                    Note(frequency: 130, duration: 0.16, gain: 0.3, square: 0.3, noise: 0.5, slide: -60)]
        case .levelUp:
            return [Note(frequency: 523, duration: 0.09), Note(frequency: 659, duration: 0.09), Note(frequency: 784, duration: 0.09),
                    Note(frequency: 1047, duration: 0.12), Note(frequency: 784, duration: 0.07), Note(frequency: 1047, duration: 0.3, gain: 0.35)]
        case .error:
            return [Note(frequency: 220, duration: 0.1, gain: 0.3, square: 0.4), Note(frequency: 165, duration: 0.16, gain: 0.3, square: 0.4)]
        case .click:
            return [Note(frequency: 1400, duration: 0.025, gain: 0.2, square: 0.1, noise: 0.2)]
        }
    }

    static func render(_ notes: [Note]) -> Data? {
        var samples: [Int16] = []
        var seed: UInt32 = 0x1234_5678
        for note in notes {
            let count = Int(note.duration * Double(sampleRate))
            var phase = 0.0
            for index in 0..<count {
                let t = Double(index) / Double(sampleRate)
                let progress = Double(index) / Double(max(count, 1))
                var frequency = note.frequency + note.slide * progress
                if note.vibrato > 0 { frequency += sin(2 * .pi * 6 * t) * note.vibrato }
                phase += 2 * .pi * frequency / Double(sampleRate)
                let attack = min(1, Double(index) / (0.004 * Double(sampleRate)))
                let release = min(1, Double(count - index) / (0.02 * Double(sampleRate)))
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = (Double(seed >> 8) / Double(1 << 24)) * 2 - 1
                var value = sin(phase) * (1 - note.square) + (sin(phase) >= 0 ? 1 : -1) * note.square
                value = value * (1 - note.noise) + noise * note.noise
                value *= note.gain * attack * release
                samples.append(Int16(max(-1, min(1, value)) * 32_000))
            }
        }
        guard !samples.isEmpty else { return nil }
        return wav(samples)
    }

    private static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples { append(sample) }
        return data
    }
}
