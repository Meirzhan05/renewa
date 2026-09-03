// Bridges the autonomous agent's proposals into the app's review queue. A proposal is the agent's
// only output; to reach the iOS review UI unchanged it must land as a `detected_billing_events` row
// (the evidence record) and a `subscription_candidates` row (the review card) against the app's scan
// run. A historical scan has many worker pages for one run, so a durable coordinator — not this
// page bridge — owns terminal run completion.
//
// Safety: only the proposal's typed, validated fields are written. There is no free-text passthrough
// from email content (the `evidence` string is synthesized from typed fields only), so the anti-exfil
// wall from `propose.ts` extends all the way to the human-facing card.

import { canonicalMerchantKey, resolveMerchantIdentity } from "../domain/email.ts";
import type { ProposalCandidate } from "./types.ts";
import type { SqlRunner } from "./reconcile-db.ts";

const BILLING_EVENT_TYPES = new Set([
  "created",
  "renewed",
  "price_changed",
  "canceled",
  "trial_started",
  "trial_ending",
]);

export type BridgeInput = {
  userId: string;
  scanRunId: string;
  provider: string; // mail_provider: 'google' | 'microsoft'
  messagesScanned: number;
  proposals: ProposalCandidate[];
  /**
   * `messageId -> sender` for this page's messages, used to resolve merchant identity from WHO BILLED
   * rather than from the model's chosen label. Absent entries fall back to the proposal's own key.
   */
  messageSenders?: Map<string, string>;
};

/** A short, human-facing summary built ONLY from typed fields (never from raw email content). */
function synthesizeEvidence(p: ProposalCandidate): string {
  const parts: string[] = [];
  if (p.amount != null && p.currency) parts.push(`${p.currency} ${p.amount}`);
  if (p.billing_cycle) parts.push(p.billing_cycle);
  else if (p.recurrence === "one_off") parts.push("one-off");
  return parts.join(" · ").slice(0, 280);
}

function eventType(p: ProposalCandidate): string {
  return p.event_type && BILLING_EVENT_TYPES.has(p.event_type) ? p.event_type : "created";
}

/**
 * Write each proposal as a detected event + a review-queue candidate.
 * Idempotent: detected events upsert on their natural key and candidates skip on a duplicate
 * detected event, so a re-claimed job does not double-surface. Returns the number of candidates
 * written (== events surfaced this run).
 */
export async function bridgeProposalsToCandidates(
  runner: SqlRunner,
  input: BridgeInput,
): Promise<number> {
  // Reconcile a second time at the write boundary: skip suppressed merchants and attach the matched
  // subscription id (so the card reads 'review'/update rather than 'add').
  const [suppressed, subs] = await Promise.all([
    runner.query(
      `select canonical_merchant_key from merchant_discovery_suppressions where user_id = $1`,
      [input.userId],
    ),
    runner.query(
      `select id, canonical_merchant_key, name from subscriptions where user_id = $1`,
      [input.userId],
    ),
  ]);
  const suppressedKeys = new Set(suppressed.rows.map((r) => String(r.canonical_merchant_key)));
  // Identity is derived here when the row does not carry one. A subscription added by hand never
  // gets the column — manual creation writes straight from the client to PostgREST — and the old
  // `where canonical_merchant_key is not null` filter dropped exactly those rows, so the user's own
  // subscriptions were the ones the agent could not recognize, and it proposed them after every
  // scan. Deriving at the point of use keeps one implementation of the rule (this one) instead of a
  // second copy in SQL or in Swift, and it covers rows that already exist rather than only new ones.
  const subByKey = new Map(
    subs.rows.map((r) => [
      String(r.canonical_merchant_key ?? canonicalMerchantKey(String(r.name ?? ""))),
      String(r.id),
    ]),
  );

  let written = 0;
  for (const p of input.proposals) {
    // Identity comes from WHO BILLED, not from the label the model chose: the same vendor named two
    // ways ("Anthropic" / "Anthropic (Claude Pro)") must reconcile and roll up as one merchant.
    const identity = resolveIdentity(p, input.messageSenders);
    if (suppressedKeys.has(identity)) continue;

    const providerMessageId = p.evidence_refs[0] ?? `agent-${identity}`;
    const evidence = synthesizeEvidence(p);
    const type = eventType(p);

    // Upsert the evidence record; DO UPDATE (not NOTHING) so we always get the id back on a re-scan.
    //
    // The event carries the SAME identity as the card, from the one `identity` resolved above. This
    // column is the join for every merchant-scoped read in the edge function — the confirm-time
    // lifecycle gate, the learning summary, evidence bundles — all of which select evidence by it.
    // An evidence row without it is invisible to all of them: the gate then finds no billing history
    // for a merchant that has one, reads that as "uncertain", and silently resolves the user's
    // confirmation to `ignored` without creating a subscription. `dedupe-inbox-proposals-by-merchant`
    // task 2.4 deliberately left this insert untouched, which is where the invariant was lost.
    //
    // Deriving the key here from `merchant_name` instead would defeat the purpose: it yields
    // `anthropic-claude-pro` where the card carries `anthropic`, so the join would still miss.
    // Resolve once, write to both rows.
    const event = await runner.query(
      `insert into detected_billing_events
         (user_id, scan_run_id, provider, provider_message_id, event_type, merchant_name,
          canonical_merchant_key, amount, currency, billing_cycle, event_date, renewal_date,
          confidence, evidence, source_received_at)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14, coalesce($15::timestamptz, now()))
       on conflict (user_id, provider, provider_message_id, event_type)
         do update set merchant_name = excluded.merchant_name,
                       -- Repair on conflict, not by migration: a row written before this column was
                       -- populated gains its identity the next time a scan re-derives the same event.
                       canonical_merchant_key = excluded.canonical_merchant_key,
                       amount = excluded.amount,
                       renewal_date = excluded.renewal_date,
                       confidence = excluded.confidence
       returning id`,
      [
        input.userId,
        input.scanRunId,
        input.provider,
        providerMessageId,
        type,
        p.merchant_name,
        identity,
        p.amount,
        p.currency,
        p.billing_cycle,
        p.event_date,
        p.renewal_date,
        p.confidence,
        evidence,
        // source_received_at is NOT NULL with no default; fall back to now() when the event has no date.
        p.event_date,
      ],
    );
    const detectedEventId = event.rows[0]?.id;
    if (!detectedEventId) continue;

    const matchedId = subByKey.get(identity) ?? null;
    // One PENDING card per merchant per user — the scope the inbox actually queries (it filters on
    // user + review_status with no run filter, so a per-run invariant would be invisible to the user
    // and later runs would stack a second card for the same vendor). The conflict target is the
    // merchant identity, so another page — or a later scan — MERGES into the existing card; the
    // partial unique index makes that hold even when pages run concurrently with no shared state.
    //
    // Merge rule: the higher-confidence proposal supplies the field, and `coalesce` then fills from
    // the loser, so a null never erases a value already known. That makes the merge order-independent
    // — page completion order is not deterministic.
    const candidate = await insertOrMergeCandidate(runner, [
      input.userId,
      input.scanRunId,
      detectedEventId,
      matchedId,
      matchedId ? "review" : "add",
      p.merchant_name,
      identity,
      p.amount,
      p.currency,
      p.billing_cycle,
      p.renewal_date,
      p.category ?? "other",
      type,
      p.confidence,
      evidence,
    ]);
    // Count cards SURFACED, not rows touched: a merge updates an existing card and must not inflate
    // the run's "found" figure. `xmax = 0` distinguishes a fresh insert from an upsert-update.
    if (candidate.rows[0]?.inserted === true) written += 1;
  }

  return written;
}

