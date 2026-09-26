import Foundation

/// WLED's effect metadata retains empty fields: an empty slot means the control is hidden.
struct StudioEffectParameter: Identifiable, Equatable {
    let key: String
    let title: String
    let isToggle: Bool
    let maximum: Double
    var id: String { key }

    static func controls(metadata: String?, effect: Int) -> [Self] {
        let keys = ["sx", "ix", "c1", "c2", "c3", "o1", "o2", "o3"]
        let titles = ["Speed", "Intensity", "Custom 1", "Custom 2", "Custom 3", "Option 1", "Option 2", "Option 3"]
        let fields: [String]
        if let metadata, !metadata.isEmpty {
            fields = String(metadata.split(separator: ";", omittingEmptySubsequences: false).first ?? "")
                .split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        } else {
            fields = Array(repeating: "!", count: effect < 128 ? 2 : 5)
        }
        return fields.prefix(keys.count).enumerated().compactMap { index, value in
            let name = String(value.split(separator: "=", omittingEmptySubsequences: false).first ?? "")
            guard !name.isEmpty else { return nil }
            return Self(key: keys[index], title: name == "!" ? titles[index] : name,
                        isToggle: index >= 5, maximum: index == 4 ? 31 : 255)
        }
    }
}
