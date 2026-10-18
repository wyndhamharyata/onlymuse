# onlymuse

A Mac app for Apple Music without the iTunes parts. It draws its own window with GPUIX. Apple
Music's own API gives the pages their data. Music.app plays every song, so playback stays lossless.

For one person only. It borrows the music.apple.com web player's tokens and drives Music.app. Never
publish it.

`design/index.html` holds the mock the app follows. `NOTES.md` holds what the tests in October 2026
found about the API and Music.app.

## Stack

- Bun runs the app. `bun build --compile` ships it as one binary.
- React 19 on `@gpuix/react` draws the window with GPUI and Metal. There is no web view. Pin
  `@gpuix/react` and `@gpuix/native` to the same exact version.
- TypeScript, `strict`. TypeScript 6 type-checks and parses for the lint. TypeScript 7 has no
  JavaScript API.
- `helper/` holds the Swift helper, built with SwiftPM for macOS 26 and later, with no packages. It
  controls Music.app through `NSAppleScript`, sends Music.app's `playerInfo` posts, reads the system
  accent colour and reads the tokens from a hidden music.apple.com page. WebKit keeps the
  sign-in in its own storage, so onlymuse stores no token itself.
- The app starts the helper and speaks JSON lines with it over its stdin and stdout.
  `src/helper.ts` names every message.

## Layout

```
src/
  main.tsx          The entry. Opens the window.
  app.tsx           The window: sidebar, page, player bar.
  helper.ts         The helper process and its messages. The one module that talks to Music.app.
  apple-music.ts    The one module that calls amp-api.music.apple.com.
  queue.ts          The play queue, shuffle and repeat. Plays the next song when Music.app stops.
  navigation.ts     The page shown, with Back and Forward.
  position.ts       The play position between Music.app's posts.
  downloads.ts      The songs Music.app has downloaded, read from its download folder.
  store.ts          The SQLite file: Apple's answers and the saved state of the window.
  artwork.ts        Apple's artwork saved on disk.
  checks.ts         The checks a saved value goes through as it comes back from the store.
  format.ts         Times as text.
  theme.ts          Colours, sizes and the accent.
  icons.tsx         The SVG icons and the Icon component.
  window/           The parts two or more pages share: Sidebar, PlayerBar, SidePanel, rows and cards.
  pages/<page>/     One folder per page, with the components only that page renders. shelves/ draws
                    Home and New. library/ draws every song list and every grid.
helper/             The Swift helper.
scripts/            The lint checks, the screenshot and the signing certificate.
design/             The mock.
experiments/        The scripts behind NOTES.md.
```

## Words

| Word | Means |
| --- | --- |
| Song | One song. Music.app and AppleScript say "track". That word stays inside the AppleScript text only. |
| Catalog | Everything Apple Music offers, in the storefront. |
| Library | The songs, albums and playlists added to the account. |
| Storefront | The Apple Music country of the account. `id` for this one. |
| Shelf | One named row on Home or New, such as Made for You. |
| Card | One tile on a shelf or a grid: an album, an artist, a playlist or a song. |
| Download | A song Music.app keeps on the Mac, as a package in its download folder. |
| Now playing | The song Music.app plays, its state, its position and the volume. |
| Queue | The songs onlymuse plays next, in order. Up Next shows it. |
| Helper | The Swift process in `helper/`. |
| Developer token | The web player's token for Apple's API. It expires about every two months. |
| User token | The token of the signed-in account, sent as `media-user-token`. |

## Function verbs

A function name starts with a verb. Each verb has one meaning.

| Verb | Means |
| --- | --- |
| `read` | Reads a value from state, a web page, Music.app or a file. |
| `fetch` | Gets data over the network. |
| `list` | Returns a list worked out from state. |
| `find` | Looks up one item that may be missing. |
| `to` | Converts one value into another and reads nothing else. |
| `send` | Sends a message to the helper, or from the helper to the app. |
| `apply` | Takes in a message and changes state to match. |
| `set` | Changes one value, inside its limits. |
| `start`, `stop` | Starts or stops a process or a loop. |
| `is`, `has` | Answers yes or no. |
| `use` | A React hook. |

A React component is a noun, such as `PlayerBar`.

## Commands

