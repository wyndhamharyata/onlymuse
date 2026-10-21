import AppKit
import WebKit

// music.youtube.com in a page no one sees. It plays YouTube songs with the page's own player, audio and all, so
// Premium's quality and its lack of ads apply. It is signed in with Helium's YouTube cookies.
@MainActor
final class YouTube: NSObject, WKNavigationDelegate {
  static let idPrefix = "yt:"

  // The page plays its own next song when one ends. Only the app's queue picks what plays, so any other song pauses.
  private static let pageScript = """
    window.onlymuseVideoID = "";
    document.addEventListener("playing", () => {
      const player = document.getElementById("movie_player");
      if (player && window.onlymuseVideoID && player.getVideoData().video_id !== window.onlymuseVideoID) player.pauseVideo();
    }, true);
    """
  // A quiet run mutes each song before it makes a sound.
  private static let muteScript = """
    document.addEventListener("play", (event) => { event.target.muted = true }, true);
    """
  private static let readStateScript = """
    (() => {
      const player = document.getElementById("movie_player");
      if (!player || !player.getVideoData) return "";
      return JSON.stringify({ id: player.getVideoData().video_id, state: player.getPlayerState(), position: player.getCurrentTime(), duration: player.getDuration() });
    })()
    """
  private static let pollSeconds = 0.5
  // The page goes this long after the last YouTube song, as it holds 200 MB or more. The next song loads it again.
  private static let idleCloseSeconds = 5.0 * 60
  private static let positionSendSeconds = 2.0
  // The page's player states, as YT.PlayerState names them.
  private static let endedState = 0
  private static let playingState = 1
  private static let pausedState = 2

  private let music: MusicApp
  // A test or bench run plays YouTube muted, and leaves Music.app playing.
  private let isQuiet: Bool
  private var playerView: WKWebView?
  private var playerWindow: NSWindow?
  private var pollTimer: Timer?
  private var idleTimer: Timer?
  private var song: SongMatch?
  private var videoID = ""
  private var isPageLoaded = false
  private var lastState = ""
  private var lastPositionSentAt = Date.distantPast
  private var volumePercent = 100

  // True from a YouTube song's start until another source plays, so Music.app's posts leave the player as it is.
  private(set) var isActive = false

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
    run("window.onlymuseVideoID = \(quoted(videoID))")
  }

  // Plays the song from YouTube. Answers its persistent ID, as Music.app's songs have.
  func play(_ match: SongMatch, videoID: String) -> String {
    idleTimer?.invalidate()
    idleTimer = nil
    isActive = true
    song = match
    self.videoID = videoID
    lastState = ""
    if !isQuiet { music.pauseIfRunning() }
    if !isQuiet, let volume = music.readVolumePercent() { volumePercent = volume }

    let view = readPlayerView()

    // The page's first load plays the song in its address. didFinish then names it as the one to keep.
    if isPageLoaded {
      run("window.onlymuseVideoID = \(quoted(videoID)); document.getElementById('movie_player').loadVideoById(\(quoted(videoID)))")
    } else {
      view.load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(videoID)")!))
    }

    startPolling()

    return Self.idPrefix + videoID
  }

  // Another source plays, so the page pauses and its posts stop.
  func stop() {
    guard isActive else { return }

    isActive = false
    pollTimer?.invalidate()
    pollTimer = nil
    run("document.getElementById('movie_player')?.pauseVideo()")
    idleTimer?.invalidate()
    idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleCloseSeconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isActive else { return }

        self.resetPlayer()
      }
    }
  }

  func apply(_ command: Command) {
    switch command.type {
    case "playPause":
      run("(() => { const player = document.getElementById('movie_player'); player.getPlayerState() === \(Self.playingState) ? player.pauseVideo() : player.playVideo() })()")
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

  func sendState() {
    lastState = ""
    poll()
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

    // The window is never shown. WebKit plays a page's media only while it is in a window.
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)

    window.contentView = view
    window.isReleasedWhenClosed = false
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
  }

  private func startPolling() {
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
  }

  private func poll() {
    guard isActive, let playerView else { return }

    playerView.evaluateJavaScript(Self.readStateScript) { [weak self] result, _ in
      MainActor.assumeIsolated {
        guard let self, self.isActive, let text = result as? String, let data = text.data(using: .utf8) else { return }
        guard let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        self.apply(page: page)
      }
    }
  }

  // Sends nowPlaying when the state changes, and the position every few seconds, as Music.app's side does.
  private func apply(page: [String: Any]) {
    let pageID = page["id"] as? String ?? ""
    let playerState = page["state"] as? Int ?? -1
    let positionSeconds = page["position"] as? Double ?? 0
    let pageDuration = page["duration"] as? Double ?? 0
    let durationSeconds = pageDuration > 0 ? pageDuration : song?.durationSeconds ?? 0
    // Until the new song loads, the page still holds the last one.
    let isLoading = pageID != videoID && pageID != "" && lastState == ""
    let hasEnded = playerState == Self.endedState || (pageID != videoID && !isLoading && pageID != "")

    if isLoading { return }

    // The page plays at its own volume until a song's first state comes, as the player may not exist before.
    if lastState == "" { run("document.getElementById('movie_player').setVolume(\(volumePercent))") }

    // Before a song starts, and while it waits for more of itself, the page plays nothing. Its state then goes
    // to the app as neither playing nor paused, so the app's clock stays still.
    let isWaiting = !hasEnded && playerState != Self.playingState && playerState != Self.pausedState

    if isWaiting { return }

    let state = hasEnded ? "stopped" : playerState == Self.pausedState ? "paused" : "playing"

    if hasEnded {
      pollTimer?.invalidate()
      pollTimer = nil
      run("document.getElementById('movie_player').pauseVideo()")
    }

    if state != lastState {
      lastState = state
      lastPositionSentAt = Date()
      send(toNowPlaying(state: state, positionSeconds: positionSeconds, durationSeconds: durationSeconds))
      return
    }

    guard state == "playing", Date().timeIntervalSince(lastPositionSentAt) >= Self.positionSendSeconds else { return }

    lastPositionSentAt = Date()
    send(["type": "position", "persistentID": Self.idPrefix + videoID, "positionSeconds": positionSeconds, "positionReadAtMs": MusicApp.nowMs()])
  }

  private func toNowPlaying(state: String, positionSeconds: Double, durationSeconds: Double) -> [String: Any] {
    guard state != "stopped", let song else { return ["type": "nowPlaying", "state": "stopped", "volumePercent": volumePercent] }

    return [
      "type": "nowPlaying", "state": state, "volumePercent": volumePercent,
      "positionSeconds": positionSeconds, "positionReadAtMs": MusicApp.nowMs(),
      "song": [
        "name": song.name, "artist": song.artistName, "album": song.albumName,
        "persistentID": Self.idPrefix + videoID, "durationSeconds": durationSeconds,
      ],
    ]
  }

  private func run(_ script: String) {
    playerView?.evaluateJavaScript(script) { _, error in
      if let error { sendError("The YouTube page answered with an error: \(error.localizedDescription)") }
    }
  }

  private func quoted(_ text: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: [text]), let array = String(data: data, encoding: .utf8) else { return "\"\"" }

    return String(array.dropFirst().dropLast())
  }
}
