import jsonpatch from "fast-json-patch";
import { MongoClient, type Db, type UpdateFilter } from "mongodb";
import type { RecordDocument, StateDocument } from "./domain.js";
import type {
  Manifest,
  RecordQuery,
  VisibilityRecord,
  StateTarget,
} from "./sync.js";
export interface Repository {
  visibilityRecords?(owner: string, ids: string[]): Promise<VisibilityRecord[]>;
  stateTarget?(owner: string, id: string): Promise<StateTarget | null>;
  saveChanges?(
    before: RecordDocument,
    after: RecordDocument,
    operations: jsonpatch.Operation[],
  ): Promise<boolean>;
  hasReferences?(owner: string, id: string): Promise<boolean>;
  listStates?(
    owner: string,
    query: { entityId?: string; after?: string; limit: number },
  ): Promise<StateDocument[]>;
  manifest?(owner: string): Promise<Manifest>;
  recordsByIds?(owner: string, ids: string[]): Promise<RecordDocument[]>;
  statesByIds?(owner: string, ids: string[]): Promise<StateDocument[]>;
  getState?(owner: string, id: string): Promise<StateDocument | null>;
  listRecords?(owner: string, query: RecordQuery): Promise<RecordDocument[]>;
  records(owner: string): Promise<RecordDocument[]>;
  get(owner: string, id: string): Promise<RecordDocument | null>;
  save(doc: RecordDocument, expected: number): Promise<boolean>;
  states(owner: string): Promise<StateDocument[]>;
  saveState(doc: StateDocument, expected: number): Promise<boolean>;
}
export class MongoRepository implements Repository {
  constructor(private db: Db) {}
  async visibilityRecords(ownerId: string, ids: string[]) {
    if (!ids.length) return [];
    return this.db
      .collection<VisibilityRecord>("entities")
      .find(
        { ownerId, id: { $in: ids } },
        {
          projection: {
            _id: 0,
            id: 1,
            deleted: 1,
            nsfw: 1,
            tagIds: 1,
            authorId: 1,
            seriesId: 1,
            workId: 1,
          },
        },
      )
      .toArray();
  }
  async stateTarget(ownerId: string, id: string) {
    return this.db.collection<StateTarget>("entities").findOne(
      { ownerId, id },
      {
        projection: {
          _id: 0,
          id: 1,
          kind: 1,
          deleted: 1,
          "media.id": 1,
          "media.pageCount": 1,
        },
      },
    );
  }
  async hasReferences(ownerId: string, id: string) {
    return !!(await this.db.collection<RecordDocument>("entities").findOne(
      {
        ownerId,
        deleted: false,
        $or: [
          { authorId: id },
          { seriesId: id },
          { workId: id },
          { tagIds: id },
          { "media.storageRootId": id },
        ],
      },
      { projection: { _id: 1 } },
    ));
  }
  async listStates(
    ownerId: string,
    query: { entityId?: string; after?: string; limit: number },
  ) {
    return this.db
      .collection<StateDocument>("states")
      .find({
        ownerId,
        ...(query.entityId ? { entityId: query.entityId } : {}),
        ...(query.after ? { id: { $gt: query.after } } : {}),
      })
      .sort({ id: 1 })
      .limit(query.limit)
      .toArray();
  }
  async manifest(ownerId: string): Promise<Manifest> {
    const [entities, states] = await Promise.all([
      this.db
        .collection<RecordDocument>("entities")
        .find(
          { ownerId },
          { projection: { _id: 0, id: 1, revision: 1, deleted: 1 } },
        )
        .limit(10001)
        .toArray(),
      this.db
        .collection<StateDocument>("states")
        .find({ ownerId }, { projection: { _id: 0, id: 1, revision: 1 } })
        .limit(10001)
        .toArray(),
    ]);
    return { entities, states };
  }
  async recordsByIds(ownerId: string, ids: string[]) {
    if (!ids.length) return [];
    return this.db
      .collection<RecordDocument>("entities")
      .find({ ownerId, id: { $in: ids } })
      .toArray();
  }
  async statesByIds(ownerId: string, ids: string[]) {
    if (!ids.length) return [];
    return this.db
      .collection<StateDocument>("states")
      .find({ ownerId, id: { $in: ids } })
      .toArray();
  }
  async getState(ownerId: string, id: string) {
    return this.db.collection<StateDocument>("states").findOne({ ownerId, id });
  }
  async listRecords(ownerId: string, query: RecordQuery) {
    const filter: Record<string, unknown> = { ownerId, deleted: false };
    for (const key of ["kind", "workId", "authorId"] as const)
      if (query[key]) filter[key] = query[key];
    if (query.after) filter.id = { $gt: query.after };
    if (query.q) {
      const escaped = query.q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      filter.$or = [
        { title: { $regex: escaped, $options: "i" } },
        {
          $expr: {
            $anyElementTrue: {
              $map: {
                input: { $objectToArray: { $ifNull: ["$localizations", {}] } },
                as: "text",
                in: {
                  $regexMatch: {
                    input: { $ifNull: ["$$text.v.title", ""] },
                    regex: escaped,
                    options: "i",
                  },
                },
              },
            },
          },
        },
      ];
    }
    return this.db
      .collection<RecordDocument>("entities")
      .find(filter)
      .sort({ id: 1 })
      .limit(query.limit)
      .toArray();
  }
  async records(ownerId: string) {
    return this.db
      .collection<RecordDocument>("entities")
      .find({ ownerId })
      .limit(10001)
      .toArray();
  }
  async get(ownerId: string, id: string) {
    return this.db
      .collection<RecordDocument>("entities")
      .findOne({ ownerId, id });
  }
  async saveChanges(
    before: RecordDocument,
    after: RecordDocument,
    operations: jsonpatch.Operation[],
  ) {
    const set: Record<string, unknown> = {
      revision: after.revision,
      updatedAt: after.updatedAt,
    };
    const unset: Record<string, ""> = {},
      push: Record<string, { $each: unknown[] }> = {};
    const touched: string[] = [];
    for (const operation of operations) {
      if (operation.op === "test") continue;
      const parts = operation.path
        .slice(1)
        .split("/")
        .map((p) => p.replace(/~1/g, "/").replace(/~0/g, "~"));
      if (parts.some((p) => p.includes(".") || p.startsWith("$")))
        return this.save(after, before.revision);
      const parentPointer = operation.path.slice(
        0,
        operation.path.lastIndexOf("/"),
      );
      const parent = jsonpatch.getValueByPointer(before, parentPointer);
      const append =
        operation.op === "add" && parts.at(-1) === "-" && Array.isArray(parent);
      if (Array.isArray(parent) && operation.op !== "replace" && !append)
        return this.save(after, before.revision);
      const field = (append ? parts.slice(0, -1) : parts).join(".");
      if (append && (field in set || field in unset))
        return this.save(after, before.revision);
      if (
        touched.some(
          (p) =>
            (p === field && !append) ||
            p.startsWith(field + ".") ||
            field.startsWith(p + "."),
        )
      )
        return this.save(after, before.revision);
      touched.push(field);
      if (append) {
        (push[field] ??= { $each: [] }).$each.push(
          (operation as { value: unknown }).value,
        );
      } else {
        const value = jsonpatch.getValueByPointer(after, operation.path);
        if (value === undefined) unset[field] = "";
        else set[field] = value;
      }
    }
    const update = {
      $set: set,
      ...(Object.keys(unset).length ? { $unset: unset } : {}),
      ...(Object.keys(push).length ? { $push: push } : {}),
    } as UpdateFilter<RecordDocument>;
    return (
      (
        await this.db.collection<RecordDocument>("entities").updateOne(
          {
            ownerId: before.ownerId,
            id: before.id,
            revision: before.revision,
          },
          update,
        )
      ).modifiedCount === 1
    );
  }
  async save(doc: RecordDocument, expected: number) {
    const col = this.db.collection<RecordDocument>("entities");
    if (!expected) {
      try {
        await col.insertOne(doc);
        return true;
      } catch (e) {
        if ((e as { code?: number }).code === 11000) return false;
        throw e;
      }
    }
    return (
      (
        await col.replaceOne(
          { ownerId: doc.ownerId, id: doc.id, revision: expected },
          doc,
        )
      ).modifiedCount === 1
    );
  }
  async states(ownerId: string) {
    return this.db
      .collection<StateDocument>("states")
      .find({ ownerId })
      .limit(10001)
      .toArray();
  }
  async saveState(doc: StateDocument, expected: number) {
    const col = this.db.collection<StateDocument>("states");
    if (!expected) {
      try {
        await col.insertOne(doc);
        return true;
      } catch (e) {
        if ((e as { code?: number }).code === 11000) return false;
        throw e;
      }
    }
    return (
      (
        await col.replaceOne(
          { ownerId: doc.ownerId, id: doc.id, revision: expected },
          doc,
        )
      ).modifiedCount === 1
    );
  }
}
let connection: Promise<MongoClient> | undefined;
export async function database() {
  const uri = process.env.MONGODB_URI;
  if (!uri) throw new Error("MONGODB_URI is required");
  connection ??= new MongoClient(uri, {
    maxPoolSize: 10,
    serverSelectionTimeoutMS: 5000,
  })
    .connect()
    .catch((e) => {
      connection = undefined;
      throw e;
    });
  return (await connection).db(process.env.MONGODB_DATABASE ?? "mangareader");
}
