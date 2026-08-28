## Transaction Token POC

Build a proof of concept demonstrating the **Transaction Token** pattern from `draft-ietf-oauth-transaction-tokens-11` (IETF OAuth WG). Pragmatic, not a conformance implementation — the goal is to make the token flow legible and let us reason about the design.

### Domain

An **account management portal**. Account managers log in and record activities delivered to their clients — activity type, cost, date delivered, and a free-text note.

Deliberately mundane; the point is the token flow, not the domain.

### Architecture

```
Portal (SPA)
    │  access token
    ▼
BFF ──── token exchange ────► TTS
    │                          │
    │◄──────  Txn-Token  ──────┘
    ▼
Activity API ──► Ledger Service ──► Store
```

Four services: a portal, a BFF, a Transaction Token Service, and at least two chained downstream services so we can watch a token propagate more than one hop.

### What the POC must demonstrate

**1. Exchange at the edge.** The BFF holds the account manager's access token and exchanges it at the TTS for a Txn-Token. Use RFC 8693 token exchange shape: `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`, `requested_token_type=urn:ietf:params:oauth:token-type:txn_token`, plus `audience`, `scope`, `subject_token`, `subject_token_type`, and the two draft-specific parameters `request_context` and `request_details` (both JSON objects). Response: `token_type: "N_A"`, `issued_token_type` set to the txn_token URN, and the JWT in the `access_token` field. Add a code comment noting that field name is RFC 8693 plumbing and the value is emphatically **not** an access token.

**2. Token shape.** Signed JWT, `typ: "txntoken+jwt"`, with:

| Claim        |                                                                                                     |
| ------------ | --------------------------------------------------------------------------------------------------- |
| `iat`, `exp` | short lifetime — 60s or less                                                                        |
| `aud`        | the **trust domain**, not a service                                                                 |
| `txn`        | unique transaction id                                                                               |
| `sub`        | account manager, unique within the trust domain                                                     |
| `scope`      | internal intent e.g. `client:activity:write` — deliberately different from the portal's OAuth scope |
| `req_wl`     | the workload that requested it (the BFF)                                                            |
| `tctx`       | authorization detail: activity type, cost, date delivered                                           |
| `rctx`       | environmental: originating IP, authn method, portal identifier                                      |

`iss` optional. Do **not** embed the incoming access token anywhere in the Txn-Token.

**3. TTS is authoritative over `tctx`.** The BFF _proposes_ via `request_details`; the TTS decides what lands in `tctx`. Demonstrate this concretely by having the TTS enrich — add at least one computed claim not present in the request (e.g. a derived client tier or an approval threshold flag). Downstream services read the integrity-critical parameters from `tctx`, not from the request body. Free-text notes stay in the body.

**4. Scope narrowing, enforced.** The TTS must reject any request whose Txn-Token scope would exceed the scope carried by the subject token. If the subject token's scope can't be determined at all, reject — never treat unknown as unconstrained. Include a test for both.

**5. Two headers, two subjects.** Downstream calls carry workload identity in `Authorization` (may change per hop) and the Txn-Token in a dedicated `Txn-Token` header, passed **unmodified** all the way down. No mid-chain re-issuance.

**6. Validation at every hop.** Each service independently verifies signature, checks `aud` matches its own trust domain, and checks expiry — before doing anything else.

**7. Internally-initiated flow.** A scheduled job that mints a Txn-Token with no inbound user token, using a self-signed JWT as `subject_token` with `subject_token_type: urn:ietf:params:oauth:token-type:self_signed`.

**8. TTS issuance policy.** A simple, visible policy table: which workload may request which scopes, and which may assert which `tctx` fields. The BFF can assert a cost; the scheduled job cannot. This is the real access-control surface of the pattern and the spec leaves it entirely to the implementer — make it obvious and easy to change.

### Observability

This is the point of the POC. Make the flow visible:

- Log at every hop: the `txn` value, which workload, what it validated, what it decided.
- Never log a complete Txn-Token — log a hash for correlation, or the decoded payload with the signature stripped.
- A way to view the decoded token at each hop side by side, so it's obvious the same token traversed the chain unchanged.

### Explicitly out of scope

Real IdP integration (stub the access token), production key management (static dev keys with a `kid` are fine), mTLS/SPIFFE workload identity (stub it, but leave a clear note that the draft requires mutual authentication on the BFF→TTS call because the access token is in flight there), and cross-trust-domain chaining.

### Deliverables

Runnable locally with one command. A README explaining the flow, and a short section listing where the POC knowingly departs from the draft and why.

Ask before choosing anything about stack, framework, storage, or crypto library — those will be supplied.
