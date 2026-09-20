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
| `MiSTer_SSD1322_USB/metadisplay.h` | New. Arcade card + console split layout. |
| `MiSTer_SSD1322_USB/bootscreen.h` | New. LittleFS-backed custom boot image. |
| `MiSTer_SSD1322_USB/MiSTer_SSD1322_USB.ino` | Includes the two headers; LEDC shim for ESP32 core 3.x. |
| `tests/` | 201 checks, no hardware needed. |
| `tools/build-tty2oled.sh` | Builds the firmware with arduino-cli. Runs on the workstation. |
| `tools/deploy-mister.sh` | Pushes this working copy to the MiSTer over SSH. Workstation. |
| `tools/flash-mister.sh` | Flashes the firmware. Runs **on the MiSTer**. |
| `tools/tty2oled-diag.sh` | Dumps MiSTer's state files and what they parse to. **On the MiSTer**. |

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
```

`MISTER=root@192.168.1.50 ./tools/deploy-mister.sh` if mDNS does not resolve.
`ssh-copy-id root@MiSTer.local` once and it stops asking for a password.

The full loop is then: edit → `./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32`
→ `./tools/deploy-mister.sh --firmware --flash` → `ssh root@MiSTer.local 'tail -f /tmp/tty2oled'`.
Script-only changes need neither the build nor the flash.

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
