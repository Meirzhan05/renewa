## Context

```
                    what we do now
  messages.list(newer_than:90d)  ──►  2,464 ids      5 units
        │
        ▼  100 per page, 6 concurrent
  messages.get × 2,464           ──►  12,320 units   ← 93% wasted here
        │
        ▼  LLM triage on subject + sender
      162 looked                                     6.6% survive
        │
        ▼
        1 billing event
```

```
                  what a pre-filter would do
  messages.list(newer_than:90d category:purchases)  ──►  ~N ids   5 units
        │
        ▼  messages.get × N
      ...                                                 ← the open question:
                                                            which of the 162 are in N?
```

The measurement we need is one number per candidate query: **of the messages triage chose to look
at, how many would the query have returned?** Everything else follows from that.

## Goals / Non-Goals

**Goals:**

- Measure, on a real mailbox, the overlap between a Gmail server-side query and the triage decision.
- Express the result as recall against two references — messages triage looked at, and messages that
  produced a detected billing event — alongside the fetch reduction each query buys.
- Fix the decision rule *before* seeing the numbers, so the result cannot be rationalized after the
  fact.
- Leave the codebase exactly as it was, plus a recorded finding.

**Non-Goals:**

- Shipping a pre-filter. If the numbers support one, it is a separate change with its own specs.
- Tuning the retry backoff, concurrency, or lookback window. Those are the alternatives this spike
  chooses between; changing them now would confound the measurement.
- Building reusable measurement infrastructure. This is throwaway instrumentation with a removal
  task attached.
- Evaluating Microsoft Graph. Same question applies there, but Gmail is where the failures are.

## Method

**Revised during execution: no production instrumentation is needed.** `worker/scripts/gmail-scan.ts`
(`npm run gmail`) is an existing dev tool that authorizes against a real mailbox read-only, runs the
same `triageInbox`, and already writes per-message decisions —
`skipped_by_triage` / `reviewed_no_proposal` / `proposed` — to a gitignored JSON under `worker/out/`.
That is exactly the instrumentation task 1 describes, already built and already outside production.

So the spike runs entirely against local dev tooling: no edge-function change, no migration, no
scratch table, no deploy, and nothing to remove afterwards beyond a throwaway comparison script. The
original plan to instrument the live scan path would have put temporary write code into the
production Gmail path to learn something a dev tool already records.

**1. Use an existing (or fresh) local scan for the decision sets.**

`worker/out/gmail-processed-*.json` holds `{ id, agent_decision }` per message. `looked` is every
message whose decision is not `skipped_by_triage`; `proposed` is the subset that produced a proposal.
Message IDs are opaque, and no subject, sender, or snippet is read out of the file or reproduced
anywhere — that boundary is the point of the product, and a spike is not a reason to cross it.

**2. Capture candidate query results.**

Call `messages.list` for the same window with each candidate, recording only the returned ID sets:

| # | query | hypothesis |
|---|---|---|
| 0 | `newer_than:90d` | baseline — what we do today |
| 1 | `newer_than:90d category:purchases` | Gmail's own receipt classifier |
| 2 | `newer_than:90d {category:purchases category:updates}` | plus transactional mail |
| 3 | `newer_than:90d {receipt invoice subscription renewal "payment" billing}` | keyword ladder |
| 4 | query 1 OR query 3 | union — highest recall, still filtered |

Paginate each to completion. Cost is 5 units per list call, so the whole ladder costs less than
fetching two messages.

**3. Compare by ID.**

For each candidate *q*:

```
recall_looked    = |q ∩ looked|    / |looked|
recall_detected  = |q ∩ detected|  / |detected|
fetch_reduction  = 1 - |q| / |baseline|
missed           = looked \ q          ← inspect these by ID against the mailbox by hand
```

The `missed` set is the interesting one: a handful of IDs a human can look at directly in Gmail to
judge whether they were real subscriptions or triage noise.

## Decision rule — fixed before the numbers

| condition | conclusion |
|---|---|
| `recall_detected = 100%` and `recall_looked ≥ 95%` and `fetch_reduction ≥ 80%` | Adopt the pre-filter as a hard filter. |
| `recall_detected = 100%` and `recall_looked` 80–95% | Use the query to **prioritize**: fetch its set first, then the remainder while quota allows. Keeps recall, spends quota on likely mail first. |
| `recall_detected < 100%` | Do **not** hard-filter. The failure it introduces is invisible, which is worse than a scan that stops visibly. Fall back to lower concurrency and longer backoff. |
| `fetch_reduction < 50%` | Not worth the complexity; go with concurrency and backoff. |

