import test from "node:test";
import assert from "node:assert/strict";
import request from "supertest";
import { createApp } from "../src/app.js";
import type { Repository } from "../src/repository.js";
import type { RecordDocument, StateDocument } from "../src/domain.js";
class TestRepository implements Repository {
  docs = new Map<string, RecordDocument>();
  stateDocs = new Map<string, StateDocument>();
  async records(owner: string) {
    return [...this.docs.values()].filter((d) => d.ownerId === owner);
  }
  async get(owner: string, id: string) {
    return this.docs.get(owner + id) ?? null;
  }
  async save(d: RecordDocument, expected: number) {
    const key = d.ownerId + d.id;
    const old = this.docs.get(key);
    if ((old?.revision ?? 0) !== expected) return false;
    this.docs.set(key, structuredClone(d));
    return true;
  }
  async states(owner: string) {
    return [...this.stateDocs.values()].filter((d) => d.ownerId === owner);
  }
  async saveState(d: StateDocument, expected: number) {
    const key = d.ownerId + d.id;
    const old = this.stateDocs.get(key);
    if ((old?.revision ?? 0) !== expected) return false;
    this.stateDocs.set(key, structuredClone(d));
    return true;
  }
}
function fixture() {
  const repo = new TestRepository();
  const app = createApp(
    async () => repo,
    async (token) => {
      if (!["alice", "bob", "phone"].includes(token))
        throw new Error("invalid");
      return {
        ownerId: token === "phone" ? "alice" : token,
        issuer: "https://auth.test/api/auth",
        subject: token,
        scopes: new Set(
          token === "phone"
            ? ["manga:read", "manga:state:write"]
            : ["manga:read", "manga:state:write", "manga:manage"],
        ),
      };
    },
  );
  return { app, repo };
}
const authorized = (app: ReturnType<typeof createApp>, token = "alice") => ({
  get: (p: string) => request(app).get(p).auth(token, { type: "bearer" }),
  post: (p: string) => request(app).post(p).auth(token, { type: "bearer" }),
  put: (p: string) => request(app).put(p).auth(token, { type: "bearer" }),
  delete: (p: string) => request(app).delete(p).auth(token, { type: "bearer" }),
});
test("login required and caller cannot inject owner", async () => {
  const { app } = fixture();
  await request(app).get("/v1/entities").expect(401);
  await request(app)
    .get("/v1/me")
    .auth("invalid", { type: "bearer" })
    .expect(401);
  await authorized(app)
    .post("/v1/entities")
    .send({ kind: "author", title: "A", ownerId: "bob" })
    .expect(400);
});
test("tenant isolation covers CRUD, references and snapshot", async () => {
  const { app } = fixture();
  const a = authorized(app),
    b = authorized(app, "bob");
  const author = (
    await a
      .post("/v1/entities")
      .send({ kind: "author", title: "Private author" })
      .expect(201)
  ).body;
  assert.equal((await b.get("/v1/entities").expect(200)).body.items.length, 0);
  await b.get(`/v1/entities/${author.id}`).expect(404);
  await b
    .put(`/v1/entities/${author.id}`)
    .set("If-Match", "1")
    .send({ kind: "author", title: "stolen" })
    .expect(404);
  await b.delete(`/v1/entities/${author.id}`).set("If-Match", "1").expect(404);
  await b
    .post("/v1/entities")
    .send({ kind: "chapter", title: "C", authorId: author.id })
    .expect(422);
  await b
    .put("/v1/states")
    .set("If-Match", "0")
    .send({ entityId: author.id, favorite: true })
    .expect(404);
  assert.deepEqual((await b.get("/v1/sync").expect(200)).body.entities, []);
});
test("iPhone token can update personal state, cannot manage metadata", async () => {
  const { app } = fixture();
  const a = authorized(app);
  const entity = (
    await a.post("/v1/entities").send({ kind: "author", title: "A" })
  ).body;
  const phone = authorized(app, "phone");
  await phone
    .post("/v1/entities")
    .send({ kind: "author", title: "B" })
    .expect(403);
  await phone
    .put("/v1/states")
    .set("If-Match", "0")
    .send({ entityId: entity.id, favorite: true })
    .expect(200);
  assert.equal((await a.get("/v1/states")).body.items[0].favorite, true);
});
test("concurrent edit rejects stale revision and delete emits tombstone", async () => {
  const { app } = fixture();
  const a = authorized(app);
  const entity = (
    await a.post("/v1/entities").send({ kind: "author", title: "A" })
  ).body;
  await a
    .put(`/v1/entities/${entity.id}`)
    .send({ kind: "author", title: "B" })
    .expect(428);
  await a
    .put(`/v1/entities/${entity.id}`)
    .set("If-Match", "1")
    .send({ kind: "author", title: "B" })
    .expect(200);
  await a
    .put(`/v1/entities/${entity.id}`)
    .set("If-Match", "1")
    .send({ kind: "author", title: "stale" })
    .expect(409);
  await a.delete(`/v1/entities/${entity.id}`).set("If-Match", "2").expect(204);
  assert.equal((await a.get("/v1/entities")).body.items.length, 0);
  assert.equal((await a.get("/v1/sync")).body.entities[0].deleted, true);
});
test("NSFW inherits through tags and parents; user can explicitly reveal", async () => {
  const { app } = fixture();
  const a = authorized(app);
  const tag = (
    await a
      .post("/v1/entities")
      .send({ kind: "tag", title: "NSFW", nsfw: true })
  ).body;
  const author = (
    await a.post("/v1/entities").send({ kind: "author", title: "A" })
  ).body;
  const work = (
    await a
      .post("/v1/entities")
      .send({ kind: "work", title: "W", authorId: author.id, tagIds: [tag.id] })
  ).body;
  const chapter = (
    await a.post("/v1/entities").send({
      kind: "chapter",
      title: "C",
      authorId: author.id,
      workId: work.id,
    })
  ).body;
  await a.get(`/v1/entities/${chapter.id}`).expect(404);
  assert.equal((await a.get("/v1/entities?kind=chapter")).body.items.length, 0);
  assert.equal(
    (await a.get("/v1/entities?kind=chapter&includeNSFW=true")).body.items
      .length,
    1,
  );
  await a
    .put("/v1/states")
    .set("If-Match", "0")
    .send({ entityId: chapter.id, starred: true })
    .expect(200);
  assert.equal((await a.get("/v1/states")).body.items.length, 0);
});
test("text-only localization does not change media and unsafe paths rejected", async () => {
  const { app } = fixture();
  const a = authorized(app);
  const author = (
    await a.post("/v1/entities").send({ kind: "author", title: "A" })
  ).body;
  const root = (
    await a
      .post("/v1/entities")
      .send({ kind: "storageRoot", title: "NAS", storageKind: "smb" })
  ).body;
  const mediaId = "13b70b8f-c948-4a5b-a745-8772808bccf6";
  const input = {
    kind: "chapter",
    title: "Original",
    authorId: author.id,
    originalLanguage: "ja",
    media: [
      {
        id: mediaId,
        language: "ja",
        kind: "images",
        storageRootId: root.id,
        relativePaths: ["A/C/1.jpg"],
        pageCount: 1,
      },
    ],
  };
  const chapter = (await a.post("/v1/entities").send(input).expect(201)).body;
  const updated = (
    await a
      .put(`/v1/entities/${chapter.id}`)
      .set("If-Match", "1")
      .send({ ...input, localizations: { zh: { title: "中文" } } })
      .expect(200)
  ).body;
  assert.deepEqual(updated.media, chapter.media);
  await a
    .post("/v1/entities")
    .send({
      ...input,
      media: [{ ...input.media[0], relativePaths: ["../escape.jpg"] }],
    })
    .expect(400);
  await a
    .put("/v1/states")
    .set("If-Match", "0")
    .send({
      entityId: chapter.id,
      progress: { mediaId, pageIndex: 9, completed: false, activeSeconds: 0 },
    })
    .expect(422);
});
test("hierarchy cannot cross authors or create a parent cycle", async () => {
  const { app } = fixture(),
    a = authorized(app);
  const one = (
    await a.post("/v1/entities").send({ kind: "author", title: "One" })
  ).body;
  const two = (
    await a.post("/v1/entities").send({ kind: "author", title: "Two" })
  ).body;
  const work = (
    await a
      .post("/v1/entities")
      .send({ kind: "work", title: "W", authorId: one.id })
  ).body;
  await a
    .post("/v1/entities")
    .send({
      kind: "chapter",
      title: "Wrong author",
      authorId: two.id,
      workId: work.id,
    })
    .expect(422);
  await a
    .put(`/v1/entities/${one.id}`)
    .set("If-Match", "1")
    .send({ kind: "author", title: "cycle", authorId: two.id })
    .expect(422);
  await a.delete(`/v1/entities/${one.id}`).set("If-Match", "1").expect(409);
});
