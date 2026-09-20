/*
  metadisplay.h - game metadata display modes for tty2oled

  Part of the tty2oled game-metadata fork.

  This header is included from the main sketch AFTER the globals it depends on
  (oled, u8g2, logoBin, DispWidth/DispHeight, actPicType, oled_drawlogo...),
  following the same pattern the sketch already uses for bitmaps.h and fonts.h.
  It is not a standalone translation unit.

  ---------------------------------------------------------------------------
  Why this works the way it does
  ---------------------------------------------------------------------------
  Adafruit_GrayOLED keeps a 4bpp framebuffer of WIDTH*HEIGHT/2 bytes, and
  Adafruit_SSD1322::draw4bppBitmap() at rotation 0 copies a picture into it
  1:1. In other words the on-disk GSC format and the live framebuffer are the
  same bytes in the same order.

  That means a metadata screen can be composed with ordinary GFX/u8g2 calls,
  snapshotted out of the framebuffer with a memcpy, and then handed to the
  sketch's existing transition effects as if it had arrived over the wire as a
  picture. No transition code has to be duplicated, and the arcade mode gets
  all ~25 effects for free.

  The only change required in the existing code is that the transition
  primitives read from a source pointer (srcBin) instead of logoBin directly.

  ---------------------------------------------------------------------------
  Wire protocol
  ---------------------------------------------------------------------------
  CMDMETA,<kind>,<interval>,<title>[|<label>=<value>]...
      kind      0 = off (plain full-screen picture, upstream behaviour)
                1 = arcade   - alternate picture <-> metadata card
                2 = console  - split layout, text left, icon right
                3 = computer - full-screen picture only
      interval  alternation period in seconds for arcade (0 disables)
      title     primary line; the daemon strips '|' ',' and control characters
      fields    up to META_MAX_FIELDS label=value pairs

  CMDICON         followed by ICON_BYTES raw bytes - 86x64 4bpp console icon
  CMDWRBOOT       followed by 8192 raw bytes - boot image, persisted to flash
  CMDCLRBOOT      forget the stored boot image, revert to the built-in logo
  CMDMETAOFF      leave metadata mode, back to plain picture display

  All three payload commands reuse the existing handshake: the payload is read
  with Serial.readBytes() immediately after the command line.
*/

#ifndef METADISPLAY_H
#define METADISPLAY_H

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
// The console layout splits the 256px width into a text column and an icon.
// ICON_X is even so that the icon lands on a byte boundary in the 4bpp buffer
// (each byte holds two pixels), which makes the blit a straight per-row
// memcpy instead of a nibble shuffle.
#define ICON_W          86
#define ICON_H          64
#define ICON_X          170                      // 170/2 = byte 85 of 128
#define ICON_STRIDE     (ICON_W / 2)             // 43 bytes per row
#define ICON_BYTES      (ICON_STRIDE * ICON_H)   // 2752 bytes
#define TEXT_W          (ICON_X - 4)             // usable text width, 2px gutter

#define META_MAX_FIELDS 6
#define META_MAX_LABEL  16
#define META_MAX_VALUE  48
#define META_MAX_TITLE  64

// ---------------------------------------------------------------------------
// Console layout rows
// ---------------------------------------------------------------------------
// A fixed "Now playing" header sits above the rule, the game title below it in
// a font a step larger than the field list, then the fields themselves.
// These are shared by the renderer and the scroll tick so the marquee measures
// the same window the title is actually drawn into.
#define CON_HEADER_TEXT  "Now playing"
#define CON_HEADER_FONT  7              // tenfatguys, 10px
#define CON_HEADER_Y     11             // header baseline
#define CON_RULE_Y       14             // hairline under the header
#define CON_TITLE_FONT   2              // luBS10 - larger than the 5x7 fields
#define CON_TITLE_LABEL  "Title: "
#define CON_TITLE_Y      26             // title baseline
#define CON_FIELD_FONT   0              // 5x7
#define CON_FIELD_Y0     36             // first field baseline
#define CON_FIELD_PITCH  9
// Leave the bottom few rows clear for the page indicator.
#define CON_FIELD_ROWS   ((DispHeight - 6 - CON_FIELD_Y0) / CON_FIELD_PITCH + 1)

