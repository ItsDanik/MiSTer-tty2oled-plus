// bandnote.h - the frontends' band, and the notice that lives in it.
//
// The menu, MisterZine and Degauss are where you choose what to play, and the
// panel shows them the way the boot screen is shown: a picture 54 rows tall,
// and the ten rows under it - the boot screen's band - left to the firmware.
// The daemon marks such a picture "band" (CMDCOR,<core>,<effect>,band; the
// menu's CMDBOOTPIC always is one) and the firmware blacks those ten rows
// whatever the picture had there, so a 256x64 banner is shown cut down to 54
// rows until it is replaced with one drawn for the shape.
//
// What goes in the band is a notice: one line of the 5x7 font in BNOTE_GREY,
// centred - "TTY2OLED+ update available" when the daemon has found a newer
// release. CMDNOTE,<text> sets it and CMDNOTE, with nothing after the comma
// takes it away. It is kept until then, across every picture, and belongs
// only to the frontends: a core's picture has no band and never shows it.
//
// How it appears depends on what the panel is doing when it arrives:
//
//   - on a frontend's picture, it fades in on its own over BNOTE_FADE_MS, grey
//     stepping up a level at a time, and fades out the same way when taken
//     away. Nothing else on the panel moves.
//   - anywhere else it waits, and is part of the next frontend picture from
//     the start: composed into the frame the transition animates towards, so
//     it arrives with the picture - faded in with it, wiped in with it.
//
// When no notice is waiting, the band can show the date and time instead
// (0.7.8b): CMDCLOCK,<left>|<right> gives two strftime formats, the first
// drawn at the band's left edge and the second at its right - "30/09/26" and
// "17:34" - in the notice's font and grey; CMDCLOCK, with nothing after it
// turns it off. The time is CMDSETTIME's, local time as the daemon sends it,
// counted on from there by millis(). It comes and goes as a notice does -
// fading in on a frontend's picture, out for a notice - but a new minute is
// drawn over the old in place: a fade every minute would be a flicker.
//
// And a feed can take turns with the clock (0.8.4b): CMDRSS gives the
// headlines of an RSS feed, and the band then shows the date and time for
// rssClockMs, fades it out, and runs the headlines through as a ticker - in
// from the right edge, a dot between one and the next - for rssScrollMs. When
// that time is up no new headline is let in, and the ones already on the
// panel run out to the left edge; only then does the clock fade back in, for
// its whole time again. The next turn carries on with the headline after the
// last one shown. A notice outranks both: while one is waiting there is no
// ticker, and one arriving mid-ticker takes the band at once.
//
// The band is shared. At power-on the boot screen's outro runs there (the
// sweep finishing, the version fading), and a busy screen's bar runs there;
// the notice waits for both, and for any picture transition, rather than
// animating one band twice at once.
//
// Needs, from the sketch or the tests: oled, u8g2, logoBin, srcBin,
// actPicType, GSC, DispWidth, millis(), oled_setfont(), oled_transition(),
// tfState/TF_IDLE/tfRenderHook (fadetransition.h), meta_transitionToBuffer()
// (metadisplay.h), boActive (bootoutro.h), busyActive (busybar.h),
// boot_quietCommand(), and the BOOT_BAND_* constants (bootscreen.h).

#ifndef BANDNOTE_H
#define BANDNOTE_H

#include <time.h>                                     // the clock: gmtime_r, strftime

