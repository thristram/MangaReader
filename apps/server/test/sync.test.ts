import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import request from "supertest";
import { createApp } from "../src/create-app.js";
import type { Repository } from "../src/repository.js";
import type { RecordDocument, StateDocument } from "../src/domain.js";
import type { RecordQuery } from "../src/sync.js";
class ScopedRepository implements Repository {
  docs = new Map<string, RecordDocument>();
  stateDocs = new Map<string, StateDocument>();
  fullReads = 0;
  async records(_owner: string): Promise<RecordDocument[]> {
    this.fullReads++;
    throw Error("Full catalog read forbidden in optimized route");
  }
  async states(_owner: string): Promise<StateDocument[]> {
    this.fullReads++;
    throw Error("Full state read forbidden in optimized route");
  }
  getCalls = 0;
  targetReads = 0;
  async get(owner: string, id: string) {
    this.getCalls++;
    return this.docs.get(owner + id) ?? null;
  }
  async stateTarget(owner: string, id: string) {
    this.targetReads++;
    const value = this.docs.get(owner + id);
    return value
      ? {
          id: value.id,
          kind: value.kind,
          deleted: value.deleted,
          media: value.media.map((m) => ({ id: m.id, pageCount: m.pageCount })),
        }
      : null;
  }
  async visibilityRecords(owner: string, ids: string[]) {
    return (await this.recordsByIds(owner, ids)).map((d) => ({
      id: d.id,
      deleted: d.deleted,
      nsfw: d.nsfw,
      tagIds: d.tagIds,
      authorId: d.authorId,
      seriesId: d.seriesId,
      workId: d.workId,
    }));
  }
  async getState(owner: string, id: string) {
    return this.stateDocs.get(owner + id) ?? null;
  }
  async save(doc: RecordDocument, expected: number) {
    const key = doc.ownerId + doc.id;
    if ((this.docs.get(key)?.revision ?? 0) !== expected) return false;
    this.docs.set(key, structuredClone(doc));
    return true;
  }
  async saveState(doc: StateDocument, expected: number) {
    const key = doc.ownerId + doc.id;
    if ((this.stateDocs.get(key)?.revision ?? 0) !== expected) return false;
    this.stateDocs.set(key, structuredClone(doc));
    return true;
  }
  async manifest(owner: string) {
    return {
      entities: [...this.docs.values()]
        .filter((v) => v.ownerId === owner)
        .map(({ id, revision, deleted }) => ({ id, revision, deleted })),
      states: [...this.stateDocs.values()]
        .filter((v) => v.ownerId === owner)
        .map(({ id, revision }) => ({ id, revision })),
    };
  }
  async recordsByIds(owner: string, ids: string[]) {
    return [...this.docs.values()].filter(
      (v) => v.ownerId === owner && ids.includes(v.id),
    );
  }
  async statesByIds(owner: string, ids: string[]) {
    return [...this.stateDocs.values()].filter(
      (v) => v.ownerId === owner && ids.includes(v.id),
    );
  }
  async hasReferences(owner: string, id: string) {
    return [...this.docs.values()].some(
      (d) =>
        d.ownerId === owner &&
        !d.deleted &&
        [
          d.authorId,
          d.seriesId,
          d.workId,
          ...d.tagIds,
          ...d.media.map((m) => m.storageRootId),
        ].includes(id),
    );
  }
  async listRecords(owner: string, q: RecordQuery) {
    return [...this.docs.values()]
      .filter(
        (v) =>
          v.ownerId === owner &&
          !v.deleted &&
          (!q.kind || v.kind === q.kind) &&
          (!q.workId || v.workId === q.workId) &&
          (!q.authorId || v.authorId === q.authorId) &&
          (!q.after || v.id > q.after),
      )
      .sort((a, b) => a.id.localeCompare(b.id))
      .slice(0, q.limit);
  }
}
function fixture() {
  const repo = new ScopedRepository();
  const app = createApp(
    async () => repo,
    async (token) => ({
      ownerId: token === "phone" ? "alice" : token,
      issuer: "https://test.invalid",
      subject: token,
      scopes: new Set(
        token === "phone"
          ? ["manga:read", "manga:state:write"]
          : ["manga:read", "manga:manage", "manga:state:write"],
      ),
    }),
  );
  return { repo, app };
}
test("novel descriptions save through PATCH/PUT and sync; limits are explicit and atomic", async () => {
  const { app, repo } = fixture();
  const entity = await chapter(app);
  const novel = "雨".repeat(34592);
  await request(app)
    .patch(`/v1/entities/${entity.id}`)
    .auth("alice", { type: "bearer" })
    .set("If-Match", "1")
    .send([{ op: "replace", path: "/description", value: novel }])
    .expect(200);
  const stored = repo.docs.get("alice" + entity.id)!;
  assert.equal(stored.description, novel);
  const body = {
    ...stored,
    localizations: { zh: { description: novel } },
  } as Record<string, unknown>;
  for (const key of ["id", "ownerId", "revision", "updatedAt", "deleted"])
    delete body[key];
  await request(app)
    .put(`/v1/entities/${entity.id}`)
    .auth("alice", { type: "bearer" })
    .set("If-Match", "2")
    .send(body)
    .expect(200);
  const synced = await request(app)
    .post("/v1/sync/records")
    .auth("alice", { type: "bearer" })
    .send({ entities: [entity.id], states: [] })
    .expect(200);
  assert.equal(synced.body.entities[0].description.length, 34592);
  assert.equal(synced.body.entities[0].localizations.zh.description, novel);
  for (const path of ["/description", "/localizations/zh/description"]) {
    const rejected = await request(app)
      .patch(`/v1/entities/${entity.id}`)
      .auth("alice", { type: "bearer" })
      .set("If-Match", "3")
      .send([{ op: "replace", path, value: "文".repeat(500001) }])
      .expect(400);
    assert.match(rejected.body.error.message, /500,000/);
  }
  assert.equal(repo.docs.get("alice" + entity.id)!.revision, 3);
  // Two large Japanese fields exceed the former HTTP parser limit, but fit
  // within the explicit document budget and remain retrievable by sync.
  const large = "文".repeat(350000);
  await request(app)
    .patch(`/v1/entities/${entity.id}`)
    .auth("alice", { type: "bearer" })
    .set("If-Match", "3")
    .send([
      { op: "replace", path: "/description", value: large },
      { op: "replace", path: "/localizations/zh/description", value: large },
    ])
    .expect(200);
  const rejected = await request(app)
    .patch(`/v1/entities/${entity.id}`)
    .auth("alice", { type: "bearer" })
    .set("If-Match", "4")
    .send([
      { op: "add", path: "/localizations/fr", value: { description: large } },
    ])
    .expect(400);
  assert.match(rejected.body.error.message, /2.8 MB/);
  assert.equal(repo.docs.get("alice" + entity.id)!.revision, 4);
});
async function chapter(app: ReturnType<typeof createApp>) {
  const author = (
    await request(app)
      .post("/v1/entities")
      .auth("alice", { type: "bearer" })
      .send({ kind: "author", title: "Author" })
      .expect(201)
  ).body;
  const root = (
    await request(app)
      .post("/v1/entities")
      .auth("alice", { type: "bearer" })
      .send({ kind: "storageRoot", title: "NAS", storageKind: "smb" })
      .expect(201)
  ).body;
  return (
    await request(app)
      .post("/v1/entities")
      .auth("alice", { type: "bearer" })
      .send({
        kind: "chapter",
        title: "Chapter",
        description: "private description",
        authorId: author.id,
        media: [
          {
            id: randomUUID(),
            language: "ja",
            kind: "images",
            storageRootId: root.id,
            pageCount: 1000,
            relativePaths: Array.from(
              { length: 1000 },
              (_, i) => `Author/Comic/Chapter/ja/${i}.png`,
            ),
          },
        ],
      })
      .expect(201)
  ).body;
}
test("manifest is conditional and owner scoped; record fetch is selective and path compact", async () => {
  const { repo, app } = fixture();
  const c = await chapter(app);
  const first = await request(app)
    .get("/v1/sync/manifest")
    .auth("alice", { type: "bearer" })
    .expect(200);
  assert.equal(first.body.schemaVersion, 2);
  assert.equal(
    JSON.stringify(first.body).includes("private description"),
    false,
  );
  assert.equal(JSON.stringify(first.body).includes(".png"), false);
  const unchanged = await request(app)
    .get("/v1/sync/manifest")
    .auth("alice", { type: "bearer" })
    .set("If-None-Match", first.headers.etag!)
    .expect(304);
  assert.equal(unchanged.text, "");
  const other = await request(app)
    .get("/v1/sync/manifest")
    .auth("bob", { type: "bearer" })
    .set("If-None-Match", first.headers.etag!)
    .expect(200);
  assert.deepEqual(other.body.entities, []);
  const batch = await request(app)
    .post("/v1/sync/records")
    .auth("alice", { type: "bearer" })
    .send({ entities: [c.id], states: [] })
    .expect(200);
  assert.equal(batch.body.entities.length, 1);
  assert.equal(
    batch.body.entities[0].media[0].pathDirectory,
    "Author/Comic/Chapter/ja",
  );
  assert.equal(batch.body.entities[0].media[0].pathFiles.length, 1000);
  assert.equal(batch.body.entities[0].media[0].relativePaths, undefined);
  assert.ok(JSON.stringify(batch.body).length < JSON.stringify(c).length / 2);
  assert.deepEqual(
    (
      await request(app)
        .post("/v1/sync/records")
        .auth("bob", { type: "bearer" })
        .send({ entities: [c.id], states: [] })
        .expect(200)
    ).body.entities,
    [],
  );
  await request(app)
    .put("/v1/states")
    .auth("alice", { type: "bearer" })
    .set("If-Match", "0")
    .send({ entityId: c.id, starred: true })
    .expect(200);
  const changed = await request(app)
    .get("/v1/sync/manifest")
    .auth("alice", { type: "bearer" })
    .set("If-None-Match", first.headers.etag!)
    .expect(200);
  assert.equal(changed.body.states.length, 1);
  await request(app)
    .get(`/v1/states/${c.id}:entity`)
    .auth("alice", { type: "bearer" })
    .expect(200);
  await request(app)
    .get(`/v1/states/${c.id}:entity`)
    .auth("bob", { type: "bearer" })
    .expect(404);
  assert.equal(repo.fullReads, 0);
});
test("small page PATCH preserves all other metadata, returns receipt, enforces CAS/scopes/paths", async () => {
  const { repo, app } = fixture();
  const c = await chapter(app);
  const path = `/v1/entities/${c.id}`;
  const patch = [
    {
      op: "add",
      path: "/media/0/relativePaths/-",
      value: "Author/Comic/Chapter/ja/1000.png",
    },
    { op: "replace", path: "/media/0/pageCount", value: 1001 },
  ];
  assert.ok(JSON.stringify(patch).length < 250);
  const receipt = await request(app)
    .patch(path)
    .auth("alice", { type: "bearer" })
    .set("If-Match", "1")
    .send(patch)
    .expect(200);
  assert.deepEqual(Object.keys(receipt.body).sort(), [
    "id",
    "revision",
    "title",
    "updatedAt",
  ]);
  const saved = await repo.get("alice", c.id);
  assert.equal(saved?.media[0]?.relativePaths.length, 1001);
  assert.equal(saved?.description, c.description);
  await request(app)
    .patch(path)
    .auth("alice", { type: "bearer" })
    .set("If-Match", "1")
    .send(patch)
    .expect(409);
  await request(app)
    .patch(path)
    .auth("phone", { type: "bearer" })
    .set("If-Match", "2")
    .send(patch)
    .expect(403);
  for (const pointer of [
    "/ownerId",
    "/id",
    "/kind",
    "/media/0/__proto__/polluted",
  ])
    await request(app)
      .patch(path)
      .auth("alice", { type: "bearer" })
      .set("If-Match", "2")
      .send([{ op: "add", path: pointer, value: "bad" }])
      .expect(400);
  await request(app)
    .patch(path)
    .auth("alice", { type: "bearer" })
    .set("If-Match", "2")
    .send([
      {
        op: "replace",
        path: "/media/0/relativePaths/0",
        value: "../escape.png",
      },
    ])
    .expect(400);
  assert.equal(({} as Record<string, unknown>).polluted, undefined);
  assert.equal((await repo.get("alice", c.id))?.revision, 2);
});
test("detail/list reads use scoped selectors; manifest retains deletion tombstones; gzip large responses", async () => {
  const { repo, app } = fixture();
  const c = await chapter(app);
  await request(app)
    .get(`/v1/entities/${c.id}?includeNSFW=true`)
    .auth("alice", { type: "bearer" })
    .expect(200);
  const list = await request(app)
    .get("/v1/entities?kind=chapter&limit=1")
    .auth("alice", { type: "bearer" })
    .expect(200);
  assert.equal(list.body.items.length, 1);
  const response = await request(app)
    .post("/v1/sync/records")
    .auth("alice", { type: "bearer" })
    .set("Accept-Encoding", "gzip")
    .send({ entities: [c.id], states: [] })
    .expect(200);
  assert.equal(response.headers["content-encoding"], "gzip");
  assert.match(response.headers["cache-control"]!, /no-store/);
  await request(app)
    .delete(`/v1/entities/${c.id}`)
    .auth("alice", { type: "bearer" })
    .set("If-Match", "1")
    .expect(204);
  const manifest = await request(app)
    .get("/v1/sync/manifest")
    .auth("alice", { type: "bearer" })
    .expect(200);
  assert.equal(
    manifest.body.entities.find((v: { id: string }) => v.id === c.id).deleted,
    true,
  );
  assert.equal(repo.fullReads, 0);
});

