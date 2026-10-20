// Sends mouse events to one process, so a test never moves the real pointer.
// swift tools/send-mouse.swift <pid> <x> <y> [move | click | rightclick | drag <x2> <y2> | scroll <pixels> | type <text>],
// x and y in window points. type sends the text as key presses, then Return. drag holds the left button from x y to x2 y2.
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
} else if action == "rightclick" {
  post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: p, mouseButton: .right))
  post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: p, mouseButton: .right))
} else if action == "drag" {
  let end = CGPoint(x: b["X"]! + Double(CommandLine.arguments[5])!, y: b["Y"]! + Double(CommandLine.arguments[6])!)
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
  // In steps, with a pause, so the app sees the drag start and the target under the pointer.
  for step in 1...20 {
    let t = Double(step) / 20
    let q = CGPoint(x: p.x + (end.x - p.x) * t, y: p.y + (end.y - p.y) * t)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: q, mouseButton: .left))
    usleep(30_000)
  }
  usleep(300_000)
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
} else if action == "scroll" {
  let dy = Int32(CommandLine.arguments[5])!
  let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
  e?.location = p
  post(e)
}
if action == "type" {
  for character in CommandLine.arguments[5].utf16 {
    for isDown in [true, false] {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown)
      var unit = character
      e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
      post(e)
    }
  }
  // Return is key 36.
  post(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
  post(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false))
}
print("sent \(action) at \(p)")
