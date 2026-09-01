// The workload credential on internal hops — the second of the two headers.
//
// `draft-ietf-oauth-transaction-tokens-11` is explicit that a Txn-Token must
// not be used to authenticate the calling workload: it says what was
// DECIDED, not who is calling. So each internal hop carries two credentials
// answering two questions:
//
//   Authorization: Bearer <workload secret>   who is calling this API
//   Txn-Token:     <JWT>                      what business decision was made
//
// A shared secret is a deliberate stub. Production is mTLS or a per-service
// JWT; what the demo needs to show is the separation, not the mechanism.
// Because it IS a stub, it is generated per-install by scripts/write-env.sh
// rather than being a committed constant.
//
// Be precise about what this does and does not demonstrate, because the
// difference is easy to overstate:
//
//   IT DOES show that a caller must hold a credential OTHER than the
//   Txn-Token, checked before it, so the Txn-Token is never what authorises
//   the call. That is the draft's requirement and it holds.
//
//   IT DOES NOT authenticate WHICH workload is calling. Every service
//   presents the identical value, so ledger-service cannot tell activity-api
//   from portal-bff, and cannot require that its caller was the previous hop.
//   activity-api "presents its own" only in the sense that it does not replay
//   the inbound header — the bytes are the same. Per-workload authentication
//   needs per-workload credentials; see ARCHITECTURE.md's departures.
import { timingSafeEqual } from "node:crypto";

const enc = new TextEncoder();

function constantTimeEqual(a, b) {
  const x = enc.encode(a);
  const y = enc.encode(b);
  if (x.length !== y.length) return false;
  return timingSafeEqual(x, y);
}

/**
 * The headers an internal caller sends.
 *
 * `x-txndemo-origin` is a CLAIM, not a credential: the shared secret cannot
 * tell one workload from another, so the receiving hop has no way to check
 * it. It exists because the trail has to say something about who called, and
 * a name it has verified is not available — recording an assumed one was
 * worse: the nightly job calls activity-api directly, and the trail
 * confidently attributed its requests to portal-bff, a service that was
 * never in the call. Labelled as unverified everywhere it is displayed.
 */
export function workloadHeaders(cfg, origin) {
  const headers = { authorization: `Bearer ${cfg.internalToken}` };
  if (origin) headers["x-txndemo-origin"] = origin;
  return headers;
}

/** The caller's own claim about who it is. Never verified — see above. */
export function claimedOrigin(req) {
  const raw = String(req.headers["x-txndemo-origin"] ?? "").slice(0, 64);
  return /^[a-z0-9-]+$/.test(raw) ? `${raw} (claimed, unverified)` : "unidentified caller";
}

/**
 * Rejects the request and returns false unless it carries the workload
 * credential. Checked BEFORE the Txn-Token, so an unauthenticated caller
 * learns nothing about whether its token would have been valid.
 */
export function requireWorkload(cfg, req, reply) {
  const header = String(req.headers.authorization ?? "");
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!presented || !constantTimeEqual(presented, cfg.internalToken)) {
    reply.code(401).send({ error: "calling workload is not authenticated" });
    return false;
  }
  return true;
}
