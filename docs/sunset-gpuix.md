# Sunsetting the gpuix app

Done on 21 Oct 2026, with two changes to the plan below. Step 1, the check by hand, was skipped: the
app has one user, and the tag keeps the old app. The two lint scripts were dropped, not rewritten.
They parsed TypeScript, and Odin's own names use some of the words they banned. The rules stay in
`CLAUDE.md`, checked by a person.

The plan, as written before the work:

The Odin app in `native/` becomes the only onlymuse. The gpuix app in `src/` is frozen now and goes
away in the steps below. Each step is one commit, and the app works after each one.

## Where things stand

- Native has every page and action the gpuix app has, and since October 2026 more: Stage, the song
  menu, the command palette, shuffle rules, the accent from the cover and Recent Songs.
- Native shares the Swift helper in `helper/`. While gpuix lives, the helper only gains commands
  and never changes one.
- Native's first run copies the gpuix app's SQLite file, which it only ever reads
  (`native/src/store/store.odin`, `copy_gpuix_file`). The saved state keeps the gpuix app's form:
  `navigation`, `queue`, `zoom`, `panel` and the lyrics lead.
- Recent Songs was first written into `src/`, by mistake, and never committed. That diff is the
  only gpuix work since the freeze.

## Step 0. Freeze (now)

- No new feature goes into `src/`. A design in `design/index.html` is built in `native/`.
- The uncommitted Recent Songs diff in `src/` is dropped. What it found about Apple's API is kept:
  the two rows in `NOTES.md`, the Recent Songs entry in the `CLAUDE.md` word list, and the mock in
  `design/`.

## Step 1. A last check of parity, by hand

Run both apps once more, side by side on the same library, and walk every page: Home, New, Search,
an artist, an album, a catalog playlist, Favourite Songs, Recently Added, Artists, Albums, Songs,
Downloaded, a library playlist, lyrics, Up Next, the sign-in card. Anything the gpuix app does that
native does not becomes a task before step 3.

## Step 2. Tag the last gpuix commit

`git tag gpuix-final`. Anything removed later comes back from there.

## Step 3. Remove the gpuix app

Delete:

- `src/`, `vendor/` (the patched gpuix binary), `node_modules/`
- `package.json`, `bun.lock`, `tsconfig.json`, `eslint.config.js`
- `scripts/bench.ts`, `scripts/gpuix-native.ts`, `scripts/probe-report.ts`, `scripts/screenshot.ts`

Keep, and move where step 4 says:

- `scripts/make-signing-certificate.sh`. The helper is signed with its certificate.
- `scripts/check-words.mjs` and `scripts/check-structure.mjs` are rewritten for the Odin source or
  dropped. The word check is worth keeping: it holds the code to the words in `CLAUDE.md`.
- `experiments/`. `am.sh` and its token files are how the API is probed, and native's tests use the
  same tokens (`OM_FAKE_TOKENS`).

The helper builds without Bun: `native/build.sh helper` runs the `swift build` and `codesign` that
`bun run helper` runs today.

## Step 4. Native moves to the top

- `native/src`, `native/build.sh`, `native/tools`, `native/docs` move to the repository's top.
- `helper.odin` finds the helper at `../helper/.build/…` instead of `../../helper/.build/…`.
- `native/README.md`'s keys, try-it list and development settings fold into one `README.md`.
- `CLAUDE.md` is rewritten for Odin: the stack, the layout of `src/`, how to build and test, the
  background test rule (`OM_BACKGROUND=1`, a copied database, the fake helper). The word list stays.
- `NOTES.md` drops what only concerned gpuix, such as its frame-time section, and keeps what
  concerns Apple's API and Music.app.

## Step 5. Native stops pointing at gpuix

- `copy_gpuix_file` and `gpuix_path` go. Every run since the first has had its own file, so nothing
  is lost.
- The saved keys and their forms stay as they are. Changing them would only lose the saved window.
- Comments that explain a choice by "as the gpuix app did" say the reason instead.
- The helper rule lifts: a command can change, as one app now speaks to it.

## After

The gpuix app's own data file, `~/Library/Application Support/onlymuse/onlymuse.sqlite`, is left
alone. Delete it by hand once you are sure, as onlymuse no longer reads it.
