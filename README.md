# onlymuse

A Mac app for Apple Music without the iTunes parts, written in Odin. It draws its own window with
Metal, its own text with CoreText and its own UI. Music.app plays every song. `CLAUDE.md` holds the
stack, the layout and the rules.

The first version drew with GPUIX in React. The tag `gpuix-final` keeps it.

## Build and run

Needs Odin 2026-10 or later (`brew install odin`). Build the Swift helper once, and again after it
changes:

```
cd ~/side_project/onlymuse
./build.sh helper
./build.sh release
./build/onlymuse
```

`./build.sh` with no argument makes a debug build. It is slower but easier to step through.

The sections below are the milestones the app was built in, each with what to try. The older ones
compare it with the GPUIX version, which it then ran beside.

## The app

`./build.sh app` builds `build/onlymuse.app`. Drag it to Applications, or open it with
`open build/onlymuse.app`. The helper sits in `Contents/Helpers`, keeps its identifier and certificate,
and so keeps Music.app's Automation permission, the Keychain's permission for Helium's key, and the Apple
and YouTube sign-ins. The icon is the ring of `design/icon.html`, made with `scripts/make-app-icon.sh`.

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
`./build.sh helper`. The panel on the right opens on Lyrics.

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
copied the gpuix app's file, so the queue, shuffle, repeat and lyrics lead carried over. That copy
went with the gpuix app.

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
- The smallest window grows with the zoom, 1000 by 600 points at 100%, so the sidebar, a page and the
  panel always fit. Zooming in grows a smaller window and stops at the step that no longer fits on the
  screen. A zoom saved on a larger screen shows a step smaller until it fits.
- When the helper finds no music.apple.com sign-in, a card asks you to sign in and opens Apple's page.

### 6a. One panel control and artwork placeholders

From here the app goes its own way rather than copying Apple Music.

- The Up Next / Lyrics tabs sit at the bottom of the side panel, and are the only way to switch it.
  The tabs at its top and the two buttons by the volume are gone. One button by the volume shows and
  hides the panel, opening it on the tab it last showed.
- An artist with no photo shows their album cover filling the circle, not inset on a square of colour.
- Open and close the panel with a page of covers showing. The covers stay drawn while the page
  resizes, rather than flashing back to their placeholders. Dragging the window's edge behaves the
  same.
- Rest the pointer on an Up Next row with a long title. The title and the artist slide.
- A lossless song's LOSSLESS badge sits right after its name.
- The window cannot be made smaller than 1000 by 600 points.
- Spacing is tighter everywhere, in steps of 4, 8, 12, 16 and 20 points: pages have 20 at their
  edges, the panel 8, the toolbar is as tall as the traffic lights, and the player bar is 70.
- Swipe up and down Home on the trackpad, a little crooked. The shelves stay put. Each swipe moves
  along one axis, picked from its first few points, and a swipe has to go clearly sideways to move a
  shelf.
- While a cover loads, its tile shows a gradient with a symbol of what it is (album, playlist,
  artist, song). Apple Music items use the cover's own colours, so the cover fades in over its own
  palette. Library items have no colours from Apple, so the name picks two hues, and an album keeps
  the same colours everywhere.

### 6b. Now Playing

