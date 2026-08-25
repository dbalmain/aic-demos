// Start both services together, so a presenter runs one command.
// Either child exiting takes the other down — a half-running demo is worse
// than a stopped one, because the failure shows up as a policy denial.
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const children = ["shop-api", "shop-web"].map((name) =>
  spawn(process.execPath, [join(here, name, "server.js")], { stdio: "inherit" }),
);

const stopAll = () => children.forEach((c) => c.kill("SIGTERM"));
for (const child of children) child.on("exit", (code) => { stopAll(); process.exit(code ?? 0); });
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, stopAll);
