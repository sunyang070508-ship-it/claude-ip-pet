import SwiftUI
import WidgetKit

struct PulseKey: EnvironmentKey { static let defaultValue: Double = 0 }
struct PhaseKey: EnvironmentKey { static let defaultValue: String = "" }
struct PreviewKey: EnvironmentKey { static let defaultValue: Bool = false }
extension EnvironmentValues {
    var widgetPulse: Double {
        get { self[PulseKey.self] }
        set { self[PulseKey.self] = newValue }
    }
    var widgetPhase: String {
        get { self[PhaseKey.self] }
        set { self[PhaseKey.self] = newValue }
    }
    var widgetPreview: Bool {
        get { self[PreviewKey.self] }
        set { self[PreviewKey.self] = newValue }
    }
}

let accent = Color(red: 0.80, green: 0.47, blue: 0.36)
let safeColor = Color(red: 0.20, green: 0.83, blue: 0.60)
let warnColor = Color(red: 0.98, green: 0.75, blue: 0.14)
let dangerColor = Color(red: 0.97, green: 0.44, blue: 0.44)
let infoColor = Color(red: 0.49, green: 0.83, blue: 0.99)

enum Level {
    case safe, warn, danger, neutral
    var color: Color {
        switch self {
        case .safe: return safeColor
        case .warn: return warnColor
        case .danger: return dangerColor
        case .neutral: return Color.white.opacity(0.85)
        }
    }
    var icon: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .danger: return "xmark.octagon.fill"
        case .neutral: return "circle.fill"
        }
    }
}

func flag(_ cc: String?) -> String {
    guard let c = cc?.lowercased(), c.count == 2,
          c.unicodeScalars.allSatisfy({ $0.value >= 97 && $0.value <= 122 }) else { return "" }
    let base: UInt32 = 0x1F1E6
    let a = base + UInt32(c.unicodeScalars.first!.value - 97)
    let b = base + UInt32(c.unicodeScalars.last!.value - 97)
    return String(UnicodeScalar(a)!) + String(UnicodeScalar(b)!)
}

func timeText(_ date: Date, short: Bool = true) -> String {
    let f = DateFormatter()
    f.dateFormat = short ? "HH:mm" : "MM-dd HH:mm"
    return f.string(from: date)
}

func scoreColor(_ d: WidgetData) -> Color {
    guard let s = d.trustScore else { return .gray }
    if d.restrictedName != nil { return dangerColor }
    if s >= 80 { return safeColor }
    if s >= 50 { return infoColor }
    if s >= 25 { return warnColor }
    return dangerColor
}

func scoreValue(_ d: WidgetData) -> String { d.trustScore.map(String.init) ?? "—" }

