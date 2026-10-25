import SwiftUI
import WidgetKit
import AppKit

private struct HUDMotionKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var hudReduceMotion: Bool {
        get { self[HUDMotionKey.self] }
        set { self[HUDMotionKey.self] = newValue }
    }
}

// Presentation only. WidgetData, privacy helpers, risk helpers and deep links stay owned
// by the original widget. No requests, preferences, timers or parallel detection state.
private enum HUD {
    static let cyan = Color(red: 0, green: 0.875, blue: 1)
    static let white = Color(red: 0.895, green: 0.96, blue: 1)
    static let ink = Color.black
    static let muted = Color.black.opacity(0.66)
    static let orange = Color(red: 1, green: 0.71, blue: 0.28)
    static let navy = Color(red: 0.012, green: 0.055, blue: 0.09)
    // Presentation palette only; the original helpers still decide every level.
    static func status(_ original: Color) -> Color {
        if original == safeColor { return Color(red: 0.02, green: 0.55, blue: 0.28) }
        if original == dangerColor { return Color(red: 0.85, green: 0.12, blue: 0.20) }
        if original == warnColor { return Color(red: 0.80, green: 0.42, blue: 0.04) }
        if original == infoColor { return Color(red: 0, green: 0.45, blue: 0.63) }
        return original
    }
    // Decoded once per extension process, not once per body/phase update.
    static let background: NSImage? = {
        guard let url = Bundle.main.url(forResource: "HUDBackground", withExtension: "png"),
              let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes -> NSImage? in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let buffer = bytes.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: buffer.count, by: 4) {
                let brightness = max(buffer[i], max(buffer[i+1], buffer[i+2]))
                let alpha = min(255, max(0, (Int(brightness) - 60) * 255 / 150))
                for channel in 0..<3 { buffer[i+channel] = UInt8(Int(buffer[i+channel]) * alpha / 255) }
                buffer[i+3] = UInt8(alpha)
            }
            return context.makeImage().map { NSImage(cgImage: $0, size: image.size) }
        }
    }()
    static let parts: [String: NSImage] = {
        guard let image = background, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [:] }
        let regions: [String: CGRect] = [
            "header": CGRect(x: 80, y: 39, width: 652, height: 75),
            "trust": CGRect(x: 47, y: 116, width: 633, height: 327),
            "left": CGRect(x: 61, y: 448, width: 597, height: 243),
            "right": CGRect(x: 662, y: 448, width: 528, height: 243),
            "lowerLeft": CGRect(x: 61, y: 695, width: 597, height: 297),
            "lowerRight": CGRect(x: 662, y: 695, width: 528, height: 297),
            "radar": CGRect(x: 1187, y: 479, width: 201, height: 220),
            "rail": CGRect(x: 1194, y: 704, width: 161, height: 283),
            "footer": CGRect(x: 58, y: 995, width: 1290, height: 88)
        ]
        return regions.compactMapValues { r in cg.cropping(to: r).map { NSImage(cgImage: $0, size: r.size) } }
    }()
    static let world: HUDWorld = {
        guard let url = Bundle.main.url(forResource: "HUDWorld", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let world = try? JSONDecoder().decode(HUDWorld.self, from: data) else { return HUDWorld(land: [], countries: [:]) }
        return world
    }()
}

struct HUDGlassBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.12), .cyan.opacity(0.035), .white.opacity(0.08)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.48), .cyan.opacity(0.20), .white.opacity(0.30)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            }
            .environment(\.colorScheme, .light)
    }
}

// Only the current data-bound foreground is rasterized, in memory, to preserve
// black/green/red under WidgetKit's automatic white tint. This is never a background
// asset or a persisted result. Native Links keep the original destinations/hit regions.
@MainActor
private enum HUDColorCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 6
        cache.totalCostLimit = 24 * 1024 * 1024; return cache
    }()
    static func image<C: View>(key: String, size: CGSize, content: C) -> NSImage? {
        if let cached = images.object(forKey: key as NSString) { return cached }
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 2
        renderer.isOpaque = false
        guard let cg = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: size)
        images.setObject(image, forKey: key as NSString, cost: cg.width * cg.height * 4)
        return image
    }
}

private struct HUDWorld: Decodable {
    let land: [[Double]]             // latitude, longitude: static map dots
    let countries: [String: [Double]] // country label points, NOT IP coordinates
}

// Panel interiors are truly transparent. Layout fills the actual Large aspect ratio;
// only linear frame sections extend vertically, while circular elements stay circular.
struct HUDLargeView: View {
    let d: WidgetData
    @Environment(\.widgetContentMargins) private var margins
    var body: some View {
        HUDLargeCanvas(d: d)
            .padding(EdgeInsets(top: -margins.top, leading: -margins.leading,
                               bottom: -margins.bottom, trailing: -margins.trailing))
            .opacity(0.85)
    }
}

