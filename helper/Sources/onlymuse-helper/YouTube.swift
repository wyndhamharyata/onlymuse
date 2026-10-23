import AppKit
import WebKit

@MainActor
final class YouTube: NSObject, WKNavigationDelegate {
  static let idPrefix = "yt:"

  private static let nudgeSeconds = 1.0
  private static let maxNudgeCount = 30
  static let pollSeconds = 0.5
  static let stuckSeconds = 10.0
  static let slowStartSeconds = 4.0
  static let maxRetryCount = 2
  // Just after the helper pauses Music.app, its posts may still say it plays.
  private static let pauseSettleSeconds = 2.0
  private static let idleCloseSeconds = 5.0 * 60
  static let positionSendSeconds = 2.0

  private let music: MusicApp
  let isQuiet: Bool
  var playerView: WKWebView?
  private var playerWindow: NSWindow?
  var pollTimer: Timer?
  private var nudgeTimer: Timer?
  private var idleTimer: Timer?
  var song: SongMatch?
  var videoID = ""
  private var preparedID = ""
  var isPageLoaded = false
  private var pausedMusicAt = Date.distantPast
  var lastState: String?
  var lastPositionSentAt = Date.distantPast
  var playedSeconds = 0.0
  var stuckSince: Date?
  var reloadCount = 0
  var startAskedAt = Date.distantPast
  var startRetryCount = 0
  var resumeSeconds = 0.0
  var volumePercent = 100

  private(set) var isActive = false

  var isPageKept = false {
    didSet {
      let isPageNoLongerNeeded = oldValue && !isPageKept && !isActive

      if isPageNoLongerNeeded { startIdleTimer() }
    }
  }

  var hasJustPausedMusic: Bool { Date().timeIntervalSince(pausedMusicAt) < Self.pauseSettleSeconds }

  init(music: MusicApp, isQuiet: Bool) {
    self.music = music
    self.isQuiet = isQuiet
  }