func countryLine(_ d: WidgetData, _ ip: String?) -> String {
    guard let ip = ip, let g = d.geo[ip] else {
        if ip == d.claudeIP, let loc = d.claudeLoc { return loc.uppercased() }
        return ""
    }
    let parts = WidgetPrefs.showIP ? [g.country, g.city] : [g.country]
    return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

// 出口 IP 是否有问题：失败 / 非 IPv4（IPv4 卡）/ 受限 / VPN·代理·Tor·滥用 / 低信任分 → 红
func ipLevel(_ d: WidgetData, ip: String?, isClaude: Bool) -> Level {
    guard let ip = ip, !ip.isEmpty else { return .danger }
    if isClaude {
        if d.restrictedName != nil { return .danger }
        if d.risk?.is_vpn == true || d.risk?.is_proxy == true || d.risk?.is_tor == true ||
           d.risk?.is_abuser == true || d.risk?.is_crawler == true { return .danger }
        if let s = d.trustScore, s < 50 { return .danger }
    }
    // 出口 IP 出现中国 IP → 红色
    let geo = d.geo[ip]
    let cc = (geo?.country_code ?? "").lowercased()
    let country = (geo?.country ?? "").lowercased()
    if cc == "cn" || country.contains("china") || country.contains("中国") { return .danger }
    return isClaude ? .safe : (ip.contains(":") ? .danger : .safe)
}

// DNS 状态：中国 DNS / 泄露 / 无法确认 → 红
func dnsLevel(_ d: WidgetData) -> Level {
    if d.dns.leaked { return .danger }
    if d.dns.state.contains("加密") || d.dns.state.contains("未暴露") { return .danger }
    return .safe
}

func udpLevel(_ d: WidgetData) -> Level {
    switch d.udp?.kind {
    case .leak: return .warn
    case .ok, .noPublic, .disabled: return .safe
    case .unavailable, nil: return .neutral
    }
}

// 分数 ≤ 40：可用性 / 服务板块数据全部显示红色横杠
func isLowScore(_ d: WidgetData) -> Bool {
    guard let s = d.trustScore else { return false }
    return s <= 40
}

func utcOffsetText(_ tz: TimeZone?) -> String {
    guard let tz = tz else { return "—" }
    let mins = tz.secondsFromGMT() / 60
    let sign = mins >= 0 ? "+" : "-"
    let absMins = abs(mins)
    return "UTC" + sign + String(absMins / 60) + (absMins % 60 == 0 ? "" : ":" + String(format: "%02d", absMins % 60))
}

func timezoneMatch(_ d: WidgetData) -> String {
    guard let tzid = d.risk?.timezone, let tz = TimeZone(identifier: tzid) else { return "未知" }
    return abs(tz.secondsFromGMT() - TimeZone.current.secondsFromGMT()) <= 3600 ? "一致" : "不一致"
}

func systemVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "macOS \(v.majorVersion).\(v.minorVersion)"
}

// 风险总览：红=警告 / 黄=风险大 / 绿=正常
func overallStatus(_ d: WidgetData) -> (Level, String) {
    if let rn = d.restrictedName { return (.danger, "⚠ 受限地区 \(rn) · Claude 会严格风控") }
    if d.risk?.is_vpn == true || d.risk?.is_proxy == true || d.risk?.is_tor == true {
        return (.danger, "⚠ 检测到 VPN / 代理 / Tor")
    }
    if d.dns.leaked { return (.danger, "⚠ DNS 可能泄露") }
    if d.isResidential == false { return (.warn, "⚠ 机房 IP · 被风控概率更高") }
    if let s = d.trustScore, s < 50 { return (.warn, "⚠ IP 风险偏高（\(s) 分）") }
    return (.safe, "✓ 住宅 IP · 未检测到风险")
}

func latencyLevel(_ ms: Int, ok: Bool) -> Level {
    guard ok else { return .danger }
    return ms < 500 ? .safe : .warn
}

func residentialLevel(_ d: WidgetData) -> Level {
    if d.isResidential == true { return .safe }
    if d.isResidential == false { return .warn }
    return .neutral
}

func residentialText(_ d: WidgetData) -> String {
    if d.isResidential == true { return "住宅" }
    if d.isResidential == false { return "机房" }
    return "—"
}

// MARK: - 深链按钮（点击打开宿主 App 执行，避免 AppIntents 元数据依赖）
struct IPVisibilityButton: View {
    @Environment(\.widgetPreview) private var preview
    var body: some View {
        Group {
            if preview { label }
            else { Link(destination: URL(string: "claudeipwidget://toggleip")!) { label } }
        }
        .accessibilityLabel(WidgetPrefs.showIP ? "隐藏 IP" : "显示 IP")
    }
    private var label: some View {
        WidgetControlGlyph(state: .help, angle: 0)
            .frame(width: 12, height: 12)
            .padding(.horizontal, 2).padding(.vertical, 3)
    }
}

