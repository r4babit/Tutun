import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers
import TutunCore

// MARK: - Окно настроек: разделы слева, как в системных «Настройках»

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "Основные", routing = "Маршруты", network = "Сеть и туннель",
         connections = "Соединения", stats = "Статистика", log = "Журнал", advanced = "Дополнительно",
         about = "О программе"
    var id: String { rawValue }
    /// Название раздела на языке интерфейса (rawValue — служебный идентификатор, не переводится).
    var title: String {
        switch self {
        case .general: return tr("Основные")
        case .routing: return tr("Маршруты")
        case .network: return tr("Сеть и туннель")
        case .connections: return tr("Соединения")
        case .stats: return tr("Статистика")
        case .log: return tr("Журнал")
        case .advanced: return tr("Дополнительно")
        case .about: return tr("О программе")
        }
    }
    /// Разделы в панели настроек; соединения, статистика и журнал открываются отдельными окнами из «Ещё».
    static let panel: [SettingsPane] = [.general, .routing, .network, .advanced, .about]
    var inPanel: Bool { Self.panel.contains(self) }
    /// Короткая подпись под квадратиком.
    var short: String {
        switch self {
        case .network: return tr("Сеть")
        case .advanced: return tr("Ещё")
        case .about: return tr("О Tutun")
        default: return title
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .routing: return "arrow.triangle.branch"
        case .network: return "network"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .stats: return "chart.bar.fill"
        case .log: return "doc.text.fill"
        case .advanced: return "wrench.and.screwdriver.fill"
        case .about: return "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: return .gray
        case .routing: return Palette.brandDeep
        case .network: return .teal
        case .connections: return Palette.on
        case .stats: return .orange
        case .log: return .indigo
        case .advanced: return .pink
        case .about: return .blue
        }
    }
}

/// Настройки в правой панели главного окна: сверху открытый раздел, снизу — квадратики разделов
/// (как «Добавить / Настройки / Серверы» слева).
struct SettingsPanel: View {
    @EnvironmentObject var m: AppModel
    var pane: SettingsPane { m.settingsPane.flatMap { $0.inPanel ? $0 : nil } ?? .general }

    var body: some View {
        VStack(spacing: 0) {
            Text(pane.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 36)
            Rectangle().fill(Dark.line).frame(height: 1)
            paneView(pane)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 30) }
                .overlay(alignment: .bottom) {
                    if m.needsReconnect {
                        Button { Task { await m.reconnect() } } label: {
                            Label(tr("Принять изменения"), systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Dark.bg)
                                .padding(.horizontal, 16)
                                .frame(height: 34)
                                .background(Capsule().fill(Palette.on))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                        .help(tr("Переподключить VPN с новыми настройками"))
                    }
                }
            // Низ квадратиков — вровень с низом кнопки «Отключить» слева.
            tiles.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 28)
        }
        .background(Dark.bg)
        .onReceive(NotificationCenter.default.publisher(for: .tutunShowSettingsPane)) { n in
            if let p = (n.object as? String).flatMap(SettingsPane.init(rawValue:)) { m.settingsPane = p }
        }
    }

    var tiles: some View {
        HStack(spacing: 4) {
            ForEach(SettingsPane.panel) { p in
                let sel = p == pane
                Button { m.settingsPane = p } label: {
                    VStack(spacing: 4) {
                        Image(systemName: p.icon).font(.system(size: 12.5, weight: .semibold)).frame(height: 16)
                        Text(p.short).font(.system(size: 9.5, weight: sel ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(sel ? Color.white : Dark.text2)
                    .frame(maxWidth: .infinity).padding(.vertical, 8).padding(.horizontal, 1)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(sel ? Dark.selected : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(sel ? Palette.on.opacity(0.45) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HoverHighlight())
                .help(p.title)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Dark.card))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Dark.line))
    }

    @ViewBuilder func paneView(_ p: SettingsPane) -> some View {
        switch p {
        case .general: GeneralPane()
        case .routing: RoutingPane()
        case .network: NetworkPane()
        case .connections: ConnectionsPane()
        case .stats: StatsPane()
        case .log: LogPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}

/// Подпись под настройкой — короткое пояснение.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

/// Список строк (домены, IP, приложения) — каждая строка отдельно.
struct ListEditor: View {
    let title: String
    @Binding var items: [String]
    var height: CGFloat = 80
    var prompt: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { Text(title) }
            TextEditor(text: Binding(get: { items.joined(separator: "\n") }, set: { items = $0.components(separatedBy: .newlines) }))
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                .overlay(alignment: .topLeading) {
                    if items.joined().isEmpty && !prompt.isEmpty {
                        Text(prompt).font(.callout).foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                    }
                }
        }
    }
}

// MARK: - Основные

struct DropdownRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }
    private struct HoverRow: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(configuration.isPressed ? 0.12 : (hovered ? 0.07 : 0))))
                .onHover { hovered = $0 }
        }
    }
}

