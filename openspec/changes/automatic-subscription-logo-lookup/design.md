## Context

Renewa's soft-squircle logo stamp currently renders remote imagery only for a stored reviewed `brand_id`. This prevents wrong matches, but unknown subscriptions always show an initial even though Logo.dev supports client-safe name lookup. The app already retains a Logo.dev publishable key, an image fallback, and a user brand picker.

Email scan currently saves a merchant name and may save a reviewed `brand_id`. A robust canonical-domain resolver would require a Logo.dev secret key in a Supabase Edge Function, which is not configured and is outside the immediate client-only rollout.

## Goals / Non-Goals

**Goals:**

- Give every non-empty subscription name an automatic Logo.dev image attempt.
- Prefer a reviewed domain whenever `brand_id` is available.
- Preserve transparent contained imagery, local fallback behavior, and the existing override control.
- Keep provider URLs ephemeral and avoid any migration or secret configuration for the immediate experience.

**Non-Goals:**

- Guaranteeing a name lookup is the correct company, storing guessed domains, or displaying a verified-status claim for automatic matches.
- Adding Logo.dev secret keys, paid API calls, or server-side transaction enrichment in this change.
- Removing the reviewed catalog or user-selected logo override.

## Decisions

### Prefer verified domain, then use the name endpoint

`SubscriptionBrandIcon` derives one remote URL: a verified catalog domain when `brand_id` resolves, otherwise a Logo.dev `/name/` request from the displayed subscription name. Both requests retain PNG, light theme, 404 fallback, and the presentation cache version.

Alternative: call only the name endpoint. This would discard known domain accuracy and can show a different mark for existing reviewed rows.

### Do not persist automatic lookup results

The name endpoint is a presentation fallback. The model continues to store `brand_id` only for catalog resolution or a deliberate user brand choice. This avoids coupling rows to a possibly incorrect provider match and makes a later enrichment migration straightforward.

Alternative: infer and save a domain from name lookup. The image endpoint does not provide a confidence result, and saving a guessed identity would make future corrections difficult.

### Reserve backend merchant enrichment for a separately configured rollout

The design records the target architecture: an Edge Function receives a merchant descriptor, calls a secret-key Logo.dev search or transaction-enrichment endpoint, then stores a canonical domain/identity only at an approved confidence. The present change provides automatic presentation for email-created rows through the same name fallback but intentionally makes no secret-key network call.

Alternative: expose a Logo.dev secret in iOS. This is prohibited because search and enrichment endpoints require a server-only credential.

## Risks / Trade-offs

- [Ambiguous name returns an incorrect logo] → Keep the fallback on 404, make no verification claim, and retain the existing override/clear action.
- [Name is generic or blank] → Do not create a remote request for empty input; show the local initial fallback.
- [Repeated rows generate redundant requests] → Use the same deterministic cache-versioned URL and rely on URL caching.
- [Future backend enrichment changes identity semantics] → Do not persist automatic name results now; define canonical-domain storage in its own migration-backed change.

## Migration Plan

1. Ship the client-only fallback; no database or Edge Function deployment is required.
2. Existing unknown and email-created rows automatically receive a name-lookup attempt the next time they render.
3. Keep users able to choose or clear a reviewed brand when the automatic result is unsuitable.
4. Roll back by removing the name fallback; existing `brand_id` values and overrides remain unaffected.

## Open Questions

- Whether the later enrichment service should use Logo.dev Search or Transaction Enrichment depends on plan availability and the form of the email merchant descriptor.
