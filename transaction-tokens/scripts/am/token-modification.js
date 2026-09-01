// TxnDemo — mints tctx/rctx on the Txn-Token, enriches the manager<->client
// relationship in-process via the openidm binding (no outbound call, no
// tunnel — ARCHITECTURE.md), and gates cost_cents on the issuance policy
// (Gate B, brief section 8).
//
// `accessToken` IS bound here (unlike validate-scope.js, which runs before
// the token exists) so getResourceOwnerId/getClientId reflect the resolved
// subject regardless of whether the subject token was opaque or a JWT. The
// subject token itself is only parsed as a JWT for the one thing that needs
// it: presenting it to policy.evaluate as {jwt: ...} for a JwtClaim match
// (see validate-scope.js's header for why that specific call needs a real
// JWT). Everything else here reads accessToken/IDM, not the raw token.
//
// TWO KINDS OF tctx FIELD, and the difference is the whole security value:
//
//   * VOUCHED — client_ref/client_display/client_tier come from IDM via the
//     subject's own relationship, and cost_cents is gated on a policy. A
//     downstream service may treat these as AIC's assertion.
//   * BOUND, NOT VOUCHED — activity_type/delivered_on and everything in rctx
//     are the caller's own words. AIC validates their SHAPE (below) and then
//     binds them to this one transaction under its signature, so they cannot
//     be altered in flight; it does not claim they are true. README says so
//     in the same words.
//
// Shape validation is a REJECTION, not a narrowing: a caller that sends
// {"admin":true} for activity_type, "not-a-date", or a negative cost has a
// bug, and signing it would launder that bug into something that looks
// vouched-for (verified 2026-09-01: before this check AM happily signed
// activity_type "[object Object]" and cost_cents -1). Narrowing is reserved
// for the one case that is a real authorization answer: the issuance policy
// refusing a cost.
//
// setField coerces a bare integer to a double (45000 -> 45000.0). Boxing
// with java.lang.Integer.valueOf only survives INSIDE a nested object, not
// at top level (docs/api/12-script-bindings-matrix.md) — cost_cents lives in
// tctx, so it is fine either way, but the boxing is kept for clarity.
var ISSUANCE_POLICY_SET = "TxnDemoIssuance";

var ACTIVITY_TYPE_RE = /^[a-z][a-z0-9_-]{0,31}$/;
var DELIVERED_ON_RE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
var CLIENT_REF_RE = /^[A-Za-z0-9._-]{1,64}$/;
var COST_CENTS_MAX = 100000000; // $1M, a demo bound: absurd values are bugs
var RCTX_MAX_LEN = 256;

function reject(why) {
  // Throwing here fails the mint. The caller gets an error instead of a
  // signed token carrying nonsense (verified 2026-09-01).
  logger.error("TxnDemo/tokenmod rejecting exchange: " + why);
  throw new Error("invalid request_details: " + why);
}

function firstParam(params, name) {
  var v = params[name];
  return (v && v.length) ? String(v[0]) : null;
}

function parseJson(raw, what) {
  if (!raw) { return {}; }
  try {
    var v = JSON.parse(raw);
    if (v === null || typeof v !== "object" || v instanceof Array) {
      reject(what + " must be a JSON object");
    }
    return v;
  } catch (e) {
    if (e && e.message && e.message.indexOf("invalid request_details") === 0) { throw e; }
    reject(what + " is not valid JSON");
  }
}

// A caller-supplied string, checked against a pattern before it is bound.
function checkedString(v, name, re) {
  if (typeof v !== "string") { reject(name + " must be a string"); }
  if (!re.test(v)) { reject(name + " is malformed"); }
  return v;
}

function checkedCost(v) {
  if (typeof v !== "number" || v !== Math.floor(v) || isNaN(v)) {
    reject("cost_cents must be a whole number");
  }
  if (v < 0 || v > COST_CENTS_MAX) { reject("cost_cents out of range"); }
  return v;
}

// Does the subject token's own scope earn the right to assert a cost? Only a
// real account manager's identity token carries the human scope; the nightly
// job's own service token never does (terraform/policy.tf). This is the ONE
// gate whose answer narrows rather than rejects — a refusal is a legitimate
// policy answer, not a malformed request.
function mayAssertCost(subjectToken) {
  if (!subjectToken) { return false; }
  try {
    var decisions = policy.evaluate({ jwt: subjectToken }, ISSUANCE_POLICY_SET, ["tctx/cost_cents"], {});
    for (var i = 0; i < decisions.length; i++) {
      var d = decisions[i];
      if (d && d.actions && d.actions.assert === true) { return true; }
    }
    return false;
  } catch (e) {
    logger.error("TxnDemo/tokenmod issuance policy evaluation failed: " + e);
    return false; // fail closed
  }
}

