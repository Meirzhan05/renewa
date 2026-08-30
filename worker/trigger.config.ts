import { defineConfig } from "@trigger.dev/sdk";

// The project ref is not a secret (it appears in the dashboard URL). `deploy` re-evaluates this config
// inside a build container where shell/.env vars are NOT present, so an env-only value fails at the
// indexing step. Default to the literal and let an env var override it for other environments.
const project = process.env.TRIGGER_PROJECT_REF ?? "proj_thnhxhlhichpevzngyyf";

export default defineConfig({
  project,
  dirs: ["./src/trigger"],
  maxDuration: 3_600,
  retries: {
    // Development must exercise the same bounded transient-failure recovery as production.
    // Disabling this leaves a page task queued forever after a one-off gateway outage.
    enabledInDev: true,
    default: {
      maxAttempts: 3,
      minTimeoutInMs: 2_000,
      maxTimeoutInMs: 30_000,
      factor: 2,
      randomize: true,
    },
  },
});
