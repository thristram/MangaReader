import Foundation
import Network

enum SMBNetworkAccess {
  static func check(_ server: URL, timeout: TimeInterval = 30) async throws {
    guard let host = server.host,
      let port = NWEndpoint.Port(rawValue: UInt16(exactly: server.port ?? 445) ?? 0),
      port.rawValue != 0
    else { throw URLError(.badURL) }
    try await SMBNetworkProbe(host: host, port: port, timeout: timeout).run()
  }
}

private final class SMBNetworkProbe: @unchecked Sendable {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "MangaReader.SMBNetworkAccess")
  private let lock = NSLock()
  private let timeout: TimeInterval
  private var completion: CheckedContinuation<Void, Error>?
  private var finished = false
  private var deadline: DispatchWorkItem?
  // Accessed only on queue.
  private var waitingError: NWError?

  init(host: String, port: NWEndpoint.Port, timeout: TimeInterval) {
    connection = NWConnection(host: .init(host), port: port, using: .tcp)
    self.timeout = timeout
  }
  func run() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        lock.lock()
        guard !finished else {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        completion = continuation
        let deadline = DispatchWorkItem { [weak self] in self?.timedOut() }
        self.deadline = deadline
        connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        lock.unlock()
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
    }
  }
  private func changed(_ state: NWConnection.State) {
    switch state {
    case .ready: finish(.success(()))
    case .waiting(let error): waitingError = error
    case .failed(let error): finish(.failure(error))
    case .cancelled: finish(.failure(CancellationError()))
    default: break
    }
  }
  private func timedOut() {
    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
      finish(
        .failure(
          NSError(
            domain: "MangaReader.LocalNetwork", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Local network access is blocked or waiting for permission. Allow MangaReader in Settings → Privacy & Security → Local Network, then retry."
            ])))
    } else if let waitingError {
      finish(.failure(waitingError))
    } else {
      finish(.failure(URLError(.timedOut)))
    }
  }
  private func finish(_ result: Result<Void, Error>) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = completion
    completion = nil
    deadline?.cancel()
    deadline = nil
    connection.stateUpdateHandler = nil
    lock.unlock()
    connection.cancel()
    continuation?.resume(with: result)
  }
}
