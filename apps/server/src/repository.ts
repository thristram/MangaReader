import { MongoClient, type Db } from "mongodb";
import type { RecordDocument, StateDocument } from "./domain.js";
export interface Repository {
  records(owner: string): Promise<RecordDocument[]>;
  get(owner: string, id: string): Promise<RecordDocument | null>;
  save(doc: RecordDocument, expected: number): Promise<boolean>;
  states(owner: string): Promise<StateDocument[]>;
  saveState(doc: StateDocument, expected: number): Promise<boolean>;
}
export class MongoRepository implements Repository {
  constructor(private db: Db) {}
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
