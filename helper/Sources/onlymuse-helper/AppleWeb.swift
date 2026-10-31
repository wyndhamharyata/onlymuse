import AppKit
import WebKit

@MainActor
final class AppleWeb: NSObject, WKNavigationDelegate {
  static let idPrefix = "am:"

  private static let startURL = URL(string: "https://music.apple.com/id/browse")!
  private static let pollSeconds = 0.5
  private static let positionSendSeconds = 2.0
  private static let startReportSeconds = 20.0
  private static let pausedState = 3
  private static let waitingStates = [0, 1, 6, 7, 8]
  private static let endedStates = [4, 5, 9]

  private let music: MusicApp
  private let isQuiet: Bool
  private var view: WKWebView?
  private var window: NSWindow?
  private var pollTimer: Timer?
  private var song: SongMatch?
  private var isPageLoaded = false
  private var catalogID = ""
  private var lastState: String?
  private var lastError = ""
  private var hasReportedStart = false
  private var lastPositionSentAt = Date.distantPast
  private var startedAt = Date.distantPast
  private var resumeSeconds = 0.0
  private var pendingSeek = -1.0
  private var volumePercent = 100

  private(set) var isActive = false

  init(music: MusicApp, isQuiet: Bool) {
    self.music = music
    self.isQuiet = isQuiet
  }

  private var scriptVolume: Double {
    isQuiet ? 0 : Double(volumePercent) / 100
  }

  func play(_ match: SongMatch, catalogID: String) -> String {
    if !isQuiet { music.pauseIfRunning() }

    isActive = true
    song = match
    self.catalogID = catalogID
    lastState = nil
    lastError = ""
    hasReportedStart = false
    resumeSeconds = 0
    pendingSeek = -1
    startedAt = Date()

    if isPageLoaded { run(toPlayScript()) } else { _ = startView() }

    var loading = makeNowPlaying(state: "playing", positionSeconds: 0, durationSeconds: match.durationSeconds)
    loading["isLoading"] = true
    send(loading)
    startPolling()

    return Self.idPrefix + catalogID
  }

  func stop() {
    guard isActive else { return }

    isActive = false
    pollTimer?.invalidate()
    pollTimer = nil
    run("window.onlymuseSong = \"\"; window.MusicKit?.getInstance?.()?.pause(); true")
    send(makeNowPlaying(state: "stopped", positionSeconds: 0, durationSeconds: 0))
  }

  func apply(_ command: Command) {
    switch command.type {
    case "playPause":
      guard isPageLoaded else { return }

      run("(() => { const music = window.MusicKit?.getInstance?.(); if (!music) return false; music.isPlaying ? music.pause() : music.play(); return true })()")
    case "seek":
      guard let positionSeconds = command.positionSeconds else { return }

      resumeSeconds = positionSeconds

      if lastState == nil {
        pendingSeek = positionSeconds
        if isPageLoaded { run("window.onlymuseSeek = \(positionSeconds); true") }
      } else {
        run("window.MusicKit?.getInstance?.()?.seekToTime(\(positionSeconds)); true")
      }
    case "setVolume":
      guard let volumePercent = command.volumePercent?.value else { return }

      self.volumePercent = volumePercent
      if isPageLoaded { run(toVolumeScript()) }
    default:
      break
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === view else { return }

    isPageLoaded = true

    if isActive { run(toPlayScript()) }
  }

  private func run(_ script: String) {
    startView().evaluateJavaScript(script) { _, error in
      if let error { sendError("The Apple Music page answered with an error: \(error.localizedDescription)") }
    }
  }

  private func toPlayScript() -> String {
    """
    (() => {
      const id = "\(catalogID)";
      const volume = \(scriptVolume);
      const startedAt = Date.now();
      window.onlymuseSong = id;
      window.onlymuseSeek = \(resumeSeconds);
      window.onlymuseError = "";
      const attempt = () => {
        if (window.onlymuseSong !== id) return;
        const music = window.MusicKit?.getInstance?.();
        if (!music) {
          if (Date.now() - startedAt < 15000) return setTimeout(attempt, 250);
          window.onlymuseError = "the page has no player";
          return;
        }
        music.setQueue({ song: id })
          .then(() => {
            music.volume = volume;
            const seek = window.onlymuseSeek || 0;
            return seek > 0 ? music.seekToTime(seek) : undefined;
          })
          .then(() => music.play())
          .catch((error) => { window.onlymuseError = String(error); });
      };
      attempt();
      return true;
    })()
    """
  }

  private func toVolumeScript() -> String {
    "window.MusicKit?.getInstance?.() && (window.MusicKit.getInstance().volume = \(scriptVolume)); true"
  }

  private func startPolling() {
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
  }

  private func poll() {
    guard isActive, let view else { return }

    view.evaluateJavaScript(Self.readStateScript) { [weak self] result, _ in
      MainActor.assumeIsolated {
        guard let self, self.isActive else { return }

        guard let text = result as? String,
          let data = text.data(using: .utf8),
          let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return self.reportSlowStart() }

        self.apply(page: page)
      }
    }
  }

