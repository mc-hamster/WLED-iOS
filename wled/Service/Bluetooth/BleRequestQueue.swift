import Foundation

/// The bridge has no request identifiers, so every consumer shares one FIFO.
/// Cancelling a queued request removes it. A request already sent is drained
/// before the next begins; its cancelled caller receives no late response.
@MainActor
final class BleRequestQueue {
    private struct Entry {
        let id: UUID
        let method: String
        let path: String
        let body: String
        var continuation: CheckedContinuation<BleBridgeResponse, Error>?
    }

    private let session: any BleBridgeConnection
    private var pending: [Entry] = []
    private var active: Entry?
    private var worker: Task<Void, Never>?

    init(session: any BleBridgeConnection) { self.session = session }

    func request(method: String, path: String, body: String = "") async throws -> BleBridgeResponse {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(Entry(id: id, method: method, path: path, body: body, continuation: continuation))
                startNext()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    func cancelAll(throwing error: Error = CancellationError()) {
        worker?.cancel()
        worker = nil
        let requests = pending + (active.map { [$0] } ?? [])
        pending.removeAll()
        active = nil
        for request in requests { request.continuation?.resume(throwing: error) }
    }

    private func cancel(_ id: UUID) {
        if active?.id == id {
            let continuation = active?.continuation
            active?.continuation = nil
            continuation?.resume(throwing: CancellationError())
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index).continuation?.resume(throwing: CancellationError())
        }
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        active = request
        worker = Task { [weak self, session] in
            let result: Result<BleBridgeResponse, Error>
            do { result = .success(try await session.request(method: request.method, path: request.path, body: request.body)) } catch { result = .failure(error) }
            guard let self, self.active?.id == request.id else { return }
            let continuation = self.active?.continuation
            self.active = nil
            self.worker = nil
            continuation?.resume(with: result)
            self.startNext()
        }
    }
}
