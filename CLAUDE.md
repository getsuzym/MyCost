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

### Running tests

`MyCostTests` (XCTest unit tests, `@testable import MyCost`) is wired into `project.pbxproj` as a unit-test bundle with `TEST_HOST` = the `MyCost` app. Run it:

```sh
xcodebuild test -project MyCost.xcodeproj -scheme MyCost \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MyCostTests
# single test:
xcodebuild test ... -only-testing:MyCostTests/MyCostTests/testRecurringSuggestionDetectsAnnualPayments
```

If `xcode-select` points at the Command Line Tools, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` instead of running `sudo xcode-select`.

Two pre-existing tests (`testMultipleMonthsStaySeparated`, `testDuplicateMatcherTreatsSimilarMerchantsSameAmountAsMediumConfidence`) pass in isolation but fail in a full-suite run — a latent test-ordering/shared-state issue that predates the test target being wired up. Not caused by, and unrelated to, current feature work.

`MyCostUITests/` (XCUITest) is still **not** a target — add a UI Test Bundle in Xcode to run it. UI tests launch the app with the `-ui-testing` argument, which makes `MyCostApp` use an in-memory `ModelContainer`. Views expose `accessibilityIdentifier`s in `screen.element` form (e.g. `review.saveApproved`, `transactionEditor.merchant`).

### project.pbxproj is hand-maintained

The project file uses synthetic sequential IDs (`0000...`) and is **not** a file-system-synchronized group. Adding a Swift file requires four manual edits: a `PBXBuildFile` entry, a `PBXFileReference` entry, a child entry in the correct `PBXGroup`, and an entry in the `Sources` build phase. (See how `OCRTransactionImportCoordinator.swift` was added.) Test-target files go in the `MyCostTests` group and the `0000…09A6` Sources phase.

## Architecture

**No view models for CRUD.** SwiftUI views bind directly to SwiftData `@Model` instances for editing. Reusable logic lives in `Services/` as stateless `struct`/`enum` types that operate on plain arrays and value-type snapshots, so they are unit-testable without a `ModelContainer`.

**Schema is declared twice** — in `MyCostApp.swift` and in the test `setUpWithError`. Both lists (`Transaction`, `Category`, `MerchantRule`, `RecurringPayment`) must stay in sync when a model is added. All model relationships use `.nullify`.

### Screenshot OCR import pipeline (the core cross-file flow)

1. `ImportView` → `ImagePicker` → `ScreenshotImportService.processScreenshot(_:)`.
2. `VisionOCRService` (conforms to `OCRServicing`, injectable for tests) returns `[RecognizedTextBlock]` (text + normalized `boundingBox` + confidence), sorted top-to-bottom, left-to-right.
3. **Spatial grouping (primary).** Blocks become `[OCRTextObservation]` (Vision's bottom-left boxes flipped to a top-left, y-down space). `TransactionRegionDetector.detectRegions(from:dividers:)` clusters observations into rows and cuts them into `TransactionRegion`s — on supplied divider lines (nearest row gap), on abnormally large vertical gaps, at date-only section headers, and before every amount-bearing row after the first. `TransactionGrouper.candidates(from:originalOCRText:)` then assigns fields **by position, not OCR order**: amount from right-aligned currency text (conflicting right-aligned amounts → `amount = nil` + `.multipleAmounts`/`.ambiguousLayout`), merchant from left-side rows (multi-line preserved), date/status from region text with a carried section-header date. Account chrome above the first date header and rows with no amount and no own date are dropped. Each candidate keeps its `observations` (text/frame/confidence) for review and the `#if DEBUG` `OCRDebugOverlayView`.
   - `TransactionCandidateParser.parse(lines:)` is the **flat-text fallback**, used only when spatial grouping returns nothing (`ScreenshotImportResult.usedSpatialGrouping == false`). It and the grouper share field parsing via `TransactionTextHeuristics` (amount/date/status regexes, merchant cleanup, `dateOnlyHeader`). Refunds parse as negative amounts; both handle sectioned statements where one date header covers several rows.
4. `OCRTransactionReviewStore` (an `ObservableObject` shared between the Import and Review tabs via `.environmentObject` on `RootTabView`) maps candidates to `[OCRTransactionDraft]` via `replaceCandidates(_:merchantRules:)`, applying merchant rules during the mapping. `OCRTransactionDraft.isUncertain(_:)` drives the "Needs review" highlighting in the UI; `canImport` gates saving.
5. `ReviewTransactionsView` edits drafts. On Save, `OCRTransactionImportCoordinator.flagDuplicateDrafts` runs `DuplicateMatchingService` against existing transactions **and against earlier drafts in the same batch**: high-confidence matches are deselected/blocked; medium matches set `duplicateSummary` and require the user to pick Merge / Keep Both / Review. If `OCRDuplicateScanResult.needsUserDecision`, saving stops and shows a message; the user decides and saves again.
6. `saveDrafts` inserts `Transaction`s (or merges into the matched existing transaction), and optionally persists a new `MerchantRule` via `MerchantRuleService.rememberRule` when the user renamed/categorized and ticked "Remember merchant rule".

### Duplicate detection — `DuplicateMatchingService` (in `DuplicateDetector.swift`)

Operates on `DuplicateTransactionSnapshot` value types (not `Transaction`) so it stays DB-free and testable. Rules: same account required; amount must match exactly; then merchant similarity (token Jaccard OR Levenshtein ≥ 0.78 on normalized text), same-day, and a pending→posted window (≤ 4 days). Confidence is `none` / `medium` / `high`. `markDuplicates` writes `duplicateState` back onto `Transaction` models.

### Merchant normalization & rules — `MerchantRuleService.swift`

