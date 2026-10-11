import Foundation
import Security

/// The app's AuthorizationRef, kept for the app's lifetime: the right is not shared, so its
/// credential (5 minutes) lives here. One dialog at a time, off the main thread. `killswitch`
/// has its own, for one run (ADR 0025).
final class AppAuthorization: @unchecked Sendable {
    enum Result: Sendable { case granted(Data), cancelled, failed(String) }

    private let lock = NSLock()
    private var ref: AuthorizationRef?

    /// The text of macOS's dialog.
    static let prompt = "KillSwitch хочет изменить настройки защиты."

    func obtain() async -> Result {
        await Task.detached(priority: .userInitiated) { self.obtainNow() }.value
    }

    private func obtainNow() -> Result {
        lock.lock()
        defer { lock.unlock() }
        if ref == nil, AuthorizationCreate(nil, nil, [], &ref) != errAuthorizationSuccess { ref = nil }
        guard let ref else { return .failed("AuthorizationCreate") }
        let status = HelperRight.name.withCString { name in
            kAuthorizationEnvironmentPrompt.withCString { promptKey in
                var text = Array(Self.prompt.utf8)
                return text.withUnsafeMutableBytes { promptBytes in
                    var right = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                    var prompt = AuthorizationItem(name: promptKey, valueLength: promptBytes.count,
                                                   value: promptBytes.baseAddress, flags: 0)
                    return withUnsafeMutablePointer(to: &right) { rightPointer in
                        withUnsafeMutablePointer(to: &prompt) { promptPointer in
                            var rights = AuthorizationRights(count: 1, items: rightPointer)
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            return AuthorizationCopyRights(ref, &rights, &environment, [.interactionAllowed, .extendRights], nil)
                        }
                    }
                }
            }
        }
        switch status {
        case errAuthorizationSuccess: break
        case errAuthorizationCanceled: return .cancelled
        default: return .failed("Нет подтверждения администратора (\(status))")
        }
        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(ref, &form) == errAuthorizationSuccess else { return .failed("AuthorizationMakeExternalForm") }
        return .granted(withUnsafeBytes(of: &form) { Data($0) })
    }
}
