import SwiftUI
import WidgetKit
import AppKit

// Presentation only. Every value and semantic color is supplied by the existing
// WidgetData and WidgetViews helpers. The original actions keep their URLs.
enum GlassPalette {
    // Light presentation palette; the existing helpers still decide every level.
    static let white = Color(red: 0.08, green: 0.14, blue: 0.23)
    static let muted = Color(red: 0.30, green: 0.38, blue: 0.49)
    static let blue = Color(red: 0.18, green: 0.43, blue: 0.68)
    static let scoreMarker = Color(red: 0.46, green: 0.72, blue: 0.88)
    static let mint = Color(red: 0.01, green: 0.48, blue: 0.36)
    static let navy = Color(red: 0.035, green: 0.13, blue: 0.23)
    static func semantic(_ color: Color) -> Color {
        if color == safeColor { return mint }
        if color == warnColor { return Color(red: 0.65, green: 0.40, blue: 0.02) }
        if color == dangerColor { return Color(red: 0.79, green: 0.17, blue: 0.23) }
        if color == infoColor { return Color(red: 0.12, green: 0.40, blue: 0.68) }
        if color == Color.white.opacity(0.85) { return white }
        return color
    }
}

enum WidgetSurfaceMetrics {
    static let designWidth: CGFloat = 1120
    static let inset: CGFloat = 26
    static let outerRadius: CGFloat = 82
    static let cardRadius: CGFloat = outerRadius - inset
}

struct LiquidGlassWidgetBackground: View {
    var body: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: WidgetSurfaceMetrics.outerRadius * geometry.size.width / WidgetSurfaceMetrics.designWidth, style: .circular)
            shape
                .fill(LinearGradient(stops: [
                    .init(color: Color(red: 0.90, green: 0.94, blue: 1), location: 0),
                    .init(color: Color(red: 0.79, green: 0.88, blue: 0.98), location: 0.48),
                    .init(color: Color(red: 0.69, green: 0.84, blue: 0.92), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    shape.fill(RadialGradient(colors: [.white.opacity(0.62), .clear],
                        center: .topLeading, startRadius: 0, endRadius: geometry.size.width * 0.86))
                }
                .overlay {
                    shape.fill(RadialGradient(colors: [Color(red: 0.55, green: 0.66, blue: 0.94).opacity(0.20), .clear],
                        center: .bottomTrailing, startRadius: 0, endRadius: geometry.size.width * 0.72))
                }
        }
    }
}

@MainActor
enum GlassForegroundCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 6
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    static func image<C: View>(key: String, size: CGSize, content: C) -> NSImage? {
        if let image = images.object(forKey: key as NSString) { return image }
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 2
        renderer.isOpaque = false
        guard let cg = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: size)
        images.setObject(image, forKey: key as NSString, cost: cg.width * cg.height * 4)
        return image
    }
}

struct LiquidGlassLargeView: View {
    let d: WidgetData
    @Environment(\.widgetContentMargins) private var margins
    @Environment(\.widgetPreview) private var preview
    var body: some View {
        LiquidGlassCanvas(d: d)
            .padding(preview ? EdgeInsets() : EdgeInsets(top: -margins.top, leading: -margins.leading,
                bottom: -margins.bottom, trailing: -margins.trailing))
    }
}