`MerchantRuleNormalizer.normalizedMerchantKey(for:)` strips processor prefixes (`SQ*`, `PAYPAL*`, `AMZN MKTP`…), store/ref/auth numbers, `#` codes, and trailing `STATE ZIP`, yielding an uppercase key. `MerchantRuleService.bestRule` scores an exact normalized-key match highest, then a rule whose (≥2) normalized tokens are a subset of the description's tokens; ties break by rule specificity then recency. Rules and the normalized key are also stored on `MerchantRule` model instances.

### Analytics — `SpendingAnalytics.monthlySummary`

Pure function over `[Transaction]`. Includes only current-month, non-excluded transactions. Reports posted vs. pending and recurring vs. non-recurring totals separately, plus highest/lowest category. Refunds (negative amounts) are intentionally kept in every total and in the hi/lo category calculation.

### Categorization chain — `MerchantCategorizationCoordinator`

`categorize(...)` is the one decision point, strict priority: **1.** user `MerchantRule` → `.ruleMatch` (no AI). **2.** `LocalMerchantCategorizer` (offline keyword table; only applies if the mapped category name exists) → `.localMatch` (no AI). **3.** connected `AIClassificationProvider` → `.aiSuggestion` (confidence ≥ threshold, preselectable) or `.lowConfidence` (below threshold, flagged for review). **4.** `.unresolved(.notConfigured | .providerUnavailable | .credentialsExpired | .requestFailed | .invalidResponse)` → caller leaves it Uncategorized. Nothing is applied silently. The default experience needs no AI (`provider` is nil).

### AI provider connection — `AIClassificationProvider` + `AIProviderService`

**No OAuth**: as of build time neither OpenAI nor Anthropic offers account/OAuth authorization granting a third-party iOS app model/API access (`AIProviderKind.supportedAuthTypes == [.apiKey]`; the enum/`AIAuthType.oauth` are stubbed for if that changes). The only path is the user's own API key. **No secret in SwiftData** — `AIProviderConnection` (`@Model`, in the schema list in `MyCostApp.swift` *and* the test setup) carries provider/state/model/endpoint/capabilities only; the key lives in `AISecretStore` (`KeychainAISecretStore` in-app, `InMemoryAISecretStore` in tests).

- `AIClassificationProvider` is the vendor-agnostic seam. `OpenAIClassificationProvider` (Chat Completions, `Authorization: Bearer`) and `AnthropicClassificationProvider` (Messages, `x-api-key` + `anthropic-version`) are in `RemoteMerchantCategorizationProvider.swift`; both take an injectable `AITransport`. `ClassificationResponseParser` validates the strict `{normalizedMerchantName, suggestedCategory, confidence, reasoningSummary}` shape — canonicalizes/drops out-of-list categories, rejects everything else as `.invalidResponse`.
- `MerchantClassificationRequest` structurally carries only merchant description + optional amount + category names — no screenshots, account numbers, other transactions, or statements.
- `AIProviderService` (stateless, `AICategorizationController.swift`): `connectWithAPIKey` validates with a live round-trip before persisting, stores the key in Keychain, upserts the `AIProviderConnection` as `.connected`, and disconnects any other provider (one active at a time); `testConnection`, `disconnect` (clears Keychain; no server-side revoke — the settings screen tells the user to delete the key in the console); `makeCoordinator(for:)` builds the chain.
- UI: `AIProviderSettingsView` (`AICategorizationSettingsView.swift`, sheet from `MerchantRulesView`) — provider picker (incl. "No AI"), key entry, Test Connection, Disconnect, Connected/Disconnected state, privacy paragraph. `ReviewTransactionsView` `@Query`s `AIProviderConnection`, shows "Ask AI" per uncategorized draft and a confirm/dismiss banner; on confirm/correct, `MerchantRuleService.learnRule` writes a local `MerchantRule` so the merchant resolves without AI next time.

### Categories — `CategoryService` + `CategoryManagementView`

Categories are dynamic SwiftData records, not a fixed list. `Category` has `isActive` (hidden categories stay on existing transactions but drop out of pickers) and `isFallback` (the single protected "Uncategorized"). `Category.defaults` seeds 8 including the fallback; `SeedDataService` also calls `CategoryService.ensureFallbackCategory` on every launch so a fallback always exists.

All mutations go through `CategoryService` (stateless, `@MainActor` for the write methods): name uniqueness is enforced case-insensitively after trimming; `deleteCategory(_:reassigningTo:transactions:merchantRules:recurringPayments:)` moves every reference to a chosen category or nil (→ Uncategorized) — never a silent drop — and refuses to delete/hide the fallback; `reorder` rewrites `sortOrder` from array order. `referenceCounts(for:…)` powers the "N transactions · M rules · K recurring" shown before a destructive delete in `CategoryManagementView` (the "Categories" tab). Category pickers in the transaction editor, merchant-rule editor, recurring-payment editor, and OCR review filter to `isActive || id == currentSelection`. `TransactionHistoryView` has a category filter. `SpendingAnalytics` already groups by `transaction.category?.name`, so dashboard totals follow renames and reassignments automatically.

### Recurring detection — `RecurringPaymentSuggestionService`

Groups posted, non-excluded transactions by account + normalized merchant key (needs ≥ 2), infers frequency from clustering of day-intervals, tolerates skipped periods, and rejects groups with high amount variance or irregular cadence. `SpendingAnalytics` also uses it for expected-monthly-recurring totals.

### Startup

`RootTabView.task` calls `SeedDataService.seedDefaultCategoriesIfNeeded` on every launch; it no-ops if any `Category` exists. The 8 default categories are `Category.defaults`. Tabs: Dashboard, Import, Review, Rules, Recurring, History.
