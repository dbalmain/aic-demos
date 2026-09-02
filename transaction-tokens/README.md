# Transaction tokens on PingOne Advanced Identity Cloud

**Status: built and running.** A working demo of the
`draft-ietf-oauth-transaction-tokens` pattern, using PingOne Advanced Identity
Cloud (AIC) as the Transaction Token Service. Everything described here is
verified against a live tenant, and [Running it](#running-it) is a step-by-step
walkthrough you can follow without knowing AIC or Terraform beforehand.

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

That's the shape of this repo. It is not a complete implementation of the draft
— [`ARCHITECTURE.md`](ARCHITECTURE.md) has the full departures list, including
three places where what's enforced here is genuinely weaker than the draft's
model — but the mechanism, a decision minted once and independently checked at
every hop, is real and running.

## The cast

| Component                                 | What it does                                                                                                                                                              | Who it talks to                            |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| **AIC** (PingOne Advanced Identity Cloud) | The identity provider _and_ the Transaction Token Service. Signs the account manager in, and mints every Txn-Token.                                                       | Everything below authenticates against it. |
| **portal-bff** (:9000)                    | The only thing the browser talks to. Holds the account manager's sign-in session and asks AIC to mint a Txn-Token per activity.                                           | Browser, AIC, activity-api                 |
| **activity-api** (:9002)                  | The middle hop. Checks the Txn-Token for itself, then forwards it — the identical token — to the ledger.                                                                  | portal-bff, ledger-service                 |
| **ledger-service** (:9003)                | Where an activity actually gets recorded. Checks the Txn-Token independently too, and writes only what the token itself says — never what the request body claims.        | activity-api                               |
| **accrual-job**                           | A nightly, unattended process — no browser, no user. Signs itself in and tries to record a cost-bearing activity. This is where the interesting part happens (see below). | AIC, activity-api                          |

## The interesting part: two identities, one gate, different answers

Two different things ask AIC for a Txn-Token in this demo:

- **The account manager**, via `portal-bff`, after signing in for real.
- **The nightly job**, via `accrual-job`, which has no user behind it at all —
  it signs itself in with its own private key.

Both ask AIC for the same thing: a Txn-Token that can assert a cost. AIC answers
differently for each, because of one rule sitting in AIC's policy engine (not in
application code): _only a token carrying an account manager's sign-in scope may
assert `cost_cents`._ The nightly job's own sign-in carries `job.accrual`
instead, so it gets a Txn-Token back — the exchange still succeeds — just one
with the cost field silently missing. The job notices, and records a cost-free
entry instead.

That refusal-then-fallback is the demo. Nobody wrote an `if` statement anywhere
that says "the nightly job can't assert a cost" — that's a policy in AIC anyone
with console access can open, read, and change, and the very next token-mint
would reflect it.

**The policy is configured in code.** In `terraform/policy.tf`, change
`TxnDemoIssuance_DenyCost`'s `action_values` from `{ assert = false }` to
`{ assert = true }`, apply, and the very next mint gives the job its cost.
Nothing else needs to change; nothing else is independently blocking it.

The refusal is a **written-down `no`**. The policy set holds two rules: an allow
for the account manager's scope and an explicit deny for the job's. A policy set
with only the allow answers a non-matching subject with "no policy applied",
which is exactly what a _deleted_ policy also looks like. Both would have
produced a cost-free token and the same cheerful "refused as expected" message.
The mint now requires an explicit `true` or `false` and fails outright on
anything else, so the demo cannot succeed by accident.

Two caveats, because the wording is easy to get wrong:

- The gate keys on the **subject**, whose sign-in this is, not on **which
  service** is asking. Both programs authenticate the exchange itself as the
  same AIC client, so this demo does not show per-workload issuance control.
- "Re-run on every mint" makes a **policy** edit take effect immediately. It
  does not make a revocation immediate: the gate reads the scope frozen into the
  subject token, so a token already issued keeps whatever it was given until it
  expires.

Both are written up as departures 3 and 8 in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## What travels where, and in what format

