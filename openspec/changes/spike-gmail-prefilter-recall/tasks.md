## 1. Instrument, temporarily and narrowly

- [x] 1.1 Record `(gmail_message_id, decision)` per message for one scan. **Already exists**:
      `npm run gmail` (`worker/scripts/gmail-scan.ts`) writes exactly this to a gitignored JSON in
      `worker/out/`. No production instrumentation, migration, or deploy is needed — see design.
- [x] 1.2 Record **IDs only**. No subject, sender, snippet, or body. Renewa's promise is that email
      content is processed transiently and never stored, and a spike is not a reason to cross that
      line. Review the diff specifically for this before running it.
- [x] 1.3 Widen the lookback for this run so more than one subscription falls in the window —
      `recall_detected` over n=1 measures nothing.

## 2. Capture the comparison

- [x] 2.1 Run one instrumented scan and capture the `looked` and `detected` ID sets.
- [x] 2.2 Call `messages.list` for the same window with each candidate query from the design's
      ladder (baseline, `category:purchases`, +`category:updates`, keyword set, union), paginating
      each to completion and recording the returned ID sets.
- [x] 2.3 Note the wall-clock and any 403s encountered while doing it — if the ladder itself trips
      rate limiting, that is a finding in its own right.

## 3. Compute and judge

- [x] 3.1 For each candidate: `recall_looked`, `recall_detected`, `fetch_reduction`, and the `missed`
      set.
- [ ] 3.2 Inspect the `missed` IDs by hand in Gmail. Were they real subscriptions, or triage noise?
      This is the judgement the numbers cannot make. **Not done, and not needed for the decision**:
      at 21.4% the best candidate is nowhere near the 95% threshold, so no reading of 11 individual
      messages could move the outcome. Worth doing only if a future candidate lands borderline.
- [x] 3.3 Apply the decision rule from the design **as written**, without adjusting it to fit the
      result. If the rule now looks wrong, say so explicitly and record why rather than quietly
      moving the threshold.

## 4. Record the finding

- [x] 4.1 Write the numbers and the decision into this change's design as a Result section — kept
      whether the answer is yes or no, so the next person does not re-run it.
- [x] 4.2 If the decision is to pre-filter or prioritize, open that as its own change. **N/A** — the
      measurement says do neither, so there is no follow-on filter change to open.
- [x] 4.3 If the decision is concurrency and backoff, note the numbers that ruled the filter out, so
      revisiting it later starts from evidence.

## 5. Leave no trace

- [x] 5.1 Remove the instrumentation and drop the scratch table or log.
- [x] 5.2 Confirm no message IDs or derived data outlive the spike beyond what
      `detected_billing_events` already stored.
- [x] 5.3 Confirm the scan path is byte-identical to before the spike apart from the recorded
      finding.
