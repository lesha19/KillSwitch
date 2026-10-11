import SwiftUI

/// «О программе → Лицензии»: a button opening a sheet (the app keeps one window, ADR 0008).
struct LicensesButton: View {
    @State private var shown = false

    var body: some View {
        Button("Лицензии") { shown = true }
            .sheet(isPresented: $shown) { LicensesView() }
    }
}

/// KillSwitch's copyright and the third-party notices bundled as ThirdPartyNotices.txt
/// (Helper/tests/notices.sh keeps it in step with the pinned versions).
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    /// The file's sections, split at its lines of 72 «=»: one Text each, so a long licence text
    /// is laid out lazily instead of as one huge block.
    private static let sections: [String] = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [String(localized: "Файл с лицензиями не найден в программе.")] }
        let separator = String(repeating: "=", count: 72)
        return text.components(separatedBy: "\n" + separator + "\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Лицензии").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(Self.sections.enumerated()), id: \.offset) { _, section in
                        Text(section)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
                .padding(.trailing, 8)
            }
            HStack {
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}
