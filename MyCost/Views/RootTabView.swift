import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var ocrReviewStore = OCRTransactionReviewStore()
    @StateObject private var nav = AppNavigationModel()
    @AppStorage("mycost.hasOnboarded") private var hasOnboarded = false
    @AppStorage("mycost.appLockEnabled") private var appLockEnabled = false
    /// 0 = require unlock immediately on every return to foreground; otherwise
    /// the number of minutes the app tolerates being backgrounded before it
    /// re-locks — same "Require Passcode: Immediately / After 5 Minutes / …"
    /// idea as iOS's own Face ID & Passcode setting.
    @AppStorage("mycost.appLockGraceMinutes") private var appLockGraceMinutes = 0
    /// When the app was last backgrounded, so returning to foreground can
    /// measure elapsed time against `appLockGraceMinutes`. Persisted (not just
    /// `@State`) so the grace period survives the app being suspended *or*
    /// terminated and relaunched while backgrounded.
    @AppStorage("mycost.appLockLastBackgroundedAt") private var lastBackgroundedTimestamp: Double = 0
    /// Starts already-locked on a cold launch when App Lock is on, unless
    /// still within the grace period from before the app was last backgrounded
    /// — so the content never flashes before the lock screen appears, but a
    /// force-quit-and-reopen inside the grace window doesn't re-prompt either.
    @State private var isLocked: Bool
    /// Set by a Home Screen quick action (long-press the app icon).
    @State private var isShowingQuickAddTransaction = false

    init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "mycost.appLockEnabled")
        let uiTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let graceMinutes = defaults.integer(forKey: "mycost.appLockGraceMinutes")
        let lastBackgrounded = defaults.double(forKey: "mycost.appLockLastBackgroundedAt")
        let withinGrace = AppLockService.isWithinGrace(graceMinutes: graceMinutes, lastBackgroundedAt: lastBackgrounded)
        _isLocked = State(initialValue: enabled && !uiTesting && !withinGrace)
    }

    /// UI tests launch straight into the tabs; the intro cover would swallow
    /// their taps.
    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

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
                MoreView()
            }
            .tabItem { Label("More", systemImage: "ellipsis.circle") }
            .accessibilityIdentifier("tab.more")
        }
        .tint(Theme.accent)
        .environmentObject(ocrReviewStore)
        .environmentObject(nav)
        .safeAreaInset(edge: .bottom, spacing: 0) { reviewBanner }
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
            SeedDataService.countAllTransactionsByDefaultIfNeeded(modelContext: modelContext)
            SeedDataService.tagLikelyIncomeIfNeeded(modelContext: modelContext)
        }
        .fullScreenCover(isPresented: showOnboarding) {
            OnboardingView()
        }
        .fullScreenCover(isPresented: $isLocked) {
            AppLockView(isLocked: $isLocked)
        }
        .sheet(isPresented: $isShowingQuickAddTransaction) {
            NavigationStack { TransactionEditorView(mode: .add) }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard appLockEnabled, !isUITesting else { return }
            switch newPhase {
            case .background:
                lastBackgroundedTimestamp = Date.now.timeIntervalSinceReferenceDate
                // A zero grace period is "Immediately" — lock right away so
                // nothing sensitive lingers on screen. With a grace period,
                // relocking is deferred to the check on return to foreground
                // below (matching iOS's own passcode grace-period behavior:
                // the content stays as-is during that window).
                if appLockGraceMinutes == 0 {
                    isLocked = true
                }
            case .active:
                // Only a real `.background` sets this — skip when it's 0 so a
                // Control Center pull-down or similar `.inactive` blip (which
                // never actually backgrounds the app) can't trigger a false
                // relock mid-use.
                guard lastBackgroundedTimestamp > 0 else { break }
                let withinGrace = AppLockService.isWithinGrace(graceMinutes: appLockGraceMinutes, lastBackgroundedAt: lastBackgroundedTimestamp)
                lastBackgroundedTimestamp = 0 // consumed; a future background starts a fresh window
                if !withinGrace {
                    isLocked = true
                }
            default:
                break
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            handlePendingShortcutIfUnlocked()
        }
        .onChange(of: isLocked) { _, locked in
            guard !locked else { return }
            handlePendingShortcutIfUnlocked()
        }
    }

    /// A quick action tapped while the app was locked stays pending — this
    /// fires again once `isLocked` clears, so it isn't lost, but also never
    /// jumps straight to "Add Transaction" past the lock screen.
    private func handlePendingShortcutIfUnlocked() {
        guard !isLocked, !isUITesting, let type = AppDelegate.pendingShortcutType else { return }
        AppDelegate.pendingShortcutType = nil
        switch type {
        case QuickAction.addTransaction:
            isShowingQuickAddTransaction = true
        case QuickAction.importScreenshots:
            nav.requestImport(session: ocrReviewStore)
        default:
            break
        }
    }

    private var showOnboarding: Binding<Bool> {
        Binding(
            get: { !hasOnboarded && !isUITesting },
            set: { presented in if !presented { hasOnboarded = true } }
        )
    }

    @ViewBuilder
    private var reviewBanner: some View {
        // Gate ONLY on the session, never on `nav.route`. Presenting/closing the
        // Review sheet must not add/remove this inset — that reflows the tab
        // content behind an animating sheet and trips `List`'s diff.
        //
        // Bottom edge, not top: a top safeAreaInset visually collided with a
        // pushed screen's own nav bar / `.searchable` field (they'd render
        // overlapping instead of the bar being pushed cleanly below it). The
        // bottom edge — a mini-player-style bar sitting right above the tab
        // bar — has no such chrome to collide with.
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
                .padding(.vertical, 12)
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
