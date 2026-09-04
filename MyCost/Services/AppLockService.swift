import Foundation
import LocalAuthentication

/// Thin wrapper over `LocalAuthentication` so the lock screen doesn't touch
/// `LAContext` directly. `.deviceOwnerAuthentication` (not the biometrics-only
/// policy) so it still works via passcode on devices without Face ID/Touch ID
/// or when biometrics are temporarily unavailable.
struct AppLockService {
    /// Whether the device can authenticate at all (biometrics or passcode set).
    /// The Settings toggle checks this before enabling the lock, so the user
    /// never ends up locked out with no way to unlock.
    func canAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }
}