// Uniform scaling keeps circular arcs circular, including nonsquare previews.
// native shapes/text; the wallpaper is never baked into the widget.
struct LiquidGlassCanvas: View {
    let d: WidgetData
    var presentationElapsed: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Shared by the visual button, native Link hit region and ripple center.
    static let designSize = CGSize(width: WidgetSurfaceMetrics.designWidth, height: WidgetSurfaceMetrics.designWidth)
    static let controlGap: CGFloat = 12
    static let controlWidth: CGFloat = 32
    static let refreshWidth: CGFloat = 52
    static let scoreTitleFontSize: CGFloat = 32
    static let scoreTitleWidth = ceil(("IP 可信度评分" as NSString).size(withAttributes: [
        .font: NSFont.systemFont(ofSize: scoreTitleFontSize, weight: .semibold)
    ]).width)
    static let helpCenter = CGPoint(x: 60 + scoreTitleWidth + controlGap + controlWidth / 2, y: 77)
    static let refreshCenter = CGPoint(x: helpCenter.x + controlWidth / 2 + controlGap + refreshWidth / 2, y: 77)
    static let refreshOrigin = UnitPoint(x: refreshCenter.x / designSize.width, y: refreshCenter.y / designSize.height)
    private var isLoading: Bool { d.phase == "loading" }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = size.width / Self.designSize.width
            let designHeight = size.height / scale
            let origin = UnitPoint(x: Self.refreshOrigin.x, y: Self.refreshCenter.y / designHeight)
            let progress = d.phase == "loading" && !reduceMotion
                ? WidgetRefreshPresentation.waveProgress(at: presentationElapsed ?? WidgetRefreshPresentation.sharedElapsed) : nil
            let foreground = composition(height: designHeight)
                .overlay {
                    if let progress { WidgetRippleSurface(origin: origin, progress: progress) }
                }
                .frame(width: Self.designSize.width, height: designHeight)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .environment(\.widgetPhase, d.phase ?? "")
                .environment(\.widgetPulse, reduceMotion ? 0 : (d.phaseAngle ?? 0))
                .environment(\.colorScheme, .light)
                .foregroundColor(GlassPalette.white)
            ZStack(alignment: .topLeading) {
                if #available(macOS 15.0, *), let image = GlassForegroundCache.image(key: cacheKey(size) + "-wave-\(progress ?? -1)", size: size, content: foreground) {
                    Image(nsImage: WidgetRippleRenderer.image(image, origin: origin, progress: progress))
                        .resizable().widgetAccentedRenderingMode(.fullColor)
                        .frame(width: size.width, height: size.height)
                        .accessibilityLabel(accessibilitySummary)
                } else { foreground }
                actionOverlay(size)
            }
        }
        .foregroundColor(GlassPalette.white)
        .accessibilityElement(children: .contain)
    }

    private func cacheKey(_ size: CGSize) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(d)) ?? Data()
        return "glass-\(bytes.hashValue)-\(WidgetPrefs.showIP)-\(size)-\(reduceMotion)-\(Locale.preferredLanguages)-\(TimeZone.current.identifier)-\(TimeZone.current.secondsFromGMT())"
    }

    private func composition(height: CGFloat) -> some View {
        let extraHeight = height - Self.designSize.height
        return ZStack(alignment: .topLeading) {
            // Opaque color belongs to this presentation too, so a desktop tint
            // cannot replace the requested light theme with the host's gray plate.
            LiquidGlassWidgetBackground().frame(width: Self.designSize.width, height: height)
            RoundedRectangle(cornerRadius: WidgetSurfaceMetrics.outerRadius, style: .circular)
                .strokeBorder(LinearGradient(colors: [.white, Color(red: 0.68, green: 0.80, blue: 0.91), .white.opacity(0.90)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2.2)
            hero.frame(width: 1068, height: 304).position(x: 560, y: 178)
            information.frame(width: 526, height: 340).position(x: 289, y: 518)
            exits.frame(width: 526, height: 272).position(x: 831, y: 484)
            device.frame(width: 526, height: 390 + extraHeight).position(x: 289, y: 899 + extraHeight / 2)
            services.frame(width: 526, height: 458 + extraHeight).position(x: 831, y: 865 + extraHeight / 2)
        }
    }

    private var hero: some View {
        ZStack(alignment: .topLeading) {
            GlassPanelSurface()
            GlassWorldMap(d: d).frame(width: 650, height: 304).offset(x: 416)
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: 355, y: 0))
                path.addLine(to: CGPoint(x: 230, y: 304)); path.addLine(to: CGPoint(x: 0, y: 304)); path.closeSubpath()
            }.fill(.white.opacity(0.22))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Self.controlGap) {
                    Text("IP 可信度评分").font(.system(size: Self.scoreTitleFontSize, weight: .semibold))
                        .frame(width: Self.scoreTitleWidth, alignment: .leading)
                    WidgetControlGlyph(state: .help, angle: 0)
                        .frame(width: Self.controlWidth, height: Self.controlWidth)
                    WidgetControlGlyph(state: refreshState, angle: reduceMotion ? 0 : (d.phaseAngle ?? 0))
                        .frame(width: Self.refreshWidth, height: Self.controlWidth)
                    Text(isLoading ? "—:—" : timeText(d.updatedAt)).font(.system(size: 28, weight: .medium)).monospacedDigit()
                        .foregroundColor(GlassPalette.muted)
                    Spacer(minLength: 0)
                }.frame(width: 503, height: 52)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(isLoading ? "—" : scoreValue(d)).font(.system(size: 112, weight: .bold, design: .rounded))
                        .tracking(-6).foregroundStyle(LinearGradient(colors: [isLoading ? GlassPalette.blue : GlassPalette.semantic(scoreColor(d)), isLoading ? GlassPalette.blue.opacity(0.65) : GlassPalette.semantic(scoreColor(d)).opacity(0.88)], startPoint: .top, endPoint: .bottom))
                    Text("/100").font(.system(size: 26)).foregroundColor(GlassPalette.muted)
                    Text(isLoading ? "检测中" : d.trustLabel.text).font(.system(size: 24, weight: .semibold))
                        .foregroundColor(isLoading ? GlassPalette.blue : GlassPalette.semantic(scoreColor(d)))
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background((isLoading ? GlassPalette.blue : GlassPalette.semantic(scoreColor(d))).opacity(0.20), in: RoundedRectangle(cornerRadius: 17))
                        .padding(.leading, 24)
                }.frame(height: 122)
                GlassScoreBar(score: isLoading ? nil : d.trustScore, pending: isLoading).frame(width: 503, height: 30).padding(.top, 3)
                HStack(spacing: 12) {
                    Image(systemName: isLoading ? "clock" : !d.hasClaudeIP ? "exclamationmark.circle.fill" : overallStatus(d).0.icon)
                        .font(.system(size: 30)).foregroundColor(isLoading ? GlassPalette.blue : GlassPalette.semantic(d.hasClaudeIP ? overallStatus(d).0.color : dangerColor))
                    Text(isLoading ? "检测中，等待结果" : riskMessage.replacingOccurrences(of: "⚠ ", with: "").replacingOccurrences(of: "✓ ", with: ""))
                        .font(.system(size: 23)).foregroundColor(GlassPalette.muted)
                        .lineLimit(1).minimumScaleFactor(0.70)
                }.frame(width: 540, alignment: .leading).padding(.top, 9)
            }.padding(.leading, 34).padding(.top, 25)
        }.clipShape(RoundedRectangle(cornerRadius: WidgetSurfaceMetrics.cardRadius, style: .circular))
    }

    private var information: some View {
        GlassSection(title: "IP 信息", icon: "mappin.circle.fill", status: d.hasClaudeIP ? overallStatus(d).0 : .neutral,
                     statusText: d.hasClaudeIP ? (overallStatus(d).0 == .safe ? "正常" : overallStatus(d).0 == .warn ? "注意" : "警告") : "未知") {
            GlassDataRow(icon: "globe", title: "地区", value: placeLine(d))
            GlassDataRow(icon: "point.3.connected.trianglepath.dotted", title: "ASN", value: d.risk?.asn.map { "AS\($0)" } ?? "—")
            GlassDataRow(icon: "building.2", title: "运营商", value: d.risk?.asOrganization ?? "—")
            GlassDataRow(icon: "square.grid.2x2", title: "属性", value: residentialText(d) + (d.isResidential == nil ? "" : " IP"), color: residentialLevel(d).color, badge: true)
            GlassDataRow(icon: "checkmark.shield", title: "滥用评分", value: d.risk?.abuser_score ?? "—", color: (d.risk?.abuser_score ?? "").contains("Low") ? safeColor : GlassPalette.white)
        }
    }

    private var exits: some View {
        GlassSection(title: "出口 IP", icon: "server.rack") {
            exitRow("中国", ip: d.cnIP, cc: d.geo[d.cnIP ?? ""]?.country_code, claude: false)
            exitRow("Cloudflare", ip: d.cfIP, cc: d.geo[d.cfIP ?? ""]?.country_code, claude: false)
            exitRow("Claude", ip: d.claudeIP, cc: d.claudeGeo?.country_code ?? d.claudeLoc, claude: true)
        }
    }
    private func exitRow(_ source: String, ip: String?, cc: String?, claude: Bool) -> some View {
        let country = countryLine(d, ip)
        let label = source == "中国" ? "中国出口IPv4" : isLoading ? source : (country.isEmpty ? source : country + " (" + source + ")")
        return HStack(spacing: 15) {
            Group {
                if isLoading { Image(systemName: "globe").foregroundColor(GlassPalette.blue.opacity(0.55)) }
                else { Text(flag(cc)) }
            }.font(.system(size: 31)).frame(width: 34)
            Text(label).font(.system(size: 20)).foregroundColor(GlassPalette.muted).lineLimit(1).minimumScaleFactor(0.68)
            Spacer(minLength: 2)
            Text(isLoading ? "检测中" : shownIP(ip)).font(.system(size: 21, weight: .semibold)).monospacedDigit()
                .foregroundColor(isLoading ? GlassPalette.blue.opacity(0.65) : GlassPalette.semantic(ipLevel(d, ip: ip, isClaude: claude).color))
                .lineLimit(1).minimumScaleFactor(0.58).frame(width: 165, alignment: .trailing)
        }.frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) { GlassRowDivider().padding(.leading, 49) }
    }

    private var device: some View {
        GlassSection(title: "设备 / 检测范围", icon: "person.crop.circle.badge.checkmark") {
            GlassDataRow(icon: "clock", title: "时区", value: timezoneMatch(d) + "  " + utcOffsetText(TimeZone.current), color: timezoneMatch(d) == "一致" ? safeColor : warnColor, wideTitle: true)
            GlassDataRow(icon: "globe", title: "语言", value: Locale.preferredLanguages.first ?? "—", wideTitle: true)
            GlassDataRow(icon: "laptopcomputer", title: "系统", value: systemVersion(), wideTitle: true)
            GlassDataRow(icon: "network", title: "WebRTC", value: "组件内检测", wideTitle: true)
            GlassDataRow(icon: "square.stack.3d.up", title: "Canvas/WebGL", value: "面板内检测", wideTitle: true)
            GlassDataRow(icon: "checkmark.shield", title: "DNS 服务商", value: d.dns.isp ?? "—", wideTitle: true)
        }
    }

    private var services: some View {
        let low = isLowScore(d)
        return GlassSection(title: "可用性 / 服务", icon: "externaldrive", status: d.hasClaudeIP ? (low || d.status?.overall_indicator != "none" ? .danger : .safe) : .neutral,
                            statusText: !d.hasClaudeIP ? "未知" : low || d.status?.overall_indicator != "none" ? "异常" : "正常") {
            if !isLoading && !d.hasClaudeIP {
                Spacer(); Text("等待检测数据").font(.system(size: 23)).foregroundColor(GlassPalette.muted)
                Text("未获取到 Claude 出口 IP").font(.system(size: 18)).foregroundColor(dangerColor); Spacer()
            } else {
                GlassDataRow(icon: "link", title: "claude.ai", value: low ? "——" : (d.availability.claudeOK ? "\(d.availability.claudeMs)ms" : "不可访问"), color: low ? dangerColor : latencyLevel(d.availability.claudeMs, ok: d.availability.claudeOK).color)
                GlassDataRow(icon: "server.rack", title: "anthropic.com", value: low ? "——" : (d.availability.anthropicOK ? "\(d.availability.anthropicMs)ms" : "不可访问"), color: low ? dangerColor : latencyLevel(d.availability.anthropicMs, ok: d.availability.anthropicOK).color)
                GlassDataRow(icon: "checkmark.shield", title: "Claude 服务状态", value: low ? "——" : (d.status?.overall_indicator == "none" ? "全部正常" : "异常"), color: low ? dangerColor : d.status?.overall_indicator == "none" ? safeColor : dangerColor, titleWidth: 180)
                GlassDataRow(icon: "checkmark.shield", title: "DNS 泄露", value: low ? "——" : d.dns.state, color: low ? dangerColor : dnsLevel(d).color)
                GlassDataRow(icon: "shield", title: "DNS 出口", value: low ? "——" : shownIP(d.dns.exitIP), color: low ? dangerColor : dnsLevel(d).color)
                GlassDataRow(icon: "network", title: "WebRTC UDP 泄露检测", value: low ? "——" : (d.udp?.text ?? "待检测"), color: low ? dangerColor : udpLevel(d).color, titleWidth: 220)
            }
        }
    }

    private var riskMessage: String {
        !d.hasClaudeIP ? "未获取到出口 IP，无法评分" : d.trustScore == nil ? "该 IP 暂无评分数据" : overallStatus(d).1
    }
    private var refreshState: WidgetControlState {
        if d.phase == "loading" { return .loading }
        // Reuses the existing exit-data success/failure predicate.
        return d.hasClaudeIP ? .ready : .failed
    }
    private func actionOverlay(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Link(destination: URL(string: "claudeipwidget://toggleip")!) { Color.white.opacity(0.001) }
                .frame(width: Self.controlWidth * size.width / Self.designSize.width, height: max(20, 52 * size.width / Self.designSize.width))
                .position(x: Self.helpCenter.x * size.width / Self.designSize.width, y: Self.helpCenter.y * size.width / Self.designSize.width)
                .accessibilityLabel(WidgetPrefs.showIP ? "问号：隐藏 IP" : "问号：显示 IP")
                .help(WidgetPrefs.showIP ? "隐藏 IP" : "显示 IP")
            Link(destination: URL(string: "claudeipwidget://refresh")!) { Color.white.opacity(0.001) }
                // Compact mouse target stays clear of the adjacent help/time.
                .frame(width: Self.refreshWidth * size.width / Self.designSize.width, height: max(20, 52 * size.width / Self.designSize.width))
                .position(x: Self.refreshCenter.x * size.width / Self.designSize.width, y: Self.refreshCenter.y * size.width / Self.designSize.width)
                .accessibilityLabel(d.phase == "loading" ? "等待检测结果" : d.hasClaudeIP ? "重新检测" : "检测失败，点击重试")
                .disabled(isLoading)
        }.buttonStyle(.plain).disabled(isLoading)
    }
    private var accessibilitySummary: String {
        if isLoading { return "Claude IP 检测。评分、IP 信息、出口、设备及服务数据均检测中。等待新的检测结果。" }
        return ["Claude IP 检测", "检测结果",
         "IP 可信度评分 " + scoreValue(d) + "，" + d.trustLabel.text, riskMessage,
         "地区 " + placeLine(d), "ASN " + (d.risk?.asn.map { "AS\($0)" } ?? "—"),
         "运营商 " + (d.risk?.asOrganization ?? "—"), "属性 " + residentialText(d),
         "滥用评分 " + (d.risk?.abuser_score ?? "—"),
         "中国出口 " + shownIP(d.cnIP), "Cloudflare 出口 " + shownIP(d.cfIP), "Claude 出口 " + shownIP(d.claudeIP),
         "时区 " + timezoneMatch(d) + utcOffsetText(TimeZone.current), "系统 " + systemVersion(),
         "WebRTC 组件内检测，Canvas/WebGL 面板内检测", "Claude 服务状态 " + (!d.hasClaudeIP ? "等待检测数据" : isLowScore(d) ? "——" : d.status?.overall_indicator == "none" ? "全部正常" : "异常"),
         "DNS " + (!d.hasClaudeIP ? "等待检测数据" : isLowScore(d) ? "——" : d.dns.state + "，" + shownIP(d.dns.exitIP)),
         "WebRTC UDP 泄露检测 " + (!d.hasClaudeIP ? "等待检测数据" : isLowScore(d) ? "——" : d.udp?.text ?? "待检测"),
         "更新时间 " + timeText(d.updatedAt)].joined(separator: "。")
    }
}

