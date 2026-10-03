/*
  mediaband.h - the transport band: a disc's place, under the console layout

  Part of the tty2oled game-metadata fork. Included from metadisplay.h, after
  the drawing helpers it uses and before the renderer that calls it.

  ---------------------------------------------------------------------------
  What it is
  ---------------------------------------------------------------------------
  The DVD core plays films, and a film has what a game has not: a place in
  it. CMDMEDIA puts that under the console layout's text - the split layout
  with the disc's icon, as for any console game - in its last two rows:

    row 32..38  Chapter  8/25              the chapter row, before the fields
    row 40..54  two field rows, paged
    row 56..62  > 0:32:25 ======o----- 1:43:39    the band, the panel's width

  The icon beside the text is cut off above the band (MEDIA_ICON_ROWS), so
  the band runs the whole width under both columns.

  The state's icon leads it: a play arrow that flashes while the film plays,
  two bars when paused, a square when stopped, three lines in the disc's
  menu - where there is no time, so the band says so instead of a bar.

  ---------------------------------------------------------------------------
  The clock
  ---------------------------------------------------------------------------
  CMDMEDIA,<state>,<seconds in>,<seconds long>,<chapter>,<chapters>

  The firmware counts the seconds on itself while the state is "playing",
  from when the command arrived - so the daemon sends one when something
  changes (play, pause, a chapter, a seek) and now and then to stay in step,
  not one a second. Nothing after the comma, or state 0, takes the band
  away. A length of 0 is a place the daemon does not know: the band shows the
  state's icon and its name, and no bar.

  Quiet, like CMDHEAD: kept across a new CMDMETA (a disc's description
  arriving late must not take its place away), forgotten by CMDMETAOFF. Not
  activity, except a change of state - someone pressed pause - which wakes a
  dimmed panel as any other button on the MiSTer would.
*/

#ifndef MEDIABAND_H
#define MEDIABAND_H

#define MEDIA_OFF        0
#define MEDIA_PLAY       1
#define MEDIA_PAUSE      2
#define MEDIA_STOP       3
#define MEDIA_MENU       4
#define MEDIA_STILL      5
#define MEDIA_MAX_SECS   359999L        // 99:59:59
#define MEDIA_MAX_CHAPTER 999

// The band is the console's last field row, in the field font, across the
// whole panel; the icon's rows stop one blank row above it.
#define MEDIA_BAND_Y     (CON_FIELD_Y0 + (CON_FIELD_ROWS - 1) * CON_FIELD_PITCH)  // baseline 62
#define MEDIA_BAND_TOP   (MEDIA_BAND_Y - CON_FIELD_ASCENT)                         // 56
#define MEDIA_ICON_ROWS  (MEDIA_BAND_TOP - 1)          // the icon's rows kept above it
#define MEDIA_X          CON_TITLE_X                   // the band's left edge
#define MEDIA_ICON_W     7                             // the state's icon, 7x7
#define MEDIA_ICON_H     (CON_FIELD_ASCENT + 1)        // the glyphs' rows, 56..62
#define MEDIA_GAP        5                             // blank columns between its parts
#define MEDIA_BAR_H      3                             // the bar, centred on the glyphs
#define MEDIA_BAR_Y      (MEDIA_BAND_TOP + (MEDIA_ICON_H - MEDIA_BAR_H) / 2)
#define MEDIA_KNOB_W     2                             // the place on it, full height
#define MEDIA_TRACK      3                             // grey of the bar still to come
#define MEDIA_DIM        8                             // grey of the length and the label
#define MEDIA_BLINK_MS   500                           // the play arrow: lit, dark, lit...
#define MEDIA_LABEL      "Chapter"

long          mediaPos      = 0;        // seconds in, when it arrived
long          mediaTotal    = 0;        // seconds long; 0 unknown
int           mediaChapter  = 0;
int           mediaChapters = 0;
unsigned long mediaAt       = 0;        // millis() when it arrived
bool          mediaRedraw   = false;    // arrived over a layout already up
long          mediaShown    = -2;       // what the band last drew (media_key); -2 nothing

// Seconds in at `now`: counted on while playing, never past the end.
static long media_elapsed(unsigned long now) {
  long s = mediaPos;
  if (mediaState == MEDIA_PLAY) s += (long)((now - mediaAt) / 1000UL);
  if (mediaTotal > 0 && s > mediaTotal) s = mediaTotal;
  if (s > MEDIA_MAX_SECS) s = MEDIA_MAX_SECS;
  return s;
}

