# Capability tokens — build plan

A self-contained demo of the **capability token** pattern on PingOne Advanced
Identity Cloud: a user holds a long-lived, near-powerless *identity* token, and
every privileged call is preceded by an RFC 8693 **token exchange** that mints a
short-lived, narrowly-scoped **capability token** for one audience. The resource
server does not trust the scope on its face — it asks **AM's policy engine** to
decide.

Nothing here is invented: token exchange is a supported grant type on this
tenant, and the AM policy API answers to a service-account bearer. Both were
verified live on 2026-08-25 (see [Discovery so far](#discovery-so-far)).

## The pattern, concretely

```
                 register (choose roles)          ┌───────────────────────┐
  browser ─────────────────────────────────────►  │  shop-web (fastify)   │
          ◄──── session cookie ───────────────────│  BFF, holds base tok  │
                                                  └───────┬───────────────┘
                                                          │ 1. login (journey / ROPC)
                                                          │    → base token: openid, no capability
                                                          │
                                                          │ 2. token exchange
                                                          │    grant_type=…:token-exchange
                                                          │    subject_token=<base>
                                                          │    audience=shop-api
                                                          │    scope=orders.approve
                                                          ▼
                                                  ┌───────────────────────┐
                                                  │  AIC / AM             │
                                                  │  ─ /am/oauth2/…/token │
                                                  │  ─ scope-validation   │  ← policy touchpoint A
                                                  │    script             │     (may this user hold
                                                  │  ─ /am/json/…/policies│      this capability?)
                                                  │      ?_action=evaluate│  ← policy touchpoint B
                                                  └───────▲───────────────┘
                                                          │ 4. evaluate(resource, action, subject=jwt)
                                                          │
  shop-web ─── 3. call with capability token ───►  ┌──────┴────────────────┐
                                                   │  shop-api (fastify)   │
                                                   │  PEP: verify + ask PDP│
                                                   └───────────────────────┘
```

Two policy touchpoints, deliberately:

- **A — mint time.** Can this subject *receive* `orders.approve` at all? Decided
  by the OAuth2 scope-validation script calling the policy engine (or, in the
  simplest variant, by the client's allowed scopes plus the subject's roles).
- **B — call time.** May *this* token do *this* action on *this* resource, right
  now? Decided by `POST /am/json/{realm}/policies?_action=evaluate`.

B is the one that makes the demo worth watching: the API never hardcodes an
authorization rule, and a policy change in AM changes the answer with no deploy.

## Scope of the demo

- **Registration with role choice.** `shop-web` shows a checkbox list
  (`orders.read`, `orders.approve`, `payments.refund`, …) and creates the user
  with those roles. This is *deliberately unsafe* and must be labelled as such
  in the UI and the README — it exists so a viewer can flip roles and watch the
  policy answer change without an admin console.
- **A visible decision trail.** Every screen shows the token that was presented,
  its scopes, its TTL, and the raw policy-evaluation response including
  `advices`. The point of the demo is the *decision*, not the CRUD.
- **`terraform apply` / `terraform destroy` stands the whole thing up and tears
  it down.** "Self-contained" means no console clicks and no manual seeding — it
  still needs an AIC tenant.

## Build order

Experiments first, Terraform last. AM policies are undocumented territory in
both repos, and a Terraform resource written before the API is understood is a
catalog we will rewrite.

### Phase 0 — discovery spike (manual, curl + `aic`) — ✅ done 2026-08-25

Answered against the live `bravo` realm and written up as
`pingone-aic-manager/docs/api/21-am-policies.md` and `22-token-exchange.md`
(it earned its own file). Results are in [Phase 0 results](#phase-0-results)
below; the table is kept as the record of what was asked.

| # | Question | Why it is load-bearing |
| - | -------- | ---------------------- |
| 1 | Can a service-account bearer **create** a resource type, a policy set (`applications`) and a policy? Which `Accept-API-Version`? `POST ?_action=create` vs `PUT /{id}`? | Everything downstream (`aic policy`, the provider) needs writes. Reads are confirmed. |
| 2 | Full JSON shape of a policy: `subject` types, `condition` types, `resourceAttributes`, `actionValues` semantics. | This becomes the typed catalog. The provider forbids JSON passthrough. |
| 3 | Does `?_action=evaluate` accept `subject: {"jwt": …}` — and does a `JwtClaim` subject condition then see the capability token's claims? | **The riskiest unknown.** If the PDP cannot take the capability token as the subject, touchpoint B needs a different shape (introspect first, pass `claims`). |
| 4 | Does `subject: {"ssoToken": …}` / `{"claims": {…}}` work, and what does the caller need to be allowed to evaluate *on behalf of* another subject? | Determines whether `shop-api` uses its own client credentials or must hold something stronger. |
| 5 | Exercise token exchange end to end on a throwaway client: which client fields are required (`grantTypes`, `tokenExchangeAuthLevel`, `mayActScript`), what `audience` does, and whether the realm-wide `acceptAudienceParametersInTokenExchangeRequests` (currently **false**) must be flipped. | A realm-wide provider setting is the one change that could affect existing traffic — see [Risks](#risks). |
| 6 | Do `OAUTH2_VALIDATE_SCOPE_NEXT_GEN` / `OAUTH2_EVALUATE_SCOPE_NEXT_GEN` scripts run on the **token-exchange** path (not just authorization_code), and can they reach the policy engine? | Decides whether touchpoint A is a script or has to be modelled some other way. Binding data for these contexts already exists in `docs/api/bindings/`. |
| 7 | `?_action=evaluateTree`, `ttl`, and `advices` — what a PEP should cache and how a deny is explained. | The demo's decision trail. |

Tooling for the spike: `scripts/verify-endpoint.sh` for reads and writes, and
`aic jwt-bearer` to mint a **user** token without a browser (an `aic-agent`
issuer already exists on the tenant) — that is what makes touchpoint B testable
before any app exists.

**Exit criterion — met.** `scripts/chain.sh` is that transcript, repeatable:
two users, three capabilities each, allows and denies at both gates. Its output
is in [README.md](README.md).

### Phase 0 results

Full detail in
[`21-am-policies.md`](../../pingone-aic-manager/docs/api/21-am-policies.md) and
[`22-token-exchange.md`](../../pingone-aic-manager/docs/api/22-token-exchange.md).
By question:

1. **Writes: yes**, all on a service-account bearer. But create is asymmetric —
   resource types `PUT /resourcetypes/{id}` with an id you choose (201);
   policies and policy sets create only via `POST ?_action=create` and 404 on a
   `PUT` to a name that does not exist. `?_action=template` on `applications` is
   **501**.
2. **Policy shape captured.** `subject` and `condition` are recursive
   discriminated unions, and `/subjecttypes` + `/conditiontypes` return a JSON
   Schema per leaf type — a machine-readable catalog source for both `aic` and
   the provider. The policy set separately declares which of them its policies
   may use.
3. **`subject: {"jwt": …}` works — this was the riskiest unknown and it lands
   well.** Better than hoped: `JwtClaim` matches *inside an array claim*,
   including the standard `scope` claim. So the policy can read the capability
   out of the presented token and the PEP cannot assert a scope the token never
   carried. The demo's policies now pass **no environment at all**.
4. **`ssoToken` needs a real AM session** (an access token is a 400).
   `claims` is accepted but satisfies nothing — an anonymous subject. With a
   `jwt` subject, `AuthenticatedUsers` **never** matches, which will silently
   defeat any policy written for browser traffic.
5. **Token exchange works, and the audience risk was a false alarm.**
   `acceptAudienceParametersInTokenExchangeRequests` exists on the *client's*
   override block, so no realm-wide change is needed — and it is moot anyway,
   because with the flag off `audience` is accepted and silently ignored rather
   than rejected. What the exchange really needs is a `may_act` claim on the
   subject token, stamped by a script.
6. **The scope hook runs on the exchange — but not the one we expected.**
   `usePolicyEngineForScope` engages and hands the policy engine an
   *unauthenticated* subject, so a per-user scope policy is unreachable that
   way. A next-gen `validate-scope` script does run on the exchange and can only
   narrow, which is the right shape; `identity` is empty there too, so the
   resource owner is recovered from `requestProperties.requestParams`.
7. **`advices` was empty everywhere** and `ttl` was always `Long.MAX_VALUE`. The
   conditions that classically emit advice are the ones that **500** against a
   JWT subject, so "explain the deny" may need the PEP to reconstruct it. Open.

Three findings that change the design rather than just the docs:

- **The exchange widens scope by default.** A token holding only `openid`
  exchanged cleanly for `payments.refund`. Gate A is load-bearing, not a nicety.
- **Gate A has to be a script**, because the declarative option gets no subject.
  That is more code than hoped but it is ~60 lines and it is in
  `scripts/am/validate-scope.js`.
- **Gate B needs no environment**, which is a better story than the original
  design: the decision is a pure function of the token the caller presented.

Two traps cost real time and are now written down: turning on
`providerOverridesEnabled` applies *every* default in the override block (it
silently switched the client from stateless JWTs to opaque tokens), and a
partial `PUT` on an OAuth2 client wipes the groups you omit (leaving
`signEncOAuth2ClientConfig` empty, which surfaces as `"Unknown Signing
Algorithm"` on every later token request).

### Phase 1 — the demo, provisioned by a script — ✅ done 2026-08-25

`aic-demos/capability-tokens/`:

```
apps/
  shop-web/        fastify + a few server-rendered pages; session store in memory
  shop-api/        fastify resource server; PEP middleware
  shared/          token helpers, policy client
scripts/
  provision.sh     aic + curl; idempotent; mirrors what Terraform will do later
  teardown.sh
docs/
  walkthrough.md   the demo script a presenter reads from
```

Provision creates, all under a `CapTokenDemo_` prefix:

- a resource type `CapTokenDemo Shop API` with the actions the API exposes,
- the policy set `CapTokenDemo` (gate B) and its policies,
- the policy set `CapTokenDemoScopes` (gate A) and its policies, now reached by
  the validate-scope script rather than `usePolicyEngineForScope`,
- **three OAuth2 clients**, one per layer boundary: `captoken-web-login`
  (authorization_code, `openid`, long-lived), `captoken-web-caller`
  (token-exchange only, no refresh token, 60s, carries the scope gate and the
  token-modification script), and `captoken-api` for the PEP's own policy calls,
- the may-act script on the login client, pointing at the caller client,
- `managed/bravo_role` records for the capability roles,
- a self-service registration journey whose scripted decision node grants the
  chosen roles.

Build the apps against the Phase 0 transcript, not against guesses.

**Built, and verified by a full teardown + reprovision + `chain.sh`.** Three
things came out differently from the sketch above:

- **The API needs a service-account bearer to reach `?_action=evaluate`.** A
  realm OAuth2 client's `client_credentials` token is refused with
  `401 Access Denied` even holding `fr:am:*`, so there is no third client. The
  API takes `CAPTOKEN_API_BEARER`, or borrows the local `aic` agent's when
  `CAPTOKEN_AIC_PROJECT` is set. Service accounts are console-created in AIC, so
  this stays a prerequisite rather than something Terraform can produce.
- **Registration is one scripted decision node**, not a page-node journey. It
  collects on its first pass via `callbacksBuilder` and creates the account on
  its second. Far less config than the stock registration nodes, and the whole
  thing is one reviewable script.
- **`gate A` reads the roles out of the subject token**, not out of IDM. The
  script hands `policy.evaluate` a `{jwt}` subject, and the scope policies match
  `JwtClaim(demoRoles)`. Sound because the token endpoint verifies the subject
  token before the script ever sees it — unlike `?_action=evaluate`, which
  verifies nothing.

What exists now:

```
apps/            shop-web (BFF, sessions, registration), shop-api (PEP), shared
scripts/         provision.sh, teardown.sh, chain.sh, aicurl.sh, am/*.js
docs/            walkthrough.md
```

### Phase 2 — `aic policy` — ✅ done 2026-08-25

A new `src/policy/` vertical in `pingone-aic-manager`, following the §9 seams
(`api`, `state`, `ops`, `spec`, `cli`; `screen`/`view` only if a tab lands).
CLI-only to begin with:

```
aic policy set list|show|pull|push
aic policy rt list|show
aic policy list|show|pull|push|rm
aic policy eval --resource … --action … --subject-jwt … [--env …]
```

**Built.** `eval` is the one that earned its keep — a policy REPL beats the console for
debugging a deny, and the demo needs exactly that during a walkthrough. Content
snapshots for conflict detection, per CLAUDE.md §5 (policies *do* have
`lastModifiedDate` but the same revert-detection argument applies).

A TUI tab is a later, separate decision — it is ~20 arms across six files
(CLAUDE.md §9), so it should not ride along on this work.

### Phase 3 — Terraform resources — ✅ done 2026-08-25

In `terraform-provider-pingone-aic`, an `internal/policy/` catalog plus:

| Resource | AM object |
| -------- | --------- |
| `pingoneaic_resource_type` | `/resourcetypes/{uuid}` |
| `pingoneaic_policy_set` | `/applications/{name}` |
| `pingoneaic_policy` | `/policies/{name}` |

Typed against the catalog, no `jsonencode()`, generate support, and the same
"unknown field is an error" contract as the rest of the provider. Also audit
`internal/oauth2client/catalog.go` for the token-exchange fields — if the
115-field catalog is missing `tokenExchangeAuthLevel` / `mayActScript`, plan
and generate already fail on this tenant, which is a real (small) bug to fix
either way.

Policy `subject` and `condition` are recursive discriminated unions
(`AND`/`OR`/`NOT` wrapping leaves). `internal/idm/`'s recursive catalog is the
precedent to copy, not `internal/nodetype/`'s flat specs.

### Phase 4 — Terraform-driven demo — ✅ done 2026-08-25

Replace `scripts/provision.sh` with `terraform/` in the demo repo; the apps read
tenant URL, client ids and secrets from `terraform output -json`. `provision.sh`
stays as the documented fallback and as the thing Phase 3 is checked against —
if `terraform apply` and `provision.sh` produce different tenants, one of them
is wrong.

## Risks

1. **The sandbox is a live customer tenant.** `alpha` holds 44 policies, 15
   policy sets, and a `URL` resource type with ~200 patterns. **The demo lives
   in `bravo`** (decided 2026-08-25) — two policy sets, zero policies, a clean
   room in the same tenant. Nothing the demo builds goes in `alpha`.
2. ~~**`acceptAudienceParametersInTokenExchangeRequests` is `false` at the realm
   level.**~~ **Resolved 2026-08-25.** The flag exists on the client's own
   override block, so no realm-wide change is needed, and the demo keys on
   `scope` rather than `audience` anyway. Nothing realm-wide was touched.
3. ~~**Touchpoint A may not exist as designed.**~~ **Resolved 2026-08-25**, in a
   worse-then-better way: the declarative option (`usePolicyEngineForScope`)
   engages on the exchange but is handed an unauthenticated subject, so it
   cannot express a per-user rule. A next-gen `validate-scope` script does run
   on the exchange and can only narrow. Gate A is therefore ~60 lines of
   JavaScript rather than a policy, and the mint-time rules live in that script
   instead of in AM policies. If that split bothers us, the script can call
   `policy.evaluate()` itself (the binding is there) — worth deciding before
   Phase 1 hardens it.
4. **Registration-with-role-choice is a hole by construction.** Keep it visibly
   labelled, keep it in `bravo`, and never let the pattern leak into a template
   someone copies.

## Decisions

### Settled after Phase 0, 2026-08-25

- **Gate A delegates to the policy engine.** The validate-scope script keeps the
  plumbing (resolve the resource owner, return the surviving scopes) but the
  role→capability rules move into `policy.evaluate()` against the
  `CapTokenDemoScopes` set, with the subject supplied explicitly since AM does
  not supply one. Both gates are then AM policies, and the demo's whole story is
  "edit a policy, watch the answer change". Costs one policy call per mint.
- **Roles become IDM managed roles.** `managed/bravo_role` plus membership,
  replacing the `frIndexedMultivalued1` expedient. The scripts query
  relationships instead of an attribute; registration becomes a relationship
  write. `frIndexedMultivalued1` stays only until that lands.
- **One OAuth2 client per layer, not one broker.** Each layer gets its own
  client: the BFF has *two* — one it authenticates users with, one it uses for
  its outbound calls to the next layer. `may_act` names the next hop's client,
  and the capability token inherits the acting client's lifetime, so this is
  also how the token gets to be short-lived. Verified working cross-client, at
  60s. **The scope gate must be attached to the acting client** — on the login
  client alone it is not consulted and the exchange is ungated.
- **Registration is a self-service journey** with a scripted decision node that
  writes the chosen roles. No IDM-writing credential in the BFF.

### Settled 2026-08-25, before Phase 0 started

- **Realm: `bravo`.** Risk 1 above.
- **Phase 0 writes are permitted and its objects stay.** The spike creates
  `CapTokenDemo_*` resource types, policy sets, policies and OAuth2 clients and
  leaves them in place, so Phase 1 provisions on top of a tenant that is already
  known to work. Realm-wide settings — notably
  `acceptAudienceParametersInTokenExchangeRequests` — are **not** changed
  without asking first.
- **Role representation is deferred to Phase 0.** Questions 3 and 6 largely
  decide it; testing beats guessing.

## Discovery so far

Verified 2026-08-25 against the sandbox tenant, `alpha` and `bravo` realms, with
a service-account bearer (`aic whoami --token`) — reads only:

- `GET /am/json{realm}/policies?_queryFilter=true` — 200. `resource=1.0` and
  `resource=2.0` both answer; `2.0` adds `resourceTypeUuid`. 44 policies in
  `alpha`, 0 in `bravo`.
- `GET /am/json{realm}/applications?_queryFilter=true` (policy sets) — 200 with
  `protocol=1.0,resource=2.0`. Each set lists its permitted `conditions[]`,
  `subjects[]` and `resourceTypeUuids[]`, which is the authoritative source for
  a typed catalog.
- `GET /am/json{realm}/resourcetypes?_queryFilter=true` — 200. Four types in
  `alpha`: `OAuth2 Scope` (action `GRANT`), `Authentication` (`Access`), `URL`
  (HTTP verbs), `IDM API Access` (`/openidm/*`).
- `POST /am/json{realm}/policies?_action=evaluate` with
  `protocol=1.0,resource=2.0` — **200**, returns `{resource, actions, attributes,
  ttl, advices}` per resource. With no `subject` it evaluates as the caller (the
  service account), which is unauthenticated as far as policy is concerned, so
  every action came back `false`. An unknown `application` gives a clean 404.
- `POST …/realm-config/agents/OAuth2Client?_action=schema` — `grantTypes`
  includes `urn:ietf:params:oauth:grant-type:token-exchange`.
- `GET …/realm-config/services/oauth-oidc` — token-exchange machinery is present
  and configured (`tokenExchangeClasses` for access-token↔id-token in both
  directions); `acceptAudienceParametersInTokenExchangeRequests` is `false`.
- `.well-known/openid-configuration` does **not** advertise
  `token-exchange` in `grant_types_supported`. Treat discovery as incomplete
  here, not as a contradiction — the grant is enabled per client.
- A `TrustedJwtIssuer` named `aic-agent` already exists, so `aic jwt-bearer` can
  mint end-user tokens for the spike.

Neither repo has any policy support today: no `policy` module in
`pingone-aic-manager/src/`, no policy resource in the provider, and no
`docs/api/` file covering the policy API.


## What phases 2–4 found

### Phase 2 — `aic policy`

Built as `src/policy/` in `pingone-aic-manager`, CLI-only, documented in
`docs/CLI.md`. The commands are the ones sketched above; the interesting part is
`eval`.

AM answers a refusal with `actions: {}`, which is "no policy applied" and covers
a resource that matched nothing, a subject that failed, and a condition that
failed — with nothing in the response to tell them apart. So `eval` reads the
set, its resource types and its policies and reconstructs the reason. Its best
line diffs the presented token against the policy:

```
- policy CapTokenDemo_PaymentsRefund wants claim demoRoles="payments.admin";
  the token has ["orders.approver","orders.reader"]
```

Building that needed AM's URL wildcard rules, which turned out **not** to be
what the vendor docs describe. Measured against a throwaway policy in `bravo`
and now tabulated in `21-am-policies.md`: `*` crosses `/` and `-*-` does not, a
query string is matched as part of the resource, matching is case-insensitive,
and a missing port is defaulted by scheme. Each row is a test.

### Phase 3 — Terraform resources

`pingoneaic_resource_type`, `pingoneaic_policy_set` and `pingoneaic_policy`,
plus generate support, in the provider.

The design problem was that `subject` and `condition` are recursive
discriminated unions and a Terraform schema is static. Rather than guess, the
depth was measured: across the sandbox's two realms — 44 policies in a live
customer realm plus the demo's six — the deepest subject tree is **three**, and
no policy uses a condition at all. The schema unrolls to six levels and errors
above that, because silently truncating a subject would widen the policy to
everyone.

The suspected OAuth2 catalog gap was not real: `tokenExchangeAuthLevel`,
`accessTokenMayActScript` and `validateScopeScript` are all there, and generate
round-trips the demo's two token-exchange clients cleanly.

One genuine provider bug fell out of using it: a script written with the
`SCRIPTED_DECISION_NODE` alias failed apply with "Provider produced inconsistent
result after apply", because AM stores `AUTHENTICATION_TREE_DECISION_NODE` and
`context` is a Required attribute. The provider's own docs advertise the alias,
so this was reachable by following them.

### Phase 4 — Terraform-driven demo

`terraform/` builds the config; `scripts/seed.sh` creates the IDM fixtures.
The split is described in [README.md](README.md#running-it) and it is the one
place the original plan was wrong: Terraform cannot own the roles and users,
because they are managed *records* rather than config.

Verified the way the plan asked for — `teardown.sh`, then `terraform apply` into
the emptied realm, then `seed.sh`, then `chain.sh` — and the output is identical
to the hand-provisioned tenant, allow for allow and deny for deny. Then a new
user registered through the UI with `payments.admin` only and got the mirror
image of alice: refund allowed, both order capabilities refused.

Two bugs found by doing that, both in the registration script and both invisible
until something went wrong:

- **`action.goTo()` records an outcome; it does not stop the script.** A failed
  `openidm.create` logged the error, set the `error` outcome, and then fell
  through to `action.goTo("created")`. AM issued a session and the caller saw a
  `tokenId` for a user that was never created — the failure surfaced one step
  later as "Resource owner authentication failed", pointing at the wrong thing.
- **No validation of the submitted email or password**, which is how the first
  bug was reachable at all.
