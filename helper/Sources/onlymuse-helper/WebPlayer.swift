import AppKit
import WebKit

// The music.apple.com web player, in a window that shows only to sign in. WebKit keeps the sign-in, as Safari does.
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
  // authorize() opens Apple's sign-in popup, so the window skips the web player's own pages.
  private static let authorizeScript = "window.MusicKit.getInstance().authorize(); true"
  private static let refreshTimeoutSeconds = 30.0
  private static let pollSeconds = 1.0
  // MusicKit restores a saved sign-in a moment after it gives the developer token.
  private static let pollsBeforeSignInNeeded = 3

  private var window: NSWindow?
  private var webView: WKWebView?
  private var popupWindows: [NSWindow] = []
  private var pollTask: Task<Void, Never>?
  private var isSigningIn = false
  private var hasAskedToAuthorize = false
  private var signedOutPollCount = 0

  func refreshTokens() {
    startPolling(isSigningIn: false)
  }

  func signIn() {
    isSigningIn = true
    readWindow().makeKeyAndOrderFront(nil)
    NSApp.activate()
    startPolling(isSigningIn: true)
  }

  private func readWindow() -> NSWindow {
    if let window { return window }

    let configuration = WKWebViewConfiguration()

    configuration.websiteDataStore = .default()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

    let webView = WKWebView(frame: .zero, configuration: configuration)

    webView.customUserAgent = Self.userAgent
    webView.uiDelegate = self
    webView.load(URLRequest(url: Self.url))

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)

    window.title = "Sign in to Apple Music"
    window.contentView = webView
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    self.window = window
    self.webView = webView

    return window
  }

  private func startPolling(isSigningIn: Bool) {
    _ = readWindow()
    signedOutPollCount = 0
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      let deadline = Date().addingTimeInterval(Self.refreshTimeoutSeconds)

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.pollSeconds))

        guard let self else { return }

        let isDone = await self.applyTokens(isSigningIn: isSigningIn)

        if isDone { return }

        if !isSigningIn && Date() > deadline {
          sendError("The web player gave no developer token within \(Int(Self.refreshTimeoutSeconds)) seconds.")
          self.finish()
          return
        }
      }
    }
  }

  // True once the page answered for this attempt, with both tokens or with no sign-in.
  private func applyTokens(isSigningIn: Bool) async -> Bool {
    guard let page = await readPageTokens(), !page.developerToken.isEmpty else { return false }

    if page.userToken.isEmpty && isSigningIn && !hasAskedToAuthorize {
      hasAskedToAuthorize = true
      _ = try? await webView?.evaluateJavaScript(Self.authorizeScript)
    }

    if page.userToken.isEmpty {
      signedOutPollCount += 1

      let isSignedOut = !isSigningIn && signedOutPollCount >= Self.pollsBeforeSignInNeeded

      if isSignedOut {
        send(["type": "signInNeeded"])
        finish()
      }

      return isSignedOut
    }

    send(["type": "tokens", "developerToken": page.developerToken, "userToken": page.userToken])
    finish()

    return true
  }

  private func readPageTokens() async -> (developerToken: String, userToken: String)? {
    guard let webView, let text = try? await webView.evaluateJavaScript(Self.readTokensScript) as? String else { return nil }
    guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }

    return (json["developerToken"] ?? "", json["userToken"] ?? "")
  }

  // The web view goes away with its window, so an idle helper holds no web page.
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
      closePopup(closing)
      return
    }

    pollTask?.cancel()
    finish()
    send(["type": "signInNeeded"])
  }

  // Apple's sign-in opens in a popup. It takes the web player's place on screen while it is open.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    let popup = WKWebView(frame: .zero, configuration: configuration)
    let popupWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)

    popup.customUserAgent = Self.userAgent
    popup.uiDelegate = self
    popupWindow.title = "Sign in to Apple Music"
    popupWindow.contentView = popup
    popupWindow.isReleasedWhenClosed = false
    popupWindow.delegate = self
    popupWindow.center()
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
    closePopup(popupWindow)
  }

  // A popup closed before the sign-in finished, so the web player shows again with its own Sign In.
  private func closePopup(_ popupWindow: NSWindow) {
    popupWindows.removeAll { $0 === popupWindow }

    if isSigningIn && popupWindows.isEmpty { window?.makeKeyAndOrderFront(nil) }
  }
}

// Letting go of a web view leaves its page's process running, with 150 MB or more. WebKit's _close ends the
// page, and so the process. It is not public, so a WebKit without it only stops the page loading.
@MainActor
func closePage(_ view: WKWebView?) {
  guard let view else { return }

  view.stopLoading()

  let close = NSSelectorFromString("_close")

  if view.responds(to: close) { view.perform(close) }
}
