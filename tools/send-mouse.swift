import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let pid = pid_t(arguments[1])!
let x = Double(arguments[2])!, y = Double(arguments[3])!
let action = arguments.count > 4 ? arguments[4] : "click"
let eventPauseMicroseconds: useconds_t = 20_000
let dragStepCount = 20
let dragStepPauseMicroseconds: useconds_t = 30_000
let dragEndPauseMicroseconds: useconds_t = 300_000
let returnKeyCode: CGKeyCode = 36
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]

guard let window = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }),
  let bounds = window[kCGWindowBounds as String] as? [String: Double]
else {
  print("no window")
  exit(1)
}

let point = CGPoint(x: bounds["X"]! + x, y: bounds["Y"]! + y)

func post(_ event: CGEvent?) {
  event?.postToPid(pid)
  usleep(eventPauseMicroseconds)
}

post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))

switch action {
case "move":
  break
case "click":
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
case "rightclick":
  post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right))
  post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right))
case "drag":
  let end = CGPoint(x: bounds["X"]! + Double(arguments[5])!, y: bounds["Y"]! + Double(arguments[6])!)

  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))

  for step in 1...dragStepCount {
    let fraction = Double(step) / Double(dragStepCount)
    let stepPoint = CGPoint(x: point.x + (end.x - point.x) * fraction, y: point.y + (end.y - point.y) * fraction)

    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: stepPoint, mouseButton: .left))
    usleep(dragStepPauseMicroseconds)
  }

  usleep(dragEndPauseMicroseconds)
  post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
case "scroll":
  let deltaPixels = Int32(arguments[5])!
  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaPixels, wheel2: 0, wheel3: 0)

  event?.location = point
  post(event)
case "type":
  for character in arguments[5].utf16 {
    for isDown in [true, false] {
      let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown)
      var unit = character

      event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
      post(event)
    }
  }

  post(CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: true))
  post(CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: false))
default:
  print("unknown action \(action)")
  exit(1)
}

print("sent \(action) at \(point)")
