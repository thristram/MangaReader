import { z } from "zod";
export const kinds = [
  "author",
  "series",
  "work",
  "chapter",
  "tag",
  "storageRoot",
] as const;
export type Kind = (typeof kinds)[number];
const locale = z.string().regex(/^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/);
const localized = z
  .object({
    title: z.string().max(500).optional(),
    description: z.string().max(30000).optional(),
  })
  .strict();
const media = z
  .object({
    id: z.uuid(),
    language: locale,
    kind: z.enum(["images", "pdf", "video"]),
    storageRootId: z.uuid(),
    relativePaths: z
      .array(
        z
          .string()
          .min(1)
          .max(4000)
          .refine(
            (p) =>
              !p.startsWith("/") &&
              !p.split("/").some((c) => c === ".." || c === "." || c === "") &&
              !p.includes("\\"),
            "Unsafe relative path",
          ),
      )
      .min(1)
      .max(10000),
    pageCount: z.number().int().min(1).max(100000),
    pageAlignment: z
      .array(z.number().int().min(0).nullable())
      .max(100000)
      .optional(),
  })
  .strict();
export const metadataSchema = z
  .object({
    kind: z.enum(kinds),
    title: z.string().trim().min(1).max(500),
    originalLanguage: locale.default("und"),
    description: z.string().max(30000).default(""),
    localizations: z.record(locale, localized).default({}),
    authorId: z.uuid().optional(),
    seriesId: z.uuid().optional(),
    workId: z.uuid().optional(),
    tagIds: z.array(z.uuid()).max(100).default([]),
    nsfw: z.boolean().default(false),
    sources: z
      .array(
        z
          .object({
            site: z.enum(["pixiv", "patreon", "fanbox", "ehentai", "other"]),
            value: z.string().min(1).max(2000),
          })
          .strict(),
      )
      .max(50)
      .default([]),
    media: z.array(media).max(30).default([]),
    storageKind: z.enum(["local", "smb"]).optional(),
  })
  .strict()
  .superRefine((v, c) => {
    if (v.kind !== "chapter" && v.media.length)
      c.addIssue({
        code: "custom",
        message: "Media belongs to chapters",
        path: ["media"],
      });
    if (v.kind === "chapter" && !v.authorId)
      c.addIssue({
        code: "custom",
        message: "A chapter requires an author (use other author if unknown)",
        path: ["authorId"],
      });
    if (v.kind === "storageRoot" && !v.storageKind)
      c.addIssue({
        code: "custom",
        message: "Storage kind required",
        path: ["storageKind"],
      });
    if (v.kind === "tag" && v.title.toLowerCase() === "nsfw" && !v.nsfw)
      c.addIssue({
        code: "custom",
        message: "NSFW tag must be marked nsfw",
        path: ["nsfw"],
      });
  });
export type Metadata = z.infer<typeof metadataSchema>;
export interface RecordDocument extends Metadata {
  id: string;
  ownerId: string;
  revision: number;
  updatedAt: string;
  deleted: boolean;
}
export const stateSchema = z
  .object({
    entityId: z.uuid(),
    pageIndex: z.number().int().min(0).max(99999).optional(),
    favorite: z.boolean().default(false),
    starred: z.boolean().default(false),
    progress: z
      .object({
        mediaId: z.uuid(),
        pageIndex: z.number().int().min(0).max(99999),
        completed: z.boolean(),
        activeSeconds: z.number().int().min(0).max(86400),
      })
      .strict()
      .optional(),
  })
  .strict();
export type PersonalState = z.infer<typeof stateSchema>;
export interface StateDocument extends PersonalState {
  id: string;
  ownerId: string;
  revision: number;
  updatedAt: string;
}
export interface Account {
  ownerId: string;
  issuer: string;
  subject: string;
  scopes: Set<string>;
}
export class Problem extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
  ) {
    super(message);
  }
}
export function hasScope(account: Account, scope: string) {
  if (!account.scopes.has(scope))
    throw new Problem(403, "insufficient_scope", `Requires ${scope}`);
}
export function publicRecord({ ownerId: _owner, ...doc }: RecordDocument) {
  return doc;
}
