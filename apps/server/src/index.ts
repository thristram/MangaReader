import { createApp } from "./app.js";
import { createVerifier } from "./auth.js";
import { Problem } from "./domain.js";
import { database, MongoRepository } from "./repository.js";
let schemaReady = false;
export default createApp(async () => {
  const db = await database();
  if (!schemaReady) {
    const marker = await db
      .collection<{ _id: string }>("schema_migrations")
      .findOne({ _id: "v1" });
    if (!marker)
      throw new Problem(
        503,
        "schema_not_ready",
        "Apply the MangaReader database migration before using the library API.",
      );
    schemaReady = true;
  }
  return new MongoRepository(db);
}, createVerifier());