private struct GlassPanelSurface: View {
    var radius: CGFloat = WidgetSurfaceMetrics.cardRadius
    var phaseOffset: Double = 0
    @Environment(\.widgetPhase) private var phase
    @Environment(\.widgetPulse) private var pulse
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .circular)
            .fill(LinearGradient(colors: [Color(red: 0.99, green: 1, blue: 1), Color(red: 0.89, green: 0.95, blue: 0.99)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .circular)
                    .fill(LinearGradient(colors: [.white.opacity(0.045), .clear, .white.opacity(0.018)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .circular)
                    .strokeBorder(LinearGradient(colors: [.white, Color(red: 0.74, green: 0.82, blue: 0.90), .white], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.6)
            }
            .overlay {
                if phase == "loading" {
                    WidgetCircuitBorder(radius: radius, angle: pulse + phaseOffset)
                }
            }
    }
}

private struct GlassSection<Content: View>: View {
    let title: String
    let icon: String
    var status: Level? = nil
    var statusText = ""
    @Environment(\.widgetPhase) private var phase
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: icon).font(.system(size: 28, weight: .medium)).foregroundColor(GlassPalette.muted).frame(width: 30)
                Text(title).font(.system(size: 26, weight: .semibold))
                Spacer(minLength: 2)
                if let status {
                    Text(phase == "loading" ? "检测中" : statusText).font(.system(size: 22, weight: .semibold))
                        .foregroundColor(phase == "loading" ? GlassPalette.blue : GlassPalette.semantic(status.color))
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background((phase == "loading" ? GlassPalette.blue : GlassPalette.semantic(status.color)).opacity(0.17), in: Capsule())
                }
            }.padding(.horizontal, 30).frame(height: 63)
                .background(GlassPalette.blue.opacity(0.045))
            VStack(spacing: 0, content: content).padding(.horizontal, 30).padding(.top, 7).padding(.bottom, 13)
                .frame(maxHeight: .infinity)
        }.background(GlassPanelSurface(phaseOffset: Double(title.count) * 53))
            .clipShape(RoundedRectangle(cornerRadius: WidgetSurfaceMetrics.cardRadius, style: .circular))
    }
}