struct RefreshButton: View {
    var compact = false
    var failed = false
    @Environment(\.widgetPreview) private var preview
    @Environment(\.widgetPhase) private var phase
    @Environment(\.widgetPulse) private var pulse
    var body: some View {
        Group {
            if preview { label }
            else { Link(destination: URL(string: "claudeipwidget://refresh")!) { label } }
        }.accessibilityLabel(phase == "loading" ? "等待检测结果" : failed ? "检测失败，点击重试" : "重新检测")
            .disabled(phase == "loading")
    }
    private var label: some View {
        WidgetControlGlyph(state: phase == "loading" ? .loading : failed ? .failed : .ready, angle: pulse)
        .frame(width: compact ? 17 : 23, height: compact ? 10 : 14)
        .foregroundColor(GlassPalette.white)
        .padding(.horizontal, compact ? 4 : 6).padding(.vertical, 3)
        .background(infoColor.opacity(0.24)).clipShape(Capsule())
    }
}

// MARK: - 通用小组件
struct HeaderRow: View {
    let d: WidgetData
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Text("Claude IP 检测")
                .font(.system(size: compact ? 9 : 9.5, weight: .semibold))
                .foregroundColor(GlassPalette.white)
                .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
            IPVisibilityButton()
            Spacer(minLength: 2)
            let fresh = Date().timeIntervalSince(d.updatedAt) < 120
            Text((fresh ? "✓ " : "") + timeText(d.updatedAt))
                .font(.system(size: 8)).foregroundColor(fresh ? GlassPalette.semantic(safeColor) : GlassPalette.muted)
                .lineLimit(1).fixedSize()
        }
    }
}

struct RiskBanner: View {
    let d: WidgetData
    var body: some View {
        let status = overallStatus(d)
        HStack(spacing: 3) {
            Image(systemName: status.0.icon).font(.system(size: 8.5))
            Text(status.1).font(.system(size: 8, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .foregroundColor(GlassPalette.semantic(status.0.color))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(status.0.color.opacity(0.14))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.40), Color.white.opacity(0.06), status.0.color.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.7
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// Solid light card surface; no wallpaper material.
struct GlassCardBackground: View {
    var corner: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: [.white, Color(red: 0.91, green: 0.95, blue: 0.99)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(GlassPalette.blue.opacity(0.18), lineWidth: 0.9)
            }
    }
}

// 小卡片容器
struct CardBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.widgetPulse) private var pulse
    @Environment(\.widgetPhase) private var phase

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 8, weight: .semibold)).foregroundColor(GlassPalette.muted)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(6.5)
        .background(GlassCardBackground(corner: 10))
        .overlay {
            if phase == "loading" {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: infoColor.opacity(0.95), location: 0.02),
                                .init(color: accent.opacity(0.98), location: 0.16),
                                .init(color: .clear, location: 0.22),
                                .init(color: .clear, location: 1.0)
                            ],
                            center: .center,
                            angle: .degrees(pulse + Double(title.count) * 37)
                        ),
                        lineWidth: 2.0
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct KV: View {
    let k: String
    let v: String
    var level: Level = .neutral
    var mono = false
    var body: some View {
        HStack(spacing: 2) {
            Text(k).font(.system(size: 7.5)).foregroundColor(GlassPalette.muted).lineLimit(1)
            Spacer(minLength: 1)
            Text(v)
                .font(.system(size: 8.5, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundColor(GlassPalette.semantic(level.color))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

struct StatusTag: View {
    let text: String
    var level: Level = .neutral
    var body: some View {
        Text(text)
            .font(.system(size: 7, weight: .semibold))
            .foregroundColor(GlassPalette.semantic(level.color))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(level.color.opacity(0.16))
            .clipShape(Capsule())
            .lineLimit(1).minimumScaleFactor(0.7)
    }
}

struct GaugeBar: View {
    let score: Int?
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [dangerColor, warnColor, Color(red: 0.64, green: 0.90, blue: 0.21), safeColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: height)
                if let s = score {
                    Capsule().fill(GlassPalette.scoreMarker)
                        .frame(width: 2, height: height + 4)
                        .offset(x: max(0, min(geo.size.width - 2, geo.size.width * CGFloat(min(max(s, 0), 100)) / 100.0)))
                }
            }
        }
        .frame(height: height + 4)
    }
}

func placeLine(_ d: WidgetData) -> String {
    let country = d.claudeGeo?.country ?? d.risk?.country ?? "—"
    guard WidgetPrefs.showIP else { return country + " · (已隐藏)" }
    let city = d.claudeGeo?.city ?? d.risk?.city ?? ""
    return city.isEmpty ? country : country + " · " + city
}

// MARK: - 小号
// Loading has no cached-data input, so previous values cannot leak into it.
struct PendingCompactWidgetView: View {
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 4) {
                Text("IP 可信度评分").font(.system(size: compact ? 10 : 12, weight: .semibold))
                Spacer(minLength: 0)
                IPVisibilityButton()
                RefreshButton(compact: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("—").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("/100").font(.system(size: 8))
                Spacer(minLength: 0)
                Text("检测中").font(.system(size: 10, weight: .medium))
            }.foregroundColor(GlassPalette.blue)
            Capsule().fill(GlassPalette.blue.opacity(0.15)).frame(height: 5)
            HStack(spacing: 10) {
                ForEach(0..<(compact ? 1 : 3), id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("检测中").font(.system(size: 9))
                        Capsule().fill(GlassPalette.blue.opacity(0.10)).frame(height: 5)
                        Capsule().fill(GlassPalette.blue.opacity(0.07)).frame(height: 5)
                    }.frame(maxWidth: .infinity)
                }
            }.foregroundColor(GlassPalette.blue.opacity(0.65))
            Spacer(minLength: 0)
        }.foregroundColor(GlassPalette.white)
            .environment(\.widgetPhase, "loading")
            .disabled(true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("所有检测数据检测中")
    }
}

