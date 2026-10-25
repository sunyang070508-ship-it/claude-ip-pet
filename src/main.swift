import AppKit
import WebKit
import Network

// 固定窗口布局：窗口坐标原点在左下角，与 CSS 的 bottom/right 对应
let WIN_W: CGFloat = 860
let WIN_H: CGFloat = 790
let COLLAPSED_SIZE = NSSize(width: 176, height: 176)
let MENU_SIZE = NSSize(width: 224, height: 380)
let PET_RECT = NSRect(x: WIN_W - 124, y: 8, width: 116, height: 112)      // 桌宠热区
let HEADER_DRAG_RECT = NSRect(x: 12, y: WIN_H - 78, width: WIN_W - 360, height: 58) // 展开后标题栏拖拽区
// Normalized HUD silhouette, shared with #panel's clip-path in jarvis.css.
let HUD_OUTLINE: [NSPoint] = [
    NSPoint(x: 0.030, y: 0.016), NSPoint(x: 0.953, y: 0.016), NSPoint(x: 0.985, y: 0.054),
    NSPoint(x: 0.985, y: 0.310), NSPoint(x: 1.000, y: 0.340), NSPoint(x: 1.000, y: 0.410),
    NSPoint(x: 0.987, y: 0.440), NSPoint(x: 0.987, y: 0.858), NSPoint(x: 0.993, y: 0.872),
    NSPoint(x: 0.993, y: 0.928), NSPoint(x: 0.955, y: 0.977), NSPoint(x: 0.035, y: 0.977),
    NSPoint(x: 0.004, y: 0.942), NSPoint(x: 0.004, y: 0.869), NSPoint(x: 0.018, y: 0.851),
    NSPoint(x: 0.018, y: 0.140), NSPoint(x: 0.004, y: 0.129), NSPoint(x: 0.004, y: 0.050)
]
let POS_KEY = "pet.window.origin"
let REOPEN_NOTIFICATION = "coffee.net.claude-ip-pet.reopen"

// MARK: - 日志（同时写 stderr 与 ~/Library/Logs/ClaudeIPPet.log）
let LOG_URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/ClaudeIPPet.log")
private let logLock = NSLock()

func log(_ msg: String) {
    let line = ISO8601DateFormatter().string(from: Date()) + " " + msg + "\n"
    if let data = line.data(using: .utf8) {
        FileHandle.standardError.write(data)
        logLock.lock()
        defer { logLock.unlock() }
        if let h = try? FileHandle(forWritingTo: LOG_URL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: LOG_URL)
        }
    }
}

