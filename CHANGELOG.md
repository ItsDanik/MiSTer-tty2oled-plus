# Changelog

The scripts and the firmware carry **one** version and are released together,
so every entry below describes both. `tools/bump-version.sh` moves the number;
a trailing `b` means beta.

## 0.4.8b — 2026-09-23

- **A settings editor in the Scripts menu.** **tty2oledplus_settings** puts
  everything worth changing behind menus - what the display shows, which
  details appear under a game, how bright the panel is and when it dims, how
  one picture replaces the last - with what each setting does written beside
  it. Nothing is written until you save, and saving restarts the display so
  the change is on the panel before you leave. It only ever writes
  `tty2oled-user.ini`, and only the settings you have actually changed:
  anything left at its default stays out of the file, so a later release that
  changes a default is still followed. Your own comments, and any setting the
  editor does not cover, are left exactly where they were. It needs a terminal
  to draw in - that is `fb_terminal=1` in `MiSTer.ini`, the default - and says
  so rather than failing into the OSD if there is none.
- **The Scripts entries are renamed** so they sort together in the menu, which
  is alphabetical: **tty2oledplus_install**, **tty2oledplus_settings**,
  **tty2oledplus_uninstall**, **tty2oledplus_update**. The old entries -
  `TTY2OLEDplus_Installer`, `update_tty2oledplus`, `uninstall_tty2oledplus` -
  are removed once the new ones are in place. Updating from 0.4.7b or earlier
  works as it always has: this release still publishes the updater under its
  old name for the installers that ask for it by that name, and the new menu
  entries appear on the first update, the old ones disappearing with it. That
  one compatibility copy is dropped in the next release.
- **The README is rewritten**, with real screenshots of the display rather
  than sketches of it - the firmware's own layout code, rendered on a
  workstation - and without the sections that were only ever for people
  working on the code.

## 0.4.7b — 2026-09-23

- **The sweep no longer lurches or smears when the MiSTer is ready.** Handing
  the animation over from the boot screen to the running firmware let it catch
  up on the time the handover had taken, so it jumped forward - and a jump
  longer than the dark end of the comet's tail left lit pixels behind it. It
  moves one step per frame now whatever the clock says, and the bar is blacked
  outright when a run ends.
- **The bar moves twice as fast**, a run taking about a third of a second
  rather than two thirds.

## 0.4.6b — 2026-09-23

- **The installer sets `log_file_entry=1` for you.** It is what makes MiSTer
  say which game is loaded, it defaults to off, and until now the installer
  could only tell you to go and set it. It is written into the `[MiSTer]`
  section of `MiSTer.ini` - not the end of the file, where a per-core section
  would own it - and what was there before is remembered, so the uninstaller
  puts it back exactly as it found it: already set means untouched, a
  different value is restored verbatim, a line we added is removed, and a
  `MiSTer.ini` we created is deleted if nothing else has been written to it.
  A setting you have changed since is always left alone. Reboot for it to
  take effect.
- **The busy bar is a comet now.** It was whole 16-pixel blocks that jumped a
  block at a time and showed four or five visible shades. It is a head with a
  64-pixel tail carrying all sixteen greys, moving a pixel at a time - ten
  times the frames, over the same 640ms.
- The message over the bar during update_all reads **"Updating System ..."**.

## 0.4.5b — 2026-09-22

- **The busy bar no longer runs for ever after an update.** When
  `update_tty2oledplus` finished, the bar kept sweeping across the menu
  picture until a core was loaded: the daemon never took it down, and the
  MENU core draws its picture with a command the firmware treats as harmless.
  Both halves are fixed - the bar is stopped when the updater exits, and the
  menu picture stops it by itself.
- **A page turn fades only what changes.** Turning from one page of metadata
  to the next used to fade the whole panel, title and all, for the sake of
  three rows of text. Now the title, the rule and the pinned fields stay lit
  and still, and only the paged rows fade out and back in - on the console
  layout the icon beside them stays lit too.
- The "UPDATING" message over the busy bar is drawn in a smaller font.

## 0.4.4b — 2026-09-22

- **The uninstaller now actually reaches the Scripts menu.** In 0.4.3b it
  landed in `/media/fat/tty2oledplus` instead: an update is applied by the
  installer already on the MiSTer, and 0.4.2b's knew nothing about a file that
  belongs somewhere else. The daemon's own start places it now, so it appears
  however old the installer that applied the update was.
- **"UPDATING" while update_all downloads.** The banner gave no sign of which
  part of an update was running. Now, when the downloader starts - the part
  that takes minutes - the panel shows UPDATING above the busy bar and nothing
  else; the banner comes back when the download ends. `UPDATE_ALL_TEXT` in the
  ini says what it reads.
- **The display says when tty2oled+ itself is updating.** Running
  `update_tty2oledplus` puts "Updating TTY2OLED+..." on the panel with the
  busy bar under it, and it stays there while the updater has the serial port
  and the display is reflashed - instead of the last game's artwork sitting
  there through the whole thing. `SELF_UPDATE_TEXT` and `SELF_UPDATE_SCREEN`
  in the ini. The uninstaller deliberately gets no such screen.

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
