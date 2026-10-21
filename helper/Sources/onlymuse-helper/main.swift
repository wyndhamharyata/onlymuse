import AppKit

// Speaks JSON lines with the app over stdin and stdout.

func toAccentMessage() -> [String: Any] {
  let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
  let hex = String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))

  return ["type": "accent", "color": hex]
}

// The helper is an app with no Dock icon, so AppKit tells it when the accent colour changes.
let application = NSApplication.shared
// A window behind the others is a bench or test run, which must leave the music as it is when it ends.
let pausesWhenAppEnds = ProcessInfo.processInfo.environment["GPUIX_BACKGROUND"] != "1"
let music = MusicApp()
let youTube = YouTube(music: music, isQuiet: !pausesWhenAppEnds)
let handoff = Handoff(music: music, youTube: youTube)

@MainActor
func pauseWhenAppEnds() {
  guard pausesWhenAppEnds else { return }

  music.pauseIfRunning()
  youTube.stop()
}

application.setActivationPolicy(.accessory)

// ⌘V and the other editing keys reach a sign-in page only through an Edit menu. The helper shows no menu bar, but its keys still work.
func toEditMenu() -> NSMenu {
  let bar = NSMenu()
  let editItem = NSMenuItem()
  let edit = NSMenu(title: "Edit")

  edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
  edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
  edit.addItem(.separator())
  edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
  edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
  edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
  editItem.submenu = edit
  bar.addItem(editItem)

  return bar
}

application.mainMenu = toEditMenu()

// The handoff reacts first, so the queue's next song replaces a pick of Music.app's before more of it plays.
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { _ in
  MainActor.assumeIsolated {
    // Music.app pauses when a YouTube song starts. Only a song it plays again takes the player back.
    if youTube.isActive {
      guard music.readPlayback() != nil else { return }

      youTube.stop()
    }

    handoff.onPlayerChange()
    send(music.readNowPlaying())
  }
}

NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
  MainActor.assumeIsolated { send(toAccentMessage()) }
}

let workspaceNotifications = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]

for name in workspaceNotifications {
  NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
    let launched = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication

    guard launched?.bundleIdentifier == MusicApp.bundleIdentifier else { return }

    MainActor.assumeIsolated { send(music.readNowPlaying()) }
  }
}

let volumeCheckSeconds = 2.0

Timer.scheduledTimer(withTimeInterval: volumeCheckSeconds, repeats: true) { _ in
  MainActor.assumeIsolated {
    if !youTube.isActive { music.sendVolumeWhenChanged() }
  }
}

// Music.app posts no position as a song plays, so the helper sends it, and the app's clock follows a seek made in Music.app.
let positionCheckSeconds = 2.0

Timer.scheduledTimer(withTimeInterval: positionCheckSeconds, repeats: true) { _ in
  MainActor.assumeIsolated {
    if !youTube.isActive, let position = music.readPosition() { send(position) }
  }
}

let webPlayer = WebPlayer()

startReadingCommands(onCommand: { command in
  switch command.type {
  case "refreshTokens": webPlayer.refreshTokens()
  // The app reloaded its code and keeps this helper, so it asks for what the helper sent at start.
  case "sendState":
    send(toAccentMessage())
    youTube.isActive ? youTube.sendState() : send(music.readNowPlaying())
    youTube.sendCookie()
  case "signIn": webPlayer.signIn()
  case "youtubeSignIn": youTube.sendCookie()
  case "playSong":
    guard let requestId = command.requestId, let song = command.song else { return }
    var persistentID: Any = NSNull()

    if let videoID = song.youTubeVideoID {
      persistentID = youTube.play(song, videoID: videoID)
    } else {
      youTube.stop()
      persistentID = music.playSong(song) ?? NSNull()
    }

    send(["type": "playSongResult", "requestId": requestId, "persistentID": persistentID])
  case "trackInfo":
    guard let persistentID = command.persistentID else { return }
    send(music.readTrackInfo(persistentID: persistentID))
  case "setFavorite":
    guard let favorited = command.favorited else { return }
    let changedID = music.setFavorite(persistentID: command.persistentID, match: command.song, favorited: favorited)
    var result: [String: Any] = ["type": "setFavoriteResult", "favorited": favorited, "persistentID": changedID ?? NSNull()]
    if let requestId = command.requestId { result["requestId"] = requestId }
    send(result)
    if let changedID { send(music.readTrackInfo(persistentID: changedID)) }
  case "setNext":
    guard let requestId = command.requestId else { return }
    // After a YouTube song, the app starts the next song itself once the page says the song ended.
    let isAfterYouTube = command.afterPersistentID?.hasPrefix(YouTube.idPrefix) ?? false
    let persistentID: Any = handoff.set(afterID: isAfterYouTube ? nil : command.afterPersistentID, next: command.song) ?? NSNull()
    send(["type": "setNextResult", "requestId": requestId, "persistentID": persistentID])
  case "playPause", "seek", "setVolume":
    guard !youTube.isActive else { return youTube.apply(command) }

    music.apply(command)
    // A seek moves the end, and Music.app posts nothing for it.
    if command.type == "seek" { handoff.arm() }
  default:
    music.apply(command)
  }
}, onAppGone: { pauseWhenAppEnds() })

// Ctrl-C and a closed terminal signal the helper with the app, so the helper pauses before the pipe closes.
var signalSources: [DispatchSourceSignal] = []

for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
  signal(signalNumber, SIG_IGN)

  let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)

  source.setEventHandler {
    MainActor.assumeIsolated { pauseWhenAppEnds() }
    exit(0)
  }
  source.resume()
  signalSources.append(source)
}

send(toAccentMessage())
send(music.readNowPlaying())
youTube.sendCookie()
webPlayer.refreshTokens()
application.run()
