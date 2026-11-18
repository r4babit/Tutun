import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TutunCore

/// Главное окно: одна страница. Справа сверху — «Добавить» и «Настройки».
struct MainView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Без полосы заголовка: кнопки окна поверх фона, «+» и настройки — на той же линии справа.
        VStack(spacing: 0) {
            topBar
            // Всё содержимое окна крупнее на MainWindowSizer.scale: раскладка та же, окно больше.
            GeometryReader { g in
                let k = MainWindowSizer.scale
                HomeView()
                    .frame(width: g.size.width / k, height: g.size.height / k, alignment: .topLeading)
                    .scaleEffect(k, anchor: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Dark.bg.ignoresSafeArea())
        .modifier(ToastOverlay(message: $m.message))
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .navigationTitle("Tutun")
        .onReceive(NotificationCenter.default.publisher(for: .tutunShowAdd)) { _ in MainWindowSizer.show(m, .add) }
        .onDrop(of: [.fileURL, .plainText, .image], isTargeted: nil) { providers in
            handleDrop(providers); return true
        }
    }

    /// Тонкая верхняя строка высотой с кнопки окна (закрыть/свернуть/развернуть стоят слева поверх неё).
    var topBar: some View {
        HStack(spacing: 4) {
            Spacer()
        }
        .padding(.leading, 80).padding(.trailing, 10)
        .frame(height: 30)
    }

    /// Перетаскивание: файл с ссылками/конфигом WireGuard, картинка с QR, текст.
    func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        let qr = QR.decode(file: url)
                        if !qr.isEmpty { await m.importQR(qr) }
                        else if let t = try? String(contentsOf: url, encoding: .utf8) { await m.importText(t) }
                    }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in if let s { Task { @MainActor in await m.importText(s) } } }
            }
        }
    }
}

/// Иконка в тонкой верхней строке.
struct TopIconButton: View {
    let icon: String; let help: String; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? Color.white : Dark.text2)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help).accessibilityLabel(help)
    }
}

// MARK: - Главная: слева состояние, справа страны

