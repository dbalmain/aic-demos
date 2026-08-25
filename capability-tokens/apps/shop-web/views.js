// Server-rendered HTML. No framework, no build step — the interesting part of
// this demo is the token and the decision, and neither is easier to read
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
input[type=text], input[type=password] { width: 100%; padding: .45rem .55rem; border: 1px solid var(--line);
        border-radius: 4px; background: transparent; color: inherit; font: inherit; }
button { padding: .45rem .9rem; border: 1px solid var(--line); border-radius: 4px; background: transparent;
        color: inherit; font: inherit; cursor: pointer; }
button.primary { border-color: currentColor; font-weight: 600; }
pre { background: #8881; padding: .7rem .8rem; border-radius: 4px; overflow-x: auto; font-size: .8rem;
      margin: .4rem 0 0; }
.allow { color: var(--ok); font-weight: 600; }
.deny { color: var(--no); font-weight: 600; }
.meta { color: var(--dim); font-size: .85rem; }
table { border-collapse: collapse; width: 100%; font-size: .9rem; }
td, th { text-align: left; padding: .3rem .6rem .3rem 0; vertical-align: top; }
a { color: inherit; }
`;

export function page(title, body) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><style>${CSS}</style></head><body>
<h1>Capability tokens</h1>
<p class="sub">A demo on PingOne Advanced Identity Cloud. Your session token can
do nothing; each action mints a 60-second token for that action alone, and the
API asks AM's policy engine whether to allow it.</p>
${body}
</body></html>`;
}

export function loginPage(error, offeredRoles = []) {
  const checkboxes = offeredRoles
    .map(
      (r) => `<label style="font-weight:400"><input type="checkbox" name="roles" value="${esc(r)}"
        ${r === "orders.reader" ? "checked" : ""}> <code>${esc(r)}</code></label>`,
    )
    .join("");
  return page(
    "Sign in",
    `${error ? `<div class="warn">${esc(error)}</div>` : ""}
<form method="post" action="/login" class="card">
  <h2 style="margin-top:0">Sign in</h2>
  <label for="u">Username</label>
  <input id="u" name="username" type="text" value="alice@captoken.demo" autocomplete="username">
  <label for="p">Password</label>
  <input id="p" name="password" type="password" autocomplete="current-password">
  <div class="row" style="margin-top:1rem">
    <button class="primary" type="submit">Sign in</button>
    <span class="meta">alice holds orders.reader + orders.approver; bob holds orders.reader only.</span>
  </div>
</form>

<form method="post" action="/register" class="card">
  <h2 style="margin-top:0">Or register</h2>
  <div class="warn" style="margin:.2rem 0 .8rem">
    <strong>Never do this.</strong> Letting people choose their own authorization
    roles at sign-up is a privilege-escalation hole. It is here so you can create
    a user, tick a capability, and watch the policy engine change its answer —
    nothing in the capability-token pattern needs it.
  </div>
  <label for="ru">Email address</label>
  <input id="ru" name="username" type="text" placeholder="you@captoken.demo" autocomplete="off">
  <label for="rp">Password</label>
  <input id="rp" name="password" type="password" autocomplete="new-password">
  <label>Roles</label>
  <div class="row">${checkboxes}</div>
  <div class="row" style="margin-top:1rem">
    <button class="primary" type="submit">Register and sign in</button>
  </div>
</form>`,
  );
}

function tokenCard(label, claims, note) {
  return `<div class="card">
  <h2 style="margin-top:0">${esc(label)}</h2>
  <table>
    <tr><th>subject</th><td>${esc(claims.sub)}</td></tr>
    <tr><th>scope</th><td><code>${esc(JSON.stringify(claims.scope ?? []))}</code></td></tr>
    <tr><th>roles</th><td><code>${esc(JSON.stringify(claims.demoRoles ?? []))}</code></td></tr>
    <tr><th>expires</th><td>${esc(claims.exp - claims.iat)}s after issue</td></tr>
  </table>
  ${note ? `<p class="meta" style="margin:.7rem 0 0">${note}</p>` : ""}
</div>`;
}

export function dashboard({ user, identityClaims, result }) {
  const actions = [
    ["read", "orders.read", "Read order 123", "/orders/123"],
    ["approve", "orders.approve", "Approve order 123", "/orders/123"],
    ["refund", "payments.refund", "Refund payment 9", "/payments/9"],
  ];
  const buttons = actions
    .map(
      ([action, capability, label]) => `<form method="post" action="/act" style="display:inline">
      <input type="hidden" name="action" value="${action}">
      <input type="hidden" name="capability" value="${capability}">
      <button type="submit">${esc(label)}</button></form>`,
    )
    .join(" ");

  return page(
    "Dashboard",
    `<div class="card row" style="justify-content:space-between">
  <div>Signed in as <strong>${esc(user)}</strong></div>
  <form method="post" action="/logout"><button type="submit">Sign out</button></form>
</div>
${tokenCard(
  "Your session token",
  identityClaims,
  "Scope <code>openid</code> and nothing else. The sign-in client is not " +
    "allowed to request a capability, so this token cannot be used against the API at all.",
)}
<h2>Do something</h2>
<p class="meta">Each button mints a fresh capability token for that one action, then calls the API with it.</p>
<div class="row" style="margin:.6rem 0 0">${buttons}</div>
${result ?? ""}`,
  );
}

export function resultCard({ capability, minted, capClaims, response, status }) {
  const allowed = status >= 200 && status < 300;
  const verdict = allowed
    ? `<span class="allow">allowed</span>`
    : `<span class="deny">denied</span>`;

  const mintLine = minted
    ? `Minted <code>${esc(JSON.stringify(capClaims.scope))}</code>, good for
       ${esc(capClaims.exp - capClaims.iat)} seconds.`
    : `<span class="deny">The exchange refused to mint it.</span> The scope policies say this
       user may not hold <code>${esc(capability)}</code>, so the token came back with no
       capability at all — the API was never called.`;

  return `<h2>Result — ${verdict}</h2>
<div class="card">
  <p style="margin:0 0 .5rem"><strong>1. Mint</strong> — asked for <code>${esc(capability)}</code>. ${mintLine}</p>
  ${
    minted
      ? `<p style="margin:.6rem 0 .3rem"><strong>2. Call</strong> — the API verified the token,
         then asked the policy engine. HTTP ${esc(status)}.</p>
     <pre>${json(response)}</pre>`
      : ""
  }
</div>`;
}
