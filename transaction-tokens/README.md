# Transaction tokens on PingOne Advanced Identity Cloud

**Status: built and running.** A working demo of the
`draft-ietf-oauth-transaction-tokens` pattern, using PingOne Advanced Identity
Cloud (AIC) as the Transaction Token Service. Everything below is verified
against a live tenant — there's a walkthrough at the end you can run yourself.

## The problem this solves

Say a company's internal systems are chained together: a portal talks to a BFF
(backend-for-frontend), which talks to an activities API, which talks to a
ledger. An account manager logs in once, and that one action — "record an
advisory activity for this client, it cost this much" — has to travel through
all three internal services before it's actually recorded.

The obvious way to do this is to pass the account manager's own login token
along at every hop. That has two problems:

1. **The token means too much, for too long.** A login token usually lives for
   minutes or hours and proves "this is the account manager, generally." Handing
   that same token to three different internal services means each one now holds
   a credential far more powerful than the one thing it actually needed to do.
2. **Nobody downstream knows what was actually decided.** By the time the
   request reaches the ledger, "was this account manager even allowed to assert
   a cost right now?" is a question only the _first_ service ever had enough
   context to answer. The ledger either has to trust the activity API's word for
   it, or re-derive the whole decision itself.

The **transaction tokens** draft's answer: mint a _new_, short-lived token — a
**Txn-Token** — the moment the real decision gets made, stamp it with exactly
what was decided (which client, what activity, whether a cost may be attached,
and by whom), and pass that one token, unchanged, through every remaining hop.
Each service checks the token's signature for itself; none of them has to call
back to the identity provider or trust what the previous hop says. The login
token never leaves the first service.

That's the shape of this repo. We don't build every wire-format detail the draft
specifies (see [`ARCHITECTURE.md`](ARCHITECTURE.md) for exactly which four don't
fit AIC and why) — but the actual mechanism, a decision minted once and
independently checked at every hop, is real and running.

## The cast

| Component                                 | What it does                                                                                                                                                              | Who it talks to                            |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| **AIC** (PingOne Advanced Identity Cloud) | The identity provider _and_ the Transaction Token Service. Signs the account manager in, and mints every Txn-Token.                                                       | Everything below authenticates against it. |
| **portal-bff**                            | The only thing the browser talks to. Holds the account manager's sign-in session and asks AIC to mint a Txn-Token per activity.                                           | Browser, AIC, activity-api                 |
| **activity-api**                          | The middle hop. Checks the Txn-Token for itself, then forwards it — the identical token — to the ledger.                                                                  | portal-bff, ledger-service                 |
| **ledger-service**                        | Where an activity actually gets recorded. Checks the Txn-Token independently too, and writes only what the token itself says — never what the request body claims.        | activity-api                               |
| **accrual-job**                           | A nightly, unattended process — no browser, no user. Signs itself in and tries to record a cost-bearing activity. This is where the interesting part happens (see below). | AIC, activity-api                          |

## The interesting part: two identities, one gate, different answers

Two different things ask AIC for a Txn-Token in this demo:

- **The account manager**, via `portal-bff`, after signing in for real.
- **The nightly job**, via `accrual-job`, which has no user behind it at all —
  it signs itself in with its own private key.

Both ask AIC for the same thing: a Txn-Token that can assert a cost. AIC answers
differently for each, because of one rule sitting in AIC's policy engine (not in
application code): _only a token that came from a real account manager sign-in
may assert `cost_cents`._ The nightly job's own sign-in never carries that
scope, so it gets a Txn-Token back — the exchange still succeeds — just one with
the cost field silently missing. The job notices, and records a cost-free entry
instead.

That refusal-then-fallback is the demo. Nobody wrote an `if` statement anywhere
that says "the nightly job can't assert a cost" — that's a policy in AIC anyone
with console access can open, read, and change, and the very next token-mint
would reflect it.

## What travels where, and in what format

| Hop                                        | Header                                                   | Format                             | Why                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------------------------------ | -------------------------------------------------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Browser → portal-bff                       | `Cookie` (a random session id)                           | **Opaque**                         | The browser never needs to read anything inside it, so there's nothing to gain from a structured format — and an opaque cookie can't leak claims if it's ever logged by accident.                                                                                                                                                                                                                                |
| portal-bff → AIC (sign-in)                 | HTTP Basic (client credentials) + form body              | —                                  | Standard OAuth2 password grant, this demo's stand-in for a real login screen.                                                                                                                                                                                                                                                                                                                                    |
| Account manager's own identity token       | held only inside portal-bff                              | **JWT, signed by AIC**             | Needs to be a real, self-contained JWT because AIC's _own_ scripts inspect its claims (which scope it carries) when deciding whether to mint a Txn-Token — not because any app in this demo decodes it. Apps that only need to know _who_ it belongs to call AIC's `/userinfo` endpoint instead of decoding it themselves, which works the same way whether the token happens to be opaque or a JWT — see below. |
| accrual-job's own identity token           | held only inside accrual-job                             | **JWT, signed by AIC**             | Same reason as above — it's the nightly job's equivalent of a login, minted via `jwt-bearer` (the job signs its own assertion with a private key AIC trusts) rather than a password.                                                                                                                                                                                                                             |
| portal-bff → activity-api → ledger-service | `Txn-Token` (a header of its own, never `Authorization`) | **JWT, signed by AIC**, 60 seconds | Has to be self-contained: every hop verifies it against AIC's public keys _independently_, with no callback to AIC and no trust placed in whichever service handed it over. Splitting it into its own header, rather than reusing `Authorization`, keeps "who is calling this API" (a service credential, absent in this small demo) cleanly separate from "what business decision was made" (the Txn-Token).    |

