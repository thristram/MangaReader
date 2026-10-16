import Foundation

/// Bounds work without repeatedly waking every queued task on the main actor.
public actor AsyncPermitPool {
  private var available: Int
  private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
  public init(limit: Int) {
    precondition(limit > 0)
    available = limit
  }
  public func acquire() async throws {
    try Task.checkCancellation()
    if available > 0 {
      available -= 1
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append((id, continuation))
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
    // A cancelled task can receive a permit just before its cancellation is processed.
    if Task.isCancelled {
      release()
      throw CancellationError()
    }
  }
  public func release() {
    if waiters.isEmpty { available += 1 } else { waiters.removeFirst().1.resume() }
  }
  private func cancel(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
    waiters.remove(at: index).1.resume(throwing: CancellationError())
  }
}
