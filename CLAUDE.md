# tty2oled+ — working notes

## Releasing: every push is a version

Commit and push only when asked; when asked, this is the whole ritual, in
order. Scripts and firmware carry **one** version and move together even when
only one side changed.

**1. Decide the version.** `VERSION` holds the *next* push's version.

```bash
git tag --list "v$(cat VERSION)"   # prints the tag => already pushed => bump
./tools/bump-version.sh            # 0.4.0b -> 0.4.1b, keeping the beta mark
```

`--set 0.5.0b` sets it outright; `--release` drops the `b` - **only when the
user asks**. The script writes `TTY2OLED_VERSION` in `tty2oled-system.ini` and
`#define BuildVersion` in the sketch, the only literal copies. `--check` says
whether all three agree; `tests/test-version.sh` fails the suite if not. The
`b` is ours; the sketch's `runsTesting` keys on upstream's trailing `T`.

**2. Changelog.** A new `## <version> — <date>` at the top of `CHANGELOG.md`,
written for someone running it, not a list of edits.

**3. Prove it - all three boards, and the release.** The bump alone makes the
binary stale, and CI builds against **today's** libraries:

```bash
arduino-cli lib upgrade                                 # what CI will install
./tests/run-all.sh                                      # must be all green
shellcheck -S error -s bash tty2oled.sh tty2oled-meta.sh tty2oled-read.sh \
  S60tty2oled tools/*.sh tests/*.sh                     # CI's line; run-all has none
for b in esp32de esp32s3 lolin32; do                    # lolin32 LAST
  ./tools/build-tty2oled.sh MiSTer_SSD1322_USB "${b}"
done
./tools/make-release.sh --out /tmp/rel --tag "v$(cat VERSION)" --notes /tmp/rel.md
```

A lolin32-only build is how `v0.4.0b` was spent. **lolin32 last** because
`deploy-mister.sh --firmware` flashes the newest `merged.bin` in any
`build-out-*`, and the hardware here is a LOLIN32. `make-release.sh` with the
real `--tag`/`--notes` runs CI's checks; its suite fails on two asset names
differing only in case (how `v0.4.1b` was spent).

**4. Commit, tag, push.**

```bash
git add -A
git status                      # read it before committing
git commit -F- <<'EOF'
<subject: what changed, imperative, no version number>

<body: why, and anything the next person would trip over>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
git tag -a "v$(cat VERSION)" -m "tty2oled+ $(cat VERSION)"
git push && git push --tags
```

CI (`.github/workflows/ci.yml`) runs every suite and builds all three boards
on every push; on a `v*` tag it builds the title index, runs `make-release.sh`
and publishes the GitHub release that the launcher's **Update** installs from.
It refuses a tag that is not `VERSION` and a version with no changelog
section. Watch it through to the **Release** job and check the assets are
served before saying it is out:

```bash
gh run watch "$(gh run list --branch "v$(cat VERSION)" --limit 1 --json databaseId -q '.[0].databaseId')" --exit-status
gh release view "v$(cat VERSION)" --json isDraft,isPrerelease,assets
curl -fsSLI -o /dev/null -w '%{http_code}\n' \
  https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/VERSION
```

**A tag CI rejects is spent.** Fix, bump again, let the failed tag stand;
never move or delete a pushed tag. (`0.4.0b`, `0.4.1b` are in the changelog as
tagged-never-released; `0.4.2b` was the first installable.)

**5. Flash, don't just deploy** - a script-only deploy leaves the display a
version behind, and the daemon says so in `/tmp/tty2oled`:

```bash
MISTER=root@192.168.1.206 ./tools/deploy-mister.sh --firmware --flash
```

`MiSTer.local` does not resolve here. The MiSTer then holds the released
version, so **Update** finds nothing until the next one (`--force` overrides).

**Skip step 5 when the user wants to test the install path.** Then wipe the
MiSTer first - install folder, both Scripts entries, the `user-startup.sh`
line, the daemon, `/tmp` and `/run` leftovers, `tty2oled-bootimg.sh clear` -
so `tty2oledplus_install` is a genuine first install with a reason to flash.

---

## What this is

