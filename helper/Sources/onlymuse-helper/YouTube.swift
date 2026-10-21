import AppKit
import WebKit

// music.youtube.com in a page no one sees. It plays YouTube songs with the page's own player, audio and all, so
// Premium's quality and its lack of ads apply. Google's sign-in shows in a window of its own, and WebKit keeps it.
@MainActor
final class YouTube: NSObject, WKNavigationDelegate, NSWindowDelegate {
  static let idPrefix = "yt:"

  private static let homeURL = URL(string: "https://music.youtube.com/")!
  private static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F")!
  // The page plays its own next song when one ends. Only the app's queue picks what plays, so any other song pauses.
  private static let pageScript = """
    window.onlymuseVideoID = "";
    document.addEventListener("playing", () => {
      const player = document.getElementById("movie_player");
      if (player && window.onlymuseVideoID && player.getVideoData().video_id !== window.onlymuseVideoID) player.pauseVideo();
    }, true);
    """
  // Passkeys work only in a browser, and Google's sign-in breaks after one fails, so the page sees no passkey
  // support and asks for the password.
  private static let noPasskeyScript = """
    try { delete window.PublicKeyCredential } catch (error) {}
    window.PublicKeyCredential = undefined;
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
  private var signInWindow: NSWindow?
  private var pollTimer: Timer?
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

  // Sends the cookie of music.youtube.com, empty when no account is signed in. src/youtube signs each request with it.
  func sendCookie() {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
      let header = cookies
        .filter { $0.domain.hasSuffix("youtube.com") }
        .map { "\($0.name)=\($0.value)" }
        .joined(separator: "; ")

      send(["type": "youtubeCookie", "cookie": header])
    }
  }

  func signIn() {
    if let signInWindow {
      signInWindow.makeKeyAndOrderFront(nil)
      NSApp.activate()
      return
    }

    let configuration = WKWebViewConfiguration()

    configuration.websiteDataStore = .default()
    configuration.userContentController.addUserScript(WKUserScript(source: Self.noPasskeyScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

    let webView = WKWebView(frame: .zero, configuration: configuration)

    webView.customUserAgent = WebPlayer.userAgent
    webView.navigationDelegate = self
    webView.load(URLRequest(url: Self.signInURL))

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)

    window.title = "Sign in to YouTube Music"
    window.contentView = webView
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    signInWindow = window
  }

  // Google sends the window on to music.youtube.com once the sign-in is done.
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    if webView === playerView {
      isPageLoaded = true
      run("window.onlymuseVideoID = \(quoted(videoID))")
      return
    }

    guard webView.url?.host == Self.homeURL.host else { return }

    signInWindow?.delegate = nil
    signInWindow?.close()
    signInWindow = nil
    // The player's page was loaded signed out, so it loads again with the new sign-in.
    resetPlayer()
    sendCookie()
  }

  func windowWillClose(_ notification: Notification) {
    signInWindow = nil
    sendCookie()
  }

  // Plays the song from YouTube. Answers its persistent ID, as Music.app's songs have.
  func play(_ match: SongMatch, videoID: String) -> String {
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

    let state = hasEnded ? "stopped" : playerState == Self.pausedState ? "paused" : "playing"

    if hasEnded {
      pollTimer?.invalidate()
      pollTimer = nil
      run("document.getElementById('movie_player').pauseVideo()")
    }

    // The page plays at its own volume until a song's first state comes, as the player may not exist before.
    if lastState == "" { run("document.getElementById('movie_player').setVolume(\(volumePercent))") }

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
