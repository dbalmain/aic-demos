// portal-bff — the only service that ever holds the account manager's own
// identity token, and the only one the browser ever talks to. The browser's
// own credential is an opaque session cookie; the identity token and every
// Txn-Token this mints stay server-side.
import Fastify from "fastify";
import formbody from "@fastify/formbody";
import cookie from "@fastify/cookie";
import { randomUUID } from "node:crypto";
import { config, exchange, login, userinfo, workloadHeaders } from "@txndemo/shared";
import { dashboard, loginPage } from "./views.js";

const cfg = config();
const sessions = new Map(); // demo-scale: in memory, lost on restart
const SESSION_COOKIE = "txndemo_sid";

const app = Fastify({ logger: { transport: { target: "pino-pretty" } } });
await app.register(formbody);
await app.register(cookie);

const sessionOf = (req) => sessions.get(req.cookies[SESSION_COOKIE]);

app.get("/", async (req, reply) => {
  const session = sessionOf(req);
  if (!session) return reply.type("text/html").send(loginPage(null));
  return reply.type("text/html").send(
    dashboard({ user: session.user, result: session.lastResult, error: session.lastError }),
  );
});

app.post("/login", async (req, reply) => {
  const { username, password } = req.body;
  let tokens;
  try {
    tokens = await login(cfg, username, password);
  } catch (e) {
    return reply.type("text/html").send(loginPage(`Sign-in failed — ${e.message}`));
  }
  // Displayed via userinfo, not by decoding the identity token — the
  // idiomatic move for any bearer, opaque or not (see shared/aic.js).
  const who = await userinfo(cfg, tokens.access_token).catch(() => ({ sub: username }));
  const sid = randomUUID();
  sessions.set(sid, { user: who.sub ?? username, identityToken: tokens.access_token, lastResult: null });
  reply.setCookie(SESSION_COOKIE, sid, { path: "/", httpOnly: true, sameSite: "lax" });
  return reply.redirect("/");
});

app.get("/logout", async (req, reply) => {
  const sid = req.cookies[SESSION_COOKIE];
  if (sid) sessions.delete(sid);
  reply.clearCookie(SESSION_COOKIE, { path: "/" });
  return reply.redirect("/");
});

app.post("/activities", async (req, reply) => {
  const session = sessionOf(req);
  if (!session) return reply.redirect("/");

  const { client_ref, activity_type, delivered_on, cost_cents, note } = req.body;
  const requestDetails = { client_ref, activity_type, delivered_on };
  if (cost_cents) requestDetails.cost_cents = Number(cost_cents);
  const requestContext = { ip: req.ip, authn: "pwd", portal: "acme-portal" };

  let result;
  try {
    const txn = await exchange(cfg, session.identityToken, { requestDetails, requestContext });
    const res = await fetch(`${cfg.activityApiUrl}/activities`, {
      method: "POST",
      headers: { ...workloadHeaders(cfg), "txn-token": txn.access_token, "content-type": "application/json" },
      body: JSON.stringify({ note }), // the free-text note; never read by downstream tctx checks
    });
    result = await res.json();
    if (!res.ok) {
      session.lastError = `activity-api refused it: ${result.error ?? res.status}`;
      session.lastResult = null;
    } else {
      session.lastError = null;
      session.lastResult = result;
    }
  } catch (e) {
    session.lastError = `exchange failed: ${e.message}`;
    session.lastResult = null;
  }
  return reply.redirect("/");
});

app.get("/healthz", async () => ({ ok: true }));

await app.listen({ port: cfg.portalPort, host: "127.0.0.1" });