| Hop                                        | Header                                                                 | Format                             | Why                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------ | ---------------------------------------------------------------------- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Browser → portal-bff                       | `Cookie` (a random session id)                                         | **Opaque**                         | The browser never needs to read anything inside it, so there's nothing to gain from a structured format — and an opaque cookie can't leak claims if it's ever logged by accident.                                                                                                                                                                                             |
| portal-bff → AIC (sign-in)                 | HTTP Basic (client credentials) + form body                            | —                                  | Standard OAuth2 password grant, this demo's stand-in for a real login screen.                                                                                                                                                                                                                                                                                                 |
| Account manager's own identity token       | held only inside portal-bff                                            | **JWT, signed by AIC**             | Needs to be a real JWT because AIC's _own_ scripts inspect its claims when deciding whether to mint a Txn-Token — not because any app here decodes it. Apps that only need to know _who_ it belongs to call AIC's `/userinfo` instead, which works the same way whether the token is opaque or a JWT.                                                                         |
| accrual-job's own identity token           | held only inside accrual-job                                           | **JWT, signed by AIC**             | Same reason — the job's equivalent of a login, minted via `jwt-bearer` (the job signs its own assertion with a private key AIC trusts) rather than a password.                                                                                                                                                                                                                |
| portal-bff → activity-api → ledger-service | **two** headers: `Authorization` (workload) and `Txn-Token` (decision) | **JWT, signed by AIC**, 60 seconds | The Txn-Token has to be self-contained: every hop verifies it against AIC's public keys _independently_, with no per-token callback and no trust in whichever service handed it over. It travels in a header of its own because the draft forbids using it to authenticate the caller — "who is calling" and "what was decided" are separate questions with separate answers. |

**Opaque where we can, a real JWT only where a real JWT is doing real work.** A
Txn-Token has to be a JWT for the pattern to mean anything, since the whole
point is that a downstream service can check it without asking anyone. But
nothing that doesn't need that property should carry it: the browser's own
credential is opaque, and the identity tokens are only ever inspected by AIC's
own scripts and by `/userinfo`, never decoded by our own application code.

### The core claims inside a Txn-Token

```jsonc
{
  "sub": "am-alice",             // human-readable, not AIC's internal UUID
  "aud": "acme-internal",        // the whole trust domain, not one service's id
  "txn": "…",                    // one id per business transaction
  "exp": …, "iat": …,            // 60-second lifetime
  "scope": ["client:activity:write"],  // the narrowed internal intent
  "req_wl": "TxnDemo_caller",    // the client that requested the mint
  "tctx": {                      // the decision
    "client_ref": "client-4471",         // vouched: the subject's own relationship
    "client_display": "Acme Holdings",   // vouched: enriched from IDM, not requested
    "client_tier": "gold",               // vouched: enriched from IDM, not requested
    "activity_type": "advisory",         // the caller's word, shape-checked
    "delivered_on": "2026-09-01",        // the caller's word, shape-checked
    "cost_cents": 45000                  // vouched: only if the issuance policy allows
  }
}
```

Everything under `tctx` is bound to this one transaction under AIC's signature,
so no hop can alter it. **That is not the same as AIC having checked it**, and
the difference is the whole security value:

- **Vouched** — the client fields come from IDM via the subject's own
  relationship, so a caller cannot name a client the subject doesn't manage.
  `cost_cents` is present only because the issuance policy said so.
- **Bound, not vouched** — the activity type and date are the caller's own
  words. AIC validates their _shape_ and rejects the whole request if it's wrong
  (a non-string type, a malformed date, a negative cost), then binds them. It
  does not claim they are true.

The free-text note a user types travels in the request body instead — never in
`tctx` — so it can never be mistaken for something integrity-critical. If the
body disagrees with the token, the body loses.

### Seeing it for yourself

After posting an activity, follow **"see it at every hop"** on the dashboard.
`GET /trail/:txn` shows one column per hop: what each service validated, what it
decided, and a hash of the token it saw. The same hash in every column is the
evidence that the token really did traverse the chain unmodified. No column ever
shows a complete token — a hash correlates, and a decoded payload carries no
signature, so nothing in the trail can be replayed.

Two things the page is careful about, both of which it previously got wrong:

- It only claims the token was unchanged when **every hop in that chain**
  reported. Stop the two downstream services and it says "not every hop
  reported, so this proves nothing either way" — where it used to find one
  surviving record, see one distinct hash, and announce agreement. Which hops it
  expects depends on where the transaction started, since the nightly job calls
  `activity-api` directly and `portal-bff` is legitimately not in that chain;
  the page names the flow it detected.
- The "called by" line is labelled **claimed, unverified**, because the shared
  workload credential genuinely cannot identify a caller. It used to assert
  `portal-bff`, which was simply false on the nightly job's path — the job calls
  `activity-api` directly.

---

## Running it

