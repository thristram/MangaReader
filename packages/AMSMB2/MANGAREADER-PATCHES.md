# MangaReader's AMSMB2 dependency

Source: https://github.com/amosavian/AMSMB2, release **4.0.3**, commit
`1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`.

This is the upstream Swift package, its tests and the libsmb2 source/header
subtrees needed by its manifests. It replaces the remote dependency so the fixes
below are reproducible in clean Mac/iPhone builds. The dynamic product and
framework embedding/signing remain unchanged. Upstream licenses are retained in
`LICENSE` and `Dependencies/libsmb2/COPYING`; sources retain their notices.

## Local patches

`AMSMB2/Context.swift`, `SMB2Client.service(revents:)`: copy the context's error
string **before** `smb2_destroy_context`. The old code queried the freed/cleared
context and reduced socket/protocol failures to `Error code 1:` with no detail.

`Dependencies/libsmb2/lib/socket.c`: stop reading and skip queued writes when a
completed PDU callback has closed the socket. Negotiate/session rejection
callbacks close the context's socket and set the original reason. Previously the
read loop then called `readv(-1, ...)`, replacing that reason with `errno:9`.
Normal logoff callbacks also close the socket and must exit the read loop.

`AMSMB2/Context.swift`, `wait_for_reply`: detect an already closed connection
separately from a poll failure. Throw its stored NT-status mapping and reason,
or `ENOTCONN` for a local rejection without an NT status. Keep the existing
callback guard against accessing completed operations during context teardown.

No SMB dialect selection, authentication, encryption or signing rules are changed.
No automatic plaintext retry is introduced. When updating upstream, compare these
patches, retain them until fixed upstream, and run
`python3 scripts/verify-smb-diagnostics.py` after the Mac build.

The test covers an actual socket reset, refused negotiation, rejected session
setup and unsupported encryption. It also checks successful guest callbacks and
normal logoff using a synthetic, unencrypted loopback session. That fixture does
not verify NTLM credentials, encrypted data transfers or a real NAS login.

`AMSMB2/Context.swift`, `disconnect`: retain file/directory handles until pending
callbacks have drained, then destroy the context. Failed async waits destroy it
before stack-backed callback data leaves scope. Both wait helpers apply this rule.
`AMSMB2/FileHandle.swift` uses an idempotent async-close path for explicit close
and deinit, avoiding the C synchronous close waiter's timeout lifetime. These fix
the captured iPhone `free_smb2fh/close_cb` crash during client destruction. Run
`python3 scripts/verify-smb-handle-lifecycle.py` after a Debug Mac build as well as
the transport diagnostics. It uses only socketpairs and synthetic handles.