// The line: the 5x7 font the busy screen's status line uses, at half the
// panel's brightness - it is a footnote to the picture, not part of it.
#define BNOTE_FONT     0
#define BNOTE_GREY     8
#define BNOTE_ASC      6                              // 5x7: rows above the baseline
// Centred in the band's ten rows: seven rows of glyph with its descent leave
// three blank, and the odd one goes above, between the notice and the
// picture: rows 54..55 blank, the glyphs 56..61, descent 62, row 63 blank.
// u8g2 draws a glyph on the rows above its baseline and the descent on it -
// measured with the real library (tools/screenshots), not assumed.
#define BNOTE_GAP      ((BOOT_BAND_H - (BNOTE_ASC + 1) + 1) / 2)   // 2 blank rows above
#define BNOTE_TOP      (BOOT_BAND_Y + BNOTE_GAP)       // 56, its first row
#define BNOTE_Y        (BNOTE_TOP + BNOTE_ASC)          // 62, its baseline: the descent's row
#define BNOTE_COLS      51                             // 256 pixels of 5x7
// A grey level every BNOTE_FADE_MS / BNOTE_GREY: the version's fade at the end
// of the boot screen takes a second, and so does this.
#define BNOTE_FADE_MS  1000
#define BNOTE_STEP_MS  (BNOTE_FADE_MS / BNOTE_GREY)
// The clock's two halves sit this far in from the panel's edges.
#define BCLOCK_MARGIN  2
#define BCLOCK_FMT_MAX 40                             // CMDCLOCK's text, both formats
#define BCLOCK_SEP     '\t'                           // between them, once formatted

// The feed's ticker. 5x7 is a fixed-width font, so a headline's width is its
// length, and only the characters on the panel are drawn.
#define RSS_MAX        2048                           // CMDRSS's bytes kept, all headlines
#define RSS_ITEMS_MAX  48                             // ...and how many headlines
#define RSS_GAP        20                             // pixels between two, the dot in the middle
#define RSS_DOT        2                              // the dot's side
#define RSS_CATCHUP    3                              // pixels a late tick may make up
#define RSS_CLOCK      0                              // the turns: the clock is up...
#define RSS_LEAVE      1                              // ...fading out for the ticker...
#define RSS_SCROLL     2                              // ...and the ticker running

#ifdef HAS_METADISPLAY

char          noteText[BNOTE_COLS + 1]  = "";   // what CMDNOTE last said
char          noteDrawn[BNOTE_COLS + 1] = "";   // what is in the band now, at noteLevel
int           noteLevel  = 0;                 // its grey on the panel; 0 is not there
unsigned long noteLast   = 0;                 // when it last stepped
bool          bandShown  = false;             // the panel shows a frontend's picture
bool          picBand    = false;             // the picture just received is one

char          clockFmt[BCLOCK_FMT_MAX + 1] = "";  // "<left>|<right>"; empty: no clock
long          clockEpoch = 0;                 // CMDSETTIME's local time...
unsigned long clockSetAt = 0;                 // ...and millis() when it came
bool          clockSet   = false;
char          clockText[BNOTE_COLS + 1] = ""; // formatted, BCLOCK_SEP between halves
long          clockTextAt = -1;               // the second it was formatted for

char          rssBuf[RSS_MAX + 1] = "";       // the headlines, a NUL after each
uint16_t      rssOff[RSS_ITEMS_MAX];          // where each starts...
uint16_t      rssLen[RSS_ITEMS_MAX];          // ...and its length
int           rssCount    = 0;                // 0: no feed
unsigned long rssClockMs  = 30000;            // the clock's turn; 0 is the ticker alone
unsigned long rssScrollMs = 60000;            // the ticker's, before it runs out
unsigned long rssStepMs   = 25;               // ms a pixel
int           rssPhase    = RSS_CLOCK;
unsigned long rssAt       = 0;                // when this turn's time began
unsigned long rssLast     = 0;                // when the ticker last moved
int           rssFirst    = 0;                // the leftmost headline on the panel, or the next in
int           rssX        = 0;                // its left edge
int           rssAdmit    = 0;                // headlines let in, counting from rssFirst
bool          rssClosing  = false;            // time is up: no more are let in
bool          rssLead     = true;             // rssFirst opened this turn: no dot before it

// Is the band the ticker's rather than the clock's? Not while a notice waits.
static bool band_rssHolds(void) {
  return rssCount > 0 && !noteText[0] && (rssPhase != RSS_CLOCK || rssClockMs == 0);
}