// Display kinds, matching the wire protocol.
#define MKIND_OFF       0
#define MKIND_ARCADE    1
#define MKIND_CONSOLE   2
#define MKIND_COMPUTER  3

// Scrolling behaviour.
#define SCROLL_STEP_MS    40    // horizontal marquee tick
#define SCROLL_PAUSE_MS   1200  // pause at each end of a marquee run
#define VSCROLL_MS        2500  // dwell per page when fields overflow
#define SCROLL_GAP        24    // px of blank between marquee wraps

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
struct MetaField {
  char label[META_MAX_LABEL];
  char value[META_MAX_VALUE];
};

int       metaKind         = MKIND_OFF;
char      metaTitle[META_MAX_TITLE] = "";
MetaField metaFields[META_MAX_FIELDS];
int       metaFieldCount   = 0;
int       metaInterval     = 12;        // arcade alternation period, seconds
bool      metaHasIcon      = false;     // a console icon has been received

// Arcade alternation.
bool          metaShowingCard = false;  // currently showing the metadata card
unsigned long metaLastSwap    = 0;

// Console scrolling.
long          titleScrollX   = 0;
unsigned long lastScrollTick = 0;
unsigned long scrollHoldUntil = 0;
int           fieldPage      = 0;
unsigned long lastPageTick   = 0;

// Buffers. metaBin holds the composed metadata card so it can be fed to the
// existing transition effects; iconBin holds the 86x64 console icon.
// Guarded to ESP32 - an ESP8266 has neither the RAM nor the NVS for these.
#ifdef ESP32X
  uint8_t metaBin[8192];
  uint8_t iconBin[ICON_BYTES];
  #define HAS_METADISPLAY 1
#endif

// Set by the sketch: which buffer the transition effects read from.
// Defaults to logoBin so upstream behaviour is unchanged.
extern uint8_t *srcBin;

// Forward declarations of sketch functions used here.
void oled_drawlogo(uint8_t e);
void oled_setfont(int font);

// ---------------------------------------------------------------------------
// meta_reset - drop all metadata and return to plain picture display.
// ---------------------------------------------------------------------------
void meta_reset(void) {
  metaKind = MKIND_OFF;
  metaTitle[0] = 0;
  metaFieldCount = 0;
  metaHasIcon = false;
  metaShowingCard = false;
  titleScrollX = 0;
  fieldPage = 0;
}

// ---------------------------------------------------------------------------
// meta_copyField - bounded copy that always NUL-terminates.
// Arduino's String is avoided in the parse path: this runs on every core
// change and String fragments the heap badly on long-running ESP32s.
// ---------------------------------------------------------------------------
static void meta_copyField(char *dst, size_t cap, const char *src, size_t len) {
  if (len >= cap) len = cap - 1;
  memcpy(dst, src, len);
  dst[len] = 0;
}

// ---------------------------------------------------------------------------
// meta_parse - parse a CMDMETA command line.
//
// Input is the full command, e.g.
//   CMDMETA,1,12,Donkey Kong (US set 1)|Year=1981|Manufacturer=Nintendo
//
// Parsed by hand rather than with String::substring to keep one allocation-free
// pass over the buffer.
// ---------------------------------------------------------------------------
bool meta_parse(const char *cmd) {
  const char *p = cmd;

  // Skip the command word.
  p = strchr(p, ',');
  if (!p) return false;
  p++;

  // kind
  int kind = atoi(p);
  p = strchr(p, ',');
  if (!p) return false;
  p++;

  // interval
  int interval = atoi(p);
  p = strchr(p, ',');
  if (!p) return false;
  p++;

  if (kind < MKIND_OFF || kind > MKIND_COMPUTER) return false;
  if (interval < 0)   interval = 0;
  if (interval > 600) interval = 600;

  metaKind       = kind;
  metaInterval   = interval;
  metaFieldCount = 0;
  metaTitle[0]   = 0;

  // title runs up to the first '|' or end of line
  const char *bar = strchr(p, '|');
  if (bar) {
    meta_copyField(metaTitle, sizeof(metaTitle), p, (size_t)(bar - p));
    p = bar + 1;
  } else {
    meta_copyField(metaTitle, sizeof(metaTitle), p, strlen(p));
    p = NULL;
  }

  // fields: label=value, separated by '|'
  while (p && *p && metaFieldCount < META_MAX_FIELDS) {
    const char *end = strchr(p, '|');
    size_t seglen = end ? (size_t)(end - p) : strlen(p);

    const char *eq = (const char *)memchr(p, '=', seglen);
    if (eq) {
      MetaField *f = &metaFields[metaFieldCount];
      meta_copyField(f->label, sizeof(f->label), p, (size_t)(eq - p));
      meta_copyField(f->value, sizeof(f->value), eq + 1,
                     seglen - (size_t)(eq - p) - 1);
      if (f->value[0]) metaFieldCount++;
    }

    if (!end) break;
    p = end + 1;
  }

  // Entering a new game resets all scroll/alternation state so the display
  // always starts from a predictable position.
  metaShowingCard = false;
  metaLastSwap    = millis();
  titleScrollX    = 0;
  fieldPage       = 0;
  lastPageTick    = millis();
  scrollHoldUntil = millis() + SCROLL_PAUSE_MS;
  return true;
}

