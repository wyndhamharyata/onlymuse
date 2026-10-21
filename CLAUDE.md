# onlymuse

A Mac app for Apple Music without the iTunes parts. It draws its own window with Metal, its own text
with CoreText and its own UI, in Odin. Apple Music's own API gives the pages their data. Music.app
plays every song, so playback stays lossless.

For one person only. It borrows the music.apple.com web player's tokens and drives Music.app. Never
publish it.

`design/index.html` holds the mock the app follows. `docs/` holds the plans for the features since.
`NOTES.md` holds what the tests in October 2026 found about the API and Music.app. `README.md` says
how to try each part of the app, and lists the development settings.

## Stack

- Odin 2026-10 or later (`brew install odin`). No packages beyond Odin's own `core` and `vendor`.
- `src/platform` opens the window with AppKit. `src/render` draws with Metal. `src/font` shapes
  text with CoreText. `src/ui` lays out a tree of boxes rebuilt every frame.
- `helper/` holds the Swift helper, built with SwiftPM for macOS 26 and later, with no packages. It
  controls Music.app through `NSAppleScript`, sends Music.app's `playerInfo` posts, reads the system
  accent colour and reads the tokens from a hidden music.apple.com page. A second hidden page, on
  music.youtube.com, plays YouTube songs. Google refuses a sign-in inside an app, so the helper reads
  the Helium browser's youtube.com cookies, with Helium's key from the Keychain. WebKit keeps the
  sign-in in its own storage, so onlymuse stores no token itself.
- The app starts the helper and speaks JSON lines with it over its stdin and stdout.
  `src/helper/helper.odin` names every message.
- The app keeps its SQLite file in `~/Library/Application Support/onlymuse-native` and its covers in
  `~/Library/Caches/onlymuse-native`. The names stay, so the saved window and queue stay.

## Layout

```
src/
  app/              The window: sidebar, pages, side panel, player bar, the queue and the palette.
                    main.odin opens the window and builds each frame. pages.odin picks the page.
  apple/            The one package that calls amp-api.music.apple.com, with its cache.
  youtube/          The one package that calls music.youtube.com. Its answers go through apple's cache.
  console/          The errors and refused requests the Console page lists. Every package reports there.
  helper/           The helper process and its messages. The one package that talks to Music.app.
  lyrics/           Lyrics from Apple, read from TTML, with romaji and translations.
  library/          The library, read from Apple's saved answers.
  store/            The SQLite file: Apple's answers, the play log and the saved state of the window.
  ui/               The boxes, their layout, hover and scroll.
  font/ icon/ image/  Text, SF Symbols and covers, each in its own atlas or textures.
  render/           Metal and the shaders.
  platform/         AppKit: the window, events, keys, text input and the clipboard.
  net/              HTTP through libcurl.
  mac/              The C APIs of macOS the app calls.
helper/             The Swift helper.
tools/              The test stand-ins: a fake Music.app and helper, and a mouse and key sender.
scripts/            The signing certificate.
app/                The app's Info.plist and AppIcon.icns, which ./build.sh app puts in onlymuse.app.
design/             The mock, and the app icon: design/icon.html shows the four drawn, app-icon.svg is the one kept.
docs/               The plans and mocks of later features.
experiments/        The scripts behind NOTES.md. am.sh asks Apple's API with the web player's tokens.
```

## Words

| Word | Means |
| --- | --- |
| Song | One song. Music.app and AppleScript say "track". That word stays inside the AppleScript text only. |
| Catalog | Everything Apple Music offers, in the storefront. |
| Library | The songs, albums and playlists added to the account. |
| Storefront | The Apple Music country of the account. `id` for this one. |
| Shelf | One named row on Home or New, such as Made for You. |
| Recent Songs | The songs of an artist from their ten newest releases, newest first. |
| Card | One tile on a shelf or a grid: an album, an artist, a playlist or a song. |
| Download | A song Music.app keeps on the Mac, as a package in its download folder. |
| Now playing | The song Music.app plays, its state, its position and the volume. |
| Queue | The songs onlymuse plays next, in order. Up Next shows it. |
| Helper | The Swift process in `helper/`. |
| Developer token | The web player's token for Apple's API. It expires about every two months. |
| YouTube song | A song from YouTube Music, with the ID `yt:` and its video ID in place of a catalog ID. |
| Match | The Apple Music song a YouTube song is. A YouTube song plays from Apple whenever it has a match. |
| User token | The token of the signed-in account, sent as `media-user-token`. |

## Function verbs

A procedure name starts with a verb. Each verb has one meaning.

