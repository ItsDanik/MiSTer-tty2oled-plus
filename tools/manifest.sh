# What a tty2oled+ install is made of. Sourced, not run.
#
# Two things put an install on a MiSTer - deploy-mister.sh from a working copy,
# and the release installer from a GitHub release - and they must agree on
# what that is. Both read the lists from here, so a script added to one cannot
# be missing from the other.

# Go into the install folder and are replaced on every install.
#
# tty2oled-user.ini is deliberately absent. It holds the user's own settings,
# it is sourced after tty2oled-system.ini so it overrides these files, and
# copying the repo's copy over it would wipe their configuration.
#
# S60tty2oled and tty2oled-read.sh both name the install folder outright - they
# have to, since they run before any ini is read - so this fork's copies are the
# ones that know about /media/fat/tty2oledplus. A stock copy left behind in a
# moved install would go looking for the old folder and find nothing.
MANIFEST_FILES="tty2oled.sh tty2oled-meta.sh tty2oled-system.ini
                S60tty2oled tty2oled-read.sh"

# Tools that run on the MiSTer. They land in the install folder flat, without
# the tools/ prefix.
# png2gsc.py is here as well as being a workstation tool: the settings editor
# turns pics/boot.png into the stored boot screen on the MiSTer itself, and
# its standard-library PNG backend is there so that needs nothing installed.
# tty2oledplus_scrape.py is Scrape metadata's worker, which the menu below
# drives and which runs on its own over SSH. tty2oledplus_syscheck.py is the
# daemon's system update check, run in the background. tty2oledplus_scummvm.py
# builds ScummVM's games index and icons, in the background too - importing
# png2gsc.py and the scraper's fold(), which is why they sit beside it.
# tty2oledplus_dvd.py reads a DVD's titles and chapters off the disc and asks
# Wikipedia what it is, in the background beside the DVD core; it imports the
# scraper's fold() and database helpers.
# tty2oledplus_rss.py reads the feed whose headlines run under the menu's
# picture, in the background too, with the scraper's fold() again.
# tty2oledplus_preview.sh shows a setting on the display while the settings
# utility changes it; it sources the daemon for the functions that send.
# tty2oled-port.sh is sourced by the daemon, S60tty2oled and the tools that
# talk to the display: which port it is on, and our own node to write through.
MANIFEST_TOOLS="tools/tty2oled-diag.sh tools/flash-mister.sh tools/fw-segments.py
                tools/tty2oled-capture.sh tools/tty2oled-bootimg.sh tools/tty2oled-boothook.sh
                tools/png2gsc.py tools/tty2oledplus_scrape.py tools/tty2oledplus_syscheck.py
                tools/tty2oledplus_scummvm.py tools/tty2oled-port.sh tools/tty2oledplus_dvd.py
                tools/tty2oledplus_rss.py tools/tty2oledplus_preview.sh
                tools/tty2oledplus_ui.sh"

# The one thing in an install that is compiled: the settings utility that
# draws on the framebuffer, which tty2oledplus_settings.sh starts from the
# Scripts menu. tools/build-config.sh builds it (gitignored, as the firmware
# is). A release is not packed without it; a deploy from a working copy that
# has not built it goes without, and Settings is then dialog's menus.
MANIFEST_BIN="tools/settings-ui/build/tty2oledplus_config"

# What the launcher opens: the updater, the settings editor, the
# uninstaller and the scraper's menu. They live in the install folder, not in the Scripts menu -
# since 0.6.3b the menu carries the launcher alone - and the launcher runs
# them from there.
#
# The updater is the one file an install cannot simply copy over: run from
# the launcher, it *is* ${INSTALL}/tty2oledplus_update.sh while it runs, so it
# places itself by rename at the end of the run, never in place.
MANIFEST_APPS="tools/tty2oledplus_update.sh tools/tty2oledplus_settings.sh
               tools/tty2oledplus_uninstall.sh tools/tty2oledplus_scrape.sh"

# Installed only when the MiSTer has none, because the user edits them.
MANIFEST_DEFAULTS="coretypes.ini tty2oled-user.ini"

# The one entry in /media/fat/Scripts: the launcher. The release carries it
# inside the scripts archive as well, and S60tty2oled places it from there on
# every start - which is how a MiSTer updated by an installer older than the
# launcher still ends up with it in its menu, and loses the three entries it
# replaces.
MANIFEST_MENU="tools/tty2oledplus.sh"
