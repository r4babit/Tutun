import Darwin
import Foundation
import SystemConfiguration

/// Временный DNS для двух проверок macOS во время восстановления маршрута.
/// Сокет слушает только loopback. Регистрация исчезает при закрытии сессии configd.
public final class ConnectivityCheckDNS {
    static let domains = ["captive.apple.com", "netcts.cdn-apple.com"]
    private let key = "State:/Network/Service/TutunConnectivityCheck/DNS" as CFString
    private var store: SCDynamicStore?
    private var source: DispatchSourceRead?

    public init() {}

    public func stop() {
        if let store { SCDynamicStoreRemoveValue(store, key) }
        store = nil
        source?.cancel()
        source = nil
    }

    public func start() throws {
        guard source == nil else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.ENOBUFS) }
        var ownsSocket = true
        defer { if ownsSocket { close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(address.sin_len)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        let configuration: [String: Any] = [
            "ServerAddresses": ["127.0.0.1"], "ServerPort": Int(UInt16(bigEndian: address.sin_port)),
            "SupplementalMatchDomains": Self.domains, "SupplementalMatchDomainsNoSearch": 1,
        ]
        guard let session = SCDynamicStoreCreate(nil, "TutunConnectivityCheck" as CFString, nil, nil),
              SCDynamicStoreAddTemporaryValue(session, key, configuration as CFDictionary) else {
            throw NSError(domain: "SystemConfiguration", code: Int(SCError()))
        }
        store = session
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "tutund.connectivity-dns"))
        reader.setEventHandler { Self.receive(fd) }
        reader.setCancelHandler { close(fd) }
        ownsSocket = false
        source = reader
        reader.resume()
    }

    private static func receive(_ fd: Int32) {
        var peer = sockaddr()
        var size = socklen_t(MemoryLayout<sockaddr>.size)
        var packet = [UInt8](repeating: 0, count: 1232)
        let count = recvfrom(fd, &packet, packet.count, 0, &peer, &size)
        guard count > 0, let answer = response(Array(packet.prefix(count))) else { return }
        _ = answer.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, &peer, size) }
    }

    static func response(_ packet: [UInt8]) -> [UInt8]? {
        guard packet.count >= 17, packet[2] & 0xf8 == 0, packet[4...5].elementsEqual([0, 1]) else { return nil }
        var fields: [String] = []
        var offset = 12
        while offset < packet.count && packet[offset] != 0 {
            let count = Int(packet[offset])
            offset += 1
            guard count <= 63, offset + count < packet.count, offset + count <= 267,
                  let field = String(bytes: packet[offset..<offset+count], encoding: .ascii),
                  !field.contains(".") else { return nil }
            fields.append(field.lowercased())
            offset += count
        }
        guard domains.contains(fields.joined(separator: ".")), offset + 5 <= packet.count,
              packet[offset+3...offset+4].elementsEqual([0, 1]) else { return nil }
        let type = Int(packet[offset+1]) * 256 + Int(packet[offset+2])
        let ip: [UInt8] = type == 1 ? [127, 0, 0, 1] : (type == 28 ? Array(repeating: 0, count: 15) + [1] : [])
        var reply: [UInt8] = [packet[0], packet[1], 0x84 | (packet[2] & 1), 0, 0, 1, 0, ip.isEmpty ? 0 : 1, 0, 0, 0, 0]
        reply += packet[12..<offset+5]
        if !ip.isEmpty { reply += [0xc0, 12, 0, UInt8(type), 0, 1, 0, 0, 0, 0, 0, UInt8(ip.count)] + ip }
        return reply
    }
}
