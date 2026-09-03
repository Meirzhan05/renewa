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
      { version: 2, scanRunId: "run-1", pageId: "page-1", executionId: "execution-1", dispatchToken: "token-1" },
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
      action: "managed_page_context", scan_run_id: "run-1", scan_job_id: "page-1", execution_id: "execution-1", dispatch_token: "token-1", runtime_task_id: "trigger-run-1",
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
      { version: 2, scanRunId: "run-1", connectionId: "connection-1" },
      async (input, init) => {
        const request = new Request(input, init);
        assert.deepEqual(await request.json(), {
          action: "managed_process_connection", scan_run_id: "run-1", connection_id: "connection-1",
        });
        return Response.json({ has_next_page: true, page_id: "page-1" });
      },
    );
    // `retryAfterMs: 0` on the ordinary path — the Edge Function only sends a delay when it has
    // re-queued a page behind a backoff.
    assert.deepEqual(result, {
      cancelled: false,
      hasNextPage: true,
      pageId: "page-1",
      retryAfterMs: 0,
    });
  } finally {
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousSecret === undefined) delete process.env.MANAGED_AGENT_SHARED_SECRET;
    else process.env.MANAGED_AGENT_SHARED_SECRET = previousSecret;
    if (previousPublicKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY;
    else process.env.SUPABASE_PUBLISHABLE_KEY = previousPublicKey;
  }
});

test("managed tasks normalize a legacy Supabase REST URL before calling Edge Functions", async () => {
  const previousURL = process.env.SUPABASE_URL;
  const previousSecret = process.env.MANAGED_AGENT_SHARED_SECRET;
  const previousPublicKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  process.env.SUPABASE_URL = "https://dev.example.test/rest/v1/";
  process.env.MANAGED_AGENT_SHARED_SECRET = "shared-development-secret";
  process.env.SUPABASE_PUBLISHABLE_KEY = "public-development-key";
  try {
    await processManagedConnection(
      { version: 2, scanRunId: "run-1", connectionId: "connection-1" },
      async (input) => {
        assert.equal(input, "https://dev.example.test/functions/v1/email-scan");
        return Response.json({ has_next_page: false });
      },
    );
  } finally {
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousSecret === undefined) delete process.env.MANAGED_AGENT_SHARED_SECRET;
    else process.env.MANAGED_AGENT_SHARED_SECRET = previousSecret;
    if (previousPublicKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY;
    else process.env.SUPABASE_PUBLISHABLE_KEY = previousPublicKey;
  }
});

test("managed page context retries a short Edge service outage before claiming work", async () => {
  const previousURL = process.env.SUPABASE_URL;
  const previousSecret = process.env.MANAGED_AGENT_SHARED_SECRET;
  const previousPublicKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  process.env.SUPABASE_URL = "https://dev.example.test";
  process.env.MANAGED_AGENT_SHARED_SECRET = "shared-development-secret";
  process.env.SUPABASE_PUBLISHABLE_KEY = "public-development-key";
  let calls = 0;
  try {
    const result = await claimManagedPageContext(
      { version: 2, scanRunId: "run-1", pageId: "page-1", executionId: "execution-1", dispatchToken: "token-1" },
      "trigger-run-1",
      async () => {
        calls += 1;
        if (calls === 1) return Response.json({ message: "Service is temporarily unavailable" }, { status: 503 });
        return Response.json({ execution_id: "execution-1", access_token: "short-lived" });
      },
    );
    assert.equal(calls, 2);
    assert.deepEqual(result, { cancelled: false, executionId: "execution-1", accessToken: "short-lived" });
  } finally {
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousSecret === undefined) delete process.env.MANAGED_AGENT_SHARED_SECRET;
    else process.env.MANAGED_AGENT_SHARED_SECRET = previousSecret;
    if (previousPublicKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY;
    else process.env.SUPABASE_PUBLISHABLE_KEY = previousPublicKey;
  }
});

test("a deferred page reports how long to hold off", async () => {
  const previousURL = process.env.SUPABASE_URL;
  const previousSecret = process.env.MANAGED_AGENT_SHARED_SECRET;
  const previousPublicKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  process.env.SUPABASE_URL = "https://dev.example.test";
  process.env.MANAGED_AGENT_SHARED_SECRET = "shared-development-secret";
  process.env.SUPABASE_PUBLISHABLE_KEY = "public-development-key";
  try {
    // A page re-queued behind a backoff: still more work to do, but no page was admitted this pass.
    const deferred = await processManagedConnection(
      { version: 2, scanRunId: "run-1", connectionId: "connection-1" },
      async () => Response.json({ has_next_page: true, retry_after_ms: 4000 }),
    );
    assert.deepEqual(deferred, {
      cancelled: false,
      hasNextPage: true,
      pageId: null,
      retryAfterMs: 4000,
    });

    // A nonsensical delay must not become a wait; treat it as no delay rather than trusting it.
    for (const bad of [-1, 0, "soon", null]) {
      const result = await processManagedConnection(
        { version: 2, scanRunId: "run-1", connectionId: "connection-1" },
        async () => Response.json({ has_next_page: true, retry_after_ms: bad }),
      );
      assert.equal(result.retryAfterMs, 0, `retry_after_ms ${JSON.stringify(bad)} must read as 0`);
    }
  } finally {
    if (previousURL === undefined) delete process.env.SUPABASE_URL; else process.env.SUPABASE_URL = previousURL;
    if (previousSecret === undefined) delete process.env.MANAGED_AGENT_SHARED_SECRET;
    else process.env.MANAGED_AGENT_SHARED_SECRET = previousSecret;
    if (previousPublicKey === undefined) delete process.env.SUPABASE_PUBLISHABLE_KEY;
    else process.env.SUPABASE_PUBLISHABLE_KEY = previousPublicKey;
  }
});
