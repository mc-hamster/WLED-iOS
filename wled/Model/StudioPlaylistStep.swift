import Foundation

struct StudioPlaylistStep: Identifiable {
    let id = UUID()
    var preset: Int
    var duration: Double = 10
    var transition: Double = 1
}
