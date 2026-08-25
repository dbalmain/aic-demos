// Every knob the demo needs, in one place, read from the environment that
// `scripts/provision.sh` writes to `apps/.env`.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/** Load `apps/.env` into process.env without adding a dotenv dependency. */
export function loadEnv() {
  let text;
  try {
    text = readFileSync(join(here, "..", ".env"), "utf8");
  } catch {
    return; // provision.sh has not run, or the caller set the vars themselves
  }
  for (const line of text.split("\n")) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)$/.exec(line);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].trim();
  }
}

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set — run scripts/provision.sh`);
  return v;
}

export function config() {
  loadEnv();
  const tenant = required("CAPTOKEN_TENANT_URL").replace(/\/$/, "");
  const realm = process.env.CAPTOKEN_REALM || "bravo";
  const realmPath = `/realms/root/realms/${realm}`;
  return {
    tenant,
    realm,
    // The realm's OAuth2 endpoints. `issuer` is read from discovery at startup
    // rather than constructed — AM's includes an explicit `:443`, and a token's
    // `iss` will not match a URL you built yourself.
    discoveryUrl: `${tenant}/am/oauth2${realmPath}/.well-known/openid-configuration`,
    tokenUrl: `${tenant}/am/oauth2${realmPath}/access_token`,
    policyUrl: `${tenant}/am/json${realmPath}/policies?_action=evaluate`,
    policySet: process.env.CAPTOKEN_POLICY_SET || "CapTokenDemo",
    registerTree: process.env.CAPTOKEN_REGISTER_TREE || "CapTokenDemoRegister",
    // The roles a registrant may pick. The journey enforces the same list — this
    // copy only decides what the form offers.
    offeredRoles: (process.env.CAPTOKEN_OFFERED_ROLES ||
      "orders.reader,orders.approver,payments.admin").split(","),
    login: {
      id: required("CAPTOKEN_LOGIN_CLIENT_ID"),
      secret: required("CAPTOKEN_LOGIN_CLIENT_SECRET"),
    },
    caller: {
      id: required("CAPTOKEN_CALLER_CLIENT_ID"),
      secret: required("CAPTOKEN_CALLER_CLIENT_SECRET"),
    },
    // The resource server's own credential, for calling the policy endpoint.
    pep: {
      id: process.env.CAPTOKEN_API_CLIENT_ID || "",
      secret: process.env.CAPTOKEN_API_CLIENT_SECRET || "",
      bearer: process.env.CAPTOKEN_API_BEARER || "",
    },
    apiUrl: process.env.CAPTOKEN_API_URL || "http://127.0.0.1:8791",
    apiAudience: process.env.CAPTOKEN_API_AUDIENCE || "https://shop-api.demo:443",
    webPort: Number(process.env.CAPTOKEN_WEB_PORT || 8790),
    apiPort: Number(process.env.CAPTOKEN_API_PORT || 8791),
  };
}
