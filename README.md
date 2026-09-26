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
whether it is `update_all` or tty2oled+ updating itself. Those screens arrive
with the same transition everything else uses; the bar that runs during the
download simply appears, since by then nothing is being replaced.

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
- leaves one entry in the Scripts menu, **tty2oledplus**, and removes itself

**Over SSH**, instead of the Scripts menu, it is one line:

```sh
curl -fsSL --cacert /etc/ssl/certs/cacert.pem \
  https://github.com/ItsDanik/MiSTer-tty2oled-plus/releases/latest/download/tty2oledplus_update.sh | bash
```

If you want to manally name it the board:
`... | bash -s -- --board lolin32` (or `esp32de`, `esp32s3`).

### The Scripts menu entry

**Scripts → tty2oledplus** opens a menu you can drive with a pad — arrows and
one button:

- **Settings** — what the display shows, see [Settings](#settings)
- **Update** — install the newest release
- **Uninstall** — remove it all again

The three live in `/media/fat/tty2oledplus` beside everything else, so your
Scripts folder carries one line of ours rather than three. An install from
before 0.6.3b had them as three separate entries, and updating replaces them
with this one - except **tty2oledplus_update**, which the old updater puts
back on its way out and which goes at the next reboot.

With `fb_terminal=0` in `MiSTer.ini` there is no screen to draw a menu on, so
the entry runs **Update** straight away.

### Updating

**Scripts → tty2oledplus → Update.** Your `tty2oled-user.ini` and
`coretypes.ini` are never overwritten, The firmware is flashed on every release,
but the custom boot image is kept.

### Uninstalling

**Scripts → tty2oledplus → Uninstall.** It asks twice before it
does anything — whether to go on, and what to do with the files that are yours
rather than ours — with arrows and one button, no typing.

Choosing **Keep them** copies your settings (`tty2oled-user.ini`,
`coretypes.ini`), the banners in `pics/user` and your `pics/boot.png` into
`/media/fat/tty2oledplus-saved` before the rest goes. **Cancel** on that
question stops the whole thing.

Then it stops the display, removes the install folder, the start line in
`user-startup.sh` and its Scripts entry, clears any boot image stored on the
display, and puts `MiSTer.ini` back as it found it. The display's firmware is
left alone.

`--yes` skips both questions, `--dry-run` only lists what would go. With
`fb_terminal=0` there is no screen to ask on, so it refuses rather than
guessing — run it with `--yes` if that is what you meant.

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

**Scripts → tty2oledplus → Settings.** **Every setting is in
there** — what the display shows, which details appear under a game, how bright
the panel is and when it dims, how one picture replaces the last, what happens
while updates run, and the connection and troubleshooting settings under
*Advanced* — picked from menus, with what each one does written beside it.

Four things are deliberately not offered, because they are not choices: the
baud rate and serial line settings (the firmware is fixed at 115200, so a
different rate can only break the link), and the three paths the installer
sets, which point at files it put there.

Nothing is written until you save, and saving restarts the display so the new
settings are on the panel before you leave the menu. Anything left at its
default is not written at all, so a later release that changes a default is
followed rather than overridden by a value you never chose.

The editor needs a terminal to draw in: from the Scripts menu that means
`fb_terminal=1` in `MiSTer.ini`, which is the default. Otherwise press F9 for
the console, or run it over SSH:

```sh
/media/fat/Scripts/tty2oledplus.sh settings
```

The same works for the other two — `tty2oledplus.sh update`, `tty2oledplus.sh
uninstall` — with their options after the name.

### The files underneath

Two files, both in `/media/fat/tty2oledplus/`, read in this order:

1. `tty2oled-system.ini` — shipped with the release and **replaced on every
   update**. Do not edit this one.
2. `tty2oled-user.ini` — yours. Never overwritten, and read second, so anything
   in it wins.

So to change something the editor does not cover, put it in the user ini and
restart the display:

```sh
echo 'RANDOMIZE_ALT_BANNERS="yes"' >> /media/fat/tty2oledplus/tty2oled-user.ini
/media/fat/tty2oledplus/S60tty2oled restart
```

The editor writes to the same file, and leaves anything it does not know about
— including your own comments — exactly where it found it.

Settings the display itself acts on — brightness, dimming, side swapping — are
sent over when it restarts, so nothing needs reflashing.

| Setting | Default | Meaning |
|---|---|---|
| `SHOW_METADATA` | `yes` | Master switch. `no` shows core artwork only. |
| `core_bootscreen_time` | `3000` | A console core launched with its game already chosen holds its own full-screen artwork this long, in ms, before the game's details replace it. `0` goes straight to the details. A game loaded into a running core is unaffected. |
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
| `FLIP_MINUTES` | `5` | How often the console layout swaps sides, so no part of the panel stays lit. The swap uses `TRANSITION`. `0` never swaps. |
| `TRANSITION` | `-2` | How one picture replaces the last. `-2` cross-fades, `-1` picks a random wipe each time, `0` none, `1`–`23` one particular wipe, `30`–`39` a cross-fade that also slides the picture — the system ini and the settings editor list all of them by name. |
| `TRANSITION_FADE_MS` | `800` | With `-2`: each fade, out and in. `0`–`4000` ms. |
| `TRANSITION_BLANK_MS` | `1000` | With `-2`: how long the panel stays black between them. `0`–`4000` ms. |
| `BOOTSCREEN_AS_MENU` | `yes` | The boot screen doubles as the menu's picture. `no` shows the artwork pack's `MENU` picture instead. |
| `UPDATE_ALL_SCREEN` | `yes` | Say so on the panel while `update_all` runs. |
| `UPDATE_ALL_TEXT` | `Updating System ...` | What it says while the download is running. |
| `SELF_UPDATE_SCREEN` | `yes` | The same, while tty2oled+ updates itself. |
| `ROTATE` | `no` | Turn the whole display 180°. |
| `USE_NAMES_TXT` | `yes` | Name cores as your MiSTer menu names them. |
| `PRIORITIZE_USER_BANNERS` | `yes` | Look in `pics/user` before the artwork pack, so a picture you put there replaces the shipped one. `no` searches the pack first. |
| `RANDOMIZE_ALT_BANNERS` | `no` | Where a core has `_altN` alternatives, dice between them on every load — upstream's behaviour. Off shows the same picture every time. |
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

**The easy way, with no workstation at all:** put a PNG at
`/media/fat/tty2oledplus/pics/boot.png` and run **tty2oledplus → Settings → Boot
screen → Use my pics/boot.png**. It converts and stores it for you, and the
same menu puts the built-in logo back.

Draw it **256x54** in up to 16 shades of grey — an indexed PNG with a 16-step
greyscale palette converts exactly. Anything else is scaled to fit and centred
on black, so it still works, just not pixel for pixel. The bottom ten rows of
the panel are not yours: that is where the firmware runs its sweep and prints
the build version, whatever picture is stored.

`pics/boot.png` is yours and stays put — no update touches it, so after a
reflash the same menu entry sends it again.

### Artwork

All of it lives under `/media/fat/tty2oledplus/pics/`, one kind per folder:

| folder | what | size |
|---|---|---|
| `pics/banner` | the core artwork pack — the full-screen picture | 256x64 |
| `pics/alt` | its alternatives, `<core>_alt1.gsc`, `_alt2.gsc` … | 256x64 |
| `pics/icon` | the console icons, for the split layout | 86x64 |
| `pics/user` | **yours** | 256x64 |
| `pics/boot.png` | **yours** — the boot screen, see below | 256x54 |

The first three are the release's and are replaced by every update. `pics/user`
is yours and no update ever touches it — which is what makes it the place to
put a picture of your own, rather than editing `pics/banner` and having the
next release undo it. A file there named after the core replaces the pack's
(`PRIORITIZE_USER_BANNERS`, on by default).

A core with alternatives shows the same one every time unless you turn
`RANDOMIZE_ALT_BANNERS` on, which dices between the picture and its
alternatives on each load. Upstream does that by default; this fork does not,
because a core that looked one way yesterday looking another way today reads
as a fault rather than a feature.

### Icons

`pics/icon` holds the icon drawn for each system —
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
# then copy it into /media/fat/tty2oledplus/pics/icon/
```

Core artwork — the full-screen picture — is **256x64**, named the same way, and
goes in `/media/fat/tty2oledplus/pics/user/`:

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