import SwiftUI

/// Full-screen blocker shown when App Lock is on and the app just came to the
/// foreground. Prompts automatically on appear; "Unlock" retries by hand (the
/// system also offers this after a failed/cancelled attempt).
struct AppLockView: View {
    @Binding var isLocked: Bool
    @State private var authFailed = false

    private let lockService = AppLockService()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text("MyCost is Locked")
                .font(.title2.bold())
            if authFailed {
                Text("Authentication failed. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Unlock") { authenticate() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .accessibilityIdentifier("appLock.unlock")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear(perform: authenticate)
    }

    private func authenticate() {
        lockService.authenticate(reason: "Unlock MyCost") { success in
            if success {
                authFailed = false
                isLocked = false
            } else {
                authFailed = true
            }
        }
    }
}
