import compression from "compression";
import jsonpatch from "fast-json-patch";
import {
  compactRecord,
  manifestETag,
  publicState,
  type Manifest,
  type VisibilityRecord,
  patchSchema,
  syncRecordsSchema,
  stateIdSchema,
} from "./sync.js";
import express from "express";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import {
  Problem,
  hasScope,
  metadataSchema,
  stateSchema,
  publicRecord,
  type Account,
  type RecordDocument,
} from "./domain.js";
import type { Repository } from "./repository.js";
import type { Verifier } from "./auth.js";
const uuid = z.uuid();
const revision = (value: unknown) => {
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < 0 || String(n) !== value)
    throw new Problem(
      428,
      "revision_required",
      "If-Match must contain an integer revision",
    );
  return n;
};
export function createApp(
  repository: () => Promise<Repository>,
  verify: Verifier,
  app: express.Express = express(),
) {
  app.disable("x-powered-by");
  app.use(compression({ threshold: 4096, level: 1 }));
  app.use(
    express.json({
      limit: "4mb",
      type: ["application/json", "application/json-patch+json"],
    }),
  );
  app.use((_req, res, next) => {
    res.set("Cache-Control", "no-store");
    next();
  });
  app.get("/health", (_req, res) => res.json({ status: "ok", apiVersion: 1 }));
  app.use("/v1", async (req, res, next) => {
    const match = /^Bearer ([^\s]+)$/i.exec(req.get("authorization") ?? "");
    if (!match?.[1]) {
      res.set("WWW-Authenticate", "Bearer");
      return next(new Problem(401, "invalid_token", "Sign in required"));
    }
    try {
      res.locals.account = await verify(match[1]);
      next();
    } catch {
      res.set("WWW-Authenticate", 'Bearer error="invalid_token"');
      next(new Problem(401, "invalid_token", "Access token rejected"));
    }
  });
  const account = (res: express.Response) => res.locals.account as Account;
  app.get("/v1/me", (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    res.json({
      ownerId: a.ownerId,
      issuer: a.issuer,
      subject: a.subject,
      scopes: [...a.scopes],
    });
  });
  async function all(owner: string) {
    const docs = await (await repository()).records(owner);
    if (docs.length > 10000)
      throw new Problem(
        503,
        "library_limit",
        "Snapshot exceeds bootstrap limit",
      );
    return docs;
  }
  const isHidden = (
    doc: VisibilityRecord,
    docs: ReadonlyMap<string, VisibilityRecord>,
    visited = new Set<string>(),
  ): boolean => {
    if (visited.has(doc.id)) return false;
    visited.add(doc.id);
    if (doc.nsfw) return true;
    return [...doc.tagIds, doc.authorId, doc.seriesId, doc.workId].some(
      (id) => {
        if (!id) return false;
        const parent = docs.get(id);
        return !!parent && !parent.deleted && isHidden(parent, docs, visited);
      },
    );
  };
  async function recordsByIds(repo: Repository, owner: string, ids: string[]) {
    return repo.recordsByIds
      ? repo.recordsByIds(owner, ids)
      : (await repo.records(owner)).filter((d) => ids.includes(d.id));
  }
  async function visibilityByIds(
    repo: Repository,
    owner: string,
    ids: string[],
  ) {
    return repo.visibilityRecords
      ? repo.visibilityRecords(owner, ids)
      : recordsByIds(repo, owner, ids);
  }
  async function visibilityDocuments(
    repo: Repository,
    owner: string,
    initial: VisibilityRecord[],
  ) {
    const docs = new Map(initial.map((d) => [d.id, d]));
    let pending = initial;
    // Resolve each dependency once; cyclic tag graphs terminate without a depth-based visibility bypass.
    while (pending.length) {
      const ids = [
        ...new Set(
          pending.flatMap((d) =>
            [...d.tagIds, d.authorId, d.seriesId, d.workId].filter(
              (id): id is string => !!id && !docs.has(id),
            ),
          ),
        ),
      ];
      if (!ids.length) break;
      pending = await visibilityByIds(repo, owner, ids);
      for (const doc of pending) docs.set(doc.id, doc);
      if (docs.size > 10000)
        throw new Problem(
          503,
          "library_limit",
          "Visibility graph exceeds library limit",
        );
    }
    return docs;
  }
  app.get("/v1/entities", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    const repo = await repository();
    const limit = z.coerce
      .number()
      .int()
      .min(1)
      .max(250)
      .parse(req.query.limit ?? 100);
    const kind =
      req.query.kind === undefined
        ? undefined
        : z
            .enum(["author", "series", "work", "chapter", "tag", "storageRoot"])
            .parse(req.query.kind);
    const workId =
      req.query.workId === undefined ? undefined : uuid.parse(req.query.workId);
    const authorId =
      req.query.authorId === undefined
        ? undefined
        : uuid.parse(req.query.authorId);
    const after =
      req.query.after === undefined ? undefined : uuid.parse(req.query.after);
    const q =
      req.query.q === undefined
        ? undefined
        : z.string().max(200).parse(req.query.q);
    let docs: RecordDocument[];
    if (repo.listRecords)
      docs = await repo.listRecords(a.ownerId, {
        limit: limit + 1,
        kind,
        workId,
        authorId,
        after,
        q,
      });
    else
      docs = (await all(a.ownerId))
        .filter(
          (d) =>
            !d.deleted &&
            (!kind || d.kind === kind) &&
            (!workId || d.workId === workId) &&
            (!authorId || d.authorId === authorId) &&
            (!after || d.id > after) &&
            (!q ||
              [
                d.title,
                ...Object.values(d.localizations).map((t) => t.title ?? ""),
              ].some((t) =>
                t.toLocaleLowerCase().includes(q.toLocaleLowerCase()),
              )),
        )
        .sort((a, b) => a.id.localeCompare(b.id))
        .slice(0, limit + 1);
    const more = docs.length > limit;
    docs = docs.slice(0, limit);
    const context =
      req.query.includeNSFW === "true"
        ? new Map(docs.map((d) => [d.id, d]))
        : await visibilityDocuments(repo, a.ownerId, docs);
    res.json({
      items: docs
        .filter(
          (d) => req.query.includeNSFW === "true" || !isHidden(d, context),
        )
        .map(publicRecord),
      ...(more ? { nextCursor: docs.at(-1)!.id } : {}),
    });
  });
  app.get("/v1/entities/:id", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    const repo = await repository();
    const d = await repo.get(a.ownerId, uuid.parse(req.params.id));
    if (
      !d ||
      d.deleted ||
      (req.query.includeNSFW !== "true" &&
        isHidden(d, await visibilityDocuments(repo, a.ownerId, [d])))
    )
      throw new Problem(404, "not_found", "Entity unavailable");
    res.json(publicRecord(d));
  });
  async function references(
    owner: string,
    body: z.infer<typeof metadataSchema>,
    id: string,
  ) {
    const refs: [string | undefined, string][] = [
      [body.authorId, "author"],
      [body.seriesId, "series"],
      [body.workId, "work"],
      ...body.tagIds.map((v) => [v, "tag"] as [string, string]),
      ...body.media.map(
        (v) => [v.storageRootId, "storageRoot"] as [string, string],
      ),
    ];
    const repo = await repository();
    const ids = [...new Set(refs.flatMap(([id]) => (id ? [id] : [])))];
    const foundRecords = repo.recordsByIds
      ? await repo.recordsByIds(owner, ids)
      : await Promise.all(ids.map((id) => repo.get(owner, id)));
    const referenced = new Map(
      foundRecords
        .filter((d): d is RecordDocument => !!d)
        .map((d) => [d.id, d]),
    );
    for (const [ref, kind] of refs)
      if (ref) {
        const found = referenced.get(ref);
        if (ref === id || !found || found.deleted || found.kind !== kind)
          throw new Problem(
            422,
            "invalid_reference",
            "Reference unavailable in this account",
          );
      }
    if (body.kind === "work" && !body.authorId)
      throw new Problem(422, "invalid_reference", "Work requires author");
    if (
      ["author", "tag", "storageRoot"].includes(body.kind) &&
      (body.authorId || body.seriesId || body.workId)
    )
      throw new Problem(
        422,
        "invalid_reference",
        "This kind cannot have hierarchy parents",
      );
    if (body.kind === "series" && (body.seriesId || body.workId))
      throw new Problem(
        422,
        "invalid_reference",
        "Series cannot have a series/work parent",
      );
    if (body.kind === "work" && body.workId)
      throw new Problem(
        422,
        "invalid_reference",
        "Work cannot have a work parent",
      );
    if (body.seriesId) {
      const series = referenced.get(body.seriesId);
      if (series?.authorId && series.authorId !== body.authorId)
        throw new Problem(
          422,
          "invalid_reference",
          "Series author does not match",
        );
    }
    if (body.workId) {
      const work = referenced.get(body.workId);
      if (work?.authorId !== body.authorId || work?.seriesId !== body.seriesId)
        throw new Problem(
          422,
          "invalid_reference",
          "Chapter hierarchy does not match its comic",
        );
    }
  }
  app.post("/v1/entities", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:manage");
    const body = metadataSchema.parse(req.body);
    const id = randomUUID();
    await references(a.ownerId, body, id);
    const doc = {
      ...body,
      id,
      ownerId: a.ownerId,
      revision: 1,
      updatedAt: new Date().toISOString(),
      deleted: false,
    };
    if (!(await (await repository()).save(doc, 0)))
      throw new Problem(409, "conflict", "Create collision");
    res.status(201).json(publicRecord(doc));
  });
  app.put("/v1/entities/:id", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:manage");
    const id = uuid.parse(req.params.id),
      expected = revision(req.get("if-match"));
    const repo = await repository();
    const old = await repo.get(a.ownerId, id);
    if (!old || old.deleted)
      throw new Problem(404, "not_found", "Entity unavailable");
    const body = metadataSchema.parse(req.body);
    if (body.kind !== old.kind)
      throw new Problem(422, "immutable_kind", "Entity kind cannot change");
    await references(a.ownerId, body, id);
    const doc = {
      ...body,
      id,
      ownerId: a.ownerId,
      revision: expected + 1,
      updatedAt: new Date().toISOString(),
      deleted: false,
    };
    if (expected !== old.revision || !(await repo.save(doc, expected)))
      throw new Problem(
        409,
        "conflict",
        "Reload current revision before editing",
      );
    res.json(publicRecord(doc));
  });
  app.patch("/v1/entities/:id", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:manage");
    const id = uuid.parse(req.params.id),
      expected = revision(req.get("if-match"));
    const repo = await repository();
    const old = await repo.get(a.ownerId, id);
    if (!old || old.deleted)
      throw new Problem(404, "not_found", "Entity unavailable");
    if (old.revision !== expected)
      throw new Problem(
        409,
        "conflict",
        "Reload current revision before editing",
      );
    const operations = patchSchema.parse(req.body);
    const keys = new Set(
      Object.keys(metadataSchema.shape).filter((k) => k !== "kind"),
    );
    for (const op of operations) {
      const key = op.path
        .split("/")[1]
        ?.replace(/~1/g, "/")
        .replace(/~0/g, "~");
      if (
        !op.path.startsWith("/") ||
        !key ||
        !keys.has(key) ||
        op.path
          .split("/")
          .some((p) => ["__proto__", "constructor", "prototype"].includes(p))
      )
        throw new Problem(
          400,
          "invalid_patch",
          "Only metadata fields can be patched",
        );
    }
    const original = Object.fromEntries(
      Object.keys(metadataSchema.shape)
        .filter((k) => old[k as keyof RecordDocument] !== undefined)
        .map((k) => [k, old[k as keyof RecordDocument]]),
    );
    let patched: unknown;
    try {
      patched = jsonpatch.applyPatch(
        original,
        operations as jsonpatch.Operation[],
        true,
        false,
        true,
      ).newDocument;
    } catch {
      throw new Problem(
        400,
        "invalid_patch",
        "Patch does not match current metadata",
      );
    }
    const body = metadataSchema.parse(patched);
    await references(a.ownerId, body, id);
    const doc = {
      ...body,
      id,
      ownerId: a.ownerId,
      revision: expected + 1,
      updatedAt: new Date().toISOString(),
      deleted: false,
    };
    if (
      !(await (repo.saveChanges
        ? repo.saveChanges(old, doc, operations as jsonpatch.Operation[])
        : repo.save(doc, expected)))
    )
      throw new Problem(
        409,
        "conflict",
        "Reload current revision before editing",
      );
    res.json({
      id,
      revision: doc.revision,
      updatedAt: doc.updatedAt,
      title: doc.title,
    });
  });
  app.delete("/v1/entities/:id", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:manage");
    const id = uuid.parse(req.params.id),
      expected = revision(req.get("if-match"));
    const repo = await repository();
    const old = await repo.get(a.ownerId, id);
    if (!old || old.deleted)
      throw new Problem(404, "not_found", "Entity unavailable");
    const referenced = repo.hasReferences
      ? await repo.hasReferences(a.ownerId, id)
      : (await all(a.ownerId)).some(
          (d) =>
            !d.deleted &&
            (d.authorId === id ||
              d.seriesId === id ||
              d.workId === id ||
              d.tagIds.includes(id) ||
              d.media.some((m) => m.storageRootId === id)),
        );
    if (referenced)
      throw new Problem(
        409,
        "referenced",
        "Detach child references before deleting",
      );
    if (
      expected !== old.revision ||
      !(await repo.save(
        {
          ...old,
          deleted: true,
          revision: expected + 1,
          updatedAt: new Date().toISOString(),
        },
        expected,
      ))
    )
      throw new Problem(409, "conflict", "Revision changed");
    res.status(204).end();
  });
  app.get("/v1/states", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    const repo = await repository();
    const limit = z.coerce
      .number()
      .int()
      .min(1)
      .max(250)
      .parse(req.query.limit ?? 100);
    const entityId =
      req.query.entityId === undefined
        ? undefined
        : uuid.parse(req.query.entityId);
    const after =
      req.query.after === undefined
        ? undefined
        : z.string().max(80).parse(req.query.after);
    let values = repo.listStates
      ? await repo.listStates(a.ownerId, { entityId, after, limit: limit + 1 })
      : (await repo.states(a.ownerId))
          .filter(
            (s) =>
              (!entityId || s.entityId === entityId) &&
              (!after || s.id > after),
          )
          .sort((a, b) => a.id.localeCompare(b.id))
          .slice(0, limit + 1);
    const more = values.length > limit;
    values = values.slice(0, limit);
    const docs = await visibilityByIds(repo, a.ownerId, [
      ...new Set(values.map((s) => s.entityId)),
    ]);
    const context =
      req.query.includeNSFW === "true"
        ? new Map(docs.map((d) => [d.id, d]))
        : await visibilityDocuments(repo, a.ownerId, docs);
    const visible = new Set(
      docs
        .filter(
          (d) =>
            !d.deleted &&
            (req.query.includeNSFW === "true" || !isHidden(d, context)),
        )
        .map((d) => d.id),
    );
    res.json({
      items: values.filter((s) => visible.has(s.entityId)).map(publicState),
      ...(more ? { nextCursor: values.at(-1)!.id } : {}),
    });
  });
  app.get("/v1/states/:id", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    const id = stateIdSchema.parse(req.params.id);
    const repo = await repository();
    const value = repo.getState
      ? await repo.getState(a.ownerId, id)
      : (await repo.states(a.ownerId)).find((s) => s.id === id);
    if (!value) throw new Problem(404, "not_found", "State unavailable");
    const entity = repo.stateTarget
      ? await repo.stateTarget(a.ownerId, value.entityId)
      : await repo.get(a.ownerId, value.entityId);
    if (!entity || entity.deleted)
      throw new Problem(404, "not_found", "State unavailable");
    res.json(publicState(value));
  });
  app.put("/v1/states", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:state:write");
    const body = stateSchema.parse(req.body),
      expected = revision(req.get("if-match"));
    const repo = await repository();
    const entity = repo.stateTarget
      ? await repo.stateTarget(a.ownerId, body.entityId)
      : await repo.get(a.ownerId, body.entityId);
    if (!entity || entity.deleted)
      throw new Problem(404, "not_found", "Entity unavailable");
    if (body.progress) {
      const m = entity.media.find((m) => m.id === body.progress!.mediaId);
      if (
        !m ||
        body.progress.pageIndex >= m.pageCount ||
        body.pageIndex !== undefined
      )
        throw new Problem(
          422,
          "invalid_progress",
          "Progress must address an existing chapter media page",
        );
    }
    if (
      body.pageIndex !== undefined &&
      (entity.kind !== "chapter" ||
        !entity.media.some((m) => body.pageIndex! < m.pageCount))
    )
      throw new Problem(422, "invalid_page", "Page unavailable");
    const id = `${body.entityId}:${body.pageIndex ?? "entity"}`;
    const doc = {
      ...body,
      id,
      ownerId: a.ownerId,
      revision: expected + 1,
      updatedAt: new Date().toISOString(),
    };
    if (!(await repo.saveState(doc, expected)))
      throw new Problem(409, "conflict", "State revision changed");
    const { ownerId, ...result } = doc;
    res.json(result);
  });
  app.get("/v1/sync/manifest", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    const repo = await repository();
    const manifest: Manifest = repo.manifest
      ? await repo.manifest(a.ownerId)
      : {
          entities: (await all(a.ownerId)).map(({ id, revision, deleted }) => ({
            id,
            revision,
            deleted,
          })),
          states: (await repo.states(a.ownerId)).map(({ id, revision }) => ({
            id,
            revision,
          })),
        };
    if (manifest.entities.length > 10000 || manifest.states.length > 10000)
      throw new Problem(
        503,
        "library_limit",
        "Manifest exceeds bootstrap limit",
      );
    const etag = manifestETag(a.ownerId, manifest);
    res.set("ETag", etag);
    res.set("X-Manga-Sync", "manifest-v2");
    if (req.get("if-none-match") === etag) {
      res.status(304).end();
      return;
    }
    res.json({ schemaVersion: 2, ...manifest });
  });
  app.post("/v1/sync/records", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    const body = syncRecordsSchema.parse(req.body);
    const repo = await repository();
    const [entities, states] = await Promise.all([
      recordsByIds(repo, a.ownerId, body.entities),
      repo.statesByIds
        ? repo.statesByIds(a.ownerId, body.states)
        : repo
            .states(a.ownerId)
            .then((values) => values.filter((s) => body.states.includes(s.id))),
    ]);
    const selectedEntities: ReturnType<typeof compactRecord>[] = [];
    const selectedStates: ReturnType<typeof publicState>[] = [];
    const remainingEntities: string[] = [],
      remainingStates: string[] = [];
    let bytes = 256;
    for (const entity of entities) {
      const value = compactRecord(entity),
        size = Buffer.byteLength(JSON.stringify(value)) + 1;
      if (size > 3000000)
        throw new Problem(
          413,
          "record_too_large",
          "Record exceeds the sync response limit",
        );
      if (bytes + size > 3000000) remainingEntities.push(entity.id);
      else {
        selectedEntities.push(value);
        bytes += size;
      }
    }
    for (const state of states) {
      const value = publicState(state),
        size = Buffer.byteLength(JSON.stringify(value)) + 1;
      if (bytes + size > 3000000) remainingStates.push(state.id);
      else {
        selectedStates.push(value);
        bytes += size;
      }
    }
    res.json({
      schemaVersion: 1,
      entities: selectedEntities,
      states: selectedStates,
      ...(remainingEntities.length ? { remainingEntities } : {}),
      ...(remainingStates.length ? { remainingStates } : {}),
    });
  });
  // Bootstrap snapshot, including tombstones and NSFW metadata; clients apply visibility locally.
  // No cursor can miss a write in flight. Incremental sync is deliberately deferred.
  app.get("/v1/sync", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    const repo = await repository();
    const entities = await all(a.ownerId);
    const states = await repo.states(a.ownerId);
    if (states.length > 10000)
      throw new Problem(
        503,
        "library_limit",
        "State snapshot exceeds bootstrap limit",
      );
    res.json({
      schemaVersion: 1,
      entities: entities.map(publicRecord),
      states: states.map(({ ownerId, ...s }) => s),
    });
  });
  app.use(
    (
      err: unknown,
      _req: express.Request,
      res: express.Response,
      _next: express.NextFunction,
    ) => {
      if (err instanceof z.ZodError)
        return res.status(400).json({
          error: {
            code: "validation_error",
            message:
              err.issues.find((issue) => issue.path.includes("description"))
                ?.message ?? "Invalid request",
            details: err.issues,
          },
        });
      const p = err instanceof Problem ? err : undefined;
      if (!p)
        console.error(
          "Request failed",
          err instanceof Error ? err.name : "Unknown error",
        );
      if (p?.code === "insufficient_scope")
        res.set("WWW-Authenticate", 'Bearer error="insufficient_scope"');
      const syntax = err instanceof SyntaxError;
      const tooLarge = (err as { type?: string })?.type === "entity.too.large";
      res.status(p?.status ?? (syntax ? 400 : tooLarge ? 413 : 500)).json({
        error: {
          code:
            p?.code ??
            (syntax
              ? "invalid_json"
              : tooLarge
                ? "payload_too_large"
                : "internal_error"),
          message:
            p?.message ??
            (tooLarge
              ? "Request body exceeds 4 MB. Split the novel into separate chapters."
              : "Request failed"),
        },
      });
    },
  );
  return app;
}
