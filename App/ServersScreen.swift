import SwiftUI

/// «Сервер»: the server choice inside the popover or the window, with «‹ Назад».
struct ServersScreen: View {
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("Назад", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Сервер").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Color.clear.frame(width: 60, height: 1)
            }
            .padding(12)
            ScrollView {
                ServerList().padding(.horizontal, 16).padding(.bottom, 16)
            }
            .frame(minHeight: 300, maxHeight: 460)
        }
    }
}