| Command | What it does |
| --- | --- |
| `bun run dev` | Builds the helper and opens the app with hot reload. |
| `bun run helper` | Builds the helper and signs it as "onlymuse local". |
| `scripts/make-signing-certificate.sh` | Makes the "onlymuse local" certificate, once per Mac. Music.app's Automation permission then holds across builds. |
| `bun run start` | Builds the helper and opens the app as the production build, with no hot reload. |
| `bun run bench` | Measures JavaScript stalls, draw times and memory in both builds, behind the other windows. |
| `ONLYMUSE_FRAMES=1 bun run dev` | Shows GPUI's frame-time overlay in the window. |
| `bun scripts/screenshot.ts <file>` | Opens the app behind the other windows and saves a picture of it. |
| `bun run lint` | ESLint, then `scripts/check-words.mjs` and `scripts/check-structure.mjs`. |
| `bun run typecheck` | TypeScript over `src/`. |
| `bun run format` | Prettier over the files you name. |

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

This covers docs, commit messages, comments, UI text and names. `bun run lint` checks the words it
can. A person checks the rest.

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
7. Name a thing by what it does: `isMissing`, never `isAbsent`.
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
version or a change. TypeScript types carry the contract, so there is no JSDoc.

## 4. A name is a full word.

- Write full words. `errorCount`, never `nErr`.
- A boolean reads as a question: `isPlaying`, `hasArtwork`.
- Use `min` and `max` for limits. Use `first` and `last` for a range that includes both ends.
- One thing has one name everywhere, as the Words table lists. A name Apple's API, Music.app or a
  library owns keeps its spelling, such as `playParams` and `persistentID`.

## 5. A number carries its unit.

- Put the unit in the name: `durationSeconds`, `positionSeconds`, `timeoutMs`, `widthPx`,
  `volumePercent`.
- Give a number a local name when a reader cannot tell what it is from its line.
- Put parentheses around mixed operators when the order is not obvious.

## 6. Contracts

- Declare each parameter as the narrowest type the callers can supply. A narrow type deletes the
  check inside the function.
- Check a value once, where it enters: a helper message, an answer from Apple's API, a page
  read. Code past that point trusts the value.
- A filter that means "everything" is a named value such as `"all"`, never `null`.
- Every function declares its return type. A React component and a one-line pass-through are the
  exceptions.
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
- Name a compound condition before you test it: `const canSeek = isPlaying && hasDuration`.
- A ternary fits on one line. Never nest one. A ternary whose branch is markup longer than eight
  lines moves that branch into its own component.
- Build a list with `if` and `push`. Never `[a && x, b && y].filter(Boolean)`. Never
  `...(cond ? [item] : [])`.
- Name a lookup table above the line that indexes it.
- When two object literals in one function share fields, name the shared fields once and spread
  them.
- Keep a function under 15 branch points. Count `if`, `else if`, `for`, `while`, `case`, `catch`, a
  ternary, `&&`, `||` and `??`. Lower the count by removing work, never by moving branches into a
  helper with no rule of its own.
- Use `startsWith`, `indexOf`, `slice` and `split` before regex.

## 8. Functions, files and services

- When two or more places do the same work, pull it into one function. A one-line body counts when
  two copies could disagree, such as a rule about when something is off.
- Before you write a new file or helper, ask one question. If you deleted it and put its code back
  where it is used, would the code be harder to follow? If not, do not write it.
- A function inside a function that is called twice moves to the top level.
- One module owns each outside service. `src/apple-music.ts` owns the base URL, the tokens and their
  headers, the timeout and the check on each answer. `src/helper.ts` owns the helper process. Nothing
  else calls `fetch` on Apple's host or writes to the helper.
- A component lives with the page that renders it. It moves to `src/window/` only when two pages
  render it.
- Decide a value once, above the elements that read it. An element reads a name. It never decides
  one.
- A colour or a size the window uses twice is a named value in `src/theme.ts`.

## 9. Tests are user journeys.

1. Each test is one journey through the running app. It starts at a window and ends at what the
   person sees or hears.
2. Mock nothing, except a service we do not control. Apple's API and Music.app are those services.
   A stand-in for each answers in the tests.
3. Never write a flag, a branch or a hook in `src/` only for a test.
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
- The lint reads the words in Swift comments and strings. A person checks the structure.

## Format

Prettier with a print width of 100, double quotes, semicolons and ES5 trailing commas.

## Accepted exceptions

- `src/store.ts` reads `ONLYMUSE_DATA` and `src/perf.tsx` reads `ONLYMUSE_PERF`, against rule 9.3. They exist for
  `scripts/bench.ts`, which measures and does not test. A measurement must not change the saved state, and the
  stall probe must run inside the app's own thread.

## Where the four projects disagreed

- Comments. ulem allows none. goui and reader-hero allow one line with a reason. This project
  follows goui and reader-hero.
- Helpers. ulem waits for three places. goui and reader-hero pull a function out at two. This
  project follows goui and reader-hero.
- Return types. ulem asks for one on every function. This project follows ulem.
- Lines. ulem asks every change to cut lines. goui and reader-hero use fewer lines to break a tie.
  This project follows goui and reader-hero.
