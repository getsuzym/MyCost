import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label("Dashboard", systemImage: "chart.pie")
            }
            .accessibilityIdentifier("tab.dashboard")

            NavigationStack {
                ImportView()
            }
            .tabItem {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            NavigationStack {
                ReviewTransactionsView()
            }
            .tabItem {
                Label("Review", systemImage: "checklist")
            }

            NavigationStack {
                TransactionHistoryView()
            }
            .tabItem {
                Label("History", systemImage: "list.bullet")
            }
            .accessibilityIdentifier("tab.history")
        }
        .task {
            SeedDataService.seedDefaultCategoriesIfNeeded(modelContext: modelContext)
        }
    }
}