// The arrow's half of its flash: lit first, from when the state arrived.
static bool media_lit(unsigned long now) {
  if (mediaState != MEDIA_PLAY) return true;
  return ((now - mediaAt) / MEDIA_BLINK_MS) % 2 == 0;
}

// Everything the band shows that changes by itself, as one number: the
// second, and the arrow's flash. A redraw is due when it differs.
static long media_key(unsigned long now) {
  return media_elapsed(now) * 2 + (media_lit(now) ? 0 : 1);
}

// A time as the length is written, so the two are the same width and the
// bar between them does not move as the seconds go: 1:05:09 beside 1:43:39,
// 05:09 beside 43:39, 5:09 beside 9:59.
static void media_timeText(long s, long like, char *out, size_t n) {
  if (s < 0) s = 0;
  const long h = s / 3600, m = (s % 3600) / 60, sec = s % 60;
  if (like >= 36000)     snprintf(out, n, "%02ld:%02ld:%02ld", h, m, sec);
  else if (like >= 3600) snprintf(out, n, "%ld:%02ld:%02ld", h, m, sec);
  else if (like >= 600)  snprintf(out, n, "%02ld:%02ld", m + h * 60, sec);
  else                   snprintf(out, n, "%ld:%02ld", m + h * 60, sec);
}

static const char *media_stateName(void) {
  switch (mediaState) {
    case MEDIA_PLAY:  return "Playing";
    case MEDIA_PAUSE: return "Paused";
    case MEDIA_STOP:  return "Stopped";
    case MEDIA_MENU:  return "Disc menu";
    case MEDIA_STILL: return "Still";
  }
  return "";
}

// The state's icon, 7x7 at x on the band's glyph rows, out of lines and
// rectangles - the same primitives as the pips.
static void media_drawIcon(int x, unsigned long now) {
  const int y = MEDIA_BAND_TOP;
  switch (mediaState) {
    case MEDIA_PLAY:
    case MEDIA_STILL:
      if (!media_lit(now)) return;
      // A triangle pointing right: columns two by two, 7, 5, 3 and 1 high.
      for (int c = 0; c < MEDIA_ICON_W; c++) {
        const int h = MEDIA_ICON_H - 2 * (c / 2);
        oled.drawFastVLine(x + c, y + (MEDIA_ICON_H - h) / 2, h, SSD1322_WHITE);
      }
      break;
    case MEDIA_PAUSE:
      oled.fillRect(x + 1, y, 2, MEDIA_ICON_H, SSD1322_WHITE);
      oled.fillRect(x + 4, y, 2, MEDIA_ICON_H, SSD1322_WHITE);
      break;
    case MEDIA_STOP:
      oled.fillRect(x, y + 1, MEDIA_ICON_W - 1, MEDIA_ICON_H - 1, SSD1322_WHITE);
      break;
    case MEDIA_MENU:
      for (int r = 0; r < 3; r++)
        oled.drawFastHLine(x, y + r * (MEDIA_ICON_H - 1) / 2, MEDIA_ICON_W, SSD1322_WHITE);
      break;
  }
}

// ---------------------------------------------------------------------------
// media_drawBand - the band, across the panel under both columns. Its rows are
// blacked first: the description scrolls through the rows above, and the icon
// was cut short of them.
// ---------------------------------------------------------------------------
static void media_drawBand(unsigned long now) {
  oled.fillRect(0, MEDIA_BAND_TOP - 1, DispWidth, DispHeight - (MEDIA_BAND_TOP - 1), SSD1322_BLACK);
  mediaShown = media_key(now);
  media_drawIcon(MEDIA_X, now);

  oled_setfont(CON_FIELD_FONT);
  u8g2.setBackgroundColor(SSD1322_BLACK);
  const int tx = MEDIA_X + MEDIA_ICON_W + MEDIA_GAP;

  // No length, or the menu: the state in words, and nothing to measure.
  if (mediaTotal <= 0 || mediaState == MEDIA_MENU) {
    u8g2.setForegroundColor(SSD1322_WHITE);
    meta_drawClipped(media_stateName(), tx, MEDIA_BAND_Y, DispWidth - tx, 0);
    return;
  }

  char in[12], len[12];
  const long el = media_elapsed(now);
  media_timeText(el, mediaTotal, in, sizeof(in));
  media_timeText(mediaTotal, mediaTotal, len, sizeof(len));
  const int inW  = meta_textWidth(in);
  const int lenW = meta_textWidth(len);
  const int lenX = DispWidth - CON_TITLE_X - lenW;

  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setCursor(tx, MEDIA_BAND_Y);
  u8g2.print(in);
  u8g2.setForegroundColor(MEDIA_DIM);
  u8g2.setCursor(lenX, MEDIA_BAND_Y);
  u8g2.print(len);
  u8g2.setForegroundColor(SSD1322_WHITE);

  const int barX = tx + inW + MEDIA_GAP;
  const int barW = lenX - MEDIA_GAP - barX;
  if (barW <= MEDIA_KNOB_W) return;
  int done = (int)((long long)barW * el / mediaTotal);
  if (done > barW) done = barW;
  oled.fillRect(barX, MEDIA_BAR_Y, barW, MEDIA_BAR_H, MEDIA_TRACK);
  if (done > 0) oled.fillRect(barX, MEDIA_BAR_Y, done, MEDIA_BAR_H, SSD1322_WHITE);
  int knob = barX + done - MEDIA_KNOB_W / 2;
  if (knob < barX) knob = barX;
  if (knob > barX + barW - MEDIA_KNOB_W) knob = barX + barW - MEDIA_KNOB_W;
  oled.fillRect(knob, MEDIA_BAND_TOP, MEDIA_KNOB_W, MEDIA_ICON_H, SSD1322_WHITE);
}

