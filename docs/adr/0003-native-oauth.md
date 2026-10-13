# ADR 0003 — Hosted ASWeb login and API resource authorization

Status: Accepted · 2026-10-13

## Context

The user wants a unified thristram-auth login, mandatory account isolation and a separate Manga API audience. Native clients cannot protect a client secret.

## Decision

Use ASWebAuthenticationSession for both apps with two public clients, S256 PKCE, state and nonce. Register the same permanent Manga resource explicitly per client. iPhone receives read/state scopes; Mac additionally manage. Validate native ID tokens and establish the same verified identity through `/v1/me`; backend verifies API access tokens and scopes independently.

Account identity is canonical issuer + subject, hashed into an owner key. Every persisted record/reference/cache/download is scoped to it. Never use email or owner IDs supplied in requests. Secrets/tokens stay in Keychain/server environment.

## Consequences

Public API configuration still needs real domains/client registrations. Signing/callback changes require coordinated config and auth registration. Current native verification supports auth's Ed25519 ID tokens and fails closed on another algorithm. Live auth/migration acceptance is separate from local compilation. A future DPoP implementation requires a shared replay store on the server.
