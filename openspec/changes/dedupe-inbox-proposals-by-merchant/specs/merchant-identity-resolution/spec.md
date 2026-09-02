## ADDED Requirements

### Requirement: Merchant identity derives from the evidence sender, not the display name
A proposal's canonical merchant key SHALL be derived from the registrable domain of the sender of the
evidence email that produced it, not from the model-chosen `merchant_name`. Two proposals raised from
the same registrable sender domain SHALL resolve to the same canonical merchant key even when their
display names differ.

#### Scenario: Differing display names on one vendor collapse to one identity
- **WHEN** one email from `no-reply@mail.anthropic.com` yields the name `Anthropic` and another from
  `no-reply@mail.anthropic.com` yields `Anthropic (Claude Pro)`
- **THEN** both proposals resolve to the same canonical merchant key

#### Scenario: Subdomains of one vendor collapse to one identity
- **WHEN** evidence arrives from `noreply@email.openai.com` and from `noreply@tm.openai.com`
- **THEN** both proposals resolve to the same canonical merchant key derived from `openai.com`

#### Scenario: Distinct vendors keep distinct identities
- **WHEN** evidence arrives from `billing@anthropic.com` and from `billing@openai.com`
- **THEN** the two proposals resolve to different canonical merchant keys

### Requirement: Shared billing processors fall back to name-derived identity
A configured set of aggregator domains (payment processors, app stores, and other shared billing
senders) SHALL NOT be used as merchant identity, because the sender identifies the processor rather
than the merchant. A proposal whose evidence sender is an aggregator domain SHALL derive its
canonical merchant key from the sanitized display name instead.

#### Scenario: App-store receipts stay separate per merchant
- **WHEN** two receipts from `no_reply@email.apple.com` name `Spotify` and `Netflix`
- **THEN** the two proposals resolve to different canonical merchant keys, and neither key is derived
  from `apple.com`

#### Scenario: Payment-processor receipts stay separate per merchant
- **WHEN** evidence arrives from a configured processor domain such as PayPal, Stripe, or Paddle
- **THEN** identity falls back to the display name rather than collapsing distinct merchants together

### Requirement: Identity resolution is deterministic and always yields a key
Merchant identity resolution SHALL be a pure, deterministic function of the evidence sender and the
sanitized display name, producing the same key for the same inputs. When the sender is absent,
unparseable, or an aggregator, and the display name is also unusable, resolution SHALL fall back to
the existing sentinel key rather than failing the proposal.

#### Scenario: Unparseable sender falls back to the name
- **WHEN** a proposal's evidence sender cannot be parsed into a domain
- **THEN** the canonical merchant key is derived from the sanitized display name

#### Scenario: No usable sender or name yields the sentinel key
- **WHEN** neither a usable sender domain nor a usable display name is available
- **THEN** resolution returns the `unknown-merchant` sentinel key and the proposal is not dropped

#### Scenario: Resolution is stable across runs
- **WHEN** the same evidence email is processed in two different scan runs
- **THEN** both runs resolve the same canonical merchant key

### Requirement: Display names remain human-facing and independent of identity
Changing identity derivation SHALL NOT change what the user reads on a card. The merchant name shown
SHALL continue to come from the validated, sanitized display name, and SHALL remain subject to the
existing anti-exfiltration bounds on that field.

#### Scenario: Card shows the display name, not the domain slug
- **WHEN** a proposal resolves its identity from `mail.anthropic.com`
- **THEN** the review card still displays the model-provided name (e.g. `Anthropic (Claude Pro)`),
  not `anthropic`

#### Scenario: Sanitization still applies
- **WHEN** a display name contains control characters or exceeds the bounded length
- **THEN** it is stripped and truncated exactly as before, independent of identity resolution
