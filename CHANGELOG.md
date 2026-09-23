# Changelog

The scripts and the firmware carry **one** version and are released together,
so every entry below describes both. `tools/bump-version.sh` moves the number;
a trailing `b` means beta.

## 0.5.9b — 2026-09-24

- **The settings editor saves what you picked.** Choosing a different
  transition - or any other single-choice setting - and pressing Enter stored
  the value that was already set, so the editor looked as though it were
  ignoring you. The lists it used needed Space pressed on the entry you wanted
  before Enter would take it, which is not something a d-pad can do. They are
  plain menus now: move to what you want, press A, and that is what is saved.
  Every list opens on the value in force, so you can still see what is set.

- **A boot screen without a workstation.** Put a PNG at
  `/media/fat/tty2oledplus/pics/boot.png` and pick **Boot screen** in
  tty2oledplus_settings: it converts it, stores it on the display and tidies
  up after itself. The same entry puts the built-in logo back. Draw it 256x54
  in up to 16 shades of grey; anything else is scaled to fit and centred.
  Your PNG stays where it is and no update touches it, so after a firmware
  flash the same entry sends it again.

- **The uninstaller asks before it removes anything.** Twice: whether to go
  on, and what to do with the files that are yours - your settings, the
  banners in `pics/user` and your `boot.png`. Keeping them copies them to
  `/media/fat/tty2oledplus-saved` first; cancelling on either question changes
  nothing. Both questions are arrows and one button, no typing. Where there is
  no screen to ask on it now refuses rather than removing the install
  silently; `--yes` still says you mean it.

- **Pictures cross-fade sliding left by default,** in 400ms rather than 800.

## 0.5.8b — 2026-09-23

- **One artwork folder, four kinds of picture.** `pics/GSC` and `pics_pri` are
  gone; everything now lives under `pics/` as `banner` (the core artwork),
  `alt` (its `_alt1`, `_alt2` ... alternatives), `icon` (the console icons)
  and `user`. Your MiSTer sorts itself out on the next restart: the old
  folders are renamed into the new ones in place, so nothing is downloaded
  again and nothing you put there is lost.

- **`pics/user` is yours, and no update will ever write into it.** Drop a
  256x64 `.gsc` named after the core in there and it replaces the shipped
  picture - which is what `pics_pri` was for, except that nothing about the
  name said so and the pack folder beside it looked just as editable.
  `PRIORITIZE_USER_BANNERS="no"` puts the pack first instead and treats yours
  as the fallback.

- **Ten new transitions: the cross-fade, sliding.** `TRANSITION="30"` through
  `"39"` fade one picture into the next exactly as `-2` does, but drift the
  picture while they do it - off one edge as it darkens, in from the other as
  it comes back. Left, right, up and down, each at a gentle pixel per step and
  at a brisk two, plus two that pick a direction at random every time. They
  are in the settings editor's Effect list by name, beside the wipes.

- **A core with more than one picture now shows the same one every time.**
  Upstream diced between a core's artwork and its alternatives on every load,
  and this fork did too. The alternatives are a different artist's take on a
  system rather than a variant of one picture, so the display changing its
  mind about what a console looks like read as a fault. Set
  `RANDOMIZE_ALT_BANNERS="yes"` for the old behaviour; alternatives of your
  own go in `pics/user` beside your banners, and are diced in with the rest.
  An ini that still sets `USE_RANDOM_ALT` gets a line in the log saying so.

## 0.5.7b — 2026-09-23

- **The side swap fades too.** Every `FLIP_MINUTES` the console layout moves to
  the other side of the panel, and it did so between one frame and the next -
  the most abrupt thing the display did, and the one that happens while nobody
  is touching the MiSTer. It uses `TRANSITION` now, like every other change of
  picture, so by default it cross-fades from one side to the other.

## 0.5.6b — 2026-09-23

- **The system icon is part of the fade now, instead of appearing after it.**
  The game's details faded in with a black panel where the icon goes, and the
  icon then popped into place on top - because the icon is a separate transfer
  that arrives just after the details, by which time the fade had already
  decided what it was fading to. The layout is composed a second time at the
  bottom of the fade, while the panel is black and doing nothing else, so the
  icon has the whole fade-out and pause to arrive in and comes up with
  everything else.

## 0.5.5b — 2026-09-23

- **Fades no longer stall part way through.** A fade would manage two or three
  of its sixteen steps, freeze for about half a second, then jump straight to
  black - on every game change, and on the way from a core's artwork to the
  game's details. The cause was the console icon that follows the game details:
  reading its 2752 bytes blocks the display's main loop, and the daemon pauses
  between the header and the data, so nothing else ran for the best part of
  half a second - including the fade. The icon is read a piece at a time now,
  with the fade advanced between pieces. A transfer that goes silent is still
  abandoned, so a truncated icon is dropped rather than half-drawn.