  private func apply(page: [String: Any]) {
    let error = page["error"] as? String ?? ""

    if !error.isEmpty { return applyError(error) }

    let state = page["state"] as? Int ?? 0
    var positionSeconds = page["position"] as? Double ?? 0
    let pageDurationSeconds = page["duration"] as? Double ?? 0
    let durationSeconds = pageDurationSeconds > 0 ? pageDurationSeconds : song?.durationSeconds ?? 0

    if Self.waitingStates.contains(state) { return reportSlowStart() }

    if Self.endedStates.contains(state) {
      if lastState == nil { return reportSlowStart() }

      finish()
      send(makeNowPlaying(state: "stopped", positionSeconds: 0, durationSeconds: 0))
      return
    }

    let stateText = state == Self.pausedState ? "paused" : "playing"

    if stateText == "playing", pendingSeek >= 0 {
      run("window.MusicKit?.getInstance?.()?.seekToTime(\(pendingSeek)); true")
      positionSeconds = pendingSeek
      pendingSeek = -1
    }

    var nowPlaying = makeNowPlaying(state: stateText, positionSeconds: positionSeconds, durationSeconds: durationSeconds)

    if stateText == "playing" { nowPlaying["hasStarted"] = true }

    if stateText != lastState {
      lastState = stateText
      lastPositionSentAt = Date()
      send(nowPlaying)
      return
    }

    guard stateText == "playing", Date().timeIntervalSince(lastPositionSentAt) >= Self.positionSendSeconds else { return }

    lastPositionSentAt = Date()
    send(makePositionMessage(persistentID: Self.idPrefix + catalogID, positionSeconds: positionSeconds))
  }

  private func applyError(_ text: String) {
    guard text != lastError else { return }

    lastError = text
    sendError("Apple Music did not play the song: \(text)")
    finish()
    send(makeNowPlaying(state: "stopped", positionSeconds: 0, durationSeconds: 0))
  }

  private func finish() {
    pollTimer?.invalidate()
    pollTimer = nil
    isActive = false
    lastState = "stopped"
    run("window.onlymuseSong = \"\"; window.MusicKit?.getInstance?.()?.pause(); true")
  }

  private func reportSlowStart() {
    guard !hasReportedStart, Date().timeIntervalSince(startedAt) >= Self.startReportSeconds else { return }

    hasReportedStart = true
    sendError("Apple Music did not start \(song?.name ?? "the song") within \(Int(Self.startReportSeconds)) s.")
    finish()
    send(makeNowPlaying(state: "stopped", positionSeconds: 0, durationSeconds: 0))
  }

  private func makeNowPlaying(state: String, positionSeconds: Double, durationSeconds: Double) -> [String: Any] {
    guard state != "stopped", let song else {
      return ["type": "nowPlaying", "state": "stopped", "volumePercent": volumePercent]
    }

    return [
      "type": "nowPlaying", "state": state, "volumePercent": volumePercent,
      "positionSeconds": positionSeconds, "positionReadAtMs": nowMs,
      "song": [
        "name": song.name, "artist": song.artistName, "album": song.albumName,
        "persistentID": Self.idPrefix + catalogID, "durationSeconds": durationSeconds,
      ],
    ]
  }

  private func startView() -> WKWebView {
    if let view { return view }

    let configuration = WKWebViewConfiguration()

    configuration.websiteDataStore = .default()
    configuration.mediaTypesRequiringUserActionForPlayback = []

    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)

    view.customUserAgent = WebPlayer.userAgent
    view.navigationDelegate = self
    view.load(URLRequest(url: Self.startURL))

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

    self.view = view
    self.window = window

    return view
  }

  private static let readStateScript = """
    (() => {
      const music = window.MusicKit?.getInstance?.();
      if (!music) return JSON.stringify({ state: 0, error: window.onlymuseError || "" });
      const item = music.nowPlayingItem;
      return JSON.stringify({
        id: (item && (item.id || (item.playParams && item.playParams.id))) || "",
        state: music.playbackState,
        position: music.currentPlaybackTime || 0,
        duration: music.currentPlaybackDuration || 0,
        error: window.onlymuseError || ""
      });
    })()
    """
}
