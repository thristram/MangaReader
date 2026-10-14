import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import ts from "typescript";
import request from "supertest";

test("the sole Express entrypoint exports the live app", async () => {
  // Vercel treats these filenames as entrypoint candidates. The injectable
  // factory must not shadow index.ts with a reserved app.ts/server.ts name.
  const candidates = [
    "app",
    "index",
    "server",
    "src/app",
    "src/index",
    "src/server",
  ]
    .flatMap((base) =>
      ["js", "cjs", "mjs", "ts", "cts", "mts"].map((ext) => `${base}.${ext}`),
    )
    .filter((path) => existsSync(new URL(`../${path}`, import.meta.url)));
  assert.deepEqual(candidates, ["src/index.ts"]);
  const entrypoint = ts.createSourceFile(
    "index.ts",
    readFileSync(new URL("../src/index.ts", import.meta.url), "utf8"),
    ts.ScriptTarget.Latest,
    true,
  );
  assert.ok(
    entrypoint.statements.some(
      (statement) =>
        ts.isImportDeclaration(statement) &&
        ts.isStringLiteral(statement.moduleSpecifier) &&
        statement.moduleSpecifier.text === "express" &&
        !statement.importClause?.isTypeOnly,
    ),
    "Vercel requires a direct runtime Express import in the entrypoint",
  );
  process.env.AUTH_ISSUER = "https://auth.deployment.test/api/auth";
  process.env.AUTH_JWKS_URL = "https://auth.deployment.test/api/auth/jwks";
  process.env.MANGA_API_AUDIENCE = "https://manga.deployment.test";
  const { default: app } = await import("../src/index.js");
  assert.equal(typeof app, "function");
  const response = await request(app).get("/health").expect(200);
  assert.deepEqual(response.body, { status: "ok", apiVersion: 1 });
  await request(app).get("/v1/me").expect(401);
});
