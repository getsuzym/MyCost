# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

MyCost is a SwiftUI + SwiftData iOS app (iOS 17, Swift 5.0, bundle id `com.getsuzym.MyCost`) for tracking personal spending. Its distinguishing feature is importing transactions from banking screenshots via on-device OCR, then reviewing/deduping them before they are saved.

## Build & test

`xcodebuild` requires a full Xcode; this machine may have only Command Line Tools selected:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -project MyCost.xcodeproj -scheme MyCost \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Tests are not wired into the project yet

`MyCostTests/` (XCTest unit tests, `@testable import MyCost`) and `MyCostUITests/` (XCUITest) contain real, maintained test source, but `MyCost.xcodeproj/project.pbxproj` currently declares **only the `MyCost` app target** — no test bundles. To run them you must first add a Unit Test Bundle and UI Test Bundle target in Xcode (test host = `MyCost`). After that:

```sh
xcodebuild test -project MyCost.xcodeproj -scheme MyCost \
  -destination 'platform=iOS Simulator,name=iPhone 16'
# single test:
xcodebuild test ... -only-testing:MyCostTests/MyCostTests/testRecurringSuggestionDetectsAnnualPayments
```

UI tests launch the app with the `-ui-testing` argument, which makes `MyCostApp` use an in-memory `ModelContainer`. Views expose `accessibilityIdentifier`s in `screen.element` form (e.g. `review.saveApproved`, `transactionEditor.merchant`) for UI tests to target.

### project.pbxproj is hand-maintained

The project file uses synthetic sequential IDs (`0000...`) and is **not** a file-system-synchronized group. Adding a Swift file requires four manual edits: a `PBXBuildFile` entry, a `PBXFileReference` entry, a child entry in the correct `PBXGroup`, and an entry in the `Sources` build phase. (See how `OCRTransactionImportCoordinator.swift` was added.)

## Architecture

**No view models for CRUD.** SwiftUI views bind directly to SwiftData `@Model` instances for editing. Reusable logic lives in `Services/` as stateless `struct`/`enum` types that operate on plain arrays and value-type snapshots, so they are unit-testable without a `ModelContainer`.

**Schema is declared twice** — in `MyCostApp.swift` and in the test `setUpWithError`. Both lists (`Transaction`, `Category`, `MerchantRule`, `RecurringPayment`) must stay in sync when a model is added. All model relationships use `.nullify`.

### Screenshot OCR import pipeline (the core cross-file flow)

1. `ImportView` → `ImagePicker` → `ScreenshotImportService.processScreenshot(_:)`.
2. `VisionOCRService` (conforms to `OCRServicing`, injectable for tests) returns `[RecognizedTextBlock]` sorted top-to-bottom, left-to-right.
3. `TransactionCandidateParser.parse(lines:)` / `parse(ocrText:)` produces `[TransactionCandidate]`, each carrying per-field confidences and a set of `TransactionCandidateValidationFlag`s (missing/ambiguous date, inferred year, missing amount/status, etc.). Single-line and multi-line bank layouts are both handled; refunds parse as negative amounts.
4. `OCRTransactionReviewStore` (an `ObservableObject` shared between the Import and Review tabs via `.environmentObject` on `RootTabView`) maps candidates to `[OCRTransactionDraft]` via `replaceCandidates(_:merchantRules:)`, applying merchant rules during the mapping. `OCRTransactionDraft.isUncertain(_:)` drives the "Needs review" highlighting in the UI; `canImport` gates saving.
5. `ReviewTransactionsView` edits drafts. On Save, `OCRTransactionImportCoordinator.flagDuplicateDrafts` runs `DuplicateMatchingService` against existing transactions **and against earlier drafts in the same batch**: high-confidence matches are deselected/blocked; medium matches set `duplicateSummary` and require the user to pick Merge / Keep Both / Review. If `OCRDuplicateScanResult.needsUserDecision`, saving stops and shows a message; the user decides and saves again.
6. `saveDrafts` inserts `Transaction`s (or merges into the matched existing transaction), and optionally persists a new `MerchantRule` via `MerchantRuleService.rememberRule` when the user renamed/categorized and ticked "Remember merchant rule".

### Duplicate detection — `DuplicateMatchingService` (in `DuplicateDetector.swift`)

Operates on `DuplicateTransactionSnapshot` value types (not `Transaction`) so it stays DB-free and testable. Rules: same account required; amount must match exactly; then merchant similarity (token Jaccard OR Levenshtein ≥ 0.78 on normalized text), same-day, and a pending→posted window (≤ 4 days). Confidence is `none` / `medium` / `high`. `markDuplicates` writes `duplicateState` back onto `Transaction` models.

### Merchant normalization & rules — `MerchantRuleService.swift`

`MerchantRuleNormalizer.normalizedMerchantKey(for:)` strips processor prefixes (`SQ*`, `PAYPAL*`, `AMZN MKTP`…), store/ref/auth numbers, `#` codes, and trailing `STATE ZIP`, yielding an uppercase key. `MerchantRuleService.bestRule` scores an exact normalized-key match highest, then a rule whose (≥2) normalized tokens are a subset of the description's tokens; ties break by rule specificity then recency. Rules and the normalized key are also stored on `MerchantRule` model instances.

### Analytics — `SpendingAnalytics.monthlySummary`

Pure function over `[Transaction]`. Includes only current-month, non-excluded transactions. Reports posted vs. pending and recurring vs. non-recurring totals separately, plus highest/lowest category. Refunds (negative amounts) are intentionally kept in every total and in the hi/lo category calculation.

### Recurring detection — `RecurringPaymentSuggestionService`

Groups posted, non-excluded transactions by account + normalized merchant key (needs ≥ 2), infers frequency from clustering of day-intervals, tolerates skipped periods, and rejects groups with high amount variance or irregular cadence. `SpendingAnalytics` also uses it for expected-monthly-recurring totals.

### Startup

`RootTabView.task` calls `SeedDataService.seedDefaultCategoriesIfNeeded` on every launch; it no-ops if any `Category` exists. The 8 default categories are `Category.defaults`. Tabs: Dashboard, Import, Review, Rules, Recurring, History.