private struct GlassDataRow: View {
    let icon: String
    let title: String
    let value: String
    var color = GlassPalette.white
    var badge = false
    var wideTitle = false
    var titleWidth: CGFloat? = nil
    @Environment(\.widgetPhase) private var phase
    var body: some View {
        HStack(spacing: 17) {
            Image(systemName: icon).font(.system(size: 23)).foregroundColor(GlassPalette.muted).frame(width: 26)
            Text(title).font(.system(size: 22)).foregroundColor(GlassPalette.muted)
                .frame(width: titleWidth ?? (wideTitle ? 151 : 125), alignment: .leading).lineLimit(1).minimumScaleFactor(0.7)
            Text(phase == "loading" ? "检测中" : value).font(.system(size: 22, weight: phase == "loading" ? .medium : color == GlassPalette.white ? .regular : .semibold))
                .foregroundColor(phase == "loading" ? GlassPalette.blue.opacity(0.65) : GlassPalette.semantic(color)).lineLimit(1).minimumScaleFactor(0.60)
                .padding(.horizontal, badge ? 12 : 0).padding(.vertical, badge ? 5 : 0)
                .background(badge ? (phase == "loading" ? GlassPalette.blue : GlassPalette.semantic(color)).opacity(0.10) : .clear, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { GlassRowDivider().padding(.leading, 49) }
    }
}

private struct GlassRowDivider: View {
    var body: some View {
        GeometryReader { geometry in
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: geometry.size.width, y: 0)) }
                .stroke(GlassPalette.muted.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }.frame(height: 1)
    }
}

