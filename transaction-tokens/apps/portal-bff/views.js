// Server-rendered HTML. No framework, no build step — the interesting part
// of this demo is the token and the decision, and neither is easier to read
// through a bundler.
const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

const json = (v) => esc(JSON.stringify(v, null, 2));

const CSS = `
:root { color-scheme: light dark; --line: #8883; --ok: #1a7f37; --no: #b3261e; --dim: #7a7a7a; }
* { box-sizing: border-box; }
body { font: 15px/1.55 ui-sans-serif, system-ui, sans-serif; margin: 0 auto; padding: 2rem 1.25rem 4rem;
       max-width: 54rem; }
h1 { font-size: 1.4rem; margin: 0 0 .25rem; }
h2 { font-size: 1.05rem; margin: 2rem 0 .6rem; }
.sub { color: var(--dim); margin: 0 0 2rem; }
.warn { border: 1px solid var(--no); border-left-width: 4px; padding: .7rem .9rem; margin: 0 0 1.5rem;
        border-radius: 4px; font-size: .9rem; }
.card { border: 1px solid var(--line); border-radius: 6px; padding: 1rem 1.1rem; margin: 0 0 1rem; }
.row { display: flex; gap: .6rem; flex-wrap: wrap; align-items: center; }
label { display: block; margin: .6rem 0 .2rem; font-weight: 600; font-size: .85rem; }
input[type=text], input[type=password], input[type=number] { width: 100%; padding: .45rem .55rem;
        border: 1px solid var(--line); border-radius: 4px; background: transparent; color: inherit;
        font: inherit; }
button { padding: .45rem .9rem; border: 1px solid var(--line); border-radius: 4px; background: transparent;
        color: inherit; font: inherit; cursor: pointer; }
button.primary { border-color: currentColor; font-weight: 600; }
pre { background: #8881; padding: .7rem .8rem; border-radius: 4px; overflow-x: auto; font-size: .8rem;
      margin: .4rem 0 0; }
.present { color: var(--ok); font-weight: 600; }
.absent { color: var(--no); font-weight: 600; }
.meta { color: var(--dim); font-size: .85rem; }
a { color: inherit; }
.hops { display: grid; gap: .9rem; grid-template-columns: repeat(auto-fit, minmax(15rem, 1fr)); }
.hop { border: 1px solid var(--line); border-radius: 6px; padding: .7rem .8rem; }
.hop h3 { margin: 0 0 .3rem; font-size: .9rem; }
.hop ul { margin: .35rem 0 .5rem; padding-left: 1.1rem; font-size: .78rem; color: var(--dim); }
.hash { font-family: ui-monospace, monospace; font-size: .72rem; word-break: break-all; }
.same { border: 1px solid var(--ok); border-left-width: 4px; padding: .55rem .8rem; border-radius: 4px;
        font-size: .85rem; margin: 0 0 1rem; }
`;

export function page(title, body) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><style>${CSS}</style></head><body>
<h1>Transaction tokens</h1>
<p class="sub">A demo of <code>draft-ietf-oauth-transaction-tokens</code> on
PingOne Advanced Identity Cloud. Your sign-in token never leaves this server;
every activity you post mints a fresh 60-second Txn-Token that carries the
decision, not your credentials, across two more services.</p>
${body}
</body></html>`;
}

export function loginPage(error) {
  return page(
    "Sign in",
    `${error ? `<div class="warn">${esc(error)}</div>` : ""}
<form method="post" action="/login" class="card">
  <label for="username">Username</label>
  <input type="text" id="username" name="username" value="am-alice" required>
  <label for="password">Password</label>
  <input type="password" id="password" name="password" required>
  <p class="row" style="margin-top:1rem"><button class="primary" type="submit">Sign in</button></p>
</form>`,
  );
}

function trailCard(result) {
  if (!result) return "";
  const t = result.tctx ?? {};
  const costLine = "cost_cents" in t
    ? `<span class="present">cost_cents present: ${esc(t.cost_cents)}</span>`
    : `<span class="absent">cost_cents refused by the issuance policy</span>`;
  return `<div class="card">
  <h2>Last activity</h2>
  <p>${costLine}${result.ledger?.replay ? " <span class=\"meta\">(replay of an existing txn)</span>" : ""}</p>
  <pre>${json(t)}</pre>
  <p class="meta">Recorded by the ledger: <code>${esc(result.ledger?.entry?.txn ?? "—")}</code>
  ${result.ledger?.entry?.txn ? `· <a href="/trail/${encodeURIComponent(result.ledger.entry.txn)}">see it at every hop</a>` : ""}</p>
</div>`;
}

// The side-by-side view: one column per hop, the same decoded payload and
// the same token hash down the row. Identical hashes are the evidence the
// token was forwarded unchanged; no column ever shows the token itself.
export function trailPage({ txn, unchanged, complete, sources, hops, flow }) {
  const cards = hops
    .map(
      (h) => `<div class="hop">
  <h3>${esc(h.hop)}</h3>
  <p class="meta">called by ${esc(h.workload)}</p>
  <p class="hash">${esc(h.token_hash)}</p>
  <ul>${h.validated.map((v) => `<li>${esc(v)}</li>`).join("")}</ul>
  <p class="meta"><strong>decided:</strong> ${esc(h.decided)}</p>
  <pre>${json(h.payload?.tctx ?? {})}</pre>
</div>`,
    )
    .join("");
  return page(
    "Transaction trail",
    `<p class="meta"><a href="/">&larr; back</a> · txn <code>${esc(txn)}</code>${
      flow ? ` · started at: ${esc(flow)}` : ""
    }</p>
${
  unchanged
    ? `<p class="same">Every hop in this chain reported, and all of them saw the same token hash — the
       Txn-Token was forwarded unmodified from the moment AIC minted it. Nothing below is a
       complete token: a hash for correlation, and the decoded <code>tctx</code> with the
       signature stripped.</p>`
    : !complete
      ? `<div class="warn">Not every hop reported, so this proves nothing either way.
         ${esc(
           (sources ?? [])
             .filter((s) => s.status !== "ok")
             .map((s) => `${s.name}: ${s.status}${s.detail ? ` (${s.detail})` : ""}`)
             .join(" · "),
         )}</div>`
      : `<div class="warn">The hops did not all see the same token. That should not happen —
         no hop is supposed to re-issue.</div>`
}
<div class="hops">${cards}</div>`,
  );
}

export function dashboard({ user, result, error }) {
  return page(
    "Post an activity",
    `<p class="meta">Signed in as <code>${esc(user)}</code> · <a href="/logout">sign out</a></p>
${error ? `<div class="warn">${esc(error)}</div>` : ""}
<form method="post" action="/activities" class="card">
  <label for="client_ref">Client</label>
  <input type="text" id="client_ref" name="client_ref" value="client-4471" required>
  <label for="activity_type">Activity type</label>
  <input type="text" id="activity_type" name="activity_type" value="advisory" required>
  <label for="delivered_on">Delivered on</label>
  <input type="text" id="delivered_on" name="delivered_on" value="2026-08-31" required>
  <label for="cost_cents">Cost (cents)</label>
  <input type="number" id="cost_cents" name="cost_cents" value="45000">
  <label for="note">Note (free text — never trusted, see below)</label>
  <input type="text" id="note" name="note" placeholder="Optional">
  <p class="row" style="margin-top:1rem"><button class="primary" type="submit">Post activity</button></p>
</form>
${trailCard(result)}
<p class="meta">The note above travels in the request body, never in <code>tctx</code> —
downstream reads cost and type from the token; if the body disagrees, the body loses.</p>`,
  );
}