**Opaque where we can, a real JWT only where a real JWT is doing real work.** We
didn't default every token in this system to opaque and every claim in this
system to hidden — a Txn-Token has to be a JWT for the whole pattern to mean
anything, since the entire point is that a downstream service can check it
without asking anyone. But nothing that doesn't need that property should carry
it: the browser's own credential is opaque, and the identity tokens are only
ever inspected by AIC's own scripts and by `/userinfo`, never decoded by our own
application code.

### The core claims inside a Txn-Token

```jsonc
{
  "sub": "am-alice",          // human-readable, not AIC's internal UUID
  "aud": "acme-internal",     // the whole trust domain, not one service's id
  "txn": "…",                 // one id per business transaction
  "exp": …, "iat": …,         // 60-second lifetime
  "req_wl": "TxnDemo_caller", // which workload requested the mint
  "tctx": {                   // the decision — integrity-critical, AIC-authoritative
    "activity_type": "advisory",
    "delivered_on": "2026-08-31",
    "client_ref": "client-4471",
    "client_display": "Acme Holdings",  // enriched from IDM, not requested
    "client_tier": "gold",              // enriched from IDM, not requested
    "cost_cents": 45000                 // present only when the issuance policy allows it
  }
}
```

Everything under `tctx` is what every downstream service actually trusts. The
free-text note a user types when posting an activity travels in the request body
instead — never in `tctx` — so it can never be mistaken for something
integrity-critical: if the body disagrees with the token, the body loses.

## Running it

You need: an unlocked `aic` agent (from a
[`pingone-aic-manager`](../../pingone-aic-manager) checkout) pointed at a
sandbox `bravo` realm, Terraform ≥ 1.6, Node ≥ 22, and the
[`terraform-provider-pingone-aic`](../../terraform-provider-pingone-aic)
provider built locally (`make install` in that repo).

```sh
cp .env.example .env      # fill in the secrets — see the comments in the file
aic login                 # in your pingone-aic-manager checkout

export PINGONEAIC_TENANT_URL="$TXNDEMO_TENANT_URL"
export PINGONEAIC_ACCESS_TOKEN="$(aic --no-prompt whoami --token)"
export TF_VAR_web_client_secret="$TXNDEMO_WEB_CLIENT_SECRET"
export TF_VAR_jobsvc_client_secret="$TXNDEMO_JOBSVC_CLIENT_SECRET"
export TF_VAR_caller_client_secret="$TXNDEMO_CALLER_CLIENT_SECRET"

terraform -chdir=terraform init
terraform -chdir=terraform apply     # the AIC side: clients, scripts, policies, the managed-object schema

scripts/seed.sh                      # the account manager, the nightly job's own identity, one client
scripts/setup-jwtbearer.sh           # the nightly job's signing key + Trusted JWT Issuer
scripts/write-env.sh                 # terraform output -> apps/.env

cd apps && npm install
npm run dev                          # portal-bff, activity-api, ledger-service — http://127.0.0.1:9000
```

Sign in as `am-alice` (the password you set in `.env`), post an activity with a
cost, and watch the trail render on the page — the exact `tctx` the ledger
recorded.

Then, in another terminal, run the nightly job and watch it get refused:

```sh
cd apps && npm run job
```

```
accrual-job: signing in as 0a97c003-… via jwt-bearer
accrual-job: exchanging for a Txn-Token, requesting cost_cents
accrual-job: cost_cents refused by the issuance policy, as expected
accrual-job: recorded a cost-free entry instead — {"activity_type":"accrual","delivered_on":"…"}
```

## Layout

| Path         | What goes there                                                                                                                                                                                            |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/`      | the four services: `portal-bff`, `activity-api`, `ledger-service`, `accrual-job`, plus `shared/` for the AIC calls they all make                                                                           |
| `terraform/` | the AIC config — this is where the TTS lives: OAuth2 clients, the validate-scope and token-modification scripts, the issuance policies, and the managed-object schema for the manager↔client relationship |
| `scripts/`   | IDM fixtures, the nightly job's signing-key setup, and the `apps/.env` writer                                                                                                                              |
| `docs/`      | the brief, the architecture, and the departures-from-the-draft log                                                                                                                                         |

Same approach as [`../capability-tokens/`](../capability-tokens/): Terraform
owns the tenant configuration, a small script owns the IDM fixtures, and the
tenant hostname and secrets live in a gitignored `.env`.

For the full technical detail — exactly which four wire-format details AIC can't
match, the eventual-consistency traps in the managed-object schema, and why the
manager↔client relationship lives inside AIC rather than in an app database —
read [`ARCHITECTURE.md`](ARCHITECTURE.md).
