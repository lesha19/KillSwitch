import SwiftUI

/// The one window of the app (spec §3, ADR 0008): a sidebar of sections on the left, the section
/// on the right. «Начало работы», confirmations and the «Изменить… → Применить…» sheets are
/// sheets of this window; nothing opens a second one.
struct MainWindow: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Bindable private var router = Router.shared

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            SectionView(section: router.section)
                .navigationTitle(router.section.title)
        }
        .frame(minWidth: MainWindow.minSize.width, minHeight: MainWindow.minSize.height)
        .sheet(isPresented: $router.onboarding) { OnboardingView() }
        .modifier(WidgetRequestAlert())
        // the helper is asked often only while something shows its answers
        .onAppear { control.viewAppeared() }
        .onDisappear { control.viewDisappeared() }
    }

    static let id = "main"
    static let minSize = CGSize(width: 720, height: 540)
}

/// «Главная · Серверы · Проверка утечек · Журнал защиты», «Настройки» with its four panes, then
/// «О программе». ↑↓ move between sections; VoiceOver reads each row as a button with its title.
struct Sidebar: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Bindable private var router = Router.shared

    var body: some View {
        List(selection: Binding(get: { router.section }, set: { if let section = $0 { router.section = section } })) {
            Section {
                ForEach(AppSection.sidebar, id: \.self) { row($0) }
            }
            Section("Настройки") {
                ForEach(AppSection.settingsPanes, id: \.self) { row($0) }
            }
            Section {
                row(.about)
            }
        }
        .listStyle(.sidebar)
    }

    /// «Главная» carries the summary as a colour dot (and its title for VoiceOver), so the state
    /// shows from any section.
    private func row(_ section: AppSection) -> some View {
        HStack {
            Label(section.title, systemImage: section.symbol)
            if section == .home {
                Spacer()
                Circle().fill(control.status(client).tone.color).frame(width: 8, height: 8)
                    .help(control.status(client).title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(section == .home ? "\(section.title): \(control.status(client).title)" : section.title)
        .tag(section)
    }
}

/// The right side of the window: the chosen section, each at a readable width.
struct SectionView: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .home:
            ScrollView {
                HomeView(style: .window)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        case .servers:
            ServersScreen(back: nil)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 8)
        case .leakTest:
            LeakTestView()
        case .log:
            ProtectionLogView()
        case .about:
            AboutView()
        case .settings(let pane):
            SettingsPaneView(pane: pane)
        }
    }
}