// 未捕获的 Objective-C 异常也留档（真正崩溃时 macOS 的 .ips 若缺失还能看到栈）
func installExceptionLogger() {
    NSSetUncaughtExceptionHandler { ex in
        log("UNCAUGHT EXCEPTION \(ex.name.rawValue): \(ex.reason ?? "?")")
        for frame in ex.callStackSymbols.prefix(25) { log("  " + frame) }
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // The visible pet is clamped explicitly. AppKit must not clamp the invisible
    // expanded canvas when the user drags the collapsed pet near a screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func accessibilityFrame() -> NSRect { frame }
    override func setAccessibilityFrame(_ value: NSRect) { setFrame(value, display: true) }
}

final class ClearPetContentView: NSView {
    override var isOpaque: Bool { false }
}

// MARK: - JS <-> 原生桥
final class Bridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var app: AppDelegate?
    private let store = UserDefaults.standard
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()
    private let allowedHosts: Set<String> = [
        "ip.net.coffee", "1.1.1.1", "claude.ai", "www.anthropic.com", "2026.ip138.com", "my.ip.cn"
    ]

    private func hostAllowed(_ host: String) -> Bool {
        let h = host.lowercased()
        return allowedHosts.contains(h) || h.hasSuffix(".d.ip.net.coffee")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "api":   handleAPI(body)
        case "store": handleStore(body)
        case "app":   handleApp(body)
        default: break
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var js = String(data: data, encoding: .utf8) else { return }
        // 避免 U+2028/2029 破坏 JS 字面量
        js = js.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        js = js.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("window.__bridgeResult(\(js));", completionHandler: nil)
        }
    }

    private func handleAPI(_ body: [String: Any]) {
        let id = body["id"] as? Int ?? 0
        guard let urlStr = body["url"] as? String,
              let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, hostAllowed(host) else {
            send(["cmd": "api", "id": id, "ok": false, "status": 0, "text": "", "error": "blocked_url"])
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = (body["method"] as? String)?.uppercased() ?? "GET"
        let timeoutMs = body["timeout"] as? Int ?? 10000
        req.timeoutInterval = max(1.0, Double(timeoutMs) / 1000.0)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let s = body["body"] as? String, let d = s.data(using: .utf8) {
            req.httpBody = d
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        session.dataTask(with: req) { [weak self] data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var text = ""
            if let data, !data.isEmpty {
                text = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
            }
            let ok = err == nil && (200..<400).contains(status)
            if url.path == "/api/session" {
                log("session report status=\(status) ok=\(ok)")
            }
            var payload: [String: Any] = ["cmd": "api", "id": id, "ok": ok, "status": status, "text": text]
            if let err { payload["error"] = err.localizedDescription }
            self?.send(payload)
        }.resume()
    }

    private func handleStore(_ body: [String: Any]) {
        let id = body["id"] as? Int ?? 0
        let op = body["op"] as? String ?? "get"
        let key = "pet." + (body["key"] as? String ?? "")
        switch op {
        case "get":
            send(["cmd": "store", "id": id, "ok": true, "value": store.string(forKey: key) ?? ""])
        case "set":
            store.set(body["value"] as? String ?? "", forKey: key)
            send(["cmd": "store", "id": id, "ok": true, "value": "ok"])
        default:
            send(["cmd": "store", "id": id, "ok": false, "value": "", "error": "bad_op"])
        }
    }

    private func handleApp(_ body: [String: Any]) {
        guard let action = body["action"] as? String else { return }
        switch action {
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
        case "open":
            let openHosts: Set<String> = ["ip.net.coffee", "net.coffee"]
            if let s = body["url"] as? String, let u = URL(string: s),
               let h = u.host?.lowercased(), openHosts.contains(h) {
                NSWorkspace.shared.open(u)
            }
        case "collapse":
            DispatchQueue.main.async { self.app?.setExpanded(false, notify: true) }
        case "expand":
            DispatchQueue.main.async { self.app?.setExpanded(true, notify: true) }
        case "refresh":
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("window.petUI && petUI.refresh();", completionHandler: nil)
            }
        case "toggle":
            DispatchQueue.main.async { self.app?.toggleExpanded() }
        case "recenter":
            DispatchQueue.main.async { self.app?.recenter() }
        case "menu":
            let open = body["open"] as? Bool ?? false
            DispatchQueue.main.async { self.app?.setMenuOpen(open) }
        default:
            log("unknown app command: \(action)")
        }
    }
}