// The supplied bitmap's coordinate system keeps each overlay inside its real frame.
private struct HUDLargeCanvas: View {
    let d: WidgetData
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 1402
            let yScale = geometry.size.height / (1122 * scale)
            ZStack {
                let foreground = content(yScale: yScale).frame(width: 1402, height: 1122 * yScale).scaleEffect(scale)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .foregroundColor(HUD.ink)
                    .environment(\.widgetPhase, d.phase ?? "")
                    .environment(\.widgetPulse, d.phaseAngle ?? 0)
                    .environment(\.hudReduceMotion, reduceMotion)
                if #available(macOS 15.0, *), let image = HUDColorCache.image(key: foregroundKey(geometry.size), size: geometry.size, content: foreground) {
                    Image(nsImage: image).resizable().widgetAccentedRenderingMode(.fullColor)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityLabel(accessibilitySummary)
                } else { foreground }
                actions(scale: scale, size: geometry.size)
            }
        }
        .foregroundColor(HUD.ink).accessibilityElement(children: .contain)
    }

    private func foregroundKey(_ size: CGSize) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(d)) ?? Data()
        return "hud-\(bytes.hashValue)-\(WidgetPrefs.showIP)-\(size.width)-\(size.height)-\(reduceMotion)-\(Locale.preferredLanguages)-\(TimeZone.current.identifier)-\(TimeZone.current.secondsFromGMT())"
    }
    private var accessibilitySummary: String {
        let low = isLowScore(d)
        return ["Claude IP 检测", "信任评分：" + scoreValue(d) + "，" + d.trustLabel.text,
                riskMessage, "地区：" + placeLine(d), "ASN：" + (d.risk?.asn.map { "AS\($0)" } ?? "—"),
                "运营商：" + (d.risk?.asOrganization ?? "—"), "属性：" + residentialText(d),
                "滥用评分：" + (d.risk?.abuser_score ?? "—"),
                "中国出口：" + shownIP(d.cnIP) + "，" + countryLine(d, d.cnIP),
                "Cloudflare：" + shownIP(d.cfIP) + "，" + countryLine(d, d.cfIP),
                "Claude：" + shownIP(d.claudeIP) + "，" + countryLine(d, d.claudeIP),
                "时区：" + timezoneMatch(d) + utcOffsetText(TimeZone.current),
                "语言：" + (Locale.preferredLanguages.first ?? "—"), "系统：" + systemVersion(),
                "WebRTC、Canvas/WebGL：面板内检测", "设备 DNS 服务商：" + (d.dns.isp ?? "—"),
                "claude.ai：" + (!d.hasClaudeIP ? "等待检测数据" : low ? "——" : d.availability.claudeOK ? "\(d.availability.claudeMs)ms" : "不可访问"),
                "anthropic.com：" + (!d.hasClaudeIP ? "等待检测数据" : low ? "——" : d.availability.anthropicOK ? "\(d.availability.anthropicMs)ms" : "不可访问"),
                "服务状态：" + (!d.hasClaudeIP ? "等待检测数据" : low ? "——" : d.status?.overall_indicator == "none" ? "全部正常" : "异常"),
                "DNS：" + (!d.hasClaudeIP ? "等待检测数据" : low ? "——" : d.dns.state + "，" + shownIP(d.dns.exitIP) + "，" + (d.dns.isp ?? "—")),
                "更新时间：" + timeText(d.updatedAt)].joined(separator: "。")
    }
    @ViewBuilder
    private func actionColor<C: View>(_ key: String, size: CGSize, @ViewBuilder content: () -> C) -> some View {
        if #available(macOS 15.0, *), let image = HUDColorCache.image(key: key, size: size, content: content().foregroundColor(HUD.ink)) {
            Image(nsImage: image).resizable().widgetAccentedRenderingMode(.fullColor).frame(width: size.width, height: size.height)
        } else { content() }
    }

    private func content(yScale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HUDReferenceArtwork(yScale: yScale).allowsHitTesting(false).accessibilityHidden(true)
            HUDCornerGlints(yScale: yScale).allowsHitTesting(false).accessibilityHidden(true)
            Text("Claude IP 检测").font(.system(size: 32, weight: .bold))
                .frame(width: 240, height: 44, alignment: .leading).position(x: 279, y: 92 * yScale)
            Text("实时检测当前网络环境").font(.system(size: 18)).foregroundColor(HUD.muted)
                .frame(width: 218, height: 34, alignment: .leading).position(x: 559, y: 98 * yScale)
            VStack(alignment: .trailing, spacing: 1) {
                Text(timeText(d.updatedAt)).font(.system(size: 34, weight: .medium, design: .monospaced)).foregroundColor(HUD.ink)
                Text("最后更新").font(.system(size: 18)).foregroundColor(HUD.muted)
            }.frame(width: 114, height: 67).position(x: 1284, y: 94 * yScale)

            HUDPanelTitle(title: "IP 可信度评分", subtitle: "TRUST SCORE", icon: "questionmark.circle", compact: true)
                .frame(width: 400, height: 48).position(x: 341, y: 180 * yScale)
            HUDTrustGauge(d: d).frame(width: 276, height: 276).position(x: 272, y: 315 * yScale)
            trustSummary.frame(width: 234, height: 228 * yScale).position(x: 518, y: 316 * yScale)
            HUDGlobeLocationView(d: d).frame(width: 670, height: 326 * yScale).position(x: 990, y: 295 * yScale)
            globeRail.frame(width: 112, height: 180).position(x: 1270, y: 255 * yScale)

            HUDPanelTitle(title: "IP 属性", subtitle: "IP INFORMATION", icon: "scope")
                .frame(width: 470, height: 58).position(x: 358, y: 494 * yScale)
            properties.frame(width: 430, height: 174 * yScale).position(x: 337, y: 612 * yScale)
            HUDPanelTitle(title: "出口 IP 列表", subtitle: "EXIT IPS", icon: "arrow.triangle.branch")
                .frame(width: 452, height: 58).position(x: 908, y: 494 * yScale)
            exits.frame(width: 452, height: 142 * yScale).position(x: 906, y: 594 * yScale)
            HUDPanelTitle(title: "设备 / 检测范围", subtitle: "DEVICE & ENVIRONMENT", icon: "desktopcomputer")
                .frame(width: 458, height: 58).position(x: 356, y: 760 * yScale)
            device.frame(width: 472, height: 200 * yScale).position(x: 360, y: 888 * yScale)
            HUDPanelTitle(title: "可用性 / 服务", subtitle: "SERVICE STATUS", icon: "square.stack.3d.up.fill")
                .frame(width: 450, height: 58).position(x: 915, y: 719 * yScale)
            services.frame(width: 410, height: 214 * yScale).position(x: 894, y: 863 * yScale)
            HUDRadar().frame(width: 190, height: 190).position(x: 1255, y: 602 * yScale)
            auxiliary.frame(width: 130, height: 260 * yScale).position(x: 1266, y: 845 * yScale)
            footer.frame(width: 1100, height: 60 * yScale).position(x: 673, y: 1042 * yScale)
        }
    }

    private var trustSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(d.trustLabel.text).font(.system(size: 30, weight: .bold)).foregroundColor(HUD.status(scoreColor(d)))
                .frame(width: 137, height: 50)
                .overlay(Capsule().stroke(HUD.cyan.opacity(0.9), lineWidth: 1.2))
                .shadow(color: HUD.cyan.opacity(0.16), radius: 10)
                .padding(.leading, 32)
            Spacer(minLength: 14)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: !d.hasClaudeIP ? "exclamationmark.circle" : overallStatus(d).0.icon)
                    .font(.system(size: 25)).foregroundColor(!d.hasClaudeIP ? HUD.muted : HUD.status(overallStatus(d).0.color))
                Text(riskMessage).font(.system(size: 20)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(d.hasClaudeIP && d.trustScore != nil ? HUD.status(overallStatus(d).0.color) : HUD.muted)
            }.padding(.leading, 30)
            Spacer(minLength: 14)
            GaugeBar(score: d.trustScore, height: 12)
            HStack {
                Text("风险高"); Spacer(); Text("一般"); Spacer(); Text("良好"); Spacer(); Text("优秀")
            }.font(.system(size: 14)).foregroundColor(HUD.muted).padding(.top, 8)
            Text("支持地区：" + (!d.hasClaudeIP ? "未知" : d.restrictedName == nil ? "正常" : "受限"))
                .font(.system(size: 14)).foregroundColor(!d.hasClaudeIP ? HUD.muted : HUD.status(d.restrictedName == nil ? safeColor : dangerColor))
                .padding(.top, 5)
        }
    }
    private var riskMessage: String {
        !d.hasClaudeIP ? "未获取到出口 IP，无法评分" : d.trustScore == nil ? "该 IP 暂无评分数据" : overallStatus(d).1
    }
    private var properties: some View {
        VStack(spacing: 0) {
            HUDDataRow(icon: "globe", title: "地区", value: placeLine(d))
            HUDDataRow(icon: "point.3.connected.trianglepath.dotted", title: "ASN", value: d.risk?.asn.map { "AS\($0)" } ?? "—")
            HUDDataRow(icon: "building.2", title: "运营商", value: d.risk?.asOrganization ?? "—")
            HUDDataRow(icon: "square.grid.2x2", title: "属性", value: residentialText(d), color: residentialLevel(d) == .neutral ? HUD.ink : residentialLevel(d).color, badge: true)
            HUDDataRow(icon: "checkmark.shield.fill", title: "滥用评分", value: d.risk?.abuser_score ?? "—",
                       color: (d.risk?.abuser_score ?? "").contains("Low") ? safeColor : HUD.ink)
        }
    }
    private var exits: some View {
        VStack(spacing: 0) {
            exitRow(source: "中国", ip: d.cnIP, cc: d.geo[d.cnIP ?? ""]?.country_code, isClaude: false)
            exitRow(source: "Cloudflare", ip: d.cfIP, cc: d.geo[d.cfIP ?? ""]?.country_code, isClaude: false)
            exitRow(source: "Claude", ip: d.claudeIP, cc: d.claudeGeo?.country_code ?? d.claudeLoc, isClaude: true)
        }
    }
    private func exitRow(source: String, ip: String?, cc: String?, isClaude: Bool) -> some View {
        let country = countryLine(d, ip)
        let label = source == "中国" ? source : country.isEmpty ? source : country + " (" + source + ")"
        return HStack(spacing: 16) {
            Text(flag(cc)).font(.system(size: 35)).frame(width: 42).accessibilityHidden(true)
            Text(label).font(.system(size: 19)).foregroundColor(HUD.ink.opacity(0.90))
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 3)
            Text(shownIP(ip)).font(.system(size: 21, weight: .semibold)).monospacedDigit()
                .foregroundColor(HUD.status(ipLevel(d, ip: ip, isClaude: isClaude).color))
                .lineLimit(1).minimumScaleFactor(0.6).frame(width: 170, alignment: .trailing).help(shownIP(ip)).layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.cyan.opacity(0.13)).frame(height: 0.8) }
        .accessibilityElement(children: .combine)
    }
    private var device: some View {
        VStack(spacing: 0) {
            HUDDataRow(icon: "clock", title: "时区", value: timezoneMatch(d) + "  " + utcOffsetText(TimeZone.current), color: timezoneMatch(d) == "一致" ? safeColor : warnColor, leadingValue: true)
            HUDDataRow(icon: "globe", title: "语言", value: Locale.preferredLanguages.first ?? "—", leadingValue: true)
            HUDDataRow(icon: "laptopcomputer", title: "系统", value: systemVersion(), leadingValue: true)
            HUDDataRow(icon: "network", title: "WebRTC", value: "面板内检测", leadingValue: true)
            HUDDataRow(icon: "square.stack.3d.up", title: "Canvas/WebGL", value: "面板内检测", leadingValue: true)
            HUDDataRow(icon: "checkmark.shield.fill", title: "DNS 服务商", value: d.dns.isp ?? "—", leadingValue: true)
        }
    }
    private var services: some View {
        let low = isLowScore(d)
        return VStack(spacing: 0) {
            if !d.hasClaudeIP {
                Spacer(); Text("等待检测数据").font(.system(size: 23)).foregroundColor(HUD.muted)
                Text("未获取到 Claude 出口 IP").font(.system(size: 17)).foregroundColor(dangerColor); Spacer()
            } else {
                HUDDataRow(icon: "link", title: "claude.ai", value: low ? "——" : (d.availability.claudeOK ? "\(d.availability.claudeMs)ms" : "不可访问"), color: low ? dangerColor : latencyLevel(d.availability.claudeMs, ok: d.availability.claudeOK).color)
                HUDDataRow(icon: "server.rack", title: "anthropic.com", value: low ? "——" : (d.availability.anthropicOK ? "\(d.availability.anthropicMs)ms" : "不可访问"), color: low ? dangerColor : latencyLevel(d.availability.anthropicMs, ok: d.availability.anthropicOK).color)
                HUDDataRow(icon: "checkmark.shield", title: "服务状态", value: low ? "——" : (d.status?.overall_indicator == "none" ? "全部正常" : "异常"), color: low ? dangerColor : (d.status?.overall_indicator == "none" ? safeColor : dangerColor))
                HUDDataRow(icon: "checkmark.shield", title: "DNS 泄露", value: low ? "——" : d.dns.state, color: low ? dangerColor : dnsLevel(d).color)
                HUDDataRow(icon: "shield", title: "DNS 出口", value: low ? "——" : shownIP(d.dns.exitIP), color: low ? dangerColor : dnsLevel(d).color, mono: true)
                HUDDataRow(icon: "globe", title: "DNS 服务商", value: low ? "——" : (d.dns.isp ?? "—"), color: low ? dangerColor : HUD.ink)
            }
        }
    }
    private var globeRail: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(["GLOBAL", "IP-LOCATION", "REAL TIME", "ANALYSIS"], id: \.self) { label in
                HStack(spacing: 8) {
                    Circle().stroke(HUD.cyan, lineWidth: 1).background(Circle().fill(HUD.cyan.opacity(0.5))).frame(width: 7, height: 7)
                    Text(label).font(.system(size: 11)).foregroundColor(HUD.muted)
                }
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
    private var auxiliary: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(["NETWORK", "SECURITY", "STABILITY"], id: \.self) { text in
                Text(text).font(.system(size: 9)).tracking(1).foregroundColor(HUD.cyan.opacity(0.9))
            }
            Spacer(minLength: 22)
            Text("J.A.R.V.I.S.").font(.system(size: 14, design: .monospaced)).tracking(2).foregroundColor(HUD.cyan)
            ForEach(Array(["在线", "检测", "分析", "完成"].enumerated()), id: \.offset) { index, title in
                HStack {
                    Text(String(format: "%03d", index + 1)); Spacer(); Text(title)
                }.font(.system(size: 12, design: .monospaced))
                    .foregroundColor((d.phase == "loading" ? index == 1 : d.hasClaudeIP && index == 3) ? HUD.cyan : HUD.muted.opacity(0.65))
            }
        }.padding(.horizontal, 6).accessibilityHidden(true).allowsHitTesting(false)
    }
    private var footer: some View {
        let loading = d.phase == "loading"
        let color: Color = loading ? HUD.cyan : !d.hasClaudeIP ? dangerColor : safeColor
        return HStack(spacing: 24) {
            Image(systemName: loading ? "arrow.triangle.2.circlepath" : !d.hasClaudeIP ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundColor(HUD.status(color)).shadow(color: color.opacity(0.6), radius: 8)
            Text(loading ? "正在重新检测…" : !d.hasClaudeIP ? "出口 IP 检测失败" : d.phase == "done" ? "数据已更新" : "检测完成")
                .font(.system(size: 22, weight: .semibold)).foregroundColor(HUD.status(color))
            Rectangle().fill(HUD.cyan.opacity(0.3)).frame(width: 1, height: 24)
            Text("上次更新：" + timeText(d.updatedAt, short: false)).font(.system(size: 17)).foregroundColor(HUD.muted)
            Spacer()
            Text("自动刷新 5 分钟").font(.system(size: 15)).foregroundColor(HUD.muted)
        }
    }
    private func actions(scale: CGFloat, size: CGSize) -> some View {
        let x: CGFloat = 0, y: CGFloat = 0
        let yScale = size.height / (1122 * scale)
        return ZStack(alignment: .topLeading) {
            Link(destination: URL(string: "claudeipwidget://toggleip")!) {
                actionColor("eye-\(WidgetPrefs.showIP)-\(scale)", size: CGSize(width: 59 * scale, height: 59 * scale)) {
                    Image(systemName: WidgetPrefs.showIP ? "eye" : "eye.slash")
                        .font(.system(size: 29 * scale, weight: .medium))
                        .frame(width: 59 * scale, height: 59 * scale)
                        .background(Circle().stroke(HUD.cyan.opacity(0.65), lineWidth: 0.5))
                }
                    .frame(width: max(24, 59 * scale), height: max(24, 59 * scale)).contentShape(Rectangle())
            }.accessibilityLabel(WidgetPrefs.showIP ? "隐藏 IP" : "显示 IP")
                .position(x: x + 922 * scale, y: y + 95 * scale * yScale)
            Link(destination: URL(string: "claudeipwidget://refresh")!) {
                actionColor("refresh-\(scale)", size: CGSize(width: 223 * scale, height: 54 * scale)) {
                    Label("重新检测", systemImage: "arrow.clockwise").font(.system(size: 23 * scale, weight: .semibold))
                        .frame(width: 223 * scale, height: 54 * scale)
                        .background(HUDCutShape(cut: 22 * scale).stroke(HUD.cyan.opacity(0.8), lineWidth: 0.5))
                }
                    .frame(height: max(24, 54 * scale)).contentShape(Rectangle())
            }.accessibilityLabel("重新检测").position(x: x + 1093 * scale, y: y + 95 * scale * yScale)
        }.foregroundColor(HUD.ink).buttonStyle(.plain)
    }
}

