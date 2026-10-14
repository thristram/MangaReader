# thristram-auth integration

MangaReader is an **API resource / audience**, while the Mac and iPhone apps use **public OAuth client registrations**. Tokens minted for Mosaic or another resource do not grant access to MangaReader. The auth repo already supports managed per-client API resource/scope policies; its production deployment/database migration is a separate operation.

## Resource policy

In thristram-auth's configuration, append the permanent Manga identifier to `OAUTH_API_RESOURCES`:

```json
[{"identifier":"https://manga-api.thenoirclub.com","allowedScopes":["manga:read","manga:state:write","manga:manage"]}]
```

Preserve existing resources. The exact identifier must match `MANGA_API_AUDIENCE` server-side and `MangaAPIAudience` in both apps (no trailing slash). It is stable across server preview deployments.

## Clients

The supplied public client ID `uFMdiHmwRvJAxJKZGzMXrYJOHMtZtjsC` is currently configured for both native apps. Its registration must enable PKCE authorization-code and refresh flows, explicitly assign the Manga resource/scopes, and allow **both** exact callbacks:

- Mac: `com.thristram.mangareader.mac:/oauth/callback`
- iPhone: `com.thristram.mangareader.iphone:/oauth/callback`

These are reverse-domain private-use schemes with no authority. Register them exactly; do not turn them into `://oauth/callback`. If changing bundle identifiers/schemes, update Info.plist and callback configuration together. A future release may adopt claimed HTTPS universal-link callbacks after website associations are provisioned.

Mac scopes: `openid profile email offline_access manga:read manga:state:write manga:manage`.

iPhone scopes: `openid profile email offline_access manga:read manga:state:write`.

No client secret is embedded. Browser consent remains enabled. Public dynamic registration does not grant this managed Manga resource implicitly.

Separate platform registrations remain supported via `MAC_OAUTH_CLIENT_ID` and `IPHONE_OAUTH_CLIENT_ID` in optional Apple `Local.xcconfig`; they can further limit iPhone's allowed scopes. With the current shared registration, iPhone still requests only read/state scopes. These public IDs and API/auth deployment values are build configuration, not app settings. A supplied client ID alone does not prove that its hosted registration has the required callbacks/grants/resource policy.

## Native login sequence

Fetch discovery under the configured canonical issuer (`<issuer>/.well-known/openid-configuration`); verify returned issuer and HTTPS endpoints. Generate random state, nonce and PKCE verifier, hash S256. ASWebAuthenticationSession opens the authorization endpoint, returns to the exact scheme/path, and state/code uniqueness are checked. Exchange code with verifier/client ID/redirect/resource.

Validate ID token signature via issuer JWKS, issuer, expiry/issued-at, client-ID audience, nonce and subject. The current auth config uses EdDSA / Ed25519; native validation uses CryptoKit and rejects other algorithms. Then call authenticated Manga `/v1/me` and require the same issuer/subject before selecting the account cache. Do not trust an unverified decoded JWT payload.

Tokens remain in Keychain, refreshes serialize, rotated refresh tokens replace stored credentials. Login/refresh attempts are tied to a session generation so a late response cannot restore credentials after sign-out/account change. Profile/email, if needed later, come from UserInfo; OAuth Provider 1.7 ID tokens do not carry those fields.

## Backend verification

Use `verifyBearerToken` from `better-auth/oauth2` with required issuer/audience/expiry/subject and allowed signed algorithms. This initial API accepts bearer tokens only; DPoP-bound tokens are rejected. Supporting DPoP requires the request-aware verifier and a persistent replay store, not a process-local map on Vercel.

JWT signature verification supports warm JWKS caching/rotation via the library. Optional opaque-token introspection is configured with a confidential API client. Never allow a missing or mismatched audience. Scope checks happen per endpoint after identity verification; every Mongo/reference lookup includes server-derived ownerId.

## Required live acceptance

Hosted sign-in/cancel, wrong callback/state/nonce, resource assignment, permission separation, refresh rotation/revocation and account switching must be exercised against the deployed auth and Manga services with actual registered clients. Unit/compile success does not claim live deployment acceptance.
