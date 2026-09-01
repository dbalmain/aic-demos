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
import { timingSafeEqual } from "node:crypto";

const enc = new TextEncoder();

function constantTimeEqual(a, b) {
  const x = enc.encode(a);
  const y = enc.encode(b);
  if (x.length !== y.length) return false;
  return timingSafeEqual(x, y);
}

/** The header an internal caller sends. */
export function workloadHeaders(cfg) {
  return { authorization: `Bearer ${cfg.internalToken}` };
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
