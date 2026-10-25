import Foundation

@main struct PresentationTimingAudit {
    static func main() throws {
        var cases: [[String: Double]] = []
        for elapsed in [0, 0.05, 0.4, 0.8, 1.59, 1.6, 1.8, 2.39, 2.4, 2.8, 3.95, 4.0, 6.5, 59.99, 60.0] {
            let finish = WidgetRefreshPresentation.finishElapsed(after: elapsed)
            precondition(finish >= elapsed)
            precondition(finish - elapsed <= WidgetRefreshPresentation.waveDuration + 0.000_001)
            precondition(WidgetRefreshPresentation.waveProgress(at: finish) == nil)
            cases.append(["resultReady": elapsed, "lastWaveFinished": finish,
                          "displayAtEarliest": finish + WidgetRefreshPresentation.finalFrameHold])
        }
        for index in 0...60_000 {
            let elapsed = Double(index) / 1000
            let finish = WidgetRefreshPresentation.finishElapsed(after: elapsed)
            precondition(finish >= elapsed - 0.000_001)
            precondition(WidgetRefreshPresentation.waveProgress(at: finish) == nil)
        }
        precondition(WidgetRefreshPresentation.waveProgress(at: 0.8) == 0.5)
        precondition(WidgetRefreshPresentation.waveProgress(at: 2.0) == nil)
        precondition(abs(WidgetRefreshPresentation.waveProgress(at: 3.2)! - 0.5) < 0.000_001)
        let bytes = try JSONSerialization.data(withJSONObject: cases, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: 15 boundary cases and 60,001 sampled completion times; no result is revealed before its final wave finishes")
    }
}