// Resolves the named client against the subject's OWN relationship, so a
// caller can only ever name a client the subject actually manages. A named
// ref that does not resolve is rejected, never dropped: dropping it used to
// mint a cost-bearing token with no client attached at all (verified
// 2026-09-01 — a bogus client_ref plus cost_cents produced exactly that,
// and the ledger wrote a costed row with a NULL client).
function resolveClient(clients, wantedRef) {
  var list = clients || [];
  if (wantedRef) {
    for (var i = 0; i < list.length; i++) {
      if (String(list[i]._refResourceId) === wantedRef) { return list[i]; }
    }
    reject("client_ref " + wantedRef + " is not a client this subject manages");
  }
  // Unnamed: the subject's only client, if they have exactly one. Several,
  // or none, means there is nothing unambiguous to attach.
  return list.length === 1 ? list[0] : null;
}

(function () {
  var sub = String(accessToken.getResourceOwnerId());
  var actingClientId = String(accessToken.getClientId());
  var params = requestProperties.requestParams;
  var details = parseJson(firstParam(params, "request_details"), "request_details");
  var context = parseJson(firstParam(params, "request_context"), "request_context");
  var subjectToken = firstParam(params, "subject_token");

  var user = null;
  try {
    user = openidm.read("managed/bravo_user/" + sub, null, ["userName", "custom_txnClients/*"]);
  } catch (e) {
    // An IDM failure must not silently downgrade to "this subject manages
    // nobody" — that is the fail-open shape this script had before.
    logger.error("TxnDemo/tokenmod IDM read failed for " + sub + ": " + e);
    throw new Error("could not resolve the subject's identity");
  }

  accessToken.setField("aud", "acme-internal");
  accessToken.setField("txn", String(accessToken.getAuditTrackingId()));
  accessToken.setField("sub", (user && user.userName) ? String(user.userName) : sub);
  accessToken.setField("req_wl", actingClientId);

  var tctx = {};
  if (details.activity_type !== undefined && details.activity_type !== null) {
    tctx.activity_type = checkedString(details.activity_type, "activity_type", ACTIVITY_TYPE_RE);
  }
  if (details.delivered_on !== undefined && details.delivered_on !== null) {
    tctx.delivered_on = checkedString(details.delivered_on, "delivered_on", DELIVERED_ON_RE);
  }

  var wantedRef = null;
  if (details.client_ref !== undefined && details.client_ref !== null) {
    wantedRef = checkedString(details.client_ref, "client_ref", CLIENT_REF_RE);
  }
  var client = resolveClient(user ? user.custom_txnClients : null, wantedRef);
  if (client) {
    tctx.client_ref = String(client._refResourceId);
    tctx.client_display = String(client.displayName || "");
    tctx.client_tier = String(client.tier || ""); // enriched from IDM, not requested
  }

  if (details.cost_cents !== undefined && details.cost_cents !== null) {
    var cost = checkedCost(details.cost_cents);
    if (mayAssertCost(subjectToken)) {
      tctx.cost_cents = java.lang.Integer.valueOf(cost);
    } else {
      logger.error("TxnDemo/tokenmod cost_cents requested but refused by issuance policy: client=" +
        actingClientId + " sub=" + sub);
      // Narrow, don't fail the exchange: the caller still gets a Txn-Token,
      // just one that cannot carry a cost. The refusal is the demonstration.
    }
  }
  accessToken.setField("tctx", tctx);

  var rctx = {};
  var rctxKeys = ["ip", "authn", "portal"];
  for (var k = 0; k < rctxKeys.length; k++) {
    var key = rctxKeys[k];
    var v = context[key];
    if (v === undefined || v === null) { continue; }
    if (typeof v !== "string") { reject("request_context." + key + " must be a string"); }
    if (v.length > RCTX_MAX_LEN) { reject("request_context." + key + " is too long"); }
    rctx[key] = v;
  }
  accessToken.setField("rctx", rctx);

  logger.error("TxnDemo/tokenmod sub=" + sub + " client=" + actingClientId +
    " tctx=" + JSON.stringify(tctx));
})();
