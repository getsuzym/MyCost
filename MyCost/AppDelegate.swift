import UIKit

/// Bridges Home Screen quick actions (long-press the app icon) into SwiftUI.
/// The static items themselves are declared in Info.plist
/// (`UIApplicationShortcutItems`); this only captures *which one* was tapped
/// so `RootTabView` can act on it once the app is foregrounded and its view
/// hierarchy exists — there's no SwiftUI-native hook for shortcut activation,
/// so `pendingShortcutType` is the hand-off point (`RootTabView` clears it
/// after acting, via `.onChange(of: scenePhase)` going `.active`).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var pendingShortcutType: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            Self.pendingShortcutType = shortcut.type
        }
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        Self.pendingShortcutType = shortcutItem.type
        completionHandler(true)
    }
}

/// The two static shortcut identifiers, matching `UIApplicationShortcutItemType`
/// in Info.plist exactly.
enum QuickAction {
    static let addTransaction = "com.getsuzym.MyCost.addTransaction"
    static let importScreenshots = "com.getsuzym.MyCost.importScreenshots"
}
