import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TutunCore

/// «+» в главном окне: добавить подписку или серверы любым способом.
struct AddSheet: View {
    @EnvironmentObject var m: AppModel
    @State private var text = ""
    @State private var working = false
    private var canAdd: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Добавить")).font(.title2.weight(.bold))
                Text(tr("Ссылка на подписку от провайдера или ссылки серверов (vless://, vmess://, trojan://, ss://, hysteria2://, tuic://, wireguard://) — по одной в строке."))
                    .font(.callout).foregroundStyle(Dark.text2).fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dark.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Dark.line))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                SourceButton(title: tr("Из буфера"), icon: "doc.on.clipboard") {
                    text = NSPasteboard.general.string(forType: .string) ?? text
                }
                SourceButton(title: tr("QR с экрана"), icon: "qrcode.viewfinder") { run { await m.importQR(QR.scanScreen()) } }
                SourceButton(title: tr("QR-картинка"), icon: "photo") { pickFile(images: true) }
                SourceButton(title: tr("Файл"), icon: "doc") { pickFile(images: false) }
            }
            HStack(spacing: 10) {
                Button { close() } label: {
                    Text(tr("Отмена"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Dark.text2)
                        .frame(maxWidth: .infinity).frame(height: 36)
                        .background(Capsule().fill(Dark.card))
                        .overlay(Capsule().strokeBorder(Dark.line))
                }
                .buttonStyle(.plain)
                .modifier(HoverHighlight())
                Button { let t = text; run { await m.importText(t) } } label: {
                    HStack(spacing: 7) {
                        if working { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "plus").font(.system(size: 11, weight: .bold)) }
                        Text(tr("Добавить"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(canAdd ? Dark.bg : Dark.text2)
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(Capsule().fill(canAdd ? Palette.on : Dark.card))
                    .overlay(Capsule().strokeBorder(canAdd ? Color.clear : Dark.line))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Dark.bg)
        .preferredColorScheme(.dark)
        .onAppear {
            // Если в буфере уже ссылка — подставляем сразу.
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               s.hasPrefix("http") || s.contains("://") { text = s }
        }
    }

    func run(_ work: @escaping () async -> Void) {
        working = true
        Task { await work(); working = false; MainWindowSizer.show(m, .servers) }
    }

    func close() {
        if m.sidePanel == .add { MainWindowSizer.toggle(m, .add) }
    }

    func pickFile(images: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        if images { p.allowedContentTypes = [.image] }
        guard p.runModal() == .OK else { return }
        let urls = p.urls
        run {
            for url in urls {
                let qr = QR.decode(file: url)
                if !qr.isEmpty { await m.importQR(qr); continue }
                guard let t = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if url.pathExtension.lowercased() == "conf",
                   let s = try? LinkParser.parseWireGuardConf(t, name: url.deletingPathExtension().lastPathComponent) {
                    m.servers.append(s); m.message = tr("Добавлен WireGuard «\(s.name)»")
                } else { await m.importText(t) }
            }
        }
    }
}

struct SourceButton: View {
    let title: String; let icon: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Dark.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Dark.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let tutunShowAdd = Notification.Name("tutunShowAdd")
    static let tutunShowSettingsPane = Notification.Name("tutunShowSettingsPane")
}
