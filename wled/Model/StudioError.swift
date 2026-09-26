import Foundation

struct StudioError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
