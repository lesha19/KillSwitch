import Foundation

/// #11: the update check (Sparkle) could not reach the appcast, which with protection on and the
/// VPN off is the kill switch doing its job. It is asked again once our VPN connects.
enum UpdateRetry {
    /// Posted by KillSwitchControl when our VPN's tunnel comes up.
    static let vpnConnected = Notification.Name("KillSwitchVPNConnected")

    /// A URL error, or one wrapped by Sparkle (its download error), but not a cancelled request.
    static func isNetworkFailure(_ error: Error?, depth: Int = 0) -> Bool {
        guard let error = error as NSError?, depth < 4 else { return false }
        if error.domain == NSURLErrorDomain { return error.code != NSURLErrorCancelled }
        return isNetworkFailure(error.userInfo[NSUnderlyingErrorKey] as? Error, depth: depth + 1)
    }
}
