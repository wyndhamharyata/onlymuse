// Sends mouse events to one process, so a test never moves the real pointer.
// swift tools/send-mouse.swift <pid> <x> <y> [move | click | scroll <pixels>], x and y in window points.
import CoreGraphics
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
let x = Double(CommandLine.arguments[2])!, y = Double(CommandLine.arguments[3])!
let action = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : "click"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
guard let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }), let b = w[kCGWindowBounds as String] as? [String: Double] else { print("no window"); exit(1) }
let p = CGPoint(x: b["X"]! + x, y: b["Y"]! + y)
func post(_ e: CGEvent?) { e?.postToPid(pid); usleep(20_000) }
post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
if action == "click" {
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
} else if action == "scroll" {
  let dy = Int32(CommandLine.arguments[5])!
  let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
  e?.location = p
  post(e)
}
print("sent \(action) at \(p)")
