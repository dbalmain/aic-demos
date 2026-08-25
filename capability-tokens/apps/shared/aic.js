// The AIC calls the demo makes, in one place: log a user in, exchange their
// identity token for a capability, verify a presented token, and ask the
// policy engine for a decision.
import { createRemoteJWKSet, jwtVerify, decodeJwt } from "jose";

const form = (o) => new URLSearchParams(o).toString();
const basic = (id, secret) =>
  "Basic " + Buffer.from(`${id}:${secret}`).toString("base64");

async function postForm(url, auth, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { authorization: auth, "content-type": "application/x-www-form-urlencoded" },
    body: form(body),
  });
  const json = await res.json().catch(() => ({}));
  if (json.error) throw new Error(`${json.error}: ${json.error_description ?? ""}`);
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
 * Log a user in and get their identity token.
 *
 * The password grant, because a scriptable demo beats a browser redirect here.
 * A real BFF uses authorization_code; nothing else in the pattern changes.
 * The login client is allowed `openid`/`profile` only, so this cannot come
 * back holding a capability.
 */
export function login(cfg, username, password) {
  return postForm(cfg.tokenUrl, basic(cfg.login.id, cfg.login.secret), {
    grant_type: "password",
    username,
    password,
    scope: "openid",
  });
}

/**
 * Trade the identity token for one capability (RFC 8693).
 *
 * Authenticates as the *caller* client, not the login client: `may_act` on the
 * identity token names it, gate A is attached to it, and the capability token
 * inherits its short lifetime. Returns `{}` scope when the policy engine says
 * this user may not hold the capability — that is a refusal, not an error.
 */
export function exchange(cfg, identityToken, capability) {
  return postForm(cfg.tokenUrl, basic(cfg.caller.id, cfg.caller.secret), {
    grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
    subject_token: identityToken,
    subject_token_type: "urn:ietf:params:oauth:token-type:access_token",
    requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
    scope: capability,
  });
}

/**
 * A verifier for tokens this realm issued.
 *
 * This is not optional ceremony. AM's policy endpoint does **not** check the
 * signature or the expiry of a `subject.jwt` — a token with rewritten claims
 * and an expired one both get real decisions back (verified 2026-08-25, see
 * docs/api/21-am-policies.md). Everything the resource server believes about a
 * presented token, it has to establish here first.
 */
export async function tokenVerifier(cfg) {
  const { issuer, jwksUri } = await discover(cfg);
  const jwks = createRemoteJWKSet(new URL(jwksUri));
  return async function verify(token) {
    const { payload } = await jwtVerify(token, jwks, {
      issuer,
      // AM sets `aud` to the client that minted the token.
      audience: cfg.caller.id,
    });
    return payload;
  };
}

/**
 * Ask the policy engine what a subject may do. Returns AM's raw answer.
 *
 * `credential` is the resource server's own, not the user's. A 401 means our
 * bearer expired, not that the subject was refused — so drop it and try once
 * more rather than reporting a policy denial that never happened.
 */
export async function evaluate(cfg, credential, { subjectToken, resources }) {
  const body = JSON.stringify({
    resources,
    application: cfg.policySet,
    subject: { jwt: subjectToken },
  });
  const call = async () =>
    fetch(cfg.policyUrl, {
      method: "POST",
      headers: {
        authorization: `Bearer ${await credential.get()}`,
        "content-type": "application/json",
        accept: "application/json",
        "accept-api-version": "protocol=1.0,resource=2.0",
      },
      body,
    });

  let res = await call();
  if (res.status === 401) {
    credential.invalidate();
    res = await call();
  }
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`policy evaluate ${res.status}: ${JSON.stringify(json)}`);
  return json;
}

export { decodeJwt };
