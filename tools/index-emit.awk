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

# The region: the first (...) group made only of region names - "(USA)",
# "(USA, Europe)", "(Europe, Australia)" - as written, short forms spelt out.
# The same rule as clean_romname's _region_of, name for name.
function region_of(name,    s, g, n, parts, i, p, u, out, ok) {
  s = name
  while (match(s, /\([^)]*\)/)) {
    g = substr(s, RSTART + 1, RLENGTH - 2)
    s = substr(s, RSTART + RLENGTH)
    n = split(g, parts, ",")
    out = ""; ok = (n > 0)
    for (i = 1; i <= n && ok; i++) {
      p = trim(parts[i]); u = toupper(p)
      if (!(u in REGION)) { ok = 0; break }
      if (u == "US") p = "USA"; else if (u == "EU") p = "Europe"; else if (u == "JP") p = "Japan"
      out = out (out == "" ? "" : ", ") p
    }
    if (ok && out != "") return out
  }
  return ""
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

BEGIN {
  FS = "\t"; OFS = "|"
  nr = split("WORLD|USA|EUROPE|JAPAN|ASIA|UK|US|EU|JP|GERMANY|FRANCE|SPAIN|ITALY|AUSTRALIA|KOREA|BRAZIL|SWEDEN|NETHERLANDS|CANADA|CHINA|TAIWAN|RUSSIA|SCANDINAVIA|HONG KONG|GREECE|PORTUGAL|DENMARK|NORWAY|FINLAND|POLAND|BELGIUM|AUSTRIA|SWITZERLAND|LATIN AMERICA|NEW ZEALAND|INDIA|MEXICO|ARGENTINA|IRELAND|SOUTH AFRICA", RL, "|")
  for (i = 1; i <= nr; i++) REGION[RL[i]] = 1
}

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
