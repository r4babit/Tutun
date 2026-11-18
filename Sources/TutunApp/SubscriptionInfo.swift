import SwiftUI
import AppKit
import TutunCore

/// Информация о подписке — открывается кнопкой «i» у названия подписки на главной.
struct SubscriptionInfo: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    let subID: UUID
    @State private var qr: QRItem?
    @State private var confirmDelete = false
    @State private var name = ""
    @State private var interval = 12
    @State private var enabled = true
    @State private var notice: String?

    var index: Int? { m.subscriptions.firstIndex { $0.id == subID } }

    var body: some View {
        VStack(spacing: 0) {
            if let i = index {
                let sub = m.subscriptions[i]
                header(sub)
                Form {
                    Section {
                        LabeledContent(tr("Трафик"), value: formatBytes(sub.download + sub.upload) + (sub.total > 0 ? tr(" из \(formatBytes(sub.total))") : tr(", без лимита")))
                        if sub.total > 0 {
                            ProgressView(value: Double(min(sub.download + sub.upload, sub.total)), total: Double(sub.total)).tint(Palette.on)
                        }
                        if let e = sub.expire {
                            let days = Int(e.timeIntervalSinceNow / 86400)
                            LabeledContent(tr("Действует до")) {
                                Text(e.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: L10n.locale)) + (days >= 0 ? tr(" · ещё \(days) дн.") : tr(" · истекла")))
                                    .foregroundStyle(days <= m.settings.expiryWarnDays ? Palette.busy : .secondary)
                            }
                        }
                        LabeledContent(tr("Серверов"), value: "\(m.servers.filter { $0.subscriptionID == sub.id }.count)")
                        LabeledContent(tr("Обновлена"), value: sub.lastUpdate?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)) ?? tr("ещё нет"))
                        if let d = sub.details, !d.isEmpty { Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        if let a = sub.announce, !a.isEmpty {
                            LabeledContent(tr("Сообщение провайдера")) {
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(a).multilineTextAlignment(.trailing)
                                    if let s = sub.announceURL, let u = URL(string: s) { Button(tr("Подробнее")) { NSWorkspace.shared.open(u) } }
                                }
                            }
                        }
                        if let e = sub.lastError { Text(e).font(.callout).foregroundStyle(Palette.bad) }
                    }
                    if sub.autoroutingURL != nil || sub.serverResolve != nil || sub.providerFragment != nil || sub.providerNoises != nil {
                        Section {
                            if sub.autoroutingURL != nil { LabeledContent(tr("Маршруты"), value: tr("обновляются по ссылке провайдера")) }
                            if sub.serverResolve != nil { LabeledContent(tr("Адреса серверов"), value: tr("через DNS провайдера")) }
                            if sub.providerFragment != nil || sub.providerNoises != nil {
                                LabeledContent(tr("Обход блокировок"), value: tr("включается, если не включён у вас"))
                            }
                        } header: { Text(tr("Настройки провайдера")) }
                    }
                    Section {
                        LabeledContent(tr("Название")) {
                            TextField("", text: $name).multilineTextAlignment(.trailing)
                        }
                        LabeledContent(tr("Ссылка")) {
                            Text(sub.url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        NumberMenu(title: tr("Обновлять каждые"), value: $interval, options: [1, 3, 6, 12, 24, 48, 72, 168], range: 1...168, unit: tr("ч"))
                        Toggle(tr("Показывать серверы этой подписки"), isOn: $enabled)
                    }
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            Button(tr("Скопировать ссылку")) {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sub.url, forType: .string)
                                notice = tr("Ссылка скопирована")
                            }
                            Button(tr("QR-код")) { qr = QRItem(title: sub.name, text: sub.url) }
                            if let s = sub.supportURL, let u = URL(string: s) { Button(tr("Поддержка")) { NSWorkspace.shared.open(u) } }
                            if let s = sub.webPageURL, let u = URL(string: s) { Button(tr("Кабинет")) { NSWorkspace.shared.open(u) } }
                            if let e = sub.supportEmail, let u = URL(string: "mailto:" + e) { Button(tr("Написать в поддержку")) { NSWorkspace.shared.open(u) } }
                            Button(tr("Удалить подписку"), role: .destructive) { confirmDelete = true }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                HStack(spacing: 10) {
                    Spacer()
                    Button(tr("Отмена")) { dismiss() }
                    Button(tr("Сохранить")) {
                        guard let current = index else { return }
                        m.subscriptions[current].name = name
                        m.subscriptions[current].updateIntervalHours = interval
                        m.subscriptions[current].enabled = enabled
                        dismiss()
                    }.buttonStyle(TutunButtonStyle(primary: true))
                }.padding(.horizontal, 18).padding(.bottom, 18).padding(.top, 10)
            }
        }
        .frame(width: 560, height: 560)
        .background(Dark.bg)
        .modifier(ToastOverlay(message: $notice, bottom: 66))
        .preferredColorScheme(.dark)
        .buttonStyle(TutunButtonStyle())
        .onAppear {
            if let i = index {
                name = m.subscriptions[i].name
                interval = m.subscriptions[i].updateIntervalHours
                enabled = m.subscriptions[i].enabled
            }
        }
        .sheet(item: $qr) { q in QRSheet(title: q.title, text: q.text) }
        .confirmationDialog(tr("Удалить подписку и все её серверы?"), isPresented: $confirmDelete) {
            Button(tr("Удалить"), role: .destructive) { m.removeSubscription(subID); dismiss() }
        } message: { Text(tr("Вернуть можно, снова добавив ссылку на подписку.")) }
    }

    func header(_ sub: Subscription) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.brand.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.name).font(.title3.weight(.bold))
                Text(sub.lastError == nil ? tr("Подписка работает") : tr("Не удалось обновить")).font(.caption)
                    .foregroundStyle(sub.lastError == nil ? Palette.on : Palette.bad)
            }
            Spacer()
        }
        .padding(18)
    }
}