## 0.5.4b — 2026-09-23

- **No more flash before the fade.** The game's details appeared for an instant
  at full brightness just before fading in. The console icon is sent
  immediately after the details, by which time the fade towards those very
  details is already running, and the display was composing the layout the
  moment the icon landed - putting it on the panel for one frame before the
  fade overwrote it. The icon now waits for the panel to settle and redraws
  once, after.
- **The core boot screen actually works now.** It was only armed when the game
  was already known at the moment the core changed, and on a real MiSTer that
  almost never happens: the core is published a second or two before the game.
  So the setting did nothing, and the pause before the details appeared was
  MiSTer's own. It is armed on every console core change now, and timed from
  the moment the artwork reaches the panel - so the artwork is guaranteed
  `core_bootscreen_time` on screen, and a game that arrives after that has
  already elapsed is still drawn at once rather than waiting out a second one.

## 0.5.3b — 2026-09-23

- **Loading a ROM into a core that is already running now transitions too.**
  It changed the screen with no transition at all, and so, sometimes, did the
  core boot screen. The cause was the console icon: the daemon sends one after
  every set of game details, game changes included, and the display composed
  the split layout the moment it arrived - cutting straight to the new game and
  marking the first draw done before the transition could happen. The icon now
  only redraws when the layout is already on screen, which is what that redraw
  was for.
- Everything that puts the split layout on screen for the first time uses
  `TRANSITION` now: a core and its game arriving together, a game loaded into a
  running core, and a game replaced by another.

## 0.5.2b — 2026-09-23

- **The core boot screen transitions into the game's details** rather than
  cutting to them. Three seconds of the core's artwork followed by an abrupt
  swap was the one visible cut left in the console path; it now uses whatever
  `TRANSITION` is set to, the same effect a core change uses, so the artwork
  fades or wipes into the layout.
- While any picture transition is running, the marquee and the field pager
  hold still. They redraw the whole frame, and a transition animates from one
  copy towards another, so anything drawn between two of its steps was
  overwritten by the next one - a fade with a long title would have spent
  itself fighting the scroll.

## 0.5.1b — 2026-09-23

- **A core launched with its game now shows the core's own artwork first.**
  Loading a console core and its ROM in one go - from a frontend, or a `.mgl`
  entry - went straight to the game's split layout, so the core's full-screen
  picture was never seen at all. It is held for three seconds first, the way a
  console holds its own boot screen before the game starts, and then the
  layout replaces it. `core_bootscreen_time` in the settings, in milliseconds;
  `0` goes straight to the layout as before. The hold is measured from the
  moment the artwork is actually on the panel, so the transition in front of
  it does not eat into it. A game loaded into a core that is already running
  is unaffected - the artwork has been up all along, and there is nothing to
  introduce.
- **The end of the boot animation is smoother.** The loading bar finishing its
  sweep and the version number fading out used to run at the same time, and
  the bar visibly stuttered as it left the panel: each step of the version
  fade blacks half the band and re-renders the text into it, which is a much
  heavier frame than the bar's own few columns. They run one after the other
  now - the comet leaves the panel, then the version fades - which is the
  order they already read in, and neither drops frames.

## 0.5.0b — 2026-09-23

- **Every setting is in the Scripts menu now.** **tty2oledplus_settings** grew
  from 24 settings to 35, so there is nothing left that can only be changed by
  editing a file over SSH. New in it: whether the display is mounted upside
  down, whether cores with more than one picture vary between them, which
  serial port the display is on, where your games live, the debug log, and -
  under a new **Advanced** heading - the timings for how often the daemon looks
  for a loaded game, for `update_all`, and for another program handing the
  display back.
- **Four things are deliberately still not offered**, and the test suite holds
  the list: the baud rate and the serial line settings, because the firmware is
  fixed at 115200 and a different value can only break the link between the
  MiSTer and the display; and the three paths the installer sets, because
  those are where it put things rather than settings. Everything else in the
  user half of `tty2oled-system.ini` must now be reachable from the menu or the
  suite fails - so a setting added in a later release cannot quietly ship
  without a way to change it.
- **Longer values can be typed.** The editor's text boxes were capped at 32
  characters for every setting, which is why the list of places your games can
  be was not offered before - it is longer than that. The cap is per setting
  now.

## 0.4.10b — 2026-09-23

- **One artwork format.** The pack is now a single folder of greyscale `.gsc`
  pictures. Upstream shipped five - `GSC`, `XBM`, `XBM_TEXT`, `GSC_US`,
  `XBM_US` - with three settings choosing between them, which was never a
  feature: `.gsc` was added after the 1bpp `.xbm` and the conversion was left
  half-finished. It is finished now. The fifteen pictures that existed only as
  `.xbm` were converted and look exactly as they did; nothing else in those
  folders was reachable. `USE_GSC_PICTURE`, `USE_TEXT_PICTURE` and
  `USE_US_PICTURE` are gone, and leaving them in your user ini is harmless.
