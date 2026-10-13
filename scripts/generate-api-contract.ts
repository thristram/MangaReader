import { z } from "zod";
import { writeFileSync } from "node:fs";
import { metadataSchema, stateSchema } from "../apps/server/src/domain.js";
const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` });
const input = z.toJSONSchema(metadataSchema, { io: "input" });
const state = z.toJSONSchema(stateSchema, { io: "input" });
const metadataOutput = z.toJSONSchema(metadataSchema),
  stateOutput = z.toJSONSchema(stateSchema);
const entity = {
  ...metadataOutput,
  required: [
    ...(metadataOutput.required ?? []),
    "id",
    "revision",
    "updatedAt",
    "deleted",
  ],
  properties: {
    ...metadataOutput.properties,
    id: { type: "string", format: "uuid" },
    revision: { type: "integer", minimum: 1 },
    updatedAt: { type: "string", format: "date-time" },
    deleted: { type: "boolean" },
  },
};
const storedState = {
  ...stateOutput,
  required: [...(stateOutput.required ?? []), "id", "revision", "updatedAt"],
  properties: {
    ...stateOutput.properties,
    id: { type: "string" },
    revision: { type: "integer", minimum: 1 },
    updatedAt: { type: "string", format: "date-time" },
  },
};
const json = (schema: unknown) => ({
  content: { "application/json": { schema } },
});
const errors = Object.fromEntries(
  [400, 401, 403, 404, 409, 413, 422, 428, 500, 503].map((code) => [
    code,
    {
      description: (
        {
          400: "Invalid request",
          401: "Invalid access token",
          403: "Insufficient scope",
          404: "Unavailable in this account",
          409: "Stale revision or referenced entity",
          413: "Body exceeds 2 MB",
          422: "Invalid relationship or page",
          428: "If-Match required",
          500: "Internal error",
          503: "Schema not ready or snapshot bootstrap limit",
        } as Record<number, string>
      )[code],
      ...json(ref("Error")),
    },
  ]),
);
const response = (schema: unknown, status = "200") => ({
  ...errors,
  [status]: { description: "Success", ...json(schema) },
});
const header = {
  name: "If-Match",
  in: "header",
  required: true,
  description:
    "Unquoted integer revision. Use 0 for a new personal state; existing objects require their current revision.",
  schema: { type: "string", pattern: "^[0-9]+$" },
};
const id = {
  name: "id",
  in: "path",
  required: true,
  schema: { type: "string", format: "uuid" },
};
const nsfw = {
  name: "includeNSFW",
  in: "query",
  schema: { type: "boolean", default: false },
};
const operation = (scope: string, fields: object) => ({
  "x-required-scope": scope,
  security: [{ bearer: [] }],
  ...fields,
});
const body = (name: string) => ({ required: true, ...json(ref(name)) });
const paths = {
  "/health": {
    get: {
      operationId: "health",
      security: [],
      responses: {
        200: {
          description: "Liveness (not database readiness)",
          ...json({
            type: "object",
            properties: { status: { const: "ok" }, apiVersion: { const: 1 } },
          }),
        },
      },
    },
  },
  "/v1/me": {
    get: operation("manga:read", {
      operationId: "currentAccount",
      responses: response(ref("Account")),
    }),
  },
  "/v1/entities": {
    get: operation("manga:read", {
      operationId: "listEntities",
      parameters: [
        nsfw,
        ...["kind", "q", "workId", "authorId"].map((name) => ({
          name,
          in: "query",
          schema:
            name === "kind"
              ? {
                  type: "string",
                  enum: [
                    "author",
                    "series",
                    "work",
                    "chapter",
                    "tag",
                    "storageRoot",
                  ],
                }
              : { type: "string" },
        })),
      ],
      responses: response({
        type: "object",
        required: ["items"],
        properties: { items: { type: "array", items: ref("Entity") } },
      }),
    }),
    post: operation("manga:manage", {
      operationId: "createEntity",
      requestBody: body("MetadataInput"),
      responses: response(ref("Entity"), "201"),
    }),
  },
  "/v1/entities/{id}": {
    get: operation("manga:read", {
      operationId: "getEntity",
      parameters: [id, nsfw],
      responses: response(ref("Entity")),
    }),
    put: operation("manga:manage", {
      operationId: "replaceEntity",
      parameters: [id, header],
      requestBody: body("MetadataInput"),
      responses: response(ref("Entity")),
    }),
    delete: operation("manga:manage", {
      operationId: "deleteEntity",
      parameters: [id, header],
      responses: {
        ...errors,
        204: { description: "Tombstone written; no media deleted" },
      },
    }),
  },
  "/v1/states": {
    get: operation("manga:read", {
      operationId: "listStates",
      parameters: [nsfw],
      responses: response({
        type: "object",
        required: ["items"],
        properties: { items: { type: "array", items: ref("State") } },
      }),
    }),
    put: operation("manga:state:write", {
      operationId: "replacePersonalState",
      parameters: [header],
      requestBody: body("StateInput"),
      responses: response(ref("State")),
    }),
  },
  "/v1/sync": {
    get: operation("manga:read", {
      operationId: "syncSnapshot",
      description:
        "Complete account metadata, including NSFW and deletion tombstones. Clients must apply visibility policy before rendering. No incremental cursor in v1.",
      responses: response({
        type: "object",
        required: ["schemaVersion", "entities", "states"],
        properties: {
          schemaVersion: { const: 1 },
          entities: { type: "array", items: ref("Entity") },
          states: { type: "array", items: ref("State") },
        },
      }),
    }),
  },
};
const doc = {
  openapi: "3.1.0",
  info: {
    title: "MangaReader Metadata API",
    version: "0.1.0",
    description:
      "Account-scoped control plane. Comic bytes and SMB credentials never pass through this API.",
  },
  servers: [{ url: "https://manga.example.com" }],
  paths,
  components: {
    securitySchemes: {
      bearer: {
        type: "http",
        scheme: "bearer",
        bearerFormat: "OAuth access token",
      },
    },
    schemas: {
      MetadataInput: input,
      Entity: entity,
      StateInput: state,
      State: storedState,
      Account: {
        type: "object",
        required: ["ownerId", "issuer", "subject", "scopes"],
        properties: {
          ownerId: { type: "string" },
          issuer: { type: "string", format: "uri" },
          subject: { type: "string" },
          scopes: { type: "array", items: { type: "string" } },
        },
      },
      Error: {
        type: "object",
        required: ["error"],
        properties: {
          error: {
            type: "object",
            required: ["code", "message"],
            properties: {
              code: { type: "string" },
              message: { type: "string" },
              details: { type: "array", items: { type: "object" } },
            },
          },
        },
      },
    },
  },
};
writeFileSync(
  new URL("../packages/api-contract/openapi.json", import.meta.url),
  JSON.stringify(doc, null, 2) + "\n",
);