test("Mongo page append uses guarded $push/$set, while array removal keeps safe replacement semantics", async () => {
  const { MongoRepository } = await import("../src/repository.js");
  const updates: { filter: unknown; update: unknown }[] = [];
  const replacements: unknown[] = [];
  const collection = {
    updateOne: async (filter: unknown, update: unknown) => {
      updates.push({ filter, update });
      return { modifiedCount: 1 };
    },
    replaceOne: async (_filter: unknown, value: unknown) => {
      replacements.push(value);
      return { modifiedCount: 1 };
    },
  };
  const repo = new MongoRepository({
    collection: () => collection,
  } as unknown as import("mongodb").Db);
  const before: RecordDocument = {
    id: randomUUID(),
    ownerId: "alice",
    kind: "chapter",
    title: "C",
    originalLanguage: "ja",
    description: "",
    localizations: {},
    tagIds: [],
    nsfw: false,
    sources: [],
    revision: 1,
    updatedAt: "old",
    deleted: false,
    media: [
      {
        id: randomUUID(),
        language: "ja",
        kind: "images",
        storageRootId: randomUUID(),
        pageCount: 1000,
        relativePaths: Array.from(
          { length: 1000 },
          (_, i) => `Folder/${i}.png`,
        ),
      },
    ],
  };
  const after = structuredClone(before);
  after.revision = 2;
  after.updatedAt = "new";
  after.media[0]!.relativePaths.push("Folder/new.png");
  after.media[0]!.pageCount++;
  assert.equal(
    await repo.saveChanges(before, after, [
      { op: "add", path: "/media/0/relativePaths/-", value: "Folder/new.png" },
      { op: "replace", path: "/media/0/pageCount", value: 1001 },
    ]),
    true,
  );
  assert.deepEqual(updates[0]!.filter, {
    ownerId: "alice",
    id: before.id,
    revision: 1,
  });
  assert.ok(JSON.stringify(updates[0]!.update).length < 300);
  assert.equal(replacements.length, 0);
  assert.deepEqual((updates[0]!.update as { $push: unknown }).$push, {
    "media.0.relativePaths": { $each: ["Folder/new.png"] },
  });
  const removed = structuredClone(after);
  removed.media[0]!.relativePaths.splice(0, 1);
  removed.revision = 3;
  await repo.saveChanges(after, removed, [
    { op: "remove", path: "/media/0/relativePaths/0" },
  ]);
  assert.equal(replacements.length, 1);
  assert.deepEqual(replacements[0], removed);
});

