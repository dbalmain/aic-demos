# Walkthrough

Fifteen minutes, four beats. Everything below is live against the tenant; there
is no scripted output.

Start it:

```sh
scripts/provision.sh     # once — idempotent, safe to re-run
cd apps && npm install && npm run dev
```

Then open <http://127.0.0.1:8790>.

---

## 1. The session token can't do anything

Sign in as **alice@captoken.demo**. The dashboard shows her token:

```
scope   ["openid"]
roles   ["orders.reader","orders.approver"]
```

She holds two roles, and the token holds no capability. Point at the *sign-in
client* to say why: it is allowed `openid` and `profile` and nothing else, so
this token could not have carried a capability even if the app had asked. If
this token leaked, it would buy an attacker nothing.

> Worth saying out loud: this is the part most OAuth deployments get backwards.
> The long-lived token is usually the powerful one.

## 2. One action, one capability, sixty seconds

Press **Approve order 123**. Behind the button:

- the BFF calls the token endpoint with `grant_type=…:token-exchange`,
  presenting alice's session token and asking for `orders.approve`;
- AM issues a token whose scope is exactly `["orders.approve"]`, valid **60
  seconds**;
- the API gets that token, and only that.

The 60 seconds are not a setting on the exchange — there is no such setting.
They come from the *caller* client, a second OAuth2 client that exists only to
make outbound calls. That is the pattern's shape: **one client per layer**, and
`may_act` on the session token names which one is allowed to act.

## 3. The API doesn't decide — it asks

Expand the result. `trail.question` is the exact question the API put to AM:

```json
{ "resource": "https://shop-api.demo:443/orders/123",
  "action": "approve", "application": "CapTokenDemo" }
```

and `trail.answer` is AM's reply. The API contains no rule about who may
approve an order. To prove it, change the policy in AM and press the button
again — no restart, no deploy:

```sh
# Suspend the approve policy and watch the same click start failing.
scripts/aicurl.sh GET  "/am/json/realms/root/realms/bravo/policies/CapTokenDemo_OrdersApprove" \
  --apiver protocol=1.0,resource=2.0 > /tmp/p.json
jq '.active=false' /tmp/p.json > /tmp/p-off.json
scripts/aicurl.sh PUT  "/am/json/realms/root/realms/bravo/policies/CapTokenDemo_OrdersApprove" \
  --apiver protocol=1.0,resource=2.0 --data "$(cat /tmp/p-off.json)"
```

Re-enable it with the original `/tmp/p.json` afterwards.

## 4. Two gates, and they refuse differently

Still as alice, press **Refund payment 9**. The result reads:

> The exchange refused to mint it… the API was never called.

That is **gate A** — the mint-time gate. Alice has no `payments.admin` role, so
AM would not issue her the capability at all, and there was nothing to send.

Now sign out, **register** a new user, and tick only `payments.admin`. Same
button, and now it works — while *Approve* stops working. Nothing was
configured between those two runs; the policies read the roles out of the
token.

Gate B is the other refusal: a token that *does* carry a capability, presented
for something that capability does not cover. Both are the policy engine; they
just catch different mistakes.

---

## The bit worth staying for

The API verifies the token before it asks AM anything. That is not ceremony —
AM's policy endpoint checks **neither the signature nor the expiry** of a
`subject.jwt`. Show it:

```sh
# a genuine read-only token for bob, with its claims rewritten to say "approve"
curl -s -X POST -H "Authorization: Bearer $FORGED" \
  http://127.0.0.1:8791/orders/123/approve
# → 401 {"error":"token rejected: signature verification failed"}

# the same forged token, asked of AM's policy engine directly
scripts/aicurl.sh POST "/am/json/realms/root/realms/bravo/policies?_action=evaluate" \
  --apiver protocol=1.0,resource=2.0 \
  --data '{"resources":["https://shop-api.demo:443/orders/123"],
           "application":"CapTokenDemo","subject":{"jwt":"'"$FORGED"'"}}'
# → {"approve": true}
```

The PDP answers a hypothetical: *if these claims were true, what would be
allowed?* Establishing that they are true is the resource server's job, and a
PEP that skips it has built an open door with a policy engine bolted to it.

(The token endpoint is not like this — a forged `subject_token` is rejected
outright. It is `?_action=evaluate` specifically.)

## Registration is the demo's deliberate hole

Letting people choose their own authorization roles at sign-up is a
privilege-escalation vulnerability. It is in the demo so a viewer can change
the outcome in ten seconds without an admin console, and the page says so. The
journey bounds the choice to the demo's three capability roles, so it is "pick
from this menu" rather than "name any role in the realm" — but do not carry
either into anything real.