Allow about 20 minutes the first time. Steps 1–3 are one-time setup; 4–8 build
the demo; 9–11 run it.

### What you need first

| Thing                                                          | Why                                                                                                                                                | Check               |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| **An AIC tenant** you may write to, with a `bravo` realm       | The demo creates OAuth2 clients, scripts, policies and a managed-object type in it. Use a sandbox — **not** a tenant holding live customer config. | your Ping console   |
| **A `pingone-aic-manager` checkout**, onboarded to that tenant | Everything here borrows its service-account credentials rather than holding its own. If `aic ctx list` shows your tenant with a `*`, you're set.   | `aic ctx list`      |
| **Go** ≥ 1.25                                                  | to build the Terraform provider from source                                                                                                        | `go version`        |
| **Terraform** ≥ 1.6                                            | creates the AIC-side configuration                                                                                                                 | `terraform version` |
| **Node** ≥ 22.13                                               | the four services. Verified on 24.19. `node:sqlite` needs 22.13+ without a flag.                                                                   | `node --version`    |
| **bash, curl, jq, python3**                                    | the helper scripts                                                                                                                                 | `jq --version`      |

Those three checkouts can live wherever you like. Nothing here assumes a
particular layout: `pingone-aic-manager` is reached through the `AIC_PROJECT`
variable you set in step 2, and the provider only has to be built once, from
wherever you cloned it.

### 1. Build and install the Terraform provider

The provider is not published to a registry, and this demo needs fixes that only
exist in the local checkout. `make install` drops the binary where Terraform
looks for local plugins — a machine-wide location, so it does not matter where
you run it from.

```sh
cd /path/to/terraform-provider-pingone-aic
make install
```

> **If you rebuild the provider later**, Terraform will refuse to use it —
> `the cached package ... does not match any of the checksums recorded in the dependency lock file`.
> Delete the lock and re-init:
> `rm -rf terraform/.terraform terraform/.terraform.lock.hcl && terraform -chdir=terraform init`.

### 2. Fill in your configuration

```sh
cd /path/to/aic-demos/transaction-tokens
cp .env.example .env
$EDITOR .env
```

You need to provide seven values; the comments in the file say the same:

- `AIC_PROJECT` — the **absolute** path to your `pingone-aic-manager` checkout.
  This is the only thing tying the two repos together: `aic` roots itself there
  instead of at the current directory, so it finds your tenant config and its
  credentials. It must be a real project directory — one with a `.aic/` in it —
  because `aic` rejects a path that isn't rather than quietly falling back to
  the current one and acting on a different tenant.
- `TXNDEMO_TENANT_URL` — your tenant's base URL. Get it from `aic ctx list`
  rather than typing it; it's the last column of the row marked `*`.
- Three client secrets (`..._WEB_...`, `..._JOBSVC_...`, `..._CALLER_...`) —
  **you choose these.** Terraform sets them on the clients it creates, so
  nothing external has to agree with them. Any strong random string will do.
- Two passwords (`TXNDEMO_ALICE_PASSWORD`, `TXNDEMO_JOBSVC_PASSWORD`) — also
  yours to choose, for the two identities the demo seeds. The realm enforces a
  password policy: mixed case, a digit, and a symbol.

`.env` is gitignored and must stay that way — it holds secrets and your tenant
hostname, which is customer-identifying.

### 3. Load the configuration into your shell

The helper scripts read `.env` themselves, but Terraform reads its settings from
the environment, so your own shell needs them too.

```sh
set -a && . ./.env && set +a
```

<details>
<summary>fish</summary>

```fish
for line in (grep -v '^\s*#' .env | grep '=')
    set -gx (string split -m1 '=' $line)
end
```

</details>

Then unlock the AIC agent — everything from here borrows its token:

```sh
aic login
```

If that says _no project here_, `AIC_PROJECT` didn't reach this shell — check
step 2 and re-run step 3. If it says _AIC_PROJECT=… is not a directory_, the
path is wrong.

Now hand Terraform what it needs:

```sh
export PINGONEAIC_TENANT_URL="$TXNDEMO_TENANT_URL"
export PINGONEAIC_ACCESS_TOKEN="$(aic --no-prompt whoami --token)"
export TF_VAR_web_client_secret="$TXNDEMO_WEB_CLIENT_SECRET"
export TF_VAR_jobsvc_client_secret="$TXNDEMO_JOBSVC_CLIENT_SECRET"
export TF_VAR_caller_client_secret="$TXNDEMO_CALLER_CLIENT_SECRET"
```

