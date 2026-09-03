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

One pre-existing test fails: `testDuplicateMatcherTreatsSimilarMerchantsSameAmountAsMediumConfidence` — "SQ Coffee Bar" vs "Square Coffee Bar LLC" scores ~0.73 against the 0.78 `merchantSimilarity` threshold in `DuplicateDetector.swift`. It encodes a desired-but-unimplemented behavior (abbreviation-aware similarity) and is awaiting a product decision on the threshold. Not caused by, and unrelated to, current feature work.

`MyCostUITests` is a UI-test-bundle target (`-only-testing:MyCostUITests`). Tests launch with `-ui-testing`, which makes `MyCostApp` use an in-memory `ModelContainer` (default categories seeded on launch). Views expose `accessibilityIdentifier`s in `screen.element` form (`review.saveApproved`, `transactionEditor.merchant`, `dashboard.openMonth`, `monthDetail.addTransaction`, …). The app opens on Dashboard; with 8 tabs, everything after the 4th is under the tab bar's "More" (Categories, Accounts, Recurring, History). The add-transaction UI tests exist specifically as a crash guard for the SwiftUI diff issue below.

### Add/save must not restructure a `List` and animate the app at once

`ContiguousArrayBuffer.swift:692` / `AppGraph.shared may only be set once!` on "adding a transaction" came from a `List` doing several structural changes in one `@Query`-driven update (a `Section` appearing, an `if/else` flipping `ContentUnavailableView` ↔ `ForEach`) **while** `.toastHost()` animated the whole `TabView` (a toast now fires on every save). Rules that keep it stable, applied to `DashboardView`, `MonthDetailView`, `ReviewTransactionsView`: never wrap the whole app in `.animation(_:value:)` — `ToastHost` animates only its overlay `ZStack`; don't gate a `Section` or swap `ForEach`↔`ContentUnavailableView` on data that changes on add — keep the `Section`/`ForEach` always present and show an empty-state `Text` as a sibling row; compute a recomputed summary/list **once** per `body` (`let x = x; return List{…}`) so its `ForEach` diffs against one snapshot; and every `Identifiable` used in a `ForEach` over a *recomputed* collection needs a value-derived `id` (see `CategorySpend.id`, `RecurringPaymentSuggestion.id`), never `let id = UUID()`.

### project.pbxproj is hand-maintained

The project file uses synthetic sequential IDs (`0000...`) and is **not** a file-system-synchronized group. Adding a Swift file requires four manual edits: a `PBXBuildFile` entry, a `PBXFileReference` entry, a child entry in the correct `PBXGroup`, and an entry in the `Sources` build phase. (See how `OCRTransactionImportCoordinator.swift` was added.) Test-target files go in the `MyCostTests` group and the `0000…09A6` Sources phase.

## Architecture

**No view models for CRUD.** SwiftUI views bind directly to SwiftData `@Model` instances for editing. Reusable logic lives in `Services/` as stateless `struct`/`enum` types that operate on plain arrays and value-type snapshots, so they are unit-testable without a `ModelContainer`.

**Schema is declared twice** — in `MyCostApp.swift` and in the test `setUpWithError`. Both lists (`Transaction`, `Category`, `MerchantRule`, `RecurringPayment`, `Account`) must stay in sync when a model is added. All model relationships use `.nullify`. New `Transaction` fields for amount normalization (`normalizedAmount`, `transactionDirectionRawValue`, `accountTypeRawValue`, `countsAsSpending`, `needsDirectionReview`) are all `= <default>` so they're a lightweight migration on existing stores.

**No AI.** There is no network/LLM categorization. The AI provider connection, Keychain secret store, OpenAI/Anthropic providers, and their settings screen were removed. `MerchantCategorizationCoordinator` is a small synchronous type with three outcomes: `.ruleMatch` (user `MerchantRule`) → `.localMatch` (`LocalMerchantCategorizer` known-merchant table) → `.unresolved` (manual / Uncategorized). Merchant learning stays: renaming/recategorizing a transaction can be saved as a `MerchantRule` (`MerchantRuleService.learnRule`).

