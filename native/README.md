# onlymuse native

A new version of onlymuse written in Odin. It draws its own window with Metal, its own text with
CoreText and its own UI. It is kept apart from the gpuix app in `../src`, which still works as before.

## Build and run

Needs Odin 2026-10 or later (`brew install odin`).

```
cd ~/side_project/onlymuse/native
./build.sh release
./build/onlymuse
```

`./build.sh` with no argument makes a debug build. It is slower but easier to step through.

## Keys

| Key | Does |
| --- | --- |
| `⌘+` / `⌘-` / `⌘0` | Zoom in, out, and back to 100% |
| `⌘]` / `⌘[` | Lyrics 50 ms earlier or later |
| `⌘Q` | Quit |

## Try it, milestone by milestone

### 0. The window

Open the app. The window blurs what is behind it and tints it dark at 85%, like the gpuix app.

- Move a window or a wallpaper behind it. The blur follows.
- Move the mouse over the window. A faint circle follows the pointer, with no lag you can see.
- Leave it alone. Activity Monitor shows about 0% CPU, as it draws only when something changes.

### 1. Text

The window shows 2,000 song rows, in English and Japanese.

- Scroll with the trackpad, fast and slow. A flick keeps gliding and slows down as macOS decides.
- Hover the rows. Each one lights up under the pointer.
- Press `⌘+` a few times. Text stays sharp at every size, Japanese included.
- With `OM_FRAMES=1`, the top right corner shows how long the last frame took to build. It stays well under 1 ms.

To measure the scrolling yourself:

```
OM_BENCH=1 ./build/onlymuse
```

The window scrolls by itself for 10 seconds, then prints frame times and quits.

### 2. The UI core

The window is now built from boxes, the way the real pages will be. It shows a sidebar, the page
title, a list of 2,000 songs and an Up Next panel.

- Click a sidebar item. It takes the accent colour and the title changes. Hover and press fade in and out.
- Click a song row to select it.
- Click Up Next at the top right. The panel slides in and fades in. Click again and it slides away.
- Scroll the list. Only the rows on screen are built, so 2,000 rows cost as little as 20.
- Resize the window, or zoom with `⌘+`. Everything lays out again.

`OM_BENCH=1 ./build/onlymuse` prints frame times as before, now through the whole UI.

### 3. Albums with covers

The app opens on Albums: every album in your library, read from the gpuix app's saved answers in
`~/Library/Application Support/onlymuse/onlymuse.sqlite`. The file is only read, never written.

- The first run downloads the covers into `~/Library/Caches/onlymuse-native/images`. Each one fades in
  as it arrives. Later runs read them from disk.
- Scroll fast from top to bottom and back. Covers scrolled past before they loaded are skipped, so
  the ones on screen come first.
- Hover a cover. It lights up a little.
- Long names end in an ellipsis. Songs in the sidebar still shows the 2,000-row list.
- Open Activity Monitor and scroll for a minute. Memory stays near 275 MB. The app keeps at most 160
  covers on the GPU and never unloads one on screen.

To measure three passes over the whole library:

```
OM_BENCH=1 OM_BENCH_FRAMES=8000 ./build/onlymuse
```

### 4. Lyrics

The app now starts the Swift helper, as the gpuix app does, so build it once first with
`cd .. && bun run helper`. The panel on the right opens on Lyrics.

- Play a song in Music.app, or in the gpuix app. The panel shows its name and lyrics.
- Each word fades into your accent colour as it is sung. The line before fades back as the next one
  starts. The lines glide up so the current one stays fourth from the top.
- A Japanese line shows its pronunciation in Latin letters under it, lit word by word too.
- `⌘]` runs the lyrics 50 ms earlier and `⌘[` 50 ms later. A note shows the new lead for 2 seconds.
  The app starts from the lead you saved in the gpuix app, 0.5 s by default.
- Pause in Music.app. The lyrics stop. Between words the app draws nothing, so it stays near 4% CPU
  while a song plays.
- Click Up Next and Lyrics to switch tabs. The Up Next list is still sample songs.

Quitting the app pauses Music.app, as the gpuix app does.

To try it without Music.app, with a stand-in that says "soldier game" by ADO plays from 30 s:

```
OM_HELPER=$PWD/tools/fake-helper.sh OM_BACKGROUND=1 ./build/onlymuse
```

### 5a. The whole window, and the player bar

The window now has the gpuix app's layout: sidebar, toolbar, page, side panel and player bar.

- The sidebar shows Apple Music, Library and your playlists, with SF Symbols. Click an item to open
  it. Albums and Songs work. The other pages say they come later.
- Back and Forward at the top left step through the pages you opened.
- Songs shows your library's songs, with artwork, album and length.
- The player bar shows the playing song with Music.app's artwork. Play, Pause, Previous and Next
  control Music.app. Click or drag along the bar to seek. The clock ticks once a second, and nothing
  else draws in between.
- Drag the volume bar to set Music.app's volume.
- The two buttons left of the volume open Lyrics and Up Next in the panel. Click the lit one to close
  it. Up Next comes with the queue in the next step. Shuffle and repeat too.

### 5b. The queue, and the app's own saved state

The app now keeps its own SQLite file in `~/Library/Application Support/onlymuse-native`. The first run
copies the gpuix app's file, so your queue, shuffle, repeat and lyrics lead carry over. The gpuix
app's file is only read.

- Open Songs and click a song. It plays in Music.app, and the songs after it make the queue.
- Click the list button left of the volume to see Up Next. The playing song is lit. Click another to
  play it. Hover one to show its × and remove it.
