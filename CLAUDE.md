# tty2oled+ — working notes

## Releasing: every push is a version

Commit and push only when asked - but when asked, this is the whole ritual,
in order. The scripts and the firmware carry **one** version and move together
even when only one side changed, because a build where the two differ is a
build nobody can reason about.

**1. Decide the version.** `VERSION` holds the version of the *next* push. If
it has already been tagged, the work since then needs a new number; if not,
`VERSION` is already the one to push.

```bash
V="$(cat VERSION)"
git tag --list "v${V}"          # prints the tag => already pushed => bump
./tools/bump-version.sh         # 0.4.0b -> 0.4.1b, keeping the beta mark
```

`--set 0.5.0b` says it outright, and `--release` drops the `b` - **only when
the user asks for it**, never on your own judgement. The script writes the
number into `tty2oled-system.ini` and the sketch's `BuildVersion`, which are
the only two places that need it as a literal.

**2. Write the changelog.** A new `## <version> — <date>` section at the top of
`CHANGELOG.md`, describing what changed for someone running it, not what was
edited.

**3. Prove it.** Both, every time - the version bump alone changes the
firmware, so the binary is stale until it is rebuilt:

```bash
./tests/run-all.sh                                      # must be all green
./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32    # picks up BuildVersion
```

**4. Commit, tag, push.** The tag is what makes "which firmware is on the
display" answerable from the repo.

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

The tag push is also the release. CI (`.github/workflows/ci.yml`) runs every
suite and builds the firmware for all three boards on every push; on a `v*`
tag it then builds the title index, runs `tools/make-release.sh` and publishes
a GitHub release - which is what `update_tty2oledplus` on every MiSTer installs
from. Watch it through: `gh run watch`. It refuses a tag that is not `VERSION`
and a version with no `CHANGELOG.md` section, so steps 1 and 2 are enforced
there too. `./tools/make-release.sh --out /tmp/rel` builds the same release
locally, to look at before tagging.

**5. Flash, don't just deploy.** The firmware version moved with the scripts,
so a script-only deploy leaves the display a version behind and the daemon
will say so in `/tmp/tty2oled`:

```bash
./tools/deploy-mister.sh --firmware --flash
```

