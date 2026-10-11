import SwiftUI

/// «Бета-версии» in «О программе» (#16): Sparkle also takes the "beta" channel of the appcast.
struct BetaUpdatesToggle: View {
    let updater: Updater

    var body: some View {
        Toggle(isOn: Binding(get: { updater.betaUpdates }, set: { updater.betaUpdates = $0 })) {
            Text("Бета-версии")
            Text("Новые версии раньше остальных. В них могут быть ошибки; VPN и защита работают как обычно.")
        }
    }
}
