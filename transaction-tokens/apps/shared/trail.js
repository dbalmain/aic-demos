// The per-hop trail: what each service saw, what it checked, what it decided.
//
// docs/brief.md calls this the point of the POC, and it asks for three
// things specifically:
//
//   * every hop logs the txn, which workload, what it validated, what it
//     decided;
//   * a complete Txn-Token is NEVER logged — a hash for correlation, or the
//     decoded payload with the signature stripped;
//   * the decoded token viewable at each hop side by side, so it is obvious
//     the same token traversed the chain unchanged.
//
// The third is what makes the second non-negotiable in a way that is easy to
// get wrong: to show a token is unchanged you are tempted to show the token.
// The hash does the job — same hash at every hop is the proof — and the
// decoded payload gives you the content without the credential. Nothing here
// can be replayed.
//
// In-memory and capped, because this is a demo and a trail that outlives the
// token it describes is a liability, not a feature.
import { createHash } from "node:crypto";

const MAX_TXNS = 200;
const hops = new Map(); // txn -> entry[]

/** A stable, non-reversible correlator. The same token hashes the same at
 *  every hop; a different token cannot be made to collide with it. */
export function tokenHash(token) {
  return "sha256:" + createHash("sha256").update(token).digest("hex").slice(0, 16);
}

/**
 * Record one hop.
 *
 * @param {string} hop        the service's own name
 * @param {string} token      the raw Txn-Token — hashed here, never stored
 * @param {object} payload    the verified claims (no signature by definition)
 * @param {string[]} validated what this hop actually checked
 * @param {string} decided    what it did as a result
 * @param {string} workload   who called this hop
 */
export function note({ hop, token, payload, validated, decided, workload }) {
  const txn = payload?.txn;
  if (!txn) return;
  if (!hops.has(txn)) {
    if (hops.size >= MAX_TXNS) hops.delete(hops.keys().next().value);
    hops.set(txn, []);
  }
  hops.get(txn).push({
    hop,
    at: new Date().toISOString(),
    workload,
    token_hash: tokenHash(token),
    validated,
    decided,
    // The decoded payload, which is the whole point of showing it: a reader
    // can see tctx is identical at every hop without being handed a usable
    // credential.
    payload,
  });
}

/** This service's own record of one transaction. */
export function trailFor(txn) {
  return hops.get(txn) ?? [];
}

/** Registers GET /trail/:txn on a Fastify instance, behind `guard`. */
export function registerTrailRoute(app, guard) {
  app.get("/trail/:txn", async (req, reply) => {
    if (!guard(req, reply)) return;
    return { hops: trailFor(req.params.txn) };
  });
}
