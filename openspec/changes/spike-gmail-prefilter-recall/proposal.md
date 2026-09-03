## Why

Scans keep failing on Gmail rate limits, and the cause is not the retry policy — it is how much mail
we fetch. Measured on 2026-09-03:

```
messages fetched     2,464    one messages.get each, 5 quota units apiece
triage said "look"     162    6.6%
billing events found     1
```

We spend roughly 93% of the Gmail quota fetching mail the triage discards on subject and sender
alone, before anything reads it. Per scan that is ~12,458 quota units against a limit of 250 units
per user per second — about 50 seconds of pure quota budget, fetched six-at-a-time in bursts that
exceed the limit even though the average does not.

The reason is that there is no filter:

```ts
// _shared/email-scan-window.ts
return `newer_than:${lookbackDays}d`;
```

`messages.list` costs 5 units for up to 500 results, so filtering *server-side* is nearly free while
filtering *client-side* costs 5 units per message. A query like `category:purchases` might cut
fetches by an order of magnitude.

**But it might also lose subscriptions, and we cannot currently tell.** The whole discovery design is
deliberately recall-biased — triage admits anything not an explicit skip, and degrades to
recall-only on model outage specifically so nothing is silently lost. A Gmail-side query is a *hard*
filter: what it excludes is never fetched, never triaged, and never visible to anyone. Adopting one
on intuition would trade a visible failure (a scan that stops) for an invisible one (a subscription
that is never found), which is the worse of the two.

This spike measures the disagreement instead of arguing about it.

## What Changes

Nothing ships. This is a time-boxed investigation producing a decision and a recorded measurement.

- Add temporary, ID-only instrumentation to one scan: for each message, record its Gmail message ID
  and whether triage looked at it or skipped it. No subjects, senders, or bodies.
- Run `messages.list` with a ladder of candidate queries against the same mailbox and window,
  capturing the ID set each returns. Each list call costs 5 units, so the whole comparison is
  cheaper than fetching two messages.
- Compare by ID: for each candidate query, what fraction of the looked-at messages and of the
  detected billing events would it have retained, and how many fetches would it have avoided.
- Record the result, remove the instrumentation, and decide between pre-filtering, slowing down, or
  using the query to prioritize rather than exclude.

**This cannot be answered from data already stored.** Renewa deliberately keeps no email content —
"processed transiently and never stored" — and `triage_look_count` is a per-page count, not a
per-message decision. There is nothing to mine retroactively; the measurement has to be taken live.

## Capabilities

### New Capabilities
- `mailbox-fetch-recall`: the constraint this investigation exists to protect — narrowing what a scan
  fetches must be justified by measured recall against the unfiltered baseline, uncertain narrowings
  reorder work rather than drop it, and a filter's continued fitness stays observable. This outlives
  the spike whichever way the numbers fall; the finding itself does not become a requirement.

### Modified Capabilities
None.

## Impact

- Temporary instrumentation in the Gmail page path (`supabase/functions/email-scan/index.ts`) and
  wherever triage decisions are returned, recording message IDs and decisions only.
- A scratch table or log for the ID/decision pairs, dropped when the spike ends.
- `openspec/specs/mailbox-fetch-recall/` — the durable constraint on narrowing, which applies to the
  lookback window and to Microsoft Graph as much as to any Gmail query.
- One real scan against a real mailbox, plus a handful of `messages.list` calls.
- No user-visible change, no schema change that outlives the spike.

## Decision this unblocks

Whether the fix for rate limiting is **fetch less** (a server-side pre-filter), **fetch slower**
(lower concurrency, longer backoff), or **fetch in priority order** (filtered set first, remainder if
budget allows). Those are materially different changes, and the current evidence does not
distinguish them.