`./tools/bump-version.sh --check` at any time says whether the three copies
still agree; `tests/test-version.sh` fails the suite if they do not. The
reasoning behind all of it is under [Versioning](#versioning) below.

---

**tty2oled+** is a fork of
[venice1200/MiSTer_tty2oled](https://github.com/venice1200/MiSTer_tty2oled),
GPLv3 like upstream. Branch: `feature/game-metadata`, based on upstream `50c08ac`.

The install folder **is** the fork's own: `/media/fat/tty2oledplus`, where
upstream uses `/media/fat/tty2oled`, so neither updater can overwrite the
other's files. It **replaces** upstream, though, rather than sitting beside it:
the two would fight over one serial port, and upstream's boot hook would start
its daemon beside ours on every reboot. So while `/media/fat/tty2oled` holds
upstream's `tty2oled.sh` or `S60tty2oled`, three things refuse and say how to
remove it - the installer (before it changes anything), the deploy
(before copying anything) and `S60tty2oled start` (into `DAEMONLOG` as well,
since nobody reads stdout at boot). `stop` and `status` still work. The README's
move-the-folder migration satisfies all three.

Everything else deliberately keeps the upstream spelling: the script and ini
filenames, the `S60tty2oled` init script, the NVS namespace and the serial
protocol. Renaming those buys nothing and breaks every set of instructions on
the internet, every thread about the thing, and any muscle memory the user
has.

`TTY2OLED_PATH` in `tty2oled-system.ini` is the one definition; everything
inside the ini derives from it. Two scripts cannot use it and name the folder
outright, because they run *before* any ini is read: `S60tty2oled` and
`tty2oled-read.sh`. `deploy-mister.sh` ships both for exactly that reason - a
stock copy left in a moved install goes looking for `/media/fat/tty2oled` and
finds nothing.

Upstream shows one picture per **core**. This fork shows the **game**: arcade
cores alternate artwork with an info card, console cores get a split layout
with scrolling text and an icon panel.

## Layout of the change

| Path | What it is |
|---|---|
| `tty2oled-meta.sh` | New. Turns MiSTer's `/tmp` state files into display metadata. |
| `tty2oled.sh` | Daemon. Sends `CMDMETA`/`CMDICON`, watches game state, not just the core. |
| `tty2oled-system.ini` | New settings (see below). |
| `VERSION`, `CHANGELOG.md` | One version for scripts and firmware; an entry per release. |
| `tools/bump-version.sh` | Moves that number, and `--check`s that every copy agrees. |
| `coretypes.ini` | New. `corename=console\|computer\|arcade`, consulted before folder guessing. |
| `MiSTer_SSD1322_USB/metadisplay.h` | New. Arcade card + console split layout. |
| `MiSTer_SSD1322_USB/bootscreen.h` | New. LittleFS-backed custom boot image, and the reserved band below it. |
| `MiSTer_SSD1322_USB/bootlogo.h` | New. The built-in 256x54 boot picture, generated. |
| `MiSTer_SSD1322_USB/bootlogo.png` | New. The art it is generated from. |
| `MiSTer_SSD1322_USB/contrastfade.h` | New. Every contrast change fades; base level times the transition veil. |
| `MiSTer_SSD1322_USB/fadetransition.h` | New. `TRANSITION=-2`: palette-and-contrast fade out, black, fade in. |
| `MiSTer_SSD1322_USB/bootoutro.h` | New. The boot screen as the menu's picture, and the power-on outro. |
| `MiSTer_SSD1322_USB/busybar.h` | New. The boot sweep as a busy bar in the band, for update_all's downloader. |
| `MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino` | Includes the two headers; LEDC shim for ESP32 core 3.x. |
| `tests/` | 1248 checks, no hardware needed. |
| `tools/build-title-index.sh` | Builds the CRC32 title index from libretro-database. Workstation. |
| `tools/mamexml2index.awk` | Year/publisher for arcade-lineage consoles out of a MAME XML. |
| `tools/png2gsc.py` | PNG -> the 4bpp `.gsc` the display wants. Workstation. |
| `pics_pri/ICON/` | The icons themselves, 27 drawn; same path as on the MiSTer. |
| `pics/` | The core artwork pack, 2322 files. Upstream's, vendored. |
| `tools/tty2oled-bootimg.sh` | Installs/clears the stored boot screen. **On the MiSTer**. |
| `tools/dat2index.awk`, `tools/index-emit.awk` | The DAT parser and index emitter it drives. |
| `tools/build-tty2oled.sh` | Builds the firmware with arduino-cli. Runs on the workstation. |
| `tools/deploy-mister.sh` | Pushes this working copy to the MiSTer over SSH. Workstation. |
| `tools/tty2oled-boothook.sh` | Adds the boot hook to `user-startup.sh`. Fed to the MiSTer on stdin by the deploy. |
| `tools/manifest.sh` | What an install is made of. Read by the deploy and the release, so they agree. |
| `tools/make-release.sh` | Builds the release assets into `dist/`. CI runs it on a tag; so can you. |
| `tools/TTY2OLEDplus_Installer.sh` | The starter users drop in `/media/fat/Scripts`: fetches the latest installer, checks it, runs it, removes itself. **On the MiSTer**. |
| `tools/update_tty2oledplus.sh` | Installs/updates from a GitHub release. **On the MiSTer**; `update_tty2oledplus` in its Scripts menu. |
| `.github/workflows/ci.yml` | Tests and firmware on every push; the release on a `v*` tag. |
| `tools/flash-mister.sh` | Flashes the firmware. Runs **on the MiSTer**. |
| `tools/fw-segments.py` | Which parts of a merged image to write, so the boot image and settings survive. **On the MiSTer**. |
| `tools/tty2oled-diag.sh` | Dumps MiSTer's state files and what they parse to. **On the MiSTer**. |
| `tools/tty2oled-capture.sh` | Records every state change while you load games. **On the MiSTer**. |

## What ends up on screen

`build_meta` in `tty2oled-meta.sh` turns MiSTer's `/tmp` files into a kind, a
title and an ordered field list; `sendmeta` puts it on the wire; the firmware
composes it.

| kind | layout |
|---|---|
| `arcade` | full-screen artwork, then each page of the info card in turn, then the artwork again - one step every `METADATA_INTERVAL`s |
| `console` | split: "Now playing", a rule, the title, paged fields on the left; an 86x64 icon on the right |
| `computer` | untouched - full-screen artwork, as upstream |
| `unknown` | as `computer`; metadata off |

**update_all overrides all of it.** While a process whose command line names
`update_all` exists, the daemon sends `CMDMETAOFF` and `update_all.gsc` (exact
name; `pics_pri`, then `pics/GSC`, then `.xbm`), or the bare name as text when
there is none, and does nothing else until it exits - then clears `oldcore`
and `META_WIRE_LAST` so the core and game go out again in full. It has no
state file and does not touch `CORENAME` (MiSTerZine runs it from inside a
core), so the process is the only signal: `updateall_pass` greps
`/proc/*/cmdline` every `UPDATE_ALL_POLL` seconds, and the upstream path's
`inotifywait` gained a timeout for it. `UPDATE_ALL_SCREEN="no"` turns it off.

The picture is cropped to 54 rows (the daemon sends 6912 bytes of it and 1280
of black), which frees the boot band for the **busy bar**: `CMDBUSY,1` while
update_all's downloader runs, `CMDBUSY,0` after. update_all runs the
downloader from `/tmp/ua_downloader_{bin,latest.zip,dd.pyz}`, so that is what
`downloader_running` matches - except with `--list-dbs`, a query the settings
screen makes, which is not an update. The bar is `busybar.h`, the boot sweep
at full width ticked from `loop()`; it waits out a Fade, holds the screensaver
off, and stops dead on any command `boot_quietCommand` does not list.

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
That table is the console vocabulary. Arcade has its own, all of it out of
the `.mra` sitting in `STARTPATH`:

| field | tag |
|---|---|
| title | `<name>` |
| Year, Manufacturer, Region, Platform, Version | the tag of that name |
| Genre | `<catver>` - "Platform / Run Jump" - falling back to `<category>` |
| Players | `<players>` |
| Controls | `<joystick>`, or a button count when the board has no stick |
| Buttons | the first `count` of `<buttons names="...">`; the rest are the cabinet's own |
| Orientation | `<rotation>`, capitalised |
| Set, Core, MAME | `<setname>`, `<rbf>`, `<mameversion>` |
| Author | the `author` attribute of `<about>` |

Two ini lists pick and order them, because the values are two shapes:
`ARCADE_FIELDS` for the short ones, which pair up two to a row, and
`ARCADE_FIELDS_WIDE` for the ones that need a row to themselves.
`ARCADE_PINNED` is the grid row repeated above the wide pages, and must be the
first names in `ARCADE_FIELDS` - it is the top row of the grid, and a row
cannot start halfway down the list. Genre, Platform and Version are known but
listed in neither by default.

The labels on the card are abbreviated - `Manufctr`, `Orient` - because half a
row is about fifteen characters. The ini names are not: `_arcade_display_label`
maps one to the other, so `ARCADE_FIELDS` stays readable.

**Nothing built for a card may contain a comma.** `metasanitize` replaces one
with a space, because the optional pinned count in `CMDMETA` is recognised by
being digits followed by a comma. `Attack/Jump`, not `Attack, Jump`.

`parse_mra` reads the lot in **one** `awk` pass rather than a `sed` per tag:
seventeen tags at three processes each is most of a second on a DE10-Nano,
and it lands on every arcade core change. The same pass pulls the two
attributes - `<buttons names=... count=...>` and `<about author=...>` - by
locating them in a lowercased copy of the line, which is safe because
`tolower` cannot change a length.

## Console layout, row by row

64 rows is the whole budget, so every gap is a named constant in
`metadisplay.h` and these are the numbers to tune if it looks wrong on glass.
Each `CON_GAP_*` is a count of **blank rows**, and each following element's
top row is one past the last blank one - that `+1` is easy to leave out, and
leaving it out silently closes the gap rather than breaking anything.

```
row  0..11  "Now playing"        baseline CON_HEADER_Y   pips at the right
row 12      blank                         CON_GAP_HEADER
row 13      rule                          CON_RULE_Y
row 14      blank                         CON_GAP_RULE
row 15      blank                         CON_GAP_RULE is 2
row 16..30  game title           baseline CON_TITLE_Y
row 31      blank                         CON_GAP_TITLE
row 32..38  field 0              baseline CON_FIELD_Y0   pinned
row 40..46  field 1                       + CON_FIELD_PITCH  pinned
row 48..54  field 2                                      paged
row 56..62  field 3                                      paged
```

Four field rows, where there used to be three. Two came free: the page
indicator moved up beside the header, which released the bottom of the panel,
and `CON_FIELD_PITCH` dropped from 9 to 8 - a 7px font with one blank row
between, which pays for the gap under the title.

`tests/firmware/test_meta_layout.cpp` derives each gap back out of the
constants and compares it to the `CON_GAP_*` it came from, so changing one
number cannot quietly overlap two elements. It caught exactly that while this
was written: `CON_TITLE_Y` was missing its `+1` and the title sat directly on
the rule.

## Field alignment

Labels are drawn at the text column's left edge; values share a column of
their own, `meta_valueOffset()` - the widest label across **every** field,
plus 5. Measured across all of them rather than the visible page, so the
column does not shift when the pager turns over, and capped at half the text
width so one long label cannot push the values off screen. A label wider than
the column still gets its value placed after itself rather than drawn on top.

Values used to be packed immediately after each label, so every row started
its value wherever its own label ended - `Year` is shorter than `System`, so
their values sat in different places and the rows read as misaligned. The
labels were always fine; it was only ever the values.

## Arcade card, row by row

Same convention as the console layout: each `CARD_GAP_*` is a count of blank
rows and the next element's top row is one past the last of them.

```
row  0..12  title                baseline CARD_TITLE_Y   pips at the right
row 13..15  blank                         CARD_GAP_TITLE
row 16      rule                          CARD_RULE_Y
row 17..19  blank                         CARD_GAP_RULE
row 20..26  row 0                baseline CARD_FIELD_Y0
row 31..37  row 1                         + CARD_FIELD_PITCH is 11
row 42..48  row 2
row 53..59  row 3
```

Four rows, and a row carries either two fields or one - which it is depends on
the page, not the row:

```
page 0   Year     1993          Manufctr  Midway
         Region   World         Orient    Horizontal
         Core     blahmid_tunit Author    rejectedcoins
         Set      nbajam        MAME      0289

page 1   Year     1993          Manufctr  Midway
         Players  4
         Controls 8-way
         Buttons  Turbo/Shoot / Block/Pass / Steal
```

The grid pages pair the leading `metaCompact` fields two to a row, reading
**across**; the wide pages give a row each to the rest, under a repeat of the
pinned grid row. `meta_cardColX` is the only thing that knows where a column
starts, and the value offset is measured against `CARD_COL_W` so one shared
column serves the paired rows and the full-width ones alike - `8-way` starts
at the same x as `1993`.

`meta_cardGridPages`/`meta_cardWideSlots`/`meta_cardWidePages`/
`meta_cardPageCount` are the only things that work the paging out, so the
renderer and the alternation tick cannot disagree about which page is next -
the console pair made exactly that mistake once. With nothing paired and
nothing pinned it degrades to one field per row, paged, which is what an older
script that sends no counts gets.

The alternation runs **artwork, page 0, page 1, artwork**: `meta_tick` moves to
the next page while the card is up and only returns to the artwork after the
last one. Each step is a transition effect like any other.

Arcade names run long - `Teenage Mutant Ninja Turtles (World 4 Players)` is
wider than the panel at 12px - so a title that will not fit drops to
`CARD_TITLE_ALT` before it is allowed to be truncated. There is no marquee
here: the card is snapshotted into `metaBin` and handed to the transition
effects, so it is a still image by construction.

## Pinned fields

The first `metaPinned` fields are drawn on every page; the rest cycle through
the rows left over. With four rows and two pinned, System and Year stay put
while Genre/Region and Format take turns below them. On the arcade card the
same count means the grid's top row, which is already on the grid page and is
repeated above each wide page.

The script decides which, the firmware only counts: `meta_addfields_ordered`
emits the pinned names first, in `METADATA_PINNED` order, and sends the count
as a fourth header field in `CMDMETA`. So the firmware never needs to know a
field's name, and re-ordering is a script-side change.

The card counts the same way, and takes a second number with it: `compact`,
how many leading fields it pairs two to a row. Both counts are optional and
safely so: `metasanitize` strips commas from the title and from every value,
so everything after the header is comma-free, and a comma-terminated run of
digits is therefore unambiguous. A script that sends neither, or only the
first, still works - the firmware reads what is there and the title starts
where the counts stop. A title starting with digits (`1943 The Battle of
Midway`) is not mistaken for one, because it is not followed by a comma.

`meta_pinnedRows`/`meta_pageSlots`/`meta_pageCount` are the only things that
work this out, so the renderer and the scroll tick cannot disagree about how
many pages exist - they did once, over the marquee window, and the result was
a title that scrolled without ever overflowing. Pinning is capped at one below
the row count so there is always something left to page with.

`META_PINNED_COUNT` and `META_COMPACT_COUNT` are reset in `meta_reset` as well
as in the emitter that uses them. Each layout has its own emitter and neither
sets the other's count, so without the reset a console game would inherit the
previous arcade card's pairing and be drawn half a row wide.

## Dimming and side swapping

Both run on the firmware's own clock, so the daemon sends them once at startup
(`senddim`, `sendflip`) rather than driving them.

**Every contrast change fades** (`contrastfade.h`). Nothing but that header
calls `oled.setContrast()`: `CMDCON`, dimming, waking, the screensaver and the
picture paths all ask `contrast_fadeTo()`, and `contrast_tick()` in `loop()`
moves the panel there over `CONTRAST_FADE_MS`. A fade always starts from
where the panel is, so a new target mid-fade turns around instead of
snapping back; a target it is already heading for is not a new fade, because
the picture paths re-assert the contrast on every draw and restarting the
clock each time would stall it. `boot_waitOrCommand` ticks it too, since
`loop()` is not running during the boot screen - which is how the power-on
fade-in works: `setup()` blacks the panel (veil down, base at 255), the
power-on screen composes its first frame into the framebuffer, and hands it
to `transition_fadeIn(BOOT_FADE_MS)` - the same fade-in a Fade transition
does, palette steps and contrast together - instead of sending it to the
panel. Sending it first put it up undarkened at contrast 0, plainly visible.
`BOOT_FADE_MS` (0.8s, fixed) must fit inside the 1s hold: the palette steps
redraw the whole frame from a copy and would wipe out the sweep's bar if they
overlapped it, and `test_meta_layout` checks the two constants. If the daemon
speaks first the fade finishes in `loop()`, and its `CMDCON` moves the base
level under the veil without disturbing it. Re-shows (`CMDSORG`, the tilt
sensor) do not fade in; the panel is already lit and blacking it would
flicker.

**The panel's level is two faders multiplied**: the base (`CONTRAST`, dimming,
the screensaver) and the *veil*, which only the Fade transition and the boot fade-in move. Kept
apart so neither knows about the other - a transition on a dimmed panel goes
80 -> 0 -> 80, and a dim that starts mid-transition lands correctly once the
veil lifts. With the veil at 255 the panel gets exactly the base level.

**`TRANSITION=-2` is a fade, not a wipe** (`fadetransition.h`): the old picture
fades out, the panel is cleared and held black for `TRANSITION_BLANK_MS`, the
new one is drawn plainly (effect 0) and fades in, `TRANSITION_FADE_MS` each
way. **Contrast alone does not reach black** - an SSD1322 at contrast 0 is dim,
not dark, and the first version of this left the picture plainly visible at
the bottom of the fade. So the picture fades too: sixteen palette steps, each
taking every pixel one grey level down (floored at 0), one per sixteenth of
the fade time, so they start and end with the contrast. The fade-in mirrors
it. The steps are computed from `fadeBin`, an 8KB copy of the picture being
faded (ESP32 only; the ESP8266 keeps the contrast-only fade), never by
darkening the framebuffer in place - so anything drawn into the framebuffer
meanwhile is overwritten by the next step. `meta_showCard` is the one caller
that renders *before* asking, so it calls `transition_prepare()` first to take
the old picture while it is still there. All fade times, contrast and
transition alike, max out at 4000ms and default to 800ms.

**The new picture is rendered, not drawn, before it fades in.** The plain draw
(effect 0) ends in `oled.display()`, so using it put the new picture on the
panel undarkened for one frame transfer, at contrast 0 - which on this panel
is far from dark - and it flashed just before every fade-in.
`oled_renderlogo()` fills the framebuffer and shows nothing; the first frame
the panel gets is the fully darkened one. The fake panel in the tests records
the brightest grey it was ever sent (`shownPeak`), which is how a frame that
should never have been shown is caught.

**`CONTRAST` and the palette are independent.** The veil scales the base
level, so `CONTRAST=120` fades 120 -> 0 -> 120; the palette steps always walk
all sixteen grey levels, unscaled. `test_meta_layout` holds both. It is a state machine ticked from `loop()`, never a blocking loop like
the wipes: five seconds at the defaults of not reading the serial port would
overflow its 256-byte buffer with the metadata and icon that follow every
picture. Because the draw happens seconds after the request, `srcBin` and
`actPicType` are captured when it is asked for - the card alternation puts
both back the moment it returns. A request while fading out or black just
replaces the picture waiting to be shown; one while fading in turns around
from where it got to; any other effect cancels it and draws at once.
`oled_transition()` is the one entry point for every transition: `-2` fades,
anything else negative is a random wipe, `0`..`maxEffect` is that wipe. The
parsers used to clamp everything below `-1` up to `-1`, so `-2` has to be let
through them explicitly.

**The card alternation uses `TRANSITION`.** It used to pass `-1` - random -
whatever the ini said, so a `TRANSITION` of 5 wiped the artwork in with 5 and
every card page with a lottery. It passes `tEffect`, the value the last
`CMDCOR` carried.

The ini lists every effect by number and name, so nobody has to read the
sketch. `test-wire.sh` checks the list against the `case` labels of
`oled_drawlogo` and `maxEffect`, so an effect added to one and not the other
fails the suite.

**Dimming** is not upstream's screensaver - that moves a logo around to shift
which pixels are lit, and the two compose. This only lowers contrast after
`DIM_AFTER` seconds with nothing drawn, and restores it on the next draw.
The dim level is `DIM_CONTRAST`, an absolute 0..255 like `CONTRAST` and
capped at the waking level. It used to be `DIM_PERCENT`, a share of the waking
level, so the same number meant a different brightness for every `CONTRAST`;
the daemon now says so in its log if a user ini still sets the old name.
Going dim fades over `DIM_FADE_MS` (0..10000, default 6s) - burn-in
protection nobody should notice happening - while waking uses
`CONTRAST_FADE_MS` like any other change, because something new has arrived.
`TRANSITION` ships as `-2`, the Fade.
`meta_activity()` is the wake, and it is called **only** from the command
dispatcher - a command arriving is new content, and that is what "screen
update" means here.

It is deliberately *not* called from the draw helpers, which is where it
started. The marquee redraws every 40ms and the field pager every 2.5s, both
through `meta_showConsole`, so counting any draw as activity meant a console
game with a long title or a second page never went idle and the panel never
dimmed at all. The animation carries on quite happily at reduced brightness.
A fade is only started on the transitions, not every tick, and during one the
panel is written only when the level actually changes.

**Side swapping** mirrors the console layout every `FLIP_MINUTES` so no region
holds the same lit pixels indefinitely. `meta_iconX`/`meta_textX`/`meta_textW`
are the only things that know which side is which. The icon x must stay
**even**: the framebuffer is 4bpp, so a pixel column maps to a whole byte only
at even x, and `meta_blitIcon` copies whole bytes. 0 and 170 both are.

## The wire protocol this fork adds

Upstream's commands are unchanged. These are additions, all ESP32-only:

| command | payload |
|---|---|
| `CMDMETA,<kind>,<interval>[,<pinned>[,<compact>]],<title>[\|<label>=<value>]...` | one line; both counts optional, in order |
| `CMDMETAOFF` | none - leave metadata mode, back to plain artwork |
| `CMDICON` | followed by exactly 2752 raw bytes (86x64, 4bpp) |
| `CMDSHMETA` | none - force the metadata view now |
| `CMDDIM,<seconds>,<contrast>,<wake>[,<dim fade ms>]` | one line; 0 seconds disables; contrast 0..255, capped at the wake level; wake -1 means CONTRAST; going dim takes the fade time, 0..10000, default 6000 - waking takes `CMDFADE`'s |
| `CMDFADE,<ms>` | one line; how long every contrast change fades, 0..4000, 0 jumps. Sent before the first `CMDCON` |
| `CMDBOOTPIC,<core>,<effect>` | one line, no payload; show the boot image as the core's picture. Sent for MENU when `BOOTSCREEN_AS_MENU` is on. Nothing transitions if the power-on screen is still up |
| `CMDTFADE,<fade ms>,<blank ms>` | one line; the Fade transition's timings, 0..4000 each. Sent before the first picture. `CMDCOR`'s effect may now be `-2` |
| `CMDBUSY,<0\|1>` | one line; 1 runs the boot sweep in the bottom band, 0 lets it finish its cycle and stop. Any drawing command stops it at once |
| `CMDFLIP,<seconds>` | one line; 0 disables and returns to the normal side |
| `CMDWRBOOT` | followed by exactly 6912 raw bytes (256x54, 4bpp) |
| `CMDCLRBOOT` | none - forget the stored boot image |
| `CMDBOOTINF` | none - replies with the boot image status |

`,` `|` and `=` are the separators, so `metasanitize` strips them from every
value along with anything non-printable. A short `CMDICON`/`CMDWRBOOT`
transfer is dropped rather than half-applied.

## Running the tests

```bash
./tests/run-all.sh
```

Eleven suites: metadata extraction, wire protocol, title index, versioning,
daemon lifecycle, deploy, png2gsc, installer, flashing, firmware parser,
firmware layout. CI runs
all of them on every push (`.github/workflows/ci.yml`), with inotify-tools and
ImageMagick installed so nothing is skipped there.

The installer suite builds a real release from the working copy - small index,
small artwork pack, stand-in firmware images - serves it over `file://` laid
out as GitHub serves releases, and runs the installer against a fake
`/media/fat`. Only the init script and `flash-mister.sh` are stand-ins. Each of
its safety properties was checked by breaking the installer on purpose: skip the
checksum, overwrite `tty2oled-user.ini`, miss upstream's daemon, read the
display's first line as its answer - the suite fails on every one.

The deploy suite runs `deploy-mister.sh` in full from a scratch copy of the
repository, with `ssh` and `scp` replaced by fakes that record every call - so
it checks the order, the options and what would reach the MiSTer, and nothing
leaves the machine. The scratch copy is so its fake `merged.bin` can never be
the newest build in the real working copy, which is the one `--flash` picks.
The boot hook is sourced as a library (`BOOTHOOK_LIB=yes`) and run against
fixture copies of `user-startup.sh`.

The png2gsc suite runs the tool as a command, on both backends where both are
installed, and reads what it writes through the daemon's own
`tail -n +4 | xxd -r -p` rather than a parser of its own. It also regenerates
`bootlogo.h` with the command recorded in its header and fails if the result
differs - so a change to the converter that alters the built-in picture is
caught, and so is a hand edit to a file that says "do not edit".

The daemon suite covers the loop
itself rather than what it says - the display being unplugged under it,
`/tmp/CORENAME` not existing yet, and which process the init script starts and
stops. `/dev/null` is a character device, so it stands in for a display that is
present, and a path that does not exist for one that is not. One assertion
needs a real `inotifywait` and reports itself skipped when the workstation has
none. The firmware suites compile the display headers against stubs under
`-Wall -Wextra -Werror` with ASan/UBSan and a real 8192-byte framebuffer — no
Arduino toolchain, no ESP32, no serial port.

**Every bug fixed here reached hardware first.** When fixing another one, add
the test and confirm it fails against the unfixed code before committing.

## Hardware this was tested on

Wemos LOLIN32 (classic ESP32), USB mode, SSD1322 256x64. Ask the display what
it is rather than trusting the installer menu — "DevKit" appears twice there,
and a generic ESP32 DevKit V4 is the `lolin32` profile, not `esp32de`:

```bash
. /media/fat/tty2oledplus/tty2oled-system.ini
stty -F ${TTYDEV} ${BAUDRATE} ${TTYPARAM}
echo "CMDHWINF" > ${TTYDEV}; read -t5 R < ${TTYDEV}; echo "$R"   # HWLOLIN32;0.4.0b;  <- board;version
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
./tools/deploy-mister.sh --pics             # also copy the pics/ artwork pack
./tools/deploy-mister.sh --all              # index, icons and artwork together
./tools/deploy-mister.sh --dry-run --all    # check and list, touch nothing
```

`MISTER=root@192.168.1.50 ./tools/deploy-mister.sh` if mDNS does not resolve.
`ssh-copy-id root@MiSTer.local` once and it stops asking for a password; until
then it asks once per deploy, not once per step, because every `ssh` and `scp`
rides on one multiplexed connection (`ControlMaster`, socket in a `mktemp -d`
removed on exit).

It runs from any directory - it `cd`s to the repository from its own path - and
**checks everything local before touching the MiSTer**: `ssh`/`scp` (and `tar`
for `--pics`) installed, every file it ships present, and the build, index,
icons or artwork each flag needs. Then one `ssh ... true` to prove the host is
reachable, with the `MISTER=` and `ssh-copy-id` hints if not. Only then does
anything get copied, so a deploy either fails before it starts or runs through.
It did not use to: `--index` with no index built copied the scripts first, then
exited before the restart, leaving the old daemon running over new files.

It asks the init script whether the daemon came up (`S60tty2oled status`)
rather than reading a pid file itself, so the pid file is known to one script.

The full loop is then: edit → `./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32`
→ `./tools/deploy-mister.sh --firmware --flash` → `ssh root@MiSTer.local 'tail -f /tmp/tty2oled'`.
Script-only changes need neither the build nor the flash.

The folder is created if it is not there, so a first deploy to a MiSTer that
has never had this fork works. What it does *not* bring is upstream's artwork
pack or its updaters, so the way to move an existing install is to `mv` the old
folder to the new name and deploy over it - the README has the three commands,
including the `sed` over `/media/fat/linux/user-startup.sh`, which still points
at the old `S60tty2oled`.

`coretypes.ini` is copied only when the MiSTer has none, so edits to it
survive a deploy. `titleindex/`, `pics_pri/ICON/` and `pics/` move only when
asked for by flag, because all three are large and none of them changes with
the scripts.

`pics/` is **upstream's core artwork pack, vendored into this repo** - 2322
files, what `CMDCOR` actually puts on screen. 87MB on disk but only ~12MB
packed, because a `.gsc`/`.xbm` is `0X00,`-style hex text and compresses about
sevenfold. It is vendored rather than fetched so a fresh MiSTer needs nothing
but this repo; upstream's picture repo and its updaters are not part of the
fork, for the reasons under [Staying out of upstream's way](#staying-out-of-upstreams-way).

`--pics` sends it as one `tar` stream rather than 2322 `scp` calls. `/media/fat`
is mounted `sync,dirsync`, so every separate file write waits on the SD card -
the difference is minutes against seconds. `du` on the MiSTer reports the pack
as 292MB rather than 87MB, which is exFAT cluster slack over 2322 small files,
not a different set of files.

All five subfolders are live. `tty2oled.sh` searches
`gsc_us xbm_us gsc xbm xbm_text` in order, so `XBM` is the fallback for a core
with no `GSC` - shipping only `GSC` would leave those cores blank.

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
- **A daemon started over `ssh -t` died when the connection closed.**
  `S60tty2oled start` used a bare `&`, which left the daemon in the caller's
  process group and on its terminal. `deploy-mister.sh --flash` runs
  `flash-mister.sh` over `ssh -t` so esptool's progress shows, and
  `flash-mister.sh` restarts the daemon on its way out - so the kernel's SIGHUP
  to the terminal's foreground group killed it the moment ssh disconnected. The
  display, reset by the flash, sat in its boot animation waiting for a daemon
  that no longer existed; a cold reboot "fixed" it, because the boot hook has
  no terminal. Found on hardware: plain `ssh` keeps the daemon, `ssh -tt` kills
  it, every time. The same missing detach was why `ssh host S60tty2oled start`
  never returned - the daemon held ssh's stdout - which callers had each worked
  around with `</dev/null >>log`. `start` now runs the daemon under `setsid`,
  with its own stdio (`DAEMONLOG`), and ignores SIGHUP around the fork: between
  fork and `setsid` the child is still in the caller's group, and the test
  that plays the hangup (`kill -HUP 0` from the starter's group) caught exactly
  that window. `setsid` execs rather than forks when its caller is not a group
  leader, so `$!` stays the daemon's pid.
- **A merged firmware image is the whole chip, and writing it erases the
  data partitions.** It is 4MB of a 4MB flash, and `nvs` (Preferences) and
  `spiffs` (the LittleFS the boot image lives on) are `0xFF` in it because the
  build has nothing for them. Written at `0x0` it wiped both, so every flash
  forgot the stored boot screen. `fw-segments.py` plans the write instead:
  the bootloader and partition table, then each partition that has data,
  trimmed to where the data ends - 520KB rather than 4MB. Only when the
  display's own partition table, read first with `esptool read_flash 0x8000
  0xC00`, matches the image's; any doubt - unreadable table, moved
  partitions, data outside them - and it writes the whole image as before.
  `tests/test-flash.sh` applies the plan to a simulated chip and compares.
- **CI builds three boards against today's libraries; a local build is one
  board against whatever was installed.** `v0.4.0b` was tagged with the
  esp32de and esp32s3 builds broken: Adafruit GFX 1.12.6 made upstream's
  `round(<int>)` in the GSC path an ambiguous overload, and the workstation
  still had 1.12.3 and only ever built lolin32. The release job never ran, so
  nothing was published, but the tag was spent - hence 0.4.1b. Before tagging,
  `arduino-cli lib upgrade` and build all three boards, **lolin32 last**:
  `deploy-mister.sh --firmware` takes the newest `merged.bin` in any
  `build-out-*`, so an S3 image built after it is what gets flashed.
- **GitHub release asset names are case-insensitive.** `v0.4.1b`'s release
  job created the release, then failed uploading `tty2oledplus_installer.sh`
  beside `TTY2OLEDplus_Installer.sh` with "ReleaseAsset.name already exists",
  and `gh` deleted the half-made release - another tag spent. The installer is
  `update_tty2oledplus.sh` now, the name it already had in the Scripts menu,
  and `test-installer.sh` fails on any two assets that differ only in case.
  The same pair would also have collided in a clone on macOS or Windows.
- **A theory that fits is not a cause.** The flash hang first looked like the
  firmware formatting LittleFS after the erase and missing the daemon's
  handshake meanwhile. Reproducing it - erase the region, reset, start the
  daemon - showed the display answering fine. The difference between the
  reproduction and the real run was `ssh -t`, and that was it.
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
- **Upstream's updater wired the boot line by grepping for the string
  `tty2oled`**, not for the path, so on a MiSTer that has ever had upstream
  installed it saw the old line, decided the work was done, and never added
  ours. `deploy-mister.sh` does this now and matches on the full path.
  `/media/fat/linux/user-startup.sh` is the one file outside the install
  folder that names it.
- **The panel boots at contrast 5 unless something says otherwise.** That is
  upstream's initial value for `contrast`, and it is almost off. Everything on
  the boot screen - picture, sweep, version - happens before the daemon's
  `CMDCON` can arrive, so the one stretch of the session nobody could read was
  the one that says which firmware is running. It starts at 255 now; `CMDCON`
  still replaces it with the user's stored level the moment the daemon
  connects.
- **`loop()` does not run until `setup()` returns, and the start screen was
  inside `setup()`.** The firmware ignored the serial port for the length of
  the whole boot animation - 2s hold plus 8 sweep cycles plus 0.5s, near enough
  eight seconds - while the daemon, which never waited for `ttyrdy;` and has no
  reason to, sent its entire startup handshake into a chip that was not
  listening. The animation exists to fill the wait, so the wait has to be what
  ends it: `boot_waitOrCommand` returns on `Serial.available()`, and `ttyrdy;`
  now goes out *before* the screen so it means "I will answer you" rather than
  "the animation finished". A `CMDCOR` landing in that window was worse than
  slow: 8192 bytes into a 256-byte RX ring is a short `readBytes`, which draws
  the transfer-error bitmap.
- **Startup order is boot time.** The daemon used to run `checkversion`, the
  clock, the screensaver, the dimming and the side-swap settings in front of
  the first picture. None of them change what that picture looks like, and
  `checkversion` blocks for up to two seconds when the display cannot answer
  `CMDHWINF` yet. Contrast and rotation are the only two the picture depends on
  - the rest is `deferred_setup`, run once the artwork is already on the panel.
- **`WAITSECS` is two different waits.** After a picture header it is a
  transfer sync; after a single-line command it is just a pause, and the
  firmware acks those after `cDelay` = 15ms. `CMDWAITSECS` (0.05) is the second
  one, which took about a second out of the startup handshake. `cmdwait` falls
  back to `WAITSECS`, so an ini that predates the setting still works.
- **A loop branch with nothing in it is a loop that eats a core.** Every branch
  of the daemon's main loop ends in something that blocks - an `inotifywait`,
  or a sleep - except the one for a missing `/tmp/CORENAME`, which used to end
  in a `dbug` and nothing else. The file really can be missing: `S60tty2oled`
  waits for the serial device but not for MiSTer's `Main`, so the daemon can
  reach the loop first, and it then span at 99% of a core until `Main` wrote
  the file - writing the same debug line into `/tmp` for the whole of it when
  `debug="true"`. `waitforcorename` watches the *directory*, because
  `inotifywait` on a path that does not exist returns immediately, which is the
  spin again; and it falls back to a plain sleep on any exit code that is
  neither an event nor the timeout, because a machine with no inotify-tools is
  the spin a third time.
- **The device check ran once, in front of the loop.** `${TTYDEV}` disappears
  when the ESP is unplugged, when the USB bus re-enumerates it, and when a
  flash resets the board; after that every `echo >${TTYDEV}` fails silently,
  one per command, while the loop carries on and the panel keeps whatever was
  last drawn. Nothing recovered short of restarting the daemon. `serialready`
  is the per-pass check, and it does two jobs: while the port is absent it is
  the loop's only brake, and when the port comes back it re-runs the handshake
  and clears `oldcore`, `META_WIRE_LAST` and `DEFERRED_DONE`. All three,
  because a re-enumerated board has rebooted into its boot screen with the
  firmware's own defaults - so the core picture, the metadata line that
  `sendmeta` de-duplicates, and the time/screensaver/dimming/flip settings that
  lived in the RAM the reset cleared all have to go out again.
- **A pid file is not evidence, and this one was shared with upstream.**
  `S60tty2oled` wrote `/run/tty2oled-daemon.pid`, which is the path upstream's
  copy writes, and checked only that `/proc/<pid>` existed. Side-by-side
  installs is the whole point of the fork's own folder, and that one path undid
  it: a live upstream daemon in the file read as "already running" and stopped
  ours from starting, and `stop` then killed it. `stop` was worse than the
  sharing - it found the inotify child by grepping `ps` for the string
  `tty2oled` and taking a line by position, so on a machine running two
  installs it could name either. Proved rather than reasoned: the unfixed
  `stop()` kills an unrelated `sleep 60` whose pid is sitting in that file.
  `daemonpid` now believes a number only when `/proc/<pid>/cmdline` names
  *this* install's `${DAEMONSCRIPT}`, which also covers a recycled pid; the old
  path is still swept, safely because of that check, so a deploy can still stop
  a daemon the previous version of the script started. `children` reads ppids
  out of `/proc` instead of parsing `ps`.
- **Moving a path means finding everything that reads it.** The daemon's pid
  file moved to its own name, and `deploy-mister.sh` went on checking the old
  one by hand - every plain deploy would have reported a healthy daemon as "did
  not start" and exited 1. Nothing tested the deploy, so nothing noticed until
  it was read. It asks `S60tty2oled status` now, and `test-deploy.sh` fails if
  any command it sends names a `.pid` file.
- **`png2gsc.py` had two backends that disagreed, and Pillow's was the
  worse.** Found by writing the tests, and the first three on the default path:
  `--dither` turned pictures **almost entirely black** - quantizing a greyscale
  image to a palette reads each grey as a palette *index*, so only greys 0-15
  found their entries and everything brighter hit the black filler, and it has
  to go through RGB first. **16-bit PNGs**, which GIMP and Krita write at
  16-bit precision, came out in two tones, because `convert("L")` on `I;16`
  clips at 255 instead of scaling. `thumbnail()` never enlarges, so an icon
  drawn at half size stayed a postage stamp while ImageMagick filled the frame.
  And ImageMagick's `-colors 16` chose sixteen greys to suit the image rather
  than the panel's sixteen, so a ramp used ten levels. Truncating with `>> 4`
  became rounding to the nearest level at the same time, which is what made the
  two agree; it moved 146 anti-aliased edge pixels of the built-in boot logo
  up by one level, and `bootlogo.h` was regenerated for it.
- **Three scripts read the pid file by hand**, and moving it broke all three.
  The deploy was found by reading it; `flash-mister.sh` and
  `tty2oled-bootimg.sh` were found only when a test grepped the whole repo for
  the path. Both stop the daemon to free the serial port and restart it "if it
  was running" - judged by the old path, so after the move they concluded it
  never was, and a successful flash or boot-image upload left the display with
  no daemon at all. `test-daemon.sh` now fails if any script but the init
  script and the ini names a pid file. Grep for every reader before moving a
  path; the tests only cover what they were written to cover.
- **`EPOCHREALTIME` is punctuated by the locale.** Under `el_GR` it reads
  `1790041391,629355`, and bash arithmetic takes that comma as the comma
  operator rather than failing - so a timing assertion built on it silently
  measured nothing and passed. `tests/test-daemon.sh` pins `LC_ALL=C`.
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

**Two spellings of `.gsc`, one wire format.** This tool writes three header
lines then one hex character per pixel; the vendored artwork pack writes three
header lines then `0X1f,0Xa2,` bytes. They are interchangeable, because the
daemon sends either with `tail -n +4 | xxd -r -p` (`tty2oled.sh:191`), which
consumes hex digits and ignores everything else - both reduce to the same 8192
bytes. What is *not* negotiable is the header being exactly three lines, since
that `tail -n +4` is hardcoded.

All of them are `.gsc`: three header lines, then the pixels, row
major. So the panel has **16 grey levels**, `0` black to `f` white - no colour,
no alpha. Sizes are fixed and the firmware reads an exact byte count, so a
file one byte out is dropped as truncated.

| | size | bytes | where |
|---|---|---|---|
| core banner | 256x64 | 8192 | `pics/GSC/<CORENAME>.gsc` - what `CMDCOR` shows |
| console icon | 86x64 | 2752 | `pics_pri/ICON/<CORENAME>.gsc`, falling back to `pics/ICON/` |
| blank icon | 86x64 | 2752 | `png2gsc.py --blank --out ...`, all pixels `0` |
| boot screen | 256x54 | 6912 | the ESP's own flash, via `CMDWRBOOT` |
| built-in boot logo | 256x54 | 6912 | `bootlogo.h`, compiled into the firmware |

Draw at the target size in Aseprite or Pixelorama with a 16-step greyscale
palette, export PNG, then:

The icon set is **curated, and the files are the list**: `pics_pri/ICON` holds
one drawn icon per system this fork supports - 27 of the 47 console cores in
`coretypes.ini`. The other 20 still get the split layout and everything in it;
`findicon` simply finds nothing and the panel beside the text stays black.
There is no stub generator any more: a blank file in there would be
indistinguishable from a drawn one and would quietly make the list wrong.

```bash
./tools/png2gsc.py --banner --out pics/GSC/NES.gsc nes.png   # 256x64 banner
./tools/deploy-mister.sh --pics

./tools/png2gsc.py --out pics_pri/ICON/NES.gsc nes.png
./tools/deploy-mister.sh --icons

./tools/png2gsc.py --boot splash.png                    # 256x54 boot screen
# copy splash.gsc to the MiSTer, then ON THE MISTER:
/media/fat/tty2oledplus/tty2oled-bootimg.sh set splash.gsc
/media/fat/tty2oledplus/tty2oled-bootimg.sh status
/media/fat/tty2oledplus/tty2oled-bootimg.sh clear
```

The icon filename is the **core name**, the one `CORENAME` reports and
`tty2oled-diag.sh` prints - `GBA.gsc`, `MegaDrive.gsc`, not `GameBoyAdvance`.
Icons need no firmware flash and no upload: the daemon reads the file off the
SD card and sends it with `CMDICON` on every core change.

`png2gsc.py` fits and centres on black by default rather than stretching -
scaling up as well as down; `--stretch` fills, `--dither` helps photos and
hurts flat pixel art, `--invert` is for art drawn dark-on-light. Pillow is used
if installed, ImageMagick otherwise, and `--backend pillow|magick` picks one.

The two backends are held to the same output. Each 8-bit grey goes to the
**nearest** of the sixteen levels 0, 17, 34 ... 255 (`level()` in the tool,
`-posterize 16` in ImageMagick), so art drawn in that palette converts exactly
either way, and a smooth ramp comes out identical pixel for pixel.

## The boot screen band

The bottom **10 rows** of the panel are the firmware's, not the picture's, so a
user boot image is **256x54** and `BOOTIMG_BYTES` is 6912.

```
row  0..53  picture              stock logo at x=82, or the stored image
row 54      blank                        BOOT_GAP_BAND
row 55..62  sweep bar                    BOOT_BAR_Y, BOOT_BAR_H
row 57..63  build version        baseline BOOT_VER_Y, 5x7 font
```

Ten rows is measured off the stock screen rather than guessed: the sweep and
the version overlap because they are sequential in time, their union is rows
55..63, and the tenth is the blank row that keeps the picture off the bar.
Every constant is placed off `BOOT_BAND_Y`, and
`tests/firmware/test_meta_layout.cpp` derives the gaps back out of them, so the
band cannot be resized without the bar and the version moving with it.

The sequence is the same whatever is stored: **picture and version together in
the first frame**, then after `BOOT_HOLD_MS` (1s) the sweep starts and cycles
until the daemon says something. That is the point of the band - the first
version of this module let a stored image replace the whole screen, and a
display booting into somebody's artwork could no longer say which firmware it
was running. The version used to be drawn when the sweep *finished*, which
answered that question only after the ten seconds somebody was actually
looking.

Because the version is up for the whole animation and the two share rows
57..62, the bar cannot use the full width any more: `boot_barStartX` measures
what was actually drawn (`u8g2.getCursorX()`, so the `runsTesting` markers
count) and rounds up to a whole `BOOT_BAR_STEP`. Rounding matters - the bar's
grey is its position (`i/BOOT_BAR_STEP`, 0..15), not a counter, so starting
off-step would shift every segment's grey and the last one would no longer end
on the panel edge. `BOOT_BAR_X_MAX` caps it so a pathological string cannot
leave no bar at all.

**The sweep ends when the wait ends, not after a count.** `boot_waitOrCommand`
replaces every `delay()` in the sequence and returns early the moment
`Serial.available()`, so the first byte the daemon sends stops the animation
wherever it is. `oled_showStartScreen(true)` from `setup()` therefore repeats
for as long as the MiSTer takes; the default `false` used by `CMDSORG` and the
tilt sensor keeps the bounded `BOOT_SWEEP_REPEATS`, because on a re-show the
daemon is connected and silent and nothing would ever arrive to stop it. On a
re-show's exit the bar's own columns are blacked out - an aborted sweep stops
half-drawn - and the version is left alone, which the column reservation makes
safe.

**At power-on the boot screen is not left - it becomes the menu's picture**
(`bootoutro.h`, `BOOTSCREEN_AS_MENU`, on by default). The daemon sends
`CMDBOOTPIC,MENU,<transition>` for the MENU core instead of a picture, and the
firmware composes the boot image (stored, or built-in) with a black band into
`logoBin`, like any core picture, and transitions to it. At power-on it is
already on the panel, so nothing transitions at all. Instead, the moment the
daemon speaks, the power-on screen hands over to an outro: the sweep finishes
the cycle it was in - on to the edge, then clearing back - and the version
fades out over `BOOT_VERFADE_MS` (1s), its grey stepping 15 to 0. The band
ends empty under the picture.

The outro runs from `loop()`, not in `setup()` where the power-on screen is:
the daemon's handshake is arriving, and not reading the port for a few hundred
milliseconds overflows its 256-byte buffer. The sweep's position is handed
over as the next segment and which half of the cycle; `-1` means the daemon
spoke during the hold and there is no cycle to finish. The outro waits for the
power-on fade-in if that is still running - its palette steps redraw the whole
frame from a copy and would undo it - and stops dead the moment anything else
takes the panel.

`bootHolding` is what says the power-on screen is still up. The daemon's setup
commands leave it set (`boot_quietCommand`: contrast, fade times, dimming,
clock, version query, `CMDMETAOFF`, `CMDBOOTPIC`); **everything else clears
it, commands nobody has heard of included**, and so does the screensaver
starting and any re-show. The asymmetry is deliberate: a stale "still up"
would make the next `CMDBOOTPIC` skip its transition and leave whatever had
been drawn meanwhile as the menu's picture, while a wrongly cleared one only
costs a transition.

**The built-in picture is the same shape as a stored one.** Upstream drew a
120x46 1bpp XBM at x=82; this fork compiles in a full-width 4bpp picture
(`bootlogo.h`) and `oled_showStartScreen` has one path for both - a stored
image is simply preferred, and everything after the picture is identical. A
16-grey wordmark reads as artwork on this panel in a way a monochrome bitmap
does not, and one path means the band cannot be right for one and wrong for
the other.

`oled_showStartScreen` composes into `metaBin` (`logoBin` on the ESP8266, the
only framebuffer that build has - both are idle at power-up and on `CMDSORG`)
and blacks it from `BOOTIMG_BYTES` to `BOOT_PANEL_BYTES` before
`draw4bppBitmap`, which copies all 8192 bytes whatever the picture is. Short
and the sweep runs over a strip of stale buffer - on a re-show, the last
metadata card.

`bootlogo.h` is **generated, not edited**, from `bootlogo.png` beside it; the
command is written into the header's own first lines:

```bash
./tools/png2gsc.py --boot --header -o MiSTer_SSD1322_USB/bootlogo.h \
                   MiSTer_SSD1322_USB/bootlogo.png
```

`--header` emits the same pixels as `--boot` does, packed two per byte with the
high nibble on the left, which is the SSD1322 framebuffer layout and exactly
what `xxd -r -p` makes of a `.gsc`. `test_meta_layout` checks the array is
`BOOTIMG_BYTES` long, so regenerating it at the wrong size fails the suite
rather than drawing a strip of stale buffer above the band.

`tty2oled_logo` in `bitmaps.h` is upstream's 120x46 XBM and is now unused. It
is kept, commented, because it is upstream's asset; `tty2oled_logo32` is a
different bitmap and the screensaver still uses it.

Images stored before the band existed are 8192 bytes. `boot_begin` accepts
both sizes and `boot_load` reads `BOOTIMG_BYTES` either way, so a legacy image
is **cropped** to its top 54 rows rather than discarded - the rows that go are
exactly the rows the firmware now draws over. `CMDBOOTINF` answers
`BOOTIMG,legacy` for one, which is how `tty2oled-bootimg.sh status` knows to
say it is being cropped.

The number lives as a literal in three files that cannot read each other -
`png2gsc.py`, `tty2oled-bootimg.sh` and `bootscreen.h` - so `test-index.sh`
greps all three and checks they agree. A mismatch is either a file the
installer refuses or a transfer the firmware waits forever to finish.

## Releases and the installer

A tag push publishes a GitHub release (see step 4 at the top). Users install
by copying the `TTY2OLEDplus_Installer.sh` asset to `/media/fat/Scripts` and
running it from the Scripts menu; afterwards `update_tty2oledplus` is there
instead. Over SSH it is one line:

```sh
curl -fsSL --cacert /etc/ssl/certs/cacert.pem \
  https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/update_tty2oledplus.sh | bash
```

**Asset names carry no version** - `tty2oledplus.tar.gz`, `tty2oledplus-lolin32.bin`,
`VERSION`, `SHA256SUMS`. GitHub serves the newest release's assets at
`/releases/latest/download/<name>`, so the installer finds the latest release
without the API or any JSON parsing on the MiSTer. That address skips releases
marked *pre-release*, which is why CI never marks them, whatever the `b` says.

**MiSTer's curl cannot verify GitHub's certificate on its own** - every https
request fails with "unable to get local issuer certificate". It works with
`--cacert /etc/ssl/certs/cacert.pem`, the bundle MiSTer ships, and the
installer passes it. Measured on the MiSTer, not assumed.

The installer downloads everything it needs and checks each file against
`SHA256SUMS` **before changing anything**, so a damaged download leaves the
install as it was. `tty2oled-user.ini` and `coretypes.ini` are installed only
when missing. The firmware is flashed only when the display reports a
different version, and only for the board the display names; a display that
does not answer is left alone unless `--board` says what it is, because
guessing wrong flashes the wrong pinout. It refuses to run while upstream is
installed at all, and while upstream's
daemon holds the serial port. The daemon is restarted however the run ends.

**It does not ask for a key at the end, on purpose.** MiSTer's Scripts menu
already does: with `fb_terminal` on (the default) Main runs the script under
`agetty` on tty2 inside a wrapper that echoes "Press any key to continue", and
keeps the terminal up until a key is pressed (`MENU_SCRIPTS_FB` in
Main_MiSTer's `menu.cpp`). A prompt of our own there is a second prompt and a
second keypress. With `fb_terminal=0` the script runs under `popen` with the
OSD showing its output, has no terminal to read a key from, and returns to the
menu when it exits. update_all.sh prompts in neither case, and nor do we.

**`TTY2OLEDplus_Installer.sh` is only a starter**, so the copy a user
downloads never goes stale: it fetches `update_tty2oledplus.sh` and
`SHA256SUMS` from `/releases/latest`, refuses an installer that does not match,
runs it with the same arguments, and deletes itself - by that exact name, and
only after a successful run that left `update_tty2oledplus.sh` beside it. A
failed run leaves it in the menu to try again. Its temp folder is a global,
not a `local`: the `EXIT` trap fires after `main` has returned, and a local
was out of scope by then, so every successful run leaked it into `/tmp`.

It lives in `main()`, called on the last line, because `curl | bash` runs the
bytes as they arrive and a dropped connection would otherwise run half a script.
It replaces `Scripts/update_tty2oledplus.sh` **by rename**, because that may be
the very file bash is still reading.

The display's `CMDHWINF` answer is parsed as `;`-separated tokens, not as a
line: every command the daemon ever sent was followed by a `ttyack;`, and any it
did not read are still queued on the port ahead of the answer.

What goes into a release is `tools/manifest.sh`, the same list
`deploy-mister.sh` uses. `ESP32_CORE_VERSION` in the workflow pins the core CI
builds with to the one used here (`arduino-cli core list`); the libraries are
still whatever is current when CI runs, which is the one way a release build
can differ from a local one.

## Staying out of upstream's way

Upstream's `installer.sh`, `update_tty2oled.sh`, `update_tty2oled_script.sh`,
`local_flasher.sh` and `tty2oleddb.json` are **not part of this fork**. Every
one of them exists to pull venice1200's scripts or tty2tft.de's stock firmware
over a local install, which is the one thing a fork must not let happen. They
took `REPOSITORY_URL`, `PICTURE_REPOSITORY_URL`, `UPDATESCRIPT`, `AUTOUPDATE`,
`SCRIPT_UPDATE`, `TTY2OLED_UPDATE` and `MOUNTRO` out of the ini with them.

The `SCRIPT_UPDATE="no"` / `TTY2OLED_UPDATE="no"` switches that used to guard
this are gone too, and are not missed: they only ever worked if the updater
read *our* ini, and an updater installed in `/media/fat/Scripts` reads the
folder it was installed for. The install folder being its own is the real
protection.

What upstream's updaters did do usefully was wire the boot hook, so
`deploy-mister.sh` does that now, by feeding `tools/tty2oled-boothook.sh` to
the MiSTer on stdin. It adds

```
[ -e /media/fat/tty2oledplus/S60tty2oled ] && /media/fat/tty2oledplus/S60tty2oled $1
```

**at the top of** `/media/fat/linux/user-startup.sh` when that exact line is
not there, creating the file from `_user-startup.sh` if MiSTer has not made one
yet. It matches on the full path rather than on the string `tty2oled`, which is
the mistake upstream's version made - a MiSTer that once had stock tty2oled
already has a line with that word in it, and a loose match calls the job done
and never adds ours.

Top, not appended: `user-startup.sh` already runs late in the boot, and
everything above the line - mounts, network shares, somebody else's script - is
time the panel spends on its boot screen. The hook backgrounds the daemon, so
nothing below it is held up by going second. An existing hook further down is
reported and **left alone** rather than moved: it is the user's file, and the
line may be there on purpose. So is one that is commented out - reported as
commented out, not re-enabled, and not described as "already at the top".

If upstream's own hook is active *and* upstream's `S60tty2oled` still exists,
it warns: both daemons would start at boot on one serial port. It does not
touch that line. Upstream's hook is guarded by `[ -e ... ]`, so once that
install is moved or removed the line is harmless and the warning goes quiet.

## Versioning

The procedure is at the top of this file; this is what is underneath it.

`VERSION` at the repo root is the source of truth, `0.4.0b` at the time of
writing: `major.minor.patch` with an optional one-letter pre-release mark.

Two files need the number as a literal and cannot read `VERSION` at run time,
so `bump-version.sh` writes both: `TTY2OLED_VERSION` in `tty2oled-system.ini`,
and `#define BuildVersion` in the sketch. Nothing else holds a copy - the
README quotes the current number in prose, which is allowed to age, and the
daemon reports whatever the ini gives it.

That `b` is *this fork's* pre-release mark. The sketch's `runsTesting` keys on
a trailing `T`, which is upstream's and unrelated - a version ending in `b`
leaves it off, which is what we want.

`tests/test-version.sh` is what stops the copies drifting - it runs `--check`,
proves the arithmetic (including `0.4.9b` to `0.4.10b`, and that `--release`
refuses to run twice), and drives `checkversion` against a FIFO standing in
for the display.

`checkversion` in the daemon asks `CMDHWINF` at startup and prints both
numbers to `/tmp/tty2oled`, complaining when they differ. It has to read
`;`-delimited tokens and skip what is not a board id, because the firmware
acknowledges every command with `ttyack;` - including the one that asks.

## Not done yet

- **20 console cores have no icon.** The 27 that do are the supported set;
  the rest show the split layout with a black panel beside it. The file name
  is the core name `coretypes.ini` uses, which is what `findicon` looks for.
- **WonderSwan resolves per game, not per system.** The index is found and
  many titles hit; the misses are romsets whose filenames differ from
  No-Intro's, which the name fallback cannot bridge.
- **Neo Geo coverage is partial.** 203 sets from MAME 2003-Plus, matched by
  title, so a romset using a different spelling misses - `Bakatonosama
  Mahjong Manyuuki` against MAME's `Manyuki` is one letter out.
- **The LEDC shim is a clean upstream PR** on its own, independent of the
  metadata work.
