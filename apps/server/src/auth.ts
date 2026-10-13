import { createHash } from "node:crypto";
import { verifyBearerToken } from "better-auth/oauth2";
import type { Account } from "./domain.js";
import { Problem } from "./domain.js";
export type Verifier = (token: string) => Promise<Account>;
export function createVerifier(env: NodeJS.ProcessEnv = process.env): Verifier {
  const issuer = env.AUTH_ISSUER,
    audience = env.MANGA_API_AUDIENCE,
    jwksUrl = env.AUTH_JWKS_URL;
  if (!issuer || !audience || !jwksUrl)
    throw new Error(
      "Configure AUTH_ISSUER, MANGA_API_AUDIENCE and AUTH_JWKS_URL",
    );
  for (const value of [issuer, audience, jwksUrl])
    if (new URL(value).protocol !== "https:")
      throw new Error("Auth endpoints and audience require HTTPS");
  return async (token) => {
    const claims = await verifyBearerToken(token, {
      verifyOptions: {
        issuer,
        audience,
        algorithms: ["EdDSA", "RS256", "ES256"],
        requiredClaims: ["exp", "sub", "iss"],
      },
      jwksUrl,
      ...(env.AUTH_INTROSPECTION_CLIENT_ID &&
      env.AUTH_INTROSPECTION_CLIENT_SECRET
        ? {
            remoteVerify: {
              introspectUrl: `${issuer}/oauth2/introspect`,
              clientId: env.AUTH_INTROSPECTION_CLIENT_ID,
              clientSecret: env.AUTH_INTROSPECTION_CLIENT_SECRET,
            },
          }
        : {}),
    });
    if (typeof claims.sub !== "string" || !claims.sub || claims.iss !== issuer)
      throw new Problem(401, "invalid_token", "Invalid identity");
    const ownerId = createHash("sha256")
      .update(`${issuer}\0${claims.sub}`)
      .digest("hex");
    return {
      ownerId,
      issuer,
      subject: claims.sub,
      scopes: new Set(
        typeof claims.scope === "string" ? claims.scope.split(" ") : [],
      ),
    };
  };
}