struct ChoiceMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        LabeledContent(title) {
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    Text(options.first(where: { $0.1 == selection })?.0 ?? tr("Выбрать"))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hovering || open ? Palette.on : Dark.text2)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(minHeight: 29)
                .background(RoundedRectangle(cornerRadius: 8).fill(Dark.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovering || open ? Palette.on.opacity(0.5) : Dark.line))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(options.indices, id: \.self) { i in
                            Button { selection = options[i].1; open = false } label: {
                                HStack {
                                    Text(options[i].0).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: "checkmark").foregroundStyle(Palette.on)
                                        .frame(width: 12).opacity(selection == options[i].1 ? 1 : 0)
                                }
                                .font(.system(size: 11.5, weight: selection == options[i].1 ? .semibold : .regular))
                                .foregroundStyle(selection == options[i].1 ? Color.white : Dark.text2)
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 6).fill(selection == options[i].1 ? Palette.on.opacity(0.15) : .clear))
                            }.buttonStyle(DropdownRowStyle())
                        }
                    }.padding(7)
                }
                .frame(width: 220, height: min(CGFloat(options.count * 36 + 14), 280))
                .background(Dark.bg)
                .preferredColorScheme(.dark)
            }
        }
    }
}

struct NumberMenu: View {
    let title: String
    @Binding var value: Int
    let options: [Int]
    let range: ClosedRange<Int>
    let unit: String
    @State private var showCustom = false
    @State private var showOptions = false
    @State private var customText = ""
    @State private var hovering = false

    private var valueLabel: String {
        unit.isEmpty ? "\(value)" : "\(value) \(unit)"
    }

    var body: some View {
        LabeledContent(title) {
            Button { showCustom = false; showOptions.toggle() } label: {
                HStack(spacing: 7) {
                    Text(valueLabel).monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hovering || showOptions ? Palette.on : Dark.text2)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 10)
                .frame(minWidth: 86, minHeight: 29, alignment: .trailing)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Dark.card))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hovering || showOptions ? Palette.on.opacity(0.5) : Dark.line, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                VStack(spacing: 3) {
                    ForEach(Array(Set(options + [value])).sorted(), id: \.self) { option in
                        Button {
                            value = option
                            showOptions = false
                        } label: {
                            HStack(spacing: 9) {
                                Text(unit.isEmpty ? "\(option)" : "\(option) \(unit)")
                                    .monospacedDigit()
                                Spacer(minLength: 8)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Palette.on)
                                    .frame(width: 12).opacity(option == value ? 1 : 0)
                            }
                            .font(.system(size: 11.5, weight: option == value ? .semibold : .regular))
                            .foregroundStyle(option == value ? Color.white : Dark.text2)
                            .padding(.horizontal, 9)
                            .frame(height: 27)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(option == value ? Palette.on.opacity(0.15) : .clear))
                        }
                        .buttonStyle(DropdownRowStyle())
                    }
                    Rectangle().fill(Dark.line).frame(height: 1).padding(.vertical, 3)
                    Button {
                        customText = String(value)
                        showCustom.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Text(tr("Другое значение…"))
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 9)
                        .frame(height: 29)
                    }
                    .buttonStyle(DropdownRowStyle())
                    if showCustom {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(tr("От \(range.lowerBound) до \(range.upperBound)"))
                                .font(.system(size: 10)).foregroundStyle(Dark.text2)
                            HStack(spacing: 6) {
                                TextField(tr("Число"), text: $customText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { acceptCustom() }
                                Button { acceptCustom() } label: {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.on)
                                }
                                .buttonStyle(.plain)
                                .disabled(Int(customText).map { !range.contains($0) } ?? true)
                            }
                        }.padding(.horizontal, 9).padding(.vertical, 6)
                    }
                }
                .padding(7)
                .frame(width: 158)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dark.bg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Dark.line))
                .preferredColorScheme(.dark)
            }
            .fixedSize()
        }
    }

    private func acceptCustom() {
        guard let number = Int(customText), range.contains(number) else { return }
        value = number
        showOptions = false
    }
}