| Verb | Means |
| --- | --- |
| `read` | Reads a value from an answer, a web page, Music.app or a file. |
| `fetch` | Gets data over the network. |
| `watch` | Asks for an answer and returns what there is so far, each frame. |
| `list` | Returns a list worked out from state. |
| `find` | Looks up one item that may be missing. |
| `to` | Converts one value into another and reads nothing else. |
| `send` | Sends a message to the helper, or from the helper to the app. |
| `apply` | Takes in a message and changes state to match. |
| `set` | Changes one value, inside its limits. |
| `start`, `stop` | Starts or stops a process or a loop, or readies a package. |
| `build` | Builds boxes for this frame. |
| `draw` | Draws a box's own content, such as an image. |
| `is`, `has` | Answers yes or no. |

## Commands

| Command | What it does |
| --- | --- |
| `./build.sh` | Builds `build/onlymuse` for debugging. |
| `./build.sh release` | Builds `build/onlymuse` optimised. Run it with `./build/onlymuse`. |
| `./build.sh helper` | Builds the helper and signs it as "onlymuse local". |
| `./build.sh app` | Builds `build/onlymuse.app`, with the helper in `Contents/Helpers` and the icon, both signed. |
| `scripts/make-app-icon.sh` | Makes `app/AppIcon.icns` from `design/app-icon.svg`. Run it after changing the icon. |
| `scripts/make-signing-certificate.sh` | Makes the "onlymuse local" certificate, once per Mac. Music.app's Automation permission then holds across builds. |
| `OM_BENCH=1 ./build/onlymuse` | Scrolls a long list and prints frame times. Its window shows in front. |

## Testing without taking the screen

A test run never touches the real library, Music.app or the person's window:

- `OM_DATA=<folder>` with a copy of the SQLite file, made with `sqlite3 … "VACUUM INTO '…'"`.
- `OM_HELPER=$PWD/tools/fake-music.py` instead of the helper. `OM_FAKE_TOKENS` lets it read Apple's
  catalog, which is read only.
- `OM_CAPTURE=<file>` saves a frame and quits, behind the other windows, where AeroSpace leaves it.
  `OM_BACKGROUND=1` keeps any other run there too.
- `tools/send-mouse.swift` clicks, drags and types into that window without bringing it in front.

`README.md` lists every setting.

# Rules

These rules come from goui, reader-hero, marknotes-cf and ulem. They govern every change. When a
rule makes the code worse, keep the better code and give the reason in the commit message. Never
drop a rule silently.

## 1. Write for the reader.

Judge code by how long another person needs to understand it. A short line that needs a second read
is worse than a longer line that does not. A reader holds about four things in mind at once. Keep
each block within that.

This rule settles every tie between the rules below.

## 2. Use plain words.

This covers docs, commit messages, comments, UI text and names. A person checks them.

1. Never use these words or their other forms: `bail`, `absent`, `clearing`, `no-op`,
   `falls through`, `survives`, `lands`, `landed`, `leaves`, `read better`, `invariant`, `gap`,
   `sits` (for placement), `minted`, `guard`, `adds`, `call site`, `gate`, `cut` (for a branch),
   `shape`, `spike`, and the opener `Worth ...ing?`.
2. Never use these metaphors: `load-bearing`, `frozen`, `seam`, `surface` (as a noun),
   `carries the weight`, `outranks`, `the heart of the change`, `honest` or `lie` (about code),
   `earns its place`, `holds the contract`.
3. No em dashes, no en dashes and no semicolons in prose. Never write a short label, then a colon,
   then its explanation. A colon only opens a list or an example.
4. No words that claim weight instead of stating a fact: `critically`, `significantly`,
   `the key insight`, `this is important`, `make no mistake`.
5. In docs and commit messages, never join two facts with `because`, `therefore` or `hence`. Write
   two plain sentences.
6. One fact per sentence.
7. Name a thing by what it does: `is_missing`, never `is_absent`.
8. Read each sentence aloud. If a person explaining the thing to a teammate would not say it that
   way, write it again.

"Add" as a button label or an action name, such as "Add to Library" and `addToLibrary`, is allowed.

## 3. A comment says what a name cannot.

The default is no comment. Write one line only when it holds one of these:

- The reason the code does something a reader would not expect.
- The source of a formula, with the source's own symbol.
- The unit of a bare number, when a name cannot hold it.
- A constraint outside the code that a tool or a platform sets.

Never write a banner, step narration, a label such as `// Main logic`, commented-out code, or a TODO
with no named task. A comment is one line. It explains the code as it is. It never refers to a past
version or a change. Types carry the contract.

## 4. A name is a full word.

- Write full words. `error_count`, never `n_err`.
- A boolean reads as a question: `is_playing`, `has_artwork`.
- Use `min` and `max` for limits. Use `first` and `last` for a range that includes both ends.
- One thing has one name everywhere, as the Words table lists. A name Apple's API, Music.app or a
  library owns keeps its spelling in its JSON tag, such as `playParams` and `persistentID`.

## 5. A number carries its unit.

- Put the unit in the name: `duration_seconds`, `position_seconds`, `timeout_ms`, `size_points`,
  `size_pixels`, `volume_percent`. A size in the UI is in points unless its name says pixels.
