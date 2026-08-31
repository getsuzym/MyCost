# MyCost

MyCost is a SwiftUI and SwiftData iOS app for tracking personal spending.

## MVP Scope

The first working flow supports:

- Manual transaction add, edit, and delete.
- Categorizing transactions with seeded default categories.
- Renaming merchants and storing `MerchantRule` records for future normalization.
- Marking transactions as excluded from totals.
- Tracking posted vs. pending transactions.
- Marking transactions as recurring and creating `RecurringPayment` records.
- Dashboard totals powered by saved SwiftData transactions.
- Placeholder Import and Review screens for the future screenshot OCR workflow.

## Requirements

- Xcode with iOS 17 SDK or newer.
- SwiftData-capable deployment target, currently iOS 17.0.

This environment currently has only the Command Line Tools selected, so local `xcodebuild` verification requires switching to a full Xcode install:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Project Structure

```text
MyCost/
  Models/        SwiftData models and domain enums
  Services/      Seed data, analytics, duplicate detection, import stubs
  Views/         SwiftUI tab flows and shared components
```

The app starts in `RootTabView`, which seeds default categories on launch and exposes Dashboard, Import, Review, and History tabs.

## Data Model

- `Transaction`: spending record with merchant, amount, date, category, pending/posted status, exclusion state, duplicate state, and optional recurring payment link.
- `Category`: seeded spending categories used for dashboard totals.
- `MerchantRule`: records merchant rename/category preferences for future import normalization.
- `RecurringPayment`: tracks recurring merchants, amount, frequency, category, and next expected date.

## Next Steps

- Add OCR and screenshot parsing to `ScreenshotImportService`.
- Route extracted screenshots into a review queue.
- Apply `MerchantRule` records during import.
- Add duplicate detection against persisted transactions before insertion.
- Add tests once a full Xcode toolchain is available.