// Recompose only clean decorative sections of the supplied bitmap. Nine-slicing
// extends flat panel interiors/edge lines; corners and the circular radar retain shape.
private struct HUDReferenceArtwork: View {
    let yScale: CGFloat
    private func part(_ name: String, _ r: CGRect, stretch: Bool = true) -> some View {
        Group {
            if let image = HUD.parts[name] {
                if stretch {
                    Image(nsImage: image).resizable(capInsets: EdgeInsets(top: 28, leading: 28, bottom: 28, trailing: 28))
                } else { Image(nsImage: image).resizable().scaledToFit() }
            }
        }.frame(width: r.width, height: r.height * yScale).position(x: r.midX, y: r.midY * yScale)
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let image = HUD.background {
                Image(nsImage: image).resizable(capInsets: EdgeInsets(top: 130, leading: 65, bottom: 130, trailing: 65))
                    .frame(width: 1346, height: 1090 * yScale).position(x: 701, y: 561 * yScale)
                    .mask {
                        Path { p in
                            p.addRect(CGRect(x: 0, y: 0, width: 1402, height: 1122 * yScale))
                            p.addRect(CGRect(x: 76, y: 130 * yScale, width: 1262, height: 868 * yScale))
                        }.fill(style: FillStyle(eoFill: true))
                    }
            }
            part("header", CGRect(x: 84, y: 51, width: 650, height: 75))
            part("trust", CGRect(x: 81, y: 134, width: 580, height: 313))
            part("left", CGRect(x: 94, y: 458, width: 540, height: 256))
            part("right", CGRect(x: 648, y: 458, width: 520, height: 217))
            part("lowerLeft", CGRect(x: 94, y: 727, width: 528, height: 263))
            part("lowerRight", CGRect(x: 648, y: 687, width: 520, height: 303))
            part("radar", CGRect(x: 1160, y: 478, width: 220, height: 240), stretch: false)
            part("rail", CGRect(x: 1185, y: 705, width: 154, height: 285))
            part("footer", CGRect(x: 86, y: 1001, width: 1241, height: 80))
            Rectangle().fill(HUD.cyan.opacity(0.45)).frame(width: 1260, height: 1).position(x: 712, y: 132 * yScale)
        }.opacity(0.95)
    }
}

