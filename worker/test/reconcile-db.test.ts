import { test } from "node:test";
import assert from "node:assert/strict";
import { createPgReconcileReaders, type SqlRunner } from "../src/agent/reconcile-db.ts";

// A fake runner that routes each query to canned rows by sniffing the table it selects from, and
// records the user_id param so we can assert the reader scopes every read to one user.
function fakeRunner(tables: Record<string, Array<Record<string, unknown>>>): {
  runner: SqlRunner;
  userIds: unknown[];
} {
  const userIds: unknown[] = [];
  const runner: SqlRunner = {
    async query(text, params) {
      userIds.push(params[0]);
      const from = /from\s+(\w+)/i.exec(text)?.[1] ?? "";
      return { rows: tables[from] ?? [] };
    },
  };
  return { runner, userIds };
}

test("listCurrentSubscriptions maps app rows into TrackedSubscription and scopes to the user", async () => {
  const { runner, userIds } = fakeRunner({
    subscriptions: [
      { canonical_merchant_key: "netflix", name: "Netflix", price: "15.99", currency: "USD", billing_cycle: "monthly", status: "active" },
      { canonical_merchant_key: "figma", name: "Figma", price: 12, currency: "USD", billing_cycle: "weird", status: "paused" },
    ],
  });
  const readers = createPgReconcileReaders(runner, "user-1");
  const subs = await readers.listCurrentSubscriptions();

  assert.deepEqual(subs, [
    { merchant_key: "netflix", merchant_name: "Netflix", amount: 15.99, currency: "USD", billing_cycle: "monthly", status: "active" },
    // numeric price coerced from number; unknown cycle nulled; 'paused' → 'unknown'
    { merchant_key: "figma", merchant_name: "Figma", amount: 12, currency: "USD", billing_cycle: null, status: "unknown" },
  ]);
  assert.equal(userIds[0], "user-1");
});

test("listPriorDecisions merges suppressions, field priors, and aliases per merchant", async () => {
  const { runner } = fakeRunner({
    merchant_discovery_suppressions: [{ canonical_merchant_key: "spotify" }],
    merchant_review_priors: [
      { canonical_merchant_key: "anthropic", field: "billing_cycle", value: "yearly" },
      { canonical_merchant_key: "anthropic", field: "category", value: "work" },
      { canonical_merchant_key: "spotify", field: "category", value: "entertainment" },
    ],
    reviewed_merchant_aliases: [{ alias_key: "anthropic-pbc", canonical_merchant_key: "anthropic" }],
  });
  const readers = createPgReconcileReaders(runner, "user-1");
  const decisions = await readers.listPriorDecisions();
  const byKey = new Map(decisions.map((d) => [d.merchant_key, d]));

  // A merchant with only learned priors is 'confirmed' and carries its field priors + aliases.
  assert.deepEqual(byKey.get("anthropic"), {
    merchant_key: "anthropic",
    disposition: "confirmed",
    field_priors: { billing_cycle: "yearly", category: "work" },
    aliases: ["anthropic-pbc"],
  });
  // Suppression outranks a confirmed prior for the same merchant.
  assert.equal(byKey.get("spotify")?.disposition, "suppressed");
});

test("listPriorDecisions filters to a single merchant when asked", async () => {
  const { runner } = fakeRunner({
    merchant_review_priors: [
      { canonical_merchant_key: "anthropic", field: "billing_cycle", value: "yearly" },
      { canonical_merchant_key: "notion", field: "category", value: "work" },
    ],
  });
  const readers = createPgReconcileReaders(runner, "user-1");
  const decisions = await readers.listPriorDecisions("notion");
  assert.equal(decisions.length, 1);
  assert.equal(decisions[0]?.merchant_key, "notion");
});
