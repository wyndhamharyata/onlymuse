// Renders an SVG to a PNG with a transparent background, as WebKit draws it, filters and all.
// swift tools/render-icon.swift <in.svg> <out.png> <size in pixels>
import AppKit
import WebKit

let arguments = CommandLine.arguments
let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])
let sizePixels = Double(arguments[3])!
let application = NSApplication.shared

// No Dock icon, and never in front of the person's windows.
application.setActivationPolicy(.prohibited)

final class Renderer: NSObject, WKNavigationDelegate {
  // The snapshot is twice the view's size on a Retina screen, so the view is half the pixels asked for.
  let view = WKWebView(frame: NSRect(x: 0, y: 0, width: sizePixels / 2, height: sizePixels / 2))
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: sizePixels / 2, height: sizePixels / 2), styleMask: [.borderless], backing: .buffered, defer: false)

  override init() {
    super.init()
    view.setValue(false, forKey: "drawsBackground")
    view.navigationDelegate = self
    window.contentView = view

    let svg = (try? String(contentsOf: inputURL, encoding: .utf8)) ?? ""
    let page = "<html><body style=\"margin:0;background:transparent\"><div style=\"width:\(sizePixels / 2)px;height:\(sizePixels / 2)px\">\(svg.replacingOccurrences(of: "width=\"1024\" height=\"1024\"", with: "width=\"100%\" height=\"100%\""))</div></body></html>"

    view.loadHTMLString(page, baseURL: inputURL.deletingLastPathComponent())
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      let configuration = WKSnapshotConfiguration()

      configuration.snapshotWidth = NSNumber(value: sizePixels / 2)
      webView.takeSnapshot(with: configuration) { image, _ in
        guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        bitmap.size = NSSize(width: sizePixels, height: sizePixels)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: outputURL)
        print("rendered \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) to \(outputURL.path)")
        exit(0)
      }
    }
  }
}

let renderer = MainActor.assumeIsolated { Renderer() }
application.run()