- **What was in the folders that went**, since deleting artwork deserves
  showing your working: `GSC_US` held one file, byte-identical to the `GSC`
  one beside it. `XBM_US` held three genuinely different pictures - US branding,
  Genesis rather than Mega Drive - but all three also existed in `GSC`, and the
  search order put `XBM_US` first, so switching US pictures on *downgraded*
  those cores from 16 greys to black-and-white to get it. `XBM_TEXT` was not
  searched at all unless you turned it on, and its eight exclusive cores
  already fell through to the display drawing the core name as text - which is
  what those pictures are. Of `XBM`'s 373 files, 351 were duplicates of a `.gsc`
  the search found first, and 7 were `_alt` variants that could never be picked.
- **Your own pictures still win.** Drop a `.gsc` named after the core into
  `pics_pri` and it replaces the packaged one, exactly as before -
  `tools/png2gsc.py --banner` makes one from a PNG. `<core>_alt1.gsc` and
  friends are still diced between when `USE_RANDOM_ALT` is on.
- **One core stops showing a transfer error.** `invinco.gsc` in upstream's pack
  is corrupt - 6976 bytes of what renders as static rather than a picture - so
  the display drew its transfer-error bitmap every time that core was loaded.
  There is nothing there to repair, so it is removed; the core now shows its
  name as text, like any other core without artwork. Every one of the remaining
  1905 pictures is a full 8192 bytes, and the test suite checks that.
- The pack is 1905 files and 82MB, down from 2322 and 87MB - about 12MB packed
  either way, so `tty2oledplus_update --pics` is no slower or faster.

## 0.4.9b — 2026-09-23

- **The screensaver is gone.** Upstream's moving-logo screensaver - the five
  picture screens, the starfield and the flying toasters - is removed from the
  firmware and from the settings. It never worked properly beside this fork's
  game display: its idle timer was reset only by the picture paths, and a
  metadata screen is not one, so on a console game it would take the panel
  after its start delay and never give it back until you changed core - a game
  change was not enough. Brightness dimming (`DIM_AFTER`) and the side swap
  (`FLIP_MINUTES`) are what protect the panel now, and unlike the screensaver
  they leave the game on screen. `SCREENSAVER` and its seven
  `SCREENSAVER_SCREEN_*` settings no longer do anything; leaving them in your
  user ini is harmless. The firmware still accepts `CMDSAVER` and `CMDSWSAVER`
  and ignores them, so a daemon older than the firmware, and MiSTer SAM, do
  not paint the command on the panel as text.
- **SD mode is gone.** `USBMODE` selected a serial protocol that no firmware in
  this repository speaks, and every feature this fork has was switched off when
  it was set to `no`. The setting, its guards and the command-line arguments
  that set it are removed.
- **The pre-0.4.8b updater name is no longer published.** 0.4.8b shipped
  `update_tty2oledplus.sh` one last time so installs predating the Scripts-menu
  rename could reach it; as promised, that copy is dropped here. An install
  that has updated at least once since 0.4.8b has the new name and is
  unaffected. One still on 0.4.7b or earlier has to be installed again by hand,
  with `tty2oledplus_install.sh` from this release.
- **Sleep mode is a mutex, and is treated as one.** `/tmp/tty2oled_sleep` is
  how another program claims the display; MiSTer SAM takes it for a whole
  attract session and drives the panel itself. SAM also writes a deadline into
  the file, which nothing has ever read - so a SAM that was killed left the
  display frozen on whatever it drew last, until you removed the file by hand
  or restarted the daemon. The deadline is honoured now, with a minute's grace
  past it before the display is taken back. Coming back is a full redraw, which
  also puts right the screensaver setting SAM changes behind your back. The
  wait no longer blocks for ever, and no longer spins on a MiSTer without
  inotify-tools.
- **`tty2oledplus_update` refuses to run while something else has the
  display**, rather than updating over it. It asks the display its version and
  may reflash it, and a flash landing while another program is writing is the
  one failure here that needs a USB cable and a workstation to undo. It says
  what to stop, and how to clear the file if it was simply left behind.
- **`SHOW_CONSOLE_SPLIT` is removed.** It was in the ini, the README and the
  settings editor, and no script ever read it: turning it off did nothing. The
  console split layout is what a console game looks like, and `SHOW_METADATA`
  is the switch that turns the whole thing off.
- **The settings file is shorter.** Upstream's changelog for it, a prompt
  helper and seventeen colour variables nothing called, and eight settings that
  were read by nothing - including one defined twice with two different values
  - are all out. Nothing that was doing anything was removed.

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
