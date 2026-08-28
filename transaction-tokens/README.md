# Transaction tokens on PingOne AIC

A proof of concept for `draft-ietf-oauth-transaction-tokens-11`: the account
manager's access token stops at the edge, and a 60-second **Txn-Token** carries
the authorized intent of one business transaction across four internal
services — reaching the last one byte for byte identical to how it left the
first.

**Status: design.** Nothing is built. Read
[`ARCHITECTURE.md`](ARCHITECTURE.md) — or the rendered
[`docs/architecture.html`](docs/architecture.html) — and answer the open
questions at the end of it.

The brief this is built from is [`docs/brief.md`](docs/brief.md).

## Layout

| Path | What goes there |
| --- | --- |
| `apps/` | portal + BFF, the TTS, the activity API, the ledger, the nightly job |
| `terraform/` | the AIC config: OAuth2 clients, the issuance policies, any scripts |
| `scripts/` | seed data and the local run/teardown helpers |
| `docs/` | the brief, the architecture, and the departures-from-the-draft log |

Same approach as [`../capability-tokens/`](../capability-tokens/): Terraform
owns the tenant configuration, a small script owns the IDM fixtures, and the
tenant hostname and secrets live in a gitignored `.env`.
