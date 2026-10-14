import SwiftUI
import UniformTypeIdentifiers

/// Settings › Дополнительно › «Перенос настроек» (#15, ADR 0024): save the settings to a JSON
/// file without the subscription and keys, load them back, or reset them. Loading and resetting
/// show what changes first; the root settings then go through the same commands and password as
/// their own screens (KillSwitchControl.applySettings), the way of connecting through switchCore.
struct SettingsTransferSection: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Environment(AutoConnector.self) private var auto
    @Environment(Updater.self) private var updater
    @State private var file: SettingsFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var review: Review?
    @State private var note: String?

    struct Review: Identifiable {
        let id = UUID()
        let title: String
        let settings: SettingsBackup.Settings
        let changes: [SettingsBackup.Change]
        /// «Сбросить»: every subscription's favourites and recents go, not only those the file names.
        var resetting = false
        /// The file has root settings, but the service is not installed.
        let rootSkipped: Bool
    }

    private var installed: Bool { control.state != .notInstalled }

    private var current: SettingsBackup.Settings {
        .init(app: SettingsBackup.snapshot(.standard, serverKeys: client.serverKeys, subscription: client.activeID,
                                         ownKeys: client.blocks.first { $0.id == ServerID.own }?.keys ?? [:]), root: installed ? control.rootSettings : nil)
    }

    var body: some View {
        Section("Перенос настроек") {
            HStack {
                Button("Сохранить в файл…") {
                    file = SettingsFile(data: SettingsBackup.export(current, appVersion: DeviceInfo.appVersion, date: Date()))
                    exporting = true
                }
                Button("Загрузить из файла…") { importing = true }
                Spacer()
                Button("Сбросить…") { show(SettingsBackup.reset, title: String(localized: "Сбросить настройки?"), resetting: true) }
            }
            .disabled(control.busy)
            Text("Ссылка подписки, свои серверы и ключи в файл не попадают: на новом Mac их добавляют заново. Названия сетей Wi‑Fi в файле есть.")
                .foregroundStyle(.secondary)
            if let note {
                Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
            }
        }
        .fileExporter(isPresented: $exporting, document: file, contentType: .json, defaultFilename: "KillSwitch-settings") { result in
            if case .failure(let error) = result { note = error.localizedDescription }
            file = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            load(url)
        }
        .sheet(item: $review) { review in
            ReviewSheet(review: review) { apply(review.settings, resetting: review.resetting) }
        }
    }

    private func load(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= SettingsBackup.maxBytes else { throw SettingsBackup.Problem.notSettings }
            show(try SettingsBackup.read(Data(contentsOf: url)), title: String(localized: "Загрузить настройки?"))
        } catch let problem as SettingsBackup.Problem {
            note = problem.message
        } catch {
            note = String(localized: "Не получилось прочитать файл.")
        }
    }

    private func show(_ settings: SettingsBackup.Settings, title: String, resetting: Bool = false) {
        let changes = SettingsBackup.changes(from: current, to: settings)
        let rootSkipped = !installed && settings.root != nil
        guard !changes.isEmpty else {
            note = String(localized: "Менять нечего: настройки уже такие.")
            return
        }
        note = nil
        review = Review(title: title, settings: settings, changes: changes, resetting: resetting, rootSkipped: rootSkipped)
    }

    /// The root settings behind the password first, and the app's only once they are in: a
    /// cancelled or failed password leaves nothing half applied. Then the way of connecting.
    /// Without root settings to change (or without the service) the app's apply at once.
    private func apply(_ settings: SettingsBackup.Settings, resetting: Bool) {
        guard installed, let root = settings.root else { return applyApp(settings.app, resetting: resetting) }
        control.applySettings(root) { [client] in
            applyApp(settings.app, resetting: resetting)
            if let core = root.core { client.switchCore(to: core) }
        }
    }

    private func applyApp(_ app: [String: SettingsBackup.Value], resetting: Bool) {
        SettingsBackup.apply(app, to: .standard, subscription: client.activeID, own: Set(client.manual.map(\.name)),
                             names: Set(client.profileProxies?.servers ?? []), resetting: resetting)
        auto.reloadSettings()
        let interval = UserDefaults.standard.integer(forKey: "subscriptionIntervalHours")
        if client.intervalHours != interval { client.intervalHours = interval }
        if updater.betaUpdates != UpdateChannel.isBeta() { updater.betaUpdates = UpdateChannel.isBeta() }
        control.syncSpeed()
    }
}

private struct ReviewSheet: View {
    let review: SettingsTransferSection.Review
    let apply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.title).font(.headline)
            List {
                rows(review.changes.filter { !$0.root })
                let root = review.changes.filter(\.root)
                if !root.isEmpty {
                    Section("Защита и служба — спросит пароль") { rows(root) }
                }
            }
            .frame(minHeight: 220)
            // outside the list, so scrolling never hides them; at most three, so they never push the
            // buttons off the sheet (every entry is listed above)
            let warnings = review.changes.flatMap(\.warnings).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            ForEach(warnings.prefix(3), id: \.self) { warning in
                Label {
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            if warnings.count > 3 {
                Text("и ещё \(warnings.count - 3)").foregroundStyle(.secondary)
            }
            if review.rootSkipped {
                Text("Настройки защиты не применятся: служба KillSwitch не установлена.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Применить") {
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func rows(_ changes: [SettingsBackup.Change]) -> some View {
        ForEach(changes) { change in
            if change.added.isEmpty && change.removed.isEmpty {
                LabeledContent(change.title) {
                    Text("\(change.old) → \(change.new)").foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                }
            } else {
                // a root list: every entry it gains or loses, never a shortened summary
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.title)
                    if !change.added.isEmpty {
                        Text("Добавится: \(change.added.joined(separator: ", "))").foregroundStyle(.secondary)
                    }
                    if !change.removed.isEmpty {
                        Text("Уберётся: \(change.removed.joined(separator: ", "))").foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
        }
    }
}

/// The exported JSON for `fileExporter`.
struct SettingsFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