- Let a song end. The next one starts right away, with no Autoplay song between, as in the gpuix app.
- Shuffle and repeat work in the player bar. Repeat goes off, all, one.
- Previous goes back a song, or starts this one again once 3 seconds have played.
- A catalog song not yet in your library shows "Adding to library…" while Apple adds it, then plays.
- Quit Music.app. The player keeps the last song and where it was. Press play to resume it.

To try the queue without Music.app, with a stand-in that plays at 60 times the speed:

```
OM_HELPER=$PWD/tools/fake-music.py OM_FAKE_SPEED=60 OM_BACKGROUND=1 ./build/onlymuse
```

### 5c. Home, New, albums and playlists

Pages now read Apple's API the way the gpuix app does. A saved answer shows at once. One older than
its rule is checked with Apple meanwhile (Home 10 minutes, New 60 minutes, catalog pages a day), and
the page updates if Apple has something newer.

- Home and New show their shelves. The first shelf has bigger tiles. Swipe sideways on a shelf to
  scroll it. Swipe up and down anywhere to scroll the page.
- Click an album on a shelf, or in Albums, to open it: cover, artist, genre and year, badges such as
  LOSSLESS and In Library, Play, Shuffle and the songs. Click the artist's name to go to the artist,
  which comes in the next step.
- Click a song on a shelf to play the shelf's songs from it.
- Click a playlist in the sidebar or on a shelf to open it. Favourite Songs and Recently Added work too.

### 5d. Every library page, artists and Downloaded

- Songs, Favourite Songs, Downloaded and every playlist share one list: title, song count, Play,
  Shuffle and rows with artwork, artist and album. Long lists build only the rows on screen.
- Albums, Artists and Recently Added share one grid with an item count. Artists are round.
- Every page now reads Apple's API, as Home does, so a song added on another device shows up.
- Click an artist to open their page: the photo fades into the window, Play and Shuffle play their
  top songs, then Top Songs, In Your Library, Albums and Similar Artists.
- Downloaded lists the songs Music.app has downloaded, from its download folder, with how many are
  lossless.

### 5e. Search, the player bar's extras, saved state and sign-in

- Click Search in the sidebar and type, in any script. Japanese input composes in the field, with
  the unfinished text underlined and the candidates under the caret. Return searches. Escape or a
  click elsewhere leaves the field. Backspace, Option Backspace, the arrows, Cmd A and Cmd V work.
  The term is kept for the next run.
- Search results show the top artist, songs, albums and artists.
- Click the artist and album line in the player bar to open the Apple Music artist.
- A long song name ends in "…". Rest the pointer on it and it slides to show the rest.
- A lossless song from the queue shows LOSSLESS next to its name.
- Quit and open again. The app opens on the page you left, scrolled where you left it, with Back and
  Forward, the panel and the zoom as they were. Back and Forward also return each page to its place.
- Zoom goes through the gpuix app's steps, from 67% to 200%.
- When the helper finds no music.apple.com sign-in, a card asks you to sign in and opens Apple's page.

### 6a. One panel control and artwork placeholders

From here the app goes its own way rather than copying Apple Music.

- The Up Next / Lyrics tabs sit at the bottom of the side panel, and are the only way to switch it.
  The tabs at its top and the two buttons by the volume are gone. One button by the volume shows and
  hides the panel, opening it on the tab it last showed.
- An artist with no photo shows their album cover filling the circle, not inset on a square of colour.
- While a cover loads, its tile shows a gradient with a symbol of what it is (album, playlist,
  artist, song). Apple Music items use the cover's own colours, so the cover fades in over its own
  palette. Library items have no colours from Apple, so the name picks two hues, and an album keeps
  the same colours everywhere.

## Development settings

| Variable | Does |
| --- | --- |
| `OM_BENCH=1` | Scrolls by itself for 1,200 frames, prints frame times and quits. |
| `OM_FRAMES=1` | Shows how long each frame took to build, at the top right. |
| `OM_FAKE_LOG=<file>` | The fake helpers write the commands they get to this file. |
| `OM_FAKE_SPEED=<n>` | `tools/fake-music.py` plays songs n times faster, so they end in seconds. |
| `OM_FAKE_MISSING=<name>` | `tools/fake-music.py` finds this song only on the 4th ask, as if Apple were adding it. |
| `OM_HELPER=<file>` | Runs this instead of the Swift helper. `tools/fake-helper.sh` says a song plays. |
| `OM_FAKE_POSITION=<seconds>` | Where the fake helper's song starts. |
| `OM_BACKGROUND=1` | For the tests. Opens the window behind the others, never focused and with no Dock icon, so AeroSpace leaves it floating. macOS stops a covered window's display link, so a timer runs its frames, which are captured but not shown. The helper leaves Music.app as it is when the app quits. Captures set it. The bench keeps its window in front, as it measures the screen. |
| `OM_DATA=<folder>` | Keeps `onlymuse.sqlite` in this folder instead. |
| `OM_BENCH_FRAMES=<count>` | Frames the bench runs. 1,200 by default. |
| `OM_CAPTURE=<file>` | Saves a frame to the file as raw BGRA pixels and quits. It prints the size. Convert it with `magick -size <width>x<height> -depth 8 bgra:<file> out.png`. |
| `OM_CAPTURE_SECONDS=<seconds>` | Waits this long before the capture, so a test can click first. |

`tools/send-mouse.swift` moves, clicks and scrolls in the app without moving the real pointer.
