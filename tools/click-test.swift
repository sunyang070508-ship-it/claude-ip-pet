import AppKit
import CoreGraphics

// 测试辅助：对桌宠热区发送真实鼠标点击/拖拽（需要辅助功能权限）
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "click"
let screen = NSScreen.main!
let v = screen.visibleFrame
let W: CGFloat = 424, H: CGFloat = 704
let margin = max(8, min(18, (v.height - H) / 2))
var origin = CGPoint(x: v.maxX - W - margin, y: v.minY + margin)
if let saved = UserDefaults(suiteName: "coffee.net.claude-ip-pet")?.string(forKey: "pet.window.origin") {
    let parts = saved.split(separator: ",").compactMap { Double($0) }
    if parts.count == 2 { origin = CGPoint(x: parts[0], y: parts[1]) }
}
let gx = origin.x + 358
let gy = screen.frame.height - (origin.y + 64)
print("mode:\(mode) trusted:\(AXIsProcessTrusted()) origin:\(origin) click:(\(gx),\(gy))")

let src = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
}
CGWarpMouseCursorPosition(CGPoint(x: gx, y: gy))
usleep(250_000)
if mode == "drag" {
    post(.leftMouseDown, CGPoint(x: gx, y: gy))
    for i in 1...6 { post(.leftMouseDragged, CGPoint(x: gx - CGFloat(i * 20), y: gy - CGFloat(i * 20))) }
    post(.leftMouseUp, CGPoint(x: gx - 120, y: gy - 120))
} else {
    post(.leftMouseDown, CGPoint(x: gx, y: gy))
    post(.leftMouseUp, CGPoint(x: gx, y: gy))
}
print("done")
