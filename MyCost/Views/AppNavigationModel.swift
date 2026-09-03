import SwiftUI

/// App-level presentation state kept out of the individual views: which
/// root-level sheet is up (the screenshot import flow or the persistent Review
/// session) and whether the "a review is already in progress" prompt is
/// showing. Held as a `@StateObject` on `RootTabView` and shared via
/// `.environmentObject`.
@MainActor
final class AppNavigationModel: ObservableObject {
    enum Route: Int, Identifiable {
        case importPicker
        case review
        var id: Int { rawValue }
    }

    @Published var route: Route?
    @Published var isShowingImportConflict = false

    /// Dashboard's import button. Opens the picker directly, or asks how to
    /// handle an unfinished review session first — never discards it silently.
    func requestImport(session: OCRTransactionReviewStore) {
        if session.hasActiveSession {
            isShowingImportConflict = true
        } else {
            route = .importPicker
        }
    }

    func continueCurrentReview() {
        isShowingImportConflict = false
        route = .review
    }

    /// Only reached by an explicit "Replace" tap in the conflict dialog.
    func replaceReview(session: OCRTransactionReviewStore) {
        session.clear()
        isShowingImportConflict = false
        route = .importPicker
    }

    func openReview() {
        route = .review
    }

    func dismissRoute() {
        route = nil
    }

    /// Called when screenshot processing finishes. Auto-navigates to Review when
    /// at least one transaction was detected (even if some screenshots failed);
    /// otherwise stays on the import flow so the user can retry.
    func finishImportProcessing(detectedCount: Int) {
        route = detectedCount > 0 ? .review : .importPicker
    }
}
