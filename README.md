# tty2oled+

*A game-aware OLED display for the **[MiSTer FPGA]**.*

Fork of **[tty2oled]**, adding extra features like game metadata display.

An SSD1322 OLED panel connects to the MiSTer over USB and shows what you are
playing: artwork for the core, the game's title, the year it came out, who made
it, and — for arcade boards — everything the `.mra` knows.

![The console layout: "Now playing", the game title, its details, and the
system's icon beside them](docs/img/console-nes.png)

## What is on screen

**Console cores** get a split layout: the title, then the fields you asked for,
with an icon for the system beside them. A title too wide for the column
scrolls; more fields than rows and they take turns, the pips by the header
counting the pages.

![Five fields on four rows: System and Year pinned, Region and Format
paging](docs/img/console-paging.png)

Every few minutes the two halves swap sides, so no region of the panel holds
the same lit pixels all day.

![The same layout mirrored: icon left, text right](docs/img/console-flipped.png)

**Arcade cores** alternate the artwork with an info card, one step every
`METADATA_INTERVAL` seconds — artwork, each page of the card in turn, then the
artwork again.

![NBA Jam's marquee artwork](docs/img/arcade-art.png)

![Card page one: year, manufacturer, region, orientation, core, author, set and
MAME version](docs/img/arcade-card-1.png)

![Card page two: players, controls and button names, under the pinned
row](docs/img/arcade-card-2.png)

**Computer cores** show the core's artwork full-screen, and nothing else, yet.  
Computer metadata support coming in the future.

![The C64 core's artwork, full screen](docs/img/computer-art.png)

**At power-on** the panel says which firmware it is running while it waits for
the MiSTer, with a sweep to show it is alive and waiting. The picture is yours
if you have stored one.

![The boot screen: the MiSTer wordmark, the build version, and the sweep
bar](docs/img/boot.png)

**While an update runs** the panel says so instead of leaving stale artwork up,
whether it is `update_all` or tty2oled+ updating itself.

![The message "Updating System ..." above the sweep bar](docs/img/busy.png)

Pictures cross-fade by default, and the panel dims itself after a couple of
minutes of nothing happening, waking on the next thing the MiSTer sends.

## What you need

- A **tty2oled display with an ESP32** — classic ESP32 or S3 — driving an
  SSD1322 256x64 panel, in **USB mode**. (An ESP8266 has too little RAM for
  the game display; the SD and Standard sketch variants are not covered.)
- A MiSTer that is **online**, for the install.

## Installing

1. Download **[tty2oledplus_install.sh]** from the latest release.
2. Copy it to `/media/fat/Scripts` on the MiSTer's SD card — over the network
   share, over FTP, or with the card in your computer.
3. On the MiSTer: **Scripts → tty2oledplus_install**.
4. **Reboot.** MiSTer only reads the setting the installer changed at boot.

The installer fetches the newest release and checks every file against the
release's checksums. Then it:

- installs the scripts, the title index, the system icons and the core artwork
  into `/media/fat/tty2oledplus`
- asks the display which board it is and flashes the matching firmware — only
  when the display is running a different version, and never by guessing
- sets `log_file_entry=1` in the `[MiSTer]` section of `MiSTer.ini`, which is
  what makes MiSTer report the loaded game, and remembers what was there before
- starts the display, and adds the line to `/media/fat/linux/user-startup.sh`
  that starts it on every boot
- leaves **tty2oledplus_settings**, **tty2oledplus_update** and
  **tty2oledplus_uninstall** in the Scripts menu, and removes itself

**Over SSH**, instead of the Scripts menu, it is one line:

```sh
curl -fsSL --cacert /etc/ssl/certs/cacert.pem \
  https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/tty2oledplus_update.sh | bash
```

If you want to manally name it the board:
`... | bash -s -- --board lolin32` (or `esp32de`, `esp32s3`).

### Updating

Run **tty2oledplus_update** from the Scripts menu. Your `tty2oled-user.ini` and
`coretypes.ini` are never overwritten, The firmware is flashed on every release,
but the custom boot image is kept.

### Uninstalling

Run **tty2oledplus_uninstall** from the Scripts menu. It stops the display,
removes the install folder, the start line in `user-startup.sh` and every
Scripts entry it put there, clears any boot image stored on the display, puts
`MiSTer.ini` back as it found it, and removes itself. `--keep-settings` saves your two ini files
first; `--dry-run` only lists what would go.

[tty2oledplus_install.sh]: https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/tty2oledplus_install.sh

## Where the game details come from

The title comes from the filename. The year, publisher, genre and developer come
from an index that is installed with everything else — built from
**[libretro-database]**, offline, no API key and no account. MiSTer writes the
loaded ROM's CRC32 (or a disc serial) to `/tmp/GAMEID`, and that is the key; a
miss costs only the extra fields, and the title still shows.

| Systems | What you get |
|---|---|
| 27 cartridge systems — NES, SNES, Mega Drive, Game Boy and Advance, N64, Master System, TurboGrafx-16, the Ataris, and more | title, region, year, publisher, genre, developer |
| Neo Geo | title, year, publisher — from the MAME set, it being arcade hardware |
| PlayStation, Saturn, Mega CD, 3DO, PC Engine CD | title and region only |

Disc systems are a limit of the source: the
cartridge metadata sets carry release dates and publishers, and the disc set
carries neither.

Arcade cores do not use the index at all — everything on the card is read
straight out of the `.mra` file the core was started from.

Cores are named on screen the way your MiSTer menu names them, from `names.txt`
if you have one.

## Settings

Run **tty2oledplus_settings** from the Scripts menu. Everything worth changing
is in there — what the display shows, which details appear under a game, how
bright the panel is and when it dims, how one picture replaces the last —
picked from menus, with what each one does written beside it.

Nothing is written until you save, and saving restarts the display so the new
settings are on the panel before you leave the menu. Anything left at its
default is not written at all, so a later release that changes a default is
followed rather than overridden by a value you never chose.

The editor needs a terminal to draw in: from the Scripts menu that means
`fb_terminal=1` in `MiSTer.ini`, which is the default. Otherwise press F9 for
the console, or run it over SSH:

```sh
/media/fat/Scripts/tty2oledplus_settings.sh
```

### The files underneath

Two files, both in `/media/fat/tty2oledplus/`, read in this order:

1. `tty2oled-system.ini` — shipped with the release and **replaced on every
   update**. Do not edit this one.
2. `tty2oled-user.ini` — yours. Never overwritten, and read second, so anything
   in it wins.

So to change something the editor does not cover, put it in the user ini and
restart the display:

```sh
echo 'USE_RANDOM_ALT="no"' >> /media/fat/tty2oledplus/tty2oled-user.ini
/media/fat/tty2oledplus/S60tty2oled restart
```

The editor writes to the same file, and leaves anything it does not know about
— including your own comments — exactly where it found it.

Settings the display itself acts on — brightness, dimming, side swapping — are
sent over when it restarts, so nothing needs reflashing.

| Setting | Default | Meaning |
|---|---|---|
| `SHOW_METADATA` | `yes` | Master switch. `no` shows core artwork only. |
| `METADATA_INTERVAL` | `12` | Arcade: seconds per screen — artwork, each card page in turn, then the artwork again. `0` never swaps. |
| `METADATA_FIELDS` | `System Year Genre Region Format` | Which console fields show, and in what order. Four fit at once; the rest page every 2.5s. Available: System Region Year Company Genre Developer Format. |
| `METADATA_PINNED` | `System Year` | Fields that stay put while the rest page under them. |
| `COMPACT_YEAR_COMPANY` | `yes` | Fold the publisher into the year: `1989, Acclaim` on one row. |
| `ARCADE_FIELDS` | `Year Manufacturer Region Orientation Core Author Set MAME` | Short arcade fields, paired two to a row. |
| `ARCADE_FIELDS_WIDE` | `Players Controls Buttons` | Arcade fields whose values need a row of their own. |
| `ARCADE_PINNED` | `Year Manufacturer` | The grid row repeated above each wide page. |
| `CONTRAST` | `255` | Panel brightness, `0`–`255`. |
| `CONTRAST_FADE_MS` | `800` | How long a brightness change takes to fade, `0`–`4000` ms. `0` jumps. |
| `DIM_AFTER` | `120` | Seconds with nothing new on screen before the panel dims. `0` never dims. |
| `DIM_CONTRAST` | `80` | Brightness to dim to, on the same scale as `CONTRAST`. |
| `DIM_FADE_MS` | `6000` | How long going dim takes, `0`–`10000` ms — slow enough not to notice. Waking takes `CONTRAST_FADE_MS`. |
| `DIM_WAKE` | `-1` | Brightness to wake to. `-1` means `CONTRAST`. |
| `FLIP_MINUTES` | `5` | How often the console layout swaps sides. `0` never swaps. |
| `TRANSITION` | `-2` | How one picture replaces the last. `-2` cross-fades, `-1` picks a random wipe each time, `0` none, `1`–`23` one particular wipe — the system ini lists all of them by name. |
| `TRANSITION_FADE_MS` | `800` | With `-2`: each fade, out and in. `0`–`4000` ms. |
| `TRANSITION_BLANK_MS` | `1000` | With `-2`: how long the panel stays black between them. `0`–`4000` ms. |
| `BOOTSCREEN_AS_MENU` | `yes` | The boot screen doubles as the menu's picture. `no` shows the artwork pack's `MENU` picture instead. |
| `UPDATE_ALL_SCREEN` | `yes` | Say so on the panel while `update_all` runs. |
| `UPDATE_ALL_TEXT` | `Updating System ...` | What it says while the download is running. |
| `SELF_UPDATE_SCREEN` | `yes` | The same, while tty2oled+ updates itself. |
| `ROTATE` | `no` | Turn the whole display 180°. |
| `USE_NAMES_TXT` | `yes` | Name cores as your MiSTer menu names them. |
| `GAME_ROOTS` | SD, `usb0`–`usb5`, `cifs` | Where your games live, searched in order. |

`coretypes.ini`, in the same folder, says which cores are consoles, which are
computers and which are arcade. It is only installed when you do not already
have one, so anything you add to it survives an update.

## Making it yours

### A boot screen of your own

The boot screen lives in the display's own flash, so it appears with the MiSTer
switched off or the SD card out. It is **256x54**, not the full 256x64: the
bottom ten rows are the firmware's, where it prints the build version and runs
the sweep.

Converting a picture needs `png2gsc.py` from this repository, which runs on
your computer; storing it is done on the MiSTer:

```sh
./tools/png2gsc.py --boot splash.png          # on your computer -> splash.gsc

/media/fat/tty2oledplus/tty2oled-bootimg.sh set splash.gsc    # on the MiSTer
/media/fat/tty2oledplus/tty2oled-bootimg.sh status            # what is stored
/media/fat/tty2oledplus/tty2oled-bootimg.sh clear             # back to the built-in one
```

Storing one takes a few seconds and no reflash.

### Icons

`/media/fat/tty2oledplus/pics_pri/ICON/` holds the icon drawn for each system —
26 of them, covering the systems most people play:

> 3DO · Atari 2600 / 5200 / 7800 · Atari Lynx · Game Boy · Game Boy Color ·
> Game Boy Advance · Game Gear · Genesis · Jaguar · Mega CD · Mega Drive ·
> N64 · NES · Neo Geo · PlayStation · Saturn · Master System · SNES ·
> 32X · TurboGrafx-16 · TurboGrafx-16 CD · Virtual Boy · WonderSwan ·
> WonderSwan Color

The twenty console cores without one still get the split layout and everything
in it — just a black panel where the icon would be. To draw your own, work at
**86x64** in sixteen shades of grey, and name the file after the core, as
MiSTer names it: `MegaDrive.gsc`, `GBA.gsc`, `NES.gsc`.

```sh
./tools/png2gsc.py --out MegaDrive.gsc megadrive.png
# then copy it into /media/fat/tty2oledplus/pics_pri/ICON/
```

Core artwork — the full-screen picture — is **256x64**, named the same way, and
goes in `/media/fat/tty2oledplus/pics/GSC/`:

```sh
./tools/png2gsc.py --banner --out MegaDrive.gsc art.png
```

Either is picked up on the next core change: no flashing and no uploading.

`png2gsc.py` fits and centres a picture on black rather than stretching it,
scaling up as well as down. `--stretch` fills the frame, `--dither` suits
photographs and hurts flat pixel art, and `--invert` is for art drawn
dark-on-light. It uses Pillow if you have it and ImageMagick otherwise.

Everything on this panel is sixteen shades of grey — no colour, no
transparency. Draw in that palette and the conversion is exact.

## Credit and licence

Original project (tty2oled): venice1200
GPLv3, as that is.

Game metadata comes from **[libretro-database]** and the MAME project.

<!----------------------------------------------------------------------------->

[MiSTer FPGA]: https://github.com/MiSTer-devel
[libretro-database]: https://github.com/libretro/libretro-database
[tty2oled]: https://github.com/venice1200/MiSTer_tty2oled