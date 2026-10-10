import Foundation
import Security

/// install.sh, uninstall.sh and the helper they install run as root from the app bundle, which
/// the user can write to: before that, the bundle's signature (with every nested part and every
/// sealed resource, Helper/ included) must still be intact and ours.
enum BundleSignature {
    /// A certificate issued by Apple to our team (Developer ID or Apple Development).
    static let ourTeam = #"anchor apple generic and certificate leaf[subject.OU] = "YR58655PJ7""#

    static func isValid(_ bundle: URL, requirement text: String = ourTeam) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
