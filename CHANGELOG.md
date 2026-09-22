# Changelog

The scripts and the firmware carry **one** version and are released together,
so every entry below describes both. `tools/bump-version.sh` moves the number;
a trailing `b` means beta.

## 0.4.3b — 2026-09-22

- **An uninstaller.** `uninstall_tty2oledplus` in the Scripts menu removes
  every trace of tty2oled+: the install folder, the start line in
  `user-startup.sh`, both Scripts entries, the pid file and logs, and the boot
  image stored in the display's own flash - then itself. `--keep-settings`
  saves your `tty2oled-user.ini` and `coretypes.ini` beside the install first,
  `--dry-run` only lists what would go. The firmware stays on the display: an
  ESP32 with none shows nothing at all. Upstream's install, if you have one,
  and `log_file_entry=1` in `MiSTer.ini` are left alone.
- The installer and the deploy both put the uninstaller in the Scripts menu,
  so an existing install gains it with the next update.

## 0.4.2b — 2026-09-22

The first published release. Everything described under 0.4.1b and 0.4.0b is
in it; neither of those was ever published.

- The installer behind the Scripts menu is now called `update_tty2oledplus.sh`
  everywhere - in the release as well as in the menu. The SSH one-liner
  downloads `.../releases/latest/download/update_tty2oledplus.sh`. 0.4.1b's
  release failed to publish because GitHub treats `TTY2OLEDplus_Installer.sh`
  and the installer's old name, `tty2oledplus_installer.sh`, as the same file.

## 0.4.1b — 2026-09-22

Tagged, never released.

- **ESP32 DevKit and ESP32-S3 firmware builds again.** 0.4.0b was tagged but
  never released: with Adafruit GFX 1.12.6 the grey-scale picture path failed
  to compile for those two boards (an ambiguous `round()` on a whole number,
  inherited from upstream). The WEMOS LOLIN32 build was unaffected. The fix
  does not change a single pixel.

## 0.4.0b — 2026-09-22

First versioned build of the fork.

### Display

- **Console cores** get a split layout: "Now playing", the game title with a
  marquee when it overflows, a paged field list, and an 86×64 icon beside it.
- **Arcade cores** get an info card that alternates with the artwork. It shows
  everything the `.mra` carries across two pages — a two-column grid of year,
  manufacturer, region, orientation, core, author, set and MAME version, then
  a row each for players, controls and the game's button names under a repeat
  of the pinned row. Artwork, page 1, page 2, artwork, one step per
  `METADATA_INTERVAL`.
- Computer cores are untouched, and `SHOW_METADATA="no"` gives upstream
  behaviour exactly.
- The panel dims after `DIM_AFTER` seconds with nothing new on it, and the
  console layout swaps sides every `FLIP_MINUTES` so no region holds the same
  lit pixels.
- A custom boot screen can be stored in the display's own flash, so it appears
  with the MiSTer switched off.

### Metadata

- Titles come from the filename; year, publisher, genre and developer come
  from a local index built from libretro-database and keyed on the CRC32 or
  disc serial MiSTer writes to `/tmp/GAMEID`.
- `coretypes.ini` classifies every known core as console, computer or arcade.
- Core names are shown as MiSTer's own `names.txt` shows them.

### Project

- **Installs from the Scripts menu**: copy `TTY2OLEDplus_Installer.sh` to
  `/media/fat/Scripts` and run it. It installs the newest release - scripts,
  title index, icons, artwork - checks every download against the release's
  checksums first, flashes the firmware for the board the display reports, and
  wires the boot hook. `update_tty2oledplus` takes its place in the menu for
  every update after, and never overwrites your `tty2oled-user.ini`.
- Installs to **`/media/fat/tty2oledplus`**, its own folder, so neither
  project's updater can overwrite the other's files. It replaces upstream
  rather than running beside it - both would drive the same serial port - and
  says what to remove when it finds upstream installed.
- `tools/deploy-mister.sh` installs from a working copy over SSH: scripts, firmware, title index,
  icons, and the boot hook in `user-startup.sh`.
- Upstream's installer, both update scripts, the local flasher, the downloader
  DB, the non-USB sketches and the `Testing/` tree are gone — all of them
  existed to pull upstream's files over a local install, which is the one
  thing a fork must not allow.
- 1248 checks in `./tests/run-all.sh`, needing no MiSTer, no ESP32 and no
  serial port.
