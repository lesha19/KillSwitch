import CryptoKit
import Foundation
import IOKit

/// What the subscription server learns about this Mac (Remnawave's per-device limit).
enum DeviceInfo {
    /// Stable per Mac, survives reinstalling the app; the hardware UUID itself is not sent.
    static let hwid: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? Host.current().localizedName ?? "mac"
        let digest = SHA256.hash(data: Data(("KillSwitch:" + uuid).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }()

    /// e.g. "0.7", for the User-Agent.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }

    /// e.g. "Mac14,6".
    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let name = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? "Mac" : name
    }
}
