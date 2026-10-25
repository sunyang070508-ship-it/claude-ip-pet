import Foundation

// 小组件共享数据：全部来自 ip.net.coffee 的公开接口（与原站一致）
struct GeoInfo: Codable {
    let country: String?
    let region: String?
    let city: String?
    let isp: String?
    let country_code: String?
}

struct RiskInfo: Codable {
    let trust_score: Int?
    let asn: Int?
    let asOrganization: String?
    let country: String?
    let countryCode: String?
    let region: String?
    let city: String?
    let timezone: String?
    let isResidential: Bool?
    let is_datacenter: Bool?
    let company_type: String?
    let company_name: String?
    let is_vpn: Bool?
    let is_proxy: Bool?
    let is_tor: Bool?
    let is_crawler: Bool?
    let is_abuser: Bool?
    let abuser_score: String?
    let datacenter_name: String?
    let rdns: String?
    let rpki_status: String?
    let asn_kind: String?
    let src: String?
}

struct ServiceStatus: Codable {
    let overall: String?
    let overall_indicator: String?
}

struct Availability: Codable {
    var claudeOK = false
    var claudeMs: Int = -1
    var anthropicOK = false
    var anthropicMs: Int = -1
}

struct DNSStatus: Codable {
    var state = "检测中"
    var exitIP: String?
    var isp: String?
    var leaked = false
}

struct HistoryEntry: Codable, Identifiable {
    var id: String { ip + "|" + String(time.timeIntervalSince1970) }
    let ip: String
    let cc: String
    let time: Date
}

struct WidgetData: Codable {
    var updatedAt = Date()
    var phase: String?
    var phaseAngle: Double?
    var claudeIP: String?
    var claudeLoc: String?
    var cfIP: String?
    var cnIP: String?
    var cnSource = "站点回显"
    var geo: [String: GeoInfo] = [:]
    var risk: RiskInfo?
    var status: ServiceStatus?
    var availability = Availability()
    var dns = DNSStatus()
    var udp: WebRTCUDPStatus?
    var history: [HistoryEntry] = []

    static let restricted: [String: String] = [
        "CN": "中国大陆", "HK": "香港", "MO": "澳门", "RU": "俄罗斯", "KP": "朝鲜",
        "IR": "伊朗", "SY": "叙利亚", "CU": "古巴", "BY": "白俄罗斯", "VE": "委内瑞拉"
    ]

    var claudeGeo: GeoInfo? { claudeIP.flatMap { geo[$0] } }
    var restrictedName: String? {
        let cc = (risk?.countryCode ?? claudeLoc ?? "").uppercased()
        return cc.isEmpty ? nil : Self.restricted[cc]
    }
    var hasClaudeIP: Bool { !(claudeIP ?? "").isEmpty }
    var trustScore: Int? {
        guard hasClaudeIP else { return nil }
        if restrictedName != nil { return 0 }
        return risk?.trust_score
    }
    var trustLabel: (text: String, color: Int) {
        guard let s = trustScore else { return ("无数据", 0x9ca3af) }
        if restrictedName != nil { return ("不可访问", 0xef4444) }
        if s >= 95 { return ("极度纯净", 0x22c55e) }
        if s >= 80 { return ("纯净", 0x22c55e) }
        if s >= 50 { return ("良好", 0x84cc16) }
        if s >= 25 { return ("中性", 0xeab308) }
        return ("可疑", 0xef4444)
    }
    var isResidential: Bool? {
        if let r = risk?.isResidential { return r }
        if let dc = risk?.is_datacenter { return !dc }
        return nil
    }
}

// 组件本地偏好：默认隐藏 IP；刷新状态与缓存
// 与宿主 App 的共享通道：宿主写扩展容器 Data/tmp，扩展内 NSHomeDirectory() 指向自己的容器
enum WidgetPrefs {
    private static let cacheKey = "widget.cachedData"
    private static let showIPKey = "widget.showIP"

