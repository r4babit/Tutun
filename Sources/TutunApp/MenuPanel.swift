import SwiftUI
import TutunCore

/// Панель по клику на значок в строке меню — то же, что левая колонка окна, плюс быстрые страны.
struct MenuPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusColumn(compact: true)
            Rectangle().fill(Dark.line).frame(height: 1)
            Text(tr("Серверы")).font(.caption.weight(.semibold)).foregroundStyle(Dark.text3)
            CountryList(compact: true).frame(height: 250)
            Rectangle().fill(Dark.line).frame(height: 1)
            HStack {
                Button { openMainWindow(openWindow) } label: { Label(tr("Открыть окно"), systemImage: "macwindow") }
                Spacer()
                Button { WindowOpener.openSettings() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(tr("Настройки"))
                    .help(tr("Настройки"))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "xmark.circle") }
                    .accessibilityLabel(tr("Закрыть Tutun. VPN продолжит работать через службу"))
                    .help(tr("Закрыть Tutun. VPN продолжит работать через службу"))
            }
            .buttonStyle(TutunButtonStyle()).foregroundStyle(Dark.text2)
        }
        .padding(16)
        .frame(width: 340)
        .background(Dark.bg)
        .modifier(ToastOverlay(message: $m.message))
        .preferredColorScheme(.dark)
    }
}
