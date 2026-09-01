// activity-api — the middle hop. Authenticates the CALLING WORKLOAD from its
// own credential, validates the Txn-Token independently of it, then forwards
// the same token bytes to ledger-service. Bold edge in ARCHITECTURE.md's
// diagram: this is what "no mid-chain re-issuance" means in practice — the
// token this service saw is byte-for-byte what the ledger sees.
//
// Two headers, two questions (shared/workload.js): `Authorization` says who
// is calling, `Txn-Token` says what was decided. The draft requires them to
// be separate, and forwarding is the one place that distinction shows: the
// Txn-Token is passed through untouched, while this service presents its OWN
// workload credential to the ledger rather than replaying the portal's.
import Fastify from "fastify";
import {
  config,
  txnTokenVerifier,
  workloadHeaders,
  requireWorkload,
  claimedOrigin,
  note,
  registerTrailRoute,
} from "@txndemo/shared";

const cfg = config();
// Gate A can narrow a Txn-Token to an empty scope and still mint transaction
// claims, so the operation scope is checked here rather than assumed.
const verifyTxnToken = await txnTokenVerifier(cfg, ["client:activity:write"]);

const app = Fastify({ logger: { transport: { target: "pino-pretty" } } });

app.post("/activities", async (req, reply) => {
  if (!requireWorkload(cfg, req, reply)) return;

  const header = req.headers["txn-token"];
  if (!header) return reply.code(401).send({ error: "no Txn-Token header presented" });

  let payload;
  try {
    payload = await verifyTxnToken(header);
  } catch (e) {
    return reply.code(401).send({ error: `Txn-Token rejected: ${e.message}` });
  }

  note({
    hop: "activity-api",
    token: header,
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
    decided: "forward the same token, unmodified, to ledger-service",
  });

  const res = await fetch(`${cfg.ledgerUrl}/entries`, {
    method: "POST",
    headers: { ...workloadHeaders(cfg, "activity-api"), "txn-token": header },
  });
  const ledger = await res.json().catch(() => ({}));
  if (!res.ok) return reply.code(res.status).send({ error: "ledger rejected the entry", ledger });

  return { accepted: true, tctx: payload.tctx, ledger };
});

// What this hop saw, for the side-by-side view. Behind the workload
// credential like everything else — a trail is not public just because it
// holds no complete token.
registerTrailRoute(app, (req, reply) => requireWorkload(cfg, req, reply));

app.get("/healthz", async () => ({ ok: true }));

await app.listen({ port: cfg.activityApiPort, host: "127.0.0.1" });
