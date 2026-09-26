import Foundation
import SwiftUI

struct StudioSegment: Identifiable {
    let raw: [String: Any]
    var id: Int { number("id") }
    var name: String { (raw["n"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Segment \(id + 1)" }
    var colors: [[Int]] { raw["col"] as? [[Int]] ?? [[255, 160, 80], [0, 0, 0], [0, 0, 0]] }
    var isMatrix: Bool { raw["startY"] != nil }
    var supportsWhite: Bool { number("lc") & 2 != 0 }
    var supportsCCT: Bool { number("lc") & 4 != 0 }
    var supportsRGB: Bool { raw["lc"] == nil || number("lc") & 1 != 0 }
    func number(_ key: String, default value: Int = 0) -> Int { (raw[key] as? NSNumber)?.intValue ?? value }
    func flag(_ key: String, default value: Bool = false) -> Bool { raw[key] as? Bool ?? value }
    func color(at index: Int) -> Color {
        guard colors.indices.contains(index), colors[index].count >= 3 else { return .white }
        let channels = colors[index]
        return Color(red: Double(channels[0]) / 255, green: Double(channels[1]) / 255, blue: Double(channels[2]) / 255)
    }
}
