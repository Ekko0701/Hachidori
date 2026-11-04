import Foundation

/// Helpers for attributing captured traffic to the device that sent it.
public enum ClientDevice {
    /// Normalises a socket peer address for display and grouping:
    /// IPv4-mapped IPv6 (`::ffff:192.168.0.4`) becomes plain IPv4.
    public static func normalize(_ address: String) -> String {
        let lowered = address.lowercased()
        if lowered.hasPrefix("::ffff:") {
            let rest = String(address.dropFirst("::ffff:".count))
            if rest.contains(".") { return rest }
        }
        return address
    }

    /// Whether the address is this machine (loopback).
    public static func isLocal(_ address: String?) -> Bool {
        guard let address else { return true }
        return address == "127.0.0.1" || address == "::1" || address.hasPrefix("127.")
    }

    public enum Kind: String, Sendable, CaseIterable {
        case iphone, ipad, android, mac, windows, unknown

        /// SF Symbol for sidebar rows.
        public var symbolName: String {
            switch self {
            case .iphone: return "iphone"
            case .ipad: return "ipad"
            case .android: return "smartphone"
            case .mac: return "laptopcomputer"
            case .windows: return "pc"
            case .unknown: return "network"
            }
        }

        public var title: String {
            switch self {
            case .iphone: return "iPhone"
            case .ipad: return "iPad"
            case .android: return "Android"
            case .mac: return "Mac"
            case .windows: return "Windows"
            case .unknown: return "Device"
            }
        }
    }

    /// Best guess at the device type from the User-Agent strings it has sent.
    /// Mobile markers win over desktop ones because iOS/Android apps often send
    /// generic CFNetwork / OkHttp agents alongside the browser-style ones.
    public static func kind(forUserAgents agents: some Sequence<String>) -> Kind {
        var seen: Set<Kind> = []
        for ua in agents {
            let lowered = ua.lowercased()
            if lowered.contains("ipad") { seen.insert(.ipad) }
            else if lowered.contains("iphone") || lowered.contains("ios/") || lowered.contains("ipod") { seen.insert(.iphone) }
            else if lowered.contains("android") || lowered.contains("okhttp") { seen.insert(.android) }
            else if lowered.contains("macintosh") || lowered.contains("mac os x") || lowered.contains("darwin") || lowered.contains("macos") { seen.insert(.mac) }
            else if lowered.contains("windows") { seen.insert(.windows) }
        }
        for candidate in [Kind.ipad, .iphone, .android, .mac, .windows] where seen.contains(candidate) {
            return candidate
        }
        return .unknown
    }
}
