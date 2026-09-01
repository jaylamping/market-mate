#!/usr/bin/env node
// Localhost-bound, display-only start guard for the Market Mate dashboard.
// Market Mate refuses any configuration that would expose the dashboard
// beyond localhost or grant it authority; see WU-46.

import { spawn } from "node:child_process";

const containerMode = process.env.MM_DASHBOARD_CONTAINER_LOOPBACK_PUBLISHED === "1";
const dashboardVariables = Object.keys(process.env).filter((name) =>
  name.startsWith("MM_DASHBOARD_"),
);
const allowedVariables = containerMode
  ? ["MM_DASHBOARD_CONTAINER_LOOPBACK_PUBLISHED"]
  : [];
const refused = dashboardVariables.filter(
  (name) => !allowedVariables.includes(name),
);

if (refused.length > 0) {
  console.error(
    `config refused: unsupported dashboard configuration ${refused.join(", ")}; ` +
      "the Market Mate dashboard is localhost-bound and display-only.",
  );
  process.exit(2);
}

const hostname = containerMode ? "0.0.0.0" : "127.0.0.1";
const child = spawn("next", ["start", "--hostname", hostname], {
  stdio: "inherit",
});
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => child.kill(signal));
}
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 1);
});
