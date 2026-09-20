# tty2oled game-metadata fork — working notes

Fork of [venice1200/MiSTer_tty2oled](https://github.com/venice1200/MiSTer_tty2oled),
GPLv3 like upstream. Branch: `feature/game-metadata`, based on upstream `50c08ac`.

Upstream shows one picture per **core**. This fork shows the **game**: arcade
cores alternate artwork with an info card, console cores get a split layout
with scrolling text and an icon panel.

## Layout of the change

| Path | What it is |
|---|---|
| `tty2oled-meta.sh` | New. Turns MiSTer's `/tmp` state files into display metadata. |
| `tty2oled.sh` | Daemon. Sends `CMDMETA`/`CMDICON`, watches game state, not just the core. |
| `tty2oled-system.ini` | New settings (see below). |
| `MiSTer_SSD1322_USB/metadisplay.h` | New. Arcade card + console split layout. |
| `MiSTer_SSD1322_USB/bootscreen.h` | New. LittleFS-backed custom boot image. |
| `MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino` | Includes the two headers; LEDC shim for ESP32 core 3.x. |
| `tests/` | 201 checks, no hardware needed. |
| `tools/` | Build and diagnostic helpers. |

## Running the tests

```bash
./tests/run-all.sh
```

Four suites: metadata extraction, wire protocol, firmware parser, firmware
layout. The firmware suites compile the display headers against stubs under
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
`0x0`. The Arduino IDE works too — board profile `WEMOS LOLIN32`, and on an S3
set **USB CDC On Boot: Disabled** or `Serial` leaves the UART bridge the MiSTer
talks to.

## Deploying

Scripts: copy `tty2oled.sh`, `tty2oled-meta.sh`, `tty2oled-system.ini` to
`/media/fat/tty2oled/`, `chmod +x` the two scripts, restart with
`/media/fat/tty2oled/S60tty2oled restart`. **Never overwrite
`tty2oled-user.ini`** — it is the user's, and it is sourced after
`system.ini` so their settings win.

Firmware first, then scripts. New firmware with old scripts behaves exactly
like upstream; the reverse sends commands the firmware cannot parse.

Debug with `debug="true"` in `tty2oled-user.ini`, log at `/tmp/tty2oled`.
`./tools/tty2oled-diag.sh` on the MiSTer dumps every state file with mtimes and
shows what `build_meta` made of them — run it right after loading a game.

## Things that cost time, recorded so they do not again

- **`FULLPATH` is the containing folder, not the ROM path.** The file name is
  in `CURRENTPATH`. Reading `FULLPATH` titles every game after its folder.
- **Loading a ROM does not modify `/tmp/CORENAME`.** Watching that file alone
  can never notice a game change. The daemon watches the game-state files too.
- **MiSTer never clears `FULLPATH`/`FILESELECT`/`GAMEID`.** They outlive the
  core that wrote them, so a core started from the menu inherits the previous
  core's game. Trusted only when newer than `CORENAME`.
- **`FILESELECT` is written while merely browsing**, value `active`, and
  `FULLPATH` is rewritten with it. Only `selected` counts, and identical
  metadata is not resent or the marquee restarts on every keypress.
- **`log_file_entry=1` is required in `MiSTer.ini`** and defaults to off.
  Without it MiSTer publishes nothing but the core name.
- **ESP32 core 3.x removed the channel-based LEDC API.** Upstream's stable
  sketch does not build on current cores. A guarded macro block maps the old
  spelling onto `ledcAttach`/`ledcDetach`; 2.x is unaffected.
- **Renaming a variable mid-function is how the staleness guard silently
  stopped working** — it kept testing the old name while the value had moved.
  Its test passed for an unrelated reason. Check that a test fails without its
  fix.

## Two switches that exist to stop your work being overwritten

- `SCRIPT_UPDATE="no"` in `tty2oled-system.ini` — otherwise the updater pulls
  upstream's `tty2oled.sh` over this one.
- `TTY2OLED_UPDATE="no"` in `tty2oled-user.ini` — otherwise `update_all`
  reflashes stock firmware from tty2tft.de over your build.

`REPOSITORY_URL` still points at upstream. Repoint it at the fork before
turning either back on.

## Not done yet

- **Console icons.** Nothing ships them, so the icon panel is blank. They are
  86x64 `.gsc` files in `/media/fat/tty2oled/pics/ICON/`, with
  `pics_pri/ICON/` overriding, same convention as the pictures.
- **Title index.** `tty2oled-meta.sh` can upgrade a filename-derived title to a
  canonical one via CRC32, but no index is built yet. Format is
  `CRC32|Title|Region|Year|Publisher`, path in `TITLE_INDEX`.
- **The LEDC shim is a clean upstream PR** on its own, independent of the
  metadata work.
- Arcade side was described as "close enough for now" — not yet specified.