// The clock as it reads now, into clockText - formatted once a second at
// most. False when there is no clock: none asked for, or no time yet.
static bool band_clockNow(void) {
  if (!clockFmt[0] || !clockSet) { clockText[0] = '\0'; return false; }
  const long t = clockEpoch + (long)((millis() - clockSetAt) / 1000UL);
  if (t == clockTextAt && clockText[0]) return true;
  clockTextAt = t;
  char fmt[BCLOCK_FMT_MAX + 1];
  strcpy(fmt, clockFmt);
  char *right = strchr(fmt, '|');
  if (right) *right++ = '\0';
  time_t tt = (time_t)t;
  struct tm tmv;
  gmtime_r(&tt, &tmv);                        // the daemon sends local time
  char l[BNOTE_COLS + 1] = "", r[BNOTE_COLS + 1] = "";
  if (fmt[0] && !strftime(l, sizeof(l), fmt, &tmv)) l[0] = '\0';
  if (right && right[0] && !strftime(r, sizeof(r), right, &tmv)) r[0] = '\0';
  // Both halves on one line of the band: the right one is cut first.
  size_t ll = strlen(l);
  if (ll > BNOTE_COLS - 1) { ll = BNOTE_COLS - 1; l[ll] = '\0'; }
  size_t room = BNOTE_COLS - 1 - ll;
  if (strlen(r) > room) r[room] = '\0';
  // No "|", one piece: centred, as a notice is.
  memcpy(clockText, l, ll);                   // ll + 1 + strlen(r) <= BNOTE_COLS
  clockText[ll] = '\0';
  if (right) { clockText[ll] = BCLOCK_SEP; strcpy(clockText + ll + 1, r); }
  return true;
}

// The band's line now: the notice, else the clock, else nothing - and
// nothing while the feed's ticker has its turn. Into out,
// BNOTE_COLS + 1 long; true when it is the clock.
static bool band_want(char *out) {
  if (noteText[0]) { strcpy(out, noteText); return false; }
  if (band_rssHolds()) { out[0] = '\0'; return false; }
  if (band_clockNow()) { strcpy(out, clockText); return true; }
  out[0] = '\0';
  return false;
}

// The band as it should look at `level`: black, and the notice over it.
//
// A notice is centred; the clock is its two halves, one to each edge.
static void band_drawNote(int level) {
  oled.fillRect(0, BOOT_BAND_Y, DispWidth, BOOT_BAND_H, SSD1322_BLACK);
  if (level <= 0 || !noteDrawn[0]) return;
  oled_setfont(BNOTE_FONT);
  u8g2.setForegroundColor((uint16_t)level);
  const char *sep = strchr(noteDrawn, BCLOCK_SEP);
  if (sep) {
    char l[BNOTE_COLS + 1];
    size_t n = (size_t)(sep - noteDrawn);
    memcpy(l, noteDrawn, n); l[n] = '\0';
    if (l[0]) { u8g2.setCursor(BCLOCK_MARGIN, BNOTE_Y); u8g2.print(l); }
    if (sep[1]) {
      u8g2.setCursor(DispWidth - BCLOCK_MARGIN - u8g2.getUTF8Width(sep + 1), BNOTE_Y);
      u8g2.print(sep + 1);
    }
  } else {
    int x = (DispWidth - u8g2.getUTF8Width(noteDrawn)) / 2;
    if (x < 0) x = 0;
    u8g2.setCursor(x, BNOTE_Y);
    u8g2.print(noteDrawn);
  }
  u8g2.setForegroundColor(SSD1322_WHITE);
}

// The clock's turn starts over: with every frontend picture, and whenever the
// ticker is taken off the band.
static void band_rssRest(void) {
  rssPhase = RSS_CLOCK;
  rssAt    = millis();
}

