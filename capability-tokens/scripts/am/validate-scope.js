// CapTokenDemo — the capability gate at mint time (gate A).
//
// AM invokes one validate*Scope function per grant type and intersects the
// return with what was requested, so this can narrow a request but never widen
// one. Without it, RFC 8693 token exchange issues whatever the *client* is
// allowed, regardless of what the subject token held or who the subject is
// (verified 2026-08-25).
//
// The rules are not in here. They are policies in the CapTokenDemoScopes set,
// one per capability, and this script only asks. Two AM limitations shape how:
//
//   - `identity` is bound but empty on this path, so the resource owner has to
//     come out of the request itself (`requestProperties.requestParams`).
//   - `policy.evaluate` accepts a subject of `{claims}` or `{jwt}` and treats
//     both as ANONYMOUS — a policy with an `AuthenticatedUsers` subject grants
//     nothing here. A `{jwt}` subject does satisfy `JwtClaim`, so the scope
//     policies match on the subject token's `demoRoles` claim, which the
//     access-token-modification script put there.
//
// Only the exchange can mint a capability. The login client is restricted to
// `openid`/`profile` by its own scope list and does not run this script.
var SCOPES_POLICY_SET = "CapTokenDemoScopes";
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

// The scopes the policy engine says this subject token may be given.
function granted(subjectToken, requested) {
  var decisions = policy.evaluate({ jwt: subjectToken }, SCOPES_POLICY_SET, requested, {});
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
    // Not a mint. Nothing here should be issuing capabilities anyway; let the
    // client's own scope list be the only authority.
    return requested;
  }
  var out;
  try {
    out = granted(firstParam(params, "subject_token"), requested);
  } catch (e) {
    logger.error("CapTokenDemo/" + where + " policy evaluation failed: " + e);
    return [];   // fail closed: no decision, no capability
  }
  logger.error("CapTokenDemo/" + where + " requested=[" + requested.join(",") +
    "] granted=[" + out.join(",") + "]");
  return out;
}

function validateAccessTokenScope() { return grantable("access_token"); }
function validateRefreshTokenScope() { return grantable("refresh_token"); }
function validateAuthorizationScope() { return grantable("authorization"); }
function validateBackChannelAuthorizationScope() { return grantable("ciba"); }
function validateDeviceCodeScope() { return grantable("device_code"); }
