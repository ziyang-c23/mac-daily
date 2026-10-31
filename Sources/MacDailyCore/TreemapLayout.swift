import Foundation

public struct TreemapWeight: Sendable, Equatable {
    public var id: String
    public var weight: Double
    public init(id: String, weight: Double) { self.id = id; self.weight = weight }
}
public struct TreemapTile: Sendable, Equatable, Identifiable {
    public var id: String
    public var frame: CGRect
    public init(id: String, frame: CGRect) { self.id = id; self.frame = frame }
}
/// Original squarified layout. Geometry is shared by drawing and hit testing.
public enum TreemapLayout {
    public static func layout(items: [TreemapWeight], in bounds: CGRect) -> [TreemapTile] {
        guard WindowGeometry.isValid(bounds) else { return [] }
        var seen = Set<String>()
        let valid = items.filter { $0.weight.isFinite && $0.weight > 0 && seen.insert($0.id).inserted }
            .sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }
        guard let maximum = valid.first?.weight else { return [] }
        let scaledSum = valid.reduce(0) { $0 + $1.weight / maximum }
        guard scaledSum.isFinite, scaledSum > 0, (bounds.width * bounds.height).isFinite else { return [] }
        let weighted = valid.map { TreemapWeight(id: $0.id, weight: ($0.weight / maximum / scaledSum) * bounds.width * bounds.height) }
        var remaining = bounds, result: [TreemapTile] = [], row: [TreemapWeight] = []
        func worst(_ values: [TreemapWeight], side: Double) -> Double {
            guard let minimum = values.map(\.weight).min(), minimum > 0, side > 0 else { return .infinity }
            let sum = values.reduce(0) { $0 + $1.weight }, maximum = values.map(\.weight).max()!
            return max(side * side * maximum / (sum * sum), sum * sum / (side * side * minimum))
        }
        func emit(_ row: [TreemapWeight]) {
            let sum = row.reduce(0) { $0 + $1.weight }
            guard sum > 0, remaining.width > 0, remaining.height > 0 else { return }
            if remaining.width >= remaining.height {
                let width = min(remaining.width, sum / remaining.height)
                var y = remaining.minY
                for (index, item) in row.enumerated() {
                    let height = index == row.count - 1 ? remaining.maxY - y : min(remaining.maxY - y, item.weight / width)
                    result.append(.init(id: item.id, frame: .init(x: remaining.minX, y: y, width: width, height: max(0, height))))
                    y += height
                }
                remaining = .init(x: remaining.minX + width, y: remaining.minY,
                                  width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = min(remaining.height, sum / remaining.width)
                var x = remaining.minX
                for (index, item) in row.enumerated() {
                    let width = index == row.count - 1 ? remaining.maxX - x : min(remaining.maxX - x, item.weight / height)
                    result.append(.init(id: item.id, frame: .init(x: x, y: remaining.minY, width: max(0, width), height: height)))
                    x += width
                }
                remaining = .init(x: remaining.minX, y: remaining.minY + height,
                                  width: remaining.width, height: max(0, remaining.height - height))
            }
        }
        for item in weighted {
            let side = min(remaining.width, remaining.height)
            if row.isEmpty || worst(row + [item], side: side) <= worst(row, side: side) { row.append(item) }
            else { emit(row); row = [item] }
        }
        emit(row)
        return result
    }
    public static func hitTest(_ point: CGPoint, tiles: [TreemapTile]) -> String? {
        tiles.first { $0.frame.contains(point) }?.id
    }
}