/** Resolve a proposal's merchant identity from its evidence sender, falling back to its own key. */
function resolveIdentity(p: ProposalCandidate, senders?: Map<string, string>): string {
  const sender = senders?.get(p.evidence_refs[0] ?? "");
  return sender ? resolveMerchantIdentity(sender, p.merchant_name) : p.merchant_key;
}

const CAND_COLUMNS = `(user_id, scan_run_id, detected_event_id, matched_subscription_id,
  suggested_action, merchant_name, canonical_merchant_key, amount, currency, billing_cycle,
  renewal_date, category, event_type, confidence, evidence, resolution_reason)`;

/** `excluded` wins the field when it is more confident, then either side fills a gap in the other. */
function mergeField(column: string): string {
  return `${column} = case when excluded.confidence > c.confidence
      then coalesce(excluded.${column}, c.${column})
      else coalesce(c.${column}, excluded.${column}) end`;
}

async function insertOrMergeCandidate(runner: SqlRunner, params: unknown[]) {
  try {
    return await runner.query(
      `insert into subscription_candidates as c ${CAND_COLUMNS}
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,'agentic_proposal')
       on conflict (user_id, canonical_merchant_key) where review_status = 'pending' do update set
         -- The card belongs to the most recent scan that saw the merchant, so a merged card stays
         -- coherent with the latest run's summary.
         scan_run_id = excluded.scan_run_id,
         ${mergeField("merchant_name")},
         ${mergeField("amount")},
         ${mergeField("currency")},
         ${mergeField("billing_cycle")},
         ${mergeField("renewal_date")},
         ${mergeField("evidence")},
         matched_subscription_id =
           coalesce(excluded.matched_subscription_id, c.matched_subscription_id),
         -- Keep the action consistent with the match: a later proposal that matches a tracked
         -- subscription must flip the card from 'add' to 'review'.
         suggested_action = case
           when coalesce(excluded.matched_subscription_id, c.matched_subscription_id) is not null
             then 'review' else c.suggested_action end,
         confidence = greatest(c.confidence, excluded.confidence)
       returning id, (xmax = 0) as inserted`,
      params,
    );
  } catch (error) {
    // One email can evidence two merchants (an aggregator receipt listing several subscriptions).
    // Those proposals share a detected event, and `unique (detected_event_id)` rejects the second —
    // a constraint OTHER than our conflict target, so it raises instead of merging. The previous
    // `on conflict (detected_event_id) do nothing` silently skipped it; preserve exactly that rather
    // than letting one proposal abort the whole page's bridge.
    if ((error as { code?: string })?.code === "23505") return { rows: [] };
    throw error;
  }
}
