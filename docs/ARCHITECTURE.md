# Architecture

MyCost uses a small SwiftUI + SwiftData architecture intended to stay easy to change during the MVP phase.

## Layers

`Models`

SwiftData model objects represent the durable domain state. Views bind directly to model instances for editing, which keeps the MVP compact and avoids premature repository abstractions.

`Services`

Stateless helpers hold reusable business logic:

- `SeedDataService` inserts default categories once.
- `SpendingAnalytics` computes dashboard totals from transaction arrays.
- `DuplicateDetector` provides deterministic merchant/date/amount/status fingerprinting.
- `ScreenshotImportService` is a placeholder for OCR extraction.
- `MerchantRuleService` records merchant rename rules and can apply them to matching transactions.

`Views`

The app uses tab-based navigation:

- Dashboard: monthly total, posted total, pending total, category totals, highest category, lowest category.
- Import: placeholder for screenshot import.
- Review: placeholder list for possible duplicates.
- History: saved transactions with add and delete affordances.
- Detail: transaction summary with edit and delete.
- Editor: shared add/edit form.

## Dashboard Rules

Dashboard calculations include transactions in the current month unless they are excluded. Posted and pending totals are shown separately. Highest and lowest category calculations use the same included monthly transaction set.

## Import Roadmap

The current model is prepared for screenshot import without implementing OCR yet. The intended flow is:

1. Select screenshots in Import.
2. Extract candidate transactions.
3. Normalize merchants with `MerchantRule`.
4. Detect duplicates.
5. Review and edit candidates.
6. Save accepted transactions into SwiftData.