Writing this down first is deliberate. With one detected event in the current data, it would be very
easy to look at "100% of 1" and call it proof.

## Result — measured 2026-09-03

Mailbox: the developer's own. Window: `newer_than:180d`, 3,209 messages. Sample: 300 messages run
through the real triage — 14 looked at, 286 skipped, **0 proposals**.

| query | window | recall_looked | recall_proposed | fetch_reduction |
|---|---|---|---|---|
| 0 baseline `newer_than:180d` | 3,209 | 100.0% | n/a | — |
| 1 `category:purchases` | 35 | **21.4%** | n/a | 98.9% |
| 2 `{category:purchases category:updates}` | 2,052 | **64.3%** | n/a | 36.1% |
| 3 keyword ladder | 259 | **57.1%** | n/a | 91.9% |
| 4 union(1,3) | 271 | **64.3%** | n/a | 91.6% |

**Decision: do not pre-filter.** Applying the rule as written, without adjustment: a hard filter
needed `recall_looked ≥ 95%`, prioritization needed 80–95%, and the best candidate reaches 64.3%.
Gmail's own purchases category — the most promising hypothesis going in — returns 3 of the 14
messages triage wanted to read. Whatever signal triage uses, Gmail's classifier and full-text search
do not reproduce it.

The `recall_proposed` column is empty because this sample produced no proposals, so the strongest
criterion in the decision rule could not be evaluated at all. That does not change the outcome —
`recall_looked` fails every threshold on its own — but it means the result rests entirely on
agreement with triage, which the threats section already flags as not ground truth.

Cost of the measurement: five `messages.list` ladders plus one 300-message local scan. No production
change, no deploy.

**What this leaves.** Filtering is off the table, and the session's earlier fallback of "lower the
concurrency" was separately invalidated: the quota error names its limit as
`Total Query Cost / Units per minute per user`, a per-minute cost budget rather than a per-second
burst rate, so spreading the same requests over more seconds spends exactly the same quota. The
levers that remain are (a) backoff long enough for the per-minute budget to refill, (b) a shorter
lookback, which reduces total cost directly and is by far the simplest, and (c) requesting a quota
increase for the project. A full scan of ~2,464 messages costs ~12,458 units, which leaves almost no
headroom in a single minute's budget for a retry or a second scan.

## Threats to validity

- **One mailbox, and it is the developer's.** Gmail's `category:purchases` accuracy varies by user,
  locale, and how much a mailbox has been trained. A result here is indicative, not general.
- **No detected events in the measured sample.** The 300-message sample produced zero proposals, so
  `recall_detected` was never measured. Widening the lookback to 180 days did not help — the sample
  is 9.3% of the window and happened to contain no billing mail the agent would propose.
- **A 14-message denominator.** Each looked-at message is worth 7.1 percentage points, so the recall
  figures are coarse. They are decisive here only because the gap is large: 21.4% is not a borderline
  result. A closer call would need a bigger sample.
- **Triage is not ground truth.** It is an LLM, non-deterministic, and deliberately over-admits. High
  overlap with triage is evidence a query is safe; low overlap is not proof it is unsafe.
- **Triage decisions may vary run to run.** Capture the decision set in the same run that produces
  the comparison, not across runs.
- **Gmail's classifier changes.** A result true today is not permanently true, which argues for
  prioritization over hard filtering even if the numbers look good.

## Time box

One instrumented scan plus the query ladder. If it is not answered in an hour of work, the answer is
"go with concurrency and backoff" — that path needs no evidence and unblocks the user immediately.

## Open Questions

- Does the lookback window deserve its own look? Scanning 365 days mostly re-finds the same
  subscriptions at 4× the quota. That may be a bigger, simpler win than any query.
- `getProfile` is fetched once per page purely for a `historyId` — 23 extra round trips per scan.
  Cheap in units, but worth folding into whatever change follows.
- Should the eventual filter be per-provider? Microsoft Graph has different operators and different
  throttling behaviour, and copying a Gmail answer across would be a guess.