struct SmallView: View {
    let d: WidgetData
    var body: some View {
        if d.phase == "loading" {
            PendingCompactWidgetView(compact: true)
        } else if !d.hasClaudeIP {
            VStack(spacing: 5) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 18)).foregroundColor(GlassPalette.muted)
                Text("等待检测数据").font(.system(size: 10)).foregroundColor(GlassPalette.muted)
                RefreshButton(failed: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HeaderRow(d: d, compact: true)
                Spacer(minLength: 1)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(scoreValue(d))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(GlassPalette.semantic(scoreColor(d)))
                    Text("/100").font(.system(size: 7.5)).foregroundColor(GlassPalette.muted)
                    Spacer(minLength: 1)
                    StatusTag(text: d.trustLabel.text, level: (d.trustScore ?? 0) >= 80 ? .safe : (d.trustScore ?? 0) >= 25 ? .warn : .danger)
                    RefreshButton(compact: true)
                }
                GaugeBar(score: d.trustScore, height: 5)
                Text(d.trustLabel.text == "纯净" ? "该 IP 信誉优异" : "该 IP 存在风险")
                    .font(.system(size: 8)).foregroundColor(GlassPalette.semantic(scoreColor(d))).lineLimit(1)
                Spacer(minLength: 1)
                HStack(spacing: 3) {
                    Text(flag(d.claudeGeo?.country_code ?? d.claudeLoc)).font(.system(size: 10))
                    Text(shownIP(d.claudeIP))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(GlassPalette.semantic(ipLevel(d, ip: d.claudeIP, isClaude: true).color))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                HStack(spacing: 4) {
                    Text(countryLine(d, d.claudeIP)).font(.system(size: 8)).foregroundColor(GlassPalette.muted).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - 中号：三列 + 彩色状态
struct MediumView: View {
    let d: WidgetData
    var body: some View {
        if d.phase == "loading" {
            PendingCompactWidgetView()
        } else if !d.hasClaudeIP {
            VStack(spacing: 5) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 18)).foregroundColor(GlassPalette.muted)
                Text("等待检测数据").font(.system(size: 10)).foregroundColor(GlassPalette.muted)
                RefreshButton(failed: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HeaderRow(d: d, compact: true)
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(scoreValue(d))
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.65)
                                .foregroundColor(GlassPalette.semantic(scoreColor(d)))
                            Text("/100").font(.system(size: 7)).foregroundColor(GlassPalette.muted)
                            Spacer(minLength: 1)
                            StatusTag(text: d.trustLabel.text, level: (d.trustScore ?? 0) >= 80 ? .safe : (d.trustScore ?? 0) >= 25 ? .warn : .danger)
                            RefreshButton(compact: true)
                        }
                        GaugeBar(score: d.trustScore, height: 5)
                        Text(d.trustScore ?? 0 >= 80 ? "该 IP 信誉优异" : "该 IP 存在风险")
                            .font(.system(size: 7.5)).foregroundColor(GlassPalette.semantic(scoreColor(d))).lineLimit(1)
                        Spacer(minLength: 0)
                        KV(k: "支持地区", v: d.restrictedName == nil ? "正常" : "受限", level: d.restrictedName == nil ? .safe : .danger)
                        KV(k: "claude", v: d.availability.claudeOK ? "\(d.availability.claudeMs)ms" : "不可访问",
                           level: latencyLevel(d.availability.claudeMs, ok: d.availability.claudeOK))
                        KV(k: "anthropic", v: d.availability.anthropicOK ? "\(d.availability.anthropicMs)ms" : "不可访问",
                           level: latencyLevel(d.availability.anthropicMs, ok: d.availability.anthropicOK))
                    }
                    .frame(width: 98)
                    Divider().overlay(GlassPalette.blue.opacity(0.12))
                    VStack(alignment: .leading, spacing: 3) {
                        mediumIP(label: "中国出口IPv4", ip: d.cnIP, cc: d.geo[d.cnIP ?? ""]?.country_code, level: ipLevel(d, ip: d.cnIP, isClaude: false))
                        mediumIP(label: "Cloudflare", ip: d.cfIP, cc: d.geo[d.cfIP ?? ""]?.country_code, level: ipLevel(d, ip: d.cfIP, isClaude: false))
                        mediumIP(label: "Claude", ip: d.claudeIP, cc: d.claudeGeo?.country_code ?? d.claudeLoc, level: ipLevel(d, ip: d.claudeIP, isClaude: true))
                        Spacer(minLength: 0)
                        KV(k: "时区", v: timezoneMatch(d) + " " + utcOffsetText(TimeZone.current),
                           level: timezoneMatch(d) == "一致" ? .safe : .warn)
                    }
                    .frame(width: 112)
                    Divider().overlay(GlassPalette.blue.opacity(0.12))
                    VStack(alignment: .leading, spacing: 2) {
                        KV(k: "地区", v: placeLine(d))
                        KV(k: "属性", v: residentialText(d) + (d.risk?.company_type.map { " (\($0))" } ?? ""), level: residentialLevel(d))
                        KV(k: "ASN", v: d.risk?.asn.map { "AS\($0)" } ?? "—")
                        KV(k: "运营商", v: d.risk?.asOrganization ?? "—")
                        KV(k: "滥用", v: d.risk?.abuser_score ?? "—", level: (d.risk?.abuser_score ?? "").contains("Low") ? .safe : .neutral)
                        KV(k: "DNS", v: d.dns.state, level: dnsLevel(d))
                        KV(k: "DNS 出口", v: shownIP(d.dns.exitIP), level: dnsLevel(d), mono: true)
                        KV(k: "Claude 服务状态", v: d.status?.overall_indicator == "none" ? "全部正常" : "异常",
                           level: d.status?.overall_indicator == "none" ? .safe : .danger)
                        KV(k: "WebRTC UDP", v: d.udp?.text ?? "待检测", level: udpLevel(d))
                    }
                }
            }
        }
    }
    private func mediumIP(label: String, ip: String?, cc: String?, level: Level) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.system(size: 6.5)).foregroundColor(GlassPalette.muted)
                .lineLimit(1).minimumScaleFactor(0.8).frame(width: 40, alignment: .leading)
            Text(flag(cc)).font(.system(size: 7))
            Text(shownIP(ip))
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(GlassPalette.semantic(level.color))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

