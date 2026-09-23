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

# Installed only when the MiSTer has none, because the user edits them.
MANIFEST_DEFAULTS="coretypes.ini tty2oled-user.ini"

# Go into /media/fat/Scripts, not the install folder: the Scripts menu is
# where a user looks for them, and the uninstaller in particular has to outlive
# the folder it removes. Both installers put them there, and the release
# carries them inside the scripts archive as well - S60tty2oled places them
# from there on every start, which is how a MiSTer updated by an installer
# older than any of these names still ends up with them in its menu.
#
# Named so they sort together in the Scripts menu, which is alphabetical:
# install, settings, uninstall, update.
MANIFEST_MENU="tools/tty2oledplus_update.sh tools/tty2oledplus_settings.sh
               tools/tty2oledplus_uninstall.sh"
