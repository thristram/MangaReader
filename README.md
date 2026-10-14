# MangaReader

A native macOS manga library manager and an iPhone reading companion, backed by an account-scoped Node.js metadata API. **Interface: English. Preferred manga language: Chinese (`zh`), configurable independently.**

This repository contains the first development milestone, not a completed P0 release. See [implementation status](docs/implementation-status.md) for implemented features, limitations and remaining acceptance work.

## Repository

| Path | Responsibility |
| --- | --- |
| `apps/apple` | SwiftUI Mac and iPhone applications; native lifecycle and media components |
| `packages/MangaCore` | Shared Swift models, API client, language policy, import scanner, safe path/move logic and OIDC validation |
| `apps/server` | Express / TypeScript control plane; MongoDB metadata; thristram-auth bearer verification |
| `packages/api-contract/openapi.json` | Generated OpenAPI 3.1 contract |
| `docs` | Product requirements, specification, ADRs, setup, usage and migration guides |
| `docs/mock` | Editable UI mock and standalone preview from the design conversation |

The auth service remains in its separate `thristram-auth` repository. Comic bytes travel directly between the Apple app and local/SMB storage. Vercel stores and serves metadata only.

## Setup

Prerequisites: Node.js 22.16+, npm, MongoDB, and Xcode 26+ with iOS/macOS 26 SDKs. This milestone was built with Xcode 27.0 / Swift 6.4. Native targets require iOS/macOS 26 for the system Liquid Glass chrome.

```sh
npm ci
cp apps/server/.env.example apps/server/.env
cp apps/apple/Config/Local.xcconfig.example apps/apple/Config/Local.xcconfig
```

Fill in the server's MongoDB URI, canonical auth issuer, JWKS URL and permanent Manga API resource identifier. Apple deployment URLs are already configured in `apps/apple/Config/Service.xcconfig`: API/resource `https://manga-api.thenoirclub.com`, issuer `https://auth.thenoirclub.com/api/auth`. Change this project file and rebuild to use another deployment; no endpoint editor appears in the app. The supplied public PKCE client ID is shared by both apps in `Base.xcconfig`; use `Local.xcconfig` only if overriding client IDs. No client secret belongs in an app. [Auth registration](docs/server/auth-integration.md) explains the resource policy, scopes and both required callbacks.

```sh
npm run db:migrate                  # dry run
npm run db:migrate -- --apply       # after a database backup
npm run dev                        # local metadata API, port 3000
open apps/apple/MangaReader.xcodeproj
```

Select `MangaReaderMac` or `MangaReaderiPhone` in Xcode. Configure a signing team for device/distribution builds. Use a reachable HTTPS API for native integration; localhost from an iPhone is the phone itself. Deploy the server to Vercel with **Root Directory `apps/server`** and the server sample's environment variables. Do not put SMB/NAS credentials or local Ollama settings into Vercel.

The local API can be exercised through `/health` and authenticated requests, but `/health` is liveness rather than database/auth readiness. Tests inject a repository and verifier; production has no demo login or authentication bypass.

## Usage

1. Open the app's full-window welcome screen and click **Sign In** to open hosted Thristram login in `ASWebAuthenticationSession`. A verified account reveals the library; sign-out returns to the welcome screen.
2. On Mac, open Import; drop folders anywhere in Import & Identify or select folders/PDF/MP4/WebM files. Review each chapter, author, optional comic, description, language, source IDs and tags.
3. The default primary action, **Add to Library & Move Files**, explicitly commits that import. Pick the managed library root and review the source/destination before Commit. This milestone moves a clean chapter folder/file within one volume; add-only leaves files in place. Mixed folders and unsupported moves are refused.
4. Open a comic to see its chapter grid; open a chapter to read. Use the pencil to edit metadata. Set an Ollama host/model to translate title/description into the preferred manga language.
5. On iPhone, configure the matching storage root's SMB server, share, base folder and credentials. Read/download a chapter or download a work/series/author. The current transport stages the chosen chapter locally before opening it. Download files stay inside the account's app storage.
6. Favorites, stars and reading progress use the metadata API. Apps refresh metadata every 30 seconds while running; pull to refresh is also available. Offline queued edits and background downloads are not in this milestone.

See [Apple usage and setup](docs/apple/README.md), [server setup](docs/server/README.md) and [migration / recovery](docs/data-migration.md). Never rerun an import blindly after files moved but a metadata request failed; the account commit journal contains the recovery data.

## Validation

```sh
npm run typecheck
npm run build
npm test
npm run contract:generate
swift test --package-path packages/MangaCore
xcodebuild -project apps/apple/MangaReader.xcodeproj -scheme MangaReaderMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-mac CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/apple/MangaReader.xcodeproj -scheme MangaReaderiPhone \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode-phone CODE_SIGNING_ALLOWED=NO build
```

After adding/removing Apple source files, run `python3 scripts/generate-xcode-project.py`. It regenerates the checked-in project and shared schemes deterministically, preserving the ignored local config. Refresh the API contract when changing validation schemas.

## Documentation

Native screens use SwiftUI on both platforms. [Page-by-page UI verification](docs/apple/ui-verification.md) includes native screenshots and the isolated preview workflow. The historical mock remains editable under `docs/mock`.

Start with [docs index](docs/README.md), [requirements](docs/requirements.md), [specification](docs/spec.md), [API contract](docs/api-contract.md), [ADRs](docs/adr/README.md) and [UI preview](docs/mock/index.html).
