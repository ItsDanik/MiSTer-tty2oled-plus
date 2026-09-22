# tty2oled+

*Game-aware display for the **[MiSTer FPGA]**.*

A fork of **[venice1200/MiSTer_tty2oled]**, which drives an SSD1322 OLED from a
MiSTer over USB and shows artwork for the running **core**.

tty2oled+ shows the **game**.

## Installation

You need a tty2oled display with an **ESP32** (see [Requirements](#requirements))
and a MiSTer that is online.

1. Download **[TTY2OLEDplus_Installer.sh]** from the latest release.
2. Copy it to the **`Scripts`** folder on the MiSTer's SD card
   (`/media/fat/Scripts`) - over the network share, FTP, or with the card in
   your computer.
3. On the MiSTer, open the menu, go to **Scripts** and run
   **TTY2OLEDplus_Installer**.
4. Reboot, so MiSTer picks up the `log_file_entry=1` the installer set for you
   (see below) and the display starts with the machine.

The installer downloads the newest release, checks every file against the
release's checksums before changing anything, and then:

- installs the scripts, the title index, the console icons and the artwork into
  `/media/fat/tty2oledplus`
- asks the display which board it is and flashes the matching firmware - only
  when the display runs a different version, and never by guessing
- sets `log_file_entry=1` in the `[MiSTer]` section of `MiSTer.ini`, which is
  what makes MiSTer say which game is loaded, and remembers what was there so
  the uninstaller can put it back
- adds the start line to `/media/fat/linux/user-startup.sh`, so the display
  comes up on every boot, and starts it now
- puts **update_tty2oledplus** and **uninstall_tty2oledplus** in the Scripts
  menu, and removes TTY2OLEDplus_Installer, which has done its job

**To update**, run **update_tty2oledplus** from the Scripts menu. Your
`tty2oled-user.ini` and `coretypes.ini` are never overwritten, and the firmware
is flashed only when the release carries a new one.

**To uninstall**, run **uninstall_tty2oledplus** from the Scripts menu. It
stops the display, removes `/media/fat/tty2oledplus`, the start line in
`user-startup.sh` and both Scripts entries, clears any boot image stored on the
display, puts `MiSTer.ini` back as the install found it, and removes itself - `--keep-settings` saves your two ini files beside
the install first, and `--dry-run` only lists what would go. The firmware stays
on the display: it is the display's own flash, and an ESP32 with none shows
nothing at all.

**Coming from upstream tty2oled?** tty2oled+ replaces it - both would drive the
same serial port - so the installer stops and says what to remove if it finds
`/media/fat/tty2oled`. To keep your settings instead, see
[Coming from an upstream install](#coming-from-an-upstream-install).

**Over SSH** instead of the Scripts menu, the same installer is one line:

```sh
curl -fsSL --cacert /etc/ssl/certs/cacert.pem \
  https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/update_tty2oledplus.sh | bash
```

If the display is too broken to say what board it is, name it:
`... | bash -s -- --board lolin32` (or `esp32de`, `esp32s3`).

[TTY2OLEDplus_Installer.sh]: https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/TTY2OLEDplus_Installer.sh

| | Upstream | tty2oled+ |
|---|---|---|
| Arcade core | core artwork | artwork, then two pages of everything the `.mra` knows — year, manufacturer, region, orientation, core, author, set, MAME version, then players, controls and button names — then back to the artwork |
| Console core | core artwork | split layout — scrolling game title and details, console icon beside it |
| Idle | full brightness | dims after a couple of minutes, wakes on the next change |
| Burn-in | fixed layout | the console layout swaps sides every few minutes |
| Computer core | core artwork | unchanged |
| Boot screen | built-in logo | your own image, stored on the display |

Everything upstream does still works, including all of its transition effects —
the metadata screens are composed into the same framebuffer format the pictures
use, so they animate in exactly the same way. Set `SHOW_METADATA="no"` and the
behaviour is upstream's, unchanged.

```
┌────────────────────────────────────────────────────┬──────────────┐
│ Now playing                                        │              │
│ ──────────────────────────────────────             │              │
│ The Legend of Zelda                                │  (console    │
│ System   = Nintendo NES                            │   icon)      │
│ Year     = 1987                                    │              │
│ Company  = Nintendo                            ▪▫  │              │
└────────────────────────────────────────────────────┴──────────────┘
```

The arcade card is the whole panel, and takes two turns to say everything the
`.mra` knows — artwork, page 1, page 2, artwork, one step per
`METADATA_INTERVAL`:

```
┌───────────────────────────────────────────────────────────────────┐
│               NBA Jam (rev 3.01 04/07/93)                    ▪▫   │
│ ───────────────────────────────────────────────────────────────── │
│ Year     1993            Manufctr  Midway                         │
│ Region   World           Orient    Horizontal                     │
│ Core     blahmid_tunit   Author    rejectedcoins                  │
│ Set      nbajam          MAME      0289                           │
└───────────────────────────────────────────────────────────────────┘
┌───────────────────────────────────────────────────────────────────┐
│               NBA Jam (rev 3.01 04/07/93)                    ▫▪   │
│ ───────────────────────────────────────────────────────────────── │
│ Year     1993            Manufctr  Midway                         │
│ Players  4                                                        │
│ Controls 8-way                                                    │
│ Buttons  Turbo/Shoot / Block/Pass / Steal                         │
└───────────────────────────────────────────────────────────────────┘
```

## Requirements

- Any tty2oled build on an **ESP32** (classic, or S3). ESP8266 keeps upstream
  behaviour — the display code needs more RAM than it has.
- **USB mode.** The SD and Standard sketch variants are not covered yet.
- `log_file_entry=1` in `MiSTer.ini`. It defaults to off, and without it MiSTer
  never publishes which game is loaded, so only core names can show. The
  installer sets it; a working copy deploy does not, so set it by hand there.

## Installing from a working copy

For development, from a workstation with the repo checked out and SSH to the
MiSTer:

```bash
ssh-copy-id root@MiSTer.local                # once, so it stops asking

./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32   # or esp32de / esp32s3
./tools/deploy-mister.sh --firmware --flash            # firmware, then scripts
```

This fork installs to **`/media/fat/tty2oledplus/`**, not upstream's
`/media/fat/tty2oled/`, so neither updater can overwrite the other's files.
It **replaces** upstream rather than running beside it — both would be driving
the same serial port — so while `/media/fat/tty2oled/` still holds upstream's
scripts, the installer, the deploy and the daemon's init script all refuse to
go on, and say how to remove it. Moving the folder, below, is one way.

### Coming from an upstream install

Move the folder, point the boot script at the new one, and install over it.
Moving rather than copying keeps your artwork, your `tty2oled-user.ini` and
your `coretypes.ini`. On the MiSTer, over SSH:

```bash
/media/fat/tty2oled/S60tty2oled stop
mv /media/fat/tty2oled /media/fat/tty2oledplus
sed -i 's|/media/fat/tty2oled/|/media/fat/tty2oledplus/|g' /media/fat/linux/user-startup.sh
rm -f /media/fat/Scripts/update_tty2oled.sh
```

Then run **TTY2OLEDplus_Installer** from the Scripts menu, as in
[Installation](#installation) - or, from a working copy,
`./tools/deploy-mister.sh`.

Installing over it is the part that matters: `S60tty2oled` and `tty2oled-read.sh` name
the install folder outright — they run before any ini is read, so they have to
— and the copies that came with upstream still name the old one. Upstream's
installer, its two update scripts and its `tty2oled_cc.sh` menu are not part
of this fork; delete them from the moved folder if you want it tidy.

A MiSTer that has never had any of this gets everything in one go — scripts,
title index, console icons and the core artwork pack:

```bash
./tools/deploy-mister.sh --all
```

`MISTER=root@192.168.1.50 ./tools/deploy-mister.sh` if mDNS does not resolve.
Script-only changes afterwards need neither the build nor the flash — just
`./tools/deploy-mister.sh`, which also adds the boot hook to
`/media/fat/linux/user-startup.sh` the first time, so the daemon comes back
after a reboot.

Upstream's installer and its two update scripts are not part of this fork:
they exist to pull venice1200's scripts and tty2tft.de's stock firmware over a
local install. The release installer above is this fork's own.

Firmware first, then scripts. New firmware with old scripts behaves exactly
like upstream; the reverse sends commands the firmware cannot parse.
`--firmware --flash` gets that order right on its own.

Not sure which board you have? Ask the display — upstream's installer menu
lists "DevKit" twice, and a generic ESP32 DevKit V4 is the `lolin32` profile:

```bash
. /media/fat/tty2oledplus/tty2oled-system.ini
stty -F ${TTYDEV} ${BAUDRATE} ${TTYPARAM}
echo "CMDHWINF" > ${TTYDEV}; read -t5 R < ${TTYDEV}; echo "$R"   # HWLOLIN32;...
```

**`tty2oled-user.ini` is never copied** — it holds your settings, and it is
sourced after `tty2oled-system.ini` so they take precedence.

## Game metadata

Titles come from the filename. Year, publisher, genre and developer come from a
local index built from **[libretro-database]** — offline, no API key, no
account. MiSTer writes the loaded game's CRC32 (or a disc serial) to
`/tmp/GAMEID`, and that is the key.

```bash
./tools/build-title-index.sh        # ~2.5MB, 38k games, cached between runs
./tools/deploy-mister.sh --index
```

One file per core in `titleindex/`, looked up by CRC32, then disc serial, then
title. A miss costs only the extra fields — the filename title still shows.

| Systems | What you get |
|---|---|
| 47 cartridge systems | title, region, year, publisher, genre, developer |
| Neo Geo | title, year, publisher (from the MAME set — it is arcade hardware) |
| PSX, Saturn, Sega CD, 3DO, PC Engine CD | title, region only |

The disc systems are a limit of the source, not of the romset: libretro's
metadata categories cover cartridge systems, and disc titles appear only in the
redump set, which has no release dates or publishers at all.

`./tools/build-title-index.sh --list` shows the core-to-system map. If a system
of yours is missing, add it there; `tools/tty2oled-diag.sh` on the MiSTer prints
the core name to use.

## Artwork

Both icons and the boot screen are `.gsc`: a three-line header, then **one hex
character per pixel**. So 16 grey levels, `0` black to `f` white — no colour,
no alpha. Sizes are fixed, and a file even one byte short is rejected.

| | Size | Where |
|---|---|---|
| Console icon | 86×64 | `pics_pri/ICON/<CoreName>.gsc` |
| Boot screen | 256×64 | the display's own flash |

`pics_pri/ICON/` holds a drawn icon for each of the 27 systems this fork
supports:

> 3DO · Atari 2600 / 5200 / 7800 · Atari Lynx · Game Boy · Game Boy Color ·
> Game Boy Advance · Game Gear · Genesis · Jaguar · Mega CD · Mega Drive ·
> N64 · NES · Neo Geo · PlayStation · Saturn · Master System · SNES ·
> 32X · TurboGrafx-16 · TurboGrafx-16 CD · Virtual Boy · WonderSwan ·
> WonderSwan Color

Every other console core still gets the split layout — title, fields, the
lot — just with a blank panel where the icon would be. To add one, draw at
86×64 in 16 greys (Aseprite, Pixelorama) and name the file after the core, as
`tty2oled-diag.sh` on the MiSTer reports it:

```bash
./tools/png2gsc.py --out pics_pri/ICON/MegaDrive.gsc megadrive.png
./tools/deploy-mister.sh --icons
```

Core banners — the full-screen artwork `CMDCOR` puts up — are 256×64 and live
in `pics/GSC`, named after the core the same way:

```bash
./tools/png2gsc.py --banner --out pics/GSC/MegaDrive.gsc art.png
./tools/deploy-mister.sh --pics
```

The filename is the **core name** MiSTer reports — `GBA.gsc`, `MegaDrive.gsc`,
`NEOGEO.gsc`. No flash and no upload: the daemon reads the file off the SD card
and sends it over when the core changes.

The boot screen lives on the ESP itself, so it appears with the MiSTer switched
off or the SD card removed:

```bash
./tools/png2gsc.py --boot splash.png             # -> splash.gsc, 256x54
# copy splash.gsc to the MiSTer, then on the MiSTer:
/media/fat/tty2oledplus/tty2oled-bootimg.sh set splash.gsc
/media/fat/tty2oledplus/tty2oled-bootimg.sh status   # what is stored now
/media/fat/tty2oledplus/tty2oled-bootimg.sh clear    # back to the built-in logo
```

**256×54, not 256×64.** The bottom ten rows of the panel are the firmware's.
Whatever image is stored, the build version is printed there in the very first
frame and stays up until the daemon sends the first core — so a display booting
into your artwork can tell you which firmware it is running for the whole time
you are waiting, not just at the end. A second later the power-on sweep starts
in the rows beside it and keeps cycling until the MiSTer's daemon makes
contact, which is also the moment it stops: the animation is there to show the
display is alive and waiting, so it ends when the waiting does. A full-screen
image stored by an older version still works; it is cropped to its top 54 rows,
and `tty2oled-bootimg.sh status` says so.

With nothing stored you get the built-in screen, a 16-grey MiSTer wordmark
compiled into the firmware rather than upstream's monochrome bitmap. It lives
in `MiSTer_SSD1322_USB/bootlogo.h`, which is generated from the `.png` beside
it and not edited by hand:

```bash
./tools/png2gsc.py --boot --header -o MiSTer_SSD1322_USB/bootlogo.h \
                   MiSTer_SSD1322_USB/bootlogo.png
```

Changing it needs a rebuild and a flash; changing the stored one does not.

`png2gsc.py` fits and centres on black rather than stretching, scaling up or
down; `--stretch` fills, `--dither` suits photographs and hurts flat pixel art,
`--invert` is for art drawn dark-on-light. It uses Pillow if installed,
ImageMagick otherwise, and gives the same result with either. Draw in the
16-step grey palette (0, 17, 34 ... 255) and it converts exactly. 16-bit PNGs
are fine.

## Settings

Added to `tty2oled-system.ini`; override them in `tty2oled-user.ini`.

| Setting | Default | Meaning |
|---|---|---|
| `SHOW_METADATA` | `yes` | Master switch. `no` gives upstream behaviour exactly. |
| `METADATA_INTERVAL` | `12` | Arcade: seconds per screen — artwork, each card page in turn, then the artwork again. `0` never swaps. |
| `SHOW_CONSOLE_SPLIT` | `yes` | Console: text left, icon right. |
| `METADATA_FIELDS` | `System Year Genre Region Format` | Which console fields show, and in what order. Three fit at once; the rest page. |
| `METADATA_WARN` | `yes` | Warn once at startup if `log_file_entry` is missing. |
| `METADATA_POLL` | `5` | Seconds before re-checking for state files that did not exist yet. |
| `USE_NAMES_TXT` | `yes` | Show cores by the name in MiSTer's `names.txt`, as its own menu does. |
| `GAME_ROOTS` | SD, `usb0`–`usb5`, `cifs` | Where games may live. Searched in order. |
| `TITLE_INDEX_DIR` | `tty2oledplus/titleindex` | Per-core index files. |
| `CONTRAST` | `255` | Panel brightness, `0`–`255`. |
| `CONTRAST_FADE_MS` | `800` | How long any brightness change takes to fade, `0`–`4000` ms. `0` jumps. Going dim has its own `DIM_FADE_MS`. |
| `TRANSITION` | `-2` | How one picture replaces the last, on core changes and between arcade card pages. `-2` fades, `-1` is a random wipe, `0` none, `1`–`23` one wipe; the ini lists them all. |
| `TRANSITION_FADE_MS` | `800` | With `-2`: how long each fade, out and in, takes. `0`–`4000` ms. |
| `BOOTSCREEN_AS_MENU` | `yes` | The boot screen is the menu's picture: at power-on it stays up, the bar finishes and the version fades out. `no` shows the pack's `MENU.gsc`. |
| `TRANSITION_BLANK_MS` | `1000` | With `-2`: how long the panel stays black between them. `0`–`4000` ms. |
| `DIM_AFTER` | `120` | Seconds of nothing new on screen before the panel dims. `0` never dims. |
| `DIM_FADE_MS` | `6000` | How long going dim takes, `0`–`10000` ms - slow enough not to be noticed. Waking takes `CONTRAST_FADE_MS`. |
| `DIM_CONTRAST` | `80` | Brightness to dim to, `0`–`255` like `CONTRAST`, never above the waking level. Replaces `DIM_PERCENT`. |
| `DIM_WAKE` | `-1` | Brightness to wake at. `-1` uses `CONTRAST`. |
| `FLIP_MINUTES` | `5` | Swap the console layout's sides this often. `0` never swaps. |
| `ARCADE_FIELDS` | `Year Manufacturer Region Orientation Core Author Set MAME` | Short arcade fields, paired two to a row. |
| `ARCADE_FIELDS_WIDE` | `Players Controls Buttons` | Arcade fields whose values need a full row of their own. |
| `ARCADE_PINNED` | `Year Manufacturer` | The grid row repeated above each wide page. |
| `METADATA_PINNED` | `System Year` | Fields that stay on screen while the rest page under them. |
| `COMPACT_YEAR_COMPANY` | `yes` | Fold the publisher into the year: `1989, Acclaim` on one row. |

### Where settings live, and how to change them

Two files, both in `/media/fat/tty2oledplus/`, sourced in this order:

1. `tty2oled-system.ini` — shipped by this repo and **overwritten on every
   deploy**. Do not edit it on the MiSTer.
2. `tty2oled-user.ini` — yours. Never copied by `deploy-mister.sh`, and read
   second, so anything here wins.

So to change a setting, add it to the user ini and restart the daemon:

```bash
ssh root@MiSTer.local
echo 'DIM_AFTER="60"' >> /media/fat/tty2oledplus/tty2oled-user.ini
/media/fat/tty2oledplus/S60tty2oled restart
```

Settings the firmware acts on (`DIM_*`, `FLIP_MINUTES`, `CONTRAST`) are sent
over the wire when the daemon starts, so a restart is enough — no reflash.
To check what is actually in force:

```bash
. /media/fat/tty2oledplus/tty2oled-system.ini
[ -r /media/fat/tty2oledplus/tty2oled-user.ini ] && . /media/fat/tty2oledplus/tty2oled-user.ini
echo "${DIM_AFTER} ${DIM_CONTRAST} ${FLIP_MINUTES} ${METADATA_FIELDS}"
```

`coretypes.ini` maps each core to `console`, `computer` or `arcade`. It is
consulted before any guesswork, and a deploy will not overwrite one you have
edited.

Nothing here can be overwritten by upstream's updaters: they are not part of
this fork, and the install folder is not the one they write to. If you also
run stock tty2oled from `/media/fat/tty2oled`, its updater will keep that
folder up to date and leave this one alone — but only one of the two daemons
may run at a time, since they share the serial port.

## Troubleshooting

```bash
echo 'debug="true"' >> /media/fat/tty2oledplus/tty2oled-user.ini
/media/fat/tty2oledplus/S60tty2oled restart
tail -f /tmp/tty2oled
```

Two tools, both run **on the MiSTer**:

- `tty2oled-diag.sh` — every state file with its timestamp, what the metadata
  layer made of it, and whether the loaded game hit the index. Run it right
  after loading a game.
- `tty2oled-capture.sh` — records the same thing continuously while you load
  games, so a whole set of systems can be looked at in one pass.

Nothing on screen but core artwork? Check `log_file_entry=1` is in
`MiSTer.ini`, then check `tty2oled-diag.sh` reports `KIND=console`.

## Versions

The scripts and the firmware carry **one** version — `VERSION` at the repo
root, currently `0.4.0b` — and are released together. A trailing `b` means
beta.

```bash
./tools/bump-version.sh            # 0.4.0b -> 0.4.1b, before every push
./tools/bump-version.sh --release  # drop the beta mark
./tools/bump-version.sh --check    # every copy still agrees?
```

It writes the number into `tty2oled-system.ini` and into the sketch's
`BuildVersion`, which are the only two places that need it as a literal, and
`tests/test-version.sh` fails if they ever drift apart. The daemon asks the
display for its version at startup and says so in `/tmp/tty2oled` when the two
do not match — so a display behaving oddly after a script-only deploy explains
itself in one line.

`CHANGELOG.md` has an entry per version, and each push is tagged:

```bash
git tag -a v0.4.0b -m "tty2oled+ 0.4.0b" && git push --tags
```

so "which firmware is on the display" is answerable from the repo.

## Tests

```bash
./tests/run-all.sh
```

638 checks across six suites, needing no MiSTer, no ESP32 and no serial port.
The firmware suites compile the display code against stubs under
`-Wall -Wextra -Werror` with ASan/UBSan and a real 8192-byte framebuffer.

Every bug fixed here reached hardware first, so each one has a test that was
confirmed to fail against the unfixed code.

## Not done yet

- **The icons are blank.** The files are named and valid; nobody has drawn them.
- **Disc-system release dates.** Not available offline; see above.
- SD and Standard sketch variants.

## Credit and licence

All of the hard parts — the hardware, the sketch, the picture pipeline, the
transitions, the daemon — are venice1200's and the tty2oled contributors'. This
fork only adds a metadata layer on top. GPLv3, like upstream.

Metadata comes from **[libretro-database]** and the MAME project, both
community efforts that this leans on entirely.

Documentation for the underlying project lives in the
**[upstream wiki][Documentation]**.

<!----------------------------------------------------------------------------->

[MiSTer FPGA]: https://github.com/MiSTer-devel
[venice1200/MiSTer_tty2oled]: https://github.com/venice1200/MiSTer_tty2oled
[libretro-database]: https://github.com/libretro/libretro-database
[Documentation]: https://github.com/venice1200/MiSTer_tty2oled/wiki
