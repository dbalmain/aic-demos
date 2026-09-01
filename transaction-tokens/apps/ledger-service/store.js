// The ledger's own store: one row per transaction, keyed by the Txn-Token's
// `txn` claim so a re-delivered token records once, not twice.
import { DatabaseSync } from "node:sqlite";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const db = new DatabaseSync(join(here, "ledger.sqlite"));

db.exec(`
  CREATE TABLE IF NOT EXISTS entries (
    txn           TEXT PRIMARY KEY,
    sub           TEXT NOT NULL,
    client_ref    TEXT,
    client_display TEXT,
    client_tier   TEXT,
    activity_type TEXT,
    delivered_on  TEXT,
    cost_cents    INTEGER,
    recorded_at   TEXT NOT NULL
  )
`);

const insert = db.prepare(`
  INSERT INTO entries
    (txn, sub, client_ref, client_display, client_tier, activity_type, delivered_on, cost_cents, recorded_at)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
`);
const existing = db.prepare("SELECT 1 FROM entries WHERE txn = ?");

/**
 * Records one entry from a Txn-Token's own claims — never from a request
 * body, which is exactly the property that makes tctx integrity-critical
 * rather than advisory.
 *
 * Returns `"recorded"`, or `"replay"` when this txn is already on file.
 * A plain INSERT, with the replay decided by an explicit lookup: `INSERT OR
 * IGNORE` swallows EVERY constraint violation, so a token with a null `sub`
 * tripped NOT NULL, changed no rows, and was reported to the caller as a
 * replay of a transaction that had never happened. A real integrity error
 * now throws and surfaces as a 500, which is what it is.
 */
export function record(payload) {
  if (existing.get(payload.txn)) return "replay";
  const tctx = payload.tctx ?? {};
  insert.run(
    payload.txn,
    payload.sub,
    tctx.client_ref ?? null,
    tctx.client_display ?? null,
    tctx.client_tier ?? null,
    tctx.activity_type ?? null,
    tctx.delivered_on ?? null,
    tctx.cost_cents ?? null,
    new Date().toISOString(),
  );
  return "recorded";
}

export function all() {
  return db.prepare("SELECT * FROM entries ORDER BY recorded_at DESC").all();
}
