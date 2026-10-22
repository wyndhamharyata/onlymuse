import AppKit
import WebKit

// music.youtube.com in a page no one sees. It plays YouTube songs with the page's own player, audio and all, so
// Premium's quality and its lack of ads apply. It is signed in with Helium's YouTube cookies.
@MainActor
final class YouTube: NSObject, WKNavigationDelegate {
  static let idPrefix = "yt:"

  // The page plays its own next song when one ends. Only the app's queue picks what plays, so any other song pauses.
  // A song loaded ahead, while Music.app plays, is muted and paused once it starts, so it waits ready to play.
  // A page first loaded for that says so in its address, as the page plays its song before didFinish.
  private static let pageScript = """
    window.onlymuseVideoID = "";
    window.onlymuseIsPreparing = location.hash === "#\(YouTube.prepareHash)";
    document.addEventListener("play", (event) => { if (window.onlymuseIsPreparing) event.target.muted = true }, true);
    document.addEventListener("playing", () => {
      const player = document.getElementById("movie_player");
      if (!player) return;
      if (window.onlymuseIsPreparing || (window.onlymuseVideoID && player.getVideoData().video_id !== window.onlymuseVideoID)) player.pauseVideo();
    }, true);
    """
  private static let prepareHash = "onlymuse-prepare"
  // The page may load a song's address and fetch none of it until it is played, so it is played, muted and
  // paused at once, until its length is known.
  private static let nudgeScript = """
    (() => {
      const player = document.getElementById("movie_player");
      if (!window.onlymuseIsPreparing || !player || !player.getPlayerState) return false;
      player.mute();
      if (player.getPlayerState() === \(pausedState) && player.getDuration() > 0) return true;
      if (player.getPlayerState() !== \(playingState)) player.playVideo();
      return false;
    })()
    """
  private static let nudgeSeconds = 1.0
  private static let maxNudgeCount = 30
  // A quiet run mutes each song before it makes a sound, and the page's player can never turn it back on.
  private static let muteScript = """
    (() => {
      const muted = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "muted");
      const volume = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume");
      Object.defineProperty(HTMLMediaElement.prototype, "muted", { get() { return true }, set() {}, configurable: true });
      Object.defineProperty(HTMLMediaElement.prototype, "volume", { get() { return 0 }, set() {}, configurable: true });
      document.addEventListener("play", (event) => { muted.set.call(event.target, true); volume.set.call(event.target, 0) }, true);
    })();
    """
  private static let readStateScript = """
    (() => {
      const player = document.getElementById("movie_player");
      if (!player || !player.getVideoData) return "";
      return JSON.stringify({ id: player.getVideoData().video_id, state: player.getPlayerState(), position: player.getCurrentTime(), duration: player.getDuration() });
    })()
    """
  // What the page shows when its song stops by itself, for the Console.
  private static let readProblemScript = """
    (() => JSON.stringify({
      visibility: document.visibilityState,
      error: document.querySelector(".ytp-error")?.innerText ?? "",
      dialogs: [...document.querySelectorAll("tp-yt-paper-dialog, ytmusic-you-there-renderer")].filter((dialog) => dialog.offsetParent).map((dialog) => dialog.innerText.slice(0, 200)),
      hasSource: !!document.querySelector("video")?.src,
    }))()
    """
  private static let pollSeconds = 0.5
  // A song that stops by itself for this long after it played loads again where it stopped, at most maxReloadCount times.
  private static let stuckSeconds = 10.0
  private static let maxReloadCount = 2
  // A song starts about a second after the page has it. One not started this long after is asked for again, then
  // the page opens again with it.
  private static let slowStartSeconds = 4.0
  // Asks again once, then opens the page again once, then gives up.
  private static let maxStartRetryCount = 2
  // Music.app's posts this soon after the helper paused it may still say it plays.
  private static let pauseSettleSeconds = 2.0
  // The page goes this long after the last YouTube song, as it holds 200 MB or more, unless the queue has more.
  // The next song loads it again.
  private static let idleCloseSeconds = 5.0 * 60
  private static let positionSendSeconds = 2.0
  // The page's player states, as YT.PlayerState names them.
  private static let endedState = 0
  private static let playingState = 1
  private static let pausedState = 2
  private static let bufferingState = 3
  private static let unstartedState = -1

  private let music: MusicApp
  // A test or bench run plays YouTube muted, and leaves Music.app playing.
  private let isQuiet: Bool
  private var playerView: WKWebView?
  private var playerWindow: NSWindow?
  private var pollTimer: Timer?
  private var nudgeTimer: Timer?
  private var idleTimer: Timer?
  private var song: SongMatch?
  private var videoID = ""
  // The song loaded ahead, to play next.
  private var preparedID = ""
  private var isPageLoaded = false
  private var pausedMusicAt = Date.distantPast
  private var lastState = ""
  private var lastPositionSentAt = Date.distantPast
  private var playedSeconds = 0.0
  private var stuckSince: Date?
  private var reloadCount = 0
  private var startAskedAt = Date.distantPast
  private var startRetryCount = 0
  // Where the song starts once the page opens again, after it stopped partway.
  private var resumeSeconds = 0.0
  private var volumePercent = 100

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

