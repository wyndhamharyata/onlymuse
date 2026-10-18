import AppKit
import ApplicationServices
// usage: axplay [press]  — lists Play/Shuffle buttons in Music's front window; "press" presses the first Play
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else { print("Music not running"); exit(1) }
print("trusted:", AXIsProcessTrusted())
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
var queue: [AXUIElement] = (attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(1).map { $0 }
var found: [(AXUIElement, String)] = []
var seen = 0
while !queue.isEmpty && seen < 5000 {
  let e = queue.removeFirst(); seen += 1
  let role = attr(e, kAXRoleAttribute) as? String ?? ""
  if role == "AXButton" {
    let label = [attr(e, kAXTitleAttribute), attr(e, kAXDescriptionAttribute), attr(e, "AXIdentifier")].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " / ")
    if label.range(of: "play|shuffle", options: [.regularExpression, .caseInsensitive]) != nil { found.append((e, label)) }
  }
  queue += attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
print("scanned \(seen) elements")
for (_, l) in found { print("  button:", l) }
if CommandLine.arguments.dropFirst().first == "press", let play = found.first(where: { $0.1.range(of: "^Play / play", options: [.regularExpression, .caseInsensitive]) != nil }) {
  print("press:", AXUIElementPerformAction(play.0, kAXPressAction as CFString).rawValue)
}
