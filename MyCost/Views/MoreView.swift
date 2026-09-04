import SwiftData
import SwiftUI

/// The "More" tab — a drill-down list to the secondary management screens that
/// no longer have their own bottom tab. Every preference/toggle lives in
/// Settings, not scattered across these rows or on Dashboard/Recurring.
struct MoreView: View {
    @EnvironmentObject private var ocrReviewStore: OCRTransactionReviewStore
    @EnvironmentObject private var nav: AppNavigationModel
    @Query private var deletedRecords: [DeletedTransactionRecord]

    var body: some View {
        List {
            if ocrReviewStore.hasActiveSession {
                Section {
                    Button {
                        nav.openReview()
                    } label: {
                        Label("Review \(ocrReviewStore.drafts.count) transaction\(ocrReviewStore.drafts.count == 1 ? "" : "s")",
                              systemImage: "checklist")
                    }
                    .accessibilityIdentifier("more.review")
                }
            }

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("more.settings")
            }

            Section {
                NavigationLink {
                    CategoryManagementView()
                } label: {
                    Label("Categories", systemImage: "folder")
                }
                .accessibilityIdentifier("more.categories")

                NavigationLink {
                    MerchantRulesView()
                } label: {
                    Label("Merchant Rules", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("more.rules")
            } header: {
                Text("Organize")
            } footer: {
                Text("How transactions get sorted and named — visited occasionally, not daily, so these moved off the main tab bar.")
            }

            Section("Manage") {
                NavigationLink {
                    TransactionHistoryView()
                } label: {
                    Label("All Transactions", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("more.transactions")

                NavigationLink {
                    TagManagementView()
                } label: {
                    Label("Tags", systemImage: "tag")
                }
                .accessibilityIdentifier("more.tags")

                NavigationLink {
                    AccountsView()
                } label: {
                    Label("Accounts", systemImage: "creditcard")
                }
                .accessibilityIdentifier("more.accounts")

                NavigationLink {
                    RecentlyDeletedView()
                } label: {
                    HStack {
                        Label("Recently Deleted", systemImage: "trash")
                        if !deletedRecords.isEmpty {
                            Spacer()
                            Text("\(deletedRecords.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("more.recentlyDeleted")
            }
        }
        .navigationTitle("More")
        .themedListBackground()
    }
}
