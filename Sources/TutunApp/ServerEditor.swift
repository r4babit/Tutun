import SwiftUI
import AppKit
import TutunCore

struct QRItem: Identifiable { let id = UUID(); let title: String; let text: String }
struct EditTarget: Identifiable { let id = UUID(); let server: Server? }

// MARK: - Редактор сервера

struct ServerEditor: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) private var dismiss
    let original: Server?
    @State private var name = ""
    @State private var link = ""
    @State private var json = ""
    @State private var useJSON = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(original == nil ? tr("Новый сервер") : tr("Сервер «\(m.displayName(original!))»")).font(.headline)
            if original?.subscriptionID != nil {
                Text(tr("Сервер из подписки: изменения сохранятся как отдельный сервер, а переименование — для этого же."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField(tr("Название"), text: $name).textFieldStyle(.roundedBorder)
            Picker("", selection: $useJSON) { Text(tr("Ссылка")).tag(false); Text("JSON (outbound xray / sing-box)").tag(true) }
                .pickerStyle(.segmented)
            if useJSON {
                TextEditor(text: $json).font(.caption.monospaced()).frame(height: 300)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            } else {
                TextEditor(text: $link).font(.callout.monospaced()).frame(height: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("vless:// vmess:// trojan:// ss:// hysteria2:// tuic:// wireguard:// socks://").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(tr("Отмена")) { dismiss() }
                Button(tr("Сохранить")) { save() }
                    .buttonStyle(TutunButtonStyle(primary: true))
            }
        }
        .padding()
        .frame(width: 620)
        .background(Dark.bg)
        .preferredColorScheme(.dark)
        .buttonStyle(TutunButtonStyle())
        .onAppear {
            if let o = original {
                name = m.displayName(o); link = o.rawLink ?? ""
                json = LinkParser.toJSON(o.outbound, pretty: true); useJSON = o.rawLink == nil
            }
        }
    }

    func save() {
        // Только переименование сервера из подписки.
        if let o = original, (useJSON ? json == LinkParser.toJSON(o.outbound, pretty: true) : link == (o.rawLink ?? "")) {
            m.rename(o, to: name); dismiss(); return
        }
        do {
            try m.saveEdited(original: original, link: useJSON ? nil : link, json: useJSON ? json : nil, name: name)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct QRSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String; let text: String
    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            if let img = QR.image(text) { Image(nsImage: img).interpolation(.none).resizable().frame(width: 260, height: 260) }
            else { Text(tr("Слишком длинно для QR-кода")).foregroundStyle(.secondary) }
            Text(tr("Отсканируйте телефоном (Happ, INCY, v2RayTun и др.)")).font(.caption).foregroundStyle(.secondary)
            Button(tr("Закрыть")) { dismiss() }
        }.padding(20)
            .background(Dark.bg)
            .preferredColorScheme(.dark)
            .buttonStyle(TutunButtonStyle())
    }
}
