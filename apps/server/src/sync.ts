import { z } from "zod";
import { createHash } from "node:crypto";
import type { RecordDocument, StateDocument } from "./domain.js";
import { publicRecord } from "./domain.js";
export type EntityStamp = Pick<RecordDocument, "id" | "revision" | "deleted">;
export type StateStamp = Pick<StateDocument, "id" | "revision">;
export interface Manifest {
  entities: EntityStamp[];
  states: StateStamp[];
}
export interface RecordQuery {
  kind?: string;
  workId?: string;
  authorId?: string;
  q?: string;
  after?: string;
  limit: number;
}
export function manifestETag(owner: string, manifest: Manifest) {
  const ordered = {
    entities: [...manifest.entities].sort((a, b) => a.id.localeCompare(b.id)),
    states: [...manifest.states].sort((a, b) => a.id.localeCompare(b.id)),
  };
  return (
    '"' +
    createHash("sha256")
      .update(owner)
      .update(JSON.stringify(ordered))
      .digest("base64url") +
    '"'
  );
}
// Transport-only representation. MongoDB and legacy APIs retain relativePaths.
export function compactRecord(doc: RecordDocument) {
  return {
    ...publicRecord(doc),
    media: doc.media.map(({ relativePaths, ...media }) => {
      let directory = (relativePaths[0] ?? "").split("/").slice(0, -1);
      for (const path of relativePaths.slice(1)) {
        const parts = path.split("/");
        let i = 0;
        while (
          i < directory.length &&
          i < parts.length - 1 &&
          directory[i] === parts[i]
        )
          i++;
        directory = directory.slice(0, i);
      }
      const prefix = directory.length ? directory.join("/") + "/" : "";
      return {
        ...media,
        pathDirectory: directory.join("/"),
        pathFiles: relativePaths.map((p) => p.slice(prefix.length)),
      };
    }),
  };
}
export function publicState({
  ownerId: _owner,
  _id: _mongo,
  ...value
}: StateDocument & { _id?: unknown }) {
  return value;
}

export const patchSchema = z
  .array(
    z
      .object({
        op: z.enum(["add", "remove", "replace", "test"]),
        path: z.string().min(1).max(2000),
        value: z.unknown().optional(),
      })
      .strict(),
  )
  .max(10000);
export const stateIdSchema = z
  .string()
  .regex(/^[0-9a-f-]{36}:(?:entity|[0-9]+)$/i);
export const syncRecordsSchema = z
  .object({
    entities: z.array(z.uuid()).max(100),
    states: z.array(stateIdSchema).max(100),
  })
  .strict();

export type VisibilityRecord = Pick<
  RecordDocument,
  "id" | "deleted" | "nsfw" | "tagIds" | "authorId" | "seriesId" | "workId"
>;
export type StateTarget = Pick<RecordDocument, "id" | "kind" | "deleted"> & {
  media: Pick<RecordDocument["media"][number], "id" | "pageCount">[];
};
