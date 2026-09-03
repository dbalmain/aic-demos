# Capability tokens on PingOne Advanced Identity Cloud

A demo of the **capability token** pattern: a user holds a long-lived identity
token that can do almost nothing, and every privileged call is preceded by an
RFC 8693 **token exchange** that mints a short-lived token carrying exactly one
capability. The resource server does not trust that capability on its face — it
asks AM's policy engine.

**Status: complete.** `terraform apply` builds the whole thing in a tenant from
nothing, two fastify apps drive it, and a registration journey lets a viewer
create a user and watch the policy answer change. `scripts/provision.sh` is
still here as the shell equivalent and as the thing Terraform is checked against
— if the two produce different tenants, one of them is wrong. [PLAN.md](PLAN.md)
has the build order and what each phase found;
[docs/walkthrough.md](docs/walkthrough.md) is the script a presenter reads from.

```sh
cp .env.example .env      # fill in AIC_PROJECT (absolute) and the secrets
set -a && . ./.env && set +a

aic login

export PINGONEAIC_TENANT_URL="$CAPTOKEN_TENANT_URL"
export PINGONEAIC_ACCESS_TOKEN="$(aic --no-prompt whoami --token)"
export TF_VAR_login_client_secret="$CAPTOKEN_LOGIN_CLIENT_SECRET"
export TF_VAR_caller_client_secret="$CAPTOKEN_CALLER_CLIENT_SECRET"

terraform -chdir=terraform init
terraform -chdir=terraform apply
scripts/seed.sh           # the IDM fixtures Terraform does not own
scripts/write-env.sh      # terraform output -> apps/.env

cd apps && npm install && npm run dev   # http://127.0.0.1:8790
```

<details>
<summary>fish</summary>

```fish
for line in (grep -v '^\s*#' .env | grep '=')
    set -gx (string split -m1 '=' $line)
end
```

</details>

## What it looks like working

```text
$ scripts/chain.sh
== alice@captoken.demo ==
  identity token : {"scope":["openid"],"demoRoles":["orders.reader","orders.approver"]}
  it may         : {} on the order
  orders.read: minted ["orders.read"] for 60s -> {"read":true}
  orders.approve: minted ["orders.approve"] for 60s -> {"approve":true}
  payments.refund: minted [] for 60s -> {}
== bob@captoken.demo ==
  identity token : {"scope":["openid"],"demoRoles":["orders.reader"]}
  it may         : {} on the order
  orders.read: minted ["orders.read"] for 60s -> {"read":true}
  orders.approve: minted [] for 60s -> {}
  payments.refund: minted [] for 60s -> {}
```

Three things are worth pointing at in that output:

- **`it may: {}`** — the identity token is genuinely powerless. Same user, same
  order, denied, because the token is not carrying the capability.
- **`payments.refund: minted []`** for alice and **`orders.approve: minted []`**
  for bob — the exchange refuses to mint a capability the user has no claim to.
  That gate is not free; see the warning below.
- The policy call passes **no environment at all**. The policies read the role
  and the capability out of the presented token.
- **`for 60s`** — the identity token lives 900 seconds and the capability tokens
  60, because they are minted by a different client. There is no per-exchange
  lifetime; a short-lived capability token _is_ a second client.

## The mechanism

```text
  browser ──► shop-web (BFF)
                 │  1. log in as CapTokenDemo_web   → identity token, scope=[openid], 900s
                 │     the may-act script stamps       may_act={client_id: CapTokenDemo_caller}
                 │
                 │  2. exchange as CapTokenDemo_caller → capability token, scope=[orders.approve], 60s
                 │        AM runs the caller's           ← gate A: may this user hold
                 │        validate-scope script             this capability?
                 ▼
              shop-api  ──► POST /am/json/{realm}/policies?_action=evaluate
                 3. presents the capability token       ← gate B: may THIS token do
                    as subject.jwt                         THIS, on THIS resource?
```

**One client per layer.** The login client and the caller client are different
OAuth2 clients on purpose: `may_act` names a client, the acting client
authenticates the exchange, and the issued token inherits _its_ lifetime. Gate A
must be attached to the **acting** client — with the script on the login client
only, the exchange is ungated and mints capabilities the user has no claim to.

Gate B is the one worth watching: `shop-api` hardcodes no authorization rule, so
editing a policy in AM changes the answer with no deploy.

> **The exchange widens scope by default.** With no gate A, a subject token
> holding only `openid` exchanges cleanly for `payments.refund` — AM checks the
> request against the _client's_ allowed scopes, not the subject token's. A
> capability-token design without a mint-time gate is decorative. The obvious
> gate (`usePolicyEngineForScope`) does not work on this path; the details, and
> the one that does, are in `pingone-aic-manager/docs/api/22-token-exchange.md`.

## Running it

### Terraform owns the config; a script owns the fixtures

`terraform/` declares everything that is **configuration**: the resource type,
both policy sets, the six policies, the four AM scripts, the registration
journey and the two OAuth2 clients. `scripts/seed.sh` creates the **fixtures**:
three `managed/bravo_role` records and two demo users.

That split is not arbitrary. Those are managed _records_, not config — the
provider models IDM schema, not the rows in it — and registration creates more
users at runtime anyway, so the tenant's user table was never Terraform's to
declare. There is one other thing Terraform cannot produce: reaching
`?_action=evaluate` needs a **service-account** bearer, and AIC service accounts
are created in the console. That stays a prerequisite.

`terraform -chdir=terraform destroy` removes the config; `scripts/teardown.sh`
removes everything including the fixtures.

