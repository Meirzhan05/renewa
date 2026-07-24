# Repository Guidelines

## Project Structure & Module Organization

`Renewa/` contains the SwiftUI application. Views are organized by feature (`OverviewView.swift`, `EmailScanView.swift`), while shared state, models, networking, secure storage, and design tokens live in `AppStore.swift`, `Models.swift`, `SupabaseClient.swift`, `KeychainStore.swift`, and `Theme.swift`. App metadata is in `Renewa-Info.plist`; local public configuration belongs in the ignored `Config.local.xcconfig`.

`supabase/migrations/` contains ordered PostgreSQL migrations. Edge Functions live under `supabase/functions/<function-name>/`, with reusable code in `_shared/`.

There is no committed test target yet. Add iOS tests under `RenewaTests/` and backend tests beside their Edge Function.

## Build, Test, and Development Commands

```sh
xcodebuild -project Renewa.xcodeproj -target Renewa \
  -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

Builds the release-compatible iOS target without requiring signing.

```sh
xcodebuild -project Renewa.xcodeproj -target Renewa \
  -configuration Debug -sdk iphonesimulator -arch arm64 \
  SYMROOT=/tmp/RenewaBuild OBJROOT=/tmp/RenewaObj build
```

Compiles the simulator build used for local UI verification.

```sh
supabase start
supabase db reset
supabase functions serve --env-file supabase/functions/.env
```

Starts the local backend, reapplies migrations, and serves Edge Functions. Never commit the local `.env`.

## Coding Style & Naming Conventions

Use four-space indentation in Swift and two spaces in TypeScript and SQL. Follow Swift API Design Guidelines: `UpperCamelCase` types, `lowerCamelCase` properties/functions, and one primary view per `*View.swift` file. Keep UI state `private` when possible and perform network work with structured concurrency.

Use lowercase kebab-case for Edge Function directories and timestamp-prefixed migration names. Keep shared backend helpers provider-neutral.

## Testing Guidelines

Use XCTest for models, spending calculations, store behavior, and API decoding. Name tests `test_<behavior>_<expectedResult>()`. Backend tests should cover OAuth state validation, token encryption, duplicate events, confidence thresholds, RLS ownership, and unauthenticated Function requests. Run relevant builds and local migration resets before submitting.

## Commit & Pull Request Guidelines

The repository has no established commit history. Use short, imperative commits such as `Add renewal date validation` or `Harden OAuth callback state`.

Pull requests should include a concise summary, testing performed, configuration or migration notes, and linked issues. Attach before/after screenshots for UI changes. Call out new secrets, OAuth scopes, RLS changes, or destructive migrations explicitly.

## Security & Configuration

Only publishable Supabase values belong in `Config.local.xcconfig`. Keep OpenAI, provider, encryption, and Supabase server keys in backend secrets. Preserve read-only mail scopes and RLS ownership checks.

# Project Goals

Build the project until all acceptance criteria are satisfied.

## Rules
- Never stop after one task.
- Commit logical changes frequently.
- Update `todo.md` after each milestone.
- Run tests before considering a task complete.
- If blocked, explain why and propose the next action.

## Definition of Done
- All tests pass
- Lint passes
- Documentation updated
