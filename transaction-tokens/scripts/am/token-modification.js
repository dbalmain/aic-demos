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
// setField coerces a bare integer to a double (45000 -> 45000.0). Boxing
// with java.lang.Integer.valueOf only survives INSIDE a nested object, not
// at top level (docs/api/12-script-bindings-matrix.md) — cost_cents lives in
// tctx, so it is fine either way, but the boxing is kept for clarity.
var ISSUANCE_POLICY_SET = "TxnDemoIssuance";

function firstParam(params, name) {
  var v = params[name];
  return (v && v.length) ? String(v[0]) : null;
}

function parseJson(raw) {
  if (!raw) { return {}; }
  try {
    return JSON.parse(raw);
  } catch (e) {
    logger.error("TxnDemo/tokenmod could not parse JSON param: " + e);
    return {};
  }
}

// Does the subject token's own scope earn the right to assert a cost? Only a
// real account manager's identity token carries HUMAN_SCOPE; the nightly
// job's own service token never does (terraform/variables.tf).
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

// Picks the account manager's client the request named, or their only one.
// Returns null rather than guessing across several — an ambiguous request
// should surface as "no client_ref resolved", not a silent wrong pick.
function pickClient(clients, wantedRef) {
  if (!clients || !clients.length) { return null; }
  if (wantedRef) {
    for (var i = 0; i < clients.length; i++) {
      if (String(clients[i]._refResourceId) === String(wantedRef)) { return clients[i]; }
    }
    return null;
  }
  return clients.length === 1 ? clients[0] : null;
}

(function () {
  var sub = String(accessToken.getResourceOwnerId());
  var actingClientId = String(accessToken.getClientId());
  var params = requestProperties.requestParams;
  var details = parseJson(firstParam(params, "request_details"));
  var context = parseJson(firstParam(params, "request_context"));
  var subjectToken = firstParam(params, "subject_token");

  var user = null;
  try {
    user = openidm.read("managed/bravo_user/" + sub, null, ["userName", "custom_txnClients/*"]);
  } catch (e) {
    logger.error("TxnDemo/tokenmod IDM read failed for " + sub + ": " + e);
  }

  accessToken.setField("aud", "acme-internal");
  accessToken.setField("txn", String(accessToken.getAuditTrackingId()));
  accessToken.setField("sub", (user && user.userName) ? String(user.userName) : sub);
  accessToken.setField("req_wl", actingClientId);

  var tctx = {};
  if (details.activity_type) { tctx.activity_type = String(details.activity_type); }
  if (details.delivered_on) { tctx.delivered_on = String(details.delivered_on); }

  var client = user ? pickClient(user.custom_txnClients, details.client_ref) : null;
  if (client) {
    tctx.client_ref = String(client._refResourceId);
    tctx.client_display = String(client.displayName || "");
    tctx.client_tier = String(client.tier || ""); // enriched from IDM, not requested
  }

  if (details.cost_cents !== undefined && details.cost_cents !== null) {
    if (mayAssertCost(subjectToken)) {
      tctx.cost_cents = java.lang.Integer.valueOf(parseInt(details.cost_cents, 10));
    } else {
      logger.error("TxnDemo/tokenmod cost_cents requested but refused by issuance policy: client=" +
        actingClientId + " sub=" + sub);
      // Narrow, don't fail the exchange: the caller still gets a Txn-Token,
      // just one that cannot carry a cost. The refusal is the demonstration.
    }
  }
  accessToken.setField("tctx", tctx);

  var rctx = {};
  if (context.ip) { rctx.ip = String(context.ip); }
  if (context.authn) { rctx.authn = String(context.authn); }
  if (context.portal) { rctx.portal = String(context.portal); }
  accessToken.setField("rctx", rctx);

  logger.error("TxnDemo/tokenmod sub=" + sub + " client=" + actingClientId +
    " tctx=" + JSON.stringify(tctx));
})();
