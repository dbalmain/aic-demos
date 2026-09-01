// The AIC calls the demo makes: log the account manager in, sign the nightly
// job's own jwt-bearer assertion, exchange either identity for a Txn-Token,
// verify a presented Txn-Token, and read a user's own identity via userinfo
// rather than decoding a token client-side — the idiomatic move regardless
// of token format, and the one place "opaque where we can" reaches the app
// layer even though the identity tokens themselves stay JWTs (see
// scripts/am/validate-scope.js for why AM's own scripts need that).
import { createRemoteJWKSet, jwtVerify, importJWK, SignJWT } from "jose";
import { randomUUID } from "node:crypto";

const form = (o) => new URLSearchParams(o).toString();
const basic = (id, secret) => "Basic " + Buffer.from(`${id}:${secret}`).toString("base64");

const b64uToBig = (s) => BigInt("0x" + Buffer.from(s, "base64url").toString("hex"));
const bigToB64u = (n) => {
  let hex = n.toString(16);
  if (hex.length % 2) hex = "0" + hex;
  return Buffer.from(hex, "hex").toString("base64url");
};
function modinv(a, m) {
  let [oldR, r] = [a, m];
  let [oldS, s] = [1n, 0n];
  while (r !== 0n) {
    const q = oldR / r;
    [oldR, r] = [r, oldR - q * r];
    [oldS, s] = [s, oldS - q * s];
  }
  return ((oldS % m) + m) % m;
}

/**
 * `aic jwt-bearer key export` writes p/q but not the CRT params (dp/dq/qi) —
 * fine for AM's own use, but Node's RSA JWK importer rejects a private key
 * that has p/q without them (verified 2026-08-31: "Invalid JWK RSA key" with
 * no further detail). Derived here rather than requesting a format change
 * from the export command, since any RSA JWK missing them needs the same fix.
 */
function completeRsaJwk({ aic_created, aic_host, aic_owner, ...jwk }) {
  if (jwk.dp && jwk.dq && jwk.qi) return jwk;
  const d = b64uToBig(jwk.d), p = b64uToBig(jwk.p), q = b64uToBig(jwk.q);
  return {
    ...jwk,
    dp: bigToB64u(d % (p - 1n)),
    dq: bigToB64u(d % (q - 1n)),
    qi: bigToB64u(modinv(q, p)),
  };
}

async function postForm(url, auth, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { authorization: auth, "content-type": "application/x-www-form-urlencoded" },
    body: form(body),
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    // A gateway 502 or an HTML error page is not an OAuth error response.
    // Surfacing the status beats failing three lines later on a missing
    // access_token, which is what swallowing this used to look like.
    throw new Error(`${url} -> HTTP ${res.status}: ${text.slice(0, 200)}`);
  }
  if (json.error) throw new Error(`${json.error}: ${json.error_description ?? ""}`);
  if (!res.ok) throw new Error(`${url} -> HTTP ${res.status}`);
  return json;
}

/** The realm's `issuer` and JWKS URL, read from discovery rather than built. */
export async function discover(cfg) {
  const res = await fetch(cfg.discoveryUrl);
  if (!res.ok) throw new Error(`discovery failed: ${res.status}`);
  const doc = await res.json();
  return { issuer: doc.issuer, jwksUri: doc.jwks_uri };
}

/**
 * Log the account manager in. Password grant, because a scriptable demo
 * beats a browser redirect; a real BFF uses authorization_code and nothing
 * else in the pattern moves. The web client is allowed openid/profile/
 * portal.activities only, so this cannot come back holding client:activity:*.
 */
export function login(cfg, username, password) {
  return postForm(cfg.tokenUrl, basic(cfg.web.id, cfg.web.secret), {
    grant_type: "password",
    username,
    password,
    scope: `openid ${cfg.portalScope}`,
  });
}

/**
 * The nightly job's own sign-in: build and sign its jwt-bearer assertion,
 * then exchange it for a service-scoped access token. `aud` is the realm's
 * own discovery issuer — the audience must include the `:443` AM's issuer
 * carries, so build it from discovery rather than from TXNDEMO_TENANT_URL
 * (docs/api/17-jwt-bearer-user-tokens.md, in pingone-aic-manager).
 */
export async function loginAsJob(cfg, jwk, subjectId) {
  const { issuer } = await discover(cfg);
  const key = await importJWK(completeRsaJwk(jwk), "RS256");
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new SignJWT({ sub: subjectId })
    .setProtectedHeader({ alg: "RS256", typ: "JWT", kid: jwk.kid })
    .setIssuer("aic-agent")
    .setAudience(issuer)
    .setIssuedAt(now)
    .setExpirationTime(now + 120)
    .setJti(randomUUID())
    .sign(key);

  return postForm(cfg.tokenUrl, basic(cfg.jobsvc.id, cfg.jobsvc.secret), {
    grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion,
    scope: "job.accrual",
  });
}

