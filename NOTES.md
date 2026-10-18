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
- **Playing a song.** The helper looks for the song in Music.app's library by name, artist and
  album, and plays the one closest in length. When the library has none, the app puts the song in
  the library through the API, then asks again every 1.5 seconds until Music.app shows it.
- **Shuffle and repeat** belong to the app's queue. Repeat one plays the song again when Music.app
  stops at its end.
- **Next and previous** move through the queue while Music.app plays the song the queue started.
  For any other song they go to Music.app.
- **onlymuse shows only what it has a page for.** Stations, radio shows and videos stay off every
  shelf. Music.app can play a station only from its own page, so onlymuse never opens Music.app.

### Pages and where their data comes from

| Page | Source |
| --- | --- |
| Home | `/v1/me/recommendations` |
| New | `/v1/editorial/{storefront}/groupings?platform=web&name=music`. A shelf with no name is a banner and is skipped. |
| Search | `/v1/catalog/{storefront}/search` |
| Artist | `/v1/catalog/{storefront}/artists/{id}?views=…`, and the library albums of the library artist with the same name |
| Album | `/v1/catalog/{storefront}/albums/{id}?include=artists&relate=library` |
| Apple Music playlist | `/v1/catalog/{storefront}/playlists/{id}` and its `/tracks` |
| Favourite Songs, playlists | `/v1/me/library/playlists/{id}/tracks` |
| Recently Added, Artists, Albums, Songs | `/v1/me/library/…`. Artists come with `include=catalog`, for the photo and the full artist page. |
| Downloaded | The download packages of Music.app, then `/v1/catalog/{storefront}/songs?ids=…` |
| Lyrics | `/v1/catalog/{storefront}/songs/{id}/lyrics`. A 404 means the song has none. |

### Found while building

- **Tokens.** The Keychain asks again after every helper build. macOS ties Keychain access to each
  build's hash when the app has no Apple Team ID. So the tokens live only in the hidden web player's
  own WebKit storage, and in memory. The helper reads them from `MusicKit.getInstance()` on start.
- **Sign-in.** `MusicKit.getInstance().authorize()` opens Apple's sign-in popup straight away. The
  helper shows the popup in a window of its own and hides the web player's window meanwhile.
- **Favourite Songs** is the one library playlist with `canEdit` and `canDelete` both false. Its
  name follows the account's language, "Favourite Songs" in en-GB.
- **Library pages.** A library list answers at most 100 items. Its `next` link drops the query, so
  the sort order goes with it. The app keeps its own query and reads only the offset from `next`.
- **Library search** finds nothing for a term with an apostrophe, such as "SHE'S". The artist page
  searches the longest word of the name and checks the full name.
- **Library artists** have no photo. Their catalog artist has one. 6 of 629 library artists have no
  catalog artist.
- **Downloads.** Each download is a folder
  `~/Music/Music/Media.localized/Apple Music/<artist>/<album>/<song>.movpkg`. Its `boot.xml`
  names the stream file `P…_A<catalog ID>_audio_<language>_gr<rate>[_alac].m3u8` and says
  `<Complete>YES</Complete>` once the download is done. `_alac` marks a lossless download. On
  18 Oct 2026 the library held 850 downloads, 731 of them lossless.
- **Artwork.** For a streamed song, AppleScript answers the four bytes `msng`, its missing value,
  instead of an image. The helper keeps only data that starts like a PNG or a JPEG.
- **Images in GPUIX** need a definite width and height. A width of 100% draws the image at its own
  size.
- **Signing.** The helper is signed with the self-signed certificate "onlymuse local", from
  `scripts/make-signing-certificate.sh`. Every build then keeps its Automation permission.

### Persistence

- `~/Library/Application Support/onlymuse/onlymuse.sqlite`, in WAL mode, holds two tables.
  `responses` keeps Apple's answers with their ETags. `state` keeps the page and its history, the
  queue, the resume point, the open panel, the search term and the accent, as JSON per key.
- A stored answer shows at once, without waiting for the tokens. A stale one is checked with
  `If-None-Match`. Apple answers 304 for an unchanged library or catalog answer. Home changes on
  every request.
- State is saved 300 ms after each change, and the play position every 5 seconds. A force quit
  loses at most that much.
- Song lists, grids, Home, New and the album page save the key of their top row, never a pixel
  offset. A list row can scroll sideways in GPUIX 0.10, so each shelf of Home and New is a list row.
  A shelf draws only the cards in view, between two empty boxes as wide as the cards it skips.
- Artwork is saved in `~/Library/Caches/onlymuse/images`, named by a hash of its URL. A file unused
  for 60 days is removed.

## Frame times (18 Oct 2026)

`bun run bench` measures each build behind the other windows. Findings from the profile of a scroll:

- React does almost no work during a scroll. GPUI's frame is the cost: gpuix builds the element tree
  from its retained tree (about half), taffy lays it out (about a third), then prepaint and paint.
  A frame costs in proportion to the elements laid out, about 300 on a list page.
- A frame takes 5 to 7 ms at p90 against 8.3 ms at 120 Hz. Single frames reach 15 to 30 ms.
- gpuix 0.10 ships with GPUI's `test-support` on. With it, every update that dirties the window draws
  a whole frame at once: each wheel event over a list costs about 6.5 ms, a click costs two draws,
  and each React commit costs a draw too. `vendor/gpuix.patch` limits that draw
  to test windows and covered windows, so a visible window draws once per display frame. A wheel
  event then costs 0.5 ms and a commit about 0 ms.
- The app runs the patched build. `vendor/gpuix-native.darwin-arm64.node` is gpuix 0.10.0 (commit
  410fb56) built with `vendor/gpuix.patch` and Rust 1.97.1, then given SDK 26.5 with
  `vtool`. dyld rejects the string table that the SDK 27 linker writes. `bun install` runs
  `scripts/gpuix-native.ts`, which puts it in place of the published binary. On a gpuix upgrade, the
  patch must be built again or dropped.
- The patch also rests hover styles during a scroll, until 150 ms after the last wheel event. The
  rows under a still pointer change every frame, so the highlight jumped from row to row and could
  trail the content by a frame. Clicks and the cursor are unchanged.
- With the display asleep, `CGGetActiveDisplayList` lists no display and GPUI cannot create its
  display link. A bench run then measures nothing on screen.
- Up Next mounts 32 rows through gpuix's `itemCount`, not one per queued song. Opening it stalls for
  about 40 ms, most of it the two draws of the click and the first draw of the new rows.

## Open questions

- **Token refresh with an expired token.** The refresh reads a fresh developer token from the web
  player, and the app retries a 401 or a 403 once. It ran with a valid token only. The developer
  token in use expires on 22 Dec 2026.
- **Sign-in with the popup.** Tested signed out in a throwaway session. Not yet tested to the end
  with the real account.
- **Silence between songs.** Not measured. Gapless albums will not stay gapless.
- **Library growth.** Every song played goes into the library. A cleanup of songs the app added only
  to play them may help.
- **The sidebar reads the playlists once,** on start.
- **Songs started in Music.app** show no artwork in the player bar.

## Experiments

`experiments/` holds the scripts. They read the tokens from `$ONLYMUSE_TOKENS` (default
`$TMPDIR/onlymuse`): a file `dev` with the developer token and a file `mut` with the user token.
Keep tokens and `.har` exports out of this folder.

- `am.sh /v1/path` makes a GET with the tokens.
- `listen.swift` prints Music.app's playerInfo posts. Build with `swiftc -O listen.swift -o listen`.
- `axplay.swift` lists the Play and Shuffle buttons in Music.app's window. `press` presses the
  album page's Play.