private struct GlassScoreBar: View {
    let score: Int?
    var pending = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: pending ? [GlassPalette.blue.opacity(0.12), GlassPalette.blue.opacity(0.28)] : [Color(red: 1, green: 0.35, blue: 0.49), Color(red: 1, green: 0.75, blue: 0.29), Color(red: 0.55, green: 0.99, blue: 0.48), GlassPalette.mint], startPoint: .leading, endPoint: .trailing)).frame(height: 20)
                if let score {
                    Capsule().fill(GlassPalette.scoreMarker).frame(width: 12, height: 35)
                        .offset(x: max(0, min(geometry.size.width - 12, geometry.size.width * CGFloat(min(100, max(0, score))) / 100 - 6)))
                }
            }.frame(maxHeight: .infinity)
        }
    }
}

private struct GlassMapData: Decodable {
    let land: [[Double]]
    let countries: [String: [Double]]
    static let shared: GlassMapData = {
        guard let url = Bundle.main.url(forResource: "HUDWorld", withExtension: "json"),
              let data = try? Data(contentsOf: url), let world = try? JSONDecoder().decode(GlassMapData.self, from: data)
        else { return GlassMapData(land: [], countries: [:]) }
        return world
    }()
}

private struct GlassWorldMap: View {
    let d: WidgetData
    private static let labelFrame = CGRect(x: 353, y: 186, width: 260, height: 74)
    private var isLoading: Bool { d.phase == "loading" }
    private var code: String { (d.risk?.countryCode ?? d.claudeGeo?.country_code ?? d.claudeLoc ?? "").uppercased() }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let anchor = d.hasClaudeIP ? GlassMapData.shared.countries[code] : nil
                let longitude = (anchor?.last ?? -30) + 36
                let center = CGPoint(x: size.width * 0.69, y: size.height * 0.98)
                let radius = size.height * 0.96
                // Fixed decorative particles: no random state, timers or new timeline.
                for index in 0..<68 {
                    let u = sin(Double(index) * 12.9898 + 1.3) * 43758.5453
                    let v = sin(Double(index) * 78.233 + 4.1) * 19341.732
                    let x = 125 + (u - floor(u)) * (size.width - 125)
                    let y = (v - floor(v)) * size.height
                    guard hypot(x - center.x, y - center.y) > radius * 0.97 else { continue }
                    let diameter = index % 9 == 0 ? 3.2 : index % 3 == 0 ? 1.8 : 0.9
                    let particle = Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter))
                    var glow = context
                    if index % 9 == 0 { glow.addFilter(.shadow(color: .cyan.opacity(0.8), radius: 7)) }
                    glow.fill(particle, with: .color(index % 9 == 0 ? Color.white.opacity(0.95) : Color.cyan.opacity(0.30 + Double(index % 4) * 0.12)))
                    if index % 9 == 0 {
                        var cross = Path(); cross.move(to: CGPoint(x: x - 5, y: y + 1.5)); cross.addLine(to: CGPoint(x: x + 8, y: y + 1.5))
                        cross.move(to: CGPoint(x: x + 1.5, y: y - 5)); cross.addLine(to: CGPoint(x: x + 1.5, y: y + 8))
                        glow.stroke(cross, with: .color(.cyan.opacity(0.30)), lineWidth: 0.6)
                    }
                }
                func project(_ latitude: Double, _ lon: Double) -> (point: CGPoint, z: Double) {
                    let lat = latitude * .pi / 180, azimuth = (lon - longitude) * .pi / 180
                    let tilt = 10.0 * .pi / 180
                    let x = cos(lat) * sin(azimuth)
                    let y = sin(lat) * cos(tilt) - cos(lat) * cos(azimuth) * sin(tilt)
                    let z = sin(lat) * sin(tilt) + cos(lat) * cos(azimuth) * cos(tilt)
                    return (CGPoint(x: center.x + radius * x, y: center.y - radius * y), z)
                }
                let rings: [(rotation: Double, squash: Double, scale: Double, color: Color)] = [
                    (-0.34, 0.23, 1.25, Color(red: 0.18, green: 0.58, blue: 0.86)),
                    (0.91, 0.32, 1.18, Color(red: 0.16, green: 0.60, blue: 0.67)),
                    (-1.06, 0.44, 1.14, Color(red: 0.39, green: 0.52, blue: 0.86))
                ]
                func orbitPoint(_ angle: Double, _ index: Int) -> CGPoint {
                    let ring = rings[index]
                    let x = radius * ring.scale * cos(angle), y = radius * ring.squash * sin(angle)
                    return CGPoint(x: center.x + x * cos(ring.rotation) - y * sin(ring.rotation),
                                   y: center.y + x * sin(ring.rotation) + y * cos(ring.rotation) - radius * 0.08)
                }
                func orbit(_ start: Double, _ end: Double, _ ringIndex: Int) -> Path {
                    Path { path in
                        for index in 0...140 {
                            let angle = start + (end - start) * Double(index) / 140
                            let point = orbitPoint(angle, ringIndex)
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                }
                // Curved communication paths are decorative and do not represent probes.
                for index in rings.indices {
                    context.stroke(orbit(0, .pi * 2, index), with: .color(rings[index].color.opacity(0.20)), lineWidth: 1.0)
                }
                let sphere = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                var rim = context
                rim.addFilter(.shadow(color: Color(red: 0.40, green: 0.78, blue: 1).opacity(0.35), radius: 10))
                rim.stroke(sphere, with: .color(Color(red: 0.31, green: 0.66, blue: 0.87).opacity(0.65)), lineWidth: 1.8)
                context.fill(sphere, with: .radialGradient(Gradient(colors: [Color(red: 0.92, green: 0.98, blue: 1), Color(red: 0.72, green: 0.88, blue: 0.97), Color(red: 0.45, green: 0.70, blue: 0.85)]),
                    center: CGPoint(x: center.x - radius * 0.40, y: center.y - radius * 0.65), startRadius: 0, endRadius: radius * 1.7))
                let highlight = Path { path in
                    path.addArc(center: center, radius: radius, startAngle: .degrees(217), endAngle: .degrees(311), clockwise: false)
                }
                rim.stroke(highlight, with: .color(Color.white.opacity(0.92)), lineWidth: 2.8)
                var surface = context; surface.clip(to: sphere)
                for latitude in stride(from: -60.0, through: 60.0, by: 20.0) {
                    var path = Path(); var drawing = false
                    for lon in stride(from: longitude - 180, through: longitude + 180, by: 3) {
                        let p = project(latitude, lon)
                        if p.z > 0 { if drawing { path.addLine(to: p.point) } else { path.move(to: p.point) }; drawing = true }
                        else { drawing = false }
                    }
                    surface.stroke(path, with: .color(Color(red: 0.26, green: 0.55, blue: 0.75).opacity(0.16)), lineWidth: 0.65)
                }
                for lon in stride(from: longitude - 80, through: longitude + 80, by: 20) {
                    var path = Path(); var drawing = false
                    for latitude in stride(from: -90.0, through: 90.0, by: 3) {
                        let p = project(latitude, lon)
                        if p.z > 0 { if drawing { path.addLine(to: p.point) } else { path.move(to: p.point) }; drawing = true }
                        else { drawing = false }
                    }
                    surface.stroke(path, with: .color(Color(red: 0.26, green: 0.55, blue: 0.75).opacity(0.16)), lineWidth: 0.65)
                }
                var cells = Set<Int>()
                for coordinate in GlassMapData.shared.land where coordinate.count >= 2 {
                    let p = project(coordinate[0], coordinate[1]); guard p.z > 0 else { continue }
                    let column = Int(p.point.x / 4.7), row = Int(p.point.y / 4.7)
                    guard cells.insert(row * 2048 + column).inserted else { continue }
                    // Raise each dot along the projected surface normal. The
                    // top, side and cast shadow give the land a beaded relief.
                    let diameter = 1.3 + p.z * 2.2
                    let elevation = 3.0 + p.z * 3.4
                    let top = CGPoint(x: p.point.x + (p.point.x - center.x) / radius * elevation,
                                      y: p.point.y + (p.point.y - center.y) / radius * elevation)
                    let shadow = Path(ellipseIn: CGRect(x: p.point.x + 0.8, y: p.point.y + 1.2, width: diameter * 1.10, height: diameter * 0.72))
                    surface.fill(shadow, with: .color(Color(red: 0.10, green: 0.32, blue: 0.48).opacity(0.14 + p.z * 0.14)))
                    var side = Path(); side.move(to: p.point); side.addLine(to: top)
                    context.stroke(side, with: .color(Color(red: 0.12, green: 0.40, blue: 0.60).opacity(0.40 + p.z * 0.24)), lineWidth: diameter * 0.78)
                    let dot = Path(ellipseIn: CGRect(x: top.x - diameter / 2, y: top.y - diameter / 2, width: diameter, height: diameter))
                    context.fill(dot, with: .radialGradient(Gradient(colors: [Color(red: 0.84, green: 0.99, blue: 1), Color(red: 0.23, green: 0.65, blue: 0.84), Color(red: 0.08, green: 0.34, blue: 0.58)]),
                        center: CGPoint(x: top.x - diameter * 0.20, y: top.y - diameter * 0.25), startRadius: 0, endRadius: diameter * 0.80))
                }
                var beam = context
                beam.addFilter(.shadow(color: Color.white.opacity(0.65), radius: 3))
                for index in rings.indices {
                    beam.stroke(orbit(.pi, .pi * 2, index), with: .color(rings[index].color.opacity(index == 0 ? 0.70 : 0.43)), lineWidth: index == 0 ? 1.7 : 1.15)
                    for fraction in [1.16 + Double(index) * 0.09, 1.72 + Double(index) * 0.05] {
                        let point = orbitPoint(.pi * fraction, index)
                        let star = Path(ellipseIn: CGRect(x: point.x - 2.2, y: point.y - 2.2, width: 4.4, height: 4.4))
                        beam.fill(star, with: .color(.white))
                        beam.stroke(star, with: .color(rings[index].color.opacity(0.75)), lineWidth: 0.8)
                    }
                }
                if let coordinate = anchor, coordinate.count >= 2 {
                    let p = project(coordinate[0], coordinate[1]).point
                    let label = Self.labelFrame
                    // Two short segments meet the label border, never its text.
                    if CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8).contains(p) && !label.contains(p) {
                        let end: CGPoint
                        let elbow: CGPoint
                        if p.y < label.minY {
                            end = CGPoint(x: label.minX + 36, y: label.minY)
                            elbow = CGPoint(x: min(end.x - 14, p.x + end.y - p.y), y: end.y)
                        } else if p.y > label.maxY {
                            end = CGPoint(x: label.minX + 36, y: label.maxY)
                            elbow = CGPoint(x: min(end.x - 14, p.x + p.y - end.y), y: end.y)
                        } else {
                            end = CGPoint(x: label.minX, y: min(label.maxY - 22, max(label.minY + 22, p.y)))
                            elbow = CGPoint(x: end.x - 14, y: p.y)
                        }
                        let leader = Path { path in
                            path.move(to: p); path.addLine(to: elbow); path.addLine(to: end)
                        }
                        context.stroke(leader, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                        context.stroke(leader, with: .color(Color(red: 0.26, green: 0.59, blue: 0.80).opacity(0.90)), style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                    }
                    // A compact surface point replaces the floating badge.
                    let halo = Path(ellipseIn: CGRect(x: p.x - 23, y: p.y - 23, width: 46, height: 46))
                    context.fill(halo, with: .radialGradient(Gradient(colors: [.white.opacity(0.85), Color(red: 0.30, green: 0.73, blue: 0.95).opacity(0.22), .clear]),
                        center: p, startRadius: 4, endRadius: 23))
                    let landing = Path(ellipseIn: CGRect(x: p.x - 17, y: p.y - 6, width: 34, height: 12))
                    context.fill(landing, with: .color(GlassPalette.blue.opacity(0.12)))
                    context.stroke(landing, with: .color(Color(red: 0.29, green: 0.61, blue: 0.81).opacity(0.70)), lineWidth: 1.6)
                    let point = Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
                    var locator = context
                    locator.addFilter(.shadow(color: GlassPalette.blue.opacity(0.28), radius: 3, y: 1))
                    locator.fill(point, with: .linearGradient(Gradient(colors: [Color(red: 0.48, green: 0.84, blue: 0.98), Color(red: 0.16, green: 0.48, blue: 0.74)]),
                        startPoint: CGPoint(x: p.x, y: p.y - 6), endPoint: CGPoint(x: p.x, y: p.y + 6)))
                    locator.stroke(point, with: .color(.white), lineWidth: 2.2)
                }
            }
            HStack(spacing: 12) {
                Group {
                    if isLoading { Image(systemName: "globe").foregroundColor(GlassPalette.blue.opacity(0.55)) }
                    else { Text(flag(code)) }
                }.font(.system(size: 34))
                VStack(alignment: .leading, spacing: 5) {
                    Text(isLoading ? "检测中" : d.hasClaudeIP ? (d.claudeGeo?.country ?? d.risk?.country ?? "未知地区") : "等待定位")
                        .font(.system(size: 21, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.65)
                    Text(isLoading ? "出口 IP · 等待新数据" : d.hasClaudeIP ? "出口 IP · 国家级示意" : "未获取到出口 IP")
                        .font(.system(size: 15)).foregroundColor(GlassPalette.muted)
                }
            }.foregroundColor(GlassPalette.white)
                .padding(.horizontal, 15).frame(width: Self.labelFrame.width, height: Self.labelFrame.height, alignment: .leading)
                .background(LinearGradient(colors: [.white, Color(red: 0.81, green: 0.91, blue: 0.98)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 19))
                .overlay { RoundedRectangle(cornerRadius: 19).strokeBorder(GlassPalette.blue.opacity(0.30), lineWidth: 1.2) }
                .offset(x: Self.labelFrame.minX, y: Self.labelFrame.minY)
        }.clipped().accessibilityHidden(true).allowsHitTesting(false)
    }
}
