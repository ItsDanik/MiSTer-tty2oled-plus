# tty2oled+ — working notes

**tty2oled+** is a fork of
[venice1200/MiSTer_tty2oled](https://github.com/venice1200/MiSTer_tty2oled),
GPLv3 like upstream. Branch: `feature/game-metadata`, based on upstream `50c08ac`.

The name is branding only. Install paths (`/media/fat/tty2oled`), script and ini
filenames, the `S60tty2oled` init script, the NVS namespace and the serial
protocol all deliberately keep the upstream spelling - renaming any of them
would break existing installs, the official installer and the update scripts
for no benefit.

Upstream shows one picture per **core**. This fork shows the **game**: arcade
cores alternate artwork with an info card, console cores get a split layout
with scrolling text and an icon panel.

## Layout of the change

| Path | What it is |
|---|---|
| `tty2oled-meta.sh` | New. Turns MiSTer's `/tmp` state files into display metadata. |
| `tty2oled.sh` | Daemon. Sends `CMDMETA`/`CMDICON`, watches game state, not just the core. |
| `tty2oled-system.ini` | New settings (see below). |
| `coretypes.ini` | New. `corename=console\|computer\|arcade`, consulted before folder guessing. |
| `MiSTer_SSD1322_USB/metadisplay.h` | New. Arcade card + console split layout. |
| `MiSTer_SSD1322_USB/bootscreen.h` | New. LittleFS-backed custom boot image. |
| `MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino` | Includes the two headers; LEDC shim for ESP32 core 3.x. |
| `tests/` | 418 checks, no hardware needed. |
| `tools/build-title-index.sh` | Builds the CRC32 title index from libretro-database. Workstation. |
| `tools/mamexml2index.awk` | Year/publisher for arcade-lineage consoles out of a MAME XML. |
| `tools/png2gsc.py` | PNG -> the 4bpp `.gsc` the display wants. Workstation. |
| `tools/make-icon-stubs.sh` | A blank, correctly named `.gsc` per console core. |
| `pics_pri/ICON/` | The icons themselves; same path as on the MiSTer. |
| `tools/tty2oled-bootimg.sh` | Installs/clears the stored boot screen. **On the MiSTer**. |
| `tools/dat2index.awk`, `tools/index-emit.awk` | The DAT parser and index emitter it drives. |
| `tools/build-tty2oled.sh` | Builds the firmware with arduino-cli. Runs on the workstation. |
| `tools/deploy-mister.sh` | Pushes this working copy to the MiSTer over SSH. Workstation. |
| `tools/flash-mister.sh` | Flashes the firmware. Runs **on the MiSTer**. |
| `tools/tty2oled-diag.sh` | Dumps MiSTer's state files and what they parse to. **On the MiSTer**. |
| `tools/tty2oled-capture.sh` | Records every state change while you load games. **On the MiSTer**. |

## What ends up on screen

`build_meta` in `tty2oled-meta.sh` turns MiSTer's `/tmp` files into a kind, a
title and an ordered field list; `sendmeta` puts it on the wire; the firmware
composes it.

| kind | layout |
|---|---|
| `arcade` | full-screen artwork, alternating with an info card every `METADATA_INTERVAL`s |
| `console` | split: "Now playing", a rule, the title, paged fields on the left; an 86x64 icon on the right |
| `computer` | untouched - full-screen artwork, as upstream |
| `unknown` | as `computer`; metadata off |

The console title marquees when it overflows the column, and the field list
pages every 2.5s when there are more than three. Both only redraw when
something actually moves.

Where a field comes from:

| field | source |
|---|---|
| title | `CURRENTPATH` cleaned by `clean_romname`, upgraded to the index's canonical title when the game resolves |
| System | `CORENAME`, renamed through `names.txt` |
| Region | the `(USA)` group in the filename, or the index |
| Year, Company, Genre, Developer | the index only - a filename cannot supply them |
| Format | the file extension, recovered off disk when MiSTer stripped it |

`METADATA_FIELDS` picks which of those reach the screen and in what order.

## The wire protocol this fork adds

Upstream's commands are unchanged. These are additions, all ESP32-only:

| command | payload |
|---|---|
| `CMDMETA,<kind>,<interval>,<title>[\|<label>=<value>]...` | one line |
| `CMDMETAOFF` | none - leave metadata mode, back to plain artwork |
| `CMDICON` | followed by exactly 2752 raw bytes (86x64, 4bpp) |
| `CMDSHMETA` | none - force the metadata view now |
| `CMDWRBOOT` | followed by exactly 8192 raw bytes (256x64, 4bpp) |
| `CMDCLRBOOT` | none - forget the stored boot image |
| `CMDBOOTINF` | none - replies with the boot image status |

`,` `|` and `=` are the separators, so `metasanitize` strips them from every
value along with anything non-printable. A short `CMDICON`/`CMDWRBOOT`
transfer is dropped rather than half-applied.

## Running the tests

```bash
./tests/run-all.sh
```

Five suites: metadata extraction, wire protocol, title index, firmware parser,
firmware layout. The firmware suites compile the display headers against stubs under
`-Wall -Wextra -Werror` with ASan/UBSan and a real 8192-byte framebuffer — no
Arduino toolchain, no ESP32, no serial port.

**Every bug fixed here reached hardware first.** When fixing another one, add
the test and confirm it fails against the unfixed code before committing.

## Hardware this was tested on

Wemos LOLIN32 (classic ESP32), USB mode, SSD1322 256x64. Ask the display what
it is rather than trusting the installer menu — "DevKit" appears twice there,
and a generic ESP32 DevKit V4 is the `lolin32` profile, not `esp32de`:

```bash
. /media/fat/tty2oled/tty2oled-system.ini
stty -F ${TTYDEV} ${BAUDRATE} ${TTYPARAM}
echo "CMDHWINF" > ${TTYDEV}; read -t5 R < ${TTYDEV}; echo "$R"   # HWLOLIN32;230702;
```

## Building the firmware

```bash
./tools/build-tty2oled.sh <sketch dir> lolin32     # or esp32de / esp32s3
```

Installs arduino-cli, the ESP32 core and every library, then compiles. Produces
`build-out-<board>/MiSTer_SSD1322_USB.ino.merged.bin`, flashable as one file at
`0x0` — the merged image already carries the bootloader, partition table and
boot_app0 at their right offsets, which is what makes the S3's bootloader-at-`0x0`
versus classic-ESP32-at-`0x1000` difference a non-issue.

Build output is gitignored (`MiSTer_SSD1322_USB/build-out-*/`); those are ~1MB
binaries that do not belong in history.

The Arduino IDE works too — board profile `WEMOS LOLIN32`, and on an S3 set
**USB CDC On Boot: Disabled** or `Serial` leaves the UART bridge the MiSTer
talks to. The Flatpak IDE needs `flatpak override --user --device=all
cc.arduino.IDE2` before it can see a serial port at all, and the arduino-cli
route avoids the whole question.

## Deploying

Over SSH from the repo root — no Samba, no git on the MiSTer:

```bash
./tools/deploy-mister.sh                    # scripts, then restart the daemon
./tools/deploy-mister.sh --firmware --flash # also copy and flash the newest build
./tools/deploy-mister.sh --index            # also copy titleindex/*.idx
./tools/deploy-mister.sh --icons            # also copy pics_pri/ICON/*.gsc
```

`MISTER=root@192.168.1.50 ./tools/deploy-mister.sh` if mDNS does not resolve.
`ssh-copy-id root@MiSTer.local` once and it stops asking for a password.

The full loop is then: edit → `./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32`
→ `./tools/deploy-mister.sh --firmware --flash` → `ssh root@MiSTer.local 'tail -f /tmp/tty2oled'`.
Script-only changes need neither the build nor the flash.

`coretypes.ini` is copied only when the MiSTer has none, so edits to it
survive a deploy. `titleindex/` and `pics_pri/ICON/` move only when asked for
by flag, because both are large and neither changes with the scripts.

**`tty2oled-user.ini` is deliberately not in the deploy list.** It holds the
user's own settings and is sourced after `tty2oled-system.ini`, so copying the
repo's copy over it would wipe their configuration.

Firmware first, then scripts, when doing it by hand. New firmware with old
scripts behaves exactly like upstream; the reverse sends commands the firmware
cannot parse. (`deploy-mister.sh --firmware --flash` gets this order right.)

Debug with `debug="true"` in `tty2oled-user.ini`, log at `/tmp/tty2oled`.
`./tools/tty2oled-diag.sh` on the MiSTer dumps every state file with mtimes and
shows what `build_meta` made of them — run it right after loading a game. That
is what found the `FULLPATH` bug.

## Things that cost time, recorded so they do not again

- **`FULLPATH` is the containing folder, not the ROM path.** The file name is
  in `CURRENTPATH`. Reading `FULLPATH` titles every game after its folder.
- **Loading a ROM does not modify `/tmp/CORENAME`.** Watching that file alone
  can never notice a game change. The daemon watches the game-state files too.
- **MiSTer never clears `FULLPATH`/`FILESELECT`/`GAMEID`.** They outlive the
  core that wrote them, so a core started from the menu inherits the previous
  core's game. Trusted only when newer than `CORENAME`.
- **`bash`'s `-nt` compares whole seconds.** It reads `st_mtime`, not the
  nanoseconds, and MiSTer writes `CORENAME`, `CURRENTPATH`, `FULLPATH`,
  `FILESELECT` and `GAMEID` inside one second. Any guard phrased as "the
  selection must be newer than the core name" therefore answers *no* on every
  core that rewrites `CORENAME` as the ROM loads - GBA, Game Gear, Virtual
  Boy, NeoGeo, 32X, PC Engine CD - and those systems never showed a game at
  all. Phrase it the other way round (`CORENAME` strictly newer than the
  selection) so same-second writes count as current, and **latch** the
  decision: the guard runs only on a core change, and the polls that follow
  keep rejecting that exact selection (`META_STALE_REF`, content plus mtime)
  until a different one arrives. Re-running a timestamp test on every poll
  cannot tell leftover state from a freshly loaded game.
- **`GAMEID` needs a different freshness test from the rest.** Checking it
  against `CORENAME` is useless within one core: the *previous* game was also
  loaded after the core started, so its CRC passes. MiSTer writes the selection
  first and the CRC a few hundred ms later, which is long enough for the daemon
  to wake on the selection and display the previous game's year and publisher
  beside the new game's title - then replace them when the real CRC lands. The
  test that works is against the selection: a `GAMEID` older than
  `CURRENTPATH` belongs to the game before this one. Equal mtimes count as
  fresh, or good CRCs get thrown away.
- **The CRC misses the index on whole systems.** MiSTer and No-Intro do not
  always hash the same bytes - an iNES header counted by one and not the other
  is enough. `lookup_name` is the fallback: the index stores the cleaned title,
  `clean_romname` produces the same cleaned title from the filename, and
  `tests/test-index.sh` pins the two together so the fallback is an exact match
  rather than a fuzzy one. The TITLE INDEX block in `tty2oled-diag.sh` reports
  which path resolved the game.
- **`FILESELECT` is written while merely browsing**, value `active`, and
  `FULLPATH` is rewritten with it. Only `selected` counts, and identical
  metadata is not resent or the marquee restarts on every keypress.
- **`log_file_entry=1` is required in `MiSTer.ini`** and defaults to off.
  Without it MiSTer publishes nothing but the core name.
- **Core names are not index names.** `CORENAME` is whatever the core's
  confstr says, not what libretro calls the system: `MEGADRIVE` vs `GENESIS`,
  `GBC` vs the Game Boy core's combined index. `_index_alias` maps them and
  `_index_file` also matches case-insensitively; a core with no data at all
  falls through to the filename. Add an alias when a system shows only
  System/Region/Format.
- **The Neo Geo is arcade hardware as far as the data is concerned.** None of
  libretro's four metadata categories carry SNK Neo Geo - only Neo Geo Pocket
  - so its year and publisher come from the MAME set instead
  (`mamexml2index.awk`, games with `romof="neogeo"`). MAME descriptions carry
  both regional titles as "Aero Fighters 3 / Sonic Wings 3", and a romset may
  use either, so one record is emitted per alias.
- **The TurboGrafx core reports `TGFX16` for cartridges and CDs both**, so its
  index merges the cartridge dats with the redump PC Engine CD set. A core
  whose index needs several sources gets them in one file; `harvest` in the
  builder takes a system list plus the categories to pull for it.
- **Disc systems have no year or publisher upstream.** libretro's
  `metadat/{releaseyear,publisher,genre,developer}` cover 47 cartridge systems;
  PSX, Saturn, Sega CD, 3DO and PC Engine CD appear only under
  `metadat/redump`, which carries name, region and serial but none of the four.
  Those indexes are built from redump and keyed on the serial MiSTer writes to
  `GAMEID` (`lookup_serial`), giving a canonical title and region but empty
  Year and Company columns. The index line is eight fields now - the serial is
  the eighth - so every reader has to absorb it or it lands in Developer.
- **`classify_core` needs `STARTPATH`, and not every core publishes one.**
  Without it the folder guess cannot run and the core lands on `unknown`,
  which turns the metadata display off entirely - the artwork stays
  full-screen and no game is ever shown, whatever the selection says. The
  shipped `coretypes.ini` states the kind outright for every core we know of
  and is consulted first. `deploy-mister.sh` installs it only when the MiSTer
  has none, so edits survive.
- **ESP32 core 3.x removed the channel-based LEDC API.** Upstream's stable
  sketch does not build on current cores. A guarded macro block maps the old
  spelling onto `ledcAttach`/`ledcDetach`; 2.x is unaffected.
- **`S60tty2oled start` does not detach the daemon.** It backgrounds
  `tty2oled.sh` with the shell's own stdout, so over SSH the daemon holds the
  connection open and `ssh` never returns - the deploy script looked like it
  had finished printing but sat there, and `--flash` never ran. Any remote
  `S60tty2oled start|restart` needs `</dev/null >>/tmp/tty2oled-daemon.log 2>&1`.
- **A ROM set lives on the SD card or on USB, and the path does not say
  which.** MiSTer reports `FULLPATH` relative to the SD card - `games/GBA` on
  the SD, `../usb0/games/PSX` on USB - so resolving from `/media/fat` alone
  finds only one of them. `find_rompath` tries the same relative path under
  every root in `GAME_ROOTS` (SD, usb0-usb5, cifs). It is used to recover the
  extension MiSTer stripped, which is the only thing the daemon needs an
  actual file for; a selection that is not on disk still displays, just
  without a Format field. Quote the name everywhere: `After Burner 32X (JU)
  [!]` is a bracket expression if it reaches pathname expansion.
- **MiSTer strips the extension from `CURRENTPATH`** for any core that
  declares a single ROM extension. `3-D Tetris (USA)`, `Aladdin (USA,
  Europe)`, `Aero Fighters 3` are whole selections, not menu labels. A rule
  requiring a game to have an extension therefore rejected every load on Game
  Boy Advance, Virtual Boy, Game Gear, NeoGeo, 32X and PC Engine CD, while
  disc cores kept working because they accept several extensions and so keep
  the `.chd`. What actually separates a core launch from a game is
  `FULLPATH`: the core browser sets it to `_Console`, a game sets it to
  `games/GBA` or `../usb0/games/PSX`.
- **`FILESELECT` does not stay `selected`.** Opening and closing the OSD after
  a load rewrites it to `cancelled`, and browsing sets `active`, both with
  `CURRENTPATH` still naming the running game. Requiring `selected` on every
  poll made the card vanish as soon as the menu was touched, so the loaded
  selection is latched (`META_LAST_SELECTED`) until a different one is chosen.
- **A core can be launched through a `.mgl`**, not just a `.rbf` - the Game
  Gear entry is `_Console/Game Gear.mgl`, and that core reports `CORENAME`
  `GameGear` with `RBFNAME` `SMS`.
- **The selection is written ~3.3s before `CORENAME` is.** Launching a core
  from the menu writes `CURRENTPATH="Nintendo GameBoy"` (the menu *label*) and
  `FULLPATH="_Console"` at t=0, and `CORENAME` only at t=3.3. The daemon wakes
  on `FULLPATH`, finds the core name unchanged, and the freshness guard then
  compares the selection against the *previous* core's `CORENAME` - older
  still, so it passes. For those three seconds an empty core showed the split
  layout titled with its own menu label. The guard against leftover state
  cannot help here; what does is that a game is a file: `build_meta` requires
  the selection to have an extension, rejects `.rbf`/`.mra`, rejects anything
  matching `STARTPATH`, and rejects any selection whose `FULLPATH` folder
  starts with `_` (`_Console`, `_Computer`, ... are core folders).
- **Nothing draws the console layout on its own.** It is drawn by `CMDCOR` on
  a core change, by `CMDICON` when an icon arrives, or by a scroll tick that
  found something to animate. A *game* change is none of those - the core has
  not changed and almost nothing ships an icon - so short-titled games with few
  fields (`Airwolf`, two fields) never reached the screen while long-titled
  ones did, because only their marquee made the tick redraw. `meta_parse` now
  sets `metaNeedsDraw` for console kinds and the next `meta_tick` honours it.
- **Renaming a variable mid-function is how the staleness guard silently
  stopped working** — it kept testing the old name while the value had moved.
  Its test passed for an unrelated reason. Check that a test fails without its
  fix.

## The title index

MiSTer writes the CRC32 of the loaded ROM to `/tmp/GAMEID`. `lookup_crc` turns
that into a canonical title plus year, publisher, genre and developer - the
things a filename cannot tell you.

```bash
./tools/build-title-index.sh            # every mapped core, ~1.8MB, 24.5k games
./tools/build-title-index.sh NES SNES   # or just these
./tools/build-title-index.sh --list     # core name -> libretro system map
./tools/deploy-mister.sh --index
```

The source is [libretro-database](https://github.com/libretro/libretro-database)
`metadat/{releaseyear,publisher,genre,developer}` - CRC-keyed, offline, no API
key, no account. Downloads are cached in `.index-cache/`; `--force` refreshes.

One file per core name, `titleindex/<CORENAME>.idx`, each line
`CRC32|Title|Region|Year|Publisher|Genre|Developer|Serial`. Per-core rather than one
combined file because the MiSTer greps it on every game load: 200KB per core
instead of 1.8MB. A five-field line still parses, so the old single-file
`TITLE_INDEX` keeps working as a fallback when there is no per-core file.

`METADATA_FIELDS` in the ini picks which fields reach the screen and in what
order. The split layout has three rows and pages the rest every 2.5s, so the
first three listed are the ones seen at a glance. Arcade cores have their own
vocabulary and ignore the setting.

**The index titles must match `clean_romname`.** A CRC hit replaces the
filename-derived title, so if `index-emit.awk` cleaned names differently the
same game would be called two different things depending on whether its CRC
happened to be indexed. `tests/test-index.sh` runs both implementations over
the same names and compares.

**If a core is missing**, add it to `sysmap()` in `tools/build-title-index.sh`;
the core names there are what MiSTer writes to `/tmp/CORENAME`, which
`tty2oled-diag.sh` prints. Cores with no libretro data (`STUDIO2`) warn and
skip.

## Core names on screen

`names.txt` is MiSTer's own core-renaming file, `<key>:<display name>`, and the
menu shows those names - so a display reading `GBA` while the menu reads
`Nintendo GameBoy Advance` is showing the wrong one. `display_corename` looks
the running core up there and the `System` field and the no-game title use the
result; `META_ICON` deliberately does not, because icons are named by core.

The file is keyed on the core file and we hold the core name, so four keys are
tried: `CORENAME`, `RBFNAME`, the `STARTPATH` basename, and that basename with
its `_YYYYMMDD` build date removed. `GBA_20260530.rbf` is keyed `GBA`;
`Game Gear.mgl` is keyed `Game Gear`. Arcade is left alone - its "core name" is
an MRA setname, which is not a core file. `USE_NAMES_TXT="no"` turns it off.

## Artwork: icons and the boot screen

Both are `.gsc`: three header lines, then **one hex character per pixel**, row
major. So the panel has **16 grey levels**, `0` black to `f` white - no colour,
no alpha. Sizes are fixed and the firmware reads an exact byte count, so a
file one byte out is dropped as truncated.

| | size | bytes | where |
|---|---|---|---|
| console icon | 86x64 | 2752 | `pics_pri/ICON/<CORENAME>.gsc`, falling back to `pics/ICON/` |
| blank icon | 86x64 | 2752 | `png2gsc.py --blank --out ...`, all pixels `0` |
| boot screen | 256x64 | 8192 | the ESP's own flash, via `CMDWRBOOT` |

Draw at the target size in Aseprite or Pixelorama with a 16-step greyscale
palette, export PNG, then:

```bash
./tools/make-icon-stubs.sh                  # a blank .gsc per console core
./tools/make-icon-stubs.sh --with-png       # ...plus 86x64 PNGs to draw on

./tools/png2gsc.py --out pics_pri/ICON/NES.gsc nes.png
./tools/deploy-mister.sh --icons

./tools/png2gsc.py --boot splash.png                    # 256x64 boot screen
# copy splash.gsc to the MiSTer, then ON THE MISTER:
/media/fat/tty2oled/tty2oled-bootimg.sh set splash.gsc
/media/fat/tty2oled/tty2oled-bootimg.sh status
/media/fat/tty2oled/tty2oled-bootimg.sh clear
```

The icon filename is the **core name**, the one `CORENAME` reports and
`tty2oled-diag.sh` prints - `GBA.gsc`, `MegaDrive.gsc`, not `GameBoyAdvance`.
Icons need no firmware flash and no upload: the daemon reads the file off the
SD card and sends it with `CMDICON` on every core change.

`png2gsc.py` fits and centres on black by default rather than stretching;
`--stretch` fills, `--dither` helps photos and hurts flat pixel art,
`--invert` is for art drawn dark-on-light. Pillow is used if installed,
ImageMagick otherwise.

## Two switches that exist to stop your work being overwritten

Both live in `tty2oled-system.ini`, which **is** deployed, so the protection
ships rather than depending on a hand-edit:

- `SCRIPT_UPDATE="no"` — otherwise the updater pulls upstream's `tty2oled.sh`
  over this one.
- `TTY2OLED_UPDATE="no"` — otherwise `update_all` reflashes stock firmware
  from tty2tft.de over your build.

This one was wrong for a while: the note said to set `TTY2OLED_UPDATE` in
`tty2oled-user.ini`, which is the one file `deploy-mister.sh` deliberately
never copies. A switch that guards against an overwrite is worthless if it
only takes effect when the user remembers to set it by hand, so it is set in
`tty2oled-system.ini` now. A user ini can still override it, because it is
sourced second.

Check what is actually in force rather than what the repo says:

```bash
ssh root@MiSTer.local '. /media/fat/tty2oled/tty2oled-system.ini
  [ -r /media/fat/tty2oled/tty2oled-user.ini ] && . /media/fat/tty2oled/tty2oled-user.ini
  echo "TTY2OLED_UPDATE=${TTY2OLED_UPDATE} SCRIPT_UPDATE=${SCRIPT_UPDATE}"'
```

`REPOSITORY_URL` still points at upstream. Repoint it at the fork before
turning either back on.

## Not done yet

- **The icons are not drawn.** `pics_pri/ICON/` holds a blank, correctly named
  `.gsc` for all 47 console cores, so the panel is black until someone draws
  them. Names come from `coretypes.ini` and are never typed twice: add a core
  there and re-run `make-icon-stubs.sh`, which leaves existing files alone.
- **WonderSwan resolves per game, not per system.** The index is found and
  many titles hit; the misses are romsets whose filenames differ from
  No-Intro's, which the name fallback cannot bridge.
- **Neo Geo coverage is partial.** 203 sets from MAME 2003-Plus, matched by
  title, so a romset using a different spelling misses - `Bakatonosama
  Mahjong Manyuuki` against MAME's `Manyuki` is one letter out.
- **The LEDC shim is a clean upstream PR** on its own, independent of the
  metadata work.
- Arcade side was described as "close enough for now" — not yet specified.