// MARK: - 大号：小区块网格（2 列 × 3 行）
struct LargeView: View {
    let d: WidgetData
    var body: some View { LiquidGlassLargeView(d: d) }
}

func bigIPRow(label: String, ip: String?, cc: String?, geo: String, level: Level = .safe) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 2) {
            Text(flag(cc)).font(.system(size: 7.5))
            Text(label).font(.system(size: 7.5)).foregroundColor(.white.opacity(0.5))
            Spacer(minLength: 1)
            Text(shownIP(ip))
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundColor(level.color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        if !geo.isEmpty {
            Text(geo).font(.system(size: 7)).foregroundColor(.white.opacity(0.4)).lineLimit(1)
                .padding(.leading, 2)
        }
    }
}

func deviceCell(_ title: String, _ value: String, level: Level = .neutral) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 7.5)).foregroundColor(.white.opacity(0.42))
        Text(value).font(.system(size: 8.5, weight: .medium))
            .foregroundColor(level.color).lineLimit(1).minimumScaleFactor(0.6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - 检测动画 overlay
struct WidgetPhaseOverlay: View {
    let phase: String
    let angle: Double
    var body: some View {
        if phase == "loading" {
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(angle * 2))
                }
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 9).padding(.vertical, 3.5)
                .background(Color.black.opacity(0.5))
                .clipShape(Capsule())
                .padding(.bottom, 7)
            }
            .allowsHitTesting(false)
        } else if phase == "done" {
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .bold))
                    Text("数据已更新").font(.system(size: 10.5, weight: .bold))
                }
                .foregroundColor(Color(red: 0.05, green: 0.19, blue: 0.13))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(safeColor)
                .clipShape(Capsule())
                .shadow(color: safeColor.opacity(0.4), radius: 8)
                .padding(.bottom, 16)
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - 入口 / Provider
struct WidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    @Environment(\.widgetContentMargins) private var margins
    let entry: ClaudeEntry
    var body: some View {
        if family == .systemLarge {
            LargeView(d: entry.data)
                .environment(\.widgetPhase, entry.data.phase ?? "")
                .environment(\.widgetPulse, entry.data.phase == "loading" ? (entry.data.phaseAngle ?? 0) : 0)
                .containerBackground(for: .widget) { LiquidGlassWidgetBackground() }
        } else {
            standardBody
                .overlay {
                    GeometryReader { geometry in
                        let size = CGSize(width: geometry.size.width + margins.leading + margins.trailing,
                                          height: geometry.size.height + margins.top + margins.bottom)
                        let content = standardBody
                            .environment(\.widgetPreview, true)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .padding(margins)
                            .background(LiquidGlassWidgetBackground())
                            .environment(\.colorScheme, .light)
                        if #available(macOS 15.0, *), let image = GlassForegroundCache.image(key: compactCacheKey(size), size: size, content: content) {
                            // Original native content/Links remain below the color
                            // snapshot, with unchanged hit regions and accessibility.
                            Image(nsImage: image).resizable().widgetAccentedRenderingMode(.fullColor)
                                .frame(width: size.width, height: size.height)
                                .offset(x: -margins.leading, y: -margins.top)
                        }
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
                .containerBackground(for: .widget) { LiquidGlassWidgetBackground() }
        }
    }

    private func compactCacheKey(_ size: CGSize) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(entry.data)) ?? Data()
        return "light-compact-\(family)-\(bytes.hashValue)-\(WidgetPrefs.showIP)-\(size)-\(Locale.preferredLanguages)-\(TimeZone.current.identifier)-\(TimeZone.current.secondsFromGMT())"
    }

    private var standardBody: some View {
        Group {
            switch family {
            case .systemMedium: MediumView(d: entry.data)
            case .systemLarge: LargeView(d: entry.data)
            default: SmallView(d: entry.data)
            }
        }
        .environment(\.widgetPhase, entry.data.phase ?? "")
        .environment(\.widgetPulse, entry.data.phase == "loading" ? (entry.data.phaseAngle ?? 0) : 0)
        .overlay {
            if let phase = entry.data.phase, phase == "loading" || phase == "done" {
                WidgetPhaseOverlay(phase: phase, angle: entry.data.phaseAngle ?? 0)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0.08), Color.white.opacity(0.30)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
                .padding(0.5)
                .allowsHitTesting(false)
        }
    }
}

