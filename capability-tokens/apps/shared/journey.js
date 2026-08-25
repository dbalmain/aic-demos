// Driving an AM journey from the server, which is a two-post conversation:
// ask for the callbacks, fill them in, post them back.
//
// The registration journey is one scripted decision node that collects on its
// first pass and creates the account on its second, so there are exactly two
// posts and no loop to write.
const HEADERS = {
  "content-type": "application/json",
  "accept-api-version": "resource=2.0, protocol=1.0",
};

function authenticateUrl(cfg, tree) {
  return (
    `${cfg.tenant}/am/json/realms/root/realms/${cfg.realm}/authenticate` +
    `?authIndexType=service&authIndexValue=${encodeURIComponent(tree)}`
  );
}

async function post(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: HEADERS,
    body: body ? JSON.stringify(body) : undefined,
  });
  return res.json();
}

/** Set the value of the first callback of a given type. */
function fill(step, type, value) {
  const cb = step.callbacks.find((c) => c.type === type);
  if (!cb) throw new Error(`the journey did not ask for a ${type}`);
  cb.input[0].value = value;
}

/**
 * Register a user with the roles they picked.
 *
 * Resolves to the new session's `tokenId`. The caller does not need it — the
 * BFF signs the user in through the token endpoint straight afterwards — but
 * its absence is how a failed journey shows up.
 */
export async function register(cfg, { email, password, roles }) {
  const url = authenticateUrl(cfg, cfg.registerTree);
  const step = await post(url);
  if (!step.callbacks) throw new Error(step.message ?? "the journey did not start");

  fill(step, "NameCallback", email);
  fill(step, "PasswordCallback", password);
  fill(step, "StringAttributeInputCallback", roles.join(","));

  const done = await post(url, step);
  if (!done.tokenId) {
    throw new Error(done.detail?.failureUrl ?? done.message ?? "registration failed");
  }
  return done.tokenId;
}
