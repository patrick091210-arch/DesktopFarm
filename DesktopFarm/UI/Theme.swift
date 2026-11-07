import SwiftUI

enum Theme {
    static let leaf = Color(red: 0.27, green: 0.66, blue: 0.33)
    static let water = Color(red: 0.23, green: 0.6, blue: 1.0)
    static let gold = Color(red: 0.96, green: 0.68, blue: 0.1)
    static let wood = Color(red: 0.62, green: 0.42, blue: 0.24)
    static let card = Color.primary.opacity(0.05)
    static let cardStroke = Color.primary.opacity(0.08)
}

/// Rounded capsule progress bar.
struct MeterBar: View {
    var value: Double
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

/// Section card container.
struct CardSection<Content: View>: View {
    var title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .bold))
                Spacer()
                if let trailing {
                    Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.cardStroke))
    }
}

/// Small pill label, e.g. `🍎苹果 x12`.
struct Chip: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

struct EmojiBadge: View {
    var emoji: String
    var size: CGFloat = 28

    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.7))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(0.06)))
    }
}

/// Compact bordered action button.
struct ActionButton: View {
    var title: String
    var systemImage: String?
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(prominent ? Theme.leaf : nil)
        .controlSize(.small)
    }
}

struct EmptyHint: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
    }
}