- Click the cover in the player bar. The page is the song's stage: its cover large with a shadow, on
  its own colours blurred behind the page and toolbar, the title, artist and album as links, quality
  pills (Lossless with Music.app's sample rate, Hi-Res, Dolby Atmos, language, lyrics), Favourite,
  Add to Playlist and Copy Link, and the lyric line being sung with its romaji.
- For a song in your library: plays with a chart of the last 8 weeks and its rank this month, last
  played, in library since, and skips, from Music.app and the app's play log.
- Credits (performer, composer, lyricists from the lyrics, label, release, genre) and Sound (format,
  sample and bit rate, length and BPM, size, ISRC with a copy button).
- More by the artist, newest first; a release from the last month says NEW.
- It follows the song. A song started outside the app is found in Apple Music by name and artist.

### 6c. Favourites

Rebuild the helper first: `./build.sh helper`.

- A heart follows the song name in the player bar. Click it, or press Cmd L, to make the playing
  song a favourite in Music.app, which also puts it in Favourite Songs. A note confirms it.
- Song rows in Songs, playlists and albums show a heart: filled in the accent for a favourite, an
  empty outline for any other. Up Next has none.
- A song that is not in your library cannot be a favourite in Music.app; the note says so.
- The app now keeps its own play log: a song heard to its middle is a play, one left sooner a skip.

### 6d. Lyrics translation

- Lyrics with romaji or an English translation show Romaji and Translation switches at the top of
  the Lyrics panel. The translation shows under the romaji. Both choices are kept for the next run.
  Kenshi Yonezu's Kanden has both.
- The lyrics' songwriters are read too; Now Playing credits them.

### 6e. The song menu and Add to Playlist

- Right-click (or Control-click) a song in any list or Up Next: Play Next, Add to Playlist, Favourite,
  Go to Artist, Copy Link. Add to Playlist lists the playlists you made, and New Playlist… names one
  with the song in it. Escape or a click outside closes it.
- Drag a song onto a playlist of yours in the sidebar to add it there. The playlist lights up under it.
- A note says when Apple took the change, or why not.

### 6f. Command palette

- Press Cmd K anywhere. Type to find pages, your playlists, library artists, albums and songs, and
  actions: Go to Now Playing, Play or Pause, Next and Previous Song, Shuffle All Songs, Favourite
  the Song Playing, Show Lyrics, Show Up Next. Names that start with what you type come first.
- When you pause typing, Apple Music is searched too.
- Up and Down choose, Return runs it, Escape or Cmd K again closes. Japanese input works here too.

### 6g. Smarter shuffle

- Shuffle now follows rules. Right-click the shuffle button, or click Rules at the top of Up Next:
  Play recent songs last (past 6 hours, or 2 h, 24 h, off), Play often-skipped songs last, Spread out
  songs from one album, and Play favourites earlier.
- Up Next says what the rules did, such as "2 recent songs play last."
- onlymuse counts plays and skips itself, so the rules learn as you listen.

### 6h. Accent from the cover

- Play a song. The accent turns to a colour from its cover over about half a second: the artist on
  Stage, the selected sidebar item, the shuffle button, the hearts and the sung words.
- The colour is the cover's main hue, so a mostly blue cover with a red title gives blue. It is
  lightened when it would be too dark to read on the window.
- A black and white cover, or no cover, keeps the accent chosen in System Settings.

### 6i. Recent Songs

- Open an artist. Under Albums, Recent Songs lists the newest songs of their ten newest releases,
  newest first, each with its album and its date. A song's date is its own, not always its album's.
- A song on a single and on a later album shows once, from the newer release.
- Click "Recent Songs ›" for all of them, with Play and Shuffle, as the other song lists have.
- In a narrow window the shelf takes one column and leaves out the dates.

### 7. YouTube Music

A song plays from Apple Music whenever Apple has it. YouTube Music adds what Apple lacks.

- Search for a song. Under Apple's songs, From YouTube lists the songs Apple Music does not have, and
  Videos on YouTube shows YouTube's videos in wide tiles. Click one to play it from YouTube.
- Open an artist. The header says how many people listen on YouTube. Under Albums come the artist's
  videos, live performances and playlists from their YouTube channel.
- Home holds YouTube Music's shelves too, such as Quick picks, between Apple's.
- In any YouTube list, a red YouTube mark stands where the heart would be for a song Apple does not
  have. A song Apple has shows Apple's heart and plays from Apple, in lossless where Apple has it.
- The player shows YOUTUBE in place of LOSSLESS while a song plays from YouTube. Pause, seek and the
  volume act on YouTube's player, and the queue goes on to the next song, from either service.
- Mixes, Liked Music and Bring Over, in the sidebar, need a sign-in. Google refuses a sign-in inside an
  app, so onlymuse uses the one the Helium browser has. Sign in at music.youtube.com in Helium, then
  click Use Helium's Sign-In. macOS asks once to let the helper read Helium's key from the Keychain.
  Choose Always Allow. The helper reads Helium's youtube.com cookies again at each start.
- Bring Over lists your YouTube playlists. Open one to see what each song plays from, then click
  Bring Over. The new Apple Music playlist holds the songs Apple has. The others stay in it, in their
  places, and play from YouTube.
- A YouTube song matches a song in your library first, with no request to Apple. Others are looked
  up by album: one search per album, then the albums' songs, 20 albums to a request. A song no album
  holds is searched alone. Each answer is saved, so a song is matched once.
- When Music.app does not start Apple's song within 8 seconds, the song plays from YouTube, and
  always will from then on. Not on Apple Music, in a matched song's menu, does the same by hand. Try
  Apple Music Again, in the menu of such a song, undoes it.
- A song only on YouTube has a heart too, after its YouTube mark. Favouriting it puts it at the end of
  Favourite Songs in onlymuse, as Apple's playlist holds Apple songs alone, and likes it on YouTube,
  so it shows in Liked Music. Removing the favourite does both the other way. A song liked on YouTube
  shows as a favourite.
- Add to Playlist works for a song only on YouTube too. It stays in the playlist in onlymuse, as
  Apple's playlists hold Apple songs alone. Its menu offers Remove from Playlist.

### 7b. When Music.app stops on a song

- Music.app says it plays a song while it still loads it. The player then says Loading in Music.app
  and its clock stays at 0:00. Only a song still at 0:00 after about 16 s is started again.
- Music.app can play a song just added to the library for a few seconds, then wait on it for good
  while it says it plays. The clock then stays still, and after about 4 s the queue starts the song
  again. Either way, a song is started again at most twice, and the Console notes each time.

### 8. Console

- Press ⌘K and open Console. It lists every error since onlymuse started, newest first: requests
  Apple or YouTube refused or never answered, covers that did not download, and what the helper, the
  queue and the store reported. Copy All copies them as text. Clear empties the list.
- It keeps the last 500 and starts empty with each run. Each line also goes to the terminal.

## Development settings

| Variable | Does |
| --- | --- |
| `OM_BENCH=1` | Scrolls by itself for 1,200 frames, prints frame times and quits. |
| `OM_FRAMES=1` | Shows how long each frame took to build, at the top right. |
| `OM_FAKE_LOG=<file>` | The fake helpers write the commands they get to this file. |
| `OM_FAKE_SPEED=<n>` | `tools/fake-music.py` plays songs n times faster, so they end in seconds. |
| `OM_FAKE_UNPLAYABLE=<name>` | `tools/fake-music.py` finds this song but never starts it, as Music.app does with a song it has no file for. |
| `OM_FAKE_SLOW_START=<name>` | `tools/fake-music.py` keeps this song at 0:00 for 7 s the first time it plays, and says it plays. |
| `OM_FAKE_STALL=<name>` | `tools/fake-music.py` stops this song at 5 s the first time it plays, and still says it plays. |
| `OM_FAKE_MISSING=<name>` | `tools/fake-music.py` finds this song only on the 4th ask, as if Apple were adding it. |
| `OM_HELPER=<file>` | Runs this instead of the Swift helper. `tools/fake-helper.sh` says a song plays. |
| `OM_FAKE_POSITION=<seconds>` | Where the fake helper's song starts. |
| `OM_FAKE_NAME`, `OM_FAKE_ARTIST`, `OM_FAKE_ALBUM`, `OM_FAKE_DURATION` | The fake helper's song, soldier game by default. |
| `OM_WINDOW=<width>x<height>` | Opens the window at this size in points. |
| `OM_FAKE_TOKENS=<folder>` | With `tools/fake-music.py`: sends the web player's tokens from `dev` and `mut` in this folder, so a test reads Apple's catalog. `experiments/am.sh` reads the same files. A file `yt-cookie` there is sent as the YouTube page's cookie, so a test reads YouTube Music signed in. |
| `OM_TYPE=<text>` | Types this into the focused field a second after start, through the view's input context, as the keyboard would. |
| `OM_PALETTE=<term>` | Opens the command palette with this term at start, as a test cannot type into a window behind the others. |
| `OM_BACKGROUND=1` | For the tests. Opens the window behind the others, never focused and with no Dock icon, so AeroSpace leaves it floating. macOS stops a covered window's display link, so a timer runs its frames, which are captured but not shown. The helper leaves Music.app as it is when the app quits. Captures set it. The bench keeps its window in front, as it measures the screen. |
| `OM_DATA=<folder>` | Keeps `onlymuse.sqlite` in this folder instead. |
| `OM_BENCH_FRAMES=<count>` | Frames the bench runs. 1,200 by default. |
| `OM_CAPTURE=<file>` | Saves a frame to the file as raw BGRA pixels and quits. It prints the size. Convert it with `magick -size <width>x<height> -depth 8 bgra:<file> out.png`. |
| `OM_CAPTURE_SECONDS=<seconds>` | Waits this long before the capture, so a test can click first. |

`tools/send-mouse.swift` moves, clicks and scrolls in the app without moving the real pointer.
