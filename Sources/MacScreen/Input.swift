import Foundation
import CoreGraphics
import ApplicationServices

/// Turns touch / mouse messages from the receiver into real macOS input events,
/// mapped onto the virtual display's bounds.
final class InputInjector {
    var displayID: CGDirectDisplayID = 0
    private var leftDown = false
    private var rightDown = false
    private let src = CGEventSource(stateID: .hidSystemState)
    private(set) var eventsPosted = 0
    private(set) var lastPoint = CGPoint.zero

    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func point(_ j: [String: Any]) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        let x = min(max((j["x"] as? Double) ?? 0, 0), 1)
        let y = min(max((j["y"] as? Double) ?? 0, 0), 1)
        // keep strictly inside the display so the cursor never jumps to a neighbour
        return CGPoint(x: b.minX + min(x * b.width, b.width - 1), y: b.minY + min(y * b.height, b.height - 1))
    }

    private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton, clicks: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.post(tap: .cghidEventTap)
        eventsPosted += 1
        lastPoint = p
    }

    func handle(_ j: [String: Any]) {
        guard displayID != 0, let t = j["t"] as? String else { return }
        switch t {
        case "m":
            let p = point(j)
            let a = j["a"] as? String ?? "move"
            let right = (j["b"] as? Int) == 2
            let clicks = Int64((j["c"] as? Int) ?? 1)
            switch a {
            case "down":
                if right { rightDown = true; post(.rightMouseDown, p, button: .right, clicks: clicks) }
                else { leftDown = true; post(.leftMouseDown, p, button: .left, clicks: clicks) }
            case "up":
                if right || rightDown { rightDown = false; post(.rightMouseUp, p, button: .right, clicks: clicks) }
                else { leftDown = false; post(.leftMouseUp, p, button: .left, clicks: clicks) }
            default:
                if leftDown { post(.leftMouseDragged, p, button: .left) }
                else if rightDown { post(.rightMouseDragged, p, button: .right) }
                else { post(.mouseMoved, p, button: .left) }
            }
        case "s":
            let p = point(j)
            post(.mouseMoved, p, button: .left)
            let dx = Int32((j["dx"] as? Double) ?? 0)
            let dy = Int32((j["dy"] as? Double) ?? 0)
            if let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                e.post(tap: .cghidEventTap)
                eventsPosted += 1
            }
        default: break
        }
    }

    /// Release any held buttons (client vanished mid-drag).
    func releaseAll() {
        let p = lastPoint
        if leftDown { leftDown = false; post(.leftMouseUp, p, button: .left) }
        if rightDown { rightDown = false; post(.rightMouseUp, p, button: .right) }
    }
}
