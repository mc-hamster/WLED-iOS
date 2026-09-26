import Foundation

/// The firmware owns one staged transfer per connection. Hold a
/// permit for the complete operation, while ordinary light commands stay usable.
@MainActor
final class WorkspaceOperationQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var occupied = false
    private var waiting: [Waiter] = []

    func perform(_ operation: () async throws -> DeviceAPIResponse) async throws -> DeviceAPIResponse {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if occupied { waiting.append(Waiter(id: id, continuation: continuation)) }
                else { occupied = true; continuation.resume() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.waiting.firstIndex(where: { $0.id == id }) else { return }
                self.waiting.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
        defer {
            if waiting.isEmpty { occupied = false }
            else { waiting.removeFirst().continuation.resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}
