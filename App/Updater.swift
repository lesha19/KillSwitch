import Sparkle
import SwiftUI

/// Sparkle 2. Feed URL, EdDSA public key and the daily schedule live in Info.plist (project.yml).
@MainActor
@Observable
final class Updater {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            MainActor.assumeIsolated { self?.canCheck = value }
        }
    }

    func check() { controller.updater.checkForUpdates() }
}

struct CheckForUpdatesButton: View {
    let updater: Updater

    var body: some View {
        Button("Проверить обновления…") { updater.check() }
            .disabled(!updater.canCheck)
    }
}
