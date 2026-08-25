// shop-web — the BFF. Holds the user's session and mints a capability token
// per action.
//
// It authenticates users as one OAuth2 client and calls the API as another.
// That is not tidiness: `may_act` on the identity token names the caller
// client, the mint-time gate is attached to it, and the capability token
// inherits its 60-second lifetime. One client could not do both.
import Fastify from "fastify";
import formbody from "@fastify/formbody";
import cookie from "@fastify/cookie";
import { randomUUID } from "node:crypto";
import { config, decodeJwt, exchange, login, register } from "@captoken/shared";
import { dashboard, loginPage, page, resultCard } from "./views.js";

const cfg = config();
const sessions = new Map(); // demo-scale: in memory, lost on restart
const SESSION_COOKIE = "captoken_sid";

const app = Fastify({ logger: { transport: { target: "pino-pretty" } } });
await app.register(formbody);
await app.register(cookie);

const sessionOf = (req) => sessions.get(req.cookies[SESSION_COOKIE]);

app.get("/", async (req, reply) => {
  const session = sessionOf(req);
  if (!session) return reply.type("text/html").send(loginPage(null, cfg.offeredRoles));
  return reply.type("text/html").send(
    dashboard({
      user: session.user,
      identityClaims: decodeJwt(session.identityToken),
      result: session.lastResult,
    }),
  );
});

app.post("/login", async (req, reply) => {
  const { username, password } = req.body;
  let tokens;
  try {
    tokens = await login(cfg, username, password);
  } catch (e) {
    return reply.type("text/html").send(loginPage(`Sign-in failed — ${e.message}`, cfg.offeredRoles));
  }
  const sid = randomUUID();
  sessions.set(sid, { user: username, identityToken: tokens.access_token, lastResult: null });
  reply.setCookie(SESSION_COOKIE, sid, { path: "/", httpOnly: true, sameSite: "lax" });
  return reply.redirect("/");
});

/**
 * Register, then sign in.
 *
 * The roles go to AM, not to IDM from here: the BFF holds no credential that
 * can write a user. The registration journey does the creating, which is also
 * where the choice is bounded to the demo's own capability roles.
 */
app.post("/register", async (req, reply) => {
  const { username, password } = req.body;
  // One checkbox arrives as a string, several as an array.
  const picked = [].concat(req.body.roles ?? []);
  try {
    await register(cfg, { email: username, password, roles: picked });
  } catch (e) {
    return reply
      .type("text/html")
      .send(loginPage(`Registration failed — ${e.message}`, cfg.offeredRoles));
  }
  const tokens = await login(cfg, username, password);
  const sid = randomUUID();
  sessions.set(sid, { user: username, identityToken: tokens.access_token, lastResult: null });
  reply.setCookie(SESSION_COOKIE, sid, { path: "/", httpOnly: true, sameSite: "lax" });
  return reply.redirect("/");
});

app.post("/logout", async (req, reply) => {
  sessions.delete(req.cookies[SESSION_COOKIE]);
  reply.clearCookie(SESSION_COOKIE, { path: "/" });
  return reply.redirect("/");
});

/**
 * One user action = one exchange + one API call.
 *
 * The exchange can come back with no capability — that is the mint-time gate
 * refusing, and it is a legitimate outcome to show, not an error to swallow.
 * When it does, the API is never called: there is nothing to call it with.
 */
app.post("/act", async (req, reply) => {
  const session = sessionOf(req);
  if (!session) return reply.redirect("/");
  const { action, capability } = req.body;

  const minted = await exchange(cfg, session.identityToken, capability);
  const capToken = minted.access_token;
  const capClaims = capToken ? decodeJwt(capToken) : null;
  const got = capClaims?.scope ?? [];

  if (!got.includes(capability)) {
    session.lastResult = resultCard({ capability, minted: false });
    return reply.redirect("/");
  }

  const path =
    action === "refund" ? "/payments/9/refund"
    : action === "approve" ? "/orders/123/approve"
    : "/orders/123";
  const res = await fetch(`${cfg.apiUrl}${path}`, {
    method: action === "read" ? "GET" : "POST",
    headers: { authorization: `Bearer ${capToken}` },
  });
  const body = await res.json().catch(() => ({}));

  session.lastResult = resultCard({
    capability,
    minted: true,
    capClaims,
    response: body,
    status: res.status,
  });
  return reply.redirect("/");
});

app.setErrorHandler((error, req, reply) => {
  req.log.error(error);
  reply.code(500).type("text/html").send(page("Error", `<div class="warn">${error.message}</div>`));
});

await app.listen({ port: cfg.webPort, host: "127.0.0.1" });
