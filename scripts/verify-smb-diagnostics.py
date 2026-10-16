#!/usr/bin/env python3
"""Check real SMB transport and protocol failures against synthetic servers.

After the Mac build, checks socket error lifetime and protocol-triggered socket
closure. No NAS address, real credentials or library files.
"""
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parents[1]
products = root / ".build/xcode-swiftui-mac/Build/Products/Debug"
include = root / "packages/AMSMB2/Dependencies/libsmb2/include"
with tempfile.TemporaryDirectory(prefix="smb-diagnostics-", dir=root / ".build") as directory:
    directory = Path(directory)
    source = directory / "Check.swift"
    source.write_text('''import Foundation
import AMSMB2
@main struct Check {
  static func main() async throws {
    let port = CommandLine.arguments[1]
    try await SMBNetworkAccess.check(URL(string: "smb://127.0.0.1:" + port)!, timeout: 3)
    let cancelled = Task {
      try await SMBNetworkAccess.check(URL(string: "smb://127.0.0.1:1")!, timeout: 3)
    }
    cancelled.cancel()
    do { try await cancelled.value; fatalError("Cancelled network check must fail") }
    catch is CancellationError {}
    print("PASS: Network.framework reachability and cancellation.")
    for (index, testPort) in CommandLine.arguments.dropFirst().enumerated() {
      let client = SMB2Manager(
        url: URL(string: "smb://127.0.0.1:" + testPort)!,
        credential: URLCredential(user: "synthetic", password: "synthetic", persistence: .none))!
      client.timeout = 5
      if index == 4 {
        // The synthetic guest server tests successful callbacks and logoff,
        // not encryption. App connections still require encryption.
        try await client.connectShare(name: "synthetic", encrypted: false)
        try await client.disconnectShare()
        print("PASS: successful guest callbacks and intentional logoff socket closure.")
        continue
      }
      do {
        try await client.connectShare(name: "synthetic", encrypted: true)
        fatalError("The synthetic server must not establish a session")
      } catch {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = ["socket", "STATUS_ACCESS_DENIED", "STATUS_LOGON_FAILURE",
                        "does not support encryption"][index]
        guard detail.contains(expected), !detail.contains("errno:9") else {
          fatalError("SMB failure was masked; expected " + expected + ": " + detail)
        }
        let codes: [POSIXErrorCode?] = [nil, .EACCES, .ECONNREFUSED, .ENOTCONN]
        if let code = codes[index] {
          let failure = error as NSError
          guard failure.domain == NSPOSIXErrorDomain, failure.code == Int(code.rawValue) else {
            fatalError("SMB failure code was masked: " + String(describing: failure))
          }
        }
        print("PASS: encrypted SMB failure preserves its cause: " + detail)
      }
    }
  }
}
''')
    executable = directory / "Check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos26.0",
        "-I", str(products),
        "-F", str(products / "PackageFrameworks"), "-framework", "AMSMB2",
        "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap"),
        "-Xcc", "-I" + str(include),
        "-Xlinker", "-rpath", "-Xlinker", str(products / "PackageFrameworks"),
        str(root / "apps/apple/Shared/SMBNetworkAccess.swift"),
        str(source), "-o", str(executable),
    ], check=True)
    def receive_frame(connection):
        def exact(size):
            data = b""
            while len(data) < size:
                part = connection.recv(size - len(data))
                assert part, "Client closed before sending an SMB frame"
                data += part
            return data
        return exact(int.from_bytes(exact(4), "big"))

    def reply(connection, request, status, body):
        header = bytearray(64)
        header[:4] = b"\xfeSMB"
        struct.pack_into("<HHIHHI", header, 4, 64, 1, status,
                         struct.unpack_from("<H", request, 12)[0], 1, 1)
        header[24:32] = request[24:32]
        header[40:48] = request[40:48]
        message = header + body
        connection.sendall(struct.pack(">I", len(message)) + message)

    def error_reply(connection, request, status):
        reply(connection, request, status, struct.pack("<HBBI", 9, 0, 0, 0))

    def negotiate_reply(connection, request, encryption):
        reply(connection, request, 0, struct.pack(
            "<HHHH16sIIIIQQHHI", 65, 1, 0x302, 0, bytes(16),
            0x40 if encryption else 0, 1048576, 1048576, 1048576, 0, 0, 128, 0, 0))

    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(10)
        observed = []

        def reset_connection():
            for scenario in ("probe", "reset", "negotiate", "session", "encryption", "logoff"):
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(5)
                    if scenario == "probe":
                        assert connection.recv(4096) == b"", "Reachability must not send SMB data"
                    else:
                        request = receive_frame(connection)
                        assert request[:4] == b"\xfeSMB"
                        if scenario == "reset":
                            connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                        else:
                            if scenario == "negotiate":
                                error_reply(connection, request, 0xC0000022)
                            else:
                                negotiate_reply(connection, request, encryption=scenario == "session")
                                if scenario == "session":
                                    request = receive_frame(connection)
                                    assert struct.unpack_from("<H", request, 12)[0] == 1
                                    error_reply(connection, request, 0xC000006D)
                                elif scenario == "logoff":
                                    # Minimal guest session, tree, echo, disconnect and logoff.
                                    # No NTLM verification, encrypted data or file access is claimed.
                                    for command, body in (
                                        (1, struct.pack("<HHHH", 9, 1, 0, 0)),
                                        (3, struct.pack("<HBBIII", 16, 1, 0, 0, 0, 0x1F01FF)),
                                        (13, struct.pack("<HH", 4, 0)),
                                        (4, struct.pack("<HH", 4, 0)),
                                        (2, struct.pack("<HH", 4, 0)),
                                    ):
                                        request = receive_frame(connection)
                                        assert struct.unpack_from("<H", request, 12)[0] == command
                                        reply(connection, request, 0, body)
                            # Keep the peer open until the client handles the response.
                            assert connection.recv(4096) == b""
                    observed.append(scenario)

        server = threading.Thread(target=reset_connection, daemon=True)
        server.start()
        port = str(listener.getsockname()[1])
        subprocess.run([str(executable), port, port, port, port, port], check=True, timeout=30)
        server.join(timeout=10)
        assert observed == ["probe", "reset", "negotiate", "session", "encryption", "logoff"], observed
