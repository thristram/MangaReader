// Install the optional builder into an ignored directory; see docs/server/README.md.
// This checks the published Vercel builder and its packaged app without credentials.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const builderPath = resolve(root, process.argv[2] ?? ".build/vercel-builder");
const requireBuilder = createRequire(resolve(builderPath, "package.json"));
const { build, entrypointCallback } = requireBuilder("@vercel/express");
const { glob, download } = requireBuilder("@vercel/build-utils");
const requireProject = createRequire(resolve(root, "package.json"));
const request = requireProject("supertest");
const workPath = resolve(root, "apps/server");
const files = await glob("{package.json,tsconfig.json,src/**/*.ts}", workPath);
const config = {
  framework: "express",
  projectSettings: {
    nodeVersion: "24.x",
    buildCommand: "npm run build",
    // Reuse the already installed workspace dependencies.
    installCommand: "",
  },
};
const args = {
  files,
  workPath,
  repoRootPath: root,
  entrypoint: "package.json",
  config,
  meta: { skipDownload: true },
};
assert.equal(await entrypointCallback(args), "src/index.ts");
const { output } = await build(args);
assert.equal(output.framework.slug, "express");
assert.equal(output.handler, "apps/server/src/index.js");
assert.equal(output.runtime, "nodejs24.x");
assert.ok(
  !Object.keys(output.files).some((path) => /(^|\/)\.env($|\.)/.test(path)),
  "Deployment bundle must not contain environment files",
);
const bundlePath = resolve(root, ".build/vercel-packaged-app");
await download(output.files, bundlePath, {});

// Only synthetic public configuration. No Mongo connection is needed for these routes.
process.env.AUTH_ISSUER = "https://auth.deployment.test/api/auth";
process.env.AUTH_JWKS_URL = "https://auth.deployment.test/api/auth/jwks";
process.env.MANGA_API_AUDIENCE = "https://manga.deployment.test";
const { default: app } = await import(
  pathToFileURL(resolve(bundlePath, output.handler)).href
);
assert.equal(typeof app, "function");
const response = await request(app).get("/health").expect(200);
assert.deepEqual(response.body, { status: "ok", apiVersion: 1 });
await request(app).get("/v1/me").expect(401);
console.log(
  JSON.stringify({
    builder: requireBuilder("@vercel/express/package.json").version,
    handler: output.handler,
    runtime: output.runtime,
    verificationNode: process.version,
    packagedHealth: 200,
    packagedUnauthorizedAPI: 401,
    environmentFilesIncluded: false,
  }),
);
