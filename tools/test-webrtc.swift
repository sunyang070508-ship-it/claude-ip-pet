import AppKit
import Foundation

@main struct WebRTCChecks {
    @MainActor static func main() async throws {
        let reference = "203.0.113.10"
        let cases: [(String, [String], String?, WebRTCUDPStatus.Kind, String?)] = [
            ("empty", [], reference, .disabled, nil),
            ("private", ["192.168.1.1", "10.0.0.2", "172.19.0.1"], reference, .noPublic, nil),
            ("source-filter", ["172.9.1.1", "198.18.1.1", "198.19.1.1", "100.64.1.1", "127.0.0.1", "0.0.0.0"], reference, .noPublic, nil),
            ("IPv6", ["2001:db8::1"], reference, .noPublic, nil),
            ("same-exit", [reference], reference, .ok, reference),
            ("different-exit", ["198.51.100.25"], reference, .leak, "198.51.100.25"),
            ("any-different", [reference, "198.51.100.25"], reference, .leak, "198.51.100.25"),
            ("duplicate", [reference, reference], reference, .ok, reference),
            ("no-reference", [reference], nil, .ok, reference),
            ("empty-reference", [reference], "", .ok, reference)
        ]
        for (name, candidates, exit, kind, shown) in cases {
            let result = WebRTCUDPStatus.classify(candidates: candidates, claudeIP: exit)
            precondition(result.kind == kind && result.exitIP == shown, name)
        }
        var legacy = WidgetData.sample; legacy.udp = nil
        let legacyJSON = try JSONEncoder().encode(legacy)
        precondition(!String(decoding: legacyJSON, as: UTF8.self).contains("\"udp\""))
        let decoded = try JSONDecoder().decode(WidgetData.self, from: legacyJSON)
        precondition(decoded.udp == nil && decoded.trustScore == legacy.trustScore && decoded.dns.state == legacy.dns.state)
        for kind in [WebRTCUDPStatus.Kind.disabled, .noPublic, .ok, .leak, .unavailable] {
            var fixture = legacy; fixture.udp = WebRTCUDPStatus(kind: kind, exitIP: reference)
            let roundTrip = try JSONDecoder().decode(WidgetData.self, from: JSONEncoder().encode(fixture))
            precondition(roundTrip.udp == fixture.udp && roundTrip.trustScore == legacy.trustScore)
        }
        print("PASS 10 source-rule cases, legacy cache decoding, five status round trips and unchanged trust score")
        if CommandLine.arguments.contains("--live") {
            _ = NSApplication.shared
            let start = Date()
            let result = await WebRTCUDPProbe.measure(claudeIP: reference)
            precondition(Date().timeIntervalSince(start) < 10)
            print("LIVE WebKit kind=\(result.kind.rawValue), UDP exit observed=\(result.exitIP != nil), elapsed=\(Date().timeIntervalSince(start))s")
        }
    }
}
