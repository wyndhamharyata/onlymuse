import AppKit
import Network
import WebKit

func readAccentMessage() -> [String: Any] {
  let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
  let hex = String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))

  return ["type": "accent", "color": hex]
}

let application = NSApplication.shared
let isPausedWhenAppEnds = ProcessInfo.processInfo.environment["GPUIX_BACKGROUND"] != "1"
let music = MusicApp()
let youTube = YouTube(music: music, isQuiet: !isPausedWhenAppEnds)
let handoff = Handoff(music: music, youTube: youTube)

signal(SIGPIPE, SIG_IGN)

let localProxy = LocalProxy()
let proxyReady = DispatchSemaphore(value: 0)
let proxyStartTimeoutSeconds = 2.0

localProxy.start { _ in proxyReady.signal() }

if proxyReady.wait(timeout: .now() + proxyStartTimeoutSeconds) == .success, let port = localProxy.port {
  WKWebsiteDataStore.default().proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))]
}

@MainActor
func pauseWhenAppEnds() {
  guard isPausedWhenAppEnds else { return }

  music.pauseIfRunning()
  youTube.stop()
}

application.setActivationPolicy(.accessory)

// ⌘V and other editing keys reach a sign-in page only through an Edit menu, even a hidden one.
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
application.mainMenu = bar

DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { _ in
  MainActor.assumeIsolated {
    let hasMusicTakenOver = !youTube.isActive || (!youTube.hasJustPausedMusic && music.readPlayback() != nil)

    guard hasMusicTakenOver else { return }

    youTube.stop()
    handoff.applyPlayerChange()
    send(music.readNowPlaying())
  }
}

NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
  MainActor.assumeIsolated { send(readAccentMessage()) }
}

let workspaceNotifications = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]

for name in workspaceNotifications {
  NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
    let changedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication

    guard changedApp?.bundleIdentifier == MusicApp.bundleIdentifier else { return }

    MainActor.assumeIsolated { send(music.readNowPlaying()) }
  }
}

// Music.app posts nothing as a song plays or its volume slider moves, so the helper reads both.
let musicCheckSeconds = 2.0

Timer.scheduledTimer(withTimeInterval: musicCheckSeconds, repeats: true) { _ in
  MainActor.assumeIsolated {
    guard !youTube.isActive else { return }

    music.sendVolumeWhenChanged()
    if let playback = music.readPlayback() { send(makePositionMessage(persistentID: playback.persistentID, positionSeconds: playback.positionSeconds)) }
  }
}

let webPlayer = WebPlayer()

startReadingCommands(onCommand: { command in
  switch command.type {
  case "refreshTokens": webPlayer.refreshTokens()
  case "signIn": webPlayer.signIn()
  case "youtubeSignIn": youTube.sendCookie()
  case "playSong", "setNext": handoff.apply(command)
  case "playPause", "seek", "setVolume":
    guard !youTube.isActive else { return youTube.apply(command) }

    music.apply(command)
    if command.type == "seek" { handoff.arm() }
  default:
    music.apply(command)
  }
}, onAppGone: { pauseWhenAppEnds() })

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

send(readAccentMessage())
send(music.readNowPlaying())
youTube.sendCookie()
webPlayer.refreshTokens()
application.run()