> `PINGONEAIC_ACCESS_TOKEN` is a snapshot, and the agent's token lives about 15
> minutes. If a later `terraform` command fails with a 401, re-run that one
> `export` line and try again.

### 4. Create the AIC-side configuration

```sh
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

Read the plan before confirming — it should be **15 to add, 0 to change, 0 to
destroy**, all of them prefixed `TxnDemo`. This creates, in your tenant:

- three OAuth2 clients — the account manager's sign-in, the job's sign-in, and
  the one internal client that performs every token exchange;
- four AM scripts — two `may_act` stamps, the narrowing gate, and the script
  that mints `tctx` and applies the issuance policy;
- two policy sets — which internal scopes a subject may be given, and which
  `tctx` fields it may assert (the second holds an explicit allow _and_ an
  explicit deny, so a refusal is a decision rather than a silence);
- one managed-object type, `bravo_txn_client`, plus the relationship linking a
  client to its account manager.

### 5. Seed the demo's records

Terraform owns tenant _configuration_; these are _records_, which is why they're
a separate step. It creates two identities (`am-alice`, `svc-accrual-job`) and
one client (`Acme Holdings`, gold tier, managed by alice).

```sh
scripts/seed.sh
```

> On a **re-run**, passwords are deliberately not re-applied: the realm's
> password history refuses a value it has already stored, so `seed.sh` would
> fail. The script says so. If you later can't sign in, use
> `scripts/reset-password.sh am-alice` with a password the realm hasn't seen.

### 6. Give the nightly job its signing key

The job has no user at a keyboard, so it signs its own assertion with a private
key AIC is configured to trust.

```sh
scripts/setup-jwtbearer.sh
```

This registers `svc-accrual-job` as an allowed subject on the realm's Trusted
JWT Issuer and exports the private key to `apps/accrual-job/.keys/signing.jwk`
(gitignored). It prints the resulting subject list — worth a glance, because it
**adds** to that list rather than replacing it.

### 7. Check the tenant side before involving any application code

```sh
scripts/chain.sh
```

This is the load-bearing checkpoint. It drives both gates directly against AIC —
no Node, no local services — so if something is wrong you know immediately
whether it's your tenant or the apps. Expect:

```text
Gate A + Gate B, as the account manager
  cost requested, policy allows it    scope=[client:activity:write] {"activity_type":"advisory","client_display":"Acme Holdings", … "cost_cents":45000, …}

Gate B, as the nightly job — the demonstration
  same cost requested, policy refuses it  scope=[client:activity:write] {"activity_type":"accrual","delivered_on":"…"}

Input validation — a malformed request is rejected, not signed
  activity_type is not a string                  REJECTED (invalid_request)
  delivered_on is not date-shaped                REJECTED (invalid_request)
  delivered_on is not a real date                REJECTED (invalid_request)
  cost_cents is negative                         REJECTED (invalid_request)
  client_ref names a client not theirs           REJECTED (invalid_request)
  no activity type or date at all                REJECTED (invalid_request)