// 把页面 console.error / 未捕获异常转发到日志，便于排查
final class LogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        log("web: \(message.body)")
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var panel: PetPanel!
    var webView: WKWebView!
    var bridge: Bridge!
    var expanded = false
    var menuOpen = false
    var terminating = false
    var monitor: Any?
    var timer: Timer?
    var dragging = false
    var moved = false
    var petClick = false
    var startMouse = NSPoint.zero
    var startOrigin = NSPoint.zero
    var shotPath: String?
    var shotDelay: Double = 14
    var scrollOffset = 0
    var expandOnLoad = false
    var evalJS: String?
    private var menuAnchorBeforePresentation: NSPoint?

    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature = ""
    private var pathDebounce: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installExceptionLogger()
        log("launched pid=\(getpid())")
        parseArgs()
        buildPanel()
        buildWebView()
        installMonitor()
        installPassthroughTimer()
        installNotificationObservers()
        startNetworkMonitor()
        webView.loadFileURL(indexURL(), allowingReadAccessTo: webDir())
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        log("will terminate")
        savePosition()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        log("terminate requested")
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        log("last window closed -> keep running (pet)")
        if !terminating {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.terminating else { return }
                self.panel.orderFrontRegardless()
                log("panel restored after last-window-closed")
            }
        }
        return false
    }

    // 仅保留外部唤起（无组件依赖）：叫回桌宠并展开
    func application(_ application: NSApplication, open urls: [URL]) {
        log("open url: \(urls.map { $0.absoluteString }.joined(separator: ","))")
        bringToFront()
        setExpanded(true, notify: true)
    }

    // VPN / 网络切换后自动刷新面板（组件独立运行，不受桌宠影响）
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let ifaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
            let sig = "\(path.status)|\(ifaces)|\(path.isExpensive)|\(path.isConstrained)"
            DispatchQueue.main.async {
                guard let self else { return }
                if self.lastPathSignature.isEmpty {
                    self.lastPathSignature = sig
                    log("network initial: \(sig)")
                    return
                }
                guard sig != self.lastPathSignature else { return }
                self.lastPathSignature = sig
                log("network changed: \(sig)")
                self.pathDebounce?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.terminating else { return }
                    log("network settled -> refresh panel")
                    self.webView?.evaluateJavaScript("window.petUI && petUI.refresh();", completionHandler: nil)
                }
                self.pathDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
            }
        }
        monitor.start(queue: DispatchQueue(label: "coffee.net.claude-ip-pet.network"))
        pathMonitor = monitor
    }

    // 再次双击 App（LaunchServices 转发的 reopen 事件）：把桌宠叫回屏幕上
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log("reopen event, visible=\(flag)")
        bringToFront()
        return true
    }

    // MARK: setup

    private func parseArgs() {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
            return nil
        }
        shotPath = value("--shot")
        if let d = value("--delay"), let v = Double(d) { shotDelay = v }
        if let s = value("--scroll"), let v = Int(s) { scrollOffset = v }
        evalJS = value("--eval")
        expandOnLoad = args.contains("--expand")
    }

    private func webDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["PET_WEB_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let res = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return res.appendingPathComponent("web", isDirectory: true)
    }

    private func indexURL() -> URL { webDir().appendingPathComponent("index.html") }

    private func buildPanel() {
        let p = PetPanel(contentRect: NSRect(origin: .zero, size: COLLAPSED_SIZE),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.level = .floating
        p.title = "Claude IP 桌宠"
        p.setAccessibilityRole(.window)
        p.setAccessibilitySubrole(.floatingWindow)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        let content = ClearPetContentView(frame: NSRect(origin: .zero, size: COLLAPSED_SIZE))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = content
        p.setFrame(NSRect(origin: actualOrigin(for: restoredOrigin(), size: COLLAPSED_SIZE), size: COLLAPSED_SIZE), display: false)

        panel = p
        NotificationCenter.default.addObserver(self, selector: #selector(panelWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: p)
    }

    @objc private func panelWillClose(_ note: Notification) {
        log("panel will close (terminating=\(terminating))")
        guard !terminating else { return }
        // 面板意外关闭时自动恢复，避免出现“闪退/消失”
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.terminating else { return }
            self.panel.orderFrontRegardless()
            log("panel reopened after unexpected close")
        }
    }

    private func buildWebView() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        let logScript = WKUserScript(source: """
            (function(){
              function send(level, args){
                try {
                  window.webkit.messageHandlers.log.postMessage(level + ': ' + args.map(function(a){
                    try { return typeof a === 'string' ? a : JSON.stringify(a); } catch(e) { return String(a); }
                  }).join(' '));
                } catch(e) {}
              }
              ['error','warn'].forEach(function(k){
                var orig = console[k];
                console[k] = function(){ send(k, Array.prototype.slice.call(arguments)); return orig.apply(console, arguments); };
              });
              window.addEventListener('error', function(e){ send('uncaught', [e.message + ' @ ' + (e.filename||'') + ':' + (e.lineno||0)]); });
              window.addEventListener('unhandledrejection', function(e){ send('rejection', [String(e.reason)]); });
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        ucc.addUserScript(logScript)
        ucc.add(LogHandler(), name: "log")
        let wv = WKWebView(frame: panel.contentView!.bounds, configuration: cfg)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.allowsMagnification = false
        wv.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { wv.underPageBackgroundColor = .clear }
        wv.wantsLayer = true
        wv.layer?.backgroundColor = NSColor.clear.cgColor
        bridge = Bridge()
        bridge.webView = wv
        bridge.app = self
        ucc.add(bridge, name: "api")
        panel.contentView!.addSubview(wv)
        webView = wv
    }

    private func installNotificationObservers() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onReopenNotification(_:)),
            name: Notification.Name(REOPEN_NOTIFICATION), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func onReopenNotification(_ note: Notification) {
        log("reopen notification received")
        bringToFront()
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        log("screen parameters changed")
        keepOnScreen()
    }

    // MARK: geometry

    private var activePetRect: NSRect {
        NSRect(x: (panel?.frame.width ?? COLLAPSED_SIZE.width) - 124, y: 8, width: 116, height: 112)
    }

    private func hudContains(_ point: NSPoint) -> Bool {
        let bounds = NSRect(x: 12, y: 124, width: 836, height: 646)
        let path = NSBezierPath()
        for (index, vertex) in HUD_OUTLINE.enumerated() {
            let p = NSPoint(x: bounds.minX + vertex.x * bounds.width,
                            y: bounds.maxY - vertex.y * bounds.height)
            if index == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        return path.contains(point)
    }

    // Keep the existing saved-coordinate convention (the expanded canvas origin),
    // while the collapsed native window only reserves space for the pet/tooltip.
    private func anchorOrigin(for origin: NSPoint, size: NSSize) -> NSPoint {
        NSPoint(x: origin.x + size.width - WIN_W, y: origin.y)
    }

    private func actualOrigin(for anchor: NSPoint, size: NSSize) -> NSPoint {
        NSPoint(x: anchor.x + WIN_W - size.width, y: anchor.y)
    }

    private var presentationSize: NSSize {
        expanded ? NSSize(width: WIN_W, height: WIN_H) : menuOpen ? MENU_SIZE : COLLAPSED_SIZE
    }

    private func resizeForPresentation(anchor suppliedAnchor: NSPoint? = nil, keepVisible: Bool = false) {
        let anchor = suppliedAnchor ?? anchorOrigin(for: panel.frame.origin, size: panel.frame.size)
        let size = presentationSize
        var frame = NSRect(origin: actualOrigin(for: anchor, size: size), size: size)
        if keepVisible {
            let petCenter = NSPoint(x: anchor.x + PET_RECT.midX, y: anchor.y + PET_RECT.midY)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(petCenter) }) ?? NSScreen.main {
                let bounds = screen.visibleFrame.insetBy(dx: 6, dy: 6)
                frame.origin.x = min(max(frame.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
                frame.origin.y = min(max(frame.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
            }
        }
        panel.setFrame(frame, display: true)
    }

    private func clampOrigin(_ origin: NSPoint) -> NSPoint {
        let size = panel?.frame.size ?? NSSize(width: WIN_W, height: WIN_H)
        return actualOrigin(for: clampAnchorOrigin(anchorOrigin(for: origin, size: size)), size: size)
    }

    /// 保证桌宠热区完整落在某块屏幕的可见区域内，避免拖出屏幕后“消失”
    private func clampAnchorOrigin(_ p: NSPoint) -> NSPoint {
        let petRect = NSRect(x: p.x + PET_RECT.origin.x, y: p.y + PET_RECT.origin.y,
                             width: PET_RECT.width, height: PET_RECT.height)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return p }
        let screen = screens.first(where: { $0.visibleFrame.intersects(petRect) })
            ?? screens.first(where: { $0.visibleFrame.intersects(NSRect(origin: p, size: NSSize(width: WIN_W, height: WIN_H))) })
            ?? screens[0]
        let v = screen.visibleFrame
        var o = p
        if petRect.minX < v.minX { o.x += v.minX - petRect.minX }
        if petRect.maxX > v.maxX { o.x -= petRect.maxX - v.maxX }
        if petRect.minY < v.minY { o.y += v.minY - petRect.minY }
        if petRect.maxY > v.maxY { o.y -= petRect.maxY - v.maxY }
        return o
    }

    private func defaultOrigin() -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let target = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.screens.first
            ?? NSScreen.main!
        let f = target.visibleFrame
        let margin = max(8, min(18, (f.height - WIN_H) / 2))
        return NSPoint(x: f.maxX - WIN_W - margin, y: f.minY + margin)
    }

    private func restoredOrigin() -> NSPoint {
        if let s = UserDefaults.standard.string(forKey: POS_KEY) {
            let parts = s.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                return clampAnchorOrigin(NSPoint(x: parts[0], y: parts[1]))
            }
        }
        return clampAnchorOrigin(defaultOrigin())
    }

    private func savePosition() {
        guard let panel else { return }
        let o = anchorOrigin(for: panel.frame.origin, size: panel.frame.size)
        UserDefaults.standard.set("\(o.x),\(o.y)", forKey: POS_KEY)
    }

    private func keepOnScreen() {
        guard let panel else { return }
        let clamped = clampOrigin(panel.frame.origin)
        if clamped != panel.frame.origin {
            panel.setFrameOrigin(clamped)
            savePosition()
            log("clamped window to \(clamped)")
        }
    }

    func recenter() {
        guard let panel else { return }
        menuAnchorBeforePresentation = nil
        panel.setFrameOrigin(actualOrigin(for: clampAnchorOrigin(defaultOrigin()), size: panel.frame.size))
        savePosition()
        log("recentered window")
    }

    func bringToFront() {
        guard let panel else { return }
        keepOnScreen()
        panel.orderFrontRegardless()
        webView?.evaluateJavaScript("window.petUI && petUI.hello();", completionHandler: nil)
    }

    // MARK: interaction

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let win = self.panel, event.window === win else { return event }
            switch event.type {
            case .leftMouseDown:
                if !win.isKeyWindow { win.makeKey() }
                let p = win.convertPoint(fromScreen: NSEvent.mouseLocation)
                if self.activePetRect.contains(p) || (self.expanded && HEADER_DRAG_RECT.contains(p)) {
                    log("mouse down on pet/header")
                    self.dragging = true
                    self.moved = false
                    self.petClick = self.activePetRect.contains(p)
                    self.startMouse = NSEvent.mouseLocation
                    self.startOrigin = win.frame.origin
                    return nil
                }
            case .leftMouseDragged:
                if self.dragging {
                    let m = NSEvent.mouseLocation
                    let dx = m.x - self.startMouse.x
                    let dy = m.y - self.startMouse.y
                    if !self.moved && hypot(dx, dy) > 3 {
                        self.moved = true
                        self.menuAnchorBeforePresentation = nil
                    }
                    if self.moved {
                        win.setFrameOrigin(self.clampOrigin(NSPoint(x: self.startOrigin.x + dx, y: self.startOrigin.y + dy)))
                    }
                    return nil
                }
            case .leftMouseUp:
                if self.dragging {
                    self.dragging = false
                    if self.moved {
                        log("drag ended at \(win.frame.origin)")
                        self.savePosition()
                    } else if self.petClick {
                        self.toggleExpanded()
                    }
                    return nil
                }
            default: break
            }
            return event
        }
    }

    // HTML 右键菜单打开时，窗口需要临时接收菜单区域的鼠标（否则点击穿透）
    func setMenuOpen(_ open: Bool) {
        let anchor = menuAnchorBeforePresentation ?? anchorOrigin(for: panel.frame.origin, size: panel.frame.size)
        if open && !menuOpen && !expanded { menuAnchorBeforePresentation = anchor }
        menuOpen = open
        if !expanded {
            resizeForPresentation(anchor: anchor, keepVisible: open)
            if !open { menuAnchorBeforePresentation = nil }
        }
        log("context menu open=\(open)")
        if open { panel.ignoresMouseEvents = false }
    }

    // Only visible UI receives the mouse, including the HUD's clipped silhouette.
    private func installPassthroughTimer() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let win = self.panel else { return }
            if self.dragging || self.menuOpen {
                if win.ignoresMouseEvents { win.ignoresMouseEvents = false }
                return
            }
            let p = win.convertPoint(fromScreen: NSEvent.mouseLocation)
            let shouldIgnore = !(self.activePetRect.contains(p) || (self.expanded && self.hudContains(p)))
            if win.ignoresMouseEvents != shouldIgnore { win.ignoresMouseEvents = shouldIgnore }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func toggleExpanded() { setExpanded(!expanded, notify: true) }

    func setExpanded(_ value: Bool, notify: Bool) {
        if value != expanded {
            // Collapse around the pet that is currently visible. Restoring a
            // pre-expansion anchor makes it jump after a screen-edge adjustment.
            let anchor = anchorOrigin(for: panel.frame.origin, size: panel.frame.size)
            menuAnchorBeforePresentation = nil
            menuOpen = false
            expanded = value
            resizeForPresentation(anchor: anchor, keepVisible: value)
        }
        log("expanded \(value)")
        if value { panel.makeKeyAndOrderFront(nil) }
        if notify {
            webView.evaluateJavaScript("window.petUI && window.petUI.setExpanded(\(value ? "true" : "false"));",
                                       completionHandler: nil)
        }
    }

    // MARK: webview

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log("page loaded")
        if expandOnLoad {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.setExpanded(true, notify: true)
            }
        }
        if let js = evalJS {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
        scheduleSnapshot()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("provisional navigation failed: \(error.localizedDescription)")
    }

    // WebContent 进程被系统回收/崩溃时自动重载，避免页面空白像“闪退”
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("web content process terminated -> reload")
        webView.reload()
    }

    private func scheduleSnapshot() {
        guard shotPath != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + shotDelay) { [weak self] in
            guard let self else { return }
            if self.scrollOffset > 0 {
                let js = "(function(){var b=document.getElementById('panelBody'); if(!b) return 0; b.scrollTop=\(self.scrollOffset); return b.scrollTop;})()"
                self.webView.evaluateJavaScript(js) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.takeSnapshot() }
                }
            } else {
                self.takeSnapshot()
            }
        }
    }

    private func takeSnapshot() {
        guard let path = shotPath else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = webView.bounds
        cfg.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        webView.takeSnapshot(with: cfg) { image, error in
            if let image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                log("snapshot -> \(path) (\(png.count) bytes)")
            } else {
                log("snapshot failed: \(String(describing: error))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }
}

// 单实例：已有桌宠在跑时，把屏幕上的那只叫出来并提示，然后退出本次启动
if let bid = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        .filter { $0.processIdentifier != getpid() }
    if !others.isEmpty {
        log("second instance -> notify running pid(s) \(others.map { $0.processIdentifier })")
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(REOPEN_NOTIFICATION), object: nil, userInfo: nil, deliverImmediately: true)
        Thread.sleep(forTimeInterval: 0.15)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
