// TxnDemo — Gate A, the narrowing gate at mint time.
//
// AM invokes one validate*Scope function per grant type and intersects the
// return with what was requested, so this can only narrow a request, never
// widen one (docs/api/22-token-exchange.md). Without it, the exchange issues
// whatever the caller CLIENT is allowed, regardless of who the subject is.
//
// `accessToken` is NOT bound at this stage (verified live, 2026-08-31 — it
// throws ReferenceError; the token being minted does not exist yet), so the
// subject has to come out of the subject_token itself. `identity` is bound
// here and resolves even when the subject_token is opaque, but
// policy.evaluate only accepts a real subject for JwtClaim matching via
// {jwt: <token>} — {claims: {...}} is documented anonymous
// (docs/api/21-am-policies.md) — so the subject tokens stay JWTs
// specifically so this script (and token-modification.js) can present them
// to the policy engine. This is the one place "opaque where we can" gives
// way: it is AM's own script doing the reading, not an external resource
// server, and every other token in this demo IS opaque (see README).
var ISSUANCE_POLICY_SET = "TxnDemoScopes";
var EXCHANGE = "urn:ietf:params:oauth:grant-type:token-exchange";

function toList(v) {
  var a = [];
  if (!v) { return a; }
  for (var i = 0; i < v.length; i++) { a.push(String(v[i])); }
  return a;
}

function firstParam(params, name) {
  var v = params[name];
  return (v && v.length) ? String(v[0]) : null;
}

// The internal scopes the policy engine says this subject token may be given.
function granted(subjectToken, requested) {
  var decisions = policy.evaluate({ jwt: subjectToken }, ISSUANCE_POLICY_SET, requested, {});
  var out = [];
  for (var i = 0; i < decisions.length; i++) {
    var d = decisions[i];
    if (d && d.actions && d.actions.GRANT === true) { out.push(String(d.resourceName)); }
  }
  return out;
}

function grantable(where) {
  var requested = toList(requestedScopes);
  var params = requestProperties.requestParams;
  if (firstParam(params, "grant_type") !== EXCHANGE) {
    return requested;
  }
  var out;
  try {
    out = granted(firstParam(params, "subject_token"), requested);
  } catch (e) {
    logger.error("TxnDemo/" + where + " policy evaluation failed: " + e);
    return []; // fail closed: no decision, no internal scope
  }
  logger.error("TxnDemo/" + where + " requested=[" + requested.join(",") +
    "] granted=[" + out.join(",") + "]");
  return out;
}

function validateAccessTokenScope() { return grantable("access_token"); }
function validateRefreshTokenScope() { return grantable("refresh_token"); }
function validateAuthorizationScope() { return grantable("authorization"); }
function validateBackChannelAuthorizationScope() { return grantable("ciba"); }
function validateDeviceCodeScope() { return grantable("device_code"); }
