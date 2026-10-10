import SwiftUI

/// Shown while the privileged daemon (ADR 0010) waits for its switch in System Settings › Login
/// Items: until then every change asks for the password, as before.
struct HelperApprovalNote: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        if control.helperAvailability == .needsApproval {
            VStack(alignment: .leading, spacing: 6) {
                Label("Разреши службу KillSwitch", systemImage: "lock.shield")
                    .font(.headline)
                Text("Системные настройки › Основные › Объекты входа и расширения: включи KillSwitch в разделе «Разрешить в фоне». Тогда изменения защиты будут спрашивать пароль или Touch ID не чаще раза в 5 минут. Пока служба не разрешена, пароль нужен при каждом изменении.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Открыть Объекты входа…") { HelperClient.openLoginItems() }
            }
        }
    }
}
