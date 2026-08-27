// Golden-set eval harness. Emergent search-based triage has no other way to prove its recall is
// stable run-to-run, so this scores ANY pipeline — old per-merchant or new autonomous — against a
// labeled fixture set. A pipeline is expressed as a `Runner`: messages in, the set of merchants it
// would SURFACE to the user out. The harness compares that to per-case expectations and reports
// recall (did we catch the real subscriptions?), false positives (did we surface something that
// should have been dropped, e.g. Uber?), and recurrence errors. Pure over its Runner — no network.

import { canonicalMerchantKey, type MailMetadata } from "../domain/email.ts";
import type { RecurrenceKind } from "../agent/types.ts";

export type SurfacedCandidate = { merchant_key: string; recurrence?: RecurrenceKind };

/** A pipeline under test: given a case's messages, return the merchants it would surface. */
export type Runner = (messages: MailMetadata[]) => Promise<SurfacedCandidate[]>;

export type GoldenExpectation = {
  // Merchants that SHOULD be surfaced, with the correct recurrence label.
  surface: Array<{ merchant: string; recurrence?: RecurrenceKind }>;
  // Merchants that should NOT be surfaced (repeated one-offs, marketing, etc.).
  abstain: string[];
};

export type GoldenCase = {
  id: string;
  description: string;
  messages: MailMetadata[];
  expect: GoldenExpectation;
};

export type CaseResult = {
  id: string;
  truePositives: string[]; // expected-surface merchants that were surfaced
  falseNegatives: string[]; // expected-surface merchants that were MISSED (recall misses)
  falsePositives: string[]; // expected-abstain merchants that were wrongly surfaced
  recurrenceErrors: string[]; // surfaced with the wrong recurrence label
};

export type EvalReport = {
  cases: CaseResult[];
  expectedSurface: number;
  truePositives: number;
  falseNegatives: number;
  falsePositives: number;
  recurrenceErrors: number;
  recall: number; // truePositives / expectedSurface
  // A single high-signal gate: every expected-abstain merchant stayed abstained across all cases
  // (this is the "Uber demotion" property generalized).
  abstainClean: boolean;
};

function keyset(names: string[]): Set<string> {
  return new Set(names.map(canonicalMerchantKey));
}

/**
 * Merchant identity is fuzzy, so eval matching is alias-tolerant: a surfaced key matches an expected
 * key when they are equal or one is a hyphen-prefixed refinement of the other (e.g. expected
 * `anthropic` matches surfaced `anthropic-claude-pro`; `adobe` matches `adobe-creative-cloud`). This
 * only relaxes matching against EXPECTED merchants — for abstain cases there is no expected key, so
 * any surface is still a false positive.
 */
export function keyMatches(a: string, b: string): boolean {
  return a === b || a.startsWith(`${b}-`) || b.startsWith(`${a}-`);
}

/** Score a runner against the golden cases. Runs cases sequentially so a real model stays rate-safe. */
export async function scoreCases(cases: GoldenCase[], runner: Runner): Promise<EvalReport> {
  const caseResults: CaseResult[] = [];
  for (const gc of cases) {
    const surfaced = await runner(gc.messages);
    const surfacedByKey = new Map(surfaced.map((s) => [s.merchant_key, s] as const));
    const expectSurface = new Map(
      gc.expect.surface.map((s) => [canonicalMerchantKey(s.merchant), s.recurrence] as const),
    );
    const expectAbstain = keyset(gc.expect.abstain);

    const surfacedList = [...surfacedByKey.values()];
    const truePositives: string[] = [];
    const falseNegatives: string[] = [];
    const recurrenceErrors: string[] = [];
    for (const [key, wantRecurrence] of expectSurface) {
      const hit = surfacedList.find((s) => keyMatches(s.merchant_key, key));
      if (!hit) {
        falseNegatives.push(key);
        continue;
      }
      truePositives.push(key);
      if (wantRecurrence && hit.recurrence && hit.recurrence !== wantRecurrence) {
        recurrenceErrors.push(key);
      }
    }
    // Strict precision: anything surfaced that matches NO expected merchant is a false positive —
    // this catches labeled-abstain merchants and any novel over-surfacing. `expectAbstain` is
    // retained in the fixture for readability but does not narrow the check.
    void expectAbstain;
    const expectedKeys = [...expectSurface.keys()];
    const falsePositives = surfacedList
      .map((s) => s.merchant_key)
      .filter((k) => !expectedKeys.some((e) => keyMatches(k, e)));

    caseResults.push({ id: gc.id, truePositives, falseNegatives, falsePositives, recurrenceErrors });
  }

  const sum = (pick: (c: CaseResult) => number) => caseResults.reduce((n, c) => n + pick(c), 0);
  const expectedSurface = cases.reduce((n, c) => n + c.expect.surface.length, 0);
  const truePositives = sum((c) => c.truePositives.length);
  const falseNegatives = sum((c) => c.falseNegatives.length);
  const falsePositives = sum((c) => c.falsePositives.length);
  const recurrenceErrors = sum((c) => c.recurrenceErrors.length);

  return {
    cases: caseResults,
    expectedSurface,
    truePositives,
    falseNegatives,
    falsePositives,
    recurrenceErrors,
    recall: expectedSurface === 0 ? 1 : truePositives / expectedSurface,
    abstainClean: falsePositives === 0,
  };
}

/** True when `candidate` is at least as good as `baseline` on recall and abstain-cleanliness. */
export function meetsOrBeats(candidate: EvalReport, baseline: EvalReport): boolean {
  return (
    candidate.recall >= baseline.recall &&
    candidate.falsePositives <= baseline.falsePositives &&
    candidate.recurrenceErrors <= baseline.recurrenceErrors
  );
}

export function loadGoldenCases(json: unknown): GoldenCase[] {
  if (!Array.isArray(json)) throw new Error("golden set must be a JSON array of cases");
  return json as GoldenCase[];
}
