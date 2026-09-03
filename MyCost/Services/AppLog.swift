import Foundation
import OSLog
import SwiftData

/// App-wide structured logging. Use a category-scoped `Logger` instead of
/// `print` so messages are filterable in Console / `log stream` and don't ship
/// user data by default.
enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.getsuzym.MyCost"

    /// Persistence — seeding, migrations, CRUD.
    static let data = Logger(subsystem: subsystem, category: "Data")
    /// Screenshot OCR import pipeline.
    static let ocr = Logger(subsystem: subsystem, category: "OCRImport")
    /// Merchant rules & recurring inference.
    static let rules = Logger(subsystem: subsystem, category: "Rules")
}

extension ModelContext {
    /// Save, logging (never throwing) on failure. For best-effort background
    /// writes — seeding, one-time migrations, rule learning — where the caller
    /// has no UI to surface an error. User-facing CRUD keeps its `do/catch`
    /// + toast instead.
    func saveOrLog(_ context: @autoclosure () -> String, logger: Logger = AppLog.data) {
        guard hasChanges else { return }
        do {
            try save()
        } catch {
            let where_ = context()
            logger.error("save failed [\(where_, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
        }
    }
}