### Screenshot OCR import pipeline (the core cross-file flow)

1. `ImportView` → `ImagePicker` (multi-select `PHPicker`, `selectionLimit = 0`, returns `[PickedImage]`) → `ScreenshotBatchImportService.process(_:progress:)`, which runs `ScreenshotImportService.processScreenshot(_:referenceDateOverride:)` **once per screenshot** (see "Batch multi-screenshot import" below).
2. `VisionOCRService` (conforms to `OCRServicing`, injectable for tests) returns `[RecognizedTextBlock]` (text + normalized `boundingBox` + confidence), sorted top-to-bottom, left-to-right.
3. **Spatial grouping (primary).** Blocks become `[OCRTextObservation]` (Vision's bottom-left boxes flipped to a top-left, y-down space). `TransactionRegionDetector.detectRegions(from:dividers:)` clusters observations into rows and cuts them into `TransactionRegion`s — on supplied divider lines (nearest row gap), on abnormally large vertical gaps, at date-only section headers, and before every amount-bearing row after the first. `TransactionGrouper.candidates(from:originalOCRText:)` then assigns fields **by position, not OCR order**: amount from right-aligned currency text (conflicting right-aligned amounts → `amount = nil` + `.multipleAmounts`/`.ambiguousLayout`), merchant from left-side rows (multi-line preserved), date/status from region text with a carried section-header date. Account chrome above the first date header and rows with no amount and no own date are dropped. Each candidate keeps its `observations` (text/frame/confidence) for review and the `#if DEBUG` `OCRDebugOverlayView`.
   - **A recognized date is never the merchant.** `TransactionTextHeuristics.detectDate` recognizes `2026-09-02`, `09/02`, `Sep 2`, and the relative words `Today` / `Yesterday` / `Tomorrow` (resolved against `referenceDate`, no year inference). Both the grouper and the flat parser strip the matched date and then run `heuristics.isEssentiallyJustADate(merchant)` — if what's left is still just a date, the merchant is cleared and `.missingMerchantDescription` / `.possibleNonTransactionLine` set, for the user to fill in.
   - **`BankLayoutProfile`** is an *optional* per-bank tuning of the generic parser, not a replacement. `BankLayoutProfile.identify(in: ocrText)` matches lowercased signature phrases and returns a profile carrying a `TransactionGrouper.Configuration`; an unrecognized layout returns `.generic` (`.default` config). `ScreenshotImportService` picks the profile and passes its config to the grouper; the chosen profile name is on `ScreenshotImportResult.layoutProfileName`.
   - `TransactionCandidateParser.parse(lines:)` is the **flat-text fallback**, used only when spatial grouping returns nothing (`ScreenshotImportResult.usedSpatialGrouping == false`). It and the grouper share field parsing via `TransactionTextHeuristics` (amount/date/status regexes, merchant cleanup, `dateOnlyHeader`). Refunds parse as negative amounts; both handle sectioned statements where one date header covers several rows.
   - One `referenceDate` (captured per `processScreenshot` call, returned on `ScreenshotImportResult`) is threaded to the grouper, the flat parser, and `replaceCandidates`, so a year-less date ("Aug 28") is inferred consistently. `dateByInferringYear` uses the current year, stepping back a year only if that would be >31 days in the future.
4. `OCRTransactionReviewStore` (an `ObservableObject` shared between the Import and Review tabs via `.environmentObject` on `RootTabView`) maps candidates to `[OCRTransactionDraft]` via `replaceCandidates(_:merchantRules:referenceDate:)`. `OCRTransactionDraft.isUncertain(_:)` drives "Needs review" highlighting; `canImport` gates saving.
5. `ReviewTransactionsView` shows an **Account Type** section (one picker per distinct draft account name, seeded from any saved `Account`), a per-row deterministic **"Suggest category"** button (runs `MerchantCategorizationCoordinator`; applies a rule/local match, or says "no match — pick manually"), plus Select All / Deselect All and "View source" (batch). `saveApprovedTransactions` first `AccountService.upsert`s the type choices, then runs `flagDuplicateDrafts` (`DuplicateMatchingService`, against existing transactions **and earlier drafts in the same batch**): **high**-confidence matches deselect their draft; **medium** ones only get a `duplicateSummary` note and are still imported, flagged `.possibleDuplicate` — duplicates never silently block a save.
6. **`OCRTransactionImportService.importDrafts(_:categories:accountTypesByName:existingTransactions:existingRules:modelContext:)`** (extracted from the view so the whole path is testable) inserts a `Transaction` per importable draft, running `TransactionNormalizer` with the draft's account type (see below) so `normalizedAmount` / `countsAsSpending` / `transactionDirection` are stamped and ambiguous rows counted in `OCRDraftImportOutcome.reviewFlaggedCount`. It calls `save()` once, then does a post-save `fetchCount` and returns an `OCRDraftImportOutcome` (`persistedTransactionCount`, `saveError`, inserted/merged IDs). `os.Logger(subsystem: "com.getsuzym.MyCost", category: "OCRImport")` logs the count, each inserted entity, and the save result. `saveError` surfaces in a `.alert` (drafts + thumbnails kept for retry); otherwise drafts are cleared and the footer shows the persisted count.

There is one source of truth — the app's `ModelContainer.mainContext`. Every screen reads it via `@Query`; nothing copies `Transaction` arrays between screens (`SpendingAnalytics` and `MonthlyTransactionsService` are pure functions fed by a `@Query`).

### Batch multi-screenshot import — `ScreenshotBatchImportService`

`ImportView` is a 4-phase wizard (`Phase`: idle → preview → processing → done). Select Screenshots (multi) → Preview grid (per-thumbnail remove, "Add More", "Process N") → Processing ("Processing screenshot N of M" from the `progress` callback) → done (summary + which screenshots failed + "Import More"). `ScreenshotBatchImportService.process([BatchScreenshotInput], progress:)` loops the **existing single-screenshot pipeline** per image — raw OCR text is never concatenated across screenshots before grouping; each screenshot produces its own candidates, then they're appended in screenshot order. It is fault tolerant: a `processScreenshot` throw becomes a `BatchScreenshotFailure(label:reason:)` and the loop continues. It stamps every candidate's `sourceScreenshotID`, shares **one `referenceDate`** across the batch (`referenceDateOverride`), and retains only a downscaled `thumbnail` per screenshot (full-resolution `UIImage`s live in `ImportView.queued` and are dropped the moment processing ends). Injection: `ScreenshotBatchImportService(importService: SingleScreenshotProcessing = ScreenshotImportService())` — tests pass a `StubSingleScreenshotProcessor` (canned `Result` per call) so batch logic is exercised without OCR.

`OCRTransactionReviewStore.replaceBatch(candidates:thumbnails:info:merchantRules:referenceDate:)` installs the combined session: `sourceThumbnails: [UUID: UIImage]` (for "View source" in a Review row), `batchInfo` (`OCRBatchSessionInfo` — succeeded screenshot count + failed labels, drives the Review banner), plus `selectAll()` / `deselectAll()` for the Review toolbar. Dedup is unchanged — the one `flagDuplicateDrafts` pass in `saveApprovedTransactions` already compares each draft against existing transactions **and earlier drafts in the batch**, so the same transaction appearing in two overlapping screenshots is flagged once (high → deselected, medium → noted, never silently dropped). Confirmation uses `CRUDFeedback.batchImportResult(added:duplicatesSkipped:persisted:)` → "14 transactions added" / "14 transactions added · 3 duplicates skipped"; on `saveError` the drafts + thumbnails are kept so the user retries without re-picking. When the last draft leaves `drafts`, the view calls `ocrReviewStore.clear()` to release the session.

### Month detail — `MonthDetailView` + `MonthlyTransactionsService`

`DashboardView` has a month stepper (`monthAnchor`, default current month) plus a "Months" section listing every month with transactions (`MonthlyTransactionsService.monthsRepresented`, newest first). Both navigate to `MonthDetailView(month:)`, whose `@Query` is filtered to `[monthStart, nextMonthStart)` via a `#Predicate` built in `init` — so add/edit/delete and a date change that crosses months update this page, Transaction History, and the Dashboard automatically with no manual refresh. The page shows a compact summary (`SpendingAnalytics` total/posted/pending + count), lists **every** transaction in the month (posted, pending, uncategorized, recurring, and excluded — excluded dimmed with a badge but tappable), newest first, and supports full CRUD: `+` → `TransactionEditorView(mode: .add, initialDate: month)`, tap → `TransactionDetailView`, swipe → Edit / Delete (confirmed).

### Category drill-down — `CategoryDetailView`

Each row in the Dashboard "Categories" section is a `NavigationLink` → `CategoryDetailView(categoryName:month:)` (the Dashboard's `monthAnchor` is passed through). It reads all transactions via `@Query` and filters in memory to `[monthStart, nextMonthStart)` + `(category?.name ?? "Uncategorized") == categoryName`, so a category change on any row removes it here and updates the total immediately. Header = category total (`spendingAmount` sum, excludes excluded) + a month stepper that starts on the passed-in month and is clamped to ≤ current month. Rows show merchant, amount, date, account, and Pending / Recurring / Excluded / "Not spending" badges. `+` → `TransactionEditorView(mode: .add, initialDate: month, initialCategoryID:)` (new `initialCategoryID` param preselects the category), tap → `TransactionDetailView`, swipe → Edit / Delete (confirmed).

### CRUD feedback — `ToastCenter` + `.toastHost()`

One app-wide toast channel, attached once with `.toastHost()` on `RootTabView`. `ToastCenter.shared.success(_:)` / `.error(_:)` / `.show(Toast)` — a single toast at a time (a newer message replaces the current, so rapid actions never stack), auto-dismissing (errors linger longer), announced to VoiceOver via `UIAccessibility.post(.announcement)`. `CRUDFeedback` holds the consistent strings (`"Transaction added"`, `"3 transactions added"`, `"Category updated"`, `"Couldn't save transaction. Please try again."`); `CRUDFeedback.result(action:noun:count:persisted:)` is the one rule — success message only when `persisted == true`, otherwise an error `Toast`. Every CRUD site (manual add/edit, screenshot import, single + bulk delete in History/MonthDetail/Detail, category add/rename/delete-with-reassignment/hide, recurring-payment save, merchant-rule add/update/delete) calls it **inside the `do` after `try modelContext.save()`**, never before; validation errors stay as inline form messages, not toasts. `ToastCenter.init` takes an injectable `sleep` for tests.

### Safe indexing

`.onDelete` / `.onMove` `IndexSet`s can be stale (async `@Query` update, rapid double-swipe) and caused `ContiguousArrayBuffer.swift:692: Index out of range` crashes. `Array+SafeIndexing.swift` adds `Collection[safe:] -> Element?` and `Array.elements(at: IndexSet) -> [Element]` (drops out-of-range offsets); `TransactionHistoryView` and `MerchantRulesView` delete handlers use `elements(at:)`, `CategoryManagementView.move` bounds-checks the offsets. Everywhere else the app looks items up by stable `id`, never a remembered index.

### Duplicate detection — `DuplicateMatchingService` (in `DuplicateDetector.swift`)

Operates on `DuplicateTransactionSnapshot` value types (not `Transaction`) so it stays DB-free and testable. Rules: same account required; amount must match exactly; then merchant similarity (token Jaccard OR Levenshtein ≥ 0.78 on normalized text), same-day, and a pending→posted window (≤ 4 days). Confidence is `none` / `medium` / `high`. `markDuplicates` writes `duplicateState` back onto `Transaction` models.

### Merchant normalization & rules — `MerchantRuleService.swift`

`MerchantRuleNormalizer.normalizedMerchantKey(for:)` strips processor prefixes (`SQ*`, `PAYPAL*`, `AMZN MKTP`…), store/ref/auth numbers, `#` codes, and trailing `STATE ZIP`, yielding an uppercase key. `caseFolded(_:)` is the lighter form (lowercase, whitespace-collapsed, trimmed) all match-type comparisons run in.

**`MerchantRule` has a `matchType`** ∈ `exact` / `startsWith` / `endsWith` / `contains` (defaulted `.exact` — lightweight migration) plus a `priority: Int` (defaulted 0). `normalizedMerchantName` / `isActive` are aliases over the stored `displayName` / `isEnabled`. `MerchantRuleService.matches(_:merchantName:originalDescription:)` tests the `caseFolded` `matchText` against **both** the merchant name and the bank's original description with the chosen operator; `.exact` additionally keeps the legacy normalized-key-equality and ≥2-token-subset fallback so pre-`matchType` rules still resolve.

**Conflict order in `bestRule`**: `priority` (higher wins outright) → match specificity (`exact` 3 > `startsWith`/`endsWith` 2 > `contains` 1) → longer `matchText` → most recently updated. So a broad `contains` never beats a more specific user rule unless the user raised its `priority`. Substring types require ≥3 chars (`matchType.minimumMatchTextLength`); the rule editor enforces it.

`MerchantRulesView` is the management screen: add/edit/delete, enable/disable (swipe), match-type picker, priority stepper, resulting merchant name + category, and a live "Matches / No match" preview against an example description. `learnRule(…, matchType:)` create-or-updates by `(caseFolded matchText, matchType)` — no duplicates. The transaction editor's "Remember merchant change?" offers **"Apply to transactions containing '<name>'"** (a `.contains` rule keyed on the new merchant name) or **"Apply to this exact merchant"** (`.exact` on the original description). OCR-import learning stays `.exact`.

### Analytics — `SpendingAnalytics.monthlySummary`

Pure function over `[Transaction]`. Includes only current-month, non-excluded rows **that `countsAsSpending`**, and sums each row's **`spendingAmount`** (account-type-normalized), not the raw bank `amount`. So credit-card payments and payroll deposits contribute 0; a refund's negative `normalizedAmount` still lowers the total; category totals, posted/pending, and recurring splits all use `spendingAmount`. Legacy rows that never went through `TransactionNormalizer` have `transactionDirection == .unknown` and `spendingAmount` falls back to `amount`.

**`CategorySpend` carries `percentageOfTotal`** = `amount / summary.total × 100` (the denominator is the same eligible monthly spending; `0` when the month has none; a net-refund category can be negative). `categoryTotals` stays sorted by `amount` descending. Because every screen recomputes the summary from a `@Query` array each `body`, percentages update immediately on add / delete / amount / category / exclude / direction / refund changes. `DashboardView`'s Categories section shows a native `Charts` `BarMark` distribution (`SpendingDistributionChart`, positive categories only) plus a `CategoryBreakdownRow` per category — name, `Formatters.currencyString`, and `Formatters.percentString` all as text (VoiceOver-combined) — each a `NavigationLink` to `CategoryDetailView`, which also shows the category's "% of month" in its header.

### Account type awareness & amount normalization — `Account` + `TransactionNormalizer`

`Account` (`@Model`, unique `name`, `accountType` ∈ `creditCard` / `debit` / `other`) remembers a source account's type so the user picks it **once**. `AccountService` does trimmed/case-insensitive name matching plus `resolveType(for:in:)` (→ `.other` if unknown) and `upsert(name:type:…)`. The **Accounts** tab (`AccountsView`) lists/edits accounts.

`TransactionNormalizer.normalize(originalAmount:accountType:description:)` → `NormalizedTransaction(normalizedAmount, direction, countsAsSpending, needsReview)`:
- **creditCard**: `+amount` → spending (`normalizedAmount = +amount`); `-amount` with a payment cue → not spending (`0`); `-amount` with a refund cue → reduces spending (`-amount`); `-amount` with no cue → not spending + `needsReview`.
- **debit**: `-amount` → spending (`normalizedAmount = +|amount|`); `+amount` with an income cue → not spending (`0`); `+amount` with a refund cue → `-|amount|`; `+amount` no cue → not spending + `needsReview`.
- **other**: cue-driven; `-amount` → spending; unexplained `+amount` → spending + `needsReview`.
It never blindly flips a sign that already matches the account convention. Cues are keyword lists (payment / refund / income). `Transaction` stores `amount` (bank original, sign preserved — also aliased `originalAmount`), `normalizedAmount`, `transactionDirection`, `accountType`, `countsAsSpending`, `needsDirectionReview`, plus `spendingAmount`/`applyNormalization(_:accountType:)` helpers. Applied at import (`OCRTransactionImportService`, per-account type from the Review screen) and in `TransactionEditorView` (Account Type picker + "Counts as spending" override that wins over the normalizer verdict).

### Categorization chain — `MerchantCategorizationCoordinator`

Synchronous, offline, three outcomes in strict priority: **1.** user `MerchantRule` → `.ruleMatch`. **2.** `LocalMerchantCategorizer` (offline keyword table; only applies if the mapped category name exists) → `.localMatch`. **3.** `.unresolved` → caller leaves it Uncategorized for manual categorization. No network, no AI. `ReviewTransactionsView`'s per-row "Suggest category" and `TransactionEditorView` use it; nothing is applied without the match being a concrete rule/local hit.

### Categories — `CategoryService` + `CategoryManagementView`

Categories are dynamic SwiftData records, not a fixed list. `Category` has `isActive` (hidden categories stay on existing transactions but drop out of pickers) and `isFallback` (the single protected "Uncategorized"). `Category.defaults` seeds 8 including the fallback; `SeedDataService` also calls `CategoryService.ensureFallbackCategory` on every launch so a fallback always exists.

All mutations go through `CategoryService` (stateless, `@MainActor` for the write methods): name uniqueness is enforced case-insensitively after trimming; `deleteCategory(_:reassigningTo:transactions:merchantRules:recurringPayments:)` moves every reference to a chosen category or nil (→ Uncategorized) — never a silent drop — and refuses to delete/hide the fallback; `reorder` rewrites `sortOrder` from array order. `referenceCounts(for:…)` powers the "N transactions · M rules · K recurring" shown before a destructive delete in `CategoryManagementView` (the "Categories" tab). Category pickers in the transaction editor, merchant-rule editor, recurring-payment editor, and OCR review filter to `isActive || id == currentSelection`. `TransactionHistoryView` has a category filter. `SpendingAnalytics` already groups by `transaction.category?.name`, so dashboard totals follow renames and reassignments automatically.

### Recurring detection — `RecurringPaymentSuggestionService`

Groups posted, non-excluded transactions by account + normalized merchant key (needs ≥ 2), infers frequency from clustering of day-intervals, tolerates skipped periods, and rejects groups with high amount variance or irregular cadence. `SpendingAnalytics` also uses it for expected-monthly-recurring totals.

### Startup

`RootTabView.task` calls `SeedDataService.seedDefaultCategoriesIfNeeded` on every launch; it no-ops if any `Category` exists. The 8 default categories are `Category.defaults`. Tabs: Dashboard, Import, Review, Rules, Categories, Accounts, Recurring, History.
