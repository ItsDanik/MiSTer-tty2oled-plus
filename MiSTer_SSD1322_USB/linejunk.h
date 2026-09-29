// A line on the port that is not all ours.
//
// Other programs open the display's port looking for their own hardware.
// Zaparoo's NFC reader auto-detect probes every USB serial port as a PN532:
// wake-up bytes 55 55 00 00 ..., then binary frames, and no newline. They sit
// in the receive buffer until the daemon's next command ends the line, and
// the whole of it used to be taken for text: "UU" (up to the first NUL) drawn
// big over whatever was up, and the command behind it lost - the busy bar's
// label forgotten, the bar stopped.
//
// Nothing the daemon sends has a control character in it, or a byte above
// 0x7E (metasanitize strips them), and every PN532 frame ends with a 0x00.
// So what follows the last such byte is ours: kept if it is a command, and a
// line that was only someone else's bytes is no line at all. Tab and carriage
// return are left alone, as they always were. Pictures and icons are read by
// count after their command line and never come through here.
#ifndef LINEJUNK_H
#define LINEJUNK_H

#include <stddef.h>
#include <string.h>

// Where the line's command starts: 0 for a clean line, past the junk for one
// with a command behind it, -1 for one to ignore.
static inline int line_commandStart(const char *s, size_t len) {
  size_t start = 0;
  bool junk = false;
  for (size_t i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    if ((c < 0x20 && c != '\t' && c != '\r') || c > 0x7E) { junk = true; start = i + 1; }
  }
  if (!junk) return 0;
  if (len - start >= 3 && strncmp(s + start, "CMD", 3) == 0) return (int)start;
  return -1;
}

#endif  // LINEJUNK_H