    private static var sharedDir: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("tmp", isDirectory: true)
    }
    private static func readShared(_ name: String) -> String? {
        guard let s = try? String(contentsOf: sharedDir.appendingPathComponent(name), encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func writeShared(_ name: String, _ value: String) {
        try? value.write(to: sharedDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    private static func removeShared(_ name: String) {
        try? FileManager.default.removeItem(at: sharedDir.appendingPathComponent(name))
    }

    // 显示完整 IP：宿主 App 通过 claudeipet://toggleip 写共享文件
    static var showIP: Bool {
        if let v = readShared("claudeipet-showip") { return v == "1" }
        return UserDefaults.standard.bool(forKey: showIPKey)
    }
    // 宿主 App 推送的检测快照：组件优先用它，保证与面板完全一致且一次原子更新
    static func sharedData() -> WidgetData? {
        let url = sharedDir.appendingPathComponent("claudeipet-data.json")
        guard let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode(WidgetData.self, from: data) else { return nil }
        return d
    }
    static var phase: String { readShared("claudeipet-phase") ?? "" }
    static var phaseAngle: Double { Double(readShared("claudeipet-phase-angle") ?? "") ?? 0 }

    static func saveCache(_ d: WidgetData) {
        if let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }
    static func loadCache() -> WidgetData? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let d = try? JSONDecoder().decode(WidgetData.self, from: data) else { return nil }
        return d
    }
}

// 默认隐藏 IP：IPv4 只留第一段，IPv6 只留第一组
func maskedIP(_ ip: String?) -> String {
    guard let ip = ip, !ip.isEmpty, ip != "—" else { return "—" }
    if ip.contains(":") {
        let parts = ip.split(separator: ":")
        let head = parts.first.map(String.init) ?? "****"
        return head + ":****:****:****"
    }
    let parts = ip.split(separator: ".")
    if parts.count == 4 { return parts[0] + ".***.***.***" }
    return "***.***.***.***"
}

func shownIP(_ ip: String?) -> String {
    WidgetPrefs.showIP ? (ip ?? "—") : maskedIP(ip)
}

enum WidgetService {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    static func get(_ url: String, timeout: TimeInterval = 8) async -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    static func trace(_ host: String) async -> (ip: String?, loc: String?) {
        guard let text = await get("https://\(host)/cdn-cgi/trace") else { return (nil, nil) }
        var ip: String?
        var loc: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if key == "ip" { ip = val }
            if key == "loc" { loc = val.lowercased() }
        }
        return (ip, loc)
    }

    static func fetchGeo(_ ips: [String]) async -> [String: GeoInfo] {
        let list = Array(Set(ips.filter { !$0.isEmpty }))
        var out: [String: GeoInfo] = [:]
        if list.isEmpty { return out }
        if list.count >= 2, let text = await get("https://ip.net.coffee/api/geoip-batch?ips=" + list.joined(separator: ",")),
           let data = text.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: GeoInfo].self, from: data) {
            out = dict
        }
        for ip in list where out[ip] == nil {
            if let text = await get("https://ip.net.coffee/api/geoip/" + ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!),
               let data = text.data(using: .utf8),
               let g = try? JSONDecoder().decode(GeoInfo.self, from: data) {
                out[ip] = g
            }
        }
        return out
    }

    static func fetchRisk(_ ip: String) async -> RiskInfo? {
        guard let text = await get("https://ip.net.coffee/api/iprisk/" + ip.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RiskInfo.self, from: data)
    }

    static func fetchStatus() async -> ServiceStatus? {
        guard let text = await get("https://ip.net.coffee/claude/status.json", timeout: 5),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ServiceStatus.self, from: data)
    }

    // 与原站“中国出口IPv4”卡一致：站点回显（同代理路径），只取 IPv4；失败回退 ip138 / ip.cn
    static func fetchCNIP() async -> (ip: String?, source: String) {
        if let text = await get("https://ip.net.coffee/cdn-cgi/trace", timeout: 6) {
            for line in text.split(separator: "\n") where line.hasPrefix("ip=") {
                let ip = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if ip.contains(".") && !ip.contains(":") { return (ip, "站点回显") }
            }
        }
        for url in ["https://2026.ip138.com/", "https://my.ip.cn/"] {
            if let text = await get(url, timeout: 6),
               let range = text.range(of: "\\b(\\d{1,3}\\.){3}\\d{1,3}\\b", options: .regularExpression) {
                return (String(text[range]), url.contains("ip138") ? "ip138" : "ip.cn")
            }
        }
        return (nil, "ip138 / ip.cn")
    }

    static func probe(_ url: String) async -> (ok: Bool, ms: Int) {
        let start = Date()
        let text = await get(url, timeout: 6)
        return (text != nil, Int(Date().timeIntervalSince(start) * 1000))
    }

    static func fetchAvailability() async -> Availability {
        var a = Availability()
        _ = await probe("https://claude.ai/cdn-cgi/trace")
        _ = await probe("https://www.anthropic.com/cdn-cgi/trace")
        async let c = probe("https://claude.ai/cdn-cgi/trace")
        async let n = probe("https://www.anthropic.com/cdn-cgi/trace")
        let (cr, nr) = await (c, n)
        a.claudeOK = cr.ok; a.claudeMs = cr.ms
        a.anthropicOK = nr.ok; a.anthropicMs = nr.ms
        return a
    }

    // DNS 泄露：触发像素图解析 → 查询解析器出口 → GeoIP
    static func fetchDNS() async -> (servers: [String], geos: [String: GeoInfo]) {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let stamp = String(Int(Date().timeIntervalSince1970))
        async let p1: String? = get("https://\(token)-1.d.ip.net.coffee/pixel.gif?_=\(stamp)", timeout: 5)
        async let p2: String? = get("https://\(token)-2.d.ip.net.coffee/pixel.gif?_=\(stamp)", timeout: 5)
        _ = await (p1, p2)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var servers: [String] = []
        for attempt in 0..<2 {
            if let text = await get("https://ip.net.coffee/api/dns/result/\(token)", timeout: 5),
               let data = text.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = obj["dns_servers"] as? [String] {
                servers = arr
                if !arr.isEmpty { break }
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        let geos = servers.isEmpty ? [:] : await fetchGeo(servers)
        return (servers, geos)
    }

    static func makeDNS(servers: [String], geos: [String: GeoInfo], claudeCountry: String) -> DNSStatus {
        var d = DNSStatus()
        guard !servers.isEmpty else {
            d.state = "DNS 加密或未暴露出口"
            return d
        }
        let claudeInChina = claudeCountry.lowercased().contains("china") || claudeCountry.contains("中国")
        var show: (String, GeoInfo)?
        for ip in servers {
            let g = geos[ip]
            let cc = (g?.country_code ?? "").lowercased()
            if cc == "cn" && !claudeInChina {
                d.state = "可能泄露"
                d.leaked = true
                d.exitIP = ip
                d.isp = g?.isp
                return d
            }
            if show == nil { show = (ip, g ?? GeoInfo(country: nil, region: nil, city: nil, isp: nil, country_code: nil)) }
        }
        d.state = "未检测到泄露"
        d.exitIP = show?.0
        d.isp = show?.1.isp
        return d
    }

    // 小组件本地历史（扩展自己的 UserDefaults，规则同原站：最多 6 条、24h 去重）
    private static let historyKey = "widget.claude_history.v1"

    static func loadHistory() -> [HistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let arr = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return arr
    }

    static func saveHistory(_ entries: [HistoryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    static func updatedHistory(current: HistoryEntry?) -> [HistoryEntry] {
        var list = loadHistory()
        if let cur = current {
            if let last = list.first, last.ip == cur.ip, Date().timeIntervalSince(last.time) < 86_400 {
                // 同 IP 24h 内不重复记录
            } else {
                list.insert(cur, at: 0)
                if list.count > 6 { list = Array(list.prefix(6)) }
            }
        }
        saveHistory(list)
        return list
    }

    static func fetchAll() async -> WidgetData {
        var d = WidgetData()
        async let claudeT = trace("claude.ai")
        async let cfT = trace("1.1.1.1")
        async let cn = fetchCNIP()
        let (cl, cf, cnr) = await (claudeT, cfT, cn)
        d.claudeIP = cl.ip
        d.claudeLoc = cl.loc
        d.cfIP = cf.ip
        d.cnIP = cnr.ip
        d.cnSource = cnr.source

        guard let cip = d.claudeIP, !cip.isEmpty else {
            d.updatedAt = Date()
            return d
        }
        let ips = [d.cnIP, d.cfIP, d.claudeIP].compactMap { $0 }
        async let riskT = fetchRisk(cip)
        async let statusT = fetchStatus()
        async let availT = fetchAvailability()
        async let geoT = fetchGeo(ips)
        async let dnsT = fetchDNS()
        async let udpT = WebRTCUDPProbe.measure(claudeIP: cip)

        d.risk = await riskT
        d.status = await statusT
        d.availability = await availT
        d.geo = await geoT
        let dns = await dnsT
        d.dns = makeDNS(servers: dns.servers, geos: dns.geos,
                        claudeCountry: d.risk?.country ?? d.geo[cip]?.country ?? "")
        d.udp = await udpT
        let entry = HistoryEntry(ip: cip,
                                 cc: (d.risk?.countryCode ?? d.claudeLoc ?? "").lowercased(),
                                 time: Date())
        d.history = updatedHistory(current: entry)
        d.updatedAt = Date()
        WidgetPrefs.saveCache(d)
        return d
    }
}
