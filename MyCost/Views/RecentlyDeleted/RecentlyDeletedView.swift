import SwiftData
import SwiftUI

/// More -> Manage -> Recently Deleted. Every transaction `TrashBin` has fully
/// deleted (past the 4-second Undo window) lands here as a
/// `DeletedTransactionRecord` for 30 days before being purged for good.
struct RecentlyDeletedView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DeletedTransactionRecord.deletedAt, order: .reverse) private var records: [DeletedTransactionRecord]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var tags: [Tag]

    @State private var pendingPurge: DeletedTransactionRecord?

    private let service = RecentlyDeletedService()

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView("No Recently Deleted Transactions", systemImage: "trash")
            } else {
                Section {
                    ForEach(records) { record in
                        RecentlyDeletedRow(record: record)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingPurge = record
                                } label: {
                                    Label("Delete Permanently", systemImage: "trash")
                                }
                                .accessibilityIdentifier("recentlyDeleted.purge")

                                Button {
                                    restore(record)
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(Theme.accent)
                                .accessibilityIdentifier("recentlyDeleted.restore")
                            }
                    }
                } footer: {
                    Text("Deleted transactions stay here for \(RecentlyDeletedService.retentionDays) days, then are removed permanently. Restoring doesn't bring back its splits or a recurring-series link.")
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .themedListBackground()
        .task {
            service.purgeExpired(records, modelContext: modelContext)
        }
        .confirmationDialog(
            "Delete this permanently?",
            isPresented: Binding(get: { pendingPurge != nil }, set: { if !$0 { pendingPurge = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let pendingPurge {
                    service.deletePermanently(pendingPurge, modelContext: modelContext)
                    ToastCenter.shared.success("Deleted permanently")
                }
                pendingPurge = nil
            }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: {
            if let pendingPurge {
                Text("\(pendingPurge.merchantName) can't be recovered after this.")
            }
        }
    }

    private func restore(_ record: DeletedTransactionRecord) {
        service.restore(record, categories: categories, tags: tags, modelContext: modelContext)
        ToastCenter.shared.success("\(record.merchantName) restored")
    }
}

private struct RecentlyDeletedRow: View {
    let record: DeletedTransactionRecord

    private var daysRemaining: Int {
        RecentlyDeletedService.daysRemaining(for: record)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.merchantName).font(.body).lineLimit(1)
                Spacer()
                Text(Formatters.currencyString(for: record.amount))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(record.categoryName ?? "Uncategorized")
                Text("·")
                Text("Deleted \(Formatters.shortDate.string(from: record.deletedAt))")
                Text("·")
                Text(daysRemaining == 0 ? "Removed today" : "\(daysRemaining) day\(daysRemaining == 1 ? "" : "s") left")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .opacity(0.75)
    }
}
