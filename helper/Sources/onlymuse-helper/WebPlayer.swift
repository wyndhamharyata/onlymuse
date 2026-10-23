import AppKit
import WebKit

@MainActor
final class WebPlayer: NSObject, WKUIDelegate, NSWindowDelegate {
  private static let url = URL(string: "https://music.apple.com/id/browse")!
  static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
  private static let readTokensScript = """
    (() => {
      const instance = window.MusicKit?.getInstance?.();
      if (!instance) return "";
      return JSON.stringify({ developerToken: instance.developerToken ?? "", userToken: instance.musicUserToken ?? "" });
    })()
    """
  private static let authorizeScript = "window.MusicKit.getInstance().authorize(); true"
  private static let refreshTimeoutSeconds = 30.0
  private static let pollSeconds = 1.0
  private static let pollsBeforeSignInNeeded = 3

  private var window: NSWindow?
  private var webView: WKWebView?
  private var popupWindows: [NSWindow] = []
  private var pollTask: Task<Void, Never>?
  private var isSigningIn = false
  private var hasAskedToAuthorize = false
  private var signedOutPollCount = 0

  func refreshTokens() {
    // The sign-in's own poll sends the tokens. A refresh closes the window as the person types.
    guard !isSigningIn else { return }

    startPolling()
  }

  func signIn() {
    isSigningIn = true
    startWindow().makeKeyAndOrderFront(nil)
    NSApp.activate()
    startPolling()
  }

  private func startWindow() -> NSWindow {
    if let window { return window }

    let configuration = WKWebViewConfiguration()

    configuration.websiteDataStore = .default()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

    let webView = WKWebView(frame: .zero, configuration: configuration)

    webView.customUserAgent = Self.userAgent
    webView.uiDelegate = self
    webView.load(URLRequest(url: Self.url))

    let window = makeSignInWindow(showing: webView, size: NSSize(width: 520, height: 720), styleMask: [.titled, .closable, .resizable])

    self.window = window
    self.webView = webView

    return window
  }

  private func makeSignInWindow(showing view: WKWebView, size: NSSize, styleMask: NSWindow.StyleMask) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: styleMask, backing: .buffered, defer: false)

    window.title = "Sign in to Apple Music"
    window.contentView = view
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()

    return window
  }

  private func startPolling() {
    _ = startWindow()
    signedOutPollCount = 0
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      let deadline = Date().addingTimeInterval(Self.refreshTimeoutSeconds)

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.pollSeconds))

        guard let self else { return }

        let isDone = await self.applyTokens()

        if isDone { return }

        let hasTimedOut = !self.isSigningIn && Date() > deadline

        if hasTimedOut {
          sendError("The web player gave no developer token within \(Int(Self.refreshTimeoutSeconds)) seconds.")
          self.finish()
          return
        }
      }
    }
  }

  private func applyTokens() async -> Bool {
    guard let page = await readPageTokens(), !page.developerToken.isEmpty else { return false }

    if !page.userToken.isEmpty {
      send(["type": "tokens", "developerToken": page.developerToken, "userToken": page.userToken])
      finish()
      return true
    }

    if isSigningIn && !hasAskedToAuthorize {
      hasAskedToAuthorize = true
      _ = try? await webView?.evaluateJavaScript(Self.authorizeScript)
    }

    signedOutPollCount += 1

    let isSignedOut = !isSigningIn && signedOutPollCount >= Self.pollsBeforeSignInNeeded

    if isSignedOut {
      send(["type": "signInNeeded"])
      finish()
    }

    return isSignedOut
  }

  private func readPageTokens() async -> (developerToken: String, userToken: String)? {
    guard let webView, let text = try? await webView.evaluateJavaScript(Self.readTokensScript) as? String else { return nil }
    guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }

    return (json["developerToken"] ?? "", json["userToken"] ?? "")
  }

  private func finish() {
    isSigningIn = false
    hasAskedToAuthorize = false
    closePage(webView)
    window?.delegate = nil
    window?.close()
    window = nil
    webView = nil

    for popup in popupWindows {
      closePage(popup.contentView as? WKWebView)
      popup.delegate = nil
      popup.close()
    }

    popupWindows = []
  }

  func windowWillClose(_ notification: Notification) {
    guard isSigningIn, let closing = notification.object as? NSWindow else { return }

    if closing !== window {
      applyPopupClosed(closing)
      return
    }

    pollTask?.cancel()
    finish()
    send(["type": "signInNeeded"])
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    let popup = WKWebView(frame: .zero, configuration: configuration)
    let popupWindow = makeSignInWindow(showing: popup, size: NSSize(width: 480, height: 640), styleMask: [.titled, .closable])

    popup.customUserAgent = Self.userAgent
    popup.uiDelegate = self
    popupWindows.append(popupWindow)
    window?.orderOut(nil)
    popupWindow.makeKeyAndOrderFront(nil)
    NSApp.activate()

    return popup
  }

  func webViewDidClose(_ webView: WKWebView) {
    guard let popupWindow = popupWindows.first(where: { $0.contentView === webView }) else { return }

    popupWindow.delegate = nil
    popupWindow.close()
    applyPopupClosed(popupWindow)
  }

  private func applyPopupClosed(_ popupWindow: NSWindow) {
    popupWindows.removeAll { $0 === popupWindow }

    if isSigningIn && popupWindows.isEmpty { window?.makeKeyAndOrderFront(nil) }
  }
}

// A released web view keeps a 150 MB page process. WebKit's private _close ends it.
@MainActor
func closePage(_ view: WKWebView?) {
  guard let view else { return }

  view.stopLoading()

  let close = NSSelectorFromString("_close")

  if view.responds(to: close) { view.perform(close) }
}
