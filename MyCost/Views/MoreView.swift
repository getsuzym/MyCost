import SwiftUI

/// The "More" tab — a drill-down list to the secondary management screens that
/// no longer have their own bottom tab.
struct MoreView: View {
    @EnvironmentObject private var ocrReviewStore: OCRTransactionReviewStore
    @EnvironmentObject private var nav: AppNavigationModel
    @AppStorage("mycost.appLockEnabled") private var appLockEnabled = false
    @State private var showsNoPasscodeAlert = false

    private let lockService = AppLockService()

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

            Section("Manage") {
                NavigationLink {
                    TransactionHistoryView()
                } label: {
                    Label("All Transactions", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("more.transactions")

                NavigationLink {
                    BudgetsView()
                } label: {
                    Label("Budgets", systemImage: "chart.bar.doc.horizontal")
                }
                .accessibilityIdentifier("more.budgets")

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
                    DataPortabilityView()
                } label: {
                    Label("Export & Backup", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("more.data")
            }

            Section {
                Toggle("Require Face ID / Passcode", isOn: Binding(
                    get: { appLockEnabled },
                    set: { newValue in
                        if newValue, !lockService.canAuthenticate() {
                            showsNoPasscodeAlert = true
                            return
                        }
                        appLockEnabled = newValue
                    }
                ))
                .accessibilityIdentifier("more.appLock")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Locks MyCost whenever it leaves the foreground. Unlocks with Face ID, Touch ID, or your device passcode.")
            }
        }
        .navigationTitle("More")
        .themedListBackground()
        .alert("Can't Enable App Lock", isPresented: $showsNoPasscodeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set a passcode for this device in Settings first.")
        }
    }
}
