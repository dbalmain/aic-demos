// ledger-service — the last hop. Authenticates the calling workload, then
// validates the same Txn-Token independently, with no per-token callback to
// AIC and no trust in whoever forwarded it, and writes the entry from tctx
// alone. If the request body disagrees with tctx, the body loses — that's
// the whole reason cost lives in the token, not the POST.
//
// This service is two hops from the sign-in and has never seen the account
// manager's login token. Everything it knows, it knows from a signature.
import Fastify from "fastify";
import {
  config,
  txnTokenVerifier,
  requireWorkload,
  claimedOrigin,
  note,
  registerTrailRoute,
} from "@txndemo/shared";
import { record, all } from "./store.js";

const cfg = config();
const verifyTxnToken = await txnTokenVerifier(cfg, ["client:activity:write"]);

const app = Fastify({ logger: { transport: { target: "pino-pretty" } } });

async function requireTxnToken(req, reply) {
  const header = req.headers["txn-token"];
  if (!header) {
    reply.code(401).send({ error: "no Txn-Token header presented" });
    return null;
  }
  try {
    return await verifyTxnToken(header);
  } catch (e) {
    reply.code(401).send({ error: `Txn-Token rejected: ${e.message}` });
    return null;
  }
}

app.post("/entries", async (req, reply) => {
  if (!requireWorkload(cfg, req, reply)) return;
  const payload = await requireTxnToken(req, reply);
  if (!payload) return;
  const outcome = record(payload);
  const inserted = outcome === "recorded";
  note({
    hop: "ledger-service",
    token: req.headers["txn-token"],
    payload,
    workload: claimedOrigin(req),
    validated: [
      "calling workload authenticated",
      "RS256 signature against AIC's JWKS",
      `iss is the ${cfg.realm} realm`,
      `aud is the trust domain ${cfg.trustDomain}`,
      "exp not passed",
      "required claims present: exp iat sub txn req_wl tctx",
      "scope carries client:activity:write",
    ],
    decided: inserted
      ? `recorded from tctx alone${payload.tctx?.cost_cents == null ? " (no cost asserted)" : ` (cost ${payload.tctx.cost_cents}c)`}`
      : "refused as a replay of a txn already recorded",
  });
  if (!inserted) {
    // The same txn arriving twice is a replay, not a second transaction.
    // 409 rather than 200, so a caller cannot read "recorded" into what is
    // really "already recorded, nothing done" (the draft leaves strict
    // single-use optional; this is the honest reporting half of it).
    reply.code(409);
  }
  return {
    entry: {
      txn: payload.txn,
      sub: payload.sub,
      tctx: payload.tctx,
    },
    replay: !inserted,
  };
});

app.get("/entries", async (req, reply) => {
  if (!requireWorkload(cfg, req, reply)) return;
  return { entries: all() };
});

registerTrailRoute(app, (req, reply) => requireWorkload(cfg, req, reply));

app.get("/healthz", async () => ({ ok: true }));

await app.listen({ port: cfg.ledgerPort, host: "127.0.0.1" });
