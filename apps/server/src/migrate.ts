import { database } from "./repository.js";
const apply = process.argv.includes("--apply");
console.log(
  "Schema v1 plus v2 query/manifest indexes: unique owner/entity/state, covered manifests and paginated lists.",
);
if (!apply) {
  console.log("Dry run only. Add --apply after backup to execute.");
  process.exit(0);
}
const db = await database();
await db
  .collection("entities")
  .createIndex({ ownerId: 1, id: 1 }, { unique: true, name: "owner_entity" });
await db
  .collection("entities")
  .createIndex({ ownerId: 1, kind: 1, deleted: 1 }, { name: "owner_kind" });
await db
  .collection("states")
  .createIndex({ ownerId: 1, id: 1 }, { unique: true, name: "owner_state" });
await db
  .collection<{ _id: string; appliedAt: Date }>("schema_migrations")
  .updateOne(
    { _id: "v1" },
    { $setOnInsert: { appliedAt: new Date() } },
    { upsert: true },
  );
await db
  .collection("entities")
  .createIndex(
    { ownerId: 1, id: 1, revision: 1, deleted: 1 },
    { name: "owner_entity_manifest" },
  );
await db
  .collection("states")
  .createIndex(
    { ownerId: 1, id: 1, revision: 1 },
    { name: "owner_state_manifest" },
  );
await db
  .collection("entities")
  .createIndex(
    { ownerId: 1, kind: 1, deleted: 1, id: 1 },
    { name: "owner_kind_page" },
  );
await db
  .collection("entities")
  .createIndex(
    { ownerId: 1, workId: 1, deleted: 1, id: 1 },
    { name: "owner_work_page" },
  );
await db
  .collection("entities")
  .createIndex(
    { ownerId: 1, authorId: 1, deleted: 1, id: 1 },
    { name: "owner_author_page" },
  );
await db
  .collection("states")
  .createIndex(
    { ownerId: 1, entityId: 1, id: 1 },
    { name: "owner_entity_states" },
  );
console.log(
  "Schema v1 and v2 performance indexes applied (no document conversion).",
);
process.exit(0);