struct ClaudeEntry: TimelineEntry {
    let date: Date
    let data: WidgetData
}

extension WidgetData {
    // Synthetic preview fixtures; these addresses are never used by live requests.
    static var sample: WidgetData {
        var d = WidgetData()
        d.claudeIP = "203.0.113.10"
        d.claudeLoc = "us"
        d.cfIP = "203.0.113.10"
        d.cnIP = "203.0.113.10"
        d.risk = RiskInfo(trust_score: 86, asn: 64500, asOrganization: "Example Network",
                          country: "United States", countryCode: "us", region: "Example Region",
                          city: "Example City", timezone: "America/Los_Angeles",
                          isResidential: false, is_datacenter: true, company_type: "hosting",
                          company_name: "Example Network", is_vpn: false, is_proxy: false,
                          is_tor: false, is_crawler: false, is_abuser: false,
                          abuser_score: "0.0022 (Low)", datacenter_name: "Example Datacenter",
                          rdns: "exit.example.invalid", rpki_status: "valid",
                          asn_kind: "hosting", src: "g1")
        d.status = ServiceStatus(overall: "全部正常", overall_indicator: "none")
        d.availability = Availability(claudeOK: true, claudeMs: 210, anthropicOK: true, anthropicMs: 440)
        d.dns = DNSStatus(state: "未检测到泄露", exitIP: "198.51.100.53", isp: "Example DNS", leaked: false)
        d.udp = WebRTCUDPStatus(kind: .ok, exitIP: d.claudeIP)
        d.geo = ["203.0.113.10": GeoInfo(country: "United States", region: "Example Region",
                                          city: "Example City", isp: "Example Network", country_code: "us")]
        return d
    }
}

