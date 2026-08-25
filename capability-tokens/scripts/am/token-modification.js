// CapTokenDemo — carry the user's demo roles in the access token, so both
// gates can key on them: the scope policies at mint time and the shop-API
// policies at call time.
//
// `identity` is bound but its AMIdentity is null on the password and
// token-exchange grants (verified 2026-08-25), so the roles are read from IDM
// by the token's own subject. `_fields=roles/*` expands the relationship, so
// the role names arrive in one read rather than one read per role.
(function () {
  var sub = String(accessToken.getResourceOwnerId());
  var roles = [];
  try {
    var user = openidm.read("managed/bravo_user/" + sub, null, ["roles/*"]);
    var granted = user && user.roles;
    if (granted) {
      for (var i = 0; i < granted.length; i++) {
        if (granted[i] && granted[i].name) { roles.push(String(granted[i].name)); }
      }
    }
  } catch (e) {
    logger.error("CapTokenDemo/tokenmod role read failed for " + sub + ": " + e);
  }
  logger.error("CapTokenDemo/tokenmod sub=" + sub + " roles=[" + roles.join(",") + "]");
  accessToken.setField("demoRoles", roles);
})();
