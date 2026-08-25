// shop-api — the resource server, and the whole point of the demo.
//
// It hardcodes no authorization rule. For every request it verifies the
// presented capability token and then asks AM's policy engine whether that
// token may take this action on this resource. Change a policy in AM and the
// answer changes here with no deploy.
//
// Every response carries the decision trail — the token's claims, the exact
// question put to the PDP, and its exact answer — because a demo of an
// authorization decision that does not show the decision is a demo of nothing.
import Fastify from "fastify";
import { config, evaluate, pdpCredential, tokenVerifier } from "@captoken/shared";

const cfg = config();
const credential = pdpCredential();
const verify = await tokenVerifier(cfg);

const app = Fastify({ logger: { transport: { target: "pino-pretty" } } });

/** The AM resource name for one of our REST paths. */
const resourceName = (path) => `${cfg.apiAudience}${path}`;

/**
 * The PEP. Verify the token locally first — AM's policy endpoint checks
 * neither signature nor expiry, so anything not established here is not
 * established at all — then ask for a decision on one action.
 */
async function permit(req, reply, { path, action }) {
  const header = req.headers.authorization ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) {
    reply.code(401).send({ error: "no capability token presented" });
    return null;
  }

  let claims;
  try {
    claims = await verify(token);
  } catch (e) {
    // Expired, forged, wrong issuer, wrong audience. The PDP would have
    // answered anyway; that is exactly why this check is here.
    reply.code(401).send({ error: `token rejected: ${e.message}` });
    return null;
  }

  const resource = resourceName(path);
  const question = { resource, action, subject: claims.sub, application: cfg.policySet };
  const decisions = await evaluate(cfg, credential, {
    subjectToken: token,
    resources: [resource],
  });
  const actions = decisions[0]?.actions ?? {};
  const trail = {
    token: { sub: claims.sub, scope: claims.scope, demoRoles: claims.demoRoles, exp: claims.exp },
    question,
    answer: { actions, advices: decisions[0]?.advices ?? {} },
  };

  if (actions[action] !== true) {
    reply.code(403).send({ error: `policy denied ${action} on ${resource}`, trail });
    return null;
  }
  return trail;
}

const ORDERS = {
  "123": { id: "123", customer: "Marchetti Group", total: "4,180.00", status: "awaiting approval" },
  "124": { id: "124", customer: "Okonkwo Ltd", total: "915.50", status: "approved" },
};
const PAYMENTS = { "9": { id: "9", order: "124", amount: "915.50", refunded: false } };

app.get("/orders/:id", async (req, reply) => {
  const trail = await permit(req, reply, { path: `/orders/${req.params.id}`, action: "read" });
  if (!trail) return;
  const order = ORDERS[req.params.id];
  if (!order) return reply.code(404).send({ error: "no such order", trail });
  return { order, trail };
});

app.post("/orders/:id/approve", async (req, reply) => {
  const trail = await permit(req, reply, { path: `/orders/${req.params.id}`, action: "approve" });
  if (!trail) return;
  const order = ORDERS[req.params.id];
  if (!order) return reply.code(404).send({ error: "no such order", trail });
  order.status = "approved";
  return { order, trail };
});

app.post("/payments/:id/refund", async (req, reply) => {
  const trail = await permit(req, reply, { path: `/payments/${req.params.id}`, action: "refund" });
  if (!trail) return;
  const payment = PAYMENTS[req.params.id];
  if (!payment) return reply.code(404).send({ error: "no such payment", trail });
  payment.refunded = true;
  return { payment, trail };
});

app.get("/healthz", async () => ({ ok: true, policySet: cfg.policySet }));

await app.listen({ port: cfg.apiPort, host: "127.0.0.1" });
