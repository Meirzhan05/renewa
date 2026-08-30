import assert from "node:assert/strict";
import { test } from "node:test";
import { claimManagedPageContext, processManagedConnection } from "../src/managed/edge-client.ts";

test("managed page context sends opaque ids and the service credential only", async () => {
  const previousURL = process.env.SUPABASE_URL;
  const previousSecret = process.env.MANAGED_AGENT_SHARED_SECRET;
  const previousPublicKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  process.env.SUPABASE_URL = "https://dev.example.test";
  process.env.MANAGED_AGENT_SHARED_SECRET = "shared-development-secret";
  process.env.SUPABASE_PUBLISHABLE_KEY = "public-development-key";
  let request: Request | undefined;
  try {
    const result = await claimManagedPageContext(
      { version: 1, scanRunId: "run-1", pageId: "page-1" },
      "trigger-run-1",
      async (input, init) => {
        request = new Request(input, init);
        return Response.json({ execution_id: "execution-1", access_token: "short-lived" });
      },
    );
    assert.deepEqual(result, { cancelled: false, executionId: "execution-1", accessToken: "short-lived" });
    assert.equal(request?.headers.get("x-renewa-managed-agent-secret"), "shared-development-secret");
    assert.equal(request?.headers.get("apikey"), "public-development-key");
    assert.deepEqual(await request?.json(), {
      action: "managed_page_context", scan_run_id: "run-1", scan_job_id: "page-1", runtime_task_id: "trigger-run-1",
    });
  } finally {
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousSecret === undefined) delete process.env.MANAGED_AGENT_SHARED_SECRET;
    else process.env.MANAGED_AGENT_SHARED_SECRET = previousSecret;
    if (previousPublicKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY;
    else process.env.SUPABASE_PUBLISHABLE_KEY = previousPublicKey;
  }
});

test("managed orchestrator asks the Edge Function to process the next opaque page", async () => {
  const previousURL = process.env.SUPABASE_URL;
  const previousSecret = process.env.MANAGED_AGENT_SHARED_SECRET;
  const previousPublicKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  process.env.SUPABASE_URL = "https://dev.example.test";
  process.env.MANAGED_AGENT_SHARED_SECRET = "shared-development-secret";
  process.env.SUPABASE_PUBLISHABLE_KEY = "public-development-key";
  try {
    const result = await processManagedConnection(
      { version: 1, scanRunId: "run-1", connectionId: "connection-1" },
      async (input, init) => {
        const request = new Request(input, init);
        assert.deepEqual(await request.json(), {
          action: "managed_process_connection", scan_run_id: "run-1", connection_id: "connection-1",
        });
        return Response.json({ has_next_page: true });
      },
    );
    assert.deepEqual(result, { cancelled: false, hasNextPage: true });
  } finally {
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousSecret === undefined) delete process.env.MANAGED_AGENT_SHARED_SECRET;
    else process.env.MANAGED_AGENT_SHARED_SECRET = previousSecret;
    if (previousPublicKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY;
    else process.env.SUPABASE_PUBLISHABLE_KEY = previousPublicKey;
  }
});
