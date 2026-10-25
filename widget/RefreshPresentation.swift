import Foundation

// Display timing only. No requests, retries, data transforms or score rules.
enum WidgetRefreshPresentation {
    static let waveDuration = 1.6
    static let waveInterval = 2.4
    static let finalFrameHold = 0.2
    static let elapsedFile = "claudeipet-presentation-elapsed"

    static func waveProgress(at elapsed: Double) -> Double? {
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: waveInterval)
        guard phase < waveDuration - 0.000_001 else { return nil }
        return phase / waveDuration
    }

    static func finishElapsed(after elapsed: Double) -> Double {
        let elapsed = max(0, elapsed)
        let cycle = floor(elapsed / waveInterval) * waveInterval
        return waveProgress(at: elapsed) == nil ? elapsed : cycle + waveDuration
    }

    static var sharedElapsed: Double {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true).appendingPathComponent(elapsedFile)
        return (try? String(contentsOf: url, encoding: .utf8)).flatMap(Double.init) ?? 0
    }
}
