import Darwin
// Synthetic socketpairs only: no NAS credentials, authentication or comic data.
import Foundation
import SMB2

@testable import AMSMB2

@main struct HandleLifecycleChecks {
  static func socketClient() throws -> (SMB2Client, Int32) {
    let client = try SMB2Client(timeout: 0.01)
    var sockets: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
    client.context!.pointee.fd = sockets[0]
    client.context!.pointee.credits = 32
    return (client, sockets[1])
  }
  static func main() throws {
    do {
      let (client, peer) = try socketClient()
      defer { Darwin.close(peer) }
      for index in 0..<10_000 {
        let result = try client.async_await(dataHandler: { _, _ in index }) { context, callback in
          SMB2Client.generic_handler(context, 0, nil, callback)
          return 0
        }
        precondition(result.result == 0 && result.data == index, "Retained callback returned stale state")
      }
      // Drain the synthetic client before closing its unanswered peer. Unlike
      // a real SMB socket, this raw socketpair has no platform socket options.
      try? client.disconnect()
      precondition(client.context == nil)
    }
    for _ in 0..<5 {
      let (client, peer) = try socketClient()
      defer { Darwin.close(peer) }
      var fileID = UUID().uuid
      let context = client.context!
      let handle = smb2_fh_from_file_id(context, &fileID)!
      var callbacks: Int32 = 0
      withUnsafeMutablePointer(to: &callbacks) { counter in
        let result = smb2_close_async(
          context, handle,
          { _, _, _, pointer in
            pointer!.assumingMemoryBound(to: Int32.self).pointee += 1
          }, counter)
        precondition(result == 0)
        // Disconnect while CLOSE still owns the file handle, then let the unanswered
        // disconnect time out. The old disconnect freed it before its close callback.
        do {
          try client.disconnect()
          fatalError("Synthetic server must time out")
        } catch {
          precondition(client.context == nil, "Timed-out context survived stack callback data")
        }
        precondition(counter.pointee == 1, "Pending CLOSE must complete exactly once")
      }
    }
    for _ in 0..<5 {
      let (client, peer) = try socketClient()
      defer { Darwin.close(peer) }
      let file = try SMB2FileHandle(fileDescriptor: UUID().uuid, on: client)
      file.close()
      precondition(
        client.context == nil, "Unanswered close must drain its callback before returning")
      file.close()  // Idempotent after a timed-out close; deinit must not close the same handle again.
    }
    // Reproduce the device stack: the wrapper still holds a C handle after
    // disconnect invalidates negotiated read size. No allocation may use -1.
    for _ in 0..<20 {
      let (client, peer) = try socketClient()
      defer { Darwin.close(peer) }
      let file = try SMB2FileHandle(fileDescriptor: UUID().uuid, on: client)
      let context = client.context!
      client.context = nil
      smb2_destroy_context(context)
      precondition(file.optimizedReadSize == 0)
      for length in [0, -1, 4096, Int(UInt32.max) + 1] {
        do { _ = try file.read(length: length); fatalError("Disconnected/invalid read must throw") } catch {}
        do { _ = try file.pread(offset: 0, length: length); fatalError("Disconnected/invalid pread must throw") } catch {}
      }
      file.close()
    }
    // A remote close must be a recoverable socket error, not SIGPIPE killing
    // the entire app. Keep the default signal disposition in this test process.
    Darwin.signal(SIGPIPE, SIG_DFL)
    for _ in 0..<5 {
      let (client, peer) = try socketClient()
      let file = try SMB2FileHandle(fileDescriptor: UUID().uuid, on: client)
      Darwin.close(peer)
      file.close()
      precondition(client.context == nil, "Broken-pipe cleanup retained a live callback")
      file.close()
    }
    print(
      "PASS: 20 read-after-disconnect sequences and invalid lengths; 10,000 retained callback round trips; 5 closed-peer writes with default SIGPIPE disposition; 5 pending CLOSE/disconnect timeouts; 5 explicit CLOSE timeouts; exactly-once C handle cleanup; retained callback lifetime; repeated close/deinit."
    )
  }
}
