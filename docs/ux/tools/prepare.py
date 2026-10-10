#!/usr/bin/env python3
"""Copies the app's SwiftUI sources into a throwaway SwiftPM package and neutralises side effects,
so docs/ux/tools/Render.swift can draw every screen with fake state. The app target is untouched.

Patches (copies only):
- KillSwitchApp.swift (the @main App) is left out;
- `private(set) var` -> `var`, top-level `private struct` -> `struct`, so the renderer can set state
  and reach the settings tabs;
- init bodies of KillSwitchControl / VPNClient / AutoConnector / FilterControl / LeakTester do
  nothing (no timers, no sudo, no keychain, no network monitor);
- the helper runner, proxy loading and the event log reader are no-ops; the keychain is a stub;
- the wizard opens on the step and install state set by Render.swift and does not run the leak test;
- «Трафик» does not read the helper's report or poll connections; «Проверить адрес» starts with
  `renderTrafficQuery`.

Usage: prepare.py <repo> <out-dir>
"""
import re
import shutil
import sys
from pathlib import Path

repo, out = Path(sys.argv[1]), Path(sys.argv[2])
src = out / "Sources" / "UXRender"
if out.exists():
    shutil.rmtree(out)
src.mkdir(parents=True)

files = [p for p in (repo / "App").glob("*.swift") if p.name != "KillSwitchApp.swift"]
files += list((repo / "App" / "Core").glob("*.swift")) + list((repo / "Shared").glob("*.swift"))


def replace_body(text: str, signature: str, body: str) -> str:
    """Replaces the body of the first declaration starting with `signature` (brace-matched)."""
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"signature not found: {signature}")
    open_brace = text.index("{", start + len(signature) - 1)
    depth, i = 0, open_brace
    while True:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return text[: open_brace + 1] + "\n" + body + "\n    " + text[i:]


patches = {
    "KillSwitchControl.swift": [
        ("    init() {", "    "),
        ("    func loadProxies(force: Bool = false) {", "        return"),
        ("    func refreshEvents() {", "        return"),
        # the state is set by Render.swift; a real refresh would ask ks and show its absence
        ("    func refresh() {", "        return"),
        ("    private static func exec(", "        (-1, \"\")"),
        # reading Happ's group container makes macOS ask "access data from other apps" and hangs
        ("    private static func readHappServers() -> [String] {", "        return []"),
        # «Трафик»: the report and the connections are set by Render.swift
        ("    func readRouting() {", "        return"),
        ("    func watchConnections(_ on: Bool) {", "        return"),
    ],
    "VPNClient.swift": [("    init(control: KillSwitchControl) {", "        self.control = control")],
    "AutoConnector.swift": [("    init(control: KillSwitchControl) {", "        self.control = control\n        super.init()")],
    "FilterControl.swift": [("    override init() {", "        super.init()")],
    "LeakTester.swift": [("    init() {", "    ")],
    "OnboardingView.swift": [("    private func rememberHome() {", "        return")],
}

for path in files:
    text = path.read_text()
    text = text.replace("private(set) var", "var")
    text = text.replace("if skipTrusted { requestLocation() }", "")   # no location prompt
    text = re.sub(r"(?m)^private struct", "struct", text)
    # no asset catalog in the renderer: the status icons are NSImages registered by name (Render.swift)
    text = text.replace("Image(status.icon)", "Image(nsImage: NSImage(named: status.icon) ?? NSImage())")
    if path.name == "TrafficView.swift":   # «Проверить адрес» opens with the address set by Render.swift
        text = text.replace("@State private var query = \"\"", "@State private var query = renderTrafficQuery")
    if path.name == "OnboardingView.swift":
        text = text.replace("control.serviceInstalled", "renderOnboarding.installed")
        text = text.replace("        index = 0\n", "        index = steps.firstIndex(of: renderOnboarding.step) ?? 0\n")
    for signature, body in patches.get(path.name, []):
        text = replace_body(text, signature, body)
    if path.name == "Keychain.swift":
        text = """import Foundation
enum Keychain {
    static func read(_ account: String) -> Data? { nil }
    @discardableResult static func write(_ account: String, _ data: Data) -> Bool { false }
    static func delete(_ account: String) {}
}
"""
    if path.name == "Notifier.swift":   # UNUserNotificationCenter throws outside an app bundle
        text = """import AppKit
@MainActor final class Notifier {
    static let shared = Notifier()
    weak var control: KillSwitchControl?
    weak var client: VPNClient?
    var openWindow: ((String) -> Void)?
    func post(_ notice: UserNotice) {}
}
"""
    if path.name == "Updater.swift":   # Sparkle is not linked into the renderer
        text = """import SwiftUI
@MainActor @Observable final class Updater {
    var canCheck = true
    var automaticallyUpdates = true
    func check() {}
}
struct CheckForUpdatesButton: View {
    let updater: Updater
    var body: some View { Button("Проверить обновления…") {} }
}
"""
    (src / path.name).write_text(text)

shutil.copy(Path(__file__).with_name("Render.swift"), src / "main.swift")
