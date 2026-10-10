// Checks Filter/TrustedCode.swift against real binaries. Run with scripts/test-filter-trust.sh.
// Fixtures (made by the script): FIXTURES/forged (ad-hoc, our core's identifier), FIXTURES/unsigned,
// FIXTURES/dev-core and FIXTURES/dev-other (signed with our Apple Development identity, if any),
// FIXTURES/devid-core (our Developer ID, if any), FIXTURES/signed-core (scripts/sign-core.sh's
// default identity), FIXTURES/adhoc-mihomo (Helper/mihomo re-signed ad-hoc, if present).
import Foundation
import Security

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checked = 0

func program(at path: String) -> TrustedCode.Program? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
          let code else { return nil }
    return TrustedCode.program { SecStaticCodeCheckValidity(code, [], $0) == errSecSuccess }
}

func expect(_ path: String, _ expected: TrustedCode.Program?, _ what: String) {
    guard FileManager.default.fileExists(atPath: path) else { print("skip  \(what): not on this Mac"); return }
    checked += 1
    let got = program(at: path)
    if got == expected {
        print("ok    \(what)")
    } else {
        failures += 1
        print("FAIL  \(what): \(path) -> \(got.map { "\($0)" } ?? "nil"), expected \(expected.map { "\($0)" } ?? "nil")")
    }
}

let fixtures = CommandLine.arguments[1]

// The audit's bypass: a binary at a trusted path or with a trusted name proves nothing.
expect("\(fixtures)/forged", nil, "ad-hoc binary with our core's identifier is not trusted")
expect("\(fixtures)/unsigned", nil, "unsigned binary is not trusted")
expect("\(fixtures)/adhoc-mihomo", nil, "ad-hoc (upstream) mihomo is not trusted")
expect("/opt/homebrew/opt/tailscale/bin/tailscaled", nil, "ad-hoc Homebrew tailscaled is not trusted")
expect("\(NSHomeDirectory())/Library/Application Support/app.dropweb/cores/DropwebCore", nil,
       "ad-hoc DropwebCore is not trusted")
expect("/usr/bin/true", nil, "Apple's own binaries are not trusted")

// Real signatures still match.
expect("\(fixtures)/dev-core", .core, "core signed by team YR58655PJ7 is trusted")
expect("\(fixtures)/dev-other", nil, "other code of our team is not the core")
expect("\(fixtures)/devid-core", .core, "core signed with our Developer ID is trusted")
expect("\(fixtures)/signed-core", .core, "core signed by scripts/sign-core.sh is trusted")
expect("/Applications/Tailscale.app", .tailscale, "Tailscale app (App Store) is trusted")
expect("/Applications/Tailscale.app/Contents/PlugIns/IPNExtension.appex", .tailscale,
       "Tailscale network extension is trusted")

print("\(checked) checked, \(failures) failed")
exit(failures == 0 && checked > 0 ? 0 : 1)
