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
    print(
      "PASS: 5 pending CLOSE/disconnect timeouts; 5 explicit CLOSE timeouts; exactly-once C handle cleanup; callback stack lifetime; repeated close/deinit."
    )
  }
}
