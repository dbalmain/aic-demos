# aic-demos

Self-contained demos of identity patterns on **PingOne Advanced Identity Cloud**
(AIC, formerly ForgeRock Identity Cloud). Each demo builds its own tenant
configuration from nothing, runs, and tears itself back down.

| Demo | What it shows |
| --- | --- |
| [`capability-tokens/`](capability-tokens/) | RFC 8693 token exchange minting short-lived single-capability tokens, with AM's policy engine as the decision point |
| [`transaction-tokens/`](transaction-tokens/) | *(design)* `draft-ietf-oauth-transaction-tokens-11` — one token carrying authorized intent across four internal hops, unchanged |

Every demo needs a tenant and the [`aic`](https://github.com/dbalmain/pingone-aic-manager)
CLI to talk to it. Tenant hostnames, client secrets and passwords are
customer-identifying: they live in a gitignored `.env` per demo, never in the
repo.
