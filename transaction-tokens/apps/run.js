// Starts the three long-running services together, so a presenter runs one
// command. accrual-job is not one of them — it is a one-shot run
// (`npm run job`), not a server, matching how the real nightly job runs.
//
// Either child exiting takes the others down — a half-running demo is worse
// than a stopped one, because the failure shows up as a validation error two
// hops away from its actual cause.
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const children = ["ledger-service", "activity-api", "portal-bff"].map((name) =>
  spawn(process.execPath, [join(here, name, "server.js")], { stdio: "inherit" }),
);

const stopAll = () => children.forEach((c) => c.kill("SIGTERM"));
for (const child of children) child.on("exit", (code) => { stopAll(); process.exit(code ?? 0); });
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, stopAll);
