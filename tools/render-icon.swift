import AppKit
import WebKit

let arguments = CommandLine.arguments
let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let sizePixels = Double(arguments[3])!
let sizePoints = sizePixels / 2
let paintWaitSeconds = 1.0
let application = NSApplication.shared

application.setActivationPolicy(.prohibited)

final class Renderer: NSObject, WKNavigationDelegate {
  let view = WKWebView(frame: NSRect(x: 0, y: 0, width: sizePoints, height: sizePoints))
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: sizePoints, height: sizePoints), styleMask: [.borderless], backing: .buffered, defer: false)

  override init() {
    super.init()
    view.setValue(false, forKey: "drawsBackground")
    view.navigationDelegate = self
    window.contentView = view

    guard let svg = try? String(contentsOf: inputURL, encoding: .utf8) else {
      print("render-icon: cannot read \(inputURL.path)")
      exit(1)
    }

    let page = "<html><body style=\"margin:0;background:transparent\"><div style=\"width:\(sizePoints)px;height:\(sizePoints)px\">\(svg.replacingOccurrences(of: "width=\"1024\" height=\"1024\"", with: "width=\"100%\" height=\"100%\""))</div></body></html>"

    view.loadHTMLString(page, baseURL: inputURL.deletingLastPathComponent())
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + paintWaitSeconds) {
      let configuration = WKSnapshotConfiguration()

      configuration.snapshotWidth = NSNumber(value: sizePoints)
      webView.takeSnapshot(with: configuration) { image, _ in
        guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        bitmap.size = NSSize(width: sizePixels, height: sizePixels)

        do {
          guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
          try png.write(to: outputURL)
        } catch {
          print("render-icon: \(error)")
          exit(1)
        }

        print("rendered \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) to \(outputURL.path)")
        exit(0)
      }
    }
  }
}

let renderer = MainActor.assumeIsolated { Renderer() }
application.run()
