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
  app.use(express.json({ limit: "2mb" }));
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
    doc: RecordDocument,
    docs: RecordDocument[],
    visited = new Set<string>(),
  ): boolean => {
    if (visited.has(doc.id)) return false;
    visited.add(doc.id);
    if (doc.nsfw) return true;
    return [...doc.tagIds, doc.authorId, doc.seriesId, doc.workId].some(
      (id) =>
        id &&
        docs.some(
          (p) => p.id === id && !p.deleted && isHidden(p, docs, visited),
        ),
    );
  };
  app.get("/v1/entities", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    const docs = await all(a.ownerId);
    const includeNSFW = req.query.includeNSFW === "true";
    const q =
      typeof req.query.q === "string" ? req.query.q.toLocaleLowerCase() : "";
    const items = docs.filter(
      (d) =>
        !d.deleted &&
        (!req.query.kind || d.kind === req.query.kind) &&
        (!req.query.workId || d.workId === req.query.workId) &&
        (!req.query.authorId || d.authorId === req.query.authorId) &&
        (includeNSFW || !isHidden(d, docs)) &&
        (!q ||
          [
            d.title,
            ...Object.values(d.localizations).map((t) => t.title ?? ""),
          ].some((t) => t.toLocaleLowerCase().includes(q))),
    );
    res.json({ items: items.map(publicRecord) });
  });
  app.get("/v1/entities/:id", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:read");
    const docs = await all(a.ownerId);
    const d = docs.find(
      (d) => d.id === uuid.parse(req.params.id) && !d.deleted,
    );
    if (!d || (req.query.includeNSFW !== "true" && isHidden(d, docs)))
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
    for (const [ref, kind] of refs)
      if (ref) {
        const found = await repo.get(owner, ref);
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
      const series = await repo.get(owner, body.seriesId);
      if (series?.authorId && series.authorId !== body.authorId)
        throw new Problem(
          422,
          "invalid_reference",
          "Series author does not match",
        );
    }
    if (body.workId) {
      const work = await repo.get(owner, body.workId);
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
  app.delete("/v1/entities/:id", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:manage");
    const id = uuid.parse(req.params.id),
      expected = revision(req.get("if-match"));
    const repo = await repository();
    const old = await repo.get(a.ownerId, id);
    if (!old || old.deleted)
      throw new Problem(404, "not_found", "Entity unavailable");
    const docs = await all(a.ownerId);
    if (
      docs.some(
        (d) =>
          !d.deleted &&
          (d.authorId === id ||
            d.seriesId === id ||
            d.workId === id ||
            d.tagIds.includes(id) ||
            d.media.some((m) => m.storageRootId === id)),
      )
    )
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
    const docs = await all(a.ownerId);
    const states = await (await repository()).states(a.ownerId);
    res.json({
      items: states
        .filter((s) =>
          docs.some(
            (d) =>
              d.id === s.entityId &&
              !d.deleted &&
              (req.query.includeNSFW === "true" || !isHidden(d, docs)),
          ),
        )
        .map(({ ownerId, ...s }) => s),
    });
  });
  app.put("/v1/states", async (req, res) => {
    const a = account(res);
    hasScope(a, "manga:state:write");
    const body = stateSchema.parse(req.body),
      expected = revision(req.get("if-match"));
    const repo = await repository();
    const entity = await repo.get(a.ownerId, body.entityId);
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
            message: "Invalid request",
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
          message: p?.message ?? "Request failed",
        },
      });
    },
  );
  return app;
}