struct HomeView: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        // Левая часть всегда одной ширины; правая (серверы) открывается вместе с плавным расширением окна.
        // Список лежит поверх справа и не влияет на размер окна — открывается по мере расширения окна.
        ZStack(alignment: .topLeading) {
            StatusColumn()
                .frame(width: MainWindowSizer.leftWidth)
                .frame(maxHeight: .infinity)
            if let panel = m.sidePanel {
                HStack(spacing: 0) {
                    Rectangle().fill(Dark.line).frame(width: 1)
                    ZStack {
                        Group {
                            switch panel {
                            case .servers: CountryList()
                            case .settings: SettingsPanel()
                            case .add: AddSheet()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(panel)
                        .transition(.opacity)
                    }
                    .clipped()
                }
                .frame(width: MainWindowSizer.serversWidth)
                .frame(maxHeight: .infinity)
                .offset(x: MainWindowSizer.leftWidth)
            }
        }
        .frame(minWidth: MainWindowSizer.leftWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .onAppear { MainWindowSizer.resize(showServers: m.sidePanel != nil, animate: false) }
    }
}

/// Ширина окна: узкое — только левая часть; со списком серверов — шире. Меняется плавно.
enum MainWindowSizer {
    static let leftWidth: CGFloat = 400
    static let serversWidth: CGFloat = 400      // как основная часть — без перекоса
    /// Масштаб главного окна (пользователь попросил крупнее на 15%).
    static let scale: CGFloat = 1.15
    static let height: CGFloat = (640 * scale).rounded()
    static let duration: TimeInterval = 0.32

    static var window: NSWindow? { NSApp.windows.first { $0.title == "Tutun" && $0.isVisible } }

    /// Открыть/закрыть правую панель (серверы или настройки). Открыта другая — просто меняем содержимое.
    /// При открытии сначала появляется панель, потом окно растёт; при закрытии окно сужается, панель убирается после.
    @MainActor
    static func toggle(_ m: AppModel, _ panel: SidePanel) {
        if m.sidePanel == panel {
            resize(showServers: false, animate: true) { m.sidePanel = nil }
        } else if m.sidePanel != nil {
            let animation: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil : .easeInOut(duration: 0.18)
            withAnimation(animation) { m.sidePanel = panel }
        } else {
            m.sidePanel = panel
            resize(showServers: true, animate: true)
        }
    }

    /// Показать панель, не закрывая её, если уже открыта (для шестерёнки в строке меню).
    @MainActor
    static func show(_ m: AppModel, _ panel: SidePanel) {
        if m.sidePanel != panel { toggle(m, panel) }
    }

    /// Окно нельзя растягивать мышью и разворачивать — размер меняет только кнопка «Серверы».
    static func lock(_ w: NSWindow) {
        if w.styleMask.contains(.resizable) { w.styleMask.remove(.resizable) }
        w.collectionBehavior.insert(.fullScreenNone)
        w.standardWindowButton(.zoomButton)?.isEnabled = false
    }

    @MainActor
    static func resize(showServers: Bool, animate: Bool, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async {
            guard let w = window else { completion?(); return }
            lock(w)
            var f = w.frame
            let target = ((showServers ? leftWidth + serversWidth : leftWidth) * scale).rounded()
            // Высоту держит само окно (фиксированный размер содержимого), здесь меняем только ширину.
            guard abs(f.width - target) > 1 else { completion?(); return }
            f.size.width = target   // левый край на месте, окно растёт и сужается вправо
            guard animate else { w.setFrame(f, display: true); completion?(); return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                w.animator().setFrame(f, display: true)
            } completionHandler: {
                completion?()
            }
        }
    }
}

/// Три квадратика над кнопкой подключения: добавить, настройки, серверы.
struct ActionTiles: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        HStack(spacing: 4) {
            tile(tr("Добавить"), icon: "plus", selected: m.sidePanel == .add, help: tr("Добавить подписку или серверы")) {
                MainWindowSizer.toggle(m, .add)
            }
            tile(tr("Настройки"), icon: "gearshape", selected: m.sidePanel == .settings,
                 help: m.sidePanel == .settings ? tr("Скрыть настройки") : tr("Показать настройки")) {
                MainWindowSizer.toggle(m, .settings)
            }
            tile(tr("Серверы"), icon: "list.bullet", selected: m.sidePanel == .servers,
                 help: m.sidePanel == .servers ? tr("Скрыть список серверов") : tr("Показать список серверов")) {
                MainWindowSizer.toggle(m, .servers)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Dark.card))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Dark.line))
    }

    func tile(_ title: String, icon: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12.5, weight: .semibold)).frame(height: 16)
                Text(title).font(.system(size: 9.5, weight: selected ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(selected ? Color.white : Dark.text2)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Dark.selected : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Palette.on.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .accessibilityLabel(help)
        .help(help)
    }
}