All checks behaved as expected. The tenant side is good; run 'cd apps && npm run dev'.
```

Note the `scope=` on each success line. Checking only the transaction context
would let this script pass with the narrowing gate completely broken: Gate A
fails closed to an _empty_ scope, Gate B keeps answering correctly, and the
services downstream would then reject the very tokens this script had blessed.

The second block is the whole point of the demo: the same request, the same
`cost_cents`, a different signed-in identity, and AIC declines to stamp the
cost.

**If it can't sign in as `am-alice`,** the record probably predates this `.env`
— see the note in step 5.

### 8. Generate the applications' configuration

```sh
scripts/write-env.sh
```

Turns `terraform output` plus your `.env` into `apps/.env` (also gitignored),
and generates the shared internal workload credential the services use to
authenticate each other.

### 9. Start the services

```sh
cd apps
npm install
npm run dev
```

One command starts all three: `ledger-service`, `activity-api`, `portal-bff`.
They log to the same terminal. Leave it running.

### 10. Post an activity as the account manager

Open **<http://127.0.0.1:9000>** and sign in as `am-alice` with the password you
put in `.env`.

The form is pre-filled. Submit it, and you should see:

- **`cost_cents present: 45000`** in green, with the full `tctx` beneath it —
  including `client_display` and `client_tier`, which you never typed. AIC
  looked those up from the client's relationship to alice.
- a **"see it at every hop"** link. Follow it for the side-by-side view: three
  columns, one per service, and the same token hash in each.

Worth trying: change **Client** to something that isn't `client-4471` and
submit. The whole mint is refused, rather than a cost-bearing token being issued
with no client attached to it.

### 11. Run the nightly job and watch it get refused

In a second terminal:

```sh
cd apps && npm run job
```

```text
accrual-job: signing in as 0a97c003-… via jwt-bearer
accrual-job: exchanging for a Txn-Token, requesting cost_cents
accrual-job: cost_cents refused by the issuance policy, as expected
accrual-job: recorded a cost-free entry instead — {"activity_type":"accrual","delivered_on":"…"}
accrual-job: ledger txn 3c47f09a-…
```

It asked for the same `cost_cents` the account manager was granted, and got a
valid Txn-Token back without it. That's one exchange, not two — the refusal
narrows the token rather than failing the call, so there is nothing to retry.

### Cleaning up

```sh
scripts/teardown.sh          # records, the issuer subject, and local artefacts
scripts/teardown.sh --all    # the above, then terraform destroy
```

Records come off before configuration, or the managed-object type outlives the
rows that depend on it. `--all` needs the same environment step 3 set up. If a
tenant step fails, teardown stops before touching your local key and `.env` and
before any `terraform destroy` — though records it had already deleted stay
deleted; it is not transactional.

One thing to know before running it against a tenant that is not yours alone:
all three records are addressed by **fixed ids**, and `seed.sh` adopts a record
it finds at one of them rather than failing. If such a record predated the demo,
teardown deletes it — it has no way to tell what it created from what it
adopted. The script says so before it starts deleting.

### When something goes wrong

| Symptom                                                                | Cause                                                                                                     |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `aic error: Config error: no project here`                             | `AIC_PROJECT` never reached this shell. Step 2, then re-run step 3.                                       |
| `aic error: Config error: AIC_PROJECT=… is not a directory`            | The path is wrong. `aic` will not fall back to the cwd, by design.                                        |
| `error: aic could not mint a token`                                    | Usually a locked agent: run `aic login`. The line below it is `aic`'s own reason.                         |
| Terraform 401 / `invalid_token` partway through                        | The agent token expired. Re-run the `PINGONEAIC_ACCESS_TOKEN` export in step 3.                           |
| `the cached package ... does not match any of the checksums`           | You rebuilt the provider. See the note in step 1.                                                         |
| `chain.sh`: cannot sign in as `am-alice`                               | The record predates this `.env`. `scripts/reset-password.sh am-alice`, with a password never used before. |
| `chain.sh`: cannot sign in as `svc-accrual-job`                        | Step 6 hasn't run, or ran before step 5 created the identity.                                             |
| The portal shows `TXNDEMO_… is not set`                                | Step 8 hasn't run, or was run before `terraform apply` finished.                                          |
| `EADDRINUSE`                                                           | An earlier `npm run dev` is still alive. Stop it — a half-running chain fails two hops from its cause.    |
| The activity posts, but `client_display` and `client_tier` are missing | The managed-schema write hasn't propagated yet — it can take seconds. Wait, then post again.              |

### Layout

| Path         | What goes there                                                                                                                                                                                           |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/`      | the four services: `portal-bff`, `activity-api`, `ledger-service`, `accrual-job`, plus `shared/` for the AIC calls, the workload credential and the per-hop trail                                         |
| `terraform/` | the AIC config — this is where the TTS lives: OAuth2 clients, the validate-scope and token-modification scripts, the issuance policies, and the managed-object schema for the manager↔client relationship |
| `scripts/`   | `seed.sh` (records), `setup-jwtbearer.sh` (the job's key), `chain.sh` (the tenant-side check), `write-env.sh`, `teardown.sh`, `reset-password.sh`, and `am/` — the three AM scripts Terraform uploads     |
| `docs/`      | the brief, and the architecture page rendered legibly                                                                                                                                                     |

Same approach as [`../capability-tokens/`](../capability-tokens/): Terraform
owns the tenant configuration, a small script owns the IDM fixtures, and the
tenant hostname and secrets live in a gitignored `.env`.

For the full technical detail — which wire-format details AIC can't match, the
eventual-consistency traps in the managed-object schema, why the manager↔client
relationship lives inside AIC rather than in an app database, and an honest list
of where this is weaker than the draft — read
[`ARCHITECTURE.md`](ARCHITECTURE.md).
