//
//  NetworkInfo.swift
//  Quake2TacticalWatchComputer
//
//  Best-effort discovery of this phone's LAN IPv4 address, shown on the config
//  screen so you know what to type into the Mac console:
//      set watch_host "<this phone's IP>"
//

import Foundation

enum NetworkInfo {
    /// The phone's IPv4 address on the active Wi-Fi (en0) interface, or nil.
    static func wifiIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }

            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(ptr.pointee.ifa_addr,
                                     socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            if result == 0 {
                address = String(cString: host)
            }
        }
        return address
    }
}
