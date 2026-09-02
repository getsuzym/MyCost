import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct Toast: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case error
        case info
    }

    let id = UUID()
    var message: String
    var style: Style
}

/// One app-wide, non-blocking feedback channel. CRUD sites call `success` /
/// `error` **after** persistence resolves; a single toast is shown at a time —
/// a newer message replaces the current one, so rapid actions never overlap or
/// stack. Auto-dismisses; errors linger a little longer. Announced to VoiceOver.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?
    private let successDuration: Duration
    private let errorDuration: Duration
    /// Injected in tests so auto-dismiss can be asserted without real waiting.
    private let sleep: @Sendable (Duration) async -> Void

    init(
        successDuration: Duration = .seconds(2.5),
        errorDuration: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.successDuration = successDuration
        self.errorDuration = errorDuration
        self.sleep = sleep
    }

    func success(_ message: String) { show(Toast(message: message, style: .success)) }
    func error(_ message: String) { show(Toast(message: message, style: .error)) }
    func info(_ message: String) { show(Toast(message: message, style: .info)) }

    func show(_ toast: Toast) {
        dismissTask?.cancel()
        current = toast
        announce(toast.message)

        let duration = toast.style == .error ? errorDuration : successDuration
        dismissTask = Task { [weak self, sleep] in
            await sleep(duration)
            guard !Task.isCancelled else { return }
            if self?.current?.id == toast.id {
                self?.current = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    private func announce(_ message: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

/// Consistent CRUD feedback strings so every screen says the same thing.
enum CRUDFeedback {
    enum Action { case add, update, delete }

    /// The single rule for CRUD feedback: a success message **only** when
    /// persistence succeeded, otherwise an error toast. Call sites do
    /// `toast.show(CRUDFeedback.result(.add, "transaction", persisted: didSave))`.
    static func result(_ action: Action, _ noun: String, count: Int = 1, persisted: Bool) -> Toast {
        guard persisted else {
            return Toast(
                message: action == .delete ? deleteFailure(noun) : saveFailure(noun),
                style: .error
            )
        }
        let message: String
        switch action {
        case .add: message = added(noun, count: count)
        case .update: message = updated(noun, count: count)
        case .delete: message = deleted(noun, count: count)
        }
        return Toast(message: message, style: .success)
    }

    static func added(_ noun: String, count: Int = 1) -> String {
        count == 1 ? "\(noun.capitalizedFirst) added" : "\(count) \(noun)s added"
    }

    static func updated(_ noun: String, count: Int = 1) -> String {
        count == 1 ? "\(noun.capitalizedFirst) updated" : "\(count) \(noun)s updated"
    }

    static func deleted(_ noun: String, count: Int = 1) -> String {
        count == 1 ? "\(noun.capitalizedFirst) deleted" : "\(count) \(noun)s deleted"
    }

    static func saveFailure(_ noun: String) -> String {
        "Couldn\u{2019}t save \(noun). Please try again."
    }

    static func deleteFailure(_ noun: String) -> String {
        "Couldn\u{2019}t delete \(noun). Please try again."
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
