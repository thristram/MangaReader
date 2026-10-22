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

`AMSMB2/Context.swift`, both asynchronous wait wrappers and `generic_handler`:
C callback state now uses an explicitly retained heap object, released after a
reply completes or after failed-wait context draining. Previously C received a
`withUnsafeMutablePointer(to: &cb)` address after that scheduling closure had
returned, outside Swift's guaranteed pointer lifetime. This was unsafe under
rapid cancelled cover requests even though the enclosing function was waiting.
The callback state no longer depends on Swift stack storage. Transport diagnostics
and pending-CLOSE timeout checks exercise success, failure and teardown paths.
This removes a concrete lifetime hazard; it does not establish that every
reported device crash had this cause without its corresponding crash log.

`Dependencies/libsmb2/lib/socket.c`, `smb2_write_to_socket`: configure
`SO_NOSIGPIPE` on Darwin SMB sockets before writing. A closed NAS peer could
otherwise deliver process-fatal SIGPIPE from `writev`, bypassing Swift error
handling entirely. The synthetic closed-peer close request reproduced SIGPIPE
before this patch. The regression retains the default signal disposition and
requires an ordinary socket error with safe callback cleanup. This is a per-socket
option, with no process-wide signal changes or changes to SMB security settings.

## Device-confirmed negative read buffer (2026-10-16)

Authorized device reports show `Data.init(repeating:count:)` trapping with count
`-1`, called by `SMB2FileHandle.read(length:)` inside the async contents producer.
The negotiated-size getter returned `-1` when a cancelled/closed client no longer
had a context. `read` and `pread` now validate connection, size and handle under
one recursive context lock before allocating, throw for invalid lengths and
bound each buffer to 1 MiB. Missing negotiated size is represented by zero, and
manager read loops throw instead of reporting a truncated successful transfer.
Async contents producers observe stream termination, stop before further reads
and finish disconnected-client streams with an error. App marker validation
uses the bounded async Data operation, waiting for its producer before teardown.
The lifecycle test now reproduces twenty read-after-disconnect sequences with
default, positive, negative and out-of-range lengths for both read variants.
