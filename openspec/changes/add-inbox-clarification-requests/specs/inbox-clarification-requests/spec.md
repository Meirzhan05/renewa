## ADDED Requirements

### Requirement: Eligible ambiguity creates a bounded clarification request
Inbox Intelligence SHALL create a clarification request only when privacy-minimized billing evidence is concrete, the ambiguity is material to a subscription decision, and a bounded user answer can safely affect a downstream review decision. The system SHALL support lifecycle, merchant-identity, and billing-cycle clarification kinds. The system MUST NOT create a request from weak, marketing-like, stale-only, or otherwise non-actionable evidence.

#### Scenario: Recent uncertain lifecycle evidence is answerable
- **WHEN** a recent paid-service evidence bundle has an uncertain lifecycle and its service identity is sufficiently resolved
- **THEN** the system creates one open lifecycle clarification asking whether the service is still active

#### Scenario: Weak evidence stays out of the queue
- **WHEN** extraction confidence is low or the message is marketing-like without concrete billing evidence
- **THEN** the system records no clarification request and does not interrupt the user

#### Scenario: Duplicate evidence does not repeat an open question
- **WHEN** a provider event repeats evidence for an ambiguity that already has an open clarification request
- **THEN** the system retains one open request for that user, evidence bundle, and clarification kind

### Requirement: Inbox presents one prioritized Quick question
Inbox Intelligence SHALL present the highest-priority open clarification as a **Quick question** below Inbox status and connected-inbox chips and above handled activity. The card SHALL contain a plain-language question, compact privacy-minimized explanation, and bounded answer choices. The home screen MUST present no more than one clarification card at a time.

#### Scenario: An eligible clarification needs attention
- **WHEN** the user has an open clarification request and Inbox Intelligence loads
- **THEN** the Inbox home shows that request in the primary review area before handled activity

#### Scenario: A clarification unlocks a candidate
- **WHEN** an open clarification answer is required before a related subscription candidate can be safely proposed
- **THEN** the clarification is prioritized ahead of that candidate in the primary review area

#### Scenario: No clarification is open
- **WHEN** the user has no open clarification request
- **THEN** Inbox Intelligence does not show a Quick question card

### Requirement: Clarification detail communicates uncertainty without exposing email content
The clarification detail experience SHALL explain the missing fact in plain language and show only the merchant label, dated evidence events, and bounded explanation allowed by the existing Inbox privacy model. It MUST NOT show raw email content, full mailbox addresses, OAuth credentials, or raw model output. The detail experience SHALL only request fields relevant to the clarification kind.

#### Scenario: User opens an identity clarification
- **WHEN** the user taps a merchant-identity Quick question
- **THEN** the detail experience asks whether the descriptors are the same service and does not show a subscription-edit form

#### Scenario: User opens a billing-cycle clarification
- **WHEN** the user taps a billing-cycle Quick question
- **THEN** the detail experience offers only the supported billing-cycle choices and a not-sure path

### Requirement: Clarification answers are durable and safe
The system SHALL persist each clarification answer with ownership, timestamp, and the request outcome. Resolving a clarification MUST be idempotent. An answer MUST NOT directly add, update, cancel, or suppress a subscription; any resulting subscription change SHALL require the existing explicit candidate confirmation flow.

#### Scenario: Positive lifecycle answer enables review rather than mutation
- **WHEN** the user indicates an eligible uncertain service is still active
- **THEN** the system may create or unblock a pending subscription candidate and waits for the user to explicitly confirm that candidate before mutating subscriptions

#### Scenario: User is not sure
- **WHEN** the user selects Not sure for a clarification
- **THEN** the system retains the evidence as uncertain, removes the request from immediate attention, and does not infer a subscription state

#### Scenario: Answer retry is idempotent
- **WHEN** the client repeats a resolve request for an already answered clarification
- **THEN** the system returns the existing resolution without recording a second outcome or applying a second downstream effect

### Requirement: Clarification requests respect owner privacy and future evidence
Clarification requests and outcomes SHALL be readable only by their owning authenticated user. The system SHALL close or supersede an open request when newer evidence resolves its ambiguity, and SHALL not immediately re-ask an answered, dismissed, or expired question without materially newer eligible evidence.

#### Scenario: New evidence resolves an open question
- **WHEN** later renewal or cancellation evidence deterministically resolves the lifecycle represented by an open clarification
- **THEN** the system closes the stale clarification and does not display it on Inbox

#### Scenario: Another user requests clarification data
- **WHEN** an authenticated user requests a clarification that belongs to another user
- **THEN** the system returns no clarification data and does not permit resolution
