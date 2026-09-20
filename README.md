# tty2oled+

*Game-aware display for the **[MiSTer FPGA]**.*

A fork of **[venice1200/MiSTer_tty2oled]**, which drives an SSD1322 OLED from a
MiSTer over USB and shows artwork for the running **core**.

tty2oled+ shows the **game**.

| | Upstream | tty2oled+ |
|---|---|---|
| Arcade core | core artwork | artwork alternating with a card: title, year, manufacturer, category |
| Console core | core artwork | split layout — scrolling game title and details, console icon beside it |
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

## Requirements

- Any tty2oled build on an **ESP32** (classic, or S3). ESP8266 keeps upstream
  behaviour — the display code needs more RAM than it has.
- **USB mode.** The SD and Standard sketch variants are not covered yet.
- `log_file_entry=1` in `MiSTer.ini`. It defaults to off, and without it MiSTer
  never publishes which game is loaded, so only core names can show.

## Install

From a workstation with the repo checked out and SSH to the MiSTer:

```bash
ssh-copy-id root@MiSTer.local                # once, so it stops asking

./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32   # or esp32de / esp32s3
./tools/deploy-mister.sh --firmware --flash            # firmware, then scripts
```

`MISTER=root@192.168.1.50 ./tools/deploy-mister.sh` if mDNS does not resolve.
Script-only changes afterwards need neither the build nor the flash — just
`./tools/deploy-mister.sh`.

Firmware first, then scripts. New firmware with old scripts behaves exactly
like upstream; the reverse sends commands the firmware cannot parse.
`--firmware --flash` gets that order right on its own.

Not sure which board you have? Ask the display — the installer's menu lists
"DevKit" twice, and a generic ESP32 DevKit V4 is the `lolin32` profile:

```bash
. /media/fat/tty2oled/tty2oled-system.ini
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

`pics_pri/ICON/` already holds a blank, correctly named file for all 47 console
cores, so you only have to draw. Work at the target size in Aseprite or
Pixelorama with a 16-step greyscale palette, then:

```bash
./tools/png2gsc.py --out pics_pri/ICON/MegaDrive.gsc megadrive.png
./tools/deploy-mister.sh --icons
```

The filename is the **core name** MiSTer reports — `GBA.gsc`, `MegaDrive.gsc`,
`NEOGEO.gsc`. No flash and no upload: the daemon reads the file off the SD card
and sends it over when the core changes.

The boot screen lives on the ESP itself, so it appears with the MiSTer switched
off or the SD card removed:

```bash
./tools/png2gsc.py --boot splash.png             # -> splash.gsc, 256x64
# copy splash.gsc to the MiSTer, then on the MiSTer:
/media/fat/tty2oled/tty2oled-bootimg.sh set splash.gsc
/media/fat/tty2oled/tty2oled-bootimg.sh clear    # back to the built-in logo
```

`png2gsc.py` fits and centres on black rather than stretching; `--stretch`
fills, `--dither` suits photographs and hurts flat pixel art, `--invert` is for
art drawn dark-on-light. It uses Pillow if installed, ImageMagick otherwise.

## Settings

Added to `tty2oled-system.ini`; override them in `tty2oled-user.ini`.

| Setting | Default | Meaning |
|---|---|---|
| `SHOW_METADATA` | `yes` | Master switch. `no` gives upstream behaviour exactly. |
| `METADATA_INTERVAL` | `12` | Arcade: seconds between artwork and info card. `0` never swaps. |
| `SHOW_CONSOLE_SPLIT` | `yes` | Console: text left, icon right. |
| `METADATA_FIELDS` | `System Year Company Genre Region Format` | Which console fields show, and in what order. Three fit at once; the rest page. |
| `METADATA_WARN` | `yes` | Warn once at startup if `log_file_entry` is missing. |
| `METADATA_POLL` | `5` | Seconds before re-checking for state files that did not exist yet. |
| `USE_NAMES_TXT` | `yes` | Show cores by the name in MiSTer's `names.txt`, as its own menu does. |
| `GAME_ROOTS` | SD, `usb0`–`usb5`, `cifs` | Where games may live. Searched in order. |
| `TITLE_INDEX_DIR` | `tty2oled/titleindex` | Per-core index files. |

`coretypes.ini` maps each core to `console`, `computer` or `arcade`. It is
consulted before any guesswork, and a deploy will not overwrite one you have
edited.

Two switches are shipped **off** in `tty2oled-system.ini` so neither updater
can overwrite this fork: `SCRIPT_UPDATE="no"` stops the updater pulling
upstream's scripts over these, and `TTY2OLED_UPDATE="no"` stops `update_all`
reflashing stock firmware over your build. Repoint `REPOSITORY_URL` at your
own fork before turning either back on.

To confirm what is actually in force on the MiSTer, including anything your
own `tty2oled-user.ini` overrides:

```bash
. /media/fat/tty2oled/tty2oled-system.ini
[ -r /media/fat/tty2oled/tty2oled-user.ini ] && . /media/fat/tty2oled/tty2oled-user.ini
echo "TTY2OLED_UPDATE=${TTY2OLED_UPDATE} SCRIPT_UPDATE=${SCRIPT_UPDATE}"
```

## Troubleshooting

```bash
echo 'debug="true"' >> /media/fat/tty2oled/tty2oled-user.ini
/media/fat/tty2oled/S60tty2oled restart
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

## Tests

```bash
./tests/run-all.sh
```

418 checks across five suites, needing no MiSTer, no ESP32 and no serial port.
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
