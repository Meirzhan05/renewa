import { defineConfig } from "@trigger.dev/sdk";

const project = process.env.TRIGGER_PROJECT_REF;
if (!project) {
  throw new Error("TRIGGER_PROJECT_REF is required to run or deploy managed Inbox tasks.");
}

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
