import SwiftUI
import AppKit
import TutunCore

/// «О программе»: версия, обновления приложения с GitHub, служба (состояние, установка, удаление), ссылки на проект.
struct AboutPane: View {
    @ObservedObject var up = Updater.shared
    @EnvironmentObject var m: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tutun").font(.title2.weight(.bold))
                        Text(tr("Версия \(Updater.currentVersion)")).foregroundStyle(.secondary)
                        Text(tr("VPN-клиент для Mac на xray и sing-box")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(tr("Обновления")) {
                status
                if let r = up.available {
                    if let notes = r.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("Что нового")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(notes).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    vpnStaysOn
                    Button { Task { await up.install() } } label: {
                        Label(tr("Установить и перезапустить"), systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(up.busy)
                }
                HStack {
                    Button(tr("Проверить обновления")) { Task { await up.check(userInitiated: true) } }
                        .disabled(up.busy)
                    Spacer()
                    if let l = up.lastCheck {
                        Text(l.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(tr("Проверять автоматически"), isOn: $up.autoCheck)
                if up.autoCheck {
                    ChoiceMenu(title: tr("Как часто"), selection: $up.intervalDays,
                               options: [(tr("Раз в день"), 1), (tr("Раз в неделю"), 7), (tr("Раз в 2 недели"), 14), (tr("Раз в месяц"), 30)])
                }
            }

            Section(tr("Служба")) {
                Button(tr("Сохранить диагностический отчёт…")) {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "Tutun-diagnostics.json"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    let fields = ["application": Updater.currentVersion,
                                  "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                                  "service": m.daemonReachable ? m.status.version : "unavailable",
                                  "state": m.daemonReachable ? m.status.state.rawValue : "unknown"]
                    do { try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
                    catch { NSAlert(error: error).runModal() }
                }

                LabeledContent(tr("Состояние"), value: m.daemonReachable ? tr("работает, версия \(m.status.version)") + (m.daemonOutdated ? tr(" — устарела") : "") :
                                (m.daemonInstalled ? tr("установлена, не отвечает") : tr("не установлена")))
                LabeledContent(tr("Перезапусков ядра"), value: "\(m.status.restarts)")
                if let stage = m.daemonInstallStage {
                    HStack(spacing: 8) {
                        if stage == .done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.on) } else { ProgressView().controlSize(.small) }
                        Text(stage.title)
                    }
                } else {
                    HStack {
                        Button(m.daemonInstalled ? tr("Переустановить службу") : tr("Установить службу")) { Task { await m.installDaemon() } }
                        if m.daemonInstalled { Button(tr("Удалить службу"), role: .destructive) { Task { await m.uninstallDaemon() } } }
                    }.disabled(m.busy)
                }
            }

            Section(tr("Проект")) {
                Button(tr("Страница на GitHub")) { NSWorkspace.shared.open(Updater.projectURL) }
                Button(tr("Все версии")) { NSWorkspace.shared.open(Updater.releasesURL) }
                Hint(tr("Обновления приходят из выпусков GitHub. Если вышла новая версия службы, приложение предложит её обновить."))
            }
        }
        .formStyle(.grouped)
        // Открыли раздел сразу после запуска, пока плановая проверка не прошла, — узнать состояние тихо, без уведомления.
        .task { if up.state == .idle { await up.check(userInitiated: false, notify: false) } }
    }

    /// Напоминание при каждом обновлении: VPN держит служба, он не прерывается.
    var vpnStaysOn: some View {
        Label(tr("VPN не отключится: подключение держит служба, пока обновляется приложение."), systemImage: "lock.shield.fill")
            .font(.callout).foregroundStyle(Palette.on)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder var status: some View {
        switch up.state {
        case .idle:
            Text(tr("Ещё не проверялось")).foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(tr("Проверяю…")) }
        case .upToDate:
            Label(tr("У вас последняя версия"), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.on)
        case .noReleases:
            Label(tr("У вас последняя версия"), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.on)
        case .available(let r):
            if up.revoked {
                Label(tr("Эта версия Tutun отозвана — установите обновление \(r.version)"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.busy)
            } else {
                Label(tr("Доступна версия \(r.version)"), systemImage: "arrow.down.circle.fill").foregroundStyle(Palette.on)
            }
        case .installing:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(tr("Загружаю и устанавливаю…")) }
            vpnStaysOn
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.busy)
        }
    }
}
