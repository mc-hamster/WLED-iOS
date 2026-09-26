import Foundation

struct StudioPreset: Identifiable {
    let id: Int
    let name: String
    let isPlaylist: Bool
    let raw: [String: Any]

    static func validName(_ value: String) -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 32 { name.removeLast() }
        return name
    }

    static func decode(_ dictionary: [String: Any]) -> [Self] {
        dictionary.compactMap { key, value in
            guard let id = Int(key), (1...250).contains(id), let entry = value as? [String: Any], !entry.isEmpty else { return nil }
            let title = (entry["n"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Scene \(id)"
            return Self(id: id, name: title, isPlaylist: entry["playlist"] != nil, raw: entry)
        }.sorted { $0.id < $1.id }
    }
}
