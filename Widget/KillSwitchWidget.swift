import AppIntents
import SwiftUI
import WidgetKit

/// The widget runs sandboxed and cannot touch pf; it asks the running app via a Darwin notification.
struct KillSwitchCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Управлять защитой"

    @Parameter(title: "Команда") var command: String

    init() {}
    init(_ command: Shared.Command) { self.command = command.rawValue }

    func perform() async throws -> some IntentResult {
        if let command = Shared.Command(rawValue: command) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFNotificationName(command.notificationName as CFString),
                                                 nil, nil, true)
        }
        try? await Task.sleep(for: .seconds(2))   // let the app switch and publish the new state
        return .result()
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let state: String
    let vpnUp: Bool
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, state: "on", vpnUp: true) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(current()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .after(.now.addingTimeInterval(300))))
    }

    private func current() -> Entry {
        let defaults = Shared.defaults
        return Entry(date: .now,
                     state: defaults?.string(forKey: Shared.stateKey) ?? "notInstalled",
                     vpnUp: defaults?.bool(forKey: Shared.vpnKey) ?? false)
    }
}

struct WidgetView: View {
    let entry: Entry

    private var isOn: Bool { entry.state == "on" }
    private var isPaused: Bool { entry.state.hasPrefix("paused:") }
    private var color: Color { isOn ? .green : isPaused ? .orange : entry.state == "off" ? .red : .gray }
    private var title: String {
        switch true {
        case isOn: "Включена"
        case isPaused: "Пауза"
        case entry.state == "off": "Выключена"
        default: "Не установлена"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isOn ? "lock.shield.fill" : "shield.slash")
                    .font(.title).foregroundStyle(color)
                Spacer()
                Image(systemName: entry.vpnUp ? "network" : "network.slash")
                    .foregroundStyle(entry.vpnUp ? .green : .orange)
            }
            Spacer(minLength: 0)
            Text("Защита").font(.caption).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if entry.state != "notInstalled" {
                Button(intent: KillSwitchCommandIntent(isOn ? .off : .on)) {
                    Text(isOn ? "Выключить" : "Включить").frame(maxWidth: .infinity)
                }
                .tint(isOn ? .red : .green)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct KillSwitchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KillSwitch", provider: Provider()) { entry in
            WidgetView(entry: entry)
        }
        .configurationDisplayName("KillSwitch")
        .description("Интернет только через VPN: состояние и переключатель.")
        .supportedFamilies([.systemSmall])
    }
}