struct GeneralPane: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section {
                ChoiceMenu(title: tr("Язык интерфейса"), selection: $m.language, options: AppLanguage.allCases.map { ($0.nativeName, $0) })
            }
            Section(tr("Подключение")) {
                ChoiceMenu(title: tr("Режим"), selection: Binding(get: { m.settings.mode }, set: { v in Task { await m.setMode(v) } }), options: [(tr("Весь трафик мака"), .tun), (tr("Системный прокси"), .proxy)])
                Toggle(isOn: $m.settings.killSwitch) {
                    Text(tr("Аварийная блокировка при потере туннеля"))
                    Hint(tr("В режиме всего трафика служба блокирует интернет, обнаружив падение туннеля, до его восстановления. Короткий промежуток до обнаружения аварии не защищён."))
                }
                Toggle(isOn: $m.settings.failover) {
                    Text(tr("Запасной сервер"))
                    Hint(tr("Если выбранный сервер перестал отвечать, Tutun переключится на самый быстрый из отвечающих."))
                }
            }
            Section {
                NumberMenu(title: tr("Проверять связь каждые"), value: $m.settings.probeIntervalSec, options: [10, 20, 30, 60, 120, 300], range: 10...300, unit: tr("с"))
                NumberMenu(title: tr("Сервер не отвечает после"), value: $m.settings.healthFailLimit, options: [1, 2, 3, 4, 5, 10], range: 1...10, unit: tr("проверок"))
            } header: { Text(tr("Автопереключение")) } footer: {
                Hint(tr("Пока сервер отвечает, Tutun остаётся на нём, даже если другой быстрее. Перестал отвечать — переходит на самый быстрый из рабочих в том же списке (самый быстрый, страна или запасной)."))
            }
            Section {
                ChoiceMenu(title: tr("К какому серверу подключаться"), selection: $m.settings.countryPick, options: [(tr("Самый быстрый из списка"), .fastest), (tr("Последний выбранный в стране"), .lastUsed), (tr("Первый в списке"), .first), (tr("Случайный"), .random)])
                Toggle(tr("Сначала избранные серверы страны"), isOn: $m.settings.countryPreferFavorites)
            } header: { Text(tr("Клик по стране")) } footer: {
                Hint(countryHint)
            }
            Section(tr("Запуск")) {
                Toggle(tr("Открывать Tutun при входе в систему"), isOn: Binding(get: { m.settings.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
                Toggle(tr("Подключаться при запуске Tutun"), isOn: $m.settings.connectOnLaunch)
                Toggle(tr("Значок в Dock, пока открыто окно"), isOn: $m.settings.showInDock)
                Hint(tr("После перезагрузки мака VPN включается сам, даже без окна: подключение держит служба."))
            }
            Section(tr("Уведомления")) {
                Toggle(isOn: $m.settings.notifications) {
                    Text(tr("Показывать уведомления"))
                    Hint(tr("Подключение, обрыв, смена сервера, конец подписки."))
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension GeneralPane {
    var countryHint: String {
        let base: String
        switch m.settings.countryPick {
        case .fastest: base = tr("Tutun берёт самый быстрый сервер страны и при обрыве сам переключается на другой сервер этой страны.")
        case .lastUsed: base = tr("Tutun подключается к серверу, который вы последним выбрали в этой стране вручную. Если такого нет — к самому быстрому.")
        case .first: base = tr("Tutun подключается к первому серверу страны по алфавиту.")
        case .random: base = tr("Tutun подключается к случайному рабочему серверу страны.")
        }
        return base + (m.settings.countryPreferFavorites ? tr(" Если в стране есть серверы со звёздочкой, выбор идёт только среди них.") : "")
    }
}

// MARK: - Маршруты

struct GeoProgressRow: View {
    let progress: GeoUpdateProgress

    private var fraction: Double? {
        guard progress.stage == .downloading, let total = progress.total, total > 0 else { return nil }
        return min(1, max(0, Double(progress.bytes) / Double(total)))
    }

    private var title: String {
        switch progress.stage {
        case .downloading: return tr("Загрузка")
        case .checking: return tr("Проверяю…")
        case .installing: return tr("Устанавливаю базы…")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let fraction {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.25), lineWidth: 3)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 16, height: 16).accessibilityHidden(true)
            } else { ProgressView().controlSize(.small).accessibilityHidden(true) }
            Text([title, progress.file].compactMap { $0 }.joined(separator: " "))
            Spacer()
            if progress.stage == .downloading {
                Text(ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file))
                if let fraction {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                }
            }
        }
        .font(.callout).monospacedDigit().accessibilityElement(children: .combine)
    }
}

struct RoutingPane: View {
    @EnvironmentObject var m: AppModel
    @State private var profileLink = ""

    var body: some View {
        Form {
            Section {
                ChoiceMenu(title: tr("Что пускать через VPN"), selection: Binding(get: { m.settings.routingMode }, set: { v in Task { await m.setRoutingMode(v) } }), options: [(tr("По правилам"), .rule), (tr("Всё"), .global), (tr("Ничего (напрямую)"), .direct)])
                VStack(alignment: .leading, spacing: 4) {
                    ChoiceMenu(title: tr("Сайты страны — напрямую"), selection: Binding(
                        get: { m.settings.russiaDirect ? m.settings.directCountry : "" },
                        set: { v in
                            if v.isEmpty { m.settings.russiaDirect = false }
                            else { m.settings.russiaDirect = true; m.settings.directCountry = v }
                        }),
                        options: [(tr("Нет — всё по остальным правилам"), ""), (tr("Россия"), "ru"), (tr("Китай"), "cn"),
                                  (tr("Иран"), "ir"), (tr("Мьянма"), "mm"), (tr("Турция"), "tr"), (tr("ОАЭ"), "ae")])
                    Hint(tr("Банки, госуслуги и местные сервисы выбранной страны идут без VPN. Россия, Китай, Иран — готовые списки сайтов и IP-адреса страны; Мьянма — банки и доменная зона; Турция, ОАЭ — только доменная зона (.tr, .ae)."))
                }
                Toggle(tr("Блокировать рекламу и трекеры"), isOn: $m.settings.blockAds)
            }
            Section {
                Toggle(tr("Обновлять раз в неделю"), isOn: $m.settings.geoAutoUpdate)
                TextField("geoip.dat", text: $m.settings.geoipURL)
                TextField("geosite.dat", text: $m.settings.geositeURL)
                LabeledContent(tr("Обновлены")) {
                    HStack {
                        Text(m.settings.geoLastUpdate?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)) ?? tr("ещё нет"))
                        Button(tr("Обновить сейчас")) { Task { await m.updateGeo() } }
                            .disabled(!m.daemonReachable || m.daemonOutdated || m.geoUpdateRequested || m.status.geoProgress != nil)
                    }
                }
                if let progress = m.status.geoProgress {
                    GeoProgressRow(progress: progress)
                } else if m.geoUpdateRequested {
                    GeoProgressRow(progress: GeoUpdateProgress(stage: .checking))
                } else if m.daemonOutdated {
                    Text(tr("Служба устарела — нажмите «Обновить службу» в настройках")).foregroundStyle(.secondary)
                } else if let error = m.geoUpdateError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            } header: { Text(tr("Гео-базы")) } footer: { Hint(tr("Списки стран и сайтов для правил. По умолчанию — runetfreedom для России.")) }
            Section(tr("Профиль маршрутов")) {
                ChoiceMenu(title: tr("Профиль"), selection: Binding(get: { m.settings.activeProfileID }, set: { id in Task { await m.activate(m.profiles.first { $0.id == id }) } }), options: [(tr("Нет"), UUID?.none)] + m.profiles.map { ($0.name, Optional($0.id)) })
                if let p = m.activeProfile {
                    Hint(tr("Напрямую: \(p.directSites.count + p.directIPs.count) · через VPN: \(p.proxySites.count + p.proxyIPs.count) · блок: \(p.blockSites.count + p.blockIPs.count)"))
                }
                HStack {
                    TextField(tr("happ://routing/add/… или JSON профиля"), text: $profileLink).textFieldStyle(.roundedBorder)
                    Button(tr("Добавить")) {
                        let t = profileLink.trimmingCharacters(in: .whitespacesAndNewlines); profileLink = ""
                        if let p = RoutingProfiles.parseLink(t) ?? RoutingProfiles.parseJSON(Data(t.utf8)) {
                            m.addProfile(p); Task { await m.activate(m.profiles.first { $0.name == p.name }) }
                        } else { m.message = tr("Профиль не распознан") }
                    }.disabled(profileLink.isEmpty)
                }
            }
            Section {
                ListEditor(title: tr("Всегда через VPN"), items: $m.settings.proxyDomains, prompt: "youtube.com")
                ListEditor(title: tr("Всегда напрямую"), items: $m.settings.directDomains, prompt: "sberbank.ru")
                ListEditor(title: tr("Блокировать"), items: $m.settings.blockDomains, prompt: "ads.example.com")
            } header: { Text(tr("Сайты")) } footer: {
                Hint(tr("Домен на строку — с поддоменами. Можно geosite:…, full:…, regexp:…, keyword:…"))
            }
            Section {
                ListEditor(title: tr("Через VPN"), items: $m.settings.proxyIPs, height: 60, prompt: "91.108.4.0/22")
                ListEditor(title: tr("Напрямую"), items: $m.settings.directIPs, height: 60, prompt: "192.0.2.0/24")
                ListEditor(title: tr("Блокировать"), items: $m.settings.blockIPs, height: 60, prompt: "geoip:…")
                ListEditor(title: tr("Мимо туннеля целиком"), items: $m.settings.excludedRoutes, height: 60, prompt: tr("10.0.0.0/8 — рабочая сеть, NAS"))
            } header: { Text(tr("IP-адреса")) }
            Section {
                ChoiceMenu(title: tr("Приложения"), selection: $m.settings.appsMode, options: [(tr("Выбранные — мимо VPN"), .exclude), (tr("Только выбранные — через VPN"), .include)])
                if m.settings.appsMode == .exclude {
                    ListEditor(title: "", items: $m.settings.directApps, height: 70, prompt: tr("Имя процесса, по одному в строке"))
                } else {
                    ListEditor(title: "", items: $m.settings.includeApps, height: 70, prompt: tr("Имя процесса, по одному в строке"))
                }
                Button(tr("Выбрать приложение…")) { pickApp() }
            } header: { Text(tr("Приложения")) } footer: { Hint(tr("Работает в режиме «Весь трафик мака».")) }
            Section(tr("Дополнительно")) {
                ChoiceMenu(title: tr("Как сопоставлять домены"), selection: $m.settings.domainStrategy, options: [(tr("Как есть"), "AsIs"), (tr("IP, если нет совпадения"), "IPIfNonMatch"), (tr("Сразу по IP"), "IPOnDemand")])
            }
        }
        .formStyle(.grouped)
    }

    func pickApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]; p.allowsMultipleSelection = true
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK else { return }
        for url in p.urls {
            guard let b = Bundle(url: url), let exe = b.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else { continue }
            if m.settings.appsMode == .exclude { if !m.settings.directApps.contains(exe) { m.settings.directApps.append(exe) } }
            else if !m.settings.includeApps.contains(exe) { m.settings.includeApps.append(exe) }
        }
    }
}

