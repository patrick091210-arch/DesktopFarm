import AppKit

/// Kind of desktop-layer station drawn for a farm object.
enum StationKind: Equatable, Sendable {
    case plant
    case machine
    case trough
}

struct Station: Identifiable, Equatable, Sendable {
    var id: UUID
    var kind: StationKind
    /// Global (Cocoa screen) centre of the station's base.
    var center: CGPoint
}

/// Grid-coordinate mapping between farm objects and desktop positions.
///
/// The "farm strip" lives at the bottom-left of the main screen: plants first, then
/// machines, then troughs. Loose food gets a deterministic ground spot.
@MainActor
final class WorldLayout {
    static let plotSize = CGSize(width: 92, height: 108)
    static let columns = 9

    var screens: [NSScreen] { NSScreen.screens }

    var gardenFrame: CGRect {
        (NSScreen.screens.first?.visibleFrame) ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func stations(plants: [UUID], machines: [UUID], troughs: [UUID]) -> [Station] {
        var result: [Station] = []
        let ordered: [(UUID, StationKind)] = plants.map { ($0, .plant) } + machines.map { ($0, .machine) } + troughs.map { ($0, .trough) }
        let frame = gardenFrame
        for (index, entry) in ordered.enumerated() {
            let column = index % Self.columns
            let row = index / Self.columns
            let x = frame.minX + 28 + Self.plotSize.width * (CGFloat(column) + 0.5)
            let y = frame.minY + 22 + Self.plotSize.height * CGFloat(row)
            result.append(Station(id: entry.0, kind: entry.1, center: CGPoint(x: x, y: y)))
        }
        return result
    }

    /// Deterministic ground spot for a loose food file.
    func groundSpot(for id: UUID) -> CGPoint {
        let frame = gardenFrame
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let hx = Double(bytes[0]) / 255
        let hy = Double(bytes[1]) / 255
        return CGPoint(
            x: frame.minX + frame.width * (0.45 + 0.4 * hx),
            y: frame.minY + 26 + frame.height * (0.06 + 0.14 * hy)
        )
    }

    /// Region animals roam in on a given screen (lower part of the visible frame).
    func petArea(screenIndex: Int) -> CGRect {
        let list = screens
        let frame = list.indices.contains(screenIndex) ? list[screenIndex].visibleFrame : gardenFrame
        return CGRect(x: frame.minX + 20, y: frame.minY + 16, width: frame.width - 40, height: frame.height * 0.38)
    }

    func globalPoint(from unit: UnitPoint2D, screenIndex: Int) -> CGPoint {
        let list = screens
        let frame = list.indices.contains(screenIndex) ? list[screenIndex].visibleFrame : gardenFrame
        let clamped = unit.clamped()
        return CGPoint(x: frame.minX + frame.width * clamped.x, y: frame.minY + frame.height * clamped.y)
    }

    func unitPoint(from point: CGPoint) -> (UnitPoint2D, Int) {
        let list = screens
        let index = list.firstIndex { $0.frame.contains(point) } ?? 0
        let frame = list.indices.contains(index) ? list[index].visibleFrame : gardenFrame
        let unit = UnitPoint2D(
            x: Double((point.x - frame.minX) / max(frame.width, 1)),
            y: Double((point.y - frame.minY) / max(frame.height, 1))
        ).clamped()
        return (unit, index)
    }
}