// The ticker as it stands: the band black, and every headline that has been
// let in drawn from rssX on, lets in those reaching the right edge unless the
// time is up.
static void band_rssDraw(void) {
  oled.fillRect(0, BOOT_BAND_Y, DispWidth, BOOT_BAND_H, SSD1322_BLACK);
  oled_setfont(BNOTE_FONT);
  u8g2.setForegroundColor((uint16_t)BNOTE_GREY);
  const int cw = (int)u8g2.getUTF8Width("M");
  int x = rssX, i = rssFirst;
  for (int k = 0; x < DispWidth; k++) {
    if (k >= rssAdmit) {
      if (rssClosing) break;
      rssAdmit++;
    }
    const int dx = x - RSS_GAP / 2 - RSS_DOT / 2;
    if (!(k == 0 && rssLead) && dx >= 0 && dx + RSS_DOT <= DispWidth)
      oled.fillRect(dx, BNOTE_TOP + (BNOTE_ASC - RSS_DOT) / 2, RSS_DOT, RSS_DOT, (uint16_t)BNOTE_GREY);
    // Only what is on the panel: from the character the left edge cuts.
    const int len = (int)rssLen[i];
    int c0 = (x < 0 && cw > 0) ? (-x) / cw : 0;
    if (c0 < len) {
      char part[BNOTE_COLS + 3];
      const int cx = x + c0 * cw;
      int n = cw > 0 ? (DispWidth - cx) / cw + 1 : len;
      if (n > len - c0) n = len - c0;
      if (n > (int)sizeof(part) - 1) n = (int)sizeof(part) - 1;
      memcpy(part, rssBuf + rssOff[i] + c0, (size_t)n);
      part[n] = '\0';
      u8g2.setCursor(cx, BNOTE_Y);
      u8g2.print(part);
    }
    x += len * cw + RSS_GAP;
    i = (i + 1) % rssCount;
  }
  u8g2.setForegroundColor(SSD1322_WHITE);
}

// The feed's turns, from band_tick with the band free. True while the ticker
// has the band and band_tick has nothing to do there.
static bool band_rssTick(void) {
  const unsigned long now = millis();
  if (!rssCount || noteText[0]) {             // no feed, or a notice takes the band
    if (rssPhase == RSS_SCROLL) {
      oled.fillRect(0, BOOT_BAND_Y, DispWidth, BOOT_BAND_H, SSD1322_BLACK);
      oled.display();
    }
    band_rssRest();
    return false;
  }
  if (rssPhase == RSS_CLOCK) {
    // Its time counts from when it is up, not from when it started coming.
    if (rssClockMs && band_clockNow() && noteLevel < BNOTE_GREY) { rssAt = now; return false; }
    if (now - rssAt >= rssClockMs) rssPhase = RSS_LEAVE;   // band_want: nothing, so it fades out
    return false;
  }
  if (rssPhase == RSS_LEAVE) {
    if (noteLevel > 0) return false;          // still going out
    noteDrawn[0] = '\0';
    rssPhase   = RSS_SCROLL;
    rssAt      = now;
    rssLast    = now;
    rssX       = DispWidth;
    rssAdmit   = 0;
    rssClosing = false;
    rssLead    = true;
    return true;
  }
  if (now - rssLast < rssStepMs) return true;
  unsigned long px = (now - rssLast) / rssStepMs;
  if (px > RSS_CATCHUP) { px = RSS_CATCHUP; rssLast = now; }
  else                  rssLast += px * rssStepMs;
  rssX -= (int)px;
  oled_setfont(BNOTE_FONT);
  const int cw = (int)u8g2.getUTF8Width("M");
  while (rssAdmit > 0 && rssX + (int)rssLen[rssFirst] * cw <= 0) {   // off the left edge
    rssX += (int)rssLen[rssFirst] * cw + RSS_GAP;
    rssFirst = (rssFirst + 1) % rssCount;
    rssAdmit--;
    rssLead = false;
  }
  band_rssDraw();
  oled.display();
  // Time up: those on the panel run out, and the clock's turn starts then -
  // its whole time, however long the last headline took.
  if (now - rssAt >= rssScrollMs) rssClosing = true;
  if (rssClosing && rssAdmit == 0) { band_rssRest(); return false; }
  return true;
}

