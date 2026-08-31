// activity-api — the middle hop. Validates the Txn-Token independently (no
// callback to AIC), then forwards the same bytes to ledger-service in the
// same Txn-Token header. Bold edge in ARCHITECTURE.md's diagram: this is
// what "no mid-chain re-issuance" means in practice — the token this
// service saw is byte-for-byte what the ledger sees.
import Fastify from "fastify";
import { config, txnTokenVerifier } from "@txndemo/shared";

const cfg = config();
const verifyTxnToken = await txnTokenVerifier(cfg);

const app = Fastify({ logger: { transport: { target: "pino-pretty" } } });

app.post("/activities", async (req, reply) => {
  const header = req.headers["txn-token"];
  if (!header) return reply.code(401).send({ error: "no Txn-Token header presented" });

  let payload;
  try {
    payload = await verifyTxnToken(header);
  } catch (e) {
    return reply.code(401).send({ error: `Txn-Token rejected: ${e.message}` });
  }

  const res = await fetch(`${cfg.ledgerUrl}/entries`, {
    method: "POST",
    headers: { "txn-token": header },
  });
  const ledger = await res.json().catch(() => ({}));
  if (!res.ok) return reply.code(res.status).send({ error: "ledger rejected the entry", ledger });

  return { accepted: true, tctx: payload.tctx, ledger };
});

app.get("/healthz", async () => ({ ok: true }));

await app.listen({ port: cfg.activityApiPort, host: "127.0.0.1" });
