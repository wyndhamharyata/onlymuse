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

## Development settings

| Variable | Does |
| --- | --- |
| `OM_BENCH=1` | Scrolls by itself for 1,200 frames, prints frame times and quits. |
| `OM_CAPTURE=<file>` | Saves the third frame to the file as raw BGRA pixels and quits. Convert it with `magick -size <width>x<height> -depth 8 bgra:<file> out.png`. |
