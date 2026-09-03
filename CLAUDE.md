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

`MyCostUITests` is a UI-test-bundle target (`-only-testing:MyCostUITests`). Tests launch with `-ui-testing`, which makes `MyCostApp` use an in-memory `ModelContainer` (default categories seeded on launch). Views expose `accessibilityIdentifier`s in `screen.element` form (`review.saveApproved`, `transactionEditor.merchant`, `dashboard.openMonth`, `monthDetail.addTransaction`, …). The app opens on Dashboard; History/Categories/Recurring are under the tab bar's "More" (7 tabs). The add-transaction UI tests exist specifically as a crash guard for the SwiftUI diff issue below.

### Add/save must not restructure a `List` and animate the app at once

`ContiguousArrayBuffer.swift:692` / `AppGraph.shared may only be set once!` on "adding a transaction" came from a `List` doing several structural changes in one `@Query`-driven update (a `Section` appearing, an `if/else` flipping `ContentUnavailableView` ↔ `ForEach`) **while** `.toastHost()` animated the whole `TabView` (a toast now fires on every save). Rules that keep it stable, applied to `DashboardView`, `MonthDetailView`, `ReviewTransactionsView`: never wrap the whole app in `.animation(_:value:)` — `ToastHost` animates only its overlay `ZStack`; don't gate a `Section` or swap `ForEach`↔`ContentUnavailableView` on data that changes on add — keep the `Section`/`ForEach` always present and show an empty-state `Text` as a sibling row; compute a recomputed summary/list **once** per `body` (`let x = x; return List{…}`) so its `ForEach` diffs against one snapshot; and every `Identifiable` used in a `ForEach` over a *recomputed* collection needs a value-derived `id` (see `CategorySpend.id`, `RecurringPaymentSuggestion.id`), never `let id = UUID()`.

### project.pbxproj is hand-maintained

The project file uses synthetic sequential IDs (`0000...`) and is **not** a file-system-synchronized group. Adding a Swift file requires four manual edits: a `PBXBuildFile` entry, a `PBXFileReference` entry, a child entry in the correct `PBXGroup`, and an entry in the `Sources` build phase. (See how `OCRTransactionImportCoordinator.swift` was added.) Test-target files go in the `MyCostTests` group and the `0000…09A6` Sources phase.

## Architecture

**No view models for CRUD.** SwiftUI views bind directly to SwiftData `@Model` instances for editing. Reusable logic lives in `Services/` as stateless `struct`/`enum` types that operate on plain arrays and value-type snapshots, so they are unit-testable without a `ModelContainer`.

**Schema is declared twice** — in `MyCostApp.swift` and in the test `setUpWithError`. Both lists (`Transaction`, `Category`, `MerchantRule`, `RecurringPayment`) must stay in sync when a model is added. All model relationships use `.nullify`.

### Screenshot OCR import pipeline (the core cross-file flow)

1. `ImportView` → `ImagePicker` (multi-select `PHPicker`, `selectionLimit = 0`, returns `[PickedImage]`) → `ScreenshotBatchImportService.process(_:progress:)`, which runs `ScreenshotImportService.processScreenshot(_:referenceDateOverride:)` **once per screenshot** (see "Batch multi-screenshot import" below).
2. `VisionOCRService` (conforms to `OCRServicing`, injectable for tests) returns `[RecognizedTextBlock]` (text + normalized `boundingBox` + confidence), sorted top-to-bottom, left-to-right.
3. **Spatial grouping (primary).** Blocks become `[OCRTextObservation]` (Vision's bottom-left boxes flipped to a top-left, y-down space). `TransactionRegionDetector.detectRegions(from:dividers:)` clusters observations into rows and cuts them into `TransactionRegion`s — on supplied divider lines (nearest row gap), on abnormally large vertical gaps, at date-only section headers, and before every amount-bearing row after the first. `TransactionGrouper.candidates(from:originalOCRText:)` then assigns fields **by position, not OCR order**: amount from right-aligned currency text (conflicting right-aligned amounts → `amount = nil` + `.multipleAmounts`/`.ambiguousLayout`), merchant from left-side rows (multi-line preserved), date/status from region text with a carried section-header date. Account chrome above the first date header and rows with no amount and no own date are dropped. Each candidate keeps its `observations` (text/frame/confidence) for review and the `#if DEBUG` `OCRDebugOverlayView`.
   - `TransactionCandidateParser.parse(lines:)` is the **flat-text fallback**, used only when spatial grouping returns nothing (`ScreenshotImportResult.usedSpatialGrouping == false`). It and the grouper share field parsing via `TransactionTextHeuristics` (amount/date/status regexes, merchant cleanup, `dateOnlyHeader`). Refunds parse as negative amounts; both handle sectioned statements where one date header covers several rows.
   - One `referenceDate` (captured per `processScreenshot` call, returned on `ScreenshotImportResult`) is threaded to the grouper, the flat parser, and `replaceCandidates`, so a year-less date ("Aug 28") is inferred consistently. `dateByInferringYear` uses the current year, stepping back a year only if that would be >31 days in the future.
4. `OCRTransactionReviewStore` (an `ObservableObject` shared between the Import and Review tabs via `.environmentObject` on `RootTabView`) maps candidates to `[OCRTransactionDraft]` via `replaceCandidates(_:merchantRules:referenceDate:)`. `OCRTransactionDraft.isUncertain(_:)` drives "Needs review" highlighting; `canImport` gates saving.
5. `ReviewTransactionsView.saveApprovedTransactions` runs `flagDuplicateDrafts` (`DuplicateMatchingService`, against existing transactions **and earlier drafts in the same batch**): **high**-confidence matches deselect their draft (excluded from import); **medium** ones only get a `duplicateSummary` note and are still imported, flagged `.possibleDuplicate` — duplicates never silently block a save.
6. **`OCRTransactionImportService.importDrafts(...)`** (extracted from the view so the whole path is testable) inserts a `Transaction` per importable draft into the app's shared `@Environment(\.modelContext)`, calls `save()` once, then does a post-save `fetchCount` and returns an `OCRDraftImportOutcome` (`persistedTransactionCount`, `saveError`, inserted/merged IDs). `os.Logger(subsystem: "com.getsuzym.MyCost", category: "OCRImport")` logs the count, each inserted entity, and the save result. `saveError` surfaces in a `.alert` (drafts kept); otherwise drafts are cleared and the footer shows the persisted count. Confirmed/corrected suggestions also `MerchantRuleService.learnRule` so the merchant resolves locally next time.

There is one source of truth — the app's `ModelContainer.mainContext`. Every screen reads it via `@Query`; nothing copies `Transaction` arrays between screens (`SpendingAnalytics` and `MonthlyTransactionsService` are pure functions fed by a `@Query`).

### Batch multi-screenshot import — `ScreenshotBatchImportService`

`ImportView` is a 4-phase wizard (`Phase`: idle → preview → processing → done). Select Screenshots (multi) → Preview grid (per-thumbnail remove, "Add More", "Process N") → Processing ("Processing screenshot N of M" from the `progress` callback) → done (summary + which screenshots failed + "Import More"). `ScreenshotBatchImportService.process([BatchScreenshotInput], progress:)` loops the **existing single-screenshot pipeline** per image — raw OCR text is never concatenated across screenshots before grouping; each screenshot produces its own candidates, then they're appended in screenshot order. It is fault tolerant: a `processScreenshot` throw becomes a `BatchScreenshotFailure(label:reason:)` and the loop continues. It stamps every candidate's `sourceScreenshotID`, shares **one `referenceDate`** across the batch (`referenceDateOverride`), and retains only a downscaled `thumbnail` per screenshot (full-resolution `UIImage`s live in `ImportView.queued` and are dropped the moment processing ends). Injection: `ScreenshotBatchImportService(importService: SingleScreenshotProcessing = ScreenshotImportService())` — tests pass a `StubSingleScreenshotProcessor` (canned `Result` per call) so batch logic is exercised without OCR.

`OCRTransactionReviewStore.replaceBatch(candidates:thumbnails:info:merchantRules:referenceDate:)` installs the combined session: `sourceThumbnails: [UUID: UIImage]` (for "View source" in a Review row), `batchInfo` (`OCRBatchSessionInfo` — succeeded screenshot count + failed labels, drives the Review banner), plus `selectAll()` / `deselectAll()` for the Review toolbar. Dedup is unchanged — the one `flagDuplicateDrafts` pass in `saveApprovedTransactions` already compares each draft against existing transactions **and earlier drafts in the batch**, so the same transaction appearing in two overlapping screenshots is flagged once (high → deselected, medium → noted, never silently dropped). Confirmation uses `CRUDFeedback.batchImportResult(added:duplicatesSkipped:persisted:)` → "14 transactions added" / "14 transactions added · 3 duplicates skipped"; on `saveError` the drafts + thumbnails are kept so the user retries without re-picking. When the last draft leaves `drafts`, the view calls `ocrReviewStore.clear()` to release the session.

### Month detail — `MonthDetailView` + `MonthlyTransactionsService`

`DashboardView` has a month stepper (`monthAnchor`, default current month) plus a "Months" section listing every month with transactions (`MonthlyTransactionsService.monthsRepresented`, newest first). Both navigate to `MonthDetailView(month:)`, whose `@Query` is filtered to `[monthStart, nextMonthStart)` via a `#Predicate` built in `init` — so add/edit/delete and a date change that crosses months update this page, Transaction History, and the Dashboard automatically with no manual refresh. The page shows a compact summary (`SpendingAnalytics` total/posted/pending + count), lists **every** transaction in the month (posted, pending, uncategorized, recurring, and excluded — excluded dimmed with a badge but tappable), newest first, and supports full CRUD: `+` → `TransactionEditorView(mode: .add, initialDate: month)`, tap → `TransactionDetailView`, swipe → Edit / Delete (confirmed). Excluded transactions stay out of the money totals (`SpendingAnalytics` filters `!isExcluded`); refunds are negative amounts and lower the total.

### CRUD feedback — `ToastCenter` + `.toastHost()`

One app-wide toast channel, attached once with `.toastHost()` on `RootTabView`. `ToastCenter.shared.success(_:)` / `.error(_:)` / `.show(Toast)` — a single toast at a time (a newer message replaces the current, so rapid actions never stack), auto-dismissing (errors linger longer), announced to VoiceOver via `UIAccessibility.post(.announcement)`. `CRUDFeedback` holds the consistent strings (`"Transaction added"`, `"3 transactions added"`, `"Category updated"`, `"Couldn't save transaction. Please try again."`); `CRUDFeedback.result(action:noun:count:persisted:)` is the one rule — success message only when `persisted == true`, otherwise an error `Toast`. Every CRUD site (manual add/edit, screenshot import, single + bulk delete in History/MonthDetail/Detail, category add/rename/delete-with-reassignment/hide, recurring-payment save, merchant-rule add/update/delete) calls it **inside the `do` after `try modelContext.save()`**, never before; validation errors stay as inline form messages, not toasts. `ToastCenter.init` takes an injectable `sleep` for tests.

### Safe indexing

`.onDelete` / `.onMove` `IndexSet`s can be stale (async `@Query` update, rapid double-swipe) and caused `ContiguousArrayBuffer.swift:692: Index out of range` crashes. `Array+SafeIndexing.swift` adds `Collection[safe:] -> Element?` and `Array.elements(at: IndexSet) -> [Element]` (drops out-of-range offsets); `TransactionHistoryView` and `MerchantRulesView` delete handlers use `elements(at:)`, `CategoryManagementView.move` bounds-checks the offsets. Everywhere else the app looks items up by stable `id`, never a remembered index.

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
