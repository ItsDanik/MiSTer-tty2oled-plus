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

## Requirements

- Any tty2oled build on an **ESP32** (classic, or S3). ESP8266 keeps upstream
  behaviour — the display code needs more RAM than it has.
- **USB mode.** The SD and Standard sketch variants are not covered yet.
- `log_file_entry=1` in `MiSTer.ini`. It defaults to off, and without it MiSTer
  never publishes which game is loaded.

## Install

Firmware first, then the scripts. New firmware with old scripts behaves exactly
like upstream, so each step is safe on its own.

```bash
# 1. Build the firmware (installs arduino-cli and everything else it needs)
./tools/build-tty2oled.sh MiSTer_SSD1322_USB lolin32     # or esp32de / esp32s3

# 2. Copy build-out-lolin32/MiSTer_SSD1322_USB.ino.merged.bin to the MiSTer,
#    then flash it from there with the daemon stopped:
/media/fat/tty2oled/S60tty2oled stop
python /tmp/esptool.py --chip esp32 --port /dev/ttyUSB0 --baud 921600 \
  --before default_reset --after hard_reset write_flash \
  --compress --flash_mode dio --flash_freq 80m --flash_size detect \
  0x0 /media/fat/tty2oled/MiSTer_SSD1322_USB.ino.merged.bin

# 3. Copy the scripts to /media/fat/tty2oled/ and restart
chmod +x /media/fat/tty2oled/tty2oled.sh /media/fat/tty2oled/tty2oled-meta.sh
/media/fat/tty2oled/S60tty2oled restart
```

Not sure which board you have? Ask the display — the installer's menu lists
"DevKit" twice, and a generic ESP32 DevKit V4 is the `lolin32` profile:

```bash
. /media/fat/tty2oled/tty2oled-system.ini
stty -F ${TTYDEV} ${BAUDRATE} ${TTYPARAM}
echo "CMDHWINF" > ${TTYDEV}; read -t5 R < ${TTYDEV}; echo "$R"
```

**Do not overwrite `tty2oled-user.ini`** — it holds your settings, and it is
sourced after `tty2oled-system.ini` so they take precedence.

## Settings

Added to `tty2oled-system.ini`; override them in `tty2oled-user.ini`.

| Setting | Default | Meaning |
|---|---|---|
| `SHOW_METADATA` | `yes` | Master switch. `no` gives upstream behaviour exactly. |
| `METADATA_INTERVAL` | `12` | Arcade: seconds between artwork and info card. `0` never swaps. |
| `SHOW_CONSOLE_SPLIT` | `yes` | Console: text left, icon right. |
| `METADATA_WARN` | `yes` | Warn once at startup if `log_file_entry` is missing. |
| `METADATA_POLL` | `5` | Seconds before re-checking for state files that did not exist yet. |

Two switches are shipped **off** so neither updater can overwrite this fork:
`SCRIPT_UPDATE="no"` here, and set `TTY2OLED_UPDATE="no"` in your user ini to
stop `update_all` reflashing stock firmware. Repoint `REPOSITORY_URL` at your
own fork before turning either back on.

## Troubleshooting

```bash
echo 'debug="true"' >> /media/fat/tty2oled/tty2oled-user.ini
/media/fat/tty2oled/S60tty2oled restart
tail -f /tmp/tty2oled
```

`./tools/tty2oled-diag.sh`, run on the MiSTer right after loading a game, prints
every state file with its timestamp and shows what the metadata layer made of
them. That is usually faster than reading the log.

## Tests

```bash
./tests/run-all.sh
```

201 checks across four suites, needing no MiSTer, no ESP32 and no serial port.
The firmware suites compile the display code against stubs under
`-Wall -Wextra -Werror` with ASan/UBSan and a real 8192-byte framebuffer.

## Not done yet

- **Console icons.** None ship, so the icon panel is blank. 86x64 `.gsc` files
  in `pics/ICON/`, overridable from `pics_pri/ICON/`.
- **CRC32 title index**, to replace filename-derived titles with canonical ones.
- SD and Standard sketch variants.

## Credit and licence

All of the hard parts — the hardware, the sketch, the picture pipeline, the
transitions, the daemon — are venice1200's and the tty2oled contributors'. This
fork only adds a metadata layer on top. GPLv3, like upstream.

Documentation for the underlying project lives in the
**[upstream wiki][Documentation]**.

<!----------------------------------------------------------------------------->

[MiSTer FPGA]: https://github.com/MiSTer-devel
[venice1200/MiSTer_tty2oled]: https://github.com/venice1200/MiSTer_tty2oled
[Documentation]: https://github.com/venice1200/MiSTer_tty2oled/wiki
