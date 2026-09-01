// portal-bff — the only service that ever holds the account manager's own
// identity token, and the only one the browser ever talks to. The browser's
// own credential is an opaque session cookie; the identity token and every
// Txn-Token this mints stay server-side.
import Fastify from "fastify";
import formbody from "@fastify/formbody";
import cookie from "@fastify/cookie";
import { randomUUID } from "node:crypto";
import {
  config,
  exchange,
  login,
  userinfo,
  workloadHeaders,
  note as noteHop,
  trailFor,
  tokenHash,
} from "@txndemo/shared";
import { decodeJwt } from "jose";
import { dashboard, loginPage, trailPage } from "./views.js";

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
  if (cost_cents !== undefined && cost_cents !== "") {
    // Convert ONLY a canonical decimal integer, and pass anything else on
    // untouched for AIC to reject.
    //
    // Two ways this went wrong, both of them this hop quietly changing what
    // the caller said. `Number("garbage")` is NaN and `Number("1e309")` is
    // Infinity; JSON.stringify writes both as `null`, which the mint reads as
    // "no cost asked for" — so malformed input came back looking exactly like
    // a policy refusal. And `Number("0x10")` is 16: AIC then signs a
    // perfectly valid sixteen-cent cost that nobody asked for. Deciding a
    // value is malformed is AIC's job; re-interpreting it before AIC sees it
    // takes that decision away.
    const raw = String(cost_cents).trim();
    requestDetails.cost_cents = /^-?[0-9]+$/.test(raw) ? Number(raw) : raw;
  }
  const requestContext = { ip: req.ip, authn: "pwd", portal: "acme-portal" };

  let result;
  try {
    const txn = await exchange(cfg, session.identityToken, { requestDetails, requestContext });

    // This hop's own trail entry. The portal is the only service that sees
    // what was ASKED for as well as what came back, so it is the only one
    // that can show a narrowing — a cost requested and not granted.
    const minted = decodeJwt(txn.access_token);
    noteHop({
      hop: "portal-bff",
      token: txn.access_token,
      payload: minted,
      workload: `${session.user} (signed in, identity token held here and nowhere else)`,
      validated: [
        "the account manager's own sign-in, via AIC",
        "AIC minted this Txn-Token; it was not built here",
      ],
      decided:
        requestDetails.cost_cents != null && minted.tctx?.cost_cents == null
          ? `asked for cost ${requestDetails.cost_cents}c; the issuance policy did not grant it`
          : "send the Txn-Token to activity-api",
    });
    session.lastTxn = minted.txn;

    const res = await fetch(`${cfg.activityApiUrl}/activities`, {
      method: "POST",
      headers: { ...workloadHeaders(cfg, "portal-bff"), "txn-token": txn.access_token, "content-type": "application/json" },
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

// The side-by-side view docs/brief.md asks for: this hop's record, plus
// each downstream hop's own, fetched from the service that made it rather
// than reconstructed here. Same token_hash down the column is the proof the
// token traversed the chain unchanged; no hop ever hands over the token
// itself.
app.get("/trail/:txn", async (req, reply) => {
  const session = sessionOf(req);
  if (!session) return reply.code(401).send({ error: "not signed in" });
  const { txn } = req.params;

  // An unreachable service, a non-200, unparseable JSON and a genuinely
  // empty trail are four different things, and collapsing them into "no
  // entries" turned the headline evidence into a lie: stop the two
  // downstream services and the surviving portal record is the only hash, so
  // the page said "every hop saw the same token hash" having observed one.
  // Each hop is now reported with its own status, and the green verdict
  // requires the COMPLETE expected set.
  const remote = async (name, base) => {
    let res;
    try {
      res = await fetch(`${base}/trail/${encodeURIComponent(txn)}`, {
        headers: workloadHeaders(cfg, "portal-bff"),
      });
    } catch (e) {
      return { name, status: "unreachable", detail: e.message, hops: [] };
    }
    if (!res.ok) return { name, status: "error", detail: `HTTP ${res.status}`, hops: [] };
    let body;
    try {
      body = await res.json();
    } catch (e) {
      return { name, status: "error", detail: `unreadable trail: ${e.message}`, hops: [] };
    }
    const hops = Array.isArray(body.hops) ? body.hops : [];
    return { name, status: hops.length ? "ok" : "no-record", hops };
  };

  const [downstream, ledger] = await Promise.all([
    remote("activity-api", cfg.activityApiUrl),
    remote("ledger-service", cfg.ledgerUrl),
  ]);
  const own = trailFor(txn);
  const sources = [
    { name: "portal-bff", status: own.length ? "ok" : "no-record", hops: own },
    downstream,
    ledger,
  ];

  const hops = sources.flatMap((s) => s.hops);
  const complete = sources.every((s) => s.status === "ok");
  const view = {
    txn,
    sources: sources.map(({ name, status, detail }) => ({ name, status, detail })),
    // Only a complete set of hops, all agreeing, is evidence. Anything else
    // is "we could not check", which the page now says instead.
    unchanged: complete && new Set(hops.map((h) => h.token_hash)).size === 1,
    complete,
    hops,
  };
  if (req.headers.accept?.includes("application/json")) return view;
  return reply.type("text/html").send(trailPage(view));
});

app.get("/healthz", async () => ({ ok: true }));

await app.listen({ port: cfg.portalPort, host: "127.0.0.1" });
