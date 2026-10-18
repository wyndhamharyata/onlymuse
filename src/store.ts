import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Apple's answers and the window's state, in one file that outlives a quit. scripts/bench.ts points ONLYMUSE_DATA at a copy.
const folder =
  process.env.ONLYMUSE_DATA ?? join(homedir(), "Library", "Application Support", "onlymuse");
const schemaVersion = 1;
const dayMs = 24 * 60 * 60 * 1000;
const unusedResponseMaxAgeMs = 30 * dayMs;

mkdirSync(folder, { recursive: true });

const database = new Database(join(folder, "onlymuse.sqlite"), { create: true, strict: true });

// WAL lets a read go on during a write. NORMAL stays safe with WAL and skips a sync on every write.
database.run("pragma journal_mode = wal");
database.run("pragma synchronous = normal");
database.run("pragma busy_timeout = 2000");

const { user_version: storedVersion } = database.query("pragma user_version").get() as {
  user_version: number;
};

// A new schema starts the cache empty. Saved state stays.
if (storedVersion !== schemaVersion) {
  database.run("drop table if exists responses");
  database.run(`pragma user_version = ${schemaVersion}`);
}

database.run(`
  create table if not exists responses (
    path text primary key,
    body text not null,
    etag text,
    fetched_at integer not null,
    used_at integer not null
  )
`);
database.run(`
  create table if not exists state (
    key text primary key,
    value text not null,
    saved_at integer not null
  )
`);
database.run("delete from responses where used_at < ?", [Date.now() - unusedResponseMaxAgeMs]);

export type StoredResponse = { body: string; etag: string | null; fetchedAtMs: number };

const readResponseQuery = database.query<
  { body: string; etag: string | null; fetched_at: number },
  [string]
>("select body, etag, fetched_at from responses where path = ?");
const markUsedQuery = database.query("update responses set used_at = ? where path = ?");
const saveResponseQuery = database.query(`
  insert into responses (path, body, etag, fetched_at, used_at)
  values (?1, ?2, ?3, ?4, ?4)
  on conflict (path) do update set body = ?2, etag = ?3, fetched_at = ?4, used_at = ?4
`);
const markFetchedQuery = database.query("update responses set fetched_at = ? where path = ?");
const markStaleQuery = database.query(
  "update responses set fetched_at = 0 where path like ? escape '\\'"
);

export function readResponse(path: string): StoredResponse | null {
  const row = readResponseQuery.get(path);

  if (!row) return null;

  markUsedQuery.run(Date.now(), path);

  return { body: row.body, etag: row.etag, fetchedAtMs: row.fetched_at };
}

export function saveResponse(path: string, body: string, etag: string | null): void {
  saveResponseQuery.run(path, body, etag, Date.now());
}

// Apple answered 304, so the stored body is current again.
export function markResponseFetched(path: string): void {
  markFetchedQuery.run(Date.now(), path);
}

export function markResponsesStale(pathStart: string): void {
  const escapedStart = pathStart
    .replaceAll("\\", "\\\\")
    .replaceAll("%", "\\%")
    .replaceAll("_", "\\_");

  markStaleQuery.run(`${escapedStart}%`);
}

export function clearResponses(): void {
  database.run("delete from responses");
}

const readStateQuery = database.query<{ value: string }, [string]>(
  "select value from state where key = ?"
);
const saveStateQuery = database.query(`
  insert into state (key, value, saved_at) values (?1, ?2, ?3)
  on conflict (key) do update set value = ?2, saved_at = ?3
`);

// A saved value is checked here, where it enters. One that does not fit its type gives the fallback.
export function readState<Value>(
  key: string,
  isValue: (value: unknown) => value is Value,
  fallback: Value
): Value {
  const row = readStateQuery.get(key);

  if (!row) return fallback;

  try {
    const value: unknown = JSON.parse(row.value);

    return isValue(value) ? value : fallback;
  } catch {
    return fallback;
  }
}

const saveDelayMs = 300;
const pendingSaves = new Map<string, ReturnType<typeof setTimeout>>();

// A burst of changes, such as a scroll, writes once when it settles.
export function saveState(key: string, value: unknown): void {
  clearTimeout(pendingSaves.get(key));
  pendingSaves.set(
    key,
    setTimeout(() => {
      pendingSaves.delete(key);
      saveStateQuery.run(key, JSON.stringify(value), Date.now());
    }, saveDelayMs)
  );
}
