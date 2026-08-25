// CapTokenDemo — self-service registration, including the roles the new user
// wants. A scripted decision node collects the details on its first pass and
// creates the account on its second.
//
// *** This is the demo's deliberate hole. ***
// Letting a registrant choose their own authorization roles is a
// privilege-escalation vulnerability, and it exists here for one reason: a
// viewer can create a user, pick a capability, and watch the policy engine's
// answer change, without an admin console. Nothing about the capability-token
// pattern needs it. Do not copy this node into anything real.
//
// The one restraint kept: the choice is bounded to the demo's own capability
// roles. "Pick from these three" is a demo; "name any role in the realm" would
// be a way to hand yourself an administrative one.
var OFFERED_ROLES = ["orders.reader", "orders.approver", "payments.admin"];

function roleRef(name) {
  var found = openidm.query("managed/bravo_role",
    { "_queryFilter": 'name eq "' + name + '"' }, ["_id"]);
  if (!found || !found.result || !found.result.length) { return null; }
  return { _ref: "managed/bravo_role/" + found.result[0]._id };
}

function chosenRoles(raw) {
  var wanted = String(raw || "").split(",");
  var refs = [];
  for (var i = 0; i < wanted.length; i++) {
    var name = wanted[i].replace(/^\s+|\s+$/g, "");
    if (OFFERED_ROLES.indexOf(name) < 0) { continue; }   // not on the menu
    var ref = roleRef(name);
    if (ref) { refs.push(ref); }
  }
  return refs;
}

if (callbacks.isEmpty()) {
  callbacksBuilder.nameCallback("Email address");
  callbacksBuilder.passwordCallback("Password", false);
  callbacksBuilder.stringAttributeInputCallback(
    "roles", "Roles (comma-separated)", OFFERED_ROLES[0], true);
} else {
  // The next-gen callback getters hand back the submitted value itself, not a
  // callback object to read it out of.
  var email = trim(callbacks.getNameCallbacks().get(0));
  var password = String(callbacks.getPasswordCallbacks().get(0));
  var roles = chosenRoles(callbacks.getStringAttributeInputCallbacks().get(0));

  // Without this the node happily "registers" a blank user: AM issues a
  // session, the caller sees a tokenId, and no record was ever created. A
  // caller that trusts the tokenId then fails one step later with
  // "Resource owner authentication failed", which points at the wrong thing.
  if (!email || !password) {
    action.withErrorMessage("An email address and a password are both required.").goTo("error");
  } else {
    register(email, password, roles);
  }
}

function trim(value) {
  return String(value == null ? "" : value).replace(/^\s+|\s+$/g, "");
}

function register(email, password, roles) {
  try {
    openidm.create("managed/bravo_user", null, {
      userName: email,
      givenName: email.split("@")[0],
      sn: "Demo",
      mail: email,
      password: password,
      accountStatus: "active",
      roles: roles
    });
  } catch (e) {
    // `goTo` records the outcome; it does not stop the script. Returning here
    // is what stops a failed create from falling through to `created` — which
    // it did, reporting success for a user that does not exist.
    logger.error("CapTokenDemo/register create failed for " + email + ": " + e);
    action.withErrorMessage("Could not register " + email + ": " + e).goTo("error");
    return;
  }

  // The tree has to know who it just authenticated, or success has no subject.
  nodeState.putShared("username", email);
  logger.error("CapTokenDemo/register created " + email + " with " + roles.length + " role(s)");
  action.goTo("created");
}
