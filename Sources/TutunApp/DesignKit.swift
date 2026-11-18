import SwiftUI
import TutunCore

struct TutunButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, primary: primary)
    }
    private struct StyledButton: View {
        let configuration: ButtonStyle.Configuration
        let primary: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(configuration.role == .destructive ? Palette.bad : (primary ? Dark.bg : Color.white))
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(primary ? Palette.on : Dark.card))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hovered ? Palette.on.opacity(0.5) : Dark.line))
                .brightness(configuration.isPressed ? -0.06 : (hovered ? 0.04 : 0))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .onHover { hovered = $0 }
        }
    }
}

/// Цвета Tutun. Фирменный — из иконки; состояния — защищено / подключение / выключено / ошибка.
enum Palette {
    static let brand = Color(red: 0.231, green: 0.435, blue: 0.910)      // #3B6FE8
    static let brandDeep = Color(red: 0.357, green: 0.247, blue: 0.851)  // #5B3FD9
    static let on = Color(red: 0.122, green: 0.710, blue: 0.561)         // #1FB58F
    static let busy = Color(red: 0.949, green: 0.639, blue: 0.227)       // #F2A33A
    static let off = Color(red: 0.541, green: 0.576, blue: 0.651)        // #8A93A6
    static let bad = Color(red: 0.898, green: 0.282, blue: 0.302)        // #E5484D

    static func state(_ s: DaemonStatus, reachable: Bool) -> Color {
        guard reachable else { return off }
        switch s.state {
        case .running: return s.healthy == true ? on : busy
        case .starting, .reconnecting: return busy
        case .failed: return bad
        case .stopped: return off
        }
    }
}

/// Слова состояния.
enum StatusText {
    static func title(_ s: DaemonStatus, reachable: Bool) -> String {
        guard reachable else { return tr("Служба не запущена") }
        if s.blocking == true { return tr("Трафик вне VPN заблокирован") }
        switch s.state {
        case .running: return s.healthy == true ? tr("Подключено") : (s.healthy == false ? tr("Нет связи с сервером") : tr("Подключение…"))
        case .starting: return tr("Подключение…")
        case .reconnecting: return tr("Переподключение…")
        case .failed: return tr("Ошибка подключения")
        case .stopped: return tr("Отключено")
        }
    }
}

/// Тёмная тема варианта 2.
enum Dark {
    static let bg = Color(red: 0.067, green: 0.078, blue: 0.106)        // #11141B
    static let card = Color(red: 0.094, green: 0.110, blue: 0.149)      // #181C26
    static let line = Color(red: 0.145, green: 0.169, blue: 0.224)      // #252B39
    static let text2 = Color(red: 0.545, green: 0.576, blue: 0.655)     // #8B93A7
    static let text3 = Color(red: 0.420, green: 0.451, blue: 0.529)     // #6B7387
    static let selected = Color(red: 0.102, green: 0.165, blue: 0.149)  // #1A2A26
}

extension Server {
    /// Имя без флага в начале — флаг показываем отдельно и крупно.
    func cleanName(_ display: String) -> String {
        guard flag != nil else { return display }
        return String(display.unicodeScalars.drop { (0x1F1E6...0x1F1FF).contains($0.value) || $0 == " " || $0.value == 0xFE0F }
            .map(Character.init))
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Мелкие элементы

/// «Уровень сигнала» по задержке: 3 полосы — быстро, 2 — нормально, 1 — медленно, пусто — нет ответа.
struct SignalBars: View {
    let ms: Int?
    var bars: Int {
        guard let ms else { return -1 }
        if ms < 0 { return 0 }
        return ms < 300 ? 3 : (ms < 800 ? 2 : 1)
    }
    var color: Color { bars == 3 ? Palette.on : (bars == 2 ? Palette.busy : (bars == 1 ? Palette.bad : Palette.off)) }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= bars ? color : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
        .frame(height: 13)
        .accessibilityLabel(ms.map { $0 < 0 ? tr("нет ответа") : tr("\($0) миллисекунд") } ?? tr("не проверен"))
    }
}

/// Задержка: полоски и число.
struct Latency: View {
    let ms: Int?
    var body: some View {
        // Полоски прижаты к числу, число — к правому краю колонки (ровно под звёздочкой у всех строк).
        HStack(spacing: 5) {
            Spacer(minLength: 0)
            SignalBars(ms: ms)
            Group {
                if let ms { Text(verbatim: ms < 0 ? tr("нет ответа") : tr("\(ms) мс")) } else { Text("—") }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(ms.map { $0 < 0 ? Palette.bad : Color.secondary } ?? Color.secondary.opacity(0.6))
            .lineLimit(1)
        }
        .frame(width: 104, alignment: .trailing)
        .padding(.trailing, 4)
    }
}

/// Метка-«таблетка».
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.13)))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}

/// Плашка-сообщение над содержимым окна.
struct MessageBar: View {
    let text: String
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Dark.card))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Dark.line))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
    }
}

struct ToastOverlay: ViewModifier {
    @Binding var message: String?
    var bottom: CGFloat = 14
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let text = message {
                MessageBar(text: text) { message = nil }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                    .padding(.horizontal, 14).padding(.bottom, bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: message)
        .task(id: message) {
            guard message != nil else { return }
            do { try await Task.sleep(nanoseconds: 4_000_000_000) }
            catch { return }
            message = nil
        }
    }
}


/// Переключатель маршрутов в стиле приложения: тёмная плашка, выбранное подсвечено зелёным.
struct RouteModeSwitch: View {
    @EnvironmentObject var m: AppModel
    private let items: [(RoutingMode, String, String)] = [
        (.rule, tr("По правилам"), "arrow.triangle.branch"),
        (.global, tr("Всё через VPN"), "lock.fill"),
        (.direct, tr("Напрямую"), "arrow.right"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { mode, title, icon in
                let sel = m.appliedSettings.routingMode == mode
                Button { Task { await m.setRoutingMode(mode) } } label: {
                    VStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                        Text(title).font(.caption.weight(sel ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(sel ? Color.white : Dark.text2)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(sel ? Dark.selected : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(sel ? Palette.on.opacity(0.45) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(mode))
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Dark.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Dark.line))
        .animation(.easeOut(duration: 0.15), value: m.appliedSettings.routingMode)
    }

    func help(_ mode: RoutingMode) -> String {
        switch mode {
        case .rule: return tr("Российские сайты и банки напрямую, остальное через VPN")
        case .global: return tr("Всё через VPN, включая российские сайты")
        case .direct: return tr("VPN включён, но трафик идёт напрямую")
        }
    }
}
