# dat2index.awk - pull one field out of a libretro-database clrmamepro .dat.
#
#   awk -v field=releaseyear -f tools/dat2index.awk "Nintendo - ....dat"
#
# Emits one TAB-separated record per game that has both a CRC and the field:
#
#   CRC32 <TAB> comment <TAB> value
#
# The input looks like this, and nothing else in the file is at column 0:
#
#   game (
#   	comment "10-Yard Fight (Japan)"
#   	releaseyear "1985"
#   	rom ( crc 44AA3EEB )
#   )
#
# The rom line carries its own parens but is indented, so a ")" at column 0 is
# unambiguously the end of a game block.

function unquote(line,    first, last) {
  first = index(line, "\"")
  if (first == 0) return ""
  last = length(line)
  while (last > first && substr(line, last, 1) != "\"") last--
  if (last <= first) return ""
  return substr(line, first + 1, last - first - 1)
}

BEGIN {
  FS = "[ \t]+"
  if (field == "") {
    print "dat2index.awk: -v field=<name> is required" > "/dev/stderr"
    exit 2
  }
  emitted = 0
}

/^game[ \t]*\(/ { comment = ""; value = ""; crc = ""; inGame = 1; next }

!inGame { next }

/^\)/ {
  if (crc != "" && value != "") {
    gsub(/\t/, " ", comment)
    gsub(/\t/, " ", value)
    print crc "\t" comment "\t" value
    emitted++
  }
  inGame = 0
  next
}

{
  # $1 is empty on indented lines because the tab is a separator, so look at
  # the first non-blank token instead of assuming a column.
  key = $1
  if (key == "") key = $2

  if (key == "comment" || key == "name") {
    # "name" is the fallback: a few dats label the title that way, and the
    # canonical No-Intro name is what we want either way. comment wins.
    if (key == "comment" || comment == "") comment = unquote($0)
  }
  else if (key == field) {
    value = unquote($0)
  }
  else if (key == "rom") {
    if (match($0, /crc[ \t]+[0-9A-Fa-f]+/)) {
      crc = substr($0, RSTART, RLENGTH)
      sub(/^crc[ \t]+/, "", crc)
      crc = toupper(crc)
    }
  }
}

END {
  if (emitted == 0) exit 1
}
