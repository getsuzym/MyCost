import Foundation
import SwiftData

/// Deferred deletion so a delete can be undone. Deleting a transaction doesn't
/// touch SwiftData immediately: the id(s) go into `pendingDeletionIDs` (which
/// every delete-capable transaction list filters out, so the row disappears
/// right away) and the real `modelContext.delete` + save happens after a grace
/// period unless `cancel(_:)` is called first from the toast's Undo action.
///
/// UI-layer, presentation-only state — deliberately not threaded into
/// `SpendingAnalytics` or any other pure service, so Dashboard-style totals
/// computed from a *different* screen's `@Query` can lag the grace period by a
/// few seconds. That's an accepted trade-off, not a bug: the deletion hasn't
/// actually happened yet.
@MainActor
final class TrashBin: ObservableObject {
    static let shared = TrashBin()

    @Published private(set) var pendingDeletionIDs: Set<UUID> = []

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var idsByToken: [UUID: Set<UUID>] = [:]

    private let delay: Duration
    /// Injected in tests so the grace period doesn't require real waiting.
    private let sleep: @Sendable (Duration) async -> Void

    init(
        delay: Duration = .seconds(4),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.delay = delay
        self.sleep = sleep
    }

    func contains(_ id: UUID) -> Bool { pendingDeletionIDs.contains(id) }

    /// Marks `ids` as pending deletion and schedules `perform` (the real
    /// `modelContext.delete` + save) after the grace period. Returns a token —
    /// pass it to `cancel(_:)` to undo.
    @discardableResult
    func scheduleDeletion(ids: [UUID], perform: @escaping () -> Void) -> UUID {
        let token = UUID()
        idsByToken[token] = Set(ids)
        pendingDeletionIDs.formUnion(ids)
        tasks[token] = Task { [weak self, sleep, delay] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.idsByToken[token] != nil else { return }
                self.idsByToken[token] = nil
                self.tasks[token] = nil
                self.pendingDeletionIDs.subtract(ids)
                perform()
            }
        }
        return token
    }

    /// Cancels a pending batch — the ids are no longer filtered out, and
    /// `perform` never runs.
    func cancel(_ token: UUID) {
        guard let ids = idsByToken[token] else { return }
        tasks[token]?.cancel()
        tasks[token] = nil
        idsByToken[token] = nil
        pendingDeletionIDs.subtract(ids)
    }

    /// The shared "delete these transactions, with Undo" flow every delete
    /// site (`TransactionHistoryView`, `TransactionDetailView`,
    /// `CategoryDetailView`, `MonthDetailView`) uses: the rows vanish
    /// immediately (`pendingDeletionIDs`, which each view's list filters on),
    /// a toast offers Undo for the grace period, and only after that
    /// (uncancelled) does the real `modelContext.delete` + save happen.
    func deleteTransactions(_ transactions: [Transaction], modelContext: ModelContext) {
        guard !transactions.isEmpty else { return }
        let ids = transactions.map(\.id)
        let token = scheduleDeletion(ids: ids) {
            transactions.forEach(modelContext.delete)
            modelContext.saveOrLog("undoable delete transaction(s)")
        }
        let message = CRUDFeedback.deleted("transaction", count: transactions.count)
        ToastCenter.shared.show(Toast(
            message: message,
            style: .success,
            actionLabel: "Undo",
            action: { [weak self] in self?.cancel(token) }
        ))
    }
}
