# mamexml2index.awk - pull one hardware family out of a MAME XML into index
# records.
#
#   awk -v family=neogeo -f tools/mamexml2index.awk "MAME 2003-Plus XML.xml"
#
# Emits the same tagged records index-emit.awk consumes, keyed on the MAME set
# name rather than a CRC:
#
#   year      <TAB> setname <TAB> description <TAB> 1995
#   publisher <TAB> setname <TAB> description <TAB> Video System Co.
#
# Why this file at all: libretro's metadat/{releaseyear,publisher,genre,
# developer} cover cartridge consoles and have no SNK Neo Geo - the AES/MVS
# machine is arcade hardware, so its data lives in the MAME set instead. The
# MiSTer NeoGeo core names its games by title ("Aero Fighters 3"), which is
# what MAME's <description> holds, so the name lookup resolves them.
#
# MAME descriptions often carry both regional titles separated by " / " -
# "Aero Fighters 3 / Sonic Wings 3" - and a romset may use either, so one
# record is emitted per alias and both find the same year and publisher.
#
# Games are selected by romof="<family>", which is how MAME marks a set as
# running on that BIOS. The BIOS set itself has no romof and is skipped.

function emit(tag, key, title, value) {
  if (value == "") return
  gsub(/\t/, " ", title)
  gsub(/\t/, " ", value)
  print tag "\t" key "\t" title "\t" value
}

function unescape(s) {
  gsub(/&amp;/,  "\\&", s)
  gsub(/&lt;/,   "<",   s)
  gsub(/&gt;/,   ">",   s)
  gsub(/&quot;/, "\"",  s)
  gsub(/&apos;/, "'",   s)
  return s
}

function tagvalue(line, tag,    re, v) {
  re = "<" tag ">[^<]*</" tag ">"
  if (!match(line, re)) return ""
  v = substr(line, RSTART + length(tag) + 2, RLENGTH - (2 * length(tag) + 5))
  return unescape(v)
}

BEGIN {
  if (family == "") {
    print "mamexml2index.awk: -v family=<name> is required" > "/dev/stderr"
    exit 2
  }
  emitted = 0
}

# <game name="sonicwi3" romof="neogeo">
/<game / {
  inGame = 0; setname = ""; desc = ""; year = ""; maker = ""
  if (index($0, "romof=\"" family "\"") == 0) next
  if (!match($0, /name="[^"]*"/)) next
  setname = substr($0, RSTART + 6, RLENGTH - 7)
  inGame = 1
  next
}

!inGame { next }

/<description>/ { desc  = tagvalue($0, "description") }
/<year>/        { year  = tagvalue($0, "year") }
/<manufacturer>/{ maker = tagvalue($0, "manufacturer") }

/<\/game>/ {
  if (setname != "" && desc != "") {
    # One record per alias, so a romset using either title resolves.
    n = split(desc, alias, / \/ /)
    for (i = 1; i <= n; i++) {
      t = alias[i]
      sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (t == "") continue
      # The key has to differ per alias or index-emit would keep only the
      # first title for the set.
      k = (i == 1) ? setname : setname "~" i
      emit("year",      k, t, year)
      emit("publisher", k, t, maker)
      emitted++
    }
  }
  inGame = 0
  next
}

END {
  if (emitted == 0) exit 1
}
