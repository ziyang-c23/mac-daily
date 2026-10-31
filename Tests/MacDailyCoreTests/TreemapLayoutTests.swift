import Foundation
import Testing
@testable import MacDailyCore

struct TreemapLayoutTests {
    @Test func areasAreProportionalWithinBoundsAndDoNotOverlap() {
        let bounds = CGRect(x: -20, y: 30, width: 800, height: 500)
        let items = [TreemapWeight(id: "large",weight: 8), .init(id: "medium",weight: 4), .init(id: "small",weight: 1)]
        let tiles = TreemapLayout.layout(items: items, in: bounds)
        #expect(tiles.count == 3)
        for tile in tiles {
            #expect(bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(tile.frame))
            let weight = items.first { $0.id == tile.id }!.weight
            #expect(abs(tile.frame.width * tile.frame.height / (bounds.width * bounds.height) - weight / 13) < 0.000001)
            #expect(TreemapLayout.hitTest(CGPoint(x: tile.frame.midX, y: tile.frame.midY), tiles: tiles) == tile.id)
        }
        for left in tiles.indices {
            for right in tiles.indices where left < right {
                let overlap = tiles[left].frame.intersection(tiles[right].frame)
                #expect(overlap.isNull || overlap.width * overlap.height < 0.00001)
            }
        }
    }
    @Test func emptyInvalidAndExtremeWeightsAreHandled() {
        let bounds = CGRect(x: 0,y: 0,width: 100,height: 100)
        #expect(TreemapLayout.layout(items: [], in: bounds).isEmpty)
        #expect(TreemapLayout.layout(items: [.init(id: "zero",weight: 0), .init(id: "nan",weight: .nan)], in: bounds).isEmpty)
        #expect(TreemapLayout.layout(items: [.init(id: "a",weight: 1)], in: .zero).isEmpty)
        let result = TreemapLayout.layout(items: [.init(id: "a",weight: .greatestFiniteMagnitude), .init(id: "b",weight: .greatestFiniteMagnitude)], in: bounds)
        #expect(result.count == 2); #expect(abs(result[0].frame.width * result[0].frame.height - 5000) < 0.00001)
    }
}