private struct HUDCornerGlints: View {
    let yScale: CGFloat
    var body: some View {
        Canvas { context, _ in
            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (96, 159, 96, 210), (96, 159, 138, 159),
                (95, 681, 95, 700), (95, 700, 114, 714),
                (648, 709, 648, 750), (648, 709, 673, 688),
                (1167, 950, 1167, 971), (1167, 971, 1148, 988),
                (276, 56, 330, 56), (917, 130, 958, 130)
            ]
            var cyan = Path()
            for (x1, y1, x2, y2) in corners {
                cyan.move(to: CGPoint(x: x1, y: y1 * yScale)); cyan.addLine(to: CGPoint(x: x2, y: y2 * yScale))
            }
            var glow = context
            glow.addFilter(.shadow(color: HUD.cyan.opacity(0.85), radius: 9))
            glow.addFilter(.shadow(color: HUD.cyan.opacity(0.45), radius: 21))
            glow.stroke(cyan, with: .color(HUD.cyan), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            context.stroke(cyan, with: .color(HUD.white.opacity(0.9)), lineWidth: 1.1)
            var orange = Path()
            orange.move(to: CGPoint(x: 52, y: 493 * yScale)); orange.addLine(to: CGPoint(x: 52, y: 551 * yScale))
            orange.move(to: CGPoint(x: 720, y: 1080 * yScale)); orange.addLine(to: CGPoint(x: 810, y: 1080 * yScale))
            var warm = context; warm.addFilter(.shadow(color: HUD.orange.opacity(0.9), radius: 10))
            warm.stroke(orange, with: .color(HUD.orange), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

private struct HUDCutShape: Shape {
    var cut: CGFloat = 12
    func path(in r: CGRect) -> Path {
        let c = min(cut, min(r.width, r.height) / 3)
        return Path { p in
            p.move(to: CGPoint(x: c, y: 0)); p.addLine(to: CGPoint(x: r.width - c, y: 0))
            p.addLine(to: CGPoint(x: r.width, y: c)); p.addLine(to: CGPoint(x: r.width, y: r.height - c))
            p.addLine(to: CGPoint(x: r.width - c, y: r.height)); p.addLine(to: CGPoint(x: c, y: r.height))
            p.addLine(to: CGPoint(x: 0, y: r.height - c)); p.addLine(to: CGPoint(x: 0, y: c)); p.closeSubpath()
        }
    }
}

private struct HUDPanelTitle: View {
    let title: String
    let subtitle: String
    let icon: String
    var compact = false
    var body: some View {
        HStack(spacing: 24) {
            if !compact { Image(systemName: icon).font(.system(size: 32, weight: .medium)).foregroundColor(HUD.cyan).frame(width: 34) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(title).font(.system(size: compact ? 26 : 24, weight: .semibold))
                    if compact { Image(systemName: icon).font(.system(size: 16)).foregroundColor(HUD.cyan.opacity(0.65)) }
                }
                Text(subtitle).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(2.7).foregroundColor(HUD.muted)
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(HUD.ink)
        .overlay(alignment: .bottom) {
            if !compact { Rectangle().fill(HUD.cyan.opacity(0.22)).frame(height: 0.8) }
        }
    }
}
private struct HUDDataRow: View {
    let icon: String
    let title: String
    let value: String
    var color: Color = HUD.ink
    var mono = false
    var leadingValue = false
    var badge = false
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 23)).foregroundColor(HUD.cyan.opacity(0.8))
                .frame(width: 30).accessibilityHidden(true)
            Text(title).font(.system(size: 19)).foregroundColor(HUD.muted)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(width: leadingValue ? 190 : 132, alignment: .leading)
            Text(value).font(.system(size: 20, weight: badge ? .semibold : .medium, design: mono ? .monospaced : .default))
                .foregroundColor(HUD.status(color)).lineLimit(1).minimumScaleFactor(0.65)
                .padding(.horizontal, badge ? 9 : 0).padding(.vertical, badge ? 3 : 0)
                .background { if badge { Capsule().stroke(color.opacity(0.6), lineWidth: 0.8) } }
                .frame(maxWidth: .infinity, alignment: leadingValue ? .leading : .trailing)
                .help(value).layoutPriority(1)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.cyan.opacity(0.12)).frame(height: 0.7) }
        .accessibilityElement(children: .ignore).accessibilityLabel(title + "：" + value)
    }

}

