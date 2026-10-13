import test from "node:test";
import assert from "node:assert/strict";
import { MongoClient } from "mongodb";
import { randomUUID } from "node:crypto";
import request from "supertest";
import { MongoRepository } from "../src/repository.js";
import { createApp } from "../src/app.js";
test(
  "MongoDB persistence, unique account indexes, CAS and account isolation",
  { skip: !process.env.MONGODB_TEST_URI },
  async () => {
    const client = await new MongoClient(
      process.env.MONGODB_TEST_URI!,
    ).connect();
    const name = "mangareader_test_" + randomUUID().replaceAll("-", "");
    const db = client.db(name);
    try {
      await db
        .collection("entities")
        .createIndex({ ownerId: 1, id: 1 }, { unique: true });
      await db
        .collection("states")
        .createIndex({ ownerId: 1, id: 1 }, { unique: true });
      const repo = new MongoRepository(db);
      const verify = async (token: string) => ({
        ownerId: token,
        issuer: "https://auth.test",
        subject: token,
        scopes: new Set(["manga:read", "manga:manage", "manga:state:write"]),
      });
      const app = createApp(async () => repo, verify);
      const created = await request(app)
        .post("/v1/entities")
        .auth("alice", { type: "bearer" })
        .send({ kind: "author", title: "Stored author" })
        .expect(201);
      const reload = createApp(
        async () => new MongoRepository(client.db(name)),
        verify,
      );
      assert.equal(
        (
          await request(reload)
            .get("/v1/entities")
            .auth("alice", { type: "bearer" })
            .expect(200)
        ).body.items[0].title,
        "Stored author",
      );
      assert.equal(
        (
          await request(reload)
            .get("/v1/entities")
            .auth("bob", { type: "bearer" })
            .expect(200)
        ).body.items.length,
        0,
      );
      const edits = await Promise.all(
        ["first", "second"].map((title) =>
          request(app)
            .put("/v1/entities/" + created.body.id)
            .auth("alice", { type: "bearer" })
            .set("If-Match", "1")
            .send({ kind: "author", title }),
        ),
      );
      assert.deepEqual(edits.map((e) => e.status).sort(), [200, 409]);
      const writes = await Promise.all(
        [true, false].map((favorite) =>
          request(app)
            .put("/v1/states")
            .auth("alice", { type: "bearer" })
            .set("If-Match", "0")
            .send({ entityId: created.body.id, favorite }),
        ),
      );
      assert.deepEqual(writes.map((e) => e.status).sort(), [200, 409]);
    } finally {
      await db.dropDatabase();
      await client.close();
    }
  },
);