struct ClaudeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeEntry { ClaudeEntry(date: Date(), data: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (ClaudeEntry) -> Void) { completion(ClaudeEntry(date: Date(), data: .sample)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeEntry>) -> Void) {
        // 宿主 App 推送的快照：与面板完全一致、一次性更新；也承载检测动画阶段
        if let shared = WidgetPrefs.sharedData(),
           WidgetPrefs.phase == "loading" || WidgetPrefs.phase == "done"
            || Date().timeIntervalSince(shared.updatedAt) < 600 {
            var d = shared
            d.phase = WidgetPrefs.phase
            d.phaseAngle = WidgetPrefs.phaseAngle
            let entry = ClaudeEntry(date: Date(), data: d)
            let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
            completion(Timeline(entries: [entry], policy: .after(next)))
            return
        }
        // 每次重建时间线都重新拉取（宿主重检 / VPN 切换后立即反映真实出口）
        Task {
            let data = await WidgetService.fetchAll()
            let entry = ClaudeEntry(date: Date(), data: data)
            let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct ClaudeIPWidget: Widget {
    let kind = "ClaudeIPWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeProvider()) { entry in
            WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claude IP 检测")
        .description("三路出口 IP（默认隐藏，可切换显隐）、Trust 评分、属性、可用性、DNS 状态；重新检测/显示 IP 由静默宿主处理，不影响桌宠。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
