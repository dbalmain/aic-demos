// The resource server's own credential for calling the policy endpoint.
//
// Reaching `?_action=evaluate` needs a **service-account** bearer. A realm
// OAuth2 client's `client_credentials` token is refused even when it holds
// `fr:am:*` — verified 2026-08-25: the token issues fine and the policy call
// comes back `401 Access Denied`. So the resource server needs a machine
// identity of its own, and in AIC a service account is created in the console,
// not by an API this demo could call.
//
// Two ways to supply it, in order:
//
//   CAPTOKEN_API_BEARER   a bearer you provide. What a deployment would do
//                         (minted from the API's own service-account JWK).
//   CAPTOKEN_AIC_PROJECT  a development shortcut: borrow the bearer from the
//                         `aic` agent running against this tenant. Explicitly
//                         opt-in, and never something to ship.
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

async function fromAicAgent(projectDir) {
  const { stdout } = await run("aic", ["--no-prompt", "whoami", "--token"], {
    env: { ...process.env, AIC_PROJECT: projectDir },
  });
  const token = stdout.trim();
  if (!token) throw new Error("aic returned no token — is the agent unlocked?");
  return token;
}

/**
 * A credential: `get()` hands back a bearer, `invalidate()` throws the cached
 * one away.
 *
 * Deliberately not refreshed on a timer. A timer has to guess the remaining
 * life of a token someone else minted, and guessing short wastes calls while
 * guessing long fails exactly the request you cared about — which is what
 * happened here, with a 10-minute window against a 898-second token whose
 * clock had started long before this process did. The rejection is the only
 * reliable signal that a bearer is finished, so use it.
 */
export function pdpCredential() {
  const fixed = process.env.CAPTOKEN_API_BEARER;
  if (fixed) return { get: async () => fixed, invalidate() {} };

  const projectDir = process.env.CAPTOKEN_AIC_PROJECT;
  if (!projectDir) {
    throw new Error(
      "the API has no way to authenticate to the policy endpoint: set " +
        "CAPTOKEN_API_BEARER, or CAPTOKEN_AIC_PROJECT to borrow the local aic agent's",
    );
  }

  let cached = null;
  return {
    async get() {
      if (!cached) cached = await fromAicAgent(projectDir);
      return cached;
    },
    invalidate() {
      cached = null;
    },
  };
}
