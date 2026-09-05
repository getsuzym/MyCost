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
    /// Persisted drag offset of the review button from its resting spot
    /// (bottom-trailing, where it first shipped). `x <= 0` moves it left, `y <=
    /// 0` moves it up; `(0, 0)` is the default resting position.
    @AppStorage("mycost.reviewButton.offsetX") private var reviewButtonOffsetX = 0.0
    @AppStorage("mycost.reviewButton.offsetY") private var reviewButtonOffsetY = 0.0
    @State private var reviewButtonDragOffset: CGSize = .zero
    /// True while a drag is in progress so the `Button`'s own action (which
    /// SwiftUI may still fire on release) is suppressed for that one gesture.
    @State private var reviewButtonIsDragging = false

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
        // The review affordance is a draggable floating button, drawn as an
        // `.overlay` on the TabView — NOT a `.safeAreaInset` and NOT a `VStack`
        // sibling. Earlier shapes each had problems: a top safeAreaInset
        // collided with a pushed screen's own nav bar / `.searchable` field; a
        // bottom safeAreaInset applied straight to a TabView fought the tab
        // bar's own bottom-safe-area handling and hid the tab bar entirely; a
        // full-width VStack sibling worked but ate a strip of vertical space on
        // every screen and crowded the tab bar. An overlay changes nothing
        // about the content's layout (so toggling it on/off as the session
        // starts/ends can't reflow a `List` behind an animating sheet), and a
        // compact button the user can drag out of the way overlaps neither the
        // tab bar (it stays above it) nor any screen's nav chrome.
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
        .overlay(alignment: .bottomTrailing) {
            reviewFloatingButton
        }
        .environmentObject(ocrReviewStore)
        .environmentObject(nav)
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
            seedReviewSessionForUITestingIfRequested()
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

    /// `-ui-testing-seed-review` seeds a fake review session on launch so a UI
    /// test can verify the banner (which otherwise only appears after a real
    /// OCR import, which XCUITest can't easily drive) — specifically, that it
    /// never obscures the tab bar or a pushed screen's own nav chrome.
    private func seedReviewSessionForUITestingIfRequested() {
        guard isUITesting, ProcessInfo.processInfo.arguments.contains("-ui-testing-seed-review") else { return }
        let candidates = (1...2).map { index in
            TransactionCandidate(
                detectedDate: .now,
                rawMerchantDescription: "Test Merchant \(index)",
                amount: Decimal(10 * index),
                status: .posted,
                originalOCRText: "Test Merchant \(index) $\(10 * index).00",
                sourceText: "Test Merchant \(index) $\(10 * index).00",
                confidence: .empty,
                validationFlags: []
            )
        }
        ocrReviewStore.replaceCandidates(candidates)
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
    private var reviewFloatingButton: some View {
        // Gate ONLY on the session, never on `nav.route`. As an `.overlay` its
        // add/remove doesn't reflow the tab content; `.transition(.identity)`
        // keeps it from sliding in/out behind a dismissing sheet.
        if ocrReviewStore.hasActiveSession {
            let count = ocrReviewStore.drafts.count
            // The button rests bottom-trailing with this padding — the exact
            // layout that passes the "never obscures the tab bar / nav chrome"
            // UI test — and a real `Button` keeps its `.buttons[…]` /
            // `isHittable` semantics. A drag only adds a clamped, persisted
            // `.offset` from there (never past the resting spot on either axis,
            // so it can't slide under the tab bar), and snaps to the nearer
            // side edge on release.
            let screen = UIScreen.main.bounds.size
            let margin: CGFloat = 18
            let bottomInset: CGFloat = 66
            let leftLimit = -max(screen.width - 52 - margin * 2, 0)
            let topLimit = -max(screen.height - 52 - bottomInset - 80, 0)
            let dx = min(max(reviewButtonOffsetX + reviewButtonDragOffset.width, leftLimit), 0)
            let dy = min(max(reviewButtonOffsetY + reviewButtonDragOffset.height, topLimit), 0)

            Button {
                guard !reviewButtonIsDragging else { return }
                nav.openReview()
            } label: {
                reviewButtonIcon(count: count)
            }
            .buttonStyle(.plain)
            .offset(x: dx, y: dy)
            .padding(.trailing, margin)
            .padding(.bottom, bottomInset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        reviewButtonIsDragging = true
                        reviewButtonDragOffset = value.translation
                    }
                    .onEnded { value in
                        let newX = min(max(reviewButtonOffsetX + value.translation.width, leftLimit), 0)
                        let newY = min(max(reviewButtonOffsetY + value.translation.height, topLimit), 0)
                        reviewButtonDragOffset = .zero
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            reviewButtonOffsetX = newX < leftLimit / 2 ? leftLimit : 0
                            reviewButtonOffsetY = newY
                        }
                        // The Button's action fires right after this on release;
                        // clear the flag on the next tick so it's suppressed
                        // exactly once.
                        DispatchQueue.main.async { reviewButtonIsDragging = false }
                    }
            )
            .accessibilityIdentifier("app.reviewBanner")
            .accessibilityLabel("\(count) transaction\(count == 1 ? "" : "s") awaiting review")
            .accessibilityHint("Opens the review screen. Drag to reposition.")
            .transition(.identity)
        }
    }

    private func reviewButtonIcon(count: Int) -> some View {
        Image(systemName: "checklist")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(Theme.accent, in: Circle())
            .overlay(alignment: .topTrailing) {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Color.red, in: Capsule())
                    .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 6, y: -6)
            }
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
            .contentShape(Circle())
    }
}