private struct HUDScoreArc: Shape {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func path(in r: CGRect) -> Path {
        let end = -90 + 360 * Double(progress)
        return Path { p in
            // Long mechanical segments, rather than repeated short pill-shaped dashes.
            for (a, b) in [(-90.0, 25.0), (30.0, 145.0), (150.0, 265.0)] where end > a {
                let radius = min(r.width, r.height) * 0.342
                p.move(to: CGPoint(x: r.midX + cos(a * .pi / 180) * radius, y: r.midY + sin(a * .pi / 180) * radius))
                p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: radius,
                         startAngle: .degrees(a), endAngle: .degrees(min(b, end)), clockwise: false)
            }
        }
    }
}

private struct HUDTrustGauge: View {
    let d: WidgetData
    @Environment(\.hudReduceMotion) private var reduceMotion
    private var numeralColor: Color { HUD.status(scoreColor(d)) }
    var body: some View {
        ZStack {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.47
                for i in 0..<120 {
                    let a = Double(i) * .pi / 60
                    let length: CGFloat = i % 10 == 0 ? 7 : 3
                    var tick = Path()
                    tick.move(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
                    tick.addLine(to: CGPoint(x: center.x + cos(a) * (radius - length), y: center.y + sin(a) * (radius - length)))
                    context.stroke(tick, with: .color(HUD.cyan.opacity(i % 10 == 0 ? 0.65 : 0.35)), lineWidth: 0.9)
                }
                for ratio in [0.66, 0.80, 0.88, 0.96, 1.035] {
                    let r = radius * ratio
                    context.stroke(Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)),
                                   with: .color(HUD.cyan.opacity(ratio == 0.80 ? 0.5 : 0.25)), lineWidth: 0.8)
                }
                var mechanical = Path()
                mechanical.addArc(center: center, radius: radius * 0.80, startAngle: .degrees(195), endAngle: .degrees(235), clockwise: false)
                var warm = context; warm.addFilter(.shadow(color: HUD.orange.opacity(0.65), radius: 7))
                warm.stroke(mechanical, with: .color(HUD.orange), lineWidth: 8)
                for a in [-90.0, 0, 90, 180] {
                    let theta = a * .pi / 180, r = radius * 1.045
                    context.stroke(Path(ellipseIn: CGRect(x: center.x+cos(theta)*r-2, y: center.y+sin(theta)*r-2, width: 4, height: 4)), with: .color(HUD.cyan), lineWidth: 0.9)
                }
            }
            HUDScoreArc(progress: 1).stroke(HUD.cyan.opacity(0.12), lineWidth: 9)
            HUDScoreArc(progress: CGFloat(min(100, max(0, d.trustScore ?? 0))) / 100)
                .stroke(HUD.cyan, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                .shadow(color: HUD.cyan.opacity(0.55), radius: 7)
                .shadow(color: HUD.cyan.opacity(0.22), radius: 16)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.65), value: d.trustScore)
            VStack(spacing: 2) {
                Text(scoreValue(d)).font(.custom("HelveticaNeue-BoldItalic", size: 76))
                    .foregroundColor(numeralColor).shadow(color: numeralColor.opacity(0.28), radius: 9).contentTransition(.numericText())
                Text("/100").font(.custom("DINAlternate-Bold", size: 20)).foregroundColor(HUD.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("信任评分：" + scoreValue(d) + " / 100，" + d.trustLabel.text)
    }
}

