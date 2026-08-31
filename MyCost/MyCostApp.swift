import SwiftData
import SwiftUI

@main
struct MyCostApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema([
                Transaction.self,
                Category.self,
                MerchantRule.self,
                RecurringPayment.self
            ])
            let isUITesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITesting)
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
    }
}
