# The display's serial port: which one it is, and how to write to it.
# Sourced, not run - by tty2oled.sh, S60tty2oled, flash-mister.sh,
# tty2oledplus_update.sh and tty2oled-bootimg.sh. Each keeps working without
# it, as it did before it existed.
#
# Two problems, both from sharing a MiSTer with other USB serial devices -
# a Zaparoo NFC reader most of all.
#
# Which port. Linux numbers ttyUSB0, ttyUSB1 ... in the order the adapters
# show up, and that order can change from one boot to the next: with a
# reader plugged in, the display can come up as ttyUSB1 and TTYDEV's
# /dev/ttyUSB0 is the reader. So once the display has answered CMDHWINF on a
# port, that port's USB identity is remembered (port_remember), read from
# /sys - vendor and product, serial, where it is plugged in, interface - and
# next time the port with that identity is used, whatever it is numbered
# (port_resolve). Nothing is written to any port to find it: probing the
# others is what Zaparoo does to us. Only a kernel-numbered TTYDEV is
# resolved; a /dev/serial/by-id/... link set by hand is already stable, and
# is taken as it is.
#
# How to write. See ttynode.

PORT_ID_FILE="${PORT_ID_FILE:-${TTY2OLED_PATH:-/media/fat/tty2oledplus}/.display-port}"
SYS_ROOT="${SYS_ROOT:-/sys}"

