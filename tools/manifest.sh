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
MANIFEST_TOOLS="tools/tty2oled-diag.sh tools/flash-mister.sh tools/fw-segments.py
                tools/tty2oled-capture.sh tools/tty2oled-bootimg.sh tools/tty2oled-boothook.sh
                tools/png2gsc.py"

# What the launcher opens: the updater, the settings editor and the
# uninstaller. They live in the install folder, not in the Scripts menu -
# since 0.6.3b the menu carries the launcher alone - and the launcher runs
# them from there.
#
# The updater is the one file an install cannot simply copy over: run from
# the launcher, it *is* ${INSTALL}/tty2oledplus_update.sh while it runs, so it
# places itself by rename at the end of the run, never in place.
MANIFEST_APPS="tools/tty2oledplus_update.sh tools/tty2oledplus_settings.sh
               tools/tty2oledplus_uninstall.sh"

# Installed only when the MiSTer has none, because the user edits them.
MANIFEST_DEFAULTS="coretypes.ini tty2oled-user.ini"

# The one entry in /media/fat/Scripts: the launcher. The release carries it
# inside the scripts archive as well, and S60tty2oled places it from there on
# every start - which is how a MiSTer updated by an installer older than the
# launcher still ends up with it in its menu, and loses the three entries it
# replaces.
MANIFEST_MENU="tools/tty2oledplus.sh"
