import Foundation
// Prints every com.apple.Music.playerInfo broadcast for N seconds.
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "12") ?? 12
let start = Date()
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { n in
  let i = n.userInfo ?? [:]
  print(String(format: "%5.1fs", Date().timeIntervalSince(start)), i["Player State"] ?? "-", "|", i["Name"] ?? "-", "|", i["Album"] ?? "-", "| PersistentID", i["PersistentID"] ?? "-")
}
print("listening"); fflush(stdout)
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
