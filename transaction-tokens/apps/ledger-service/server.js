// ledger-service — the last hop. Validates the same Txn-Token independently,
// with no callback to AIC and no trust in whoever forwarded it, and writes
// the entry from tctx alone. If the request body disagrees with tctx, the
// body loses — that's the whole reason cost lives in the token, not the POST.
import Fastify from "fastify";
import { config, txnTokenVerifier } from "@txndemo/shared";
import { record, all } from "./store.js";

const cfg = config();
const verifyTxnToken = await txnTokenVerifier(cfg);

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
  const payload = await requireTxnToken(req, reply);
  if (!payload) return;
  const inserted = record(payload);
  return {
    entry: {
      txn: payload.txn,
      sub: payload.sub,
      tctx: payload.tctx,
    },
    replay: !inserted,
  };
});

app.get("/entries", async () => ({ entries: all() }));

app.get("/healthz", async () => ({ ok: true }));

await app.listen({ port: cfg.ledgerPort, host: "127.0.0.1" });
