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
- The top right corner shows how long the last frame took to build. It stays well under 1 ms.

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

## Development settings

| Variable | Does |
| --- | --- |
| `OM_BENCH=1` | Scrolls by itself for 1,200 frames, prints frame times and quits. |
| `OM_DATA=<folder>` | Reads `onlymuse.sqlite` from this folder instead. |
| `OM_BENCH_FRAMES=<count>` | Frames the bench runs. 1,200 by default. |
| `OM_CAPTURE=<file>` | Saves a frame to the file as raw BGRA pixels and quits. It prints the size. Convert it with `magick -size <width>x<height> -depth 8 bgra:<file> out.png`. |
| `OM_CAPTURE_SECONDS=<seconds>` | Waits this long before the capture, so a test can click first. |

`tools/send-mouse.swift` moves, clicks and scrolls in the app without moving the real pointer.
