# iPhone SMB connection diagnostics

## Report and limits

The iPhone connection sheet displayed only `Error code 1:` when saving. The user
confirmed the same iPhone could connect using Apple's Files app, and MangaReader
was absent from the Local Network settings list. These facts do not identify a
particular credential, protocol or permission failure.

A credential-free protocol negotiation from the development Mac reached the
reported server. It selected SMB 3.0.2 and advertised SMB3 encryption. No login,
file read or write was performed. This excludes a blanket claim that the server
cannot support SMB3 encryption, but does not establish that the iPhone app can
authenticate or access its configured library folder.

The next iPhone report retained `Read from socket failed, errno:9. Closing
socket.` during encrypted share connection. A synthetic server reproduced that
exact text when returning `STATUS_ACCESS_DENIED` during negotiation: libsmb2's
callback closed the socket, then its read loop read the invalid descriptor and
overwrote the original error. The same masking can occur after session rejection.
The screenshot alone therefore cannot establish which NAS rejection caused it.

## Changes

- `SMBNetworkAccess` uses Network.framework to connect to the configured server's
  TCP port before its first SMB connection. It sends no credentials or SMB data,
  waits through `.waiting` for authorization/connectivity, supports cancellation
  and has a bounded timeout. Local-network-denied paths produce a Settings hint.
  Success is cached per host/port for the media service's lifetime.
- This follows Apple's [local network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).
  `NSLocalNetworkUsageDescription` was already present; it remains present. No
  Bonjour browsing or multicast entitlement was added.
- Upstream AMSMB2 4.0.3 destroyed its SMB context before reading its error text in
  `SMB2Client.service`. A local pinned copy captures that string first.
- libsmb2's socket loop now stops when a callback closes its descriptor; queued
  writes are skipped for that closed connection. The Swift wait loop reports the
  saved NT-status mapping/reason, with `ENOTCONN` for local rejection lacking an
  NT status. The existing teardown callback guard remains intact. Original
  implementation and licenses are retained. See
  [provenance](../../packages/AMSMB2/MANGAREADER-PATCHES.md).
- Save Connection shows network access, encrypted SMB session, base folder,
  library verification and device credential-save stages. Errors preserve server
  detail and include domain/code, with a nonempty fallback if none is available.
- iPhone no longer offers initialization. The shared service independently
  rejects initialization on iPhone. Mac initialization requires management scope.
  An existing library must match the account and storage-root marker.
- NAS fields disable keyboard autocorrection/capitalization. A failed disconnect
  after successful validation/persistence no longer reports a false save failure.
- Encryption stays required. There is no automatic plaintext retry or relaxed
  marker validation.

## Usage

Install/run the updated iPhone target, then choose Save Connection. Allow local
network access if iOS presents its prompt. Use the same share and base folder
as the library initialized on the Mac. For a remaining failure, report the
complete message, including its named stage and server detail; do not send a
password. An app absent from Local Network settings is not proof that access
was denied, and Files has its own permissions/client behavior.

## Verification

- Mac and iPhone Simulator builds pass with the local dynamic dependency.
- Mac framework packaging and iPhone Simulator nested signatures pass.
- Project generator checks preserve source membership, signing settings and user
  schemes. The preview builder also supplies the local package path.
- `verify-smb-diagnostics.py` connects to a synthetic loopback server. It verifies
  Network.framework readiness/cancellation and an actual socket reset. Protocol
  responses test refused negotiation (`STATUS_ACCESS_DENIED`), rejected session
  setup (`STATUS_LOGON_FAILURE`) and unsupported encryption. All retain their
  original reason and mapped error code, without being replaced by `errno:9`.
  A successful guest session also exercises echo and normal logoff closure.
  That synthetic success fixture is unencrypted and does not validate NTLM or
  encrypted transfers; app connections still require encryption. No real
  credentials or NAS files are used.
- Native regression checks stage-aware formatting for empty and detailed errors,
  alongside existing library/import/reader regressions.

```sh
python3 scripts/verify-smb-diagnostics.py
python3 scripts/verify-mac-auth-ui.py
python3 scripts/verify-apple-project.py
```

The physical iPhone's authorization prompt and the user's authenticated NAS
connection are still unverified. The simulator/loopback tests cannot certify
those device-specific flows. No database/API/environment migration is required.