// MARK: - Сеть и туннель

struct NetworkPane: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        Form {
            Section("DNS") {
                TextField(tr("Через VPN"), text: $m.settings.remoteDNS, prompt: Text(tr("1.1.1.1 или https://…")))
                VStack(alignment: .leading, spacing: 4) {
                    TextField(tr("Для сайтов страны (напрямую)"), text: $m.settings.directDNS)
                    Hint(tr("77.88.8.8 — для России; при другой стране вместо него берётся DNS провайдера."))
                }
                Toggle("IPv6", isOn: $m.settings.ipv6)
            }
            Section {
                Toggle(isOn: $m.settings.fragment) {
                    Text(tr("Фрагментация TLS"))
                    Hint(tr("Помогает, когда провайдер режет VPN по признакам соединения (DPI)."))
                }
                if m.settings.fragment {
                    ChoiceMenu(title: tr("Пакеты"), selection: $m.settings.fragmentPackets, options: [("TLS hello", "tlshello"), ("1–3", "1-3"), ("1–5", "1-5")])
                    TextField(tr("Длина, байт"), text: $m.settings.fragmentLength)
                    TextField(tr("Интервал, мс"), text: $m.settings.fragmentInterval)
                }
                Toggle(isOn: $m.settings.noises) {
                    Text(tr("Шумовые пакеты"))
                    Hint(tr("Добавляет пакеты в начало соединения. Включайте по рекомендации провайдера VPN."))
                }
                Toggle(isOn: $m.settings.mux) {
                    Text("Mux")
                    Hint(tr("Несколько соединений в одном канале. К серверам с XTLS Vision и XHTTP не применяется."))
                }
                if m.settings.mux { NumberMenu(title: tr("Потоков"), value: $m.settings.muxConcurrency, options: [1, 2, 4, 8, 16, 32, 64, 128], range: 1...128, unit: "") }
                Toggle(isOn: $m.settings.sniffing) {
                    Text(tr("Определять сайты по трафику (sniffing)"))
                    Hint(tr("Помогает применить правила для сайтов, когда приложению известен только IP-адрес."))
                }
            } header: { Text(tr("Обход блокировок")) }
            Section {
                Toggle(tr("Раздавать VPN другим устройствам"), isOn: $m.settings.allowLAN)
                if m.settings.allowLAN {
                    NumberMenu(title: tr("SOCKS-порт"), value: $m.settings.lanSocksPort, options: [10808, 20808, 30808], range: 1025...65000, unit: "")
                    NumberMenu(title: tr("HTTP-порт"), value: $m.settings.lanHttpPort, options: [10809, 20809, 30809], range: 1025...65000, unit: "")
                    TextField(tr("Логин"), text: $m.settings.lanUser, prompt: Text(tr("обязательно")))
                    SecureField(tr("Пароль"), text: $m.settings.lanPassword, prompt: Text(tr("обязательно")))
                    if m.settings.lanUser.trimmingCharacters(in: .whitespaces).isEmpty || m.settings.lanPassword.isEmpty {
                        Hint(tr("Для раздачи в локальную сеть задайте логин и пароль"))
                    }
                    LabeledContent(tr("Адрес для телефона"), value: "\(localIP() ?? tr("IP мака")):\(m.settings.lanHttpPort)")
                }
            } header: { Text(tr("Локальная сеть")) } footer: {
                Hint(tr("На телефоне: Wi-Fi → Прокси → Вручную, указать адрес и порт."))
            }
            Section(tr("Проверка серверов")) {
                ChoiceMenu(title: tr("Способ"), selection: $m.settings.pingType, options: [(tr("Настоящий запрос через сервер"), .url), (tr("Только соединение (быстрее)"), .tcp)])
                TextField(tr("Адрес проверки"), text: $m.settings.testURL)
                NumberMenu(title: tr("Ждать до"), value: $m.settings.testTimeout, options: [2, 3, 5, 10, 15, 20, 30], range: 2...30, unit: tr("с"))
                Toggle(tr("Проверять при запуске"), isOn: $m.settings.pingOnLaunch)
                Toggle(tr("Проверять после обновления подписки"), isOn: $m.settings.pingAfterUpdate)
            }
        }
        .formStyle(.grouped)
    }

    func localIP() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let first = addr else { return nil }
        defer { freeifaddrs(addr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        return nil
    }
}