/**
 * Trade an identity token for a Txn-Token (RFC 8693 + the draft's extra
 * request_details/request_context parameters — AM accepts both as plain
 * extra POST params, docs/api/22-token-exchange.md). Authenticates as the
 * one shared internal exchange client: `may_act` on the identity token names
 * it, both gate scripts are attached to it, and the Txn-Token inherits its
 * 60-second lifetime.
 */
export function exchange(cfg, subjectToken, { requestDetails, requestContext }) {
  return postForm(cfg.tokenUrl, basic(cfg.caller.id, cfg.caller.secret), {
    grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
    subject_token: subjectToken,
    subject_token_type: "urn:ietf:params:oauth:token-type:access_token",
    // The draft requires both of these on the request, so they are sent
    // rather than omitted. This does NOT make the request conformant: the
    // draft's value for requested_token_type is the txn_token URN, which AM
    // rejects outright, so what goes on the wire is the access-token URN as
    // a substitute and AM answers in kind. `audience` AM ignores entirely —
    // the trust domain is set by the modification script, not negotiated.
    // Both are ACCEPTED (verified 2026-09-01), which is compatibility, not
    // conformance. Still departures; see ARCHITECTURE.md.
    audience: cfg.trustDomain,
    requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
    scope: cfg.exchangeScope,
    request_details: JSON.stringify(requestDetails ?? {}),
    request_context: JSON.stringify(requestContext ?? {}),
  });
}

/**
 * A verifier for Txn-Tokens. Every hop calls this independently: no
 * introspection, no per-token callback to AIC, and no trust in whichever
 * service handed the token over. It is not fully offline: `jose` fetches
 * AIC's JWKS on the first verification and caches it, and reloads both on an
 * unseen `kid` AND once its cache passes jose's default max age (10 minutes),
 * so a verification after a quiet spell reaches AIC even for a key it already
 * knows. The honest claim is "no per-token callback and no issuer decision",
 * which is what the pattern actually needs. README says it in those words.
 *
 * `aud` is the trust domain the mint script set, not any one client's id.
 *
 * Everything below the signature check is the token CONTRACT: a correctly
 * signed JWT from the same issuer and audience is not automatically a
 * Txn-Token. AIC currently always sends these claims, so this guards against
 * token confusion (some other token of ours, same issuer and audience) and
 * against a future config change quietly dropping one — not against a
 * demonstrated forgery.
 *
 * @param {string[]} requiredScopes operation scopes the caller must hold.
 *   Gate A can narrow a Txn-Token all the way to an EMPTY scope while still
 *   minting valid transaction claims (docs/api/22-token-exchange.md), so a
 *   service that never looks at `scope` treats a fully-narrowed token as a
 *   fully-authorized one. Checking it here is what makes Gate A load-bearing.
 */
export async function txnTokenVerifier(cfg, requiredScopes = []) {
  const { issuer, jwksUri } = await discover(cfg);
  const jwks = createRemoteJWKSet(new URL(jwksUri));
  return async function verify(token) {
    const { payload } = await jwtVerify(token, jwks, {
      issuer,
      audience: cfg.trustDomain,
      algorithms: ["RS256"],
      requiredClaims: ["exp", "iat", "sub", "txn", "req_wl", "tctx"],
      // Without this, `iat` may sit arbitrarily far in the future and the
      // 60-second lifetime means nothing.
      maxTokenAge: "120s",
    });
    // `requiredClaims` proves a KEY EXISTS and nothing more: `sub: null`,
    // `txn: null` and `tctx: []` all satisfy it. That is the same
    // passes-for-an-unrelated-reason shape this verifier was hardened
    // against in the first place, so check the values.
    for (const claim of ["sub", "txn", "req_wl"]) {
      if (typeof payload[claim] !== "string" || payload[claim] === "") {
        throw new Error(`${claim} is not a non-empty string`);
      }
    }
    if (
      typeof payload.tctx !== "object" ||
      payload.tctx === null ||
      Array.isArray(payload.tctx)
    ) {
      throw new Error("tctx is not an object");
    }
    const held = Array.isArray(payload.scope)
      ? payload.scope
      : String(payload.scope ?? "").split(" ").filter(Boolean);
    const missing = requiredScopes.filter((s) => !held.includes(s));
    if (missing.length) {
      throw new Error(`scope ${missing.join(",")} not present (holds: ${held.join(",") || "none"})`);
    }
    return payload;
  };
}

/** Who the presented (possibly opaque) token belongs to, via OIDC userinfo. */
export async function userinfo(cfg, accessToken) {
  const res = await fetch(cfg.userinfoUrl, {
    headers: { authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) throw new Error(`userinfo ${res.status}`);
  return res.json();
}