  // Plays the song, at once when it was loaded ahead, and with sound again after it waited muted.
  // forcesLoad loads the song again even when the page already holds it, from startSeconds.
  private func toPlayScript(forcesLoad: Bool = false, startSeconds: Double = 0) -> String {
    let id = quoted(videoID)
    let unmute = isQuiet ? "" : "const video = document.querySelector('video'); if (video) video.muted = false; player?.unMute?.();"

    return """
      (() => {
        window.onlymuseIsPreparing = false;
        window.onlymuseVideoID = \(id);
        const player = document.getElementById('movie_player');
        \(unmute)
        if (!player || !player.getVideoData) return;
        if (\(!forcesLoad) && player.getVideoData().video_id === \(id) && player.getPlayerState() !== \(Self.endedState)) {
          if (player.getCurrentTime() > 1) player.seekTo(0, true);
          player.playVideo();
        } else {
          player.loadVideoById({ videoId: \(id), startSeconds: \(startSeconds) });
        }
      })()
      """
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
        guard let self, self.isActive else { return }
        self.checkSlowStart()
        guard let text = result as? String, let data = text.data(using: .utf8), let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          return self.checkStuck(playerState: nil)
        }

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

    // Before a song starts, and while it waits for more of itself, the page plays nothing, and the app hears
    // nothing new. A song that played and then waits too long loads again.
    let isWaiting = !hasEnded && playerState != Self.playingState && playerState != Self.pausedState

    if isWaiting { return checkStuck(playerState: playerState) }

    stuckSince = nil
    if playerState == Self.playingState { playedSeconds = positionSeconds }

    let state = hasEnded ? "stopped" : playerState == Self.pausedState ? "paused" : "playing"

    if hasEnded {
      pollTimer?.invalidate()
      pollTimer = nil
      run("document.getElementById('movie_player').pauseVideo()")
    }

    if state != lastState {
      lastState = state
      lastPositionSentAt = Date()
      var nowPlaying = toNowPlaying(state: state, positionSeconds: positionSeconds, durationSeconds: durationSeconds)
      // The page says it plays only once it does, so its clock moves on from the first post.
      if state == "playing" { nowPlaying["hasStarted"] = true }
      send(nowPlaying)
      return
    }

    guard state == "playing", Date().timeIntervalSince(lastPositionSentAt) >= Self.positionSendSeconds else { return }

    lastPositionSentAt = Date()
    send(["type": "position", "persistentID": Self.idPrefix + videoID, "positionSeconds": positionSeconds, "positionReadAtMs": MusicApp.nowMs()])
  }

  // The song has not started long after the page had it, as when the page's load of it hangs with no error.
  private func checkSlowStart() {
    guard lastState == "", isPageLoaded, Date().timeIntervalSince(startAskedAt) >= Self.slowStartSeconds else { return }

    startAskedAt = Date()
    startRetryCount += 1
    let name = song?.name ?? videoID

    // The app shows the song as paused at its start, so the person can press Play again or skip it.
    guard startRetryCount <= Self.maxStartRetryCount else {
      sendError("The YouTube page still has not started \(name).")
      run("document.getElementById('movie_player')?.pauseVideo()")
      lastState = "paused"
      send(toNowPlaying(state: "paused", positionSeconds: 0, durationSeconds: song?.durationSeconds ?? 0))
      return
    }

    playerView?.evaluateJavaScript("JSON.stringify({ state: \(Self.readStateScript), problem: \(Self.readProblemScript) })") { result, _ in
      sendError("The YouTube page had not started \(name) after \(Int(Self.slowStartSeconds)) s. The page showed: \(result as? String ?? "nothing")")
    }

    if startRetryCount == 1 {
      sendError("The helper asks the YouTube page for \(name) again.")
      run(toPlayScript(forcesLoad: true))
    } else {
      reopenPage(startSeconds: 0)
    }
  }

  // WebKit's network process can keep a connection that sends nothing, as when the network allows only smaller
  // packets than HTTP/3 sends, and each request on it hangs for two minutes. A new network process makes new
  // connections, then the page opens again with the song from startSeconds.
  private func reopenPage(startSeconds: Double) {
    sendError("The helper starts its network connections again and opens the YouTube page again for \(song?.name ?? videoID).")
    resumeSeconds = startSeconds
    isPageLoaded = false

    let store = WKWebsiteDataStore.default()
    let terminate = NSSelectorFromString("_terminateNetworkProcess")
    if store.responds(to: terminate) { store.perform(terminate) }

    playerView?.load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(videoID)")!))
  }

  // The page stopped a song that played, by itself: it answers no state, or one neither playing nor paused. It
  // loads the song again where it stopped, and after maxReloadCount tries the app shows it paused.
  private func checkStuck(playerState: Int?) {
    guard lastState == "playing" else { return }
    guard let since = stuckSince else {
      stuckSince = Date()
      return
    }
    guard Date().timeIntervalSince(since) >= Self.stuckSeconds else { return }

    stuckSince = Date()
    reloadCount += 1
    let name = song?.name ?? videoID
    let position = Int(playedSeconds)
    let stateText = playerState.map { "state \($0)" } ?? "no answer"

    playerView?.evaluateJavaScript(Self.readProblemScript) { result, _ in
      sendError("The YouTube page stopped \(name) at \(position / 60):\(String(format: "%02d", position % 60)) by itself (\(stateText)). The page showed: \(result as? String ?? "nothing")")
    }

    guard reloadCount <= Self.maxReloadCount else {
      lastState = "paused"
      stuckSince = nil
      send(toNowPlaying(state: "paused", positionSeconds: playedSeconds, durationSeconds: song?.durationSeconds ?? 0))
      return sendError("\(name) did not play again after \(Self.maxReloadCount) tries, so it shows as paused.")
    }

    guard reloadCount == 1 else { return reopenPage(startSeconds: playedSeconds) }

    sendError("The helper loads \(name) again from where it stopped.")
    run(toPlayScript(forcesLoad: true, startSeconds: playedSeconds))
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
