# MyCost

MyCost is a SwiftUI + SwiftData iOS app (iOS 17+) for tracking personal
spending. Its distinguishing feature is importing transactions from banking
**screenshots** via on-device Vision OCR, then reviewing and de-duplicating them
before they are saved. There is no account linking, no backend, and no
third-party analytics — all data stays on device.

## Features

- **Screenshot import** — pick one or more banking screenshots; each is OCR'd
  and spatially parsed into transaction candidates, combined into one review
  session, checked for duplicates against existing data, and saved on approval.
  The importer is layout-tolerant (RBC, TD, generic) and infers year-less and
  relative dates.
- **Account-type-aware amounts** — mark a source account as Credit Card /
  Debit / Other once; `TransactionNormalizer` then interprets signs correctly
  (credit-card purchases are positive spending, debit purchases negative;
  payments, transfers and deposits don't count).
- **Merchant rules** — Exact / Contains / Starts With / Ends With match types,
  priority, optional "mark matching transactions recurring". Saving a rule
  re-applies the rule set to the last 3 months of transactions.
- **Recurring payments** — user-controlled per transaction, plus a schedule
  model (`RecurrenceSchedule`) supporting weekly / biweekly / monthly /
  quarterly / yearly / every-N-months / Nth-weekday-of-month / Nth-business-day.
  The Recurring tab is scoped to a selected month and shows expected vs. actual
  occurrences with a paid indicator.
- **Dashboard** — month total, spend-by-category (donut + %), recurring vs.
  non-recurring, category drill-down.
- **Categories** — dynamic records with a protected "Uncategorized" fallback;
  deleting a category reassigns its references rather than dropping them.

## Requirements

- A full Xcode install with the iOS 17 SDK or newer.
- If only the Command Line Tools are selected, point at Xcode first:

  ```sh
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```

## Build & test

```sh
# Build
xcodebuild -project MyCost.xcodeproj -scheme MyCost \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Unit tests
xcodebuild test -project MyCost.xcodeproj -scheme MyCost \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:MyCostTests

# UI tests
xcodebuild test -project MyCost.xcodeproj -scheme MyCost \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:MyCostUITests
```

CI (`.github/workflows/ci.yml`) runs both test bundles on every push and PR to
`main`.

## Architecture

- **No view models for CRUD.** SwiftUI views bind directly to SwiftData
  `@Model` instances. Reusable logic lives in `Services/` as stateless
  `struct` / `enum` types that operate on plain arrays and value-type
  snapshots, so they're unit-testable without a `ModelContainer`.
- **One source of truth** — the app's `ModelContainer.mainContext`. Every
  screen reads it via `@Query`; nothing copies model arrays between screens.
- **Schema** — `Transaction`, `Category`, `MerchantRule`, `RecurringPayment`,
  `Account`, declared in `MyCostApp.swift` and mirrored in the test setup.

```text
MyCost/
  Models/        SwiftData models and domain enums
  Services/      OCR pipeline, analytics, duplicate detection, rules,
                 recurrence scheduling, seeding/migrations, logging
  Views/         SwiftUI tab flows and shared components
```

Bottom tabs: **Dashboard · Recurring · Categories · Rules · More**. Screenshot
import and the review session are presented from the Dashboard toolbar, not as
tabs; the full transaction history (with search + month scoping) is under
**More → All Transactions**.

`CLAUDE.md` documents the cross-file flows and non-obvious constraints in
detail.
