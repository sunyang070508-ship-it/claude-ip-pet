import SwiftUI
import AppKit
import CoreImage

enum WidgetControlState: Equatable {
    case help, ready, loading, failed
}

struct WidgetControlGlyph: View {
    let state: WidgetControlState
    let angle: Double
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let diameter = side * 0.94
            let plateWidth = geometry.size.width * 0.94
            let lineWidth = max(0.8, diameter * 0.055)
            let color = state == .failed ? GlassPalette.semantic(dangerColor) : GlassPalette.blue
            let lowerTint = state == .failed
                ? Color(red: 0.99, green: 0.89, blue: 0.91)
                : Color(red: 0.74, green: 0.88, blue: 0.97)
            ZStack {
                Capsule().fill(LinearGradient(colors: [.white, Color(red: 0.94, green: 0.98, blue: 1), lowerTint],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Capsule().stroke(LinearGradient(colors: [.white, color.opacity(0.20), color.opacity(0.32)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: lineWidth)
                Group {
                    if state == .loading {
                        ZStack {
                            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
                                .padding(diameter * 0.18)
                            Circle().trim(from: 0.08, to: 0.78)
                                .stroke(GlassPalette.blue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                                .rotationEffect(.degrees(angle * 2))
                                .padding(diameter * 0.18)
                        }
                    } else {
                        Image(systemName: state == .help ? "questionmark" : state == .failed ? "xmark" : "arrow.clockwise")
                            .font(.system(size: side * (state == .help ? 0.50 : 0.53), weight: .semibold))
                    }
                }.frame(width: diameter, height: diameter)
            }.foregroundColor(color).frame(width: plateWidth, height: diameter)
                .shadow(color: GlassPalette.blue.opacity(0.10), radius: side * 0.06, x: 0, y: side * 0.035)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }.accessibilityHidden(true)
    }
}

// A broad, low-amplitude radial displacement of the in-memory presentation.
// The neutral displacement field leaves text in place outside the soft wave.
@MainActor
enum WidgetRippleRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func image(_ source: NSImage, origin: UnitPoint, progress: Double?) -> NSImage {
        guard let progress, progress > 0.001, progress < 0.999,
              let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return source }
        let extent = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let center = CGPoint(x: extent.width * origin.x, y: extent.height * (1 - origin.y))
        let reach = [CGPoint.zero, CGPoint(x: extent.maxX, y: 0),
                     CGPoint(x: 0, y: extent.maxY), CGPoint(x: extent.maxX, y: extent.maxY)]
            .map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? extent.height
        let width = extent.width * 0.10
        let radius = progress * (reach + width * 2.5)
        var pixels = [UInt8](repeating: 128, count: cg.width * cg.height * 4)
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                // CGImage bitmap rows run from the top; Core Image's vector
                // field and displacement Y axis run from the bottom.
                let dx = Double(x) - center.x, dy = Double(cg.height - 1 - y) - center.y
                let distance = hypot(dx, dy)
                let normalized = (distance - radius) / width
                let wave = abs(normalized) < 2.5
                    ? sin(normalized * .pi) * exp(-normalized * normalized * 1.6) : 0
                let unit = max(1, distance)
                let index = (y * cg.width + x) * 4
                pixels[index] = UInt8(clamping: Int(128 + dx / unit * wave * 110))
                pixels[index + 1] = UInt8(clamping: Int(128 + dy / unit * wave * 110))
                pixels[index + 2] = 128
                pixels[index + 3] = 255
            }
        }
        let bytes = Data(pixels)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let field = CGImage(width: cg.width, height: cg.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return source }
        let input = CIImage(cgImage: cg).clampedToExtent()
        let output = input.applyingFilter("CIDisplacementDistortion", parameters: [
            "inputDisplacementImage": CIImage(cgImage: field),
            kCIInputScaleKey: extent.width / 360 * 2.4
        ]).cropped(to: extent)
        guard let result = context.createCGImage(output, from: extent) else { return source }
        return NSImage(cgImage: result, size: source.size)
    }
}

struct WidgetRippleSurface: View {
    let origin: UnitPoint
    let progress: Double
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * origin.x, y: size.height * origin.y)
            let reach = [CGPoint.zero, CGPoint(x: size.width, y: 0),
                         CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
                .map { hypot($0.x - center.x, $0.y - center.y) }.max() ?? size.height
            let radius = progress * (reach + size.width * 0.25)
            let fade = sin(.pi * min(1, max(0, progress)))
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.addFilter(.blur(radius: size.width * 0.014))
            context.stroke(ring, with: .color(Color.white.opacity(fade * 0.13)), lineWidth: size.width * 0.08)
            context.stroke(ring, with: .color(Color(red: 0.12, green: 0.61, blue: 0.78).opacity(fade * 0.025)), lineWidth: size.width * 0.10)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct WidgetCircuitBorder: View {
    let radius: CGFloat
    let angle: Double
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .circular)
            .strokeBorder(AngularGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.25),
                .init(color: Color.cyan.opacity(0.40), location: 0.43),
                .init(color: Color(red: 0.04, green: 0.56, blue: 0.82), location: 0.60),
                .init(color: Color(red: 0.08, green: 0.76, blue: 0.80), location: 0.72),
                .init(color: .clear, location: 0.96),
                .init(color: .clear, location: 1)
            ], center: .center, angle: .degrees(angle)), lineWidth: 4.0)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
