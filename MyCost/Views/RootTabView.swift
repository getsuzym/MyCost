import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var ocrReviewStore = OCRTransactionReviewStore()
    @StateObject private var nav = AppNavigationModel()

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem { Label("Dashboard", systemImage: "chart.pie") }
            .accessibilityIdentifier("tab.dashboard")

            NavigationStack {
                RecurringPaymentsView()
            }
            .tabItem { Label("Recurring", systemImage: "repeat") }
            .accessibilityIdentifier("tab.recurring")

            NavigationStack {
                CategoryManagementView()
            }
            .tabItem { Label("Categories", systemImage: "folder") }
            .accessibilityIdentifier("tab.categories")

            NavigationStack {
                MerchantRulesView()
            }
            .tabItem { Label("Rules", systemImage: "wand.and.stars") }
            .accessibilityIdentifier("tab.rules")

            NavigationStack {
                MoreView()
            }
            .tabItem { Label("More", systemImage: "ellipsis.circle") }
            .accessibilityIdentifier("tab.more")
        }
        .environmentObject(ocrReviewStore)
        .environmentObject(nav)
        .safeAreaInset(edge: .top, spacing: 0) { reviewBanner }
        .toastHost()
        .sheet(item: $nav.route) { route in
            switch route {
            case .importPicker:
                NavigationStack { ImportView() }
                    .environmentObject(ocrReviewStore)
                    .environmentObject(nav)
            case .review:
                NavigationStack { ReviewTransactionsView() }
                    .environmentObject(ocrReviewStore)
                    .environmentObject(nav)
            }
        }
        .confirmationDialog(
            "Review session in progress",
            isPresented: $nav.isShowingImportConflict,
            titleVisibility: .visible
        ) {
            Button("Continue Current Review") { nav.continueCurrentReview() }
            Button("Replace with New Import", role: .destructive) { nav.replaceReview(session: ocrReviewStore) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You have \(ocrReviewStore.drafts.count) transaction\(ocrReviewStore.drafts.count == 1 ? "" : "s") still under review. Starting a new import replaces that session.")
        }
        .task {
            SeedDataService.seedDefaultCategoriesIfNeeded(modelContext: modelContext)
            SeedDataService.resetStaleSpendingOverridesIfNeeded(modelContext: modelContext)
        }
    }

    @ViewBuilder
    private var reviewBanner: some View {
        // Gate ONLY on the session, never on `nav.route`. Presenting/closing the
        // Review sheet must not add/remove this inset — that reflows the tab
        // content behind an animating sheet and trips `List`'s diff.
        if ocrReviewStore.hasActiveSession {
            Button {
                nav.openReview()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                    Text("\(ocrReviewStore.drafts.count) transaction\(ocrReviewStore.drafts.count == 1 ? "" : "s") awaiting review")
                        .lineLimit(1)
                    Spacer()
                    Text("Review").fontWeight(.semibold)
                    Image(systemName: "chevron.right").font(.caption)
                }
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("app.reviewBanner")
            .transition(.identity)
            .transaction { $0.animation = nil }
        }
    }
}
