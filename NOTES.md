# onlymuse

A Mac app for Apple Music without the iTunes parts. The UI is a web page in a native shell, built
the way goui for the Mac is (`~/side_project/goui/mac/engine`). Apple's own API supplies the data.
Music.app plays the sound, so playback stays lossless.

For one person only. It borrows the web player's tokens and drives Music.app, so it is not for
distribution.

## Why

- Music.app mixes Apple Music with iTunes Store and local-library parts.
- **Go to Artist** on a library song opens the library artist page, not the Apple Music one.
- The music.apple.com web player has the right UI, but streams AAC only and cannot download.
- MusicKit needs a paid developer account ($99/yr).

## Tested (18 Oct 2026, macOS 27.0.1)

### Data: Apple's API with the web player's tokens

All calls go to `https://amp-api.music.apple.com` with four headers:

- `Authorization: Bearer <developer token>`. The web player's token, issuer `AMPWebPlay`. It
  expires about every two months (the tested one runs to 22 Dec 2026).
- `media-user-token: <user token>`. The signed-in account.
- `Origin: https://music.apple.com`. The developer token only works for `apple.com` origins.
- A Safari `User-Agent`.

The storefront is **`id`** (Indonesia), from `/v1/me/storefront`. Language is `l=en-GB`.

| Endpoint | Gives |
|---|---|
| `GET /v1/me/storefront` | Store country |
| `GET /v1/me/recommendations` | The Home shelves: Made for You, Recently Played, Stations for You, New Releases for You, "More Like …" |
| `GET /v1/me/recent/played`, `/v1/me/history/heavy-rotation` | History |
| `GET /v1/me/library/{songs,albums,playlists}`, `/v1/me/library/search` | Library. Every library song carries `playParams.catalogId` |
| `GET /v1/catalog/id/songs/{id}?relate=library` | The library ID of a catalog song, or none when it is not in the library. Each release is separate (the Oikaze EP is in the library, the Oikaze single is not) |
| `GET /v1/catalog/id/songs/{id}` | `audioTraits`: `lossless`, `atmos`, `spatial`, `lossy-stereo` |
| `GET /v1/catalog/id/artists/{id}?views=top-songs,similar-artists,latest-release,full-albums&extend=artistBio` | The full artist page, with photo and bio. This is the Go to Artist page |
| `GET /v1/catalog/id/songs/{id}/lyrics`, `/syllable-lyrics` | Lyrics as TTML. Syllable lyrics are word-synced |
| `GET /v1/catalog/id/search?term=…&types=songs,artists,albums` | Catalog search |
| `POST /v1/me/library?ids[songs]=…` or `ids[albums]=…` | Puts the songs or albums in the library. HTTP 202 |

Adding to the library does not favourite anything. Checked in Music.app (`favorited`,
`album favorited`), in `/v1/me/ratings/*` and in the Favourite Songs playlist.

### Playback: Music.app through AppleScript

- A song added through the API reaches Music.app in about **6 s**. A whole album takes about
  **13 s**. Find it by name, artist and album, then `play` it.
- Music.app's scripting has **no catalog ID**. Match on name, artist, album and duration. The API's
  catalog ID tells which release to look for.
- `play` on a library song plays that song only. Music.app keeps no queue after it, and
  `next track` does nothing. `play` on a list of songs also plays one.
- Music.app posts `com.apple.Music.playerInfo` on every change. At the end of a song it posts
  `Paused`, then `Stopped`, and **stops by itself**. `PersistentID` in the post is the AppleScript
  `persistent ID` as a signed 64-bit number.
- `open location "itmss://music.apple.com/id/album/<name>/<id>"` opens the album page but does not
  play.
- Pressing the album page's Play button through Accessibility (`AXButton`, identifier `play`)
  plays the whole album in order, from the catalog, without adding it. Not used in the design, but
  it is the route for gapless albums.
- The mini player's buttons have stable identifiers (`Music.miniPlayer.*`).

### Downloads

- Music.app has automatic downloads on (`checkForAvailableDownloads = 1`). Whatever the API puts in
  the library downloads by itself.
- Downloads land in `~/Music/Music/Media.localized/Apple Music/<artist>/<album>/*.movpkg`. These are
  encrypted HLS packages holding **ALAC**. "If" (3:27) is 23 MB, about 1.1 Mbps.
- AppleScript's `download` refuses library songs ("file track"). It takes shared tracks, URL tracks
  and playlists only. Untested on those.
- AppleScript's `kind` and `bit rate` are not reliable for Apple Music songs. A downloaded ALAC song
  reads as "HLS media". A streamed one read as "Apple Music AAC audio file, 768 kbps".

### Music.app settings in use

- **Lossless Audio** on. `preferredDownloadAudioQuality` and `preferredStreamPlaybackAudioQuality`
  are both `15`.
- Output: the Mac's headphone jack into an HD 600, at a fixed rate set in Audio MIDI Setup.
  goui for the Mac EQs the output, so playback is not bit-perfect, by choice.

## Design

`design/index.html` draws every page with real data, and its tech plan. `CLAUDE.md` holds the stack,
the layout and the rules.

- The app is a Bun process that draws with GPUIX. A Swift helper speaks JSON lines with it.
- **The app owns the queue.** Music.app plays one song at a time. On `Stopped` near the end of a
  song, the app plays the next one. A stop far from the end is the user, so the queue waits.
- **Playing a song:** if `?relate=library` gives a library ID, play it at once. If not, add it,
  wait for it in Music.app, then play it.
- **Playing an album or playlist:** add it once, then queue its songs in order.
- The helper is signed with the self-signed certificate "onlymuse local", from
  `scripts/make-signing-certificate.sh`. Every build then keeps its Automation permission.
- The Keychain asks again after every build. macOS ties Keychain access to each build's hash when
  the app has no Apple Team ID. So the tokens live only in the hidden web player's own WebKit
  storage, and in memory.
- Favourite Songs is the one library playlist with `canEdit` and `canDelete` both false.

## Open questions

- **Token refresh.** Untested. The hidden web view should read
  `MusicKit.getInstance().developerToken` and `.musicUserToken`. Apple's sign-in may need a Safari
  user agent and popup handling.
- **Silence between songs.** Not measured. Gapless albums will not stay gapless.
- **Library growth.** Every song played goes into the library. A cleanup of songs the app added only
  to play them may help.
- **Using Music.app directly** while the app plays. The playerInfo posts show it. The app should
  follow, not fight.
- **Downloads with automatic downloads off.** Not needed now.
- **Accessibility permission** for the Play-button route resets on every ad hoc rebuild, as goui's
  audio permission does.

## Experiments

`experiments/` holds the scripts. They read the tokens from `$ONLYMUSE_TOKENS` (default
`$TMPDIR/onlymuse`): a file `dev` with the developer token and a file `mut` with the user token.
Keep tokens and `.har` exports out of this folder.

- `am.sh /v1/path` makes a GET with the tokens.
- `listen.swift` prints Music.app's playerInfo posts. Build with `swiftc -O listen.swift -o listen`.
- `axplay.swift` lists the Play and Shuffle buttons in Music.app's window. `press` presses the
  album page's Play.
