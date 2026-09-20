# index-emit.awk - merge tagged metadata records into tty2oled index lines.
#
# Input (TAB separated), any order, many tags per CRC:
#
#   <tag> <TAB> CRC32 <TAB> comment <TAB> value
#
# where tag is one of: year publisher genre developer serial
#
# Output, sorted by CRC:
#
#   CRC32|Title|Region|Year|Publisher|Genre|Developer|Serial
#
# Serial is the disc systems' key. libretro carries PlayStation, Saturn, Sega
# CD, 3DO and PC Engine CD only under metadat/redump, which has name, region
# and serial but none of the four metadata categories - so those indexes have
# a title, a region and a serial, and the year and publisher columns are
# empty. MiSTer writes the disc serial to /tmp/GAMEID, which is what makes
# them findable at all: their CRC is per-track and never matches a .chd.
#
# Title and Region are derived from the No-Intro comment the same way
# clean_romname() in tty2oled-meta.sh derives them from a ROM filename, so an
# index hit and a filename fallback produce the same string for the same game.
# tests/test-index.sh checks the two implementations against each other.

function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}

# Pull the region out of the first (...) group that names one. POSIX ERE is
# leftmost-longest, which is what makes "(USA, Europe)" win over "(USA)" at the
# same position - the same thing grep -oiE does for clean_romname.
function region_of(name,    re, r) {
  re = "\\((World|USA, Europe|USA|Europe|Japan, USA|Japan|Germany|France|Spain|Italy|Australia|Korea|Brazil|Sweden|Netherlands|Canada|China|Taiwan|Asia|UK|US|EU|JP)\\)"
  if (!match(name, re)) return ""
  r = substr(name, RSTART + 1, RLENGTH - 2)
  if (toupper(r) == "US") return "USA"
  if (toupper(r) == "EU") return "Europe"
  if (toupper(r) == "JP") return "Japan"
  return r
}

function clean_title(name,    work, art, i) {
  work = name

  # (...) and [...] groups are metadata, not title.
  gsub(/\([^)]*\)/, "", work)
  gsub(/\[[^]]*\]/, "", work)

  gsub(/_/, " ", work)
  gsub(/[ \t]+/, " ", work)
  work = trim(work)
  sub(/[ \t]*-[ \t]*$/, "", work)
  work = trim(work)

  # "Legend of Zelda, The" -> "The Legend of Zelda"
  split("The A An Le La Les Der Die Das", art, " ")
  for (i = 1; i <= 9; i++) {
    if (work ~ ("," " " art[i] "$")) {
      sub(("," " " art[i] "$"), "", work)
      work = art[i] " " work
      break
    }
  }

  if (work == "") work = trim(name)
  return work
}

BEGIN { FS = "\t"; OFS = "|" }

NF < 4 { next }

{
  tag = $1; crc = toupper($2); comment = $3; value = $4
  if (crc == "") next

  # The comment is identical across categories for the same CRC; keep the
  # first one seen rather than re-deriving the title four times.
  if (!(crc in name)) name[crc] = comment

  if      (tag == "year")      year[crc]      = value
  else if (tag == "publisher") publisher[crc] = value
  else if (tag == "genre")     genre[crc]     = value
  else if (tag == "developer") developer[crc] = value
  else if (tag == "serial")    serial[crc]    = value
}

END {
  for (crc in name) {
    t = clean_title(name[crc])
    r = region_of(name[crc])
    # A record with nothing but a title still earns its place: it upgrades a
    # badly named dump to the canonical title.
    print crc, t, r, year[crc], publisher[crc], genre[crc], developer[crc], serial[crc]
  }
}