// MARK: - Отдельные окна: соединения, статистика, журнал

extension SettingsPane {
    var windowID: String { "tool-\(self)" }
}

/// Небольшое тёмное окно для соединений, статистики и журнала.
struct ToolWindow: View {
    @EnvironmentObject var m: AppModel
    let pane: SettingsPane
    var body: some View {
        Group {
            switch pane {
            case .connections: ConnectionsPane()
            case .stats: StatsPane()
            default: LogPane()
            }
        }
        .scrollContentBackground(.hidden)
        .frame(minWidth: 380, idealWidth: 420, minHeight: 360, idealHeight: 520)
        .background(Dark.bg)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Соединения

struct ConnectionsPane: View {
    @EnvironmentObject var m: AppModel
    @State private var filter = ""
    /// Без служебных соединений самого ядра (xray/sing-box) — они дублируют соединения приложений.
    var list: [Conn] {
        let apps = m.connections.filter { !$0.process.hasPrefix("xray") && !$0.process.hasPrefix("sing-box") }
        return filter.isEmpty ? apps : apps.filter { $0.host.localizedCaseInsensitiveContains(filter) || $0.process.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if m.appliedSettings.mode != .tun || !m.isConnected {
                ContentUnavailableView(tr("Соединений нет"), systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(tr("Список виден при подключённом VPN в режиме «Весь трафик мака».")))
            } else {
                TextField(tr("Сайт или приложение"), text: $filter).textFieldStyle(.roundedBorder)
                HStack {
                    Text(tr("\(list.count) активных")).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Закрыть все")) { Task { await m.closeConnection(nil) } }.disabled(m.connections.isEmpty)
                }
                // Свой список вместо системной таблицы: таблица ломала раскладку окна настроек.
                VStack(spacing: 0) {
                    if list.isEmpty {
                        Text(filter.isEmpty ? tr("Соединений пока нет — они появятся, как только приложения выйдут в интернет") : tr("Ничего не найдено"))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                        Spacer(minLength: 0)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, c in
                                    connRow(host: c.host, process: c.process.replacingOccurrences(of: " (ruslan)", with: ""),
                                            route: c.route, down: formatBytes(c.download), up: formatBytes(c.upload), header: false, id: c.id)
                                        .background(i % 2 == 1 ? Color.white.opacity(0.03) : .clear)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.2)))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Hint(tr("«через VPN» — отдано ядру; российские сайты ядро дальше отправит напрямую по правилам."))
            }
        }
        .padding(14)
        .onAppear { m.watchConnections = true }
        .onDisappear { m.watchConnections = false }
    }

    /// Две строки: адрес и кнопка закрытия; ниже — приложение, путь и трафик.
    func connRow(host: String, process: String, route: String, down: String, up: String, header: Bool, id: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(host).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if let id {
                    Button { Task { await m.closeConnection(id) } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help(tr("Закрыть соединение"))
                }
            }
            .font(.callout)
            HStack(spacing: 8) {
                Text(process).lineLimit(1).truncationMode(.tail)
                Text(route).foregroundStyle(route == tr("напрямую") ? Color.secondary : Palette.on)
                Spacer(minLength: 4)
                Text(verbatim: "↓ \(down)  ↑ \(up)").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

// MARK: - Статистика

struct StatsPane: View {
    @EnvironmentObject var m: AppModel
    struct Point: Identifiable { let id = UUID(); let day: Date; let kind: String; let mb: Double }

    var points: [Point] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return m.days.compactMap { k, v -> [Point]? in
            guard let d = f.date(from: k), Date().timeIntervalSince(d) < 31 * 86400 else { return nil }
            return [Point(day: d, kind: tr("Загрузка"), mb: Double(v.down) / 1_048_576), Point(day: d, kind: tr("Отдача"), mb: Double(v.up) / 1_048_576)]
        }.flatMap { $0 }
    }

    var monthTotal: Int64 {
        let prefix = String(AppModel.dayKey(Date()).prefix(7))
        return m.days.filter { $0.key.hasPrefix(prefix) }.values.reduce(0) { $0 + $1.up + $1.down }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(tr("Сегодня"), value: formatBytes(m.days[AppModel.dayKey(Date())].map { $0.up + $0.down } ?? 0))
                LabeledContent(tr("Этот месяц"), value: formatBytes(monthTotal))
                LabeledContent(tr("Текущая сессия"), value: formatBytes(m.status.uplink + m.status.downlink))
            } header: { Text(tr("Через VPN")) } footer: { Hint(tr("Считается, пока Tutun запущен.")) }
            Section(tr("По дням, 30 дней")) {
                if points.isEmpty { Text(tr("Пока пусто")).foregroundStyle(.secondary) } else {
                    Chart(points) { p in
                        BarMark(x: .value(tr("День"), p.day, unit: .day), y: .value(tr("МБ"), p.mb))
                            .foregroundStyle(by: .value(tr("Тип"), p.kind))
                    }
                    .chartForegroundStyleScale([tr("Загрузка"): Palette.on, tr("Отдача"): Palette.brand])
                    .frame(height: 200)
                }
            }
            Section(tr("По серверам")) {
                if m.serverUsage.isEmpty { Text(tr("Пока пусто")).foregroundStyle(.secondary) }
                ForEach(m.serverUsage.sorted { $0.value > $1.value }.prefix(12), id: \.key) { k, v in
                    LabeledContent(k, value: formatBytes(v))
                }
            }
            Section(tr("IP-адрес")) {
                LabeledContent(tr("Через VPN"), value: m.ipVPN.map { "\($0.flag) \($0.ip) · \($0.country)" } ?? "—")
                LabeledContent(tr("Без VPN"), value: m.ipDirect.map { "\($0.flag) \($0.ip) · \($0.country)" } ?? "—")
                Button(tr("Проверить")) { Task { await m.checkIP() } }
            }
            Section { Button(tr("Сбросить статистику"), role: .destructive) { m.resetStats() } }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Журнал

struct LogPane: View {
    @EnvironmentObject var m: AppModel
    @State private var filter = ""
    var lines: [String] { filter.isEmpty ? m.status.log : m.status.log.filter { $0.localizedCaseInsensitiveContains(filter) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(tr("Найти в журнале"), text: $filter).textFieldStyle(.roundedBorder)
            HStack {
                ChoiceMenu(title: "", selection: $m.settings.logLevel, options: [(tr("Ошибки"), "error"), (tr("Предупреждения"), "warning"), (tr("Подробно"), "info"), (tr("Отладка"), "debug")]).frame(width: 150)
                Spacer()
                Button(tr("Открыть файл")) { NSWorkspace.shared.open(URL(fileURLWithPath: Paths.log)) }
                Button(tr("Скопировать")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.caption.monospaced())
                                .foregroundStyle(l.contains("не ") || l.lowercased().contains("error") ? Palette.busy : .primary.opacity(0.85))
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
                .onChange(of: m.status.log.count) { proxy.scrollTo("end") }
            }
        }
        .padding(14)
    }
}

// MARK: - Дополнительно

struct AdvancedPane: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            Section {
                ForEach([SettingsPane.connections, .stats, .log]) { p in
                    Button { openWindow(id: p.windowID); NSApp.activate(ignoringOtherApps: true) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: p.icon)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.color.gradient))
                            Text(p.title)
                            Spacer()
                            Image(systemName: "macwindow").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: { Hint(tr("Открываются отдельным небольшим окном.")) }
            Section(tr("Как Tutun запрашивает подписки")) {
                Toggle(isOn: $m.settings.sendHWID) {
                    Text(tr("Отправлять ID устройства"))
                    Hint(tr("Нужно провайдерам с лимитом устройств. ID этого мака: \(m.settings.hwid)"))
                }
                Toggle(isOn: $m.settings.allowHttpSubscriptions) {
                    Text(tr("Разрешить подписки по http"))
                    Hint(tr("Небезопасно: по http ключи серверов видны провайдеру и любому в сети, список могут подменить. Включайте только для своей панели без https. ID устройства по http не отправляется."))
                }
                TextField("User-Agent", text: $m.settings.userAgent, prompt: Text(SubscriptionFetcher.defaultUserAgent))
                NumberMenu(title: tr("Ждать ответа до"), value: $m.settings.subTimeout, options: [5, 10, 15, 20, 30, 60, 120], range: 5...120, unit: tr("с"))
                Toggle(tr("Обновлять при запуске"), isOn: $m.settings.updateSubsOnLaunch)
                Toggle(tr("Пропускать одинаковые серверы"), isOn: $m.settings.ignoreDuplicates)
                NumberMenu(title: tr("Предупреждать об окончании за"), value: $m.settings.expiryWarnDays, options: [0, 1, 3, 5, 7, 14, 30], range: 0...30, unit: tr("дн."))
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }
}
