// DB-backed reconcile readers. The autonomous agent reconciles against what the user already tracks
// and has decided BEFORE it proposes, so it never re-surfaces a duplicate or a rejected merchant.
// Until now those readers were empty in-memory stubs (worker.ts wired `inMemoryReconcileReaders({})`);
// this binds them to the real app tables so reconcile actually reflects the user's state.
//
// Pure of `pg`: it depends only on a narrow `SqlRunner` (satisfied by pg.Pool/PoolClient), so it is
// unit-testable with a fake runner and does not couple the reader to the driver.

import { billingCycles, type BillingCycle } from "../domain/email.ts";
import type { PriorDecision, TrackedSubscription } from "./types.ts";
import type { ReconcileReaders } from "./tools.ts";

/** The minimal query surface the readers need. `pg.Pool` and `pg.PoolClient` both satisfy it. */
export type SqlRunner = {
  query(text: string, params: unknown[]): Promise<{ rows: Array<Record<string, unknown>> }>;
};

function coerceCycle(value: unknown): BillingCycle | null {
  return typeof value === "string" && (billingCycles as readonly string[]).includes(value)
    ? (value as BillingCycle)
    : null;
}

function coerceAmount(value: unknown): number | null {
  // pg returns numeric as a string to preserve precision; accept either.
  const n = typeof value === "number" ? value : Number(value);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

function coerceStatus(value: unknown): TrackedSubscription["status"] {
  if (value === "active") return "active";
  if (value === "canceled") return "canceled";
  return "unknown"; // 'paused' (or anything unexpected) → still tracked, but not asserted active
}

/**
 * Reconcile readers bound to the app database for one user.
 *
 * - `listCurrentSubscriptions` reads `subscriptions` (only rows with a canonical merchant key, since
 *   the agent reconciles on that key).
 * - `listPriorDecisions` merges three per-user signals into one decision per merchant key:
 *     suppressions (`merchant_discovery_suppressions`) → disposition 'suppressed' (do not re-propose),
 *     learned field priors (`merchant_review_priors`)  → disposition 'confirmed' + field_priors,
 *     reviewed aliases (`reviewed_merchant_aliases`)   → alternate labels merged into the identity.
 *   Suppression outranks a confirmed prior when both exist for the same merchant.
 */
export function createPgReconcileReaders(runner: SqlRunner, userId: string): ReconcileReaders {
  return {
    async listCurrentSubscriptions(): Promise<TrackedSubscription[]> {
      const { rows } = await runner.query(
        `select canonical_merchant_key, name, price, currency, billing_cycle, status
           from subscriptions
          where user_id = $1 and canonical_merchant_key is not null`,
        [userId],
      );
      return rows.map((row) => ({
        merchant_key: String(row.canonical_merchant_key),
        merchant_name: String(row.name ?? ""),
        amount: coerceAmount(row.price),
        currency: typeof row.currency === "string" ? row.currency : null,
        billing_cycle: coerceCycle(row.billing_cycle),
        status: coerceStatus(row.status),
      }));
    },

    async listPriorDecisions(merchant?: string): Promise<PriorDecision[]> {
      const [suppressed, priors, aliases] = await Promise.all([
        runner.query(
          `select canonical_merchant_key
             from merchant_discovery_suppressions
            where user_id = $1`,
          [userId],
        ),
        runner.query(
          `select canonical_merchant_key, field, value
             from merchant_review_priors
            where user_id = $1`,
          [userId],
        ),
        runner.query(
          `select alias_key, canonical_merchant_key
             from reviewed_merchant_aliases
            where user_id = $1`,
          [userId],
        ),
      ]);

      type Acc = {
        disposition: PriorDecision["disposition"];
        field_priors: Record<string, string | number>;
        aliases: string[];
      };
      const byKey = new Map<string, Acc>();
      const ensure = (key: string): Acc => {
        let acc = byKey.get(key);
        if (!acc) {
          acc = { disposition: "confirmed", field_priors: {}, aliases: [] };
          byKey.set(key, acc);
        }
        return acc;
      };

      for (const row of priors.rows) {
        const key = String(row.canonical_merchant_key);
        const field = typeof row.field === "string" ? row.field : null;
        if (!field) continue;
        ensure(key).field_priors[field] = String(row.value);
      }
      for (const row of aliases.rows) {
        const key = String(row.canonical_merchant_key);
        const alias = typeof row.alias_key === "string" ? row.alias_key : null;
        if (alias) ensure(key).aliases.push(alias);
      }
      // Suppression is the strongest signal — apply last so it wins over a 'confirmed' default.
      for (const row of suppressed.rows) {
        ensure(String(row.canonical_merchant_key)).disposition = "suppressed";
      }

      const all: PriorDecision[] = [...byKey.entries()].map(([merchant_key, acc]) => ({
        merchant_key,
        disposition: acc.disposition,
        field_priors: acc.field_priors,
        aliases: acc.aliases,
      }));
      return merchant ? all.filter((decision) => decision.merchant_key === merchant) : all;
    },
  };
}
