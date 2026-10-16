import Foundation

// KillSwitchHelper: the root daemon of ADR 0010, started by launchd on demand for its Mach service
// (Contents/Library/LaunchDaemons/com.lesha19.KillSwitch.helper.plist, SMAppService). It runs the
// typed commands of HelperCommand for our signed app and nothing else, and exits when idle.

Authorizer.ensureRight()
DaemonExecutable.recordApp()   // for the watchdog: an app in the Trash leaves no block (#84)
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.machService)
listener.delegate = delegate
listener.resume()
Activity.shared.exitWhenIdle()
dispatchMain()
