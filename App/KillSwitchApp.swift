import SwiftUI

@main
struct KillSwitchApp: App {
    @State private var control = KillSwitchControl()

    var body: some Scene {
        Window("KillSwitch", id: "main") {
            ContentView()
                .environment(control)
        }
        .windowResizability(.contentSize)
    }
}