#ifdef HAS_METADISPLAY

// ---------------------------------------------------------------------------
// meta_textWidth - measure a string in the currently selected u8g2 font.
// ---------------------------------------------------------------------------
static int meta_textWidth(const char *s) {
  return (int)u8g2.getUTF8Width(s);
}

// ---------------------------------------------------------------------------
// meta_drawClipped - draw text clipped to a pixel window, with optional
// horizontal offset for marquee scrolling.
//
// u8g2_for_Adafruit_GFX has no clipping of its own, so anything that would
// spill past the text column is trimmed character-by-character before drawing.
// That is cheap here because these strings are short and only redrawn on a
// scroll tick.
// ---------------------------------------------------------------------------
static void meta_drawClipped(const char *s, int x, int y, int maxw, int offset) {
  char buf[META_MAX_VALUE + META_MAX_LABEL + 4];
  size_t n = strlen(s);
  if (n >= sizeof(buf)) n = sizeof(buf) - 1;
  memcpy(buf, s, n);
  buf[n] = 0;

  int startx = x - offset;

  // Trim from the right until it fits the window.
  while (n > 0 && startx + meta_textWidth(buf) > x + maxw) {
    buf[--n] = 0;
  }
  if (!n) return;

  u8g2.setCursor(startx, y);
  u8g2.print(buf);
}

// ---------------------------------------------------------------------------
// meta_renderCard - compose the arcade metadata card into the framebuffer.
//
// Layout (256x64):
//   y  0..15   title, 12px font, centred, truncated if it will not fit
//   y  17      hairline separator
//   y 20..63   up to 5 fields, 5x7 font, label dimmed, value bright
// ---------------------------------------------------------------------------
static void meta_renderCard(void) {
  oled.clearDisplay();

  // Title
  oled_setfont(6);                                  // scumm subtitle, 12px
  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setBackgroundColor(SSD1322_BLACK);
  int tw = meta_textWidth(metaTitle);
  int tx = (tw < DispWidth) ? (DispWidth - tw) / 2 : 0;
  meta_drawClipped(metaTitle, tx, 13, DispWidth - tx, 0);

  // Separator. Drawn mid-grey so it reads as a rule rather than a bright line.
  oled.drawFastHLine(0, 17, DispWidth, 6);

  // Fields, two per row would be cramped at this width, so one per row.
  oled_setfont(0);                                  // 5x7
  int y = 28;
  for (int i = 0; i < metaFieldCount && y <= DispHeight; i++) {
    char line[META_MAX_LABEL + META_MAX_VALUE + 4];

    // Label in grey.
    u8g2.setForegroundColor(8);
    snprintf(line, sizeof(line), "%s", metaFields[i].label);
    u8g2.setCursor(4, y);
    u8g2.print(line);
    int lw = meta_textWidth(line) + 8;

    // Value in white, clipped to whatever room is left.
    u8g2.setForegroundColor(SSD1322_WHITE);
    meta_drawClipped(metaFields[i].value, 4 + lw, y, DispWidth - 8 - lw, 0);

    y += 9;
  }

  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setBackgroundColor(SSD1322_BLACK);
}