// The chapter row, first of the field rows: drawn as a field is - the label
// dimmed, the value on the shared column - but from the band's state, which
// changes without a new CMDMETA.
static void media_drawChapter(int x, int y, int w, int valueOff) {
  char v[16];
  if (mediaChapters <= 0 || mediaState == MEDIA_MENU) snprintf(v, sizeof(v), "-");
  else if (mediaChapter <= 0) snprintf(v, sizeof(v), "-/%d", mediaChapters);
  else snprintf(v, sizeof(v), "%d/%d", mediaChapter, mediaChapters);
  int vx = meta_textWidth(MEDIA_LABEL) + 5;
  if (valueOff > vx) vx = valueOff;
  u8g2.setForegroundColor(MEDIA_DIM);
  u8g2.setCursor(x, y);
  u8g2.print(MEDIA_LABEL);
  u8g2.setForegroundColor(SSD1322_WHITE);
  meta_drawClipped(v, x + vx, y, w - vx, 0);
}

// ---------------------------------------------------------------------------
// meta_parseMedia - CMDMEDIA,<state>,<seconds in>,<seconds long>,<chapter>,
// <chapters>. Draws nothing here: a layout up is drawn again once idle.
// ---------------------------------------------------------------------------
void meta_parseMedia(const char *cmd) {
  const char *p = strchr(cmd, ',');
  long v[5] = { 0, 0, 0, 0, 0 };
  int n = 0;
  if (p && p[1]) n = sscanf(p + 1, "%ld,%ld,%ld,%ld,%ld", &v[0], &v[1], &v[2], &v[3], &v[4]);
  int state = (n >= 1) ? (int)v[0] : MEDIA_OFF;
  if (state < MEDIA_OFF || state > MEDIA_STILL) state = MEDIA_OFF;
  for (int i = 1; i < 3; i++) {
    if (v[i] < 0) v[i] = 0;
    if (v[i] > MEDIA_MAX_SECS) v[i] = MEDIA_MAX_SECS;
  }
  for (int i = 3; i < 5; i++) {
    if (v[i] < 0) v[i] = 0;
    if (v[i] > MEDIA_MAX_CHAPTER) v[i] = MEDIA_MAX_CHAPTER;
  }
  // Somebody pressed something: wake the panel, as a button on the MiSTer
  // would. The seconds moving on, or a chapter turning, is the film, not them.
  if (state != mediaState && state != MEDIA_OFF && mediaState != MEDIA_OFF) meta_activity();
  mediaState    = state;
  mediaPos      = v[1];
  mediaTotal    = v[2];
  mediaChapter  = (int)v[3];
  mediaChapters = (int)v[4];
  mediaAt       = millis();
  mediaRedraw   = true;
}

void media_reset(void) {
  mediaState = MEDIA_OFF;
  mediaPos = mediaTotal = 0;
  mediaChapter = mediaChapters = 0;
  mediaRedraw = false;
  mediaShown = -2;
}

// Has the band something new to show - a second gone, the arrow's flash?
static bool meta_mediaTick(unsigned long now) {
  return meta_mediaOn() && mediaShown != -2 && media_key(now) != mediaShown;
}

#endif  // MEDIABAND_H