/// Левая колонка: состояние, страна, сервер, цифры, режимы, кнопка.
struct StatusColumn: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var updater = Updater.shared
    var compact = false

    var stateColor: Color { Palette.state(m.status, reachable: m.daemonReachable) }
    var connected: Bool { m.isConnected && m.status.state == .running }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            notices
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(stateColor).frame(width: 8, height: 8)
                    Text(StatusText.title(m.status, reachable: m.daemonReachable)).font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(stateColor)
                Text(m.currentCountryName ?? m.selectionTitle)
                    .font(.system(size: compact ? 26 : 34, weight: .heavy))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(subtitle).font(.callout).foregroundStyle(Dark.text2).lineLimit(1)
            }

            serverCard

            if m.isConnected && m.status.blocking != true {
                HStack(spacing: 8) {
                    StatTile(label: tr("Задержка"), value: m.currentLatency.map { tr("\($0) мс") } ?? "—")
                    StatTile(label: tr("Загрузка"), value: formatSpeed(m.speedDown))
                    if let since = m.status.since {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("В сети")).font(.caption).foregroundStyle(Dark.text2)
                            Text(since, style: .timer).font(.system(.body, design: .default).weight(.semibold)).monospacedDigit()
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dark.card))
                    } else {
                        StatTile(label: tr("Отдача"), value: formatSpeed(m.speedUp))
                    }
                }
                if !compact { Sparkline(values: m.history).frame(height: 34) }
            }

            // В панели строки меню — только маршруты; на главной режимы живут в настройках.
            if compact { RouteModeSwitch() }

            if !compact { Spacer(minLength: 0); ActionTiles() }

            mainButton
        }
        .padding(compact ? 0 : 28)
        .background(
            compact ? nil :
            RadialGradient(colors: [stateColor.opacity(connected ? 0.16 : 0.06), .clear], center: .init(x: 0.5, y: 0.2),
                           startRadius: 10, endRadius: 320)
        )
    }

    var subtitle: String {
        if !m.daemonReachable { return tr("Установите службу, чтобы подключаться") }
        if m.isConnected {
            var parts: [String] = []
            if let ip = m.ipVPN { parts.append("IP \(ip.ip)") }
            if m.appliedSettings.routingMode == .global { parts.append(tr("всё через VPN")) }
            return parts.joined(separator: " · ")
        }
        return tr("Нажмите «Подключить»")
    }

    var serverCard: some View {
        let s = m.currentServer
        return HStack(spacing: 12) {
            Text(s?.flag ?? m.currentFlag ?? (m.appliedSettings.autoSelect ? "⚡️" : "🌐")).font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.map { $0.cleanName(m.displayName($0)) } ?? m.selectionTitle).font(.body.weight(.semibold)).lineLimit(1)
                Text(cardSubtitle(s)).font(.caption).foregroundStyle(Dark.text2).lineLimit(1)
            }
            Spacer()
            if let s { SignalBars(ms: m.pings[s.id]) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Dark.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Dark.line))
    }

    func cardSubtitle(_ s: Server?) -> String {
        let byCountry: String = {
            switch m.appliedSettings.countryPick {
            case .fastest: return tr("самый быстрый из списка")
            case .lastUsed: return tr("последний выбранный")
            case .first: return tr("первый в списке")
            case .random: return tr("случайный из списка")
            }
        }()
        let how = m.settings.autoSelect ? tr("выбран автоматически") : (m.settings.selectedCountry != nil ? byCountry : tr("выбран вручную"))
        guard let s else { return m.isConnected ? how : (m.settings.autoSelect ? tr("Tutun выберет сам") : how) }
        return "\(s.proto) · \(s.transport) · \(how)"
    }

    @ViewBuilder var mainButton: some View {
        if let stage = m.daemonInstallStage {
            // Вместо кнопки — что сейчас происходит: нажать второй раз нечего.
            HStack(spacing: 8) {
                if stage == .done { Image(systemName: "checkmark.circle.fill") } else { ProgressView().controlSize(.small) }
                Text(stage.title)
            }
            .frame(maxWidth: .infinity)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.brand.opacity(0.45)))
            .accessibilityElement(children: .combine)
        } else if !m.daemonReachable || m.daemonOutdated {
            Button { Task { await m.installDaemon() } } label: {
                Text(m.daemonInstalled ? tr("Обновить службу") : tr("Установить службу")).frame(maxWidth: .infinity)
            }
            .buttonStyle(BigButton(fill: Palette.brand, text: .white)).disabled(m.busy)
        } else if m.status.blocking == true || (m.status.state == .failed && m.status.mode != nil) {
            HStack {
                Button { Task { await m.connect() } } label: {
                    Text(tr("Повторить")).frame(maxWidth: .infinity)
                }
                .buttonStyle(BigButton(fill: Palette.brand, text: .white))
                Button { Task { await m.disconnect() } } label: {
                    Text(tr("Отключить")).frame(maxWidth: .infinity)
                }
                .buttonStyle(BigButton(fill: Dark.card, text: .primary))
            }
            .disabled(m.busy)
        } else {
            Button { Task { await m.toggle() } } label: {
                HStack {
                    if m.busy { ProgressView().controlSize(.small) }
                    Text(m.isConnected ? tr("Отключить") : tr("Подключить"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(BigButton(fill: m.isConnected ? Color(white: 0.93) : Palette.on, text: m.isConnected ? Dark.bg : .white))
            .disabled(m.busy)
        }
    }

    @ViewBuilder var notices: some View {
        if let r = updater.available {
            Button {
                m.settingsPane = .about
                MainWindowSizer.show(m, .settings)
            } label: {
                Label(updater.revoked ? tr("Эта версия Tutun отозвана — установите обновление \(r.version)")
                                      : tr("Доступна версия \(r.version) — нажмите, чтобы обновить. VPN не отключится."),
                      systemImage: updater.revoked ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(updater.revoked ? Palette.busy : Palette.on).font(.callout)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill((updater.revoked ? Palette.busy : Palette.on).opacity(0.12)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if m.oldDaemonInstalled {
            Banner(text: tr("Осталась служба от прошлой версии — нажмите «Обновить службу»."), color: Palette.busy)
        }
        if !m.conflicts.isEmpty {
            Banner(text: tr("Работает другой VPN: \(m.conflicts.joined(separator: ", ")). Выключите его."), color: Palette.busy)
        }
    }
}

struct StatTile: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Dark.text2)
            Text(value).font(.body.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dark.card))
    }
}

struct BigButton: ButtonStyle {
    let fill: Color; let text: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(text)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Заголовок подписки можно тащить мышью, чтобы поменять порядок подписок.
struct DragSubscription: ViewModifier {
    let id: String, title: String, enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.draggable(id) {
                Text(title).font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Dark.card))
            }
        } else { content }
    }
}