// A frontend's whole frame: the picture in logoBin, and the notice as it
// stands now at full grey. Also the Fade's render hook, so a notice that
// arrives while the old picture is fading out still makes the fade-in.
static void band_render(void) {
  oled.clearDisplay();
  oled.draw4bppBitmap(logoBin);
  band_want(noteDrawn);
  noteLevel = noteDrawn[0] ? BNOTE_GREY : 0;
  band_drawNote(noteLevel);
}

// Black the band of the picture in logoBin: a frontend's picture is 54 rows,
// whatever shape the file it came from was.
static void band_crop(void) {
  memset(logoBin + BOOTIMG_BYTES, 0, BOOT_PANEL_BYTES - BOOTIMG_BYTES);
}

// Transition to the frontend's picture in logoBin, notice and all. The
// text-screen idiom: rendered into the framebuffer, copied to metaBin, and
// the transition pointed there. metaBin is free - a frontend's picture is
// always preceded by CMDMETAOFF, and with metadata off there is no card.
void band_showPicture(int effect) {
  band_crop();
  bandShown = true;
  band_rssRest();
  meta_beginTransitionText(effect);        // the old picture, while it is there
  band_render();
  tfRenderHook = band_render;              // taken by a Fade, dropped by a wipe
  meta_transitionToBuffer(effect);
}

// The power-on screen is the menu's picture already, and its outro is running
// in the band: there is nothing to transition, and the notice waits for the
// band to empty before it fades in.
void band_heldUnder(void) {
  band_crop();
  bandShown = true;
  band_rssRest();
  noteDrawn[0] = '\0';
  noteLevel = 0;
}

// CMDCOR, or CMDAPD: did this picture come marked as a frontend's? The third
// field, after the effect - which firmware before 0.7.1b reads past, since the
// effect is taken with toInt() and that stops at the comma.
void band_parsePicture(const char *cmd) {
  const char *p = strchr(cmd, ',');                // after the command
  p = p ? strchr(p + 1, ',') : nullptr;            // after the core name
  p = p ? strchr(p + 1, ',') : nullptr;            // after the effect
  picBand = p && strcmp(p + 1, "band") == 0;
}

// CMDNOTE,<text> - the rest of the line; nothing after the comma is none.
// Draws nothing here: band_tick fades it in or out when the band is free.
void band_noteParse(const char *cmd) {
  const char *text = strchr(cmd, ',');
  text = text ? text + 1 : "";
  size_t len = strlen(text);
  if (len > BNOTE_COLS) len = BNOTE_COLS;
  memcpy(noteText, text, len);
  noteText[len] = '\0';
}

// CMDCLOCK,<left>|<right> - the clock's formats, the rest of the line;
// nothing after the comma is no clock. Draws nothing: band_tick does.
void band_clockParse(const char *cmd) {
  const char *f = strchr(cmd, ',');
  f = f ? f + 1 : "";
  size_t len = strlen(f);
  if (len > BCLOCK_FMT_MAX) len = BCLOCK_FMT_MAX;
  memcpy(clockFmt, f, len);
  clockFmt[len] = '\0';
  clockTextAt = -1;
}

// CMDRSS,<clock s>,<scroll s>,<px/s>,<bytes> - the feed's turns and speed,
// and how many bytes of headlines follow the line; -1 when it is not that.
// The read is the sketch's, like a description's.
long band_rssParse(const char *cmd) {
  long c = 0, s = 0, v = 0, n = -1;
  if (sscanf(cmd, "CMDRSS,%ld,%ld,%ld,%ld", &c, &s, &v, &n) < 4 || n < 0) return -1;
  if (c < 0) c = 0;
  if (c > 3600) c = 3600;
  if (s < 1) s = 1;
  if (s > 3600) s = 3600;
  if (v < 5) v = 5;
  if (v > 200) v = 200;
  rssClockMs  = (unsigned long)c * 1000UL;
  rssScrollMs = (unsigned long)s * 1000UL;
  rssStepMs   = 1000UL / (unsigned long)v;
  return n;
}

