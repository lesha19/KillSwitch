import AppKit

/// #35: Sparkle replaces the app only after it has quit (its agent sends a Quit Apple event and
/// waits), then opens it again. AppKit refuses that event, without asking the app delegate, while
/// a window has a sheet: on 2026-10-11 «Начало работы» was open and 0.16.0 kept running
/// («App termination blocked by modal sheet»). So the sheets are closed before Sparkle asks, and a
/// newer build that is on disk while the old one runs is relaunched.
enum UpdateRelaunch {
    /// Ends every sheet of `windows` (NSApp.windows); returns how many.
    @MainActor @discardableResult
    static func closeSheets(_ windows: [some SheetHost]) -> Int {
        var closed = 0
        for window in windows {
            while let sheet = window.attachedSheet {
                window.endSheet(sheet)
                closed += 1
            }
        }
        return closed
    }

    /// CFBundleVersion of the bundle at `bundleURL`, read from the file each time (Bundle keeps the
    /// Info.plist it read at launch).
    static func buildOnDisk(_ bundleURL: URL) -> String? {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    /// Another build is installed where this one was started from.
    static func isPending(running: String?, onDisk: String?) -> Bool {
        guard let running, let onDisk else { return false }
        return running != onDisk
    }

    /// `/bin/sh` arguments that wait for process `pid` to end, then open the bundle (the new build).
    static func relaunchArguments(pid: Int32, bundlePath: String) -> [String] {
        ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
         "sh", String(pid), bundlePath]
    }

    /// #51: a relaunch for an update while the window is closed marks the time under this key; the
    /// new build then starts without the window, as the old one was left.
    static let windowlessKey = "relaunchWithoutWindow"
    static let windowlessFor: TimeInterval = 600

    /// Only a launch soon after the mark: a relaunch that never came must not hide the next start.
    static func startsWithoutWindow(markedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let markedAt else { return false }
        return now >= markedAt && now - markedAt <= windowlessFor
    }
}

/// A window that can carry sheets: NSWindow, or a stand-in in the tests (an NSWindow sheet is only
/// attached with a running application).
@MainActor
protocol SheetHost {
    var attachedSheet: NSWindow? { get }
    func endSheet(_ sheet: NSWindow)
}

extension NSWindow: SheetHost {}