// ---------------------------------------------------------------------------
// meta_blitIcon - copy the 86x64 icon into the right of the framebuffer.
//
// ICON_X is even, so each display row is  [85 bytes text][43 bytes icon]  and
// the icon copies in as one memcpy per row with no nibble arithmetic.
// ---------------------------------------------------------------------------
static void meta_blitIcon(void) {
  if (!metaHasIcon) return;
  uint8_t *fb = oled.getBuffer();
  if (!fb) return;

  const int rowBytes = DispWidth / 2;          // 128
  const int xByte    = ICON_X / 2;             // 85

  for (int row = 0; row < ICON_H && row < DispHeight; row++) {
    memcpy(&fb[row * rowBytes + xByte], &iconBin[row * ICON_STRIDE], ICON_STRIDE);
  }
}

// ---------------------------------------------------------------------------
// meta_renderConsole - compose the console split layout.
//
//   x   0..169  text column: title plus scrolling field list
//   x 170..255  console icon, blitted straight into the framebuffer
//
// The field list pages vertically when there are more fields than rows, and
// the title marquees horizontally when it is wider than the column.
// ---------------------------------------------------------------------------
static void meta_renderConsole(void) {
  oled.clearDisplay();

  // --- Header --------------------------------------------------------------
  // Fixed caption rather than the game title: the title has moved below the
  // rule where it gets a larger font and the full width of the column.
  oled_setfont(CON_HEADER_FONT);
  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setBackgroundColor(SSD1322_BLACK);
  meta_drawClipped(CON_HEADER_TEXT, 2, CON_HEADER_Y, TEXT_W, 0);

  oled.drawFastHLine(0, CON_RULE_Y, TEXT_W + 2, 6);

  // --- Title, with marquee when it overflows -------------------------------
  oled_setfont(CON_TITLE_FONT);
  const int titleLabelW = meta_textWidth(CON_TITLE_LABEL);
  const int titleX      = 2 + titleLabelW;
  const int titleWin    = TEXT_W - titleLabelW;

  u8g2.setForegroundColor(8);                       // label dimmed, as fields
  u8g2.setCursor(2, CON_TITLE_Y);
  u8g2.print(CON_TITLE_LABEL);
  u8g2.setForegroundColor(SSD1322_WHITE);

  int tw = meta_textWidth(metaTitle);
  if (tw <= titleWin) {
    titleScrollX = 0;
    meta_drawClipped(metaTitle, titleX, CON_TITLE_Y, titleWin, 0);
  } else {
    meta_drawClipped(metaTitle, titleX, CON_TITLE_Y, titleWin, (int)titleScrollX);
    // Second copy trailing the first so the wrap reads continuously.
    int wrapAt = tw + SCROLL_GAP;
    if (titleScrollX > wrapAt - titleWin) {
      meta_drawClipped(metaTitle, titleX, CON_TITLE_Y, titleWin,
                       (int)titleScrollX - wrapAt);
    }
  }

  // --- Field list ----------------------------------------------------------
  oled_setfont(CON_FIELD_FONT);
  const int firstY   = CON_FIELD_Y0;
  const int pitch    = CON_FIELD_PITCH;
  const int maxRows  = CON_FIELD_ROWS;
  int pages = (metaFieldCount + maxRows - 1) / maxRows;
  if (pages < 1) pages = 1;
  if (fieldPage >= pages) fieldPage = 0;

  int start = fieldPage * maxRows;
  int y = firstY;

  for (int i = start; i < metaFieldCount && i < start + maxRows; i++) {
    char line[META_MAX_LABEL + META_MAX_VALUE + 4];

    u8g2.setForegroundColor(8);
    snprintf(line, sizeof(line), "%s", metaFields[i].label);
    u8g2.setCursor(2, y);
    u8g2.print(line);
    int lw = meta_textWidth(line) + 5;

    u8g2.setForegroundColor(SSD1322_WHITE);
    meta_drawClipped(metaFields[i].value, 2 + lw, y, TEXT_W - lw, 0);

    y += pitch;
  }

  // Page indicator: one pip per page, current page bright.
  if (pages > 1) {
    for (int p = 0; p < pages && p < 8; p++) {
      oled.fillRect(2 + p * 5, DispHeight - 2, 3, 2,
                    (p == fieldPage) ? SSD1322_WHITE : 4);
    }
  }

  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setBackgroundColor(SSD1322_BLACK);

  // --- Icon ----------------------------------------------------------------
  meta_blitIcon();
}

