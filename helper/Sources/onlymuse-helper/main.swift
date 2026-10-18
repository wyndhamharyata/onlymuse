import AppKit

// Speaks JSON lines with the app over stdin and stdout.

func toAccentMessage() -> [String: Any] {
  let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
  let hex = String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))

  return ["type": "accent", "color": hex]
}

// The helper is an app with no Dock icon, so AppKit tells it when the accent colour changes.
let application = NSApplication.shared
let music = MusicApp()

application.setActivationPolicy(.accessory)

DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { _ in
  MainActor.assumeIsolated { send(music.readNowPlaying()) }
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
  MainActor.assumeIsolated { music.sendVolumeWhenChanged() }
}

let webPlayer = WebPlayer()

startReadingCommands { command in
  switch command.type {
  case "refreshTokens": webPlayer.refreshTokens()
  case "signIn": webPlayer.signIn()
  case "playSong":
    guard let requestId = command.requestId, let song = command.song else { return }
    let persistentID: Any = music.playSong(song) ?? NSNull()
    send(["type": "playSongResult", "requestId": requestId, "persistentID": persistentID])
  default: music.apply(command)
  }
}

send(toAccentMessage())
send(music.readNowPlaying())
webPlayer.refreshTokens()
application.run()
