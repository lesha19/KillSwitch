import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// «Сканировать QR…» (#24): a subscription or servers from a QR code in a picture — the clipboard
/// (⌃⇧⌘4 puts a screen region there), a file, or one dropped on the sheet. KillSwitch never reads
/// the screen itself, so it asks for no screen recording permission (ADR 0021).
struct QRScanButton: View {
    @State private var scanning = false

    var body: some View {
        Button("Сканировать QR…") { scanning = true }
            .help("Добавить подписку или сервер по QR-коду с картинки")
            .sheet(isPresented: $scanning) { QRScanSheet() }
    }
}

private struct QRScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VPNClient.self) private var client
    @State private var found: QRPayload?
    @State private var problem: String?
    @State private var opening = false
    @State private var dropTargeted = false
    @State private var adding = false
    /// The client's error is shown only for an «Добавить» from this sheet, not an older one.
    @State private var tried = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Сканировать QR-код").font(.headline)
            Text("Нажми ⌃⇧⌘4 и выдели QR-код на экране: снимок попадёт в буфер обмена. Или открой картинку с кодом, или перетащи её сюда.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            dropArea
            HStack {
                Button("Из буфера обмена") { scanClipboard() }
                Button("Открыть картинку…") { opening = true }
            }

            if let found, found != .unrecognized {
                foundRow(found)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if tried, let error = client.lastError { InlineError(error: error) }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(addTitle, action: add).keyboardShortcut(.defaultAction)
                    .disabled(found == nil || found == .unrecognized || adding)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $opening, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            scanFile(url)
        }
    }

    private var dropArea: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            .frame(height: 70)
            .overlay { Text("Перетащи картинку сюда").foregroundStyle(.secondary) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Место для картинки с QR-кодом")
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: \.isFileURL) else {
                    problem = String(localized: "Перетащи файл картинки.")
                    found = nil
                    return false
                }
                scanFile(url)
                return true
            } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder private func foundRow(_ payload: QRPayload) -> some View {
        if case .subscription = payload {
            LabeledContent("Подписка") { Text(payload.summary).monospaced().lineLimit(1) }
            if client.hasURL {
                Text("Она заменит текущую подписку.").font(.callout).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Свои серверы") { Text(payload.summary) }
        }
    }

    private var addTitle: String {
        if case .subscription = found, client.hasURL { return String(localized: "Заменить подписку") }
        return String(localized: "Добавить")
    }

    private func scanClipboard() {
        guard let image = NSImage(pasteboard: .general) else {
            show(nil, problem: String(localized: "В буфере обмена нет картинки. Нажми ⌃⇧⌘4 и выдели QR-код."))
            return
        }
        scan(image)
    }

    private func scanFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 50 * 1024 * 1024,
              let image = NSImage(contentsOf: url) else {
            show(nil, problem: String(localized: "Не получилось открыть картинку."))
            return
        }
        scan(image)
    }

    private func scan(_ image: NSImage) {
        guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            show(nil, problem: String(localized: "Не получилось открыть картинку."))
            return
        }
        let payloads = QRCode.payloads(in: picture)
        let payload = QRPayload.first(of: payloads)
        show(payload, problem: payloads.isEmpty
             ? String(localized: "На картинке не нашлось QR-кода. Выдели его крупнее, целиком.")
             : String(localized: "В этом QR-коде нет ссылки на подписку или сервер."))
    }

    private func show(_ payload: QRPayload?, problem: String) {
        found = payload
        tried = false
        self.problem = payload == nil || payload == .unrecognized ? problem : nil
    }

    /// Through the same checks as a link typed in Settings: nothing is added on the scan alone.
    private func add() {
        guard let found else { return }
        adding = true
        tried = true
        Task {
            switch found {
            case .subscription(let url): await client.setURL(url)
            case .servers(let text): await client.addLink(text)
            case .unrecognized: break
            }
            adding = false
            if client.lastError == nil { dismiss() }
        }
    }
}

/// «QR-код…» of the subscription (#24), to add it on a phone. The link is a secret: shown only
/// after a warning, drawn in memory, gone when the sheet closes; not offered when the provider
/// sends `hide-url`.
struct SubscriptionQRButton: View {
    @Environment(VPNClient.self) private var client
    @State private var warning = false
    @State private var code: CGImage?

    private var hidden: Bool { client.status.hidesURL == true }

    var body: some View {
        Button("QR-код…") { warning = true }
            .disabled(hidden)
            .help(hidden ? String(localized: "Сервис подписки просит не показывать ссылку")
                         : String(localized: "Показать ссылку QR-кодом, чтобы добавить подписку на телефоне"))
            .confirmationDialog("Показать QR-код подписки?", isPresented: $warning) {
                Button("Показать") { code = client.revealURL().flatMap { QRCode.image(for: $0) } }
            } message: {
                Text("Ссылка на подписку — это ключ: кто сфотографирует код, тот подключится за твой счёт. Показывай его только своему телефону и не делай снимков экрана.")
            }
            .sheet(isPresented: Binding(get: { code != nil }, set: { if !$0 { code = nil } })) {
                if let code { SubscriptionQRSheet(code: code) }
            }
    }
}

private struct SubscriptionQRSheet: View {
    @Environment(\.dismiss) private var dismiss
    let code: CGImage

    var body: some View {
        VStack(spacing: 12) {
            Text("QR-код подписки").font(.headline)
            Image(code, scale: 1, label: Text("QR-код ссылки на подписку"))
                .interpolation(.none).resizable().scaledToFit()
                .frame(width: 260, height: 260)
                .padding(24).background(.white, in: RoundedRectangle(cornerRadius: 8))
            Text("Открой камеру телефона или приложение VPN и отсканируй код. Закрой окно, когда подписка добавится.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 340)
    }
}
