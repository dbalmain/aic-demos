// accrual-job — the demo's internally-initiated flow: no user, no browser,
// run by invoking this script (a real deployment would put it on a
// scheduler; this repo does not need one to make the point).
//
// It signs its own jwt-bearer assertion, exchanges the resulting service
// token for a Txn-Token, and ASKS for a cost — the same request an account
// manager could make. The issuance policy refuses it, because the subject
// scope on a service token is never portal.activities
// (terraform/policy.tf:TxnDemoIssuance_AssertCost). That refusal narrows the
// Txn-Token rather than failing the exchange, so the job still gets a valid
// token — just one with no cost_cents in tctx — and posts a cost-free entry
// with it. No second exchange call: the fallback IS what came back.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { config, exchange, loginAsJob, workloadHeaders } from "@txndemo/shared";

const here = dirname(fileURLToPath(import.meta.url));
const cfg = config();

if (!cfg.jobSubjectId) {
  console.error("TXNDEMO_JOBSVC_SUBJECT_ID is not set — run scripts/setup-jwtbearer.sh and scripts/write-env.sh");
  process.exit(2);
}

const jwk = JSON.parse(readFileSync(join(here, ".keys", "signing.jwk"), "utf8"));

console.log(`accrual-job: signing in as ${cfg.jobSubjectId} via jwt-bearer`);
const serviceToken = await loginAsJob(cfg, jwk, cfg.jobSubjectId);

const requestDetails = {
  activity_type: "accrual",
  delivered_on: new Date().toISOString().slice(0, 10),
  cost_cents: 9900, // asked for anyway — the refusal is the point
};
const requestContext = { authn: "jwt-bearer", portal: null };

console.log("accrual-job: exchanging for a Txn-Token, requesting cost_cents");
const txn = await exchange(cfg, serviceToken.access_token, { requestDetails, requestContext });

const res = await fetch(`${cfg.activityApiUrl}/activities`, {
  method: "POST",
  headers: { ...workloadHeaders(cfg, "accrual-job"), "txn-token": txn.access_token, "content-type": "application/json" },
  body: JSON.stringify({ note: "monthly accrual" }),
});
const result = await res.json();
if (!res.ok) {
  console.error("accrual-job: activity-api refused it —", result);
  process.exit(1);
}

if ("cost_cents" in (result.tctx ?? {})) {
  console.log(`accrual-job: unexpected — cost_cents was granted (${result.tctx.cost_cents})`);
} else {
  console.log("accrual-job: cost_cents refused by the issuance policy, as expected");
  console.log("accrual-job: recorded a cost-free entry instead —", JSON.stringify(result.tctx));
}
console.log(`accrual-job: ledger txn ${result.ledger?.entry?.txn}`);