- Give a number a local name when a reader cannot tell what it is from its line.
- Put parentheses around mixed operators when the order is not obvious.

## 6. Contracts

- Declare each parameter as the narrowest type the callers can supply. A narrow type deletes the
  check inside the function.
- Check a value once, where it enters: a helper message, an answer from Apple's API, a page
  read. Code past that point trusts the value.
- A filter that means "everything" is a named value such as `"all"`, never `nil`.
- Point at a type that exists before you write a new one. Write a named type when two or more places
  use it.

## 7. Structure

- Return early. The main path comes last. Keep each `if` one level deep where you can.
- A blank line groups a block. One idea per block, about five statements.
- Control flow is its own block. An `if`, a loop, a `switch` or a `try` of more than one line has a
  blank line before and after it, unless it opens or closes its block. A run of early exits stays
  together.
- Declare, then use. A run of declarations has a blank line between it and the statements around it.
  Inside the run, the inputs come first, then the values worked out from them.
- A function of more than three lines keeps a blank line before its last return.
- Name a compound condition before you test it: `can_seek := is_playing && has_duration`.
- An `x if cond else y` fits on one line. Never nest one.
- Build a list with `if` and `append`.
- Name a lookup table above the line that indexes it.
- Keep a function under 15 branch points. Count `if`, `else if`, `for`, `while`, `case`, `catch`, a
  `x if cond else y`, `&&`, `||` and `or_else`. Lower the count by removing work, never by moving branches into a
  helper with no rule of its own.
- Use `strings.has_prefix`, `strings.index` and `strings.split` before a pattern.

## 8. Functions, files and services

- When two or more places do the same work, pull it into one function. A one-line body counts when
  two copies could disagree, such as a rule about when something is off.
- Before you write a new file or helper, ask one question. If you deleted it and put its code back
  where it is used, would the code be harder to follow? If not, do not write it.
- A function inside a function that is called twice moves to the top level.
- One package owns each outside service. `src/apple` owns the base URL, the tokens and their
  headers, the timeout and the check on each answer. `src/helper` owns the helper process. Nothing
  else asks Apple's host or writes to the helper.
- A procedure that builds part of one page lives in that page's file. It moves to `widgets.odin`
  only when two pages use it.
- Decide a value once, above the boxes that read it. A box reads a name. It never decides one.
- A colour or a size the window uses twice is a named value in `src/app/theme.odin`.

## 9. Tests are user journeys.

1. Each test is one journey through the running app. It starts at a window and ends at what the
   person sees or hears.
2. Mock nothing, except a service we do not control. Apple's API and Music.app are those services.
   A stand-in for each answers in the tests.
3. Never write a flag, a branch or a hook in `src/` only for a test. The `OM_` settings are the
   exception, listed below.
4. A test name states the situation and the result: `given a playing song, the player bar shows
   its name and position`.
5. Before you keep an assertion, break `src/` on purpose and watch the test fail.

## 10. Scope of a change

- Touch only what the task needs. Match the style already in the file. Do not tidy nearby code.
- Fewer lines wins a tie. A named value that saves the reader time stays, even when it costs a line.
- Run the formatter only on the files you changed.

## Swift

The rules above govern the helper too.

- A boolean reads as a question. A function is a verb and its subject.
- The type says the type. A `//` comment holds a reason only.
- A blank line stands between a run of declarations and the statements that use it, and around a
  `do`/`catch` or an `if` of more than one line.

## Format

`./build.sh` builds with `-strict-style`, `-vet-unused` and `-vet-shadowing`. Tabs indent. Fields
and table values line up in columns, as `odinfmt` lines them.

## Accepted exceptions

- The `OM_` settings in `README.md`, such as `OM_DATA`, `OM_CAPTURE`, `OM_TYPE` and `OM_WINDOW`,
  are read in `src/`, against rule 9.3. The window can only be seen and driven from outside the
  process by a test that takes the screen, and a test must never take it.
- The helper reads `GPUIX_BACKGROUND=1` to leave Music.app as it is when the app quits. The name is
  older than the Odin app. Changing it means changing the helper and the app together.
- With `GPUIX_BACKGROUND=1` the helper's YouTube page also plays muted, never pauses Music.app and never
  asks the Keychain for Helium's key. A test of YouTube playback then makes no sound, shows no prompt
  and leaves the person's music alone.

## Where the four projects disagreed

- Comments. ulem allows none. goui and reader-hero allow one line with a reason. This project
  follows goui and reader-hero.
- Helpers. ulem waits for three places. goui and reader-hero pull a function out at two. This
  project follows goui and reader-hero.
- Return types. ulem asks for one on every function. This project follows ulem.
- Lines. ulem asks every change to cut lines. goui and reader-hero use fewer lines to break a tie.
  This project follows goui and reader-hero.
