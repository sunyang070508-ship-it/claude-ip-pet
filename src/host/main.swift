import AppKit
import WidgetKit

// 组件宿主：无窗口、无 Dock 图标，只在组件点按“重新检测/显示IP”时静默运行
let HOST_LOG = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/ClaudeIPWidgetHost.log")
private let hostLogLock = NSLock()

func hlog(_ msg: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + " " + msg + "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
        hostLogLock.lock()
        defer { hostLogLock.unlock() }
        if let h = try? FileHandle(forWritingTo: HOST_LOG) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: HOST_LOG)
        }
    }
}

func widgetTmpDir() -> URL? {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/coffee.net.claude-ip-pet.widget/Data/tmp", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
}

func sharedWrite(_ name: String, _ value: String) {
    guard let dir = widgetTmpDir() else { hlog("shared dir missing"); return }
    do { try value.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    catch { hlog("shared write failed: \(error.localizedDescription)") }
}

func sharedRead(_ name: String) -> String? {
    guard let dir = widgetTmpDir() else { return nil }
    return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
}

func reloadWidget() {
    WidgetCenter.shared.reloadAllTimelines()
}

final class HostDelegate: NSObject, NSApplicationDelegate {
    private var spinTimer: Timer?
    private var spinAngle = 0
    private var gotURL = false
    private var finished = false
    private var waitingForFinalWave = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        hlog("host launched pid=\(getpid())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if !self.gotURL {
                hlog("no url -> quit")
                NSApp.terminate(nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        gotURL = true
        for u in urls {
            hlog("open url \(u.absoluteString)")
            switch (u.host ?? "").lowercased() {
            case "refresh": performRefresh()
            case "toggleip": performToggle()
            default: break
            }
        }
    }

    private func performToggle() {
        let newValue = (sharedRead("claudeipet-showip") ?? "0").trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "0" : "1"
        sharedWrite("claudeipet-showip", newValue)
        reloadWidget()
        hlog("toggleip -> show=\(newValue)")
        finish(after: 0.8)
    }

    private func performRefresh() {
        guard !finished else { return }
        let presentationStart = ProcessInfo.processInfo.systemUptime
        sharedWrite(WidgetRefreshPresentation.elapsedFile, "0")
        sharedWrite("claudeipet-phase", "loading")
        sharedWrite("claudeipet-phase-angle", "0")
        spinAngle = 0
        reloadWidget()
        spinTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.spinAngle = (self.spinAngle + 24) % 360
            sharedWrite("claudeipet-phase-angle", String(self.spinAngle))
            sharedWrite(WidgetRefreshPresentation.elapsedFile, String(ProcessInfo.processInfo.systemUptime - presentationStart))
            reloadWidget()
        }
        hlog("refresh start")
        Task { @MainActor in
            let data = await WidgetService.fetchAll()
            // The request has finished. Keep the previous displayed snapshot
            // until the wave already on screen has completed its outward pass.
            self.waitingForFinalWave = true
            let arrived = ProcessInfo.processInfo.systemUptime - presentationStart
            let boundary = WidgetRefreshPresentation.finishElapsed(after: arrived)
            let delay = max(0, boundary - arrived)
            hlog("presentation result ready elapsed=\(arrived) waveBoundary=\(boundary)")
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            self.spinTimer?.invalidate()
            self.spinTimer = nil
            sharedWrite(WidgetRefreshPresentation.elapsedFile, String(boundary))
            reloadWidget()
            try? await Task.sleep(nanoseconds: UInt64(WidgetRefreshPresentation.finalFrameHold * 1_000_000_000))
            hlog("presentation wave finished -> publish elapsed=\(ProcessInfo.processInfo.systemUptime - presentationStart)")
            if let encoded = try? JSONEncoder().encode(data), let dir = widgetTmpDir() {
                do {
                    try encoded.write(to: dir.appendingPathComponent("claudeipet-data.json"), options: .atomic)
                } catch {
                    hlog("snapshot write failed: \(error.localizedDescription)")
                }
            }
            sharedWrite("claudeipet-phase", "done")
            reloadWidget()
            hlog("refresh done -> done phase")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                sharedWrite("claudeipet-phase", "idle")
                sharedWrite(WidgetRefreshPresentation.elapsedFile, "0")
                reloadWidget()
                hlog("refresh done -> idle")
                self.finish(after: 0.8)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, !self.finished, !self.waitingForFinalWave else { return }
            self.spinTimer?.invalidate()
            sharedWrite("claudeipet-phase", "idle")
            sharedWrite(WidgetRefreshPresentation.elapsedFile, "0")
            reloadWidget()
            hlog("refresh timeout -> idle")
            self.finish(after: 0.5)
        }
    }

    private func finish(after delay: Double) {
        guard !finished else { return }
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            hlog("host quit")
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = HostDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