// ---------------------------------------------------------------------------
// meta_snapshot - capture the composed framebuffer into metaBin so the
// existing transition effects can animate towards it.
// ---------------------------------------------------------------------------
static void meta_snapshot(void) {
  uint8_t *fb = oled.getBuffer();
  if (fb) memcpy(metaBin, fb, (size_t)logoBytes4bpp);
}

// ---------------------------------------------------------------------------
// meta_showCard - animate from whatever is on screen to the metadata card.
// Reuses the sketch's transition effects by pointing srcBin at metaBin.
// ---------------------------------------------------------------------------
void meta_showCard(int effect) {
  meta_renderCard();
  meta_snapshot();

  int savedType = actPicType;
  actPicType = GSC;                 // the card is always 4bpp
  srcBin     = metaBin;
  oled_drawlogo(effect < 0 ? random(minEffect, maxEffect + 1) : effect);
  srcBin     = logoBin;
  actPicType = savedType;

  metaShowingCard = true;
  metaLastSwap    = millis();
}

// ---------------------------------------------------------------------------
// meta_showPicture - animate back to the game artwork held in logoBin.
// ---------------------------------------------------------------------------
void meta_showPicture(int effect) {
  srcBin = logoBin;
  oled_drawlogo(effect < 0 ? random(minEffect, maxEffect + 1) : effect);
  metaShowingCard = false;
  metaLastSwap    = millis();
}

// ---------------------------------------------------------------------------
// meta_showConsole - draw the split layout with no transition.
// Called on every scroll tick, so it must stay cheap: compose, then push.
// ---------------------------------------------------------------------------
void meta_showConsole(void) {
  meta_renderConsole();
  oled.display();
}

// ---------------------------------------------------------------------------
// meta_tick - non-blocking periodic work, called from the sketch's main loop.
//
// Arcade : swap between artwork and metadata card every metaInterval seconds.
// Console: advance the marquee and the field pager.
//
// Returns true if it drew anything, so the caller can skip its own redraw.
// ---------------------------------------------------------------------------
bool meta_tick(void) {
  unsigned long now = millis();

  if (metaKind == MKIND_ARCADE && metaInterval > 0 && metaFieldCount > 0) {
    if (now - metaLastSwap >= (unsigned long)metaInterval * 1000UL) {
      if (metaShowingCard) meta_showPicture(-1);
      else                 meta_showCard(-1);
      return true;
    }
    return false;
  }

  if (metaKind == MKIND_CONSOLE) {
    bool dirty = false;

    // Field pager.
    const int maxRows = CON_FIELD_ROWS;
    int pages = (metaFieldCount + maxRows - 1) / maxRows;
    if (pages > 1 && now - lastPageTick >= VSCROLL_MS) {
      fieldPage    = (fieldPage + 1) % pages;
      lastPageTick = now;
      dirty        = true;
    }

    // Title marquee. Only runs when the title actually overflows. The window
    // is the column minus the "Title: " label, measured in the same font the
    // renderer uses, so the scroll and the draw agree on when it overflows.
    oled_setfont(CON_TITLE_FONT);
    const int titleWin = TEXT_W - meta_textWidth(CON_TITLE_LABEL);
    int tw = meta_textWidth(metaTitle);
    if (tw > titleWin && now >= scrollHoldUntil && now - lastScrollTick >= SCROLL_STEP_MS) {
      lastScrollTick = now;
      titleScrollX++;
      int wrapAt = tw + SCROLL_GAP;
      if (titleScrollX >= wrapAt) {
        titleScrollX    = 0;
        scrollHoldUntil = now + SCROLL_PAUSE_MS;   // pause before starting over
      }
      dirty = true;
    }

    if (dirty) meta_showConsole();
    return dirty;
  }

  return false;
}

#else   // !HAS_METADISPLAY - ESP8266 builds keep upstream behaviour

bool meta_tick(void)              { return false; }
void meta_showCard(int effect)    { (void)effect; }
void meta_showPicture(int effect) { (void)effect; }
void meta_showConsole(void)       { }

#endif  // HAS_METADISPLAY

#endif  // METADISPLAY_H
