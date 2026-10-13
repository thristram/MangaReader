import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPair, SignJWT, exportJWK } from "jose";
import { createVerifier } from "../src/auth.js";
test("real JWT verifier checks signature, API audience, issuer, expiry and derives account scope", async () => {
  const { privateKey, publicKey } = await generateKeyPair("EdDSA");
  const jwk = await exportJWK(publicKey);
  jwk.kid = "test";
  jwk.alg = "EdDSA";
  const issuer = "https://auth.unit.test/api/auth",
    audience = "https://manga.unit.test";
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    if (String(input) === issuer + "/jwks")
      return new Response(JSON.stringify({ keys: [jwk] }), {
        headers: { "content-type": "application/json" },
      });
    throw new Error("Unexpected network request");
  }) as typeof fetch;
  try {
    const verify = createVerifier({
      AUTH_ISSUER: issuer,
      MANGA_API_AUDIENCE: audience,
      AUTH_JWKS_URL: issuer + "/jwks",
    });
    const sign = (iss = issuer, aud = audience, exp = "5m") =>
      new SignJWT({ scope: "manga:read manga:state:write" })
        .setProtectedHeader({ alg: "EdDSA", kid: "test" })
        .setSubject("alice")
        .setIssuer(iss)
        .setAudience(aud)
        .setIssuedAt()
        .setExpirationTime(exp)
        .sign(privateKey);
    const a = await verify(await sign());
    assert.equal(a.subject, "alice");
    assert.equal(a.ownerId.length, 64);
    assert.ok(a.scopes.has("manga:read"));
    await assert.rejects(verify(await sign(issuer, "wrong-api")));
    await assert.rejects(
      verify(await sign("https://other-auth.test", audience)),
    );
    await assert.rejects(verify(await sign(issuer, audience, "-1m")));
    const wrong = await generateKeyPair("EdDSA");
    const forged = await new SignJWT({ scope: "manga:manage" })
      .setProtectedHeader({ alg: "EdDSA", kid: "test" })
      .setSubject("alice")
      .setIssuer(issuer)
      .setAudience(audience)
      .setExpirationTime("5m")
      .sign(wrong.privateKey);
    await assert.rejects(verify(forged));
  } finally {
    globalThis.fetch = originalFetch;
  }
});
