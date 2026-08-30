// Bridges the autonomous agent's proposals into the app's review queue. A proposal is the agent's
// only output; to reach the iOS review UI unchanged it must land as a `detected_billing_events` row
// (the evidence record) and a `subscription_candidates` row (the review card) against the app's scan
// run, after which the run is marked completed. This is the app-DB write the worker owns under
// decision 2a — the edge function no longer runs discovery.
//
// Safety: only the proposal's typed, validated fields are written. There is no free-text passthrough
// from email content (the `evidence` string is synthesized from typed fields only), so the anti-exfil
// wall from `propose.ts` extends all the way to the human-facing card.

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
 * Write each proposal as a detected event + a review-queue candidate, then complete the run.
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
      `select id, canonical_merchant_key from subscriptions
        where user_id = $1 and canonical_merchant_key is not null`,
      [input.userId],
    ),
  ]);
  const suppressedKeys = new Set(suppressed.rows.map((r) => String(r.canonical_merchant_key)));
  const subByKey = new Map(subs.rows.map((r) => [String(r.canonical_merchant_key), String(r.id)]));

  let written = 0;
  for (const p of input.proposals) {
    if (suppressedKeys.has(p.merchant_key)) continue;

    const providerMessageId = p.evidence_refs[0] ?? `agent-${p.merchant_key}`;
    const evidence = synthesizeEvidence(p);
    const type = eventType(p);

    // Upsert the evidence record; DO UPDATE (not NOTHING) so we always get the id back on a re-scan.
    const event = await runner.query(
      `insert into detected_billing_events
         (user_id, scan_run_id, provider, provider_message_id, event_type, merchant_name,
          amount, currency, billing_cycle, event_date, renewal_date, confidence, evidence,
          source_received_at)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13, coalesce($14::timestamptz, now()))
       on conflict (user_id, provider, provider_message_id, event_type)
         do update set merchant_name = excluded.merchant_name,
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

    const matchedId = subByKey.get(p.merchant_key) ?? null;
    const candidate = await runner.query(
      `insert into subscription_candidates
         (user_id, scan_run_id, detected_event_id, matched_subscription_id, suggested_action,
          merchant_name, canonical_merchant_key, amount, currency, billing_cycle, renewal_date,
          category, event_type, confidence, evidence, resolution_reason)
       values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,'agentic_proposal')
       on conflict (detected_event_id) do nothing
       returning id`,
      [
        input.userId,
        input.scanRunId,
        detectedEventId,
        matchedId,
        matchedId ? "review" : "add",
        p.merchant_name,
        p.merchant_key,
        p.amount,
        p.currency,
        p.billing_cycle,
        p.renewal_date,
        p.category ?? "other",
        type,
        p.confidence,
        evidence,
      ],
    );
    if (candidate.rows.length > 0) written += 1;
  }

  // Complete the app-side run so the app's status poll flips to review-ready.
  await runner.query(
    `update email_scan_runs
        set status = 'completed',
            stage = $2,
            completed_at = now(),
            events_detected = $3,
            messages_scanned = $4
      where id = $1`,
    [input.scanRunId, written > 0 ? "review_ready" : "completed", written, input.messagesScanned],
  );

  return written;
}
