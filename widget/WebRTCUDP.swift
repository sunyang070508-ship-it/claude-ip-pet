import Foundation

// Matches the original Claude page's WebRTC candidate comparison. This result
// is independent of DNS and never participates in the existing trust score.
struct WebRTCUDPStatus: Codable, Equatable {
    enum Kind: String, Codable {
        case disabled, noPublic = "no-public", ok, leak, unavailable
    }

    let kind: Kind
    var exitIP: String? = nil

    var text: String {
        switch kind {
        case .disabled: return "WebRTC 已禁用或无泄露"
        case .noPublic, .ok: return "未检测到泄露"
        case .leak: return "可能泄露"
        case .unavailable: return "检测不可用"
        }
    }

    static func classify(candidates: [String], claudeIP: String?) -> Self {
        var seen = Set<String>()
        let all = candidates.filter { seen.insert($0).inserted }
        // Keep the source page's public-IPv4 filter, including its 172.* and
        // 100.64.* exclusions; do not change the site's comparison policy here.
        let excluded = ["192.168.", "10.", "172.", "198.18.", "198.19.", "100.64.", "127.", "0."]
        let publicIPs = all.filter { ip in
            ip.range(of: #"^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$"#, options: .regularExpression) != nil
                && !excluded.contains(where: { ip.hasPrefix($0) })
        }
        guard !publicIPs.isEmpty else { return Self(kind: all.isEmpty ? .disabled : .noPublic) }
        let reference = claudeIP ?? ""
        let leak = reference.isEmpty ? nil : publicIPs.first { $0 != reference }
        return Self(kind: leak == nil ? .ok : .leak,
                    exitIP: leak ?? publicIPs.first { $0 == reference } ?? publicIPs.first)
    }
}
