# ADR 0008 — Project deployment configuration and verified-account welcome gate

Status: Accepted · 2026-10-13

## Context

The user wants the service domain configured once in the project and a full-window Sign In welcome page instead of an unauthenticated library/configuration interface. One public OAuth client ID was supplied for the native apps.

## Decision

Put the API/resource and auth issuer in Apple `Config/Service.xcconfig`, with production API `https://manga-api.thenoirclub.com`. Include it after optional local settings so old local URLs cannot override it. Public client IDs live in `Base.xcconfig`, with optional per-platform local overrides. Read deployment values from the built bundle; ignore old UserDefaults deployment entries and remove their editors from both apps. Storage, reading and Ollama device preferences remain runtime settings.

Native root containers embed either a full-window welcome screen or the verified account's library, never a library behind a signed-out overlay. Use Combine identity observation separately from library refresh callbacks. ASWebAuthenticationSession remains the hosted authentication UI. Disable duplicate attempts, show restoration/progress/failure, allow retry/cancellation, and replace private controllers on identity change/sign-out. Mac also closes readers/sheets and releases storage access.

Both apps currently use the supplied public client registration with separate callbacks and requested scopes. This supersedes ADR 0003's assumption of two initially distinct registrations; its PKCE, state/nonce, token verification and account-isolation decisions remain. Separate platform client IDs remain supported, and a shared hosted registration must allow both callbacks. No native client secret is introduced.

## Consequences

Changing deployment/auth configuration requires a rebuild. Saved tokens are restored only for matching issuer/client/resource. Old runtime configuration is ignored, not copied into a different registration. No database/media migration is required. UI state tests use isolated bundles and synthetic verified identities, never an authentication bypass in the shipped app. Hosted registration and successful real login remain separate verification boundaries.
