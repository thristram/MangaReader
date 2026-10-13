import { database } from "./repository.js";
const apply = process.argv.includes("--apply");
console.log(
  "Schema v1: unique owner/entity and owner/state indexes, reference/list indexes.",
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
    { $set: { appliedAt: new Date() } },
    { upsert: true },
  );
console.log("Schema v1 applied.");
process.exit(0);
