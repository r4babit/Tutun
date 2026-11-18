import notify
import Foundation
import TutunCore
import TutunSystem

// tutund — служба с правами root. Запускается launchd (KeepAlive), держит VPN независимо от окна приложения.
// Принимает команды по unix-сокету /var/run/tutun.sock только от владельца установки и root.

setvbuf(stdout, nil, _IOLBF, 0)
guard getuid() == 0 else {
    FileHandle.standardError.write(Data("tutund должен работать от root (через launchd)\n".utf8))
    exit(1)
}
signal(SIGPIPE, SIG_IGN)

// Для uninstall.sh: вернуть прокси и DNS мака, если служба не успела сделать это сама.
if CommandLine.arguments.contains("--restore-network") {
    var code: Int32 = 0
    do { try SystemProxyManager().restore() } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); code = 1 }
    do { try SystemDNSManager().restore() } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); code = 1 }
    exit(code)
}

let supervisor = Supervisor()
guard let ownerText = try? String(contentsOfFile: Paths.installDir + "/owner.uid", encoding: .utf8),
      let ownerUID = uid_t(ownerText.trimmingCharacters(in: .whitespacesAndNewlines)), ownerUID > 0 else {
    FileHandle.standardError.write(Data("Нет владельца установки. Переустановите службу через Tutun.\n".utf8))
    exit(1)
}
Log.secureFiles()
supervisor.boot()
supervisor.observeEnvironment()

func serve() {
    unlink(Paths.socket)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { Log.write("socket() не удался"); exit(1) }
    var addr = IPC.sockaddrUn(Paths.socket)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { Log.write("bind() не удался: \(errno)"); exit(1) }
    chown(Paths.socket, ownerUID, 0)
    chmod(Paths.socket, 0o600)
    listen(fd, 16)
    notify_post(DaemonStatus.statusChangedNotification)

    while true {
        let c = accept(fd, nil, nil)
        if c < 0 { continue }
        var peerUID: uid_t = 0, peerGID: gid_t = 0
        guard getpeereid(c, &peerUID, &peerGID) == 0, peerUID == ownerUID || peerUID == 0 else {
            close(c); continue
        }
        DispatchQueue.global().async {
            defer { close(c) }
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var resp: DaemonStatus
            do {
                let line = try IPC.readLine(c)
                let req = try JSONDecoder.tunnel.decode(DaemonRequest.self, from: line)
                resp = supervisor.handle(req)
            } catch {
                resp = DaemonStatus(); resp.ok = false; resp.error = "Неверный запрос: \(error.localizedDescription)"
            }
            if var data = try? JSONEncoder.tunnel.encode(resp) {
                data.append(0x0A)
                try? IPC.writeAll(c, data)
            }
        }
    }
}

for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        supervisor.shutdown()   // подключение восстановится при следующем запуске службы
        unlink(Paths.socket)
        notify_post(DaemonStatus.statusChangedNotification)
        exit(0)
    }
    src.resume()
    _ = Unmanaged.passRetained(src)
}

Thread { serve() }.start()
dispatchMain()