A fork of [venice1200/MiSTer_tty2oled](https://github.com/venice1200/MiSTer_tty2oled),
GPLv3, on `main` (upstream `50c08ac` plus this fork). Upstream shows one
picture per **core**; this shows the **game**.

- **Install folder `/media/fat/tty2oledplus`** (upstream: `/media/fat/tty2oled`),
  so neither updater overwrites the other. It **replaces** upstream (one serial
  port; two boot hooks would start two daemons): while `/media/fat/tty2oled`
  holds upstream's `tty2oled.sh` or `S60tty2oled`, the installer, the deploy
  and `S60tty2oled start` refuse (start also logs to `DAEMONLOG`); `stop` and
  `status` still work. The README's move-the-folder migration satisfies all.
- **Everything else keeps upstream's spelling** - script/ini names,
  `S60tty2oled`, NVS namespace, serial protocol - so existing instructions and
  muscle memory keep working.
- `TTY2OLED_PATH` in `tty2oled-system.ini` is the one definition.
  `S60tty2oled` and `tty2oled-read.sh` run before any ini and name the folder
  outright; the deploy ships both for that reason.
- Upstream's `installer.sh`, `update_tty2oled*.sh`, `local_flasher.sh`,
  `tty2oleddb.json` and their ini keys are **not part of the fork**: they pull
  upstream over a local install. The boot hook they used to wire is now
  `tools/tty2oled-boothook.sh`, run by the deploy.

## Layout of the change

W = runs on the workstation, M = runs on the MiSTer.

| Path | What it is |
|---|---|
| `tty2oled-meta.sh` | MiSTer's `/tmp` state files -> display metadata (`build_meta`). |
| `tty2oled.sh` | Daemon. Watches game state as well as the core; sends `CMDMETA`/`CMDICON` etc. |
| `tty2oled-system.ini`, `tty2oled-user.ini` | Defaults; the user's overrides (sourced after, never shipped over). |
| `VERSION`, `CHANGELOG.md`, `tools/bump-version.sh` | One version; an entry per release; moves/checks it. |
| `coretypes.ini` | `corename=console\|computer\|arcade`, consulted before folder guessing. |
| `MiSTer_SSD1322_USB/metadisplay.h` | Arcade card + console split layout. |
| `.../bootscreen.h`, `bootlogo.h`, `bootlogo.png` | LittleFS boot image + reserved band; built-in 256x54 logo (generated from the PNG). |
| `.../contrastfade.h` | Every contrast change fades; base level x transition veil. |
| `.../pagefade.h` | A page turn fades only the rows that change. |
| `.../fadetransition.h` | `TRANSITION=-2` fade; `30`-`39` sliding fades. |
| `.../bootoutro.h`, `busybar.h` | Boot screen as menu picture + power-on outro; the sweep as a busy bar. |
| `.../bandnote.h` | Frontends' 54-row picture + band; `CMDNOTE` fading in/out there. |
| `.../linejunk.h` | Drops another program's bytes (Zaparoo's PN532 probe) ahead of a command line. |
| `.../MiSTer_SSD1322_USB.ino` | Includes the headers; LEDC shim for ESP32 core 3.x. |
| `tests/` | ~2620 checks, no hardware. |
| `tools/build-title-index.sh`, `dat2index.awk`, `index-emit.awk`, `mamexml2index.awk` | CRC32 title index from libretro-database (+ MAME XML for Neo Geo). W. |
| `tools/png2gsc.py` | PNG -> 4bpp `.gsc`. W **and** M: Pillow, ImageMagick, or a stdlib PNG decoder. |
| `tools/wheels2gsc.py`, `tools/gscpack.py` | Wheel PNGs -> 256x64 `.gsc` (`--nodupes`); pack into `.bin`+`.idx`. W. |
| `tools/mistergscpreview` | Shows `.gsc` files on the real panel over SSH; `-r` grey ramp. W. |
| `tools/make-screenshots.sh`, `tools/screenshots/` | README screenshots, rendered with the real GFX/u8g2 into `docs/img/*.png`. Re-run when a layout changes. W. |
| `tools/history2gamelist.py` | MAME `history.xml` -> arcade `gamelist.xml` + `2048.txt`. W. |
| `pics/icon/`, `pics/banner/`, `pics/arcade/`, `pics/user/` | See [Artwork folders](#artwork-folders). `pics/boot.png` is the user's, gitignored. |
| `tools/build-tty2oled.sh` | Builds firmware with arduino-cli. W. |
| `tools/deploy-mister.sh` | Pushes this working copy over SSH. W. |
| `tools/tty2oled-boothook.sh` | Adds the boot hook to `user-startup.sh`; fed on stdin by the deploy. |
| `tools/manifest.sh` | What an install is made of; read by deploy and release so they agree. |
| `tools/make-release.sh` | Release assets into `dist/`. CI runs it on a tag. |
| `tools/tty2oledplus.sh` | The launcher, the one Scripts entry: Settings / Update / Scrape metadata / Uninstall. M. |
| `tools/tty2oledplus_{settings,scrape,update,uninstall}.sh`, `_scrape.py` | The launcher's entries, in the install folder. M. |
| `tools/tty2oledplus_syscheck.py` | Would update_all update something installed? The daemon runs it in the background. M. |
| `tools/tty2oledplus_scummvm.py` | ScummVM's icon packs -> `cache/scummvm/games.idx` + per-game 86x64 icons. Daemon, background. M. |
| `tools/scummvm-entries.sh` | ScummVM's ini -> a `<folder>.scummvm` (game id) in each game folder, for ES-DE/RetroPie/RetroArch. Developer tool, not shipped (yet); fed over `ssh ... 'bash -s'`. M. |
| `tools/tty2oledplus_install.sh` | The starter users drop in Scripts. M. |
| `tools/flash-mister.sh`, `tools/fw-segments.py` | Flashes firmware, writing only segments with data. M. |
| `tools/tty2oled-port.sh` | Which port the display is on (remembered USB identity), and `ttynode`. Sourced by daemon, S60, flasher, updater, bootimg. M. |
| `tools/tty2oled-bootimg.sh` | Sets/clears/queries the stored boot image. M. |
| `tools/tty2oled-diag.sh`, `tty2oled-capture.sh` | Dump state files and what they parse to; record state changes. M. |

## What ends up on screen

`build_meta` -> kind, title, ordered fields; `sendmeta` puts it on the wire;
the firmware composes it.

| kind | layout |
|---|---|
| `arcade` | wheel logo, then each card page, then the logo - a step every `METADATA_INTERVAL`s |
| `console` | split: "Now playing", rule, title, paged fields left; 86x64 icon right; description page last |
| `computer` / `unknown` | full-screen artwork as upstream (`unknown`: metadata off) |

**Core change wire order: `CMDMETAOFF`, picture, `CMDCBOOT`, `CMDMETA`,
`CMDDESC`, `CMDICON`.** The firmware acts on each as it lands, so the order is
the behaviour. `CMDMETA` first (up to 0.6.6b) started the transition before
`CMDCBOOT` arrived, froze on the 8KB read, then jumped to black. `CMDCBOOT`
before the picture started the hold's clock early and spent it on the
transfer + fade. `test-wire.sh` checks the order; `test_meta_layout` replays it
against the firmware.

- **Core boot hold** (`core_bootscreen_time`): the daemon decides *whether*
  (`sendcoreboot`, only on a console core change); the firmware decides *when*
  (the first `meta_tick` with `tfState` idle). No `CMDCBOOT`, no hold. With `0`
  and the game already known the picture goes as `CMDAPD` (stored, not drawn).
  The hold ends in a transition (`meta_transitionToConsole`: render, snapshot
  to `metaBin`, `srcBin` there, `oled_transition(tEffect)`); plain
  `meta_showConsole` is a cut, used by every marquee tick.
- `meta_tick` returns early while `tfState != TF_IDLE`: a transition animates
  copy-to-copy and overwrites anything drawn in between.
- MiSTer publishes the core seconds before the game, so `CMDCBOOT` is armed on
  every console core change; a game arriving after the hold is drawn at once.

**Update screens transition like a picture.** `CMDCOR` if the pack has
`update_all.gsc`, else `CMDMSG,<effect>,<text>`; `CMDBUSY`'s 4th field does the
same for a labelled bar. The effect is last because the label used to be the
rest of the line (old installs keep working; `metasanitize` makes a comma
after the label unambiguous). The downloader's bar sends **no** effect - the
panel is already the update_all screen. `meta_beginTransitionText` +
`meta_transitionToBuffer` are the text-screen idiom (`busy_showLabel`,
`msg_parse`); `metaBin` is free because every update screen follows
`CMDMETAOFF`.

- **Self-update** (`selfupdate_pass`): the updater stops the daemon to use the
  port, so the daemon sends `CMDMETAOFF` + `CMDBUSY,1,<SELF_UPDATE_TEXT>` and
  no banner. `oldcore` cleared. The uninstaller is deliberately not matched.
  `SELF_UPDATE_SCREEN="no"` disables. `selfupdate_running` matches the name,
  including the pre-0.4.8b spelling.
- **The updater then drives the panel itself** (`panel_*` in
  `tty2oledplus_update.sh`, firmware >= 0.7.0b only, `T2OP_PANEL` in tests):
  the same label (a repeat, so ignored), a `CMDBUSYLINE` per step, "Flashing
  firmware - the display will restart" before the flash, `panel_reopen`
  (asks `CMDHWINF` again - old firmware flashed to new gets the finish), then
  `CMDBUSY,0,<UPDATE_DONE_TEXT>` + a line, and **the daemon is started last**,
  after `panel_hold` has waited out `UPDATE_DONE_SECS`. A `die` shows Update
  Failed from `on_exit`. The update *to* a version is run by the previous
  updater, so a new panel feature shows one update late.
- **update_all** overrides everything while a process whose cmdline names it
  exists (`updateall_pass` greps `/proc/*/cmdline` every `UPDATE_ALL_POLL`s;
  it has no state file and may run inside a core). Sends `CMDMETAOFF` and
  `update_all.gsc` (`pics/user`, then `pics/banner`) cropped to 54 rows, or the
  name as text; on exit clears `oldcore` and `META_WIRE_LAST`.
  `UPDATE_ALL_SCREEN="no"` disables. While the downloader runs
  (`/tmp/ua_downloader_{bin,latest.zip,dd.pyz}`, not `--list-dbs`):
  `CMDBUSY,1,<UPDATE_ALL_TEXT>`, then `CMDBUSY,0` and the banner again.
  The bar waits out a Fade and stops on any command not in `boot_quietCommand`.
- **update_all's own words** (firmware >= 0.7.0b, `fw_atleast`, from
  `checkversion`): update_all flushes every screen line to
  `/tmp/update_all_print.log` (downloader output relayed live). The last
  useful line (no rules, dots, `DUPLICATED:`) -> `CMDBUSYLINE`. **Followed,
  not re-read**: once trusted the file is held open (`UA_FD`); `mapfile` takes
  what is new, `ua_absorb` looks for the rare lines that matter one by one
  (verdict, run time, `Sequence:`, CR) with one glob over the batch and
  otherwise cleans only the newest useful line (`ua_takecand`); `ua_feed` +
  `ua_takecand` must equal `ua_takeline` over every line (tested). Reopened
  when replaced (`-ef /dev/fd/N`) or smaller than at the last slow look.
  With firmware >= 0.7.3b `ua_follow` looks every `UA_LINE_MS` (100) between
  the once-a-second process checks, **starting no process** (tested with
  logging stand-ins on PATH): builtin `nap` (`read -t` on a pipe), `mapfile`,
  `printf -v`, `EPOCHREALTIME`. Older firmware: once a second. The file is the **previous run's** until
  update_all recreates it, so it is trusted only once its inode/mtime differs
  from when update_all was seen (`UA_LOG_REF`). `Sequence:` latches `UA_MAIN`:
  the bar stays from there to the end, downloader or not. `Success!` /
  `There were some errors in the Updaters` is the verdict -> `ua_done`
  (`CMDBUSY,0,<UPDATE_DONE_TEXT>` + "Finished in <run time>"), timed from
  there; on exit `ua_holddone` sleeps whatever is left of `UPDATE_DONE_SECS`
  (update_all's log viewer can outlast it). A verdict printed just before
  exit is read on the exit pass; with no print log, `update_all.log` if it is
  newer than the run.
- **Frontends keep the band.** `frontend_core` (MENU, misterzine, degauss,
  zaparoo, any case) pictures go out `CMDCOR,<core>,<effect>,band` as the file's top
  6912 bytes + 1280 zeros - so a 256x54 `.gsc` works (sent raw it would be a
  short 8192 read) and a 256x64 one is cut; the firmware blacks the band too.
  The menu's `CMDBOOTPIC` is always one. `band_showPicture` composes picture
  + notice into `metaBin` (render hook for a Fade) and transitions to it;
  `bandShown` is cleared by any non-quiet command (`band_noteCommand`).
- **Update checks** (`updatenote_pass`, first thing every pass the daemon
  owns the port, and on the upstream path's wait timeouts; never blocks). Two
  background jobs (`bg_start`/`bg_collect`, a subshell per job writing
  `UC_OUT.<name>` + `.rc`, killed after `BG_GIVEUP_<name>`), each at start
  and every `UPDATE_CHECK_MINUTES`, `UC_RETRY_SECS` after a failure, each
  behind its switch (`UPDATE_CHECK_TTY2OLED`, `UPDATE_CHECK_SYSTEM`; named
  literally in `update_check_on` - the settings test greps for consumers).
  **While flagged, neither polls.** `update_note` picks one of three texts;
  `sendnote` sends it as `CMDNOTE` only on change, `fw_atleast 0.7.1`;
  `NOTE_SENT="?"` after a display reset or sleep mode.
  - **tty2oled+** (`uc_pass`): curl of `releases/latest/download/VERSION`;
    a newer one (`version_newer`: no `b` beats the same number with one) to
    `UPDATE_FLAG` in `/tmp`; a flag not newer than `TTY2OLED_VERSION` is
    stale and removed. The updater (`update_answered`, latest only, not
    `--version`, not a failed flash) removes the flag **and** sends
    `CMDNOTE,` itself - the restarted daemon's first menu picture goes out
    before it knows the firmware version.
  - **System** (`sc_pass`, `SC_FLAGGED` in memory): `nice python3
    tty2oledplus_syscheck.py --cache` -> `yes <db>: <what>` / `no` /
    `nostate` / `error`. Not started while update_all runs
    (`updateall_process`, whatever `UPDATE_ALL_SCREEN` says); when it exits
    the flag is cleared and a check runs at once; a check that overlapped a
    run (`SC_EPOCH`) is discarded.
- **What the system check reads** (all internal to update_all's downloader,
  found on a real MiSTer - verify before trusting after an update_all
  upgrade): database URLs from `/media/fat/downloader.ini` +
  `downloader_*.ini` (update_all's drop-ins; sections lower-cased, `[mister]`
  is options); `Scripts/.config/downloader/downloader_fingerprints.json`,
  `{db: {hash, size}}` = **md5 and size of the database file as
  downloaded** (checked byte for byte); `downloader.json` `dbs.<id>.files`
  `{path: {hash}}` and `.zips.<id>.summary_file.hash`; `/MiSTer.version`.
  Level 1: fingerprint differs. Level 2, only then: an installed file's hash
  changed; an installed dated file (`_YYYYMMDD.ext`) the db dropped for
  another date of the same name; an installed archive's summary (remote
  `archives`, or `zips`); `linux.version` != `/MiSTer.version`. **A path two
  databases install is skipped** - the downloader keeps one copy and the
  other's store entry stays stale for ever (kuzecores + mister_ongo). New
  files are not counted (the filter is the downloader's business).
  `--all` forces level 2: an up-to-date MiSTer must say `no`. ETags cached
  only while the md5 seen equals the fingerprint; a 304 is "same". ~12s of
  CPU (TLS), 65 databases, about 1.6MB cold.
- **MiSTer's own updater** (`Scripts/update.sh`, Zaparoo's Update):
  `sysupdate_process` (`updateall_process` is it) reports `SYSUPD`
  `update_all` or `downloader` - the launcher by argv[1], its Downloader by
  argv[0] `/tmp/downloader.sh` (update_all uses `/tmp/update_all.sh`,
  `/tmp/ua_downloader_*`); an `update_all`-named process under it is its
  own step (it matched for a minute and flashed "update_all"). `UA_KIND`
  latches per run: no picture, `CMDBUSY,1,<label>,<effect>` at once, the bar
  throughout. The line follows its log - a `/tmp/tmp*` it holds open
  (`dl_findlog`, `ls -l /proc/<pid>/fd`), `UA_LOG` in place of the print log;
  `ua_clean` drops `DEBUG|` and tracebacks. Verdict at exit from
  `downloader.log`'s summary (`Errors:` then `none.`; `dl_readfinal`), only
  if newer than the run - a cancel (SIGTERM) writes none.
- **The notice in the firmware** (`bandnote.h`): kept across pictures; on a
  shown frontend it steps 0..`BNOTE_GREY` (8) over `BNOTE_FADE_MS`, a changed
  text fades out first; it waits for `TF_IDLE`, the boot outro (`boActive`),
  the busy bar, a page fade. Elsewhere it waits and is composed into the next
  frontend picture. At power-on (`bootHolding`) `band_heldUnder` leaves the
  band to the outro, then fades in. `CMDNOTE` is quiet and not activity (no
  wake from dim). 5x7, baseline `BNOTE_Y` 62: **u8g2 draws a glyph on the rows
  above its baseline and the descent on it** (measured with the real library).
- **Degauss** is a Scripts entry over the menu core (`CORENAME` stays
  `MENU`; MisterZine, by contrast, is an `.mgl` and a real `CORENAME`).
  **Zaparoo** replaces MiSTer's main (`main=zaparoo/MiSTer_Zaparoo` in
  `MiSTer.ini`) and runs over `zaparoo/menu_zaparoo.rbf`; `CORENAME` says
  `MENU` there too, the same binary also loads stock `menu.rbf`, and
  `STARTPATH` is never cleared. The main re-execs itself (same pid) with the
  loaded rbf as argv[1]. `menu_frontend` finds both in one `/proc` grep
  (Degauss by argv[0], winning; Zaparoo by argv[1]'s basename) and `readcore`
  swaps `MENU` for `degauss`/`zaparoo`; `findpicture` looks both up `exact`.
  `menu_frontend_possible` makes both waits poll every `UPDATE_ALL_POLL`s on
  MENU/degauss/zaparoo, since starting or quitting Degauss changes no state
  file.
- Console fields page every `METADATA_INTERVAL`s (`meta_pageDwellMs`; `0`
  never turns, so never reaches the description). Redraws only on movement.

Console fields (`METADATA_FIELDS` picks and orders them):

| field | source |
|---|---|
| title | `CURRENTPATH` via `clean_romname`, upgraded to the index's title on a hit |
| System | `CORENAME` through `names.txt` |
| Region | `(USA)` in the filename, or the index |
| Year, Company, Genre, Developer | index only |
| Format | extension, recovered off disk when MiSTer stripped it |

Arcade fields, all from the `.mra` in `STARTPATH`, read in **one** `awk` pass
(`parse_mra`; a `sed` per tag cost most of a second on the DE10-Nano):
`<name>` title; Year, Manufacturer, Region, Platform, Version by tag; Genre
from `<catver>` else `<category>`; Players; Controls from `<joystick>` or a
button count; Buttons = first `count` of `<buttons names>`; Orientation from
`<rotation>`; Set/Core/MAME from `<setname>`/`<rbf>`/`<mameversion>`; Author
from `<about author>`. `ARCADE_FIELDS` (short, paired) and
`ARCADE_FIELDS_WIDE` (a row each) pick them; `ARCADE_PINNED` must be a leading
run of `ARCADE_FIELDS`. Card labels are abbreviated (`Manufctr`, `Orient`) by
`_arcade_display_label`.

**Nothing built for a card may contain a comma** - `metasanitize` turns it to
a space (`Attack/Jump`, not `Attack, Jump`).

## Console layout, row by row

Every gap is a named constant in `metadisplay.h`. Each `CON_GAP_*` counts
**blank rows**; the next element's top is one past the last blank - leaving
out that `+1` silently closes the gap. `test_meta_layout.cpp` derives each gap
back from the constants.

```
row  0..11  "Now playing"        baseline CON_HEADER_Y   pips at the right, blinking
row 12      blank                         CON_GAP_HEADER
row 13      rule                          CON_RULE_Y
row 14..15  blank                         CON_GAP_RULE is 2
row 16..30  game title           baseline CON_TITLE_Y
row 31      blank                         CON_GAP_TITLE
row 32..38  field 0              baseline CON_FIELD_Y0   pinned
row 40..46  field 1                       + CON_FIELD_PITCH (8)
row 48..54  field 2
row 56..62  field 3
```

**Field alignment:** labels at the column's left edge; values share one column,
`meta_valueOffset()` = widest label across **every** field + 5 (so it does not
shift between pages), capped at half the text width.

## Arcade card, row by row

The console's top half across the whole panel: same header, rule, title,
fonts and rows; `CARD_FIELD_*` are the `CON_FIELD_*` constants. A vertical
rule at `CARD_CELL_X` (188) closes off a cell saying `Arcade` (5x7); the pips
sit `CARD_PIP_GAP` short of it.

```
row  0..11  "Now playing"   pips  |  Arcade   CON_HEADER_Y, CARD_CELL_Y
row 13      rule, full width                  CON_RULE_Y
row 16..30  title, full width                 CON_TITLE_Y
row 32..62  four rows                         CARD_FIELD_Y0, pitch 8
```

Grid pages pair the leading `metaCompact` fields two to a row, reading
across; wide pages give a row each to the rest, under a repeat of the pinned
grid row; the description page is last.

```
page 0   Year     1993          Manufctr  Midway
         Players  4             Region    World
         Orient   Horizontal    Core      blahmid_tunit
         Author   rejectedcoins Set       nbajam
page 1   Year     1993          Manufctr  Midway
         Controls 8-way         MAME      0289
         Buttons  Turbo/Shoot / Block/Pass / Steal
```

- **A grid page holding a single field does not exist**
  (`meta_cardMerged`, decided once per `CMDMETA`): the field moves to the
  right half of the first wide field's row - only if that wide value fits half
  a row unscrolled, only past page 0, never a pinned one.
- `meta_cardGridPages`/`WideSlots`/`WidePages`/`PageCount` are the only paging
  maths, so renderer and tick cannot disagree. `meta_cardColX` is the only
  thing that knows column positions. No counts sent = one field per row.
- Alternation: **artwork, pages, description, artwork**, each step with
  `tEffect` (the last `CMDCOR`'s effect, not random).
- The card marquees: long titles and wide values scroll. `meta_drawMarquee` is
  the one marquee (offset modulo the string's wrap, so all values share
  `valueScrollX`; `meta_cardValueWrap` decides the pause). `meta_drawField`
  blacks out left of the value column and redraws the label, since
  `meta_drawClipped` trims only on the right. The pause is timed from when the
  card **lands** (`cardScrollArmed`), not from `meta_showCard`.

## Page turns, pips, pinned fields

**A page turn fades only a rectangle** (`pagefade.h`): the paged rows, out,
redraw, in, on sixteen palette steps. `meta_consolePagedRect` /
`meta_cardPagedRect` derive it from the renderers' constants. No contrast veil
(contrast is whole-panel). Byte-aligned: odd x rounds outwards, keeping the
icon out. Borrows `fadeBin`; `pf_start` yields to a picture fade. During it
`meta_tick` still advances the title marquee (`meta_titleAdvance`) and pips,
composes, then `pf_reshow` writes the rectangle back at the current step.
Anything taking the panel cancels it; a cancel mid-fade-out still does the
redraw. Half its length, capped at 400ms.

**Pips blink** every `PIP_BLINK_MS` (500) when there is more than one page
(`pipLit`, `meta_pipTick`); relit on a page turn, `CMDMETA` and
`meta_showCard`. Not activity - does not stop dimming.

**Pinned fields:** the first `metaPinned` are on every page; the rest page.
Default pins System alone. The script decides, the firmware only counts:
`meta_addfields_ordered` emits pinned names first and sends the count (and the
card's `compact` count) as optional `CMDMETA` header fields - unambiguous
because values are comma-free; `1943 The Battle...` is not a count because no
comma follows. `meta_pinnedRows`/`meta_pageSlots`/`meta_pageCount` are the only
paging maths. Pinning caps at rows-1. `META_PINNED_COUNT`/`META_COMPACT_COUNT`
are reset in `meta_reset`, or a console game inherits the last card's pairing.

## Contrast, transitions, dimming, side swap

- **Only `contrastfade.h` calls `oled.setContrast()`.** Everything asks
  `contrast_fadeTo()`; `contrast_tick()` moves there over `CONTRAST_FADE_MS`.
  A fade starts from where the panel is; re-asking for the current target is
  not a new fade. The level is **base x veil**: base = `CONTRAST`/dimming, veil
  = Fade transition and boot fade-in only (a dimmed panel fades 80->0->80).
- **Power-on fade-in**: `setup()` blacks the panel, the start screen composes
  into the framebuffer and calls `transition_fadeIn(BOOT_FADE_MS)` (0.8s, must
  fit the 1s hold - tested). `boot_waitOrCommand` ticks it. Re-shows
  (`CMDSORG`, tilt) do not fade.
- **`TRANSITION=-2` fade** (`fadetransition.h`): out, black for
  `TRANSITION_BLANK_MS`, in, `TRANSITION_FADE_MS` each way (max 4000, default
  800). **Contrast 0 is not black on an SSD1322**, so sixteen palette steps
  darken the picture alongside, computed from `fadeBin` (8KB copy; ESP32 only).
  A state machine ticked from `loop()`, never blocking (the 256-byte RX buffer
  would overflow). `srcBin`/`actPicType` captured at request. A request while
  fading out/black replaces the pending picture; while fading in, turns around;
  any other effect cancels and draws. `meta_showCard` calls
  `transition_prepare()` first because it renders before asking.
- **The new picture is rendered, not drawn** (`oled_renderlogo()`), or it
  flashes undarkened. The fake panel's `shownPeak` catches that.
- **`30`..`39` slide while fading**: 8 fixed directions at 1 or 2 px/step, 2
  random (picked once per transition; the low bit keeps the speed).
  `tf_slideAt` is a function of the step: out `base + d*n`, in `-d*(16-n)` so
  both halves drift one way and end centred. `base` comes from `tfSlidePos`
  when a fade-in is turned around. 1px steps need the per-pixel slow path.
  `transition_cancel` clears the slide; `transition_fadeIn` never slides.
- `effect_clamp` is the one clamp (`-2`, `-1`, `0..maxEffect`, fade-slides);
  `effect_is_fade` the one fade test; `oled_transition()` the one entry point.
  `test-wire.sh` checks the ini's effect list against `oled_drawlogo`'s cases,
  `maxEffect` and `EFFECT_SLIDE_FIRST`/`_LAST`; `test-settings.sh` checks the
  editor offers exactly the ini's list.
- **Dimming** (the burn-in story since the screensaver went in 0.4.9b): after
  `DIM_AFTER`s with no command, fade to `DIM_CONTRAST` (absolute 0..255, capped
  at wake; replaced `DIM_PERCENT`, which the log warns about) over
  `DIM_FADE_MS` (default 6s); wake uses `CONTRAST_FADE_MS`. `meta_activity()`
  is called **only** from the command dispatcher - counting marquee/pager draws
  kept the panel from ever dimming.
- **Side swap** mirrors the console layout every `FLIP_MINUTES`, via a
  transition (`metaFlipped` toggled before `meta_transitionToConsole`).
  `meta_iconX`/`meta_textX`/`meta_textW` own the geometry. Icon x must be
  **even** (4bpp, `meta_blitIcon` copies bytes): 0 and 170.

## The wire protocol this fork adds

Upstream's commands are unchanged. `CMDSAVER`/`CMDSWSAVER` are accepted and
ignored (an unknown command is drawn as text, and old daemons and MiSTer SAM
send them). Additions, ESP32 only:

| command | payload |
|---|---|
| `CMDMETA,<kind>,<interval>[,<pinned>[,<compact>]],<title>[\|<label>=<value>]...` | one line |
| `CMDMETAOFF` | leave metadata mode |
| `CMDICON` | + 2752 raw bytes (86x64, 4bpp) |
| `CMDSHMETA` | force the metadata view |
| `CMDCBOOT,<ms>` | hold the picture just sent 0..10000ms, from when it is up. Console core change only, after the picture, before `CMDMETA` |
| `CMDDIM,<s>,<contrast>,<wake>[,<dim fade ms>]` | 0s disables; wake -1 = CONTRAST; fade 0..10000, default 6000 |
| `CMDFADE,<ms>` | contrast fade time 0..4000; before the first `CMDCON` |
| `CMDBOOTPIC,<core>,<effect>` | boot image as the core's picture (MENU, `BOOTSCREEN_AS_MENU`); no transition if the power-on screen is up |
| `CMDTFADE,<fade ms>,<blank ms>` | Fade timings 0..4000; before the first picture |
| `CMDBUSY,<0\|1>[,<label>[,<effect>]]` | sweep in the band; 0 finishes the cycle. A label blacks the panel above and shows alone; same label ignored, new one redraws. `0` with a new label (0.7.0b) swaps it in above the band without the line - the finish - or, with no busy screen up, draws it whole with no bar. Any drawing command stops it |
| `CMDBUSYLINE,<text>` | the busy screen's status line (5x7, grey, 51 columns), rest of the line; empty removes it; ignored with no label up; waits out a transition (`busyTextDirty`). Quiet for the bar. From 0.7.3b acked **without** the 15ms `cDelay`, which stops `loop()` - it comes ten times a second |
| `CMDMSG,<effect>,<text>` | centred message, transitioned; text is the rest of the line |
| `CMDCOR,<core>,<effect>,band` | a frontend's picture: 54 rows, band blacked, the notice composed in. Older firmware reads past `,band` (`toInt()`) |
| `CMDNOTE,<text>` | the frontends' band notice, rest of the line, 51 columns; empty removes. Quiet; kept until changed (0.7.1b) |
| `CMDFLIP,<s>` | side swap period; 0 disables |
| `CMDDESC,<bytes>` | + that many raw bytes, printable ASCII, 2048 kept (`DESC_MAX`, same in daemon and importer - `test-scrape.py`), excess discarded. After `CMDMETA`, which clears it |
| `CMDSCROLL,<h>,<v>` | marquee / description speeds, px/s, 1..200 / 1..100 |
| `CMDWRBOOT` | + 6912 raw bytes (256x54, 4bpp) |
| `CMDCLRBOOT`, `CMDBOOTINF` | forget / report the stored boot image |

`,` `|` `=` are separators; `metasanitize` strips them and non-printables
from every value. A short `CMDICON`/`CMDWRBOOT` is dropped, not half-applied.

## Launcher, updater, uninstaller, Scripts menu

- **One Scripts entry**, `tty2oledplus.sh` (plus the starter
  `tty2oledplus_install`, which deletes itself after success). A
  `dialog --menu` of Settings, Update, Scrape metadata, Uninstall (last).
  Settings/Scrape return to it; **Update and Uninstall are `exec`'d**, because
  they replace/remove the launcher bash is reading. With `fb_terminal=0` it runs
  the update. Over SSH: `tty2oledplus.sh update --no-firmware`.
- **The updater installs itself by rename**, never an in-place copy (bash would
  continue at the old byte offset in the new file). `test-installer.sh` catches
  it. The asset name stays `tty2oledplus_update.sh`: every installed updater
  and starter fetches exactly that. Renaming a script renames an asset - an
  old updater then cannot update (0.4.8b republished under the old name).
- **An update is always applied by the previous installer**, so
  `place_menu_scripts` in `S60tty2oled` copies the launcher to Scripts on every
  start (`cmp` first). Old entries (0.6.2b's three, pre-0.4.8b names) are swept
  only once the launcher is there, by both the updater and
  `place_menu_scripts`.
- **Uninstaller** runs from a copy in `/tmp` (`relocate`; exFAT). Asks twice
  with `dialog`, cancel the default: `--yesno --defaultno`, then keep / delete /
  cancel the user's files (`tty2oled-user.ini`, `coretypes.ini`,
  `pics/boot.png`, `pics/user`, `scraped/` -> `${FAT}/tty2oledplus-saved`).
  With no terminal it **refuses** unless `--yes`. Removes the install, boot
  hook + comment, every Scripts entry any version made, pid file, logs, the
  stored boot image; restores `MiSTer.ini` (below). Keeps the firmware and
  everything of upstream's.

## The settings editor

`tty2oledplus_settings`: `dialog` front end for `tty2oled-user.ini`, modelled
on MiSTer's `ini_settings.sh`.

- Edits **only** the user ini; reads the system ini for defaults. A value
  equal to its default is **removed**. `ini_put` changes one line or appends
  under its own header; never rewrites the file. The ini is **parsed, not
  sourced** (runs as root; tested with a value that would touch a file).
- Covers every user setting (49, seven categories). `test-settings.sh` checks
  both ways: every offered key exists in the ini *and* is read by `tty2oled.sh`
  or `tty2oled-meta.sh`; every user key is offered or on the exclusion list
  (`BAUDRATE`, `TTYPARAM`, `NAMES_TXT`, `TITLE_INDEX`, `TITLE_INDEX_DIR`),
  itself checked against the ini.
- Enforced: `METADATA_PINNED` ⊆ `METADATA_FIELDS`; `ARCADE_PINNED` is a prefix
  of `ARCADE_FIELDS` (offered as prefixes); lists keep their order
  (`list_merge`).
- **Single choice is always `--menu` + `--default-item`, never `--radiolist`**
  (a radiolist returns the ticked item, not the highlighted one; pads have no
  Space). Field lists stay checklists. `test-settings.sh` drives a fake
  `dialog` modelling both.
- No terminal (`fb_terminal=0`): says so, exits 2.
- **Boot screen is an action**: `pics/boot.png` -> `png2gsc.py --backend pure`
  -> `tty2oled-bootimg.sh set`; the `.gsc` is deleted either way, the PNG
  survives updates and is resent after a reflash. The stdlib backend
  (`load_grey_pure`: all filters, depths 1-16, colour types 0/2/3/4/6,
  interlaced refused) is byte-identical to the others (`test-png2gsc.py`):
  alpha composited per channel before luma, Pillow's rounding.

## Scrape metadata and the description page

- **Imports `games/<folder>/gamelist.xml`** (EmulationStation format: Skraper,
  ES-DE, Batocera, Skyscraper) on every `GAME_ROOTS` root, name matched
  without case, into `scraped/<system>.txt`. **Each file once, by
  `(st_dev, st_ino)`**: MiSTer can mount one partition twice (`/dev/sda1` on
  `usb0` and `usb1`), and a path string cannot tell. `tty2oledplus_scrape.sh` picks
  systems; `tty2oledplus_scrape.py` (stdlib, Python 3.9) does the work.
- Offered: consoles with an icon (`SYSTEMS` keyed by icon, `ICON_ALIASES`
  dedupes) and Arcade always. A system's first folder is taken whole; later
  folders are shared, own extensions only.
- **Arcade** = `games/mame/gamelist.xml` (+ `games/hbmame`, zips only); never
  `_Arcade`. `arcade_lookup_scraped` tries `MRA_SETNAME` then the core name
  and resets `SCR_*` first. The MRA wins shared fields; the gamelist adds
  Developer, Publisher, Rating, Released, Series, description (`Developr`,
  `Publishr`: eight letters, like `Manufctr`). `_nocomma` folds `", "`.
- Keyed on the file name without extension; `lookup_scraped` tries
  `CURRENTPATH` stripped and as-is. Release date -> `YYYY-MM-DD`, rating 0..1
  -> /20 shown as /10, `<family>` = series. **`|`-separated, not tabs** (bash
  `read` folds runs of tabs). Folded to printable ASCII. An import replaces
  only the games it lists, writes atomically, skips a gamelist that will not
  parse. `scraped/` is the user's.
- **Description page**: last console page; keeps header, title, icon; text
  word-wrapped (`meta_descWrap`, rewrapped on side swap), scrolling a pixel per
  `metaVStepMs` after `DESC_HOLD_MS`; turns when `meta_descTravel()` is done,
  not on the interval. Turning to/from it fades the whole field area. Text
  drawn first, then rows above `DESC_TOP` blacked (u8g2 has no clipping).
- **Arcade card** has it too, full width (`meta_descX`/`meta_descW`),
  `meta_drawDesc` for both; `meta_showPicture` when travel is done;
  `meta_descRewind` starts the hold. A card with only a description has
  `meta_cardFieldPageCount` 0.
- `CMDDESC` is length-prefixed (a 2KB line could overflow the 256-byte buffer
  while animating). Speeds are px/s in ini and wire, periods in firmware;
  default vertical 6.

## ScummVM

A Linux program under the menu core, not a core: its Scripts launcher writes
`ScummVM` to `CORENAME` (and `MENU` on exit), `RBFNAME`/`STARTPATH` still say
menu. **Zaparoo starts the binary itself** (`scummvmmaster ... lure`, the
target last) and `CORENAME` stays `MENU`: `menu_frontend` finds the binary by
argv[0] in its one `/proc` grep and `readcore` makes it `ScummVM`, over
Degauss/Zaparoo; with `SVM_PID` known it is a read, not a search. `scummvm_core` routes `build_meta` to `scummvm_meta` (console kind,
`DISPLAY_CORENAME` without RBFNAME). Everything is read off ScummVM itself -
**all measured on the real MiSTer** with Full Throttle, EcoQuest, SQ2:

- **Process**: `/proc/*/cmdline` whose argv[0] basename is `scummvm*`
  (`scummvmmaster`; the launcher script is bash). Pid kept, re-checked with a
  read. ini = `--config`/`-c`, else `$XDG_CONFIG_HOME|$HOME/.config/scummvm/scummvm.ini`
  from `/proc/<pid>/environ` (`HOME=/media/fat/ScummVM`). Start time = btime +
  stat field 22 / 100. A last argument that is not an option's value is an
  autostart target: running from the start.
- **Game started** = ini mtime > start + 1s. ScummVM flushes the ini when its
  launcher closes (`lastselectedgame=<target>`, `[target]` has
  `description gameid engineid path platform language extra`). **Nothing at
  all is written going back to the launcher** (ini, log, console, `/tmp`).
- **Back in the launcher** = the game held a file under its `path` (`ls -l
  /proc/<pid>/fd`, one fork) and has held none for `SCUMMVM_GONE_SECS` (3).
  SCUMM and SCI hold files; **AGI holds none** (opens, reads, closes) - a
  game never seen holding one runs until the ini changes or ScummVM exits.
  Engines are compiled in (no plugin to see load), fb is fixed 320x240 by
  `vmode`: no other signal exists. Editing options in the launcher also
  rewrites the ini and looks like a start.
- `META_SHOWCORE`: a shown game ended; `refreshmeta` calls `senddata`
  (`CMDMETAOFF` redraws nothing). The daemon watches the ini's **folder**; the
  poll stays `METADATA_POLL` (5s) - **a pass costs ~190ms of CPU on the DE10**
  (update checks 93ms, the two `/proc` greps 55ms; ScummVM's own ~18ms), and
  a 2s poll took 9% of a core from the game. Way back: two looks, 5-10s.
- **Metadata**: `gui-icons-*.dat` (zips in the ini's `iconspath`, here
  `/media/fat/ScummVM/ICONS`) carry `games.xml`/`companies`/`engines`/`series`
  (all 167 of the user's targets hit) and `icons/<engine>-<gameid>.png`
  512x512 (165 of 167; `icons/<engine>.png` fallback). Keyed by **engine and
  id** - ids repeat across engines. Later packs win.
- **Jobs** (`scummvm_jobs`, `bg_start`): `svi` index check once per pid
  (no-op on the same packs), `svc` one icon per game not yet cached, niced -
  the stdlib PNG path is ~10s on the DE10. Icon cached as
  `SCUMMVM_CACHE/icons/<engine>-<gameid>.gsc`; until then `pics/icon/ScummVM`.
  A late icon is sent alone (`ICON_SENT`). Index landing clears `SVM_BUILT`.
- **Per pass**: the layout is built once per start (`SVM_BUILT`/`SVM_C_*`);
  a pass is the ini `stat` + the fd `ls`. ScummVM pins both DE10 cores
  (`taskset 03`) - keep it that way.
- Scraped: `ScummVM.txt`, keyed by the game folder's basename (Batocera's
  `.scummvm` suffix dropped) or the target id. The importer's `_key` strips
  only a 1-4 alnum or `.scummvm` extension, as `lookup_scraped` does.
- Tests: `test-scummvm.sh`, a fake `PROC_ROOT` with the real cmdline, environ,
  stat and fd links; packs built as zips.

## Arcade descriptions from history.xml

`tools/history2gamelist.py` (not shipped, nor its output - the file's licence)
writes a `gamelist.xml` for the sets in a ROM folder from MAME's `history.xml`,
because ScreenScraper's quota cannot cover ~15000 zips. Also `2048.txt`:
`set|bytes|kept|ends at|title` for each shortened entry. Uses the importer's
own `fold()`/`clip_desc()`.

- **Shortened here, not cut**: whole paragraphs while they fit; under two
  thirds of `DESC_MAX` (`FILL`), whole sentences of the next. Never end on a
  heading or a list. The importer's `clip_desc` cuts at a sentence end in the
  second half, else at a word with `...`; "Dr. Mario"/"Vs." are not ends
  (`_NOT_AN_END`).
- **2048** because reading time, not RAM: at 6px/s it is about a minute (1024
  cut 615 entries, 2048 cuts 145, 4096 22).
- An entry keeps only the description (drops "published N years ago", cuts at
  `- TECHNICAL -`, `- TRIVIA -`...). **Clone pointers** ("see the original
  ... entry") are followed to the original's description:
  - a pointer is release notes + "see/visit/refer to" sentences only (`NOTE`,
    `SEE`), or a first paragraph of only that;
  - target = the quoted title, else the entry's own, matched against titles
    and romanisations;
  - a machine leads only to its own kind (header's first two words); a
    cartridge only when the pointer names its platform or model ID;
  - then description > pointer, machine > cartridge, longest wins; a few hops;
  - an original with no description leaves the clone its own note if it has a
    sentence of six words or more.
- **A set with no description is omitted**, never written empty (it would
  wipe a Skraper import; the two are not merged).

## Tests

`./tests/run-all.sh` - sixteen suites (metadata, wire, index, version,
daemon, deploy, settings, ScummVM, png2gsc, scrape, syscheck,
history2gamelist, installer, flash, firmware parser, firmware layout). CI runs all with inotify-tools and
ImageMagick. No shellcheck in `run-all.sh`.

- Installer: builds a real release from the working copy, serves it via
  `file://` as GitHub does, installs into a fake `/media/fat`.
- Deploy: runs the real script from a scratch repo copy with recording fakes
  for `ssh`/`scp`; boot hook sourced with `BOOTHOOK_LIB=yes`.
- png2gsc: reads output through `tail -n +4 | xxd -r -p`; regenerates
  `bootlogo.h` and fails on a difference.
- Daemon: the loop itself (unplugged display, missing `CORENAME`, init
  start/stop); `/dev/null` stands in for a present display.
- Firmware: headers compiled against stubs, `-Wall -Wextra -Werror`,
  ASan/UBSan, a real 8192-byte framebuffer.

**Every bug here reached hardware first. Add the test and confirm it fails
against the unfixed code before committing.**

## Hardware, building, deploying

**Hardware:** Wemos LOLIN32 (classic ESP32), USB, SSD1322 256x64. Ask the
display, don't trust the installer menu (a generic DevKit V4 is `lolin32`,
not `esp32de`):

```bash
. /media/fat/tty2oledplus/tty2oled-system.ini
stty -F ${TTYDEV} ${BAUDRATE} ${TTYPARAM}
echo "CMDHWINF" > ${TTYDEV}; read -t5 R < ${TTYDEV}; echo "$R"   # HWLOLIN32;0.4.0b;
```

**Build:** `./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32` (or
`esp32de`/`esp32s3`) -> `build-out-<board>/MiSTer_SSD1322_USB.ino.merged.bin`,
flashable at `0x0` (gitignored). Arduino IDE: `WEMOS LOLIN32`; on an S3 set
**USB CDC On Boot: Disabled**. Flatpak IDE needs
`flatpak override --user --device=all cc.arduino.IDE2`.

**Deploy** (SSH, from anywhere; `MISTER=root@192.168.1.206`):

```bash
./tools/deploy-mister.sh                    # scripts, then restart the daemon
./tools/deploy-mister.sh --firmware --flash # also copy and flash the newest build
./tools/deploy-mister.sh --index|--icons|--pics|--all
./tools/deploy-mister.sh --dry-run --all    # check and list, touch nothing
```

- Checks everything local and reachability **before** copying anything; one
  multiplexed SSH connection. Asks `S60tty2oled status`, never a pid file.
- Never ships `tty2oled-user.ini`; `coretypes.ini` only when missing;
  `titleindex/`, `pics/` only by flag. `--pics` is one `tar` stream
  (`/media/fat` is `sync,dirsync`), **replaces** `pics/banner`+`pics/arcade`,
  removes `pics/alt`, excludes `pics/user`.
- By hand: firmware first, then scripts.
- Debug: `debug="true"` in the user ini, log `/tmp/tty2oled`;
  `tty2oled-diag.sh` right after loading a game.

## Artwork folders

| folder | what | size | whose |
|---|---|---|---|
| `pics/banner` | console/computer/utility core banners (192) | 256x64 | release |
| `pics/icon` | console icons (27 core names, 26 systems) | 86x64 | release, in the scripts archive |
| `pics/arcade` | `wheels.bin` + `wheels.idx` | 256x64 | release, in `tty2oledplus-pics.tar.gz` |
| `pics/user` | the user's own banners, by core or set | 256x64 | **theirs** - nothing writes it |

**Finding a picture** (`findpicture`):

- **Arcade** (`classify_core`; `core_kind` asks it even with metadata off):
  `pics/user`, then the wheel index by the **whole** lower-cased set name.
  **Never `pics/banner`, never a trimmed name** - trimming finds a different
  game's wheel for 367 sets. Otherwise the name as text.
- **Everything else** (`findbanner`): `pics/user`, `pics/banner`, trimming a
  character at a time **per folder**.
- `PRIORITIZE_USER_BANNERS` picks which folder is first; the priority is
  absolute.
- Icons have no user folder (an 86x64 icon would be indistinguishable from a
  banner). No blank stub icons: the files are the list.
- `test-wire.sh` fails if a banner is named after a wheel set that is not a
  core.

**`migrate_pics`** (in `S60tty2oled`, every start, idempotent - the previous
updater knows nothing of new layouts): renames `pics/GSC` -> `pics/banner`
etc., removes `pics/alt`, removes an old folder only once its replacement
exists, never overwrites `pics/user`. The wheel pack arrives one Update late on
an existing install (the old updater sees `pics/banner` and fetches nothing;
`deferred_setup` logs it); the new updater also checks for the wheels and
**replaces** `pics/banner`/`pics/arcade` whole. `make-release.sh` refuses to
build without the wheels.

## Arcade wheel logos

```bash
./tools/wheels2gsc.py ~/Downloads/MAME0.277Wheels -o /tmp/wheels-gsc --nodupes --report /tmp/wheels.csv
./tools/gscpack.py /tmp/wheels-gsc -o pics/arcade
```

- Converted on the workstation (Pillow, 5ms) - the MiSTer's stdlib decoder
  takes 4-16s a wheel.
- **Levels**: 2nd..99th percentile stretched over `--floor`..255 with
  `--gamma`, plus: a span under `MIN_SPAN` widened downwards (flat-colour
  logos); a peak short of 15 lifted **at most two levels** (`MAX_LIFT`);
  nothing above level 4 (`DARK_TOP`) -> reconverted inverted. Anything
  cleverer (body-to-15) looked worse on glass; the contact sheet is not the
  panel. Panel levels 0 and 1 look identical; `--floor 40` = level 2.
- **`--nodupes`**: 7614 of 12235 are identical after conversion (hashed on the
  `.gsc`); shortest name kept; `duplicates.txt` = `<removed>|<kept>`,
  cumulative across runs. exFAT here has **128KB clusters**.
- **Pack**: `wheels.bin` = 4621 raw 8192-byte frames; `wheels.idx` =
  `<set>|<frame>` for all 12235 sets, lower-cased, with a `# frames N` header
  (`.bin` size must be N*8192). The packer reads `.gsc` via `xxd -r -p`.
- **Daemon** (`findwheel`, then `senddata`, after `CMDCOR` + `WAITSECS`):

  ```bash
  frame="$(awk -F'|' -v c="${core,,}" '$1 == c { print $2; exit }' "${WHEEL_IDX}")"
  [ -n "${frame}" ] && dd if="${WHEEL_BIN}" bs=8192 skip="${frame}" count=1 2>/dev/null >"${TTYDEV}"
  ```

  Whole-field `awk`, not `grep` (a setname is not a regex). `findwheel`
  checks the frame against the `.bin`'s real size.
- Open: where the PNGs come from - redistributing 12k third-party logos.

## Artwork formats

`.gsc` = three header lines, then pixels row-major, 16 greys (`0`..`f`). Two
spellings exist (one hex char per pixel; `0X1f,` bytes); both work because the
daemon sends `tail -n +4 | xxd -r -p`, and **`xxd -r -p` restarts a token at
every non-hex character** - anything reading these must shell out to it. The
header is exactly three lines.

| | size | bytes | where |
|---|---|---|---|
| banner | 256x64 | 8192 | `pics/user`, `pics/banner/<CORENAME>.gsc` |
| icon | 86x64 | 2752 | `pics/icon/<CORENAME>.gsc` |
| boot screen | 256x54 | 6912 | ESP flash via `CMDWRBOOT` |
| built-in boot logo | 256x54 | 6912 | `bootlogo.h` |

```bash
./tools/png2gsc.py --banner --out pics/banner/NES.gsc nes.png
./tools/png2gsc.py --out pics/icon/NES.gsc nes.png          # name = CORENAME
./tools/png2gsc.py --boot splash.png                         # then, on the MiSTer:
/media/fat/tty2oledplus/tty2oled-bootimg.sh set|status|clear splash.gsc
```

Fit-and-centre by default; `--stretch`, `--dither`, `--invert`,
`--backend pillow|magick|pure`. Each grey goes to the **nearest** of 0, 17 ..
255, identically in every backend.

## The boot screen band

The bottom **10 rows** belong to the firmware, so a boot image is 256x54
(`BOOTIMG_BYTES` 6912 - a literal in `png2gsc.py`, `tty2oled-bootimg.sh` and
`bootscreen.h`; `test-index.sh` checks they agree).

```
row  0..53  picture              stock logo or the stored image
row 54      blank                BOOT_GAP_BAND
row 55..62  sweep bar            BOOT_BAR_Y, BOOT_BAR_H
row 57..63  build version        BOOT_VER_Y, 5x7 font
```

- Picture and version in the first frame; after `BOOT_HOLD_MS` (1s) the sweep
  runs until the daemon speaks. Constants hang off `BOOT_BAND_Y`, checked by
  `test_meta_layout`.
- **The sweep is a comet**: white head, tail dropping a level every
  `BOOT_BAR_SEG` (4) px to black (`BOOT_BAR_TAIL` 64). `BOOT_BAR_PX_STEP` (2)
  px every `BOOT_BAR_PX_MS` (2ms), **one step per tick, never a catch-up
  burst** (a jump past the tail's black end smears; step < seg is tested).
  The tail erases itself; a run to `BOOT_BAR_SPAN` leaves the band empty.
  `boot_barDraw` (in `bootoutro.h`) is the one drawer; `boot_barClear` on end.
- **`boot_waitOrCommand`** replaces every `delay()` and returns on
  `Serial.available()`; `ttyrdy;` goes out *before* the screen. At power-on the
  sweep repeats indefinitely; re-shows (`CMDSORG`, tilt) are bounded.
- **At power-on the boot screen becomes the menu's picture**
  (`BOOTSCREEN_AS_MENU`, `CMDBOOTPIC,MENU,<effect>`): nothing transitions; the
  outro (from `loop()`) finishes the sweep cycle, then fades the version over
  `BOOT_VERFADE_MS` (after the bar, not concurrently - that stuttered). It
  waits for the fade-in and stops on anything else.
- `bootHolding`: `boot_quietCommand`s (contrast, fades, dim, clock, version,
  `CMDMETAOFF`, `CMDBOOTPIC`) leave it set; everything else clears it.
- One path for built-in and stored image; composed into `metaBin` (`logoBin`
  on ESP8266), blacked from `BOOTIMG_BYTES` to 8192 first.
- `bootlogo.h` is **generated**:
  `./tools/png2gsc.py --boot --header -o MiSTer_SSD1322_USB/bootlogo.h MiSTer_SSD1322_USB/bootlogo.png`
- Legacy 8192-byte stored images are cropped; `CMDBOOTINF` says `BOOTIMG,legacy`.
- `tty2oled_logo` in `bitmaps.h` is upstream's, unused, kept commented.

## Releases, installer, MiSTer.ini

- Users copy `tty2oledplus_install.sh` to Scripts; over SSH:
  `curl -fsSL --cacert /etc/ssl/certs/cacert.pem https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/tty2oledplus_update.sh | bash`.
  **MiSTer's curl needs `--cacert /etc/ssl/certs/cacert.pem`.**
- **Asset names carry no version**; `/releases/latest/download/<name>` finds
  them, which skips pre-releases - so CI never marks one, `b` or not.
- The installer checks every download against `SHA256SUMS` **before changing
  anything**; installs `tty2oled-user.ini`/`coretypes.ini` only when missing;
  flashes only on a version mismatch and only for the board the display names
  (or `--board`); refuses while upstream is installed or its daemon holds the
  port; restarts the daemon however it ends. No "press a key" - MiSTer's
  Scripts wrapper already does.
- The starter fetches and verifies the latest updater, runs it, and deletes
  itself only after success left the launcher beside it. Its temp dir is a
  global (the `EXIT` trap runs after `main` returns). Everything is in `main()`
  called on the last line, so a truncated `curl | bash` runs nothing.
- `CMDHWINF` answers are parsed as `;` tokens - queued `ttyack;`s precede them
  (`checkversion` does the same).
- `ESP32_CORE_VERSION` in the workflow pins the core; libraries are CI's
  current ones.
- **`log_file_entry=1`** is set by the installer **inside `[MiSTer]`** (per-core
  sections follow it). `.misterini.state` records `present`/`changed`/`added`/
  `created`, written only on the run that changed something; the uninstaller
  reads it first and undoes accordingly, leaving a value the user has since
  set themselves.
- **Boot hook**: `[ -e /media/fat/tty2oledplus/S60tty2oled ] && /media/fat/tty2oledplus/S60tty2oled $1`
  at the **top** of `user-startup.sh` (created from `_user-startup.sh` if
  absent), matched on the full path. An existing hook elsewhere, or commented
  out, is reported and left alone. Warns if upstream's hook and `S60tty2oled`
  are both live.

## Title index and core names

- `/tmp/GAMEID` (CRC32) -> `lookup_crc` -> title, year, publisher, genre,
  developer. Built from libretro-database `metadat/*` (cached in
  `.index-cache/`, `--force` refreshes):
  `./tools/build-title-index.sh [CORE...] | --list`, then `deploy --index`.
- `titleindex/<CORENAME>.idx`, lines
  `CRC32|Title|Region|Year|Publisher|Genre|Developer|Serial`; five-field lines
  and the single-file `TITLE_INDEX` still parse.
- **Index titles must equal `clean_romname`'s** (`test-index.sh` compares the
  two implementations) - the CRC hit and the `lookup_name` fallback must agree.
- Missing core: add it to `sysmap()`; keys are `CORENAME` values.
- `names.txt` renames `System` and the no-game title (`display_corename`;
  tries `CORENAME`, `RBFNAME`, `STARTPATH` basename, and that without
  `_YYYYMMDD`). Not for icons or arcade. `USE_NAMES_TXT="no"` disables.

## Things that cost time

- **exFAT ignores case.** `pics/ICON` *is* `pics/icon`; a migration deleting
  the old spelling deleted the icons on every start for four releases. Check
  `-ef` before removing an old spelling; never ship names differing only in
  case. GitHub asset names are case-insensitive too.
- **CI shellchecks; `run-all.sh` does not.** A test defining a function named
  `rm` spent `v0.6.1b` (SC2218). Stub commands with executables on `PATH`.
- **`--radiolist` returns the ticked item**, not the highlighted one. Tests
  must drive the widget, not assume it.
- **An uninstaller that cannot ask must not proceed.**
- **The MiSTer has no image library** - hence the stdlib PNG backend.
- **`FULLPATH` is the folder**; the file name is in `CURRENTPATH`.
- **Loading a ROM does not touch `CORENAME`**; watch the game-state files.
- **MiSTer never clears `FULLPATH`/`FILESELECT`/`GAMEID`**; they outlive the
  core. Trusted only when fresh.
- **`-nt` compares whole seconds**, and MiSTer writes all state files within
  one. Test `CORENAME` *strictly newer than* the selection, run the guard only
  on a core change, and **latch** the rejected selection (`META_STALE_REF`,
  content + mtime).
- **`GAMEID` freshness is tested against the selection**, not `CORENAME`: the
  CRC lands a few hundred ms after it. Older than `CURRENTPATH` = previous
  game; equal mtimes = fresh.
- **CRC misses whole systems** (header bytes hashed differently);
  `lookup_name` is the exact-match fallback. `tty2oled-diag.sh` shows which
  path resolved.
- **`FILESELECT`**: `active` while browsing, `cancelled` after the OSD; only
  `selected` counts, and the loaded selection is latched
  (`META_LAST_SELECTED`). Identical metadata is not resent.
- **`log_file_entry=1`** or MiSTer publishes only the core name.
- **Core names are not index names** (`MEGADRIVE`/`GENESIS`, `GBC`):
  `_index_alias`, case-insensitive `_index_file`.
- **Neo Geo data comes from MAME** (`mamexml2index.awk`, `romof="neogeo"`), one
  record per " / " alias.
- **`TGFX16` covers cartridge and CD**: one index merges both (`harvest`).
- **Disc systems**: redump only - title, region, serial; keyed on the serial in
  `GAMEID` (`lookup_serial`). Every reader must absorb the eighth field.
- **Not every core publishes `STARTPATH`**; `coretypes.ini` states kinds
  outright, else they land on `unknown` (metadata off).
- **ESP32 core 3.x dropped channel LEDC**; a macro shim maps it.
- **A daemon started over `ssh -t` died on disconnect** (SIGHUP to the
  foreground group). `start` uses `setsid`, its own stdio (`DAEMONLOG`), and
  ignores SIGHUP around the fork.
- **A merged image erases `nvs` and `spiffs`** (boot image, settings).
  `fw-segments.py` writes only segments with data when the display's partition
  table (read at `0x8000`) matches; otherwise the whole image.
- **CI builds three boards against today's libraries** (`v0.4.0b`: GFX 1.12.6
  made `round(<int>)` ambiguous). See step 3.
- **Bash on the DE10 costs 50-100us a statement**, a fork ~10ms, a locale
  switch (`local LC_ALL=C`) 0.5ms, a `[[ =~ ]]` a regex compile; `mapfile`
  reads a line in 10us where a `read` loop takes 150us. Anything run ten
  times a second is written for that (`ua_follow`). Measure CPU from
  `/proc/$$/stat`, not `$(times)` - that is the subshell's.
- **A display asked too early does not answer**: straight after a flash or a
  replug `CMDHWINF` goes unanswered and `FW_VERSION` stays empty, withholding
  everything gated on `fw_atleast`. `fw_pass` asks again every `FW_ASK_SECS`
  up to `FW_ASK_MAX` times (`checkversion quiet`).
- **`CMDBOOTPIC` draws**, though it is on `boot_quietCommand`'s list; the busy
  bar uses the list minus it, and whoever puts a busy screen up takes it down.
- **Zaparoo probes the display's port as a PN532 NFC reader** (`[readers]
  auto_detect`), writing `55 55 00 ...` frames with no newline: the next
  command's line was drawn as text ("UUU") and lost - the busy bar with it -
  and a probe mid-flash broke it. It remembers a port that did not answer
  only until the device file's **mtime** changes, and Linux stamps a tty's
  node on every write through it (8s granularity) - so each write of ours
  invited the next probe. `ttynode` (in `tty2oled-port.sh`) writes through
  `/tmp/tty2oledplus.tty`, a node of our own for the device (`/run` is
  nodev); `TTYPORT` is the device, which `serialready` checks. The firmware
  (`linejunk.h`) keeps what follows the last control/non-ASCII byte if it is
  a `CMD`, else drops the line (no ack). Zaparoo has no per-port ignore;
  `auto_detect` off per driver would lose real USB PN532 readers.
  `ttynode` tests the node with `stty -F` (non-blocking), retried: a plain
  open at boot failed in the second of Zaparoo's first probe and the daemon
  wrote through `/dev/ttyUSB0` for good. Zaparoo still probes once at its
  start, and a probe mid-picture shifts it (bytes inserted, tail wrapped):
  `port_pass` sees the device's time move (`-nt PORT_REF`, no fork; the
  device is in the inotify list) and redraws everything `PORT_SETTLE_SECS`
  later; `port_mark` re-baselines after sleep mode (SAM writes through the
  device). `TIOCEXCL` does not keep root out on MiSTer - tested.
- **`ttyUSB` numbers follow detection order**, so with a Zaparoo reader
  plugged in the display can be `ttyUSB1`. `tty2oled-port.sh`: once the
  display answers `CMDHWINF` (daemon's `checkversion`, flasher, updater),
  `port_remember` writes its `/sys` identity to `.display-port`
  (`vid:pid:serial:usbpath:iface`); `port_resolve` finds it again for a
  numbered `TTYDEV` (socket beats serial - CP2102s share `0001` - a tie or
  no match leaves `TTYDEV`). A by-id link in `TTYDEV` is left alone. No
  port is written to for this. `port_moved` re-finds it after a replug;
  `TTYCONF` is the ini's `TTYDEV`, `TTYPORT` the found device.
- **A theory that fits is not a cause** - reproduce it. The "flash hang" was
  `ssh -t`, not LittleFS.
- **`/tmp/tty2oled_sleep` is a mutex**: MiSTer SAM drives the port itself
  (sourcing our ini for `TTYDEV`). Nothing writes while it exists; the updater
  refuses. SAM writes a deadline into it; `sleepmode_pass` honours it plus
  `SLEEP_STALE_GRACE` (60s), which also recovers SAM dying on our paths (it
  hardcodes `/media/fat/tty2oled`). Waking from sleep is a full redraw
  (`oldcore`, `META_WIRE_LAST`, `DEFERRED_DONE` cleared).
- **A setting in the ini is not a setting that works** - `SHOW_CONSOLE_SPLIT`
  was read by nothing for three releases. Hence the consumer check.
- **ROMs live on SD or USB**; `FULLPATH` is relative to the SD.
  `find_rompath` tries every `GAME_ROOTS`. Quote names (`[!]` globs).
- **MiSTer strips the extension** for single-extension cores; `FULLPATH`
  (`_Console` vs `games/GBA`) is what separates a core launch from a game.
- **Cores can launch via `.mgl`** (`GameGear` core, `RBFNAME` `SMS`).
- **The selection is written ~3.3s before `CORENAME`** on a menu core launch.
  `build_meta` rejects `.rbf`/`.mra`, anything matching `STARTPATH`, and
  `FULLPATH` folders starting with `_`.
- **Nothing drew the layout on a game change**: `meta_parse` sets
  `metaNeedsDraw` for console kinds.
- **Match the boot line on the full path**, not the word `tty2oled`.
- **The panel booted at contrast 5**; it starts at 255 now.
- **`setup()` held the boot animation**, ignoring serial for ~8s; hence
  `boot_waitOrCommand` and the outro in `loop()`.
- **Startup order is boot time**: only contrast and rotation precede the first
  picture; the rest is `deferred_setup`. `CMDWAITSECS` (0.05) after one-line
  commands, `WAITSECS` after picture headers (`cmdwait` falls back).
- **Every main-loop branch must block.** `waitforcorename` watches the
  directory (inotify on a missing path returns at once) and falls back to
  sleep.
- **The port disappears** (unplug, re-enumeration, flash). `serialready` runs
  every pass and, on return, re-handshakes and clears `oldcore`,
  `META_WIRE_LAST`, `DEFERRED_DONE`.
- **Pid files**: ours has its own name; `daemonpid` trusts a pid only if
  `/proc/<pid>/cmdline` names this install's `${DAEMONSCRIPT}`; `children`
  reads `/proc`. Only the init script and the ini may name a pid file
  (`test-daemon.sh`) - three scripts broke when it moved. Grep for every
  reader before moving a path.
- **Two scripts placing one file**: the deploy put menu scripts only in
  Scripts, and `place_menu_scripts` reverted them from the install folder on
  restart. A test had pinned the bug. When test and behaviour agree and
  reality does not, suspect both.
- **The busy bar's remembered label** must be forgotten on any drawing
  command, running or not (`busy_noteCommand`).
- **ScreenScraper needs developer credentials**; hence gamelists.
- **Two things animating one band** stutter; sequence them.
- **A multi-transfer picture is composed at the bottom of the fade**
  (`tfRenderHook` at `TF_BLANK`), not at request, so the icon can land.
- **A blocking read stops animation**: `serial_readTicking` ticks
  contrast/transitions while reading - **the icon only** (`logoBin`/`metaBin`
  are what a transition renders from).
- **An icon landing mid-transition** waits for `TF_IDLE` and no page fade
  (`metaIconRedraw`), and is guarded on `!metaNeedsDraw` and the core-boot
  hold, or a game change cuts without a transition. Replay the daemon's real
  command order against the firmware.
- **`png2gsc.py`'s backends disagreed**: dithering must go through RGB,
  16-bit PNGs must scale, `thumbnail()` never enlarges, `-colors 16` is not
  the panel's palette. Round to the nearest level.
- **`EPOCHREALTIME` uses the locale's decimal comma**; tests pin `LC_ALL=C`.
- **Check that a test fails without its fix** - a renamed variable left the
  staleness guard testing nothing while its test passed.
- Read the daemon's own debug log before believing a feature fires.

## Not done yet

- 20 console cores have no icon (split layout, black panel beside it).
- ScummVM: AGI (and any engine that holds no file) cannot tell its launcher
  from its game.
- WonderSwan resolves per game; misses are non-No-Intro filenames.
- Neo Geo: 203 sets from MAME 2003-Plus, matched by title.
- The LEDC shim is a clean upstream PR on its own.