/// Правая колонка (как в Happ): «Самый быстрый», затем выпадающий список подписки,
/// внутри серверы по странам. Клик по серверу — подключиться к нему.
struct CountryList: View {
    @EnvironmentObject var m: AppModel
    @State private var expanded: Set<String> = []
    @State private var info: SubRef?
    @State private var editing: EditTarget?
    @State private var qr: QRItem?
    /// Подписка, над которой сейчас держат перетаскиваемую — подсвечивается место вставки.
    @State private var dropTarget: String?
    var compact = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                fastestRow
                // Каждый раздел — в своём контейнере: одна и та же страна/сервер может быть
                // и в «Избранном», и в подписке, и список не должен их путать.
                if !m.favoriteCountryList.isEmpty || !m.favoriteServerList.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Button { withAnimation(.easeOut(duration: 0.18)) { m.favoritesCollapsed.toggle() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Dark.text3)
                                    .rotationEffect(.degrees(m.favoritesCollapsed ? 0 : 90))
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Palette.busy)
                                Text(tr("Избранное")).font(.caption.weight(.semibold)).foregroundStyle(Dark.text2)
                                Text("\(m.favoriteCountryList.count + m.favoriteServerList.count)").font(.caption2.weight(.semibold)).foregroundStyle(Dark.text3)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(m.favoritesCollapsed ? tr("Развернуть") : tr("Свернуть"))
                        if !m.favoritesCollapsed {
                            ForEach(m.favoriteCountryList) { c in
                                countryBlock(c, key: "fav|\(c.id)")
                            }
                            ForEach(m.favoriteServerList) { s in serverRow(s, showFlag: true) }
                        }
                    }
                    .id("favorites")
                }
                ForEach(m.serverGroups) { g in
                    VStack(alignment: .leading, spacing: 2) {
                        groupHeader(g)
                        if !m.isCollapsed(g.id) {
                            if g.mode == .list {
                                ForEach(g.servers) { s in serverRow(s, showFlag: true) }
                            } else {
                                ForEach(g.countries) { c in
                                    countryBlock(c, key: "\(g.id)|\(c.id)")
                                }
                            }
                        }
                    }
                    .id("group|\(g.id)")
                    // Перетаскивание подписок: бросить на подписку — встать перед ней; на «Добавленные вручную» — в конец.
                    .dropDestination(for: String.self) { items, _ in
                        guard !compact, let dragged = items.first, dragged != g.id else { return false }
                        withAnimation(.easeOut(duration: 0.18)) { m.moveSubscription(dragged, onto: g.id) }
                        return true
                    } isTargeted: { over in dropTarget = over ? g.id : (dropTarget == g.id ? nil : dropTarget) }
                }
                if m.serverGroups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "globe").font(.system(size: 34)).foregroundStyle(Dark.text3)
                        Text(tr("Серверов пока нет")).font(.headline)
                        Text(tr("Нажмите «Добавить» и вставьте ссылку на подписку")).foregroundStyle(Dark.text2)
                        Button(tr("Добавить подписку")) { NotificationCenter.default.post(name: .tutunShowAdd, object: nil) }
                            .buttonStyle(TutunButtonStyle(primary: true))
                    }.frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.horizontal, compact ? 0 : 10).padding(.vertical, compact ? 0 : 12)
        }
        .clipped()   // список не заезжает под заголовок окна при прокрутке
        .sheet(item: $editing) { t in ServerEditor(original: t.server).environmentObject(m) }
        .sheet(item: $qr) { q in QRSheet(title: q.title, text: q.text) }
        .sheet(item: $info) { r in SubscriptionInfo(subID: r.id).environmentObject(m) }
    }

    struct SubRef: Identifiable { let id: UUID }

    // MARK: строки

    var fastestRow: some View {
        let sel = m.settings.autoSelect
        return Button { Task { await m.selectFastest() } } label: {
            HStack(spacing: 12) {
                Text("⚡️").font(.system(size: compact ? 18 : 22)).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("Самый быстрый")).font(.body.weight(sel ? .semibold : .medium))
                    if !compact { Text(tr("Tutun выберет сам и переключит при обрыве")).font(.caption).foregroundStyle(Dark.text3) }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, compact ? 6 : 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(sel ? Dark.selected : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(sel ? Palette.on.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
    }

    /// Заголовок подписки — выпадающий. Сворачивание, «i» и проверка задержки — отдельные кнопки.
    func groupHeader(_ g: AppModel.ServerGroup) -> some View {
        let open = !m.isCollapsed(g.id)
        return HStack(spacing: 8) {
            // Сворачивание — щелчком по строке, а не кнопкой: кнопка перехватывала нажатие,
            // и подписку можно было тащить только за самый край.
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 16)
                Text(g.title).font(.callout.weight(.semibold)).lineLimit(1)
                Text("\(g.count)").font(.caption.weight(.semibold)).foregroundStyle(Dark.text3)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Dark.bg))
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { m.toggleCollapsed(g.id) } }
            .accessibilityAddTraits(.isButton)
            .help(open ? tr("Свернуть") : tr("Развернуть"))
            HStack(spacing: 0) {
                if !compact {
                    if g.movable {
                        headerIcon("arrow.clockwise", busy: m.refreshingGroup == g.id, help: tr("Обновить подписку"),
                                   disabled: m.refreshingGroup != nil) { Task { await m.refreshGroup(g.id) } }
                    }
                    headerIcon("speedometer", busy: m.pingingGroup == g.id, help: tr("Проверить задержку"),
                               disabled: m.pingingGroup != nil) { Task { await m.pingGroup(g.id) } }
                    layoutMenu(g)
                }
                if let id = UUID(uuidString: g.id) {
                    headerIcon("info.circle", busy: false, help: tr("Информация о подписке"), disabled: false) { info = SubRef(id: id) }
                }
            }
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Dark.card))
        // Куда встанет перетаскиваемая подписка — подсвечивается вся строка.
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(dropTarget == g.id ? Palette.on : .clear, lineWidth: 2))
        .modifier(DragSubscription(id: g.id, title: g.title, enabled: g.movable && !compact))
        .padding(.top, 10)
    }

    func headerIcon(_ name: String, busy: Bool, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if busy { ProgressView().controlSize(.mini) }
            else {
                Button(action: action) { Image(systemName: name).frame(width: 24, height: 28).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Dark.text2).disabled(disabled)
            }
        }
        .frame(width: 24, height: 28)
        .accessibilityLabel(help)
        .help(help)
    }

    /// Вид («по странам» / «списком») и сортировка — своя у каждой подписки.
    func layoutMenu(_ g: AppModel.ServerGroup) -> some View {
        Menu {
            Picker(tr("Показывать"), selection: Binding(get: { g.mode }, set: { m.setLayout(of: g.id, mode: $0) })) {
                Text(tr("По странам")).tag(GroupListMode.countries)
                Text(tr("Списком")).tag(GroupListMode.list)
            }
            .pickerStyle(.inline)
            Picker(tr("Сортировка"), selection: Binding(get: { g.mode == .list && g.sort == .count ? .name : g.sort },
                                                        set: { m.setLayout(of: g.id, sort: $0) })) {
                Text(tr("По имени")).tag(GroupSort.name)
                if g.mode == .countries { Text(tr("По числу серверов")).tag(GroupSort.count) }
                Text(tr("По задержке")).tag(GroupSort.ping)
                Text(tr("Как у провайдера")).tag(GroupSort.provider)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down").frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Dark.text2)
        .accessibilityLabel(tr("Вид и сортировка"))
        .help(tr("Вид и сортировка"))
    }

    /// Страна и (если раскрыта) её серверы — одним блоком.
    func countryBlock(_ c: AppModel.Country, key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            countryRow(c, open: expanded.contains(key)) {
                withAnimation(.easeOut(duration: 0.18)) {
                    if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
                }
            }
            if expanded.contains(key) {
                ForEach(c.servers) { s in serverRow(s) }
            }
        }
    }

    /// Строка страны: клик — самый быстрый сервер страны, стрелка справа — раскрыть её серверы.
    func countryRow(_ c: AppModel.Country, open: Bool, toggle: @escaping () -> Void) -> some View {
        let sel = !m.settings.autoSelect && m.settings.selectedCountry == c.id
        let here = m.isConnected && m.currentServer?.countryCode == c.id
        let connect = { Task { await m.selectCountry(c.id) } }
        return HStack(spacing: 0) {
            Button { _ = connect() } label: {
                HStack(spacing: 12) {
                    Text(c.flag).font(.system(size: compact ? 17 : 21)).frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).font(.body.weight(sel || here ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.75)
                        if !compact {
                            Text(serversWord(c.servers.count) + (here ? tr(" · сейчас здесь") : ""))
                                .font(.caption).foregroundStyle(Dark.text3).lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 12).padding(.vertical, compact ? 5 : 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Подключиться к самому быстрому серверу страны"))
            Button { _ = connect() } label: {
                Latency(ms: c.bestPing).padding(.vertical, compact ? 5 : 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            StarButton(on: m.isFavoriteCountry(c.id)) { m.toggleFavoriteCountry(c.id) }
            Button(action: toggle) {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .frame(width: 34, height: compact ? 30 : 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Dark.text2)
            .accessibilityLabel(open ? tr("Скрыть серверы") : tr("Показать серверы страны"))
            .help(open ? tr("Скрыть серверы") : tr("Показать серверы страны"))
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(sel ? Dark.selected : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(sel ? Palette.on.opacity(0.35) : .clear))
        .modifier(HoverHighlight())
    }

    func serversWord(_ n: Int) -> String {
        L10n.servers(n)
    }

    func serverRow(_ s: Server, showFlag: Bool = false) -> some View {
        let sel = !m.settings.autoSelect && m.settings.selectedCountry == nil && m.settings.selectedServerID == s.id
        let active = m.isConnected && m.currentServer?.id == s.id
        let connect = { Task { await m.select(s); if !m.isConnected { await m.connect() } } }
        return HStack(spacing: 0) {
            Button { _ = connect() } label: {
                HStack(spacing: 10) {
                    // В раскрытой стране — мини-флаг, в «Избранном» — обычный.
                    Text(s.flag ?? "🌐").font(.system(size: showFlag ? (compact ? 16 : 19) : (compact ? 11 : 13))).frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(s.cleanName(m.displayName(s))).font(.callout.weight(sel || active ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.75)
                            if active { Chip(text: tr("сейчас"), tint: Palette.on) }
                        }
                        if let note = s.note, !compact { Text(note).font(.caption2).foregroundStyle(Dark.text2).lineLimit(1) }
                        else if !compact { Text("\(s.proto) · \(s.transport)").font(.caption2).foregroundStyle(Dark.text3) }
                    }
                    Spacer(minLength: 6)
                    if m.speedTesting == s.id { ProgressView().controlSize(.mini) }
                    else if !compact, let sp = m.speeds[s.id], sp > 0 { Text(formatMbps(sp)).font(.caption.monospacedDigit()).foregroundStyle(Dark.text3) }
                }
                .padding(.leading, 12).padding(.vertical, compact ? 4 : 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { _ = connect() } label: {
                Latency(ms: m.pings[s.id]).padding(.vertical, compact ? 4 : 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            StarButton(on: s.favorite) { m.toggleFavorite(s) }
            Color.clear.frame(width: 34, height: 1)   // место стрелки — чтобы звёздочки стояли в одну линию
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(sel || active ? Dark.selected : .clear))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(sel ? Palette.on.opacity(0.35) : .clear))
        .modifier(HoverHighlight())
        .contextMenu {
            Button(tr("Подключиться")) { _ = connect() }
            if let code = s.countryCode { Button(tr("Самый быстрый в стране «\(Server.countryName(code))»")) { Task { await m.selectCountry(code) } } }
            Button(tr("Проверить задержку")) { Task { await m.pingOne(s) } }
            Button(tr("Тест скорости")) { Task { await m.speedTest(s) } }
            Divider()
            Button(s.favorite ? tr("Убрать из избранного") : tr("В избранное")) { m.toggleFavorite(s) }
            Button(tr("Изменить…")) { editing = EditTarget(server: s) }
            if let link = s.rawLink {
                Button(tr("Скопировать ссылку")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }
                Button(tr("Показать QR-код")) { qr = QRItem(title: m.displayName(s), text: link) }
            }
            Divider()
            Button(s.subscriptionID == nil ? tr("Удалить") : tr("Скрыть"), role: .destructive) { m.remove(s) }
        }
    }
}

/// Звёздочка «в избранное»: отмеченное сразу появляется вверху списка.
struct StarButton: View {
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 13))
                .foregroundStyle(on ? Palette.busy : Dark.text3.opacity(hover ? 1 : 0.55))
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(on ? tr("Убрать из избранного") : tr("В избранное"))
        .help(on ? tr("Убрать из избранного") : tr("В избранное — будет вверху списка"))
    }
}

/// Лёгкая подсветка строки под курсором.
struct HoverHighlight: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.04 : 0)))
            .onHover { hover = $0 }
    }
}

struct Banner: View {
    let text: String; let color: Color
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(color).font(.callout)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12)))
    }
}