# Our own node for the display's port, into TTYNODE - or the device itself
# where none can be made or opened. Linux stamps a tty's device file with the
# time whenever it is written through that file, and Zaparoo re-probes any
# port whose time has changed as a PN532 NFC reader: its bytes land on the
# panel, and in the middle of a flash they break it. Written through a node
# of our own, /dev/ttyUSB0 keeps its time. In /tmp: /run is nodev, and a node
# in /dev might be enumerated as a port itself.
ttynode() {  # ttynode <device>
  local dev="${1}" mm="" node="${TTYALIAS:-/tmp/tty2oledplus.tty}" i
  TTYNODE="${dev}"; TTYNODE_WHY=""; TTYNODE_ERR=""
  [ -c "${dev}" ] || { TTYNODE_WHY="${dev} is not a device"; return 0; }
  mm="$(stat -L -c '%t %T' "${dev}" 2>/dev/null)" || { TTYNODE_WHY="stat failed"; return 0; }
  if ! [ -c "${node}" ] || [ "$(stat -c '%t %T' "${node}" 2>/dev/null)" != "${mm}" ]; then
    # No -m: straight after boot, mknod made the node and then failed to set
    # its mode ("cannot set permissions ...: Invalid argument"), and the
    # node went unused. The mode is set on its own, and not needed; the
    # attempts are repeated for a few seconds in case of anything else.
    # TTYNODE_ERR keeps what mknod said.
    local err=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
      rm -f "${node}" 2>/dev/null
      err="$(mknod "${node}" c "$((16#${mm% *}))" "$((16#${mm#* }))" 2>&1)" \
        && { chmod 600 "${node}" 2>/dev/null; break; }
      TTYNODE_ERR="${err:-mknod failed}"
      sleep 0.3
    done
    [ -c "${node}" ] || { TTYNODE_WHY="${TTYNODE_ERR:-mknod ${node} failed}"; return 0; }
  fi
  [ -c "${node}" ] || { TTYNODE_WHY="${node} is not a device"; return 0; }
  # Opened the way stty opens a port, without waiting on it. A plain open of
  # a port nothing has configured yet blocks, and fails when another program
  # closes it meanwhile - Zaparoo's first probe, at boot, in the same second.
  # Ours not opening while the device does is a nodev mount: the device, then.
  # Neither opening is the port busy right now, and ours is as good as it.
  for i in 1 2 3 4 5; do
    stty -F "${node}" >/dev/null 2>&1 && { TTYNODE="${node}"; return 0; }
    sleep 0.2
  done
  stty -F "${dev}" >/dev/null 2>&1 && { TTYNODE_WHY="${node} would not open, ${dev} did"; return 0; }
  TTYNODE="${node}"
}

# A tty's USB identity, into PORT_ID: vendor:product:serial:usb path:interface
# (10c4:ea60:0001:1-1.2.4:00). The serial may be empty - CH340s have none.
# Returns 1 for a tty that is not on USB, or not there.
port_id() {  # port_id <device path or tty name>
  local name="" d="" iface=""
  PORT_ID=""
  name="$(readlink -f "${1}" 2>/dev/null)"; name="${name:-${1}}"; name="${name##*/}"
  d="$(readlink -f "${SYS_ROOT}/class/tty/${name}/device" 2>/dev/null)" || return 1
  [ -n "${d}" ] && [ -d "${d}" ] || return 1
  # Up from the port to the USB device, noting the interface on the way.
  while [ -n "${d}" ] && [ "${d}" != "/" ] && ! [ -r "${d}/idVendor" ]; do
    [ -r "${d}/bInterfaceNumber" ] && iface="$(<"${d}/bInterfaceNumber")"
    d="${d%/*}"
  done
  [ -r "${d}/idVendor" ] || return 1
  local v="" p="" s=""
  v="$(<"${d}/idVendor")"; p="$(<"${d}/idProduct")"
  [ -r "${d}/serial" ] && s="$(<"${d}/serial")"
  PORT_ID="${v}:${p}:${s//:/}:${d##*/}:${iface}"
}

# Where the remembered display is now, into PORT_FOUND (/dev/<tty>). The
# same vendor, product and interface are required; the same place it is
# plugged into counts most, the same serial next - two adapters of one make
# can share a serial (a CP2102's is often 0001), never a socket. A best that
# is not unique is no answer. Returns 1 with nothing remembered or found.
port_find() {
  local want="" f n score best=-1 ties=0 wv wp ws wpath wif v p s path ifn
  PORT_FOUND=""
  [ -r "${PORT_ID_FILE}" ] && IFS= read -r want <"${PORT_ID_FILE}"
  [ -n "${want}" ] || return 1
  IFS=: read -r wv wp ws wpath wif <<<"${want}"
  for f in "${SYS_ROOT}"/class/tty/ttyUSB* "${SYS_ROOT}"/class/tty/ttyACM*; do
    [ -e "${f}" ] || continue
    n="${f##*/}"
    port_id "${n}" || continue
    IFS=: read -r v p s path ifn <<<"${PORT_ID}"
    [ "${v}:${p}:${ifn}" = "${wv}:${wp}:${wif}" ] || continue
    score=0
    [ "${path}" = "${wpath}" ] && score=$((score + 2))
    [ -n "${ws}" ] && [ "${s}" = "${ws}" ] && score=$((score + 1))
    if [ "${score}" -gt "${best}" ]; then best="${score}"; ties=1; PORT_FOUND="/dev/${n}"
    elif [ "${score}" -eq "${best}" ]; then ties=$((ties + 1)); fi
  done
  [ "${ties}" -eq 1 ] || { PORT_FOUND=""; return 1; }
  [ -n "${PORT_FOUND}" ]
}

# The display answered on <device>: remember where it is. Written only when
# it changed - the install folder is on the SD card.
port_remember() {  # port_remember <device>
  local old=""
  port_id "${1}" || return 0
  [ -r "${PORT_ID_FILE}" ] && IFS= read -r old <"${PORT_ID_FILE}"
  [ "${old}" = "${PORT_ID}" ] && return 0
  printf '%s\n' "${PORT_ID}" >"${PORT_ID_FILE}" 2>/dev/null
}

# TTYDEV, resolved: where the remembered display is now, if TTYDEV is a
# kernel-numbered port and it is found. Anything else leaves it alone.
port_resolve() {
  case "${TTYDEV}" in
    /dev/ttyUSB[0-9]*|/dev/ttyACM[0-9]*) ;;
    *) return 0 ;;
  esac
  port_find || return 0
  [ "${PORT_FOUND}" = "${TTYDEV}" ] || TTYDEV="${PORT_FOUND}"
}
