import AppKit
import WebKit

// music.youtube.com in a page no one sees. It plays YouTube songs with the page's own player, audio and all, so
// Premium's quality and its lack of ads apply. It is signed in with Helium's YouTube cookies.
@MainActor
final class YouTube: NSObject, WKNavigationDelegate {
  static let idPrefix = "yt:"

  private static let nudgeSeconds = 1.0
  private static let maxNudgeCount = 30
  static let pollSeconds = 0.5
  // A song that stops by itself for this long after it played loads again where it stopped, at most maxReloadCount times.
  static let stuckSeconds = 10.0
  static let maxReloadCount = 2
  // A song starts about a second after the page has it. One not started this long after is asked for again, then
  // the page opens again with it.
  static let slowStartSeconds = 4.0
  // Asks again once, then opens the page again once, then gives up.
  static let maxStartRetryCount = 2
  // Music.app's posts this soon after the helper paused it may still say it plays.
  private static let pauseSettleSeconds = 2.0
  // The page goes this long after the last YouTube song, as it holds 200 MB or more, unless the queue has more.
  // The next song loads it again.
  private static let idleCloseSeconds = 5.0 * 60
  static let positionSendSeconds = 2.0
  private let music: MusicApp
  // A test or bench run plays YouTube muted, and leaves Music.app playing.
  let isQuiet: Bool
  var playerView: WKWebView?
  private var playerWindow: NSWindow?
  var pollTimer: Timer?
  private var nudgeTimer: Timer?
  private var idleTimer: Timer?
  var song: SongMatch?
  var videoID = ""
  // The song loaded ahead, to play next.
  private var preparedID = ""
  var isPageLoaded = false
  private var pausedMusicAt = Date.distantPast
  var lastState = ""
  var lastPositionSentAt = Date.distantPast
  var playedSeconds = 0.0
  var stuckSince: Date?
  var reloadCount = 0
  var startAskedAt = Date.distantPast
  var startRetryCount = 0
  // Where the song starts once the page opens again, after it stopped partway.
  var resumeSeconds = 0.0
  var volumePercent = 100

  // True from a YouTube song's start until another source plays, so Music.app's posts leave the player as it is.
  private(set) var isActive = false

  // The queue plays a YouTube song later, so the page stays open, as loading it again takes 10 s or more.
  var keepsPage = false {
    didSet { if oldValue && !keepsPage && !isActive { startIdleTimer() } }
  }

  var hasJustPausedMusic: Bool { Date().timeIntervalSince(pausedMusicAt) < Self.pauseSettleSeconds }

  init(music: MusicApp, isQuiet: Bool) {
    self.music = music
    self.isQuiet = isQuiet
  }

  // Sends Helium's youtube.com cookies to the app, which signs each request with them, and gives them to the
  // player's page. A quiet run never asks the Keychain, so a test shows no prompt, and it plays signed out.
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

    // A page loaded before holds the old sign-in.
    if !isActive { resetPlayer() }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === playerView else { return }

    isPageLoaded = true
    startAskedAt = Date()
    stuckSince = nil
    // A song asked to play while its page still loaded ahead plays now.
    if isActive && preparedID == "" {
      run(toPlayScript(forcesLoad: resumeSeconds > 0, startSeconds: resumeSeconds))
      resumeSeconds = 0
    } else {
      run("window.onlymuseVideoID = \(quoted(videoID)); window.onlymuseIsPreparing = \(preparedID != "")")
    }
  }

  // Plays the song from YouTube. Answers its persistent ID, as Music.app's songs have.
  func play(_ match: SongMatch, videoID: String) -> String {
    idleTimer?.invalidate()
    idleTimer = nil
    isActive = true
    song = match
    self.videoID = videoID
    lastState = ""
    playedSeconds = 0
    stuckSince = nil
    reloadCount = 0
    startAskedAt = Date()
    startRetryCount = 0
    resumeSeconds = 0
    if !isQuiet {
      music.pauseIfRunning()
      pausedMusicAt = Date()
    }
    if !isQuiet, let volume = music.readVolumePercent() { volumePercent = volume }

    stopNudging()
    let isLoadingAhead = playerView != nil && !isPageLoaded && preparedID == videoID
    preparedID = ""

    // The page's first load plays the song in its address. didFinish then names it as the one to keep.
    if isPageLoaded {
      run(toPlayScript())
    } else if !isLoadingAhead {
      readPlayerView().load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(videoID)")!))
    }

    // The app shows the song at once, still, until the page plays it, as Music.app no longer plays.
    var loading = toNowPlaying(state: "playing", positionSeconds: 0, durationSeconds: match.durationSeconds)
    loading["isLoading"] = true
    send(loading)
    startPolling()

    return Self.idPrefix + videoID
  }

  // Loads the song to play after Music.app's, muted and paused, so it starts at once when its turn comes. Only
  // while no YouTube song plays, as the page has one player. An empty ID lets the page go when it is idle.
  func prepare(videoID: String) {
    guard !isActive, videoID != preparedID else { return }

    preparedID = videoID
    guard videoID != "" else { return startIdleTimer() }

    idleTimer?.invalidate()
    idleTimer = nil

    if isPageLoaded {
      run("window.onlymuseIsPreparing = true; document.getElementById('movie_player').loadVideoById(\(quoted(videoID)))")
    } else {
      readPlayerView().load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(videoID)#\(Self.prepareHash)")!))
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

  // Another source plays, so the page pauses and its posts stop.
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
        guard let self, !self.isActive, !self.keepsPage, self.preparedID == "" else { return }

        self.resetPlayer()
      }
    }
  }

  func apply(_ command: Command) {
    switch command.type {
    case "playPause":
      // A song still loading pauses too, so Pause works before its first sound.
      run("(() => { const player = document.getElementById('movie_player'); [\(Self.playingState), \(Self.bufferingState), \(Self.unstartedState)].includes(player.getPlayerState()) ? player.pauseVideo() : player.playVideo() })()")
    case "seek":
      guard let positionSeconds = command.positionSeconds else { return }
      run("document.getElementById('movie_player').seekTo(\(positionSeconds), true)")
      lastState = ""
    case "setVolume":
      guard let percent = command.volumePercent else { return }
      volumePercent = min(max(percent, 0), 100)
      run("document.getElementById('movie_player').setVolume(\(volumePercent))")
      lastState = ""
    default:
      break
    }
  }

  private func readPlayerView() -> WKWebView {
    if let playerView { return playerView }

    let configuration = WKWebViewConfiguration()

    configuration.websiteDataStore = .default()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.userContentController.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    if isQuiet { configuration.userContentController.addUserScript(WKUserScript(source: Self.muteScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }

    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)

    view.customUserAgent = WebPlayer.userAgent
    view.navigationDelegate = self

    // WebKit plays a page's media only while it is in a window. The window is on screen for WebKit, but clear,
    // far off every display and out of Mission Control. A hidden page is slowed once its sound pauses, and
    // YouTube's player, which resets itself now and then, then never started again.
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)

    window.contentView = view
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.transient, .ignoresCycle]
    window.isExcludedFromWindowsMenu = true
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    window.orderBack(nil)
    // Off every display, the window counts as covered, which WebKit takes as hidden too.
    if view.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
      view.setValue(false, forKey: "windowOcclusionDetectionEnabled")
    }
    playerView = view
    playerWindow = window

    return view
  }

  private func resetPlayer() {
    stop()
    idleTimer?.invalidate()
    idleTimer = nil
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

  func quoted(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text]), let array = String(data: data, encoding: .utf8) else { return "\"\"" }

    return String(array.dropFirst().dropLast())
  }
}
