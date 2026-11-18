import SwiftUI
import AppKit

/// Служебное: снимки собственных окон для проверки дизайна (разрешение «Запись экрана» не нужно).
/// Работает, только если включено: defaults write local.tutun.app tutun.debugSnapshots -bool true
/// Снимает только то, что попросили, чтобы не открывать у пользователя лишние окна:
///   open 'tutun://debug/snapshot'                  — главное окно
///   open 'tutun://debug/snapshot?panel'            — панель строки меню (вне экрана, ничего не открывает)
///   open 'tutun://debug/snapshot?settings=Журнал'  — один раздел настроек
/// Снимки: ~/Library/Caches/Tutun/shots
enum Snapshot {
    static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Tutun/shots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(_ view: NSView, name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    static func capture(_ w: NSWindow?, _ name: String) {
        guard let w, let v = w.contentView?.superview ?? w.contentView else { return }
        save(v, name: name)
    }

    @MainActor
    static func run(query: String?) async {
        let q = query?.removingPercentEncoding ?? ""
        if q.hasPrefix("settings=") {
            let paneName = String(q.dropFirst("settings=".count))
            guard let pane = SettingsPane(rawValue: paneName) else { return }
            // Раздел настроек в правой панели — только если главное окно уже открыто.
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Tutun" }) else { return }
            MainWindowSizer.show(AppModel.shared, .settings)
            AppModel.shared.settingsPane = pane
            try? await Task.sleep(nanoseconds: 900_000_000)
            capture(w, "settings-\(pane.id)")
        } else if q == "panel" {
            let host = NSHostingView(rootView: MenuPanel().environmentObject(AppModel.shared))
            let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 340, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            win.setContentSize(host.fittingSize)
            win.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 700_000_000)
            save(host, name: "panel")
            win.orderOut(nil)
        } else {
            // Главное окно: снимаем, только если оно уже открыто, — сами его не открываем.
            capture(NSApp.windows.first { $0.isVisible && $0.title == "Tutun" }, "main")
        }
    }
}
