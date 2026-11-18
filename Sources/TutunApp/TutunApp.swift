import SwiftUI
import AppKit
import TutunCore

@main
struct TutunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().id(model.language).environment(\.locale, L10n.locale).environmentObject(model).buttonStyle(TutunButtonStyle()).modifier(MotionPreference())
        } label: {
            MenuBarLabel(icon: menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Tutun", id: "main") {
            MainView().id(model.language).environment(\.locale, L10n.locale).environmentObject(model).buttonStyle(TutunButtonStyle()).modifier(MotionPreference())
                .frame(height: MainWindowSizer.height)
                .modifier(DockPresence())
                .environmentObject(model)
        }
        .defaultSize(width: MainWindowSizer.leftWidth * MainWindowSizer.scale, height: MainWindowSizer.height)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        toolWindow(.connections)
        toolWindow(.stats)
        toolWindow(.log)
    }

    private func toolWindow(_ p: SettingsPane) -> some Scene {
        Window(p.title, id: p.windowID) {
            ToolWindow(pane: p).id(model.language).environment(\.locale, L10n.locale).environmentObject(model).buttonStyle(TutunButtonStyle()).modifier(MotionPreference())
        }
        .defaultSize(width: 420, height: 520)
        .windowResizability(.contentMinSize)
    }

    private var menuIcon: String {
        switch model.status.state {
        case .running: return model.status.healthy == true ? "checkmark.shield.fill" : (model.status.healthy == false ? "exclamationmark.shield" : "shield.lefthalf.filled")
        case .starting, .reconnecting: return "shield.lefthalf.filled"
        case .failed: return "exclamationmark.shield"
        case .stopped: return "shield.slash"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Открыт ли Tutun как объект входа (при включении мака) — тогда окно не показываем, только значок в строке меню.
    static var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        AppDelegate.launchedAtLogin = ev?.eventID == kAEOpenApplication &&
            ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Ядра проверки серверов принадлежат приложению и не должны оставаться после выхода.
    func applicationWillTerminate(_ notification: Notification) {
        Tester.stopAll()
    }

    /// Повторный запуск из Finder/Launchpad или клик по значку в Dock — открыть окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowOpener.open() }
        return true
    }

    /// Ссылки tutun://, vless:// и т.п., открытые из браузера, «Команд» или Терминала (open 'tutun://toggle').
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in for u in urls { await AppModel.shared.handleExternalURL(u) } }
    }
}

/// Открывает главное окно откуда угодно (из делегата приложения в том числе).
enum WindowOpener {
    static var action: OpenWindowAction?
    static var openedOnLaunch = false
    /// Настройки — правая панель главного окна.
    @MainActor static func openSettings() {
        open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainWindowSizer.show(AppModel.shared, .settings) }
    }
    static func open() {
        action?(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Значок в строке меню. Он есть всегда, поэтому через него запоминаем, как открыть окно, и открываем его при запуске.
struct MenuBarLabel: View {
    let icon: String
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: icon)
            .onAppear {
                WindowOpener.action = openWindow
                if !WindowOpener.openedOnLaunch && !AppDelegate.launchedAtLogin {
                    WindowOpener.openedOnLaunch = true
                    DispatchQueue.main.async { WindowOpener.open() }
                }
            }
    }
}

func openMainWindow(_ openWindow: OpenWindowAction) {
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
}

/// Пока окно открыто — Tutun в Dock и в переключателе ⌘Tab (если не выключено в настройках);
/// окно закрыли — остаётся только значок в строке меню.
struct DockPresence: ViewModifier {
    @EnvironmentObject var m: AppModel
    func body(content: Content) -> some View {
        content
            .onAppear {
                DockPresence.apply(windowOpen: true, show: m.appliedSettings.showInDock)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear { DockPresence.apply(windowOpen: false, show: m.appliedSettings.showInDock) }
            .onChange(of: m.appliedSettings.showInDock) { DockPresence.apply(windowOpen: true, show: m.appliedSettings.showInDock) }
    }

    static func apply(windowOpen: Bool, show: Bool) {
        NSApp.setActivationPolicy(windowOpen && show ? .regular : .accessory)
        if windowOpen {
            // После смены режима окно может уйти назад — возвращаем его наверх.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Tutun" }?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// Маленький график скорости за последнюю минуту.
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let maxV = max(values.max() ?? 1, 1)
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: g.size.height * (1 - CGFloat(v / maxV)) * 0.92 + g.size.height * 0.04)
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)); p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Palette.on.opacity(0.28), Palette.on.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f); pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(LinearGradient(colors: [Palette.on, Palette.brand], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}



private struct MotionPreference: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}