test("large selective batches defer records below the function response limit", async () => {
  const { app, repo } = fixture();
  const c = await chapter(app);
  const ids: string[] = [];
  for (let i = 0; i < 4; i++) {
    const value = structuredClone(repo.docs.get("alice" + c.id)!);
    value.id = randomUUID();
    value.media[0]!.relativePaths = Array.from(
      { length: 10000 },
      (_, n) => "Directory/" + String(n) + "x".repeat(140) + ".png",
    );
    value.media[0]!.pageCount = 10000;
    repo.docs.set("alice" + value.id, value);
    ids.push(value.id);
  }
  const response = await request(app)
    .post("/v1/sync/records")
    .auth("alice", { type: "bearer" })
    .send({ entities: ids, states: [] })
    .expect(200);
  assert.ok(Buffer.byteLength(response.text) < 3100000);
  assert.ok(response.body.remainingEntities.length > 0);
  assert.equal(
    response.body.entities.length + response.body.remainingEntities.length,
    4,
  );
});

test("scoped visibility follows deep tag chains without full scans or fail-open depth limits", async () => {
  const { app, repo } = fixture();
  const c = await chapter(app);
  let prior: string | undefined;
  for (let i = 0; i < 40; i++) {
    const id = randomUUID();
    repo.docs.set("alice" + id, {
      id,
      ownerId: "alice",
      kind: "tag",
      title: "Tag",
      originalLanguage: "en",
      description: "",
      localizations: {},
      tagIds: prior ? [prior] : [],
      nsfw: i === 0,
      sources: [],
      media: [],
      revision: 1,
      updatedAt: "fixture",
      deleted: false,
    });
    prior = id;
  }
  repo.docs.get("alice" + c.id)!.tagIds = [prior!];
  await request(app)
    .get(`/v1/entities/${c.id}`)
    .auth("alice", { type: "bearer" })
    .expect(404);
  await request(app)
    .get(`/v1/entities/${c.id}?includeNSFW=true`)
    .auth("alice", { type: "bearer" })
    .expect(200);
  assert.equal(repo.fullReads, 0);
});

test("reading state validation uses projected targets without loading chapter paths", async () => {
  const { app, repo } = fixture();
  const c = await chapter(app);
  repo.getCalls = 0;
  repo.targetReads = 0;
  await request(app)
    .put("/v1/states")
    .auth("alice", { type: "bearer" })
    .set("If-Match", "0")
    .send({
      entityId: c.id,
      favorite: false,
      starred: false,
      progress: {
        mediaId: c.media[0].id,
        pageIndex: 500,
        completed: false,
        activeSeconds: 10,
      },
    })
    .expect(200);
  await request(app)
    .get(`/v1/states/${c.id}:entity`)
    .auth("alice", { type: "bearer" })
    .expect(200);
  assert.equal(repo.getCalls, 0);
  assert.equal(repo.targetReads, 2);
  await request(app)
    .patch(`/v1/entities/${c.id}`)
    .auth("alice", { type: "bearer" })
    .set("If-Match", "1")
    .type("application/json-patch+json")
    .send([{ op: "replace", path: "/title", value: "Small title change" }])
    .expect(200);
});
