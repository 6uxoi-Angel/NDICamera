import Foundation
import Darwin

/// Локальный сетевой интерфейс iPhone (Wi-Fi, USB-тетеринг, сотовые данные).
struct LocalInterface: Identifiable, Equatable {
    let name: String
    let ip: String

    var id: String { "\(name)|\(ip)" }

    /// Человекочитаемая подпись для настроек
    var label: String {
        if name == "en0" { return "Wi-Fi (\(ip))" }
        if name.hasPrefix("en") { return "USB/провод (\(ip))" }
        if name.hasPrefix("pdp") { return "Сотовые данные (\(ip))" }
        return "\(name) (\(ip))"
    }

    /// USB-тетеринг (Lightning/USB-C) обычно поднимается как en1/en4/en5...
    var isUSB: Bool { name.hasPrefix("en") && name != "en0" }
}

enum NetworkInterfaces {
    /// Активные IPv4-интерфейсы. Сортировка: Wi-Fi, затем USB, затем остальное.
    static func all() -> [LocalInterface] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var out: [LocalInterface] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr,
               sa.pointee.sa_family == sa_family_t(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count))
                let host = String(cString: buf)
                if !host.isEmpty {
                    out.append(LocalInterface(name: name, ip: host))
                }
            }
            ptr = ifa.ifa_next
        }

        return out.sorted { a, b in
            let rankA = a.name == "en0" ? 0 : (a.isUSB ? 1 : 2)
            let rankB = b.name == "en0" ? 0 : (b.isUSB ? 1 : 2)
            return rankA == rankB ? a.name < b.name : rankA < rankB
        }
    }
}
