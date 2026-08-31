// Every knob the demo needs, in one place, read from the environment that
// `scripts/write-env.sh` writes to `apps/.env`.
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
    return; // write-env.sh has not run, or the caller set the vars themselves
  }
  for (const line of text.split("\n")) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)$/.exec(line);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].trim();
  }
}

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set — run scripts/write-env.sh`);
  return v;
}

export function config() {
  loadEnv();
  const tenant = required("TXNDEMO_TENANT_URL").replace(/\/$/, "");
  const realm = process.env.TXNDEMO_REALM || "bravo";
  const realmPath = `/realms/root/realms/${realm}`;
  return {
    tenant,
    realm,
    // `issuer` is read from discovery at startup rather than constructed —
    // AM's includes an explicit `:443`, and a token's `iss` will not match a
    // URL you built yourself.
    discoveryUrl: `${tenant}/am/oauth2${realmPath}/.well-known/openid-configuration`,
    tokenUrl: `${tenant}/am/oauth2${realmPath}/access_token`,
    userinfoUrl: `${tenant}/am/oauth2${realmPath}/userinfo`,
    web: {
      id: required("TXNDEMO_WEB_CLIENT_ID"),
      secret: required("TXNDEMO_WEB_CLIENT_SECRET"),
    },
    jobsvc: {
      id: process.env.TXNDEMO_JOBSVC_CLIENT_ID || "",
      secret: process.env.TXNDEMO_JOBSVC_CLIENT_SECRET || "",
    },
    caller: {
      id: required("TXNDEMO_CALLER_CLIENT_ID"),
      secret: required("TXNDEMO_CALLER_CLIENT_SECRET"),
    },
    // Every internal hop validates against this — never against the API's
    // own client id, which is what makes "the trust domain", not one client,
    // the audience.
    trustDomain: process.env.TXNDEMO_TRUST_DOMAIN || "acme-internal",
    portalScope: process.env.TXNDEMO_PORTAL_SCOPE || "portal.activities",
    exchangeScope: process.env.TXNDEMO_EXCHANGE_SCOPE || "client:activity:write",
    portalPort: Number(process.env.TXNDEMO_PORTAL_PORT || 9000),
    activityApiPort: Number(process.env.TXNDEMO_ACTIVITY_API_PORT || 9002),
    ledgerPort: Number(process.env.TXNDEMO_LEDGER_PORT || 9003),
    activityApiUrl: process.env.TXNDEMO_ACTIVITY_API_URL || "http://127.0.0.1:9002",
    ledgerUrl: process.env.TXNDEMO_LEDGER_URL || "http://127.0.0.1:9003",
    jobSubjectId: process.env.TXNDEMO_JOBSVC_SUBJECT_ID || "",
  };
}