  func sendCookie() {
    guard !isQuiet else { return send(["type": "youtubeCookie", "cookie": ""]) }

    DispatchQueue.global().async {
      let result = HeliumCookies.readYouTubeCookies()

      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.apply(result) }
      }
    }
  }

  private func apply(_ result: Result<[HeliumCookies.Cookie], HeliumCookies.Failure>) {
    let cookies: [HeliumCookies.Cookie]

    switch result {
    case .success(let found): cookies = found
    case .failure(.noKey): return send(["type": "youtubeCookie", "cookie": "", "problem": "keychain"])
    case .failure(.noDatabase): return send(["type": "youtubeCookie", "cookie": "", "problem": "helium"])
    }

    send(["type": "youtubeCookie", "cookie": cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")])

    let store = WKWebsiteDataStore.default().httpCookieStore

    for cookie in cookies {
      var properties: [HTTPCookiePropertyKey: Any] = [.domain: cookie.host, .path: cookie.path, .name: cookie.name, .value: cookie.value]
      if cookie.isSecure { properties[.secure] = "TRUE" }
      if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
      if let httpCookie = HTTPCookie(properties: properties) { store.setCookie(httpCookie) }
    }

    if !isActive { resetPlayer() }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === playerView else { return }

    isPageLoaded = true
    startAskedAt = Date()
    stuckSince = nil

    let isSongWaitingForPage = isActive && preparedID == ""

    if isSongWaitingForPage {
      run(toPlayScript(isLoadForced: resumeSeconds > 0, startSeconds: resumeSeconds))
      resumeSeconds = 0
    } else {
      run("window.onlymuseVideoID = \(toJavaScriptText(videoID)); window.onlymuseIsPreparing = \(preparedID != "")")
    }
  }

  func play(_ match: SongMatch, videoID: String) -> String {
    stopIdleTimer()
    isActive = true
    song = match
    self.videoID = videoID
    lastState = nil
    playedSeconds = 0
    stuckSince = nil
    reloadCount = 0
    startAskedAt = Date()
    startRetryCount = 0
    resumeSeconds = 0

    if !isQuiet {
      music.pauseIfRunning()
      pausedMusicAt = Date()
      if let volumePercent = music.readVolumePercent() { self.volumePercent = volumePercent }
    }

    stopNudging()

    let isLoadingAhead = playerView != nil && !isPageLoaded && preparedID == videoID

    preparedID = ""

    if isPageLoaded {
      run(toPlayScript())
    } else if !isLoadingAhead {
      startPlayerView().load(URLRequest(url: Self.toWatchURL(videoID: videoID)))
    }

    var loading = makeNowPlaying(state: "playing", positionSeconds: 0, durationSeconds: match.durationSeconds)
    loading["isLoading"] = true
    send(loading)
    startPolling()

    return Self.idPrefix + videoID
  }

  func prepare(videoID: String) {
    guard !isActive, videoID != preparedID else { return }

    preparedID = videoID

    guard videoID != "" else { return startIdleTimer() }

    stopIdleTimer()

    if isPageLoaded {
      run("window.onlymuseIsPreparing = true; document.getElementById('movie_player').loadVideoById(\(toJavaScriptText(videoID)))")
    } else {
      startPlayerView().load(URLRequest(url: Self.toWatchURL(videoID: videoID, isPreparing: true)))
    }

    startNudging()
  }

  private func startNudging() {
    var count = 0

    nudgeTimer?.invalidate()
    nudgeTimer = Timer.scheduledTimer(withTimeInterval: Self.nudgeSeconds, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }

        count += 1
        guard !self.isActive, self.preparedID != "", count <= Self.maxNudgeCount, let playerView = self.playerView else { return self.stopNudging() }
        guard self.isPageLoaded else { return }

        playerView.evaluateJavaScript(Self.nudgeScript) { [weak self] result, _ in
          if result as? Bool == true { MainActor.assumeIsolated { self?.stopNudging() } }
        }
      }
    }
  }

  private func stopNudging() {
    nudgeTimer?.invalidate()
    nudgeTimer = nil
  }

  func stop() {
    guard isActive else { return }

    isActive = false
    pollTimer?.invalidate()
    pollTimer = nil
    run("document.getElementById('movie_player')?.pauseVideo()")
    startIdleTimer()
  }

  private func startIdleTimer() {
    idleTimer?.invalidate()
    idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleCloseSeconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isActive, !self.isPageKept, self.preparedID == "" else { return }

        self.resetPlayer()
      }
    }
  }

  private func stopIdleTimer() {
    idleTimer?.invalidate()
    idleTimer = nil
  }

  func apply(_ command: Command) {
    switch command.type {
    case "playPause":
      run("(() => { const player = document.getElementById('movie_player'); [\(Self.playingState), \(Self.bufferingState), \(Self.unstartedState)].includes(player.getPlayerState()) ? player.pauseVideo() : player.playVideo() })()")
    case "seek":
      guard let positionSeconds = command.positionSeconds else { return }
      guard isPageLoaded else {
        resumeSeconds = positionSeconds
        return
      }
      run("document.getElementById('movie_player').seekTo(\(positionSeconds), true)")
      lastState = nil
    case "setVolume":
      guard let volumePercent = command.volumePercent?.value else { return }

      self.volumePercent = volumePercent
      sendVolumeToPage()
      lastState = nil
    default:
      break
    }
  }

  func sendVolumeToPage() {
    run("document.getElementById('movie_player').setVolume(\(volumePercent))")
  }

  static func toWatchURL(videoID: String, isPreparing: Bool = false) -> URL {
    URL(string: "https://music.youtube.com/watch?v=\(videoID)" + (isPreparing ? "#\(prepareHash)" : ""))!
  }

  private func startPlayerView() -> WKWebView {
    if let playerView { return playerView }

    let configuration = WKWebViewConfiguration()

    configuration.websiteDataStore = .default()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.userContentController.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    if isQuiet { configuration.userContentController.addUserScript(WKUserScript(source: Self.muteScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }

    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)

    view.customUserAgent = WebPlayer.userAgent
    view.navigationDelegate = self

    // After a pause, WebKit slows a hidden page so much that YouTube's player never starts again.
    // WebKit plays media only in a window, so this clear one stays open, off every display.
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)

    window.contentView = view
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.transient, .ignoresCycle]
    window.isExcludedFromWindowsMenu = true
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderBack(nil)
    if view.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
      view.setValue(false, forKey: "windowOcclusionDetectionEnabled")
    }

    playerView = view
    playerWindow = window

    return view
  }

  private func resetPlayer() {
    stop()
    stopIdleTimer()
    closePage(playerView)
    playerWindow?.close()
    playerWindow = nil
    playerView = nil
    isPageLoaded = false
    preparedID = ""
  }

  func run(_ script: String) {
    playerView?.evaluateJavaScript(script) { _, error in
      if let error { sendError("The YouTube page answered with an error: \(error.localizedDescription)") }
    }
  }

  func toJavaScriptText(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text]), let array = String(data: data, encoding: .utf8) else { return "\"\"" }

    return String(array.dropFirst().dropLast())
  }
}
