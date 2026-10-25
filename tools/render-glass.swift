import SwiftUI
import AppKit

// Offline presentation fixtures. Synthetic data by default; --live is local-only.
// Not compiled into either shipped app.
@main struct GlassRender {
    @MainActor static func main() {
        _ = NSApplication.shared
        let destination = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "/tmp/claude-glass-validation"
        try? FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let sample = WidgetData.sample
        let cached = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/coffee.net.claude-ip-pet.widget/Data/tmp/claudeipet-data.json")
        let live = CommandLine.arguments.contains("--live")
            ? (try? Data(contentsOf: cached)).flatMap { try? JSONDecoder().decode(WidgetData.self, from: $0) } ?? sample
            : sample
        render(live, name: "widget-large", width: 720, height: 740, output: destination)
        render(live, name: "widget-large-actual-size", width: 360, height: 360, output: destination)
        var loading = live; loading.phase = "loading"; loading.phaseAngle = 120
        render(loading, name: "widget-loading", width: 360, height: 360, output: destination, presentationElapsed: 0.65)
        render(mutated(sample, score: 40), name: "widget-low-40", width: 360, height: 360, output: destination)
        render(mutated(sample, score: 95), name: "widget-high-95", width: 360, height: 360, output: destination)
        render(mutated(sample, score: 86, country: "CN"), name: "widget-restricted", width: 360, height: 360, output: destination)
        render(WidgetData(), name: "widget-failed", width: 360, height: 360, output: destination)
        var retry = WidgetData(); retry.phase = "loading"; retry.phaseAngle = 120
        render(retry, name: "widget-retry-loading", width: 360, height: 360, output: destination, presentationElapsed: 0.65)
        // Preserve only the decorative globe orientation, as requested. Every
        // displayed score, IP, location label, service and device value differs.
        var alternate = WidgetData(); alternate.phase = "loading"; alternate.phaseAngle = 120
        alternate.claudeIP = "198.51.100.200"
        alternate.claudeLoc = loading.risk?.countryCode ?? loading.claudeGeo?.country_code ?? loading.claudeLoc
        alternate.updatedAt = Date(timeIntervalSince1970: 0)
        render(alternate, name: "widget-loading-alternate-data", width: 360, height: 360, output: destination, presentationElapsed: 0.65)
        var unknown = sample; unknown.risk = nil; unknown.geo = [:]; unknown.claudeLoc = nil
        render(unknown, name: "widget-unknown", width: 360, height: 360, output: destination)
        renderCompact(SmallView(d: live), width: 170, height: 170, name: "widget-small", output: destination)
        renderCompact(MediumView(d: live), width: 360, height: 170, name: "widget-medium", output: destination)
        renderCompact(SmallView(d: loading), width: 170, height: 170, name: "widget-small-loading", output: destination)
        renderCompact(MediumView(d: loading), width: 360, height: 170, name: "widget-medium-loading", output: destination)
        for kind in [WebRTCUDPStatus.Kind.ok, .leak, .disabled, .noPublic, .unavailable] {
            var fixture = sample; fixture.udp = WebRTCUDPStatus(kind: kind)
            render(fixture, name: "widget-udp-" + kind.rawValue, width: 360, height: 360, output: destination)
        }
        var udpLegacy = sample; udpLegacy.udp = nil
        render(udpLegacy, name: "widget-udp-legacy", width: 360, height: 360, output: destination)
        let pending = try! Data(contentsOf: URL(fileURLWithPath: destination).appendingPathComponent("widget-loading.png"))
        let retryPending = try! Data(contentsOf: URL(fileURLWithPath: destination).appendingPathComponent("widget-loading-alternate-data.png"))
        let (maxDelta, meanDelta) = pixelDelta(pending, retryPending)
        // Native gradient dithering and edge interpolation are not bit-exact.
        // A tiny mean plus an edge ceiling still catches any stale text/value.
        precondition(maxDelta <= 8 && meanDelta < 0.05, "Loading presentation must be independent of cached data")
        print("PASS loading with different scores/IPs/services/device data matches within raster rounding; original globe orientation retained; max channel delta=\(maxDelta)/255, mean=\(meanDelta)/255")
        print("Control layout: help=\(LiquidGlassCanvas.helpCenter), refresh=\(LiquidGlassCanvas.refreshCenter), width=\(LiquidGlassCanvas.refreshWidth)")
        if CommandLine.arguments.contains("--motion") {
            // Twelve seconds is a common cycle of the 2.4 s wave and 6 s
            // border, so the preview loops without a false reset jump.
            for index in 0..<30 {
                let elapsed = Double(index) * 0.4
                var frame = live; frame.phase = "loading"; frame.phaseAngle = elapsed * 60
                render(frame, name: String(format: "motion-%03d", index), width: 360, height: 360,
                       output: destination, presentationElapsed: elapsed)
            }
        }
        print("Rendered 20 presentation states using original WidgetData and risk helpers")
    }
    static func mutated(_ sample: WidgetData, score: Int, country: String? = nil) -> WidgetData {
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as! [String: Any]
        var risk = object["risk"] as! [String: Any]; risk["trust_score"] = score
        if let country { risk["countryCode"] = country; risk["country"] = "中国"; object["claudeLoc"] = country.lowercased() }
        object["risk"] = risk
        return try! JSONDecoder().decode(WidgetData.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func pixelDelta(_ first: Data, _ second: Data) -> (Int, Double) {
        let a = NSBitmapImageRep(data: first)!, b = NSBitmapImageRep(data: second)!
        precondition(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh)
        // Compare displayed colors. Straight-alpha RGB at nearly transparent
        // curved edges can differ greatly while compositing to the same pixel.
        func displayedPixels(_ bitmap: NSBitmapImageRep) -> [UInt8] {
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return pixels
        }
        let left = displayedPixels(a), right = displayedPixels(b)
        let deltas = zip(left, right).map { abs(Int($0) - Int($1)) }
        return (deltas.max() ?? 0, Double(deltas.reduce(0, +)) / Double(left.count))
    }
    @MainActor static func render(_ d: WidgetData, name: String, width: CGFloat, height: CGFloat, output: String, presentationElapsed: Double? = nil) {
        let content = ZStack {
            LiquidGlassWidgetBackground()
            LiquidGlassCanvas(d: d, presentationElapsed: presentationElapsed)
        }.frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: WidgetSurfaceMetrics.outerRadius * width / WidgetSurfaceMetrics.designWidth, style: .circular))
        save(content, name: name, output: output)
    }
    @MainActor static func renderCompact<C: View>(_ view: C, width: CGFloat, height: CGFloat, name: String, output: String) {
        let content = view.environment(\.widgetPreview, true).padding(16).frame(width: width, height: height)
            .background(LiquidGlassWidgetBackground()).environment(\.colorScheme, .light)
        save(content, name: name, output: output)
    }
    @MainActor static func save<C: View>(_ view: C, name: String, output: String) {
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        guard let image = renderer.nsImage, let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else {
            print("FAIL \(name)"); return
        }
        try! png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        print("PASS \(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }
}