`scripts/write-env.sh` turns `terraform output -json` into `apps/.env`, so the
apps use the names Terraform actually created rather than the names someone
assumed. The tenant URL and the two client secrets are not outputs — the
hostname is customer-identifying and the secrets are inputs, not products — so
they come from the environment, the same place Terraform got them.

### The shell path, still supported

`scripts/provision.sh` builds the identical tenant with `curl` and `jq`, and is
safe to re-run. It is kept deliberately: it is what Terraform is compared
against, and it is the faster way to read what the demo actually creates.

`scripts/chain.sh` exercises the whole flow without the apps, which is the
fastest way to tell whether the tenant or the app is at fault.

`scripts/aicurl.sh` is a small `curl` wrapper that borrows the running `aic`
agent's bearer, for any method. `aic` resolves its tenant from a project
directory — this repo is not one, so `AIC_PROJECT` in `.env` must name a
`pingone-aic-manager` checkout that is. The tenant hostname is
customer-identifying and stays out of this repo.

## What exists in the tenant

Everything below lives in the **`bravo`** realm; `alpha` is never touched.
Terraform creates all of it except the last three rows, which `scripts/seed.sh`
does.

| Kind          | Name                                                 | Purpose                                                                                                                                                                                                           |
| ------------- | ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Resource type | `CapTokenDemoShopApi`                                | `https://*:*/orders/*`, `https://*:*/payments/*`; actions `read`, `approve`, `refund`                                                                                                                             |
| Policy set    | `CapTokenDemo`                                       | Gate B — what a presented token may do                                                                                                                                                                            |
| Policy        | `CapTokenDemo_OrdersRead`                            | `read` ← role `orders.reader` **and** capability `orders.read`                                                                                                                                                    |
| Policy        | `CapTokenDemo_OrdersApprove`                         | `approve` ← `orders.approver` + `orders.approve`                                                                                                                                                                  |
| Policy        | `CapTokenDemo_PaymentsRefund`                        | `refund` ← `payments.admin` + `payments.refund`                                                                                                                                                                   |
| Policy set    | `CapTokenDemoScopes`                                 | Gate A — which capabilities a user may be _given_. Read by the validate-scope script via `policy.evaluate`                                                                                                        |
| Policy        | `CapTokenDemoScope_<capability>`                     | GRANT ← the matching role, one per capability                                                                                                                                                                     |
| Script        | `CapTokenDemo_MayAct`                                | Stamps `may_act` so the caller client may exchange                                                                                                                                                                |
| Script        | `CapTokenDemo_ValidateScope`                         | Gate A — asks the scope policies which capabilities this subject may hold                                                                                                                                         |
| Script        | `CapTokenDemo_TokenModification`                     | Puts the user's role names into the token as `demoRoles`                                                                                                                                                          |
| Script        | `CapTokenDemo_Register`                              | Self-service registration with role choice (the deliberate hole)                                                                                                                                                  |
| Journey       | `CapTokenDemoRegister`                               | One scripted decision node: collects on the first pass, creates the account on the second                                                                                                                         |
| OAuth2 client | `CapTokenDemo_web`                                   | Layer 1 sign-in. `password`, `authorization_code`, `refresh_token`; **scopes `openid`/`profile` only**, so it can never issue a capability; 900s. Its may-act script hands `CapTokenDemo_caller` the right to act |
| OAuth2 client | `CapTokenDemo_caller`                                | The BFF's outbound identity. Token-exchange **only**, no `refresh_token`; 60s; carries gate A                                                                                                                     |
| Managed role  | `orders.reader`, `orders.approver`, `payments.admin` | `managed/bravo_role`; what a user holds                                                                                                                                                                           |
| User          | `alice@captoken.demo`                                | roles `orders.reader`, `orders.approver`                                                                                                                                                                          |
| User          | `bob@captoken.demo`                                  | role `orders.reader`                                                                                                                                                                                              |

Roles are `managed/bravo_role` records with ordinary membership. The
access-token-modification script copies their names into the token as
`demoRoles`, which is the claim both gates match on.

The AM-side scripts are source-controlled here under
[`scripts/am/`](scripts/am/); the copies in the tenant were uploaded from those
files.

## Things this demo does on purpose that you must not copy

- **Registration lets the user choose their own roles.** That is the whole point
  of the demo — a viewer ticks a box and watches the policy answer change — and
  it is a privilege-escalation hole by construction. It is why the demo lives in
  `bravo`, and the registration form says so above the fields. The journey does
  bound the choice to the demo's three capability roles, so it is "pick from
  this menu" rather than "name any role in the realm".
- **The API borrows the local `aic` agent's bearer** to reach the policy
  endpoint, when `CAPTOKEN_AIC_PROJECT` is set. Reaching `?_action=evaluate`
  needs a _service-account_ bearer — a realm OAuth2 client's
  `client_credentials` token is refused even holding `fr:am:*` — and AIC service
  accounts are created in the console, not by an API this demo could call. A
  deployment sets `CAPTOKEN_API_BEARER` from the API's own service account
  instead.
- `password` grant (ROPC) is used to keep the discovery loop scriptable. A real
  BFF uses `authorization_code`.
- Client secrets and demo passwords live in `.env`, gitignored. Nothing in this
  repo should ever hold a real tenant hostname or credential.

## Where the knowledge lives

The verified API behaviour is written up in the `pingone-aic-manager` docs,
which are the source of truth for both this demo and the tooling:

- `docs/api/21-am-policies.md` — resource types, policy sets, policies, and
  `?_action=evaluate`
- `docs/api/22-token-exchange.md` — the exchange, `may_act`, and the mint-time
  scope gate