// The bytes that followed: headlines, a newline between them. Printable ASCII
// is kept, anything else is a space; none at all is no feed. A ticker that is
// running is taken off - band_tick clears it - and starts again from the top
// at its next turn.
void band_rssSet(const char *text, size_t n) {
  if (n > RSS_MAX) n = RSS_MAX;
  rssCount = 0;
  rssFirst = 0;
  size_t o = 0, start = 0;
  for (size_t i = 0; i <= n; i++) {
    const char ch = i < n ? text[i] : '\n';
    if (ch != '\n') { rssBuf[o++] = (ch >= ' ' && ch <= '~') ? ch : ' '; continue; }
    if (o > start && rssCount < RSS_ITEMS_MAX) {
      rssOff[rssCount] = (uint16_t)start;
      rssLen[rssCount] = (uint16_t)(o - start);
      rssCount++;
      rssBuf[o++] = '\0';
      start = o;
    } else {
      o = start;                               // an empty line, or one too many
    }
  }
  if (rssPhase == RSS_SCROLL) { rssAdmit = 0; rssClosing = true; }
}

// CMDSETTIME,<local seconds since 1970>: what the clock counts on from.
void band_setTime(long epoch) {
  clockEpoch  = epoch;
  clockSetAt  = millis();
  clockSet    = epoch > 0;
  clockTextAt = -1;
}

// Called for every command before it is handled. Anything that draws takes
// the panel away from the frontend's picture; CMDBOOTPIC and CMDCOR put one
// back up, and say so themselves. CMDNOTE is on the quiet list.
void band_noteCommand(const char *cmd) {
  if (strncmp(cmd, "CMDBOOTPIC", 10) == 0 || !boot_quietCommand(cmd)) bandShown = false;
}

// A step of the notice's fade, when the band is the notice's to draw in.
void band_tick(void) {
  if (!bandShown) return;
  if (tfState != TF_IDLE || boActive || busyActive || pf_active()) return;
  if (band_rssTick()) return;                 // the feed's ticker has the band
  char want[BNOTE_COLS + 1];
  const bool wantClock = band_want(want);
  bool changed = strcmp(noteDrawn, want) != 0;
  // The clock turning over: drawn again where it stands, at the grey it is.
  if (changed && wantClock && noteLevel > 0 && strchr(noteDrawn, BCLOCK_SEP)) {
    strcpy(noteDrawn, want);
    band_drawNote(noteLevel);
    oled.display();
    return;
  }
  // A different text goes out before the new one comes in.
  if (changed && noteLevel == 0) { strcpy(noteDrawn, want); changed = false; }
  int target = (!changed && noteDrawn[0]) ? BNOTE_GREY : 0;
  if (noteLevel == target) return;
  unsigned long now = millis();
  if (now - noteLast < BNOTE_STEP_MS) return;
  noteLast = now;
  noteLevel += (target > noteLevel) ? 1 : -1;
  band_drawNote(noteLevel);
  oled.display();
}

#else   // !HAS_METADISPLAY - no buffer to compose in: frontends are plain pictures

bool bandShown = false;
bool picBand   = false;
void band_showPicture(int effect)          { oled_transition(effect); }
void band_heldUnder(void)                  { }
void band_parsePicture(const char *cmd)    { (void)cmd; }
void band_noteParse(const char *cmd)       { (void)cmd; }
void band_clockParse(const char *cmd)      { (void)cmd; }
void band_setTime(long epoch)              { (void)epoch; }
long band_rssParse(const char *cmd) {
  long c, s, v, n = -1;
  return (sscanf(cmd, "CMDRSS,%ld,%ld,%ld,%ld", &c, &s, &v, &n) < 4 || n < 0) ? -1 : n;
}
void band_rssSet(const char *text, size_t n) { (void)text; (void)n; }
void band_noteCommand(const char *cmd)     { (void)cmd; }
void band_tick(void)                       { }

#endif  // HAS_METADISPLAY

#endif  // BANDNOTE_H