// Country code comes only from the pre-existing result. Static cartographic label
// points are explicitly illustrative and never presented as city/IP coordinates.
struct HUDGlobeLocationView: View {
    let d: WidgetData
    private var countryCode: String? {
        guard d.hasClaudeIP else { return nil }
        return [d.claudeGeo?.country_code, d.risk?.countryCode, d.claudeLoc]
            .compactMap { $0?.uppercased() }.first { $0.count == 2 && flag($0) != "" }
    }
    private var country: String {
        guard d.hasClaudeIP else { return "位置未知" }
        return [d.claudeGeo?.country, d.risk?.country,
                countryCode.flatMap { Locale(identifier: "zh_Hans").localizedString(forRegionCode: $0) }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "位置未知"
    }
    private var anchor: [Double]? { countryCode.flatMap { HUD.world.countries[$0] } }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                HUDGlobeDrawing(anchor: anchor, phase: d.phase ?? "", angle: d.phaseAngle ?? 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("出口 IP 位置").font(.system(size: 20)).foregroundColor(HUD.ink.opacity(0.9))
                    HStack(alignment: .center, spacing: 12) {
                        Text(flag(countryCode)).font(.system(size: 43)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(country).font(.system(size: 26, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8)
                            Text(anchor == nil ? "无可靠位置示意" : (countryCode.flatMap { Locale(identifier: "zh_Hans").localizedString(forRegionCode: $0) } ?? country) + " · 国家级示意")
                                .font(.system(size: 16)).foregroundColor(HUD.muted)
                        }
                    }
                }
                .padding(12).frame(width: geometry.size.width * 0.39, alignment: .leading)
                .overlay(HUDCutShape(cut: 10).stroke(HUD.cyan.opacity(0.6), lineWidth: 1.2))
                .position(x: geometry.size.width * 0.625, y: geometry.size.height * 0.60)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("出口 IP 位置：" + country + (anchor == nil ? "，无可靠位置示意" : "，国家级示意点，非精确坐标"))
    }
}

private struct HUDGlobeDrawing: View {
    let anchor: [Double]?
    let phase: String
    let angle: Double
    @Environment(\.hudReduceMotion) private var reduceMotion
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.41, y: size.height * 0.60)
            // Reserve the upper-right telemetry rail; no orbit crosses its labels.
            context.clip(to: Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(CGRect(x: size.width * 0.835, y: 0, width: size.width * 0.165, height: size.height * 0.65))
                // Cut away dots/grids behind the data callout instead of placing an
                // opaque content rectangle that would turn white in vibrant mode.
                p.addRect(CGRect(x: size.width * 0.43, y: size.height * 0.60 - 68,
                                 width: size.width * 0.39, height: 136))
            }, style: FillStyle(eoFill: true))
            let radius = min(size.width * 0.32, size.height * 0.65)
            let longitude = (anchor?.last ?? 15) + 6
            let latitude = min(30, max(-25, (anchor?.first ?? 12) * 0.6))
            let camera = 4.5, roll = -0.16
            let visibleDepth = 1 / camera
            func project(_ lat: Double, _ lon: Double) -> (CGPoint, Double) {
                let p = lat * .pi / 180, l = (lon - longitude) * .pi / 180, tilt = latitude * .pi / 180
                let z = sin(tilt) * sin(p) + cos(tilt) * cos(p) * cos(l)
                let perspective = sqrt(camera * camera - 1) / (camera - z)
                let dx = cos(p) * sin(l) * perspective
                let dy = -(cos(tilt) * sin(p) - sin(tilt) * cos(p) * cos(l)) * perspective
                return (CGPoint(x: center.x + radius * (dx * cos(roll) - dy * sin(roll)),
                                y: center.y + radius * (dx * sin(roll) + dy * cos(roll))), z)
            }
            let sphere = CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2)
            let orbitCenter = CGPoint(x: center.x + 50, y: center.y + radius * 0.27)
            func orbital(_ a: Double, _ ratio: Double) -> CGPoint {
                let rx = radius * ratio, ry = radius * (0.27 + (ratio - 1.18) * 0.25)
                let dx = cos(a) * rx, dy = sin(a) * ry, tilt = 0.20
                return CGPoint(x: orbitCenter.x + dx*cos(tilt)-dy*sin(tilt), y: orbitCenter.y + dx*sin(tilt)+dy*cos(tilt))
            }
            func orbitPath(_ start: Int, _ end: Int, _ ratio: Double) -> Path {
                Path { path in
                    for degree in stride(from: start, through: end, by: 2) {
                        let point = orbital(Double(degree) * .pi / 180, ratio)
                        if degree == start { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
            }
            func bandPath(_ start: Int, _ end: Int, _ inner: Double, _ outer: Double) -> Path {
                Path { path in
                    for degree in stride(from: start, through: end, by: 2) {
                        let point = orbital(Double(degree) * .pi / 180, outer)
                        if degree == start { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    for degree in stride(from: end, through: start, by: -2) {
                        path.addLine(to: orbital(Double(degree) * .pi / 180, inner))
                    }
                    path.closeSubpath()
                }
            }
            // Independent polar and diagonal planes make the hologram spatial, rather
            // than repeating the same equatorial ellipse at slightly different radii.
            func multiPoint(_ degree: Double, _ plane: Int) -> CGPoint {
                let a = degree * .pi / 180
                let rx = radius * (plane == 0 ? 0.76 : 1.22)
                let ry = radius * (plane == 0 ? 1.13 : 0.40)
                let tilt = plane == 0 ? -0.56 : -0.78
                let dx = cos(a)*rx, dy = sin(a)*ry
                return CGPoint(x: center.x+dx*cos(tilt)-dy*sin(tilt), y: center.y+dx*sin(tilt)+dy*cos(tilt))
            }
            func multiPath(_ start: Int, _ end: Int, _ plane: Int) -> Path {
                Path { path in
                    for degree in stride(from: start, through: end, by: 2) {
                        let point = multiPoint(Double(degree), plane)
                        if degree == start { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
            }
            // The back half is painted first so the earth naturally occludes it.
            var behind = context
            behind.clip(to: Path { p in p.addRect(CGRect(origin: .zero, size: size)); p.addEllipse(in: sphere) }, style: FillStyle(eoFill: true))
            for ratio in [1.30, 1.38, 1.46, 1.54] {
                behind.stroke(orbitPath(180, 360, ratio), with: .color(HUD.cyan.opacity(0.19)), lineWidth: 0.9)
            }
            for plane in 0..<2 {
                behind.stroke(multiPath(180, 360, plane), with: .color(Color(red: 0, green: 0.55, blue: 0.85).opacity(plane == 0 ? 0.40 : 0.30)), lineWidth: 1.0)
            }
            var surface = context
            surface.clip(to: Path(ellipseIn: sphere))
            func grid(_ coordinates: [(Double, Double)]) {
                var path = Path(), visible = false
                for (lat, lon) in coordinates {
                    let (point, z) = project(lat, lon)
                    if z > visibleDepth {
                        if visible { path.addLine(to: point) } else { path.move(to: point) }; visible = true
                    } else { visible = false }
                }
                surface.stroke(path, with: .color(HUD.cyan.opacity(0.17)), lineWidth: 0.65)
            }
            for lat in stride(from: -75, through: 75, by: 15) {
                grid(stride(from: -180, through: 180, by: 3).map { (Double(lat), Double($0)) })
            }
            for lon in stride(from: -180, to: 180, by: 15) {
                grid(stride(from: -90, through: 90, by: 3).map { (Double($0), Double(lon)) })
            }
            // Deterministic sub-degree jitter and luminance avoid a flat rectangular dot
            // lattice. It changes only decorative land samples, never the location marker.
            for (index, dot) in HUD.world.land.enumerated() where dot.count == 2 {
                let noise = Double((index * 73 + 19) % 101) / 100
                let jitter = (noise - 0.5) * 0.65
                let (p, z) = project(dot[0]+jitter, dot[1]-jitter*0.7)
                guard z > visibleDepth else { continue }
                let r = 0.45 + noise*0.55 + z*0.25
                let opacity = (0.25 + z*0.56) * (0.65 + noise*0.35)
                surface.fill(Path(ellipseIn: CGRect(x: p.x-r, y: p.y-r, width: r*2, height: r*2)), with: .color(HUD.cyan.opacity(opacity)))
                if index % 53 == 0 && z > 0.45 {
                    surface.fill(Path(ellipseIn: CGRect(x: p.x-1.2, y: p.y-1.2, width: 2.4, height: 2.4)), with: .color(HUD.white.opacity(0.65)))
                }
            }
            var halo = context
            halo.addFilter(.shadow(color: HUD.cyan.opacity(0.6), radius: 9))
            halo.stroke(Path(ellipseIn: sphere), with: .color(HUD.cyan.opacity(0.36)), lineWidth: 1.3)
            for (start, end) in [(-74.0, -44.0), (-35.0, 10.0), (142.0, 174.0)] {
                var rim = Path(); rim.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
                halo.stroke(rim, with: .color(HUD.cyan.opacity(0.85)), lineWidth: 3)
                context.stroke(rim, with: .color(HUD.white.opacity(0.55)), lineWidth: 0.8)
            }
            // A shallow, solid orbital band: concentric tracks, radial cells and
            // short glints form the reference's mechanical plate rather than wire loops.
            // Mechanical face and a lower bevel establish depth while the spaces
            // between the concentric tracks remain open.
            context.fill(bandPath(0, 180, 1.32, 1.50), with: .linearGradient(
                Gradient(colors: [Color(red: 0.01, green: 0.06, blue: 0.09).opacity(0.75),
                                  Color(red: 0.02, green: 0.15, blue: 0.21).opacity(0.30), HUD.navy.opacity(0.65)]),
                startPoint: CGPoint(x: orbitCenter.x, y: orbitCenter.y),
                endPoint: CGPoint(x: orbitCenter.x, y: orbitCenter.y + radius * 0.4)))
            var lowerBevel = context
            lowerBevel.translateBy(x: 0, y: 5)
            lowerBevel.stroke(orbitPath(4, 176, 1.54), with: .color(HUD.cyan.opacity(0.23)), lineWidth: 1.5)
            lowerBevel.stroke(orbitPath(12, 169, 1.32), with: .color(HUD.cyan.opacity(0.14)), lineWidth: 1)
            for ratio in [1.30, 1.35, 1.40, 1.46, 1.54] {
                context.stroke(orbitPath(0, 180, ratio), with: .color(HUD.cyan.opacity(ratio == 1.30 || ratio == 1.54 ? 0.55 : 0.22)), lineWidth: 0.9)
            }
            for degree in stride(from: 2, through: 178, by: 3) {
                let a = Double(degree) * .pi / 180
                var cell = Path(); cell.move(to: orbital(a, degree % 15 == 2 ? 1.34 : 1.42)); cell.addLine(to: orbital(a, 1.50))
                context.stroke(cell, with: .color(HUD.cyan.opacity(degree % 15 == 2 ? 0.45 : 0.18)), lineWidth: 0.9)
            }
            for (start, end) in [(9, 16), (112, 123), (138, 145)] {
                context.fill(bandPath(start, end, 1.37, 1.44), with: .color(HUD.orange.opacity(0.78)))
                for degree in stride(from: start, through: end, by: 3) {
                    let a = Double(degree) * .pi / 180
                    var tick = Path(); tick.move(to: orbital(a, 1.35)); tick.addLine(to: orbital(a, 1.47))
                    context.stroke(tick, with: .color(HUD.orange.opacity(0.9)), lineWidth: 1.3)
                }
            }
            for plane in 0..<2 {
                context.stroke(multiPath(0, 180, plane), with: .color(Color(red: 0, green: plane == 0 ? 0.55 : 0.68, blue: plane == 0 ? 0.85 : 0.78).opacity(plane == 0 ? 0.76 : 0.65)), lineWidth: 1.4)
                for degree in stride(from: 12, through: 168, by: 24) {
                    let point = multiPoint(Double(degree), plane)
                    context.stroke(Path(ellipseIn: CGRect(x: point.x-3, y: point.y-3, width: 6, height: 6)),
                                   with: .color(degree % 48 == 12 ? HUD.orange.opacity(0.8) : HUD.cyan.opacity(0.65)), lineWidth: 1)
                }
                var planeGlow = context; planeGlow.addFilter(.shadow(color: HUD.cyan.opacity(0.5), radius: 5))
                planeGlow.stroke(multiPath(plane == 0 ? 48 : 118, plane == 0 ? 63 : 133, plane), with: .color(HUD.cyan.opacity(0.9)), lineWidth: 2.1)
            }
            var orbitalGlow = context; orbitalGlow.addFilter(.shadow(color: HUD.cyan.opacity(0.6), radius: 6))
            orbitalGlow.stroke(orbitPath(28, 39, 1.54), with: .color(HUD.cyan), lineWidth: 2.8)
            orbitalGlow.stroke(orbitPath(157, 164, 1.30), with: .color(HUD.cyan), lineWidth: 2)
            var blueArc = Path()
            blueArc.addArc(center: center, radius: radius * 1.09, startAngle: .degrees(-123), endAngle: .degrees(-36), clockwise: false)
            context.stroke(blueArc, with: .color(HUD.cyan.opacity(0.25)), lineWidth: 0.9)
            for degree in stride(from: -119, through: -39, by: 4) {
                let a = Double(degree) * .pi / 180
                var tick = Path()
                tick.move(to: CGPoint(x: center.x+cos(a)*radius*1.07, y: center.y+sin(a)*radius*1.07))
                tick.addLine(to: CGPoint(x: center.x+cos(a)*radius*1.09, y: center.y+sin(a)*radius*1.09))
                context.stroke(tick, with: .color(HUD.cyan.opacity(0.33)), lineWidth: 0.8)
            }
            var starGlow = context; starGlow.addFilter(.shadow(color: HUD.cyan.opacity(0.8), radius: 6))
            for degree in [-68.0, -42, 12, 157] {
                let a = degree * .pi / 180
                let point = CGPoint(x: center.x+cos(a)*radius, y: center.y+sin(a)*radius)
                var star = Path()
                star.move(to: CGPoint(x: point.x-8, y: point.y)); star.addLine(to: CGPoint(x: point.x+8, y: point.y))
                star.move(to: CGPoint(x: point.x, y: point.y-5)); star.addLine(to: CGPoint(x: point.x, y: point.y+5))
                starGlow.stroke(star, with: .color(HUD.cyan.opacity(0.85)), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: point.x-1.5, y: point.y-1.5, width: 3, height: 3)), with: .color(HUD.white))
            }
            for radiusRatio in [1.07, 1.12] {
                var outer = Path(); outer.addArc(center: center, radius: radius*radiusRatio, startAngle: .degrees(165), endAngle: .degrees(244), clockwise: false)
                context.stroke(outer, with: .color(HUD.cyan.opacity(0.22)), lineWidth: 0.8)
            }
            for degree in stride(from: 183, through: 222, by: 3) {
                let a = Double(degree)*Double.pi/180
                var tick = Path()
                tick.move(to: CGPoint(x: center.x+cos(a)*radius*1.075, y: center.y+sin(a)*radius*1.075))
                tick.addLine(to: CGPoint(x: center.x+cos(a)*radius*1.105, y: center.y+sin(a)*radius*1.105))
                context.stroke(tick, with: .color(HUD.orange.opacity(0.75)), lineWidth: 1.4)
            }
            if phase == "loading" && !reduceMotion {
                let y = sphere.minY + (sin(angle * .pi / 180)+1) * radius
                let dx = sqrt(max(0, radius*radius-(y-center.y)*(y-center.y)))
                var scan = Path(); scan.move(to: CGPoint(x: center.x-dx, y: y)); scan.addLine(to: CGPoint(x: center.x+dx, y: y))
                context.stroke(scan, with: .color(HUD.cyan.opacity(0.5)), lineWidth: 1.3)
            }
            if let a = anchor, a.count == 2 {
                let (point, z) = project(a[0], a[1])
                if z > visibleDepth {
                    var leader = Path(); leader.move(to: point)
                    leader.addLine(to: CGPoint(x: point.x+32, y: point.y+17))
                    leader.addLine(to: CGPoint(x: size.width*0.435, y: size.height*0.60))
                    context.stroke(leader, with: .color(HUD.orange.opacity(0.9)), lineWidth: 1.5)
                    context.fill(Path(ellipseIn: CGRect(x: point.x-47, y: point.y-47, width: 94, height: 94)),
                                 with: .radialGradient(Gradient(colors: [HUD.orange.opacity(0.35), .clear]), center: point, startRadius: 7, endRadius: 47))
                    for r: CGFloat in [34, 26, 19] {
                        context.stroke(Path(ellipseIn: CGRect(x: point.x-r, y: point.y-r, width: r*2, height: r*2)),
                                       with: .color(HUD.orange.opacity(r == 34 ? 0.45 : 0.85)), lineWidth: r == 26 ? 2 : 1)
                    }
                    var pin = Path()
                    pin.move(to: CGPoint(x: point.x, y: point.y+17))
                    pin.addQuadCurve(to: CGPoint(x: point.x-11, y: point.y-4), control: CGPoint(x: point.x-11, y: point.y+2))
                    pin.addCurve(to: CGPoint(x: point.x+11, y: point.y-4), control1: CGPoint(x: point.x-11, y: point.y-19), control2: CGPoint(x: point.x+11, y: point.y-19))
                    pin.addQuadCurve(to: CGPoint(x: point.x, y: point.y+17), control: CGPoint(x: point.x+11, y: point.y+2))
                    var beacon = context; beacon.addFilter(.shadow(color: HUD.orange.opacity(0.85), radius: 6))
                    beacon.fill(pin, with: .color(HUD.white))
                }
            }
        }.clipped()
    }
}

private struct HUDRadar: View {
    @Environment(\.widgetPhase) private var phase
    @Environment(\.widgetPulse) private var pulse
    @Environment(\.hudReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if phase == "loading" && !reduceMotion {
                Circle().trim(from: 0, to: 0.22)
                    .stroke(AngularGradient(colors: [.clear, HUD.cyan.opacity(0.8)], center: .center), lineWidth: 3)
                    .rotationEffect(.degrees(pulse))
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
