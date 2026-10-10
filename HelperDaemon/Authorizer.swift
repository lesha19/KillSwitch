import Foundation
import Security

/// The root side of the authorization (ADR 0010). The app obtains `HelperRight.name` in its own
/// AuthorizationRef (macOS's dialog: password, or Touch ID where offered) and sends the external
/// form; here it is checked without any interaction: a granted, unexpired right passes, anything
/// else does not.
enum Authorizer {
    /// Puts our definition in place if the stored one differs (or is missing). Root may modify any
    /// right (`config.modify.`: is-root). False when the right is still not ours afterwards.
    @discardableResult
    static func ensureRight() -> Bool {
        if HelperRight.matches(stored()) { return true }
        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, []) }
        let status = AuthorizationRightSet(ref, HelperRight.name, HelperRight.definition as CFDictionary,
                                           "KillSwitch хочет изменить настройки защиты." as CFString, nil, nil)
        if status != errAuthorizationSuccess { Log.daemon.error("AuthorizationRightSet: \(status)") }
        return HelperRight.matches(stored())
    }

    private static func stored() -> [String: Any]? {
        var definition: CFDictionary?
        guard AuthorizationRightGet(HelperRight.name, &definition) == errAuthorizationSuccess else { return nil }
        return definition as? [String: Any]
    }

    /// The external form names an authorization that holds our right now. The definition is
    /// checked first every time: a weaker one (planted, or changed by hand) fails closed.
    static func check(_ externalForm: Data) -> Bool {
        guard externalForm.count == MemoryLayout<AuthorizationExternalForm>.size, ensureRight() else { return false }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { _ = externalForm.copyBytes(to: $0) }
        var ref: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &ref) == errAuthorizationSuccess, let ref else { return false }
        // without kAuthorizationFlagDestroyRights: the credential stays the app's for the next 5 minutes
        defer { AuthorizationFree(ref, []) }
        return HelperRight.name.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(ref, &rights, nil, [.extendRights], nil) == errAuthorizationSuccess
            }
        }
    }
}
