import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var ocrReviewStore = OCRTransactionReviewStore()

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
            .environmentObject(ocrReviewStore)
            .tabItem {
                Label("Import", systemImage: "square.and.arrow.down")
            }

            NavigationStack {
                ReviewTransactionsView()
            }
            .environmentObject(ocrReviewStore)
            .tabItem {
                Label("Review", systemImage: "checklist")
            }

            NavigationStack {
                MerchantRulesView()
            }
            .tabItem {
                Label("Rules", systemImage: "wand.and.stars")
            }

            NavigationStack {
                CategoryManagementView()
            }
            .tabItem {
                Label("Categories", systemImage: "folder")
            }
            .accessibilityIdentifier("tab.categories")

            NavigationStack {
                RecurringPaymentsView()
            }
            .tabItem {
                Label("Recurring", systemImage: "repeat")
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
