import Foundation
import TutunShared

/// Обмен с службой через unix-сокет: одна строка JSON туда, одна обратно.
public enum IPC {
    public enum Failure: Error, LocalizedError {
        case notRunning, io(String)
        public var errorDescription: String? {
            switch self {
            case .notRunning: return tr("Служба Tutun не запущена")
            case .io(let s): return tr("Ошибка связи со службой: \(s)")
            }
        }
    }

    public static func send(_ request: DaemonRequest, socketPath: String = Paths.socket, timeout: TimeInterval = 30) throws -> DaemonStatus {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io("socket") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddrUn(socketPath)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw Failure.notRunning }
        var payload = try JSONEncoder.tunnel.encode(request)
        payload.append(0x0A)
        try writeAll(fd, payload)
        let line = try readLine(fd)
        return try JSONDecoder.tunnel.decode(DaemonStatus.self, from: line)
    }

    public static func sockaddrUn(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { throw Failure.io("write") }
                off += n
            }
        }
    }

    public static func readLine(_ fd: Int32, limit: Int = 8 << 20) throws -> Data {
        var out = Data()
        var byte = [UInt8](repeating: 0, count: 65536)
        while out.count < limit {
            let n = read(fd, &byte, byte.count)
            if n < 0 { throw Failure.io("read") }
            if n == 0 { break }
            out.append(contentsOf: byte[0..<n])
            if let nl = out.firstIndex(of: 0x0A) { return out.prefix(upTo: nl) }
        }
        if out.isEmpty { throw Failure.io(tr("пустой ответ")) }
        return out
    }
}
