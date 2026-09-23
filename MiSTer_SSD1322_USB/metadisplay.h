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
  CMDMETA,<kind>,<interval>[,<pinned>[,<compact>]],<title>[|<label>=<value>]...
      kind      0 = off (plain full-screen picture, upstream behaviour)
                1 = arcade   - alternate picture <-> metadata card
                2 = console  - split layout, text left, icon right
                3 = computer - full-screen picture only
      interval  alternation period in seconds for arcade (0 disables)
      title     primary line; the daemon strips '|' ',' and control characters
      pinned    fields drawn on every page rather than paged through
      compact   leading fields the arcade card pairs two to a row; the rest
                get a full-width row each
      fields    up to META_MAX_FIELDS label=value pairs. Both layouts page
                through more fields than they have rows - the console list
                every VSCROLL_MS, the arcade card once per interval, running
                its pages back to back before the artwork returns.

  CMDICON         followed by ICON_BYTES raw bytes - 86x64 4bpp console icon
  CMDWRBOOT       followed by 6912 raw bytes - boot image, persisted to flash
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

// 16 rather than the 6 this started with: an arcade MRA carries year,
// manufacturer, genre, players, controls, region, platform, orientation,
// setname, core, MAME version and author, and the card pages through them
// rather than dropping the ones that do not fit on one screen.
#define META_MAX_FIELDS 16
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
// Every gap is named because 64 rows is a tight budget and these are the
// numbers to tune if the spacing looks wrong on glass. Each CON_GAP_* is the
// number of blank pixel rows between one element and the next.
#define CON_HEADER_TEXT  "Now playing"
#define CON_HEADER_FONT  7              // tenfatguys, 10px
#define CON_HEADER_Y     11             // header baseline
#define CON_GAP_HEADER   1              // blank rows between header and rule
#define CON_RULE_Y       (CON_HEADER_Y + CON_GAP_HEADER + 1)          // 13
#define CON_GAP_RULE     2              // blank rows between rule and title
#define CON_TITLE_FONT   2              // luBS10 - larger than the 5x7 fields
#define CON_TITLE_ASCENT 11             // luBS10 cap height above the baseline
#define CON_TITLE_X      2              // title left edge, unlabelled
// +1 like the others: the rule occupies CON_RULE_Y, CON_GAP_RULE blank rows
// follow it, and the title's top row is the one after those.
#define CON_TITLE_Y      (CON_RULE_Y + CON_GAP_RULE + 1 + CON_TITLE_ASCENT)  // 26
#define CON_TITLE_DESC   3              // luBS10 descender below the baseline
#define CON_GAP_TITLE    1              // blank rows between title and fields
#define CON_FIELD_FONT   0              // 5x7
#define CON_FIELD_ASCENT 6              // 5x7 glyph height above the baseline
// +1 for the same reason CON_RULE_Y and CON_TITLE_Y have one: the gap is the
// count of blank rows, so the next glyph's TOP row is one past the last blank
// one, and a baseline sits CON_FIELD_ASCENT below its top.
#define CON_FIELD_Y0     (CON_TITLE_Y + CON_TITLE_DESC + CON_GAP_TITLE + 1 \
                          + CON_FIELD_ASCENT)                         // 36
// 8 rather than 9: a 7px font with one blank row between, which is what buys
// the fourth field row alongside the gap under the title.
#define CON_FIELD_PITCH  8
// The page indicator used to sit along the bottom, which cost a whole field
// row. It is up beside the header now, so the list runs to the last baseline
// that still fits on the panel.
#define CON_FIELD_ROWS   ((DispHeight - 1 - CON_FIELD_Y0) / CON_FIELD_PITCH + 1)

// Page indicator, top right of the text column, next to the icon panel.
#define CON_PIP_Y        2              // top row of the pips
#define CON_PIP_W        3
#define CON_PIP_H        3
#define CON_PIP_STRIDE   5
#define CON_PIP_MAX      8

// ---------------------------------------------------------------------------
// Arcade card layout rows
// ---------------------------------------------------------------------------
// A title, a rule and four rows. Same convention as the console layout above:
// each CARD_GAP_* is a count of blank rows and the next element's TOP row is
// one past the last of them, which is where the +1 in each derived row comes
// from.
//
//   row  0..12  title            baseline CARD_TITLE_Y   pips at the right
//   row 13..15  blank                     CARD_GAP_TITLE
//   row 16      rule                      CARD_RULE_Y
//   row 17..19  blank                     CARD_GAP_RULE
//   row 20..26  row 0            baseline CARD_FIELD_Y0
//   row 31..37  row 1                     + CARD_FIELD_PITCH
//   row 42..48  row 2
//   row 53..59  row 3
//
// A row carries either two fields side by side or one across the full width;
// which it is depends on the page, not on the row. See meta_renderCard.
#define CARD_MARGIN_X     4
#define CARD_TITLE_FONT   6             // lucasarts scumm subtitle, 12px
// Arcade names run long - "Teenage Mutant Ninja Turtles (World 4 Players)" is
// wider than the panel at 12px - so a title that will not fit drops a font
// size before it is allowed to be truncated.
#define CARD_TITLE_ALT    1             // luBS08, 8px
#define CARD_TITLE_Y      12
#define CARD_GAP_TITLE    3
#define CARD_RULE_Y       (CARD_TITLE_Y + CARD_GAP_TITLE + 1)          // 16
#define CARD_GAP_RULE     3
#define CARD_FIELD_FONT   0             // 5x7
#define CARD_FIELD_ASCENT 6             // 5x7 glyph height above the baseline
#define CARD_FIELD_Y0     (CARD_RULE_Y + CARD_GAP_RULE + 1 + CARD_FIELD_ASCENT) // 26
// 11 rather than the console list's 8: the card carries half as many rows as
// it has room for glyphs, so the spare height goes into the gaps. Four rows
// falls out of it rather than being stated.
#define CARD_FIELD_PITCH  11
#define CARD_FIELD_ROWS   ((DispHeight - 1 - CARD_FIELD_Y0) / CARD_FIELD_PITCH + 1)
#define CARD_PIP_Y        4             // pips sit centred on the title row

// Two columns, with a gutter between them. The right column starts at
// CARD_MARGIN_X + CARD_COL_W + CARD_COL_GAP and ends on the right margin.
#define CARD_COL_GAP      6
#define CARD_COL_W        ((DispWidth - 2 * CARD_MARGIN_X - CARD_COL_GAP) / 2)

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
// Fields pinned to the top of the list: shown on every page rather than paged
// through. The first metaPinned of metaFields. On the console split that is
// the top of every page; on the arcade card it is the grid row that repeats
// above the wide pages.
int       metaPinned       = 0;
// How many leading fields the arcade card lays out two to a row. The rest are
// given a row each, across the full width, because their values are too long
// to pair - "Turbo/Shoot / Block/Pass / Steal" needs all 256 pixels. The
// script decides which are which; the firmware only counts.
int       metaCompact      = 0;
bool      metaHasIcon      = false;     // a console icon has been received

// A console layout is only ever drawn because something asked for it: CMDCOR
// on a core change, CMDICON when an icon arrives, or a scroll tick. A game
// change touches none of those - the core has not changed, and most systems
// ship no icon - so new metadata sets this and the next tick puts it on screen.
// Without it only titles long enough to marquee ever redrew themselves.
bool      metaNeedsDraw    = false;

// ---------------------------------------------------------------------------
// Core boot screen
// ---------------------------------------------------------------------------
// A console core launched with its game already chosen - from a frontend, or
// a .mgl - used to go straight to the split layout, so the core's own
// full-screen artwork was never seen at all. CMDCBOOT, sent just before the
// picture on a core change, asks for it to be held first, the way a console
// holds its own boot screen before the game starts.
//
// The daemon decides *whether* to hold, because only it can tell a core
// change from a game loaded into a core that was already running; the
// firmware decides *when the hold starts*, because only it knows when the
// transition finished and the picture is actually on the panel. So there is
// no timeout here and nothing to guess: no CMDCBOOT, no hold, exactly as
// before.
//
// While the hold is on, nothing else may draw the layout underneath it -
// not meta_tick honouring metaNeedsDraw, not the icon arriving - or the
// artwork would be replaced before it had been looked at.
bool          coreBootHolding = false;  // a core picture is owed its moment
unsigned long coreBootMs      = 0;      // how long to hold it for
unsigned long coreBootSince   = 0;      // when it reached the panel; 0 = not yet

// ---------------------------------------------------------------------------
// Screen side flip
// ---------------------------------------------------------------------------
// The console layout swaps sides every metaFlipMs so no region of the panel
// carries the same bright pixels forever. 0 disables it.
unsigned long metaFlipMs   = 300000;    // 5 minutes
bool          metaFlipped  = false;
unsigned long metaLastFlip = 0;

// ---------------------------------------------------------------------------
// Dimming
// ---------------------------------------------------------------------------
// Lowers the contrast after a period with nothing drawn, and restores it on
// the next draw. 0 disables it. Both directions fade (contrastfade.h). With
// upstream's logo-shuffling screensaver gone, this and FLIP_MINUTES are the
// fork's burn-in protection: one dims the panel, the other moves the console
// layout from side to side.
//
// The dim level is a contrast, 0..255, the same scale as CONTRAST - not a
// percentage of it, which is what it was: "50" then meant a different
// brightness for every CONTRAST, and the two settings could not be compared.
unsigned long metaDimAfterMs  = 120000; // 2 minutes
int           metaDimContrast = 80;     // 0..255, never above the waking level
// Going dim has its own, much slower fade: it is burn-in protection, and the
// point is that nobody notices it happen. Waking uses CONTRAST_FADE_MS like
// every other change - something new has arrived, and it should be seen.
#define DIM_FADE_MS_DEFAULT  6000
#define DIM_FADE_MS_MAX      10000
// The core boot screen is a pause before the game appears, not a screensaver:
// ten seconds is already longer than anyone wants to wait twice.
#define CORE_BOOT_MS_MAX     10000
unsigned long metaDimFadeMs   = DIM_FADE_MS_DEFAULT;
int           metaWakeContrast = -1;    // -1 = whatever CMDCON last set
bool          metaDimmed      = false;
unsigned long metaLastActivity = 0;

// Arcade alternation.
bool          metaShowingCard = false;  // currently showing the metadata card
unsigned long metaLastSwap    = 0;
// Which page of the field list the card shows. An MRA carries more fields
// than the card has rows, so each time the card comes round it shows the next
// page: artwork, page 1, artwork, page 2, ... all at metaInterval.
int           cardPage        = 0;

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

// Set by CMDCON from the ini's CONTRAST. The waking brightness, unless
// metaWakeContrast overrides it.
extern uint8_t contrast;

// Forward declarations of sketch functions used here.
void oled_drawlogo(uint8_t e);
void oled_setfont(int font);

// Defined below, called from the draw helpers above it.
void meta_activity(void);

// ---------------------------------------------------------------------------
// meta_reset - drop all metadata and return to plain picture display.
// ---------------------------------------------------------------------------
#ifdef HAS_METADISPLAY
void pf_cancel(void);                // pagefade.h, included further down
#endif

void meta_reset(void) {
#ifdef HAS_METADISPLAY
  pf_cancel();                       // no page left to fade to
#endif
  metaKind = MKIND_OFF;
  metaTitle[0] = 0;
  metaFieldCount = 0;
  metaPinned = 0;
  metaCompact = 0;
  metaHasIcon = false;
  metaNeedsDraw = false;
  coreBootHolding = false;
  coreBootSince = 0;
  metaShowingCard = false;
  titleScrollX = 0;
  fieldPage = 0;
  cardPage = 0;
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

  // Optional pinned and compact counts. metasanitize strips commas from the
  // title and from every field, so anything after this point is comma-free -
  // which makes one more comma an unambiguous signal that this token is a
  // count and not the start of the title. Both are optional and in order, so
  // a new firmware still works with an older script that sends one or
  // neither.
  int counts[2] = { 0, 0 };
  for (int c = 0; c < 2; c++) {
    const char *q = p;
    while (*q >= '0' && *q <= '9') q++;
    if (q == p || *q != ',') break;
    counts[c] = atoi(p);
    p = q + 1;
  }
  int pinned  = counts[0];
  int compact = counts[1];

  if (kind < MKIND_OFF || kind > MKIND_COMPUTER) return false;
  if (interval < 0)   interval = 0;
  if (interval > 600) interval = 600;

  metaKind       = kind;
  metaInterval   = interval;
  metaPinned     = pinned;
  metaCompact    = compact;
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

  // A pinned count at or past the row budget would leave nothing to page, so
  // cap it one short and let the rest cycle.
  if (metaPinned < 0) metaPinned = 0;
  if (metaPinned > metaFieldCount) metaPinned = metaFieldCount;
  if (metaCompact < 0) metaCompact = 0;
  if (metaCompact > metaFieldCount) metaCompact = metaFieldCount;

  // Entering a new game resets all scroll/alternation state so the display
  // always starts from a predictable position.
  metaShowingCard = false;
  cardPage        = 0;
  metaNeedsDraw   = (kind == MKIND_CONSOLE);
  metaLastFlip    = millis();
  metaLastSwap    = millis();
  titleScrollX    = 0;
  fieldPage       = 0;
  lastPageTick    = millis();
  scrollHoldUntil = millis() + SCROLL_PAUSE_MS;
  return true;
}

#ifdef HAS_METADISPLAY

#include "contrastfade.h"
#include "fadetransition.h"
#include "pagefade.h"          // a page turn fades only the rows that change

// ---------------------------------------------------------------------------
// Which side each column is on. The icon must start on an even x: the
// framebuffer is 4bpp, so a column maps to a whole byte only at even pixels,
// and meta_blitIcon copies whole bytes. 0 and ICON_X are both even.
// ---------------------------------------------------------------------------
static int meta_iconX(void) { return metaFlipped ? 0 : ICON_X; }

// ---------------------------------------------------------------------------
// Paging with pinned rows.
//
// The first metaPinned fields sit on every page; the rest cycle through the
// slots left over. With four rows and two pinned, System and Year stay put
// while Genre/Region and Format take turns below them.
//
// One place computes this so the renderer and the scroll tick cannot disagree
// about how many pages there are - they did once, over the marquee window,
// and the result was a title that scrolled without ever overflowing.
// ---------------------------------------------------------------------------
static int meta_pinnedRows(void) {
  int rows = CON_FIELD_ROWS;
  int p = metaPinned;
  if (p < 0) p = 0;
  // Never pin the whole panel: something has to be left to page with.
  if (p > rows - 1) p = rows - 1;
  if (p > metaFieldCount) p = metaFieldCount;
  return p;
}

static int meta_pageSlots(void) {
  int slots = CON_FIELD_ROWS - meta_pinnedRows();
  return slots < 1 ? 1 : slots;
}

static int meta_pageCount(void) {
  int paged = metaFieldCount - meta_pinnedRows();
  if (paged <= 0) return 1;
  int slots = meta_pageSlots();
  return (paged + slots - 1) / slots;
}

static int meta_textX(void) { return metaFlipped ? (ICON_W + 4) : 2; }

static int meta_textW(void) {
  return metaFlipped ? (DispWidth - (ICON_W + 4) - 2) : TEXT_W;
}

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
// meta_valueOffsetFor - where the value column starts, relative to the text
// column's left edge, for a column colW pixels wide.
//
// Values used to be packed immediately after each label, so every row started
// its value wherever its own label happened to end - "Year" is shorter than
// "System", so their values sat in different places and the rows read as
// misaligned. The offset is measured across EVERY field, not just the ones on
// this page, so the column does not shift when the pager turns over.
//
// Both layouts use it, so it must be called with that layout's field font
// selected: CON_FIELD_FONT for the console split, CARD_FIELD_FONT for the
// arcade card.
// ---------------------------------------------------------------------------
static int meta_valueOffsetFor(int colW) {
  int widest = 0;
  for (int i = 0; i < metaFieldCount; i++) {
    int w = meta_textWidth(metaFields[i].label);
    if (w > widest) widest = w;
  }
  int off = widest + 5;
  // A pathologically long label must not push the values off the column.
  int cap = colW / 2;
  if (off > cap) off = cap;
  return off;
}

static int meta_valueOffset(void) { return meta_valueOffsetFor(meta_textW()); }

// ---------------------------------------------------------------------------
// meta_drawField - one "Label  value" row, label dimmed, value clipped.
// ---------------------------------------------------------------------------
static void meta_drawField(int i, int x, int y, int w, int valueOff) {
  char line[META_MAX_LABEL + META_MAX_VALUE + 4];

  u8g2.setForegroundColor(8);
  snprintf(line, sizeof(line), "%s", metaFields[i].label);
  u8g2.setCursor(x, y);
  u8g2.print(line);

  // The shared column, unless this label is wide enough to reach past it -
  // then the value follows its own label rather than being drawn over it.
  int lw = meta_textWidth(line) + 5;
  int vx = (valueOff > lw) ? valueOff : lw;

  u8g2.setForegroundColor(SSD1322_WHITE);
  meta_drawClipped(metaFields[i].value, x + vx, y, w - vx, 0);
}

// ---------------------------------------------------------------------------
// Arcade card paging.
//
// The card has two kinds of page. The grid pages pair the leading metaCompact
// fields two to a row, which is what makes eight of them fit on one screen.
// The wide pages give a row each to the fields whose values are too long to
// pair, under a repeat of the pinned grid row so the game is still labelled
// with its year and maker.
//
//   page 0   Year     1993          Manufctr  Midway
//            Region   World         Orient    Horizontal
//            Core     blahmid_tunit Author    rejectedcoins
//            Set      nbajam        MAME      0289
//
//   page 1   Year     1993          Manufctr  Midway
//            Players  4
//            Controls 8-way
//            Buttons  Turbo/Shoot / Block/Pass / Steal
//
// Every count below derives from those two numbers, and the renderer and the
// alternation tick both ask here, so they cannot disagree about which page
// comes next - the console pair made exactly that mistake once.
// ---------------------------------------------------------------------------
static int meta_cardColX(int col) {
  return CARD_MARGIN_X + col * (CARD_COL_W + CARD_COL_GAP);
}

// Leading fields drawn two to a row, clamped to what actually arrived.
static int meta_cardGridCount(void) {
  int n = metaCompact;
  if (n < 0) n = 0;
  if (n > metaFieldCount) n = metaFieldCount;
  return n;
}

// The pinned row repeated above the wide pages. Only a grid field can pin: a
// wide field is a whole row, and repeating one would cost the page a line it
// has nothing to spare.
static int meta_cardPinned(void) {
  int p = metaPinned;
  int grid = meta_cardGridCount();
  if (p < 0) p = 0;
  if (p > grid) p = grid;
  return p;
}

// Rows needed to hold n fields two to a row.
static int meta_cardPairRows(int n) { return (n + 1) / 2; }

static int meta_cardGridPages(void) {
  int grid = meta_cardGridCount();
  if (grid <= 0) return 0;
  int perPage = CARD_FIELD_ROWS * 2;
  return (grid + perPage - 1) / perPage;
}

static int meta_cardWideSlots(void) {
  int slots = CARD_FIELD_ROWS - meta_cardPairRows(meta_cardPinned());
  return slots < 1 ? 1 : slots;
}

static int meta_cardWidePages(void) {
  int wide = metaFieldCount - meta_cardGridCount();
  if (wide <= 0) return 0;
  int slots = meta_cardWideSlots();
  return (wide + slots - 1) / slots;
}

static int meta_cardPageCount(void) {
  int pages = meta_cardGridPages() + meta_cardWidePages();
  return pages < 1 ? 1 : pages;
}

// ---------------------------------------------------------------------------
// meta_renderCard - compose one page of the arcade metadata card.
//
// Layout (256x64), row by row in the CARD_* constants above: the title with
// page pips at the right, a hairline rule, then CARD_FIELD_ROWS rows of the
// page described above. Labels are dimmed and values share a column, which is
// measured across every field so the columns do not move when the page turns.
// ---------------------------------------------------------------------------
static void meta_renderCard(void) {
  oled.clearDisplay();

  const int pages = meta_cardPageCount();
  if (cardPage >= pages) cardPage = 0;

  // Worked out before the title is drawn so the title is centred in - and
  // clipped to - what the pips leave, rather than running under them.
  const int pipCount = (pages > 1) ? (pages < CON_PIP_MAX ? pages : CON_PIP_MAX) : 0;
  const int pipBlock = pipCount ? (pipCount * CON_PIP_STRIDE + 4) : 0;
  const int titleWin = DispWidth - 2 * CARD_MARGIN_X - pipBlock;

  // --- Title ---------------------------------------------------------------
  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setBackgroundColor(SSD1322_BLACK);

  oled_setfont(CARD_TITLE_FONT);
  int tw = meta_textWidth(metaTitle);
  if (tw > titleWin) {                 // a size down beats losing the end of it
    oled_setfont(CARD_TITLE_ALT);
    tw = meta_textWidth(metaTitle);
  }
  int tx = CARD_MARGIN_X + ((tw < titleWin) ? (titleWin - tw) / 2 : 0);
  meta_drawClipped(metaTitle, tx, CARD_TITLE_Y,
                   CARD_MARGIN_X + titleWin - tx, 0);

  // Page indicator, hard against the right edge on the title row.
  for (int p = 0; p < pipCount; p++) {
    oled.fillRect(DispWidth - CARD_MARGIN_X - pipCount * CON_PIP_STRIDE
                    + p * CON_PIP_STRIDE,
                  CARD_PIP_Y, CON_PIP_W, CON_PIP_H,
                  (p == cardPage) ? SSD1322_WHITE : 4);
  }

  // Separator. Drawn mid-grey so it reads as a rule rather than a bright line.
  oled.drawFastHLine(0, CARD_RULE_Y, DispWidth, 6);

  // --- This page's rows ----------------------------------------------------
  oled_setfont(CARD_FIELD_FONT);
  // Measured against the narrow column, so one shared offset serves the
  // paired rows and the full-width ones alike and every value on the card
  // starts at the same x.
  const int valueOff = meta_valueOffsetFor(CARD_COL_W);
  const int gridPages = meta_cardGridPages();
  const int grid      = meta_cardGridCount();

  int y = CARD_FIELD_Y0;

  if (cardPage < gridPages) {
    // A grid page: this page's share of the paired fields.
    int first = cardPage * CARD_FIELD_ROWS * 2;
    int last  = first + CARD_FIELD_ROWS * 2;
    if (last > grid) last = grid;
    for (int i = first; i < last; i += 2) {
      meta_drawField(i, meta_cardColX(0), y, CARD_COL_W, valueOff);
      if (i + 1 < last) {
        meta_drawField(i + 1, meta_cardColX(1), y, CARD_COL_W, valueOff);
      }
      y += CARD_FIELD_PITCH;
    }
  } else {
    // A wide page: the pinned grid row, then a row each for the long values.
    const int pinned = meta_cardPinned();
    for (int i = 0; i < pinned; i += 2) {
      meta_drawField(i, meta_cardColX(0), y, CARD_COL_W, valueOff);
      if (i + 1 < pinned) {
        meta_drawField(i + 1, meta_cardColX(1), y, CARD_COL_W, valueOff);
      }
      y += CARD_FIELD_PITCH;
    }

    const int slots = meta_cardWideSlots();
    const int first = grid + (cardPage - gridPages) * slots;
    const int fullW = DispWidth - 2 * CARD_MARGIN_X;
    for (int i = first; i < metaFieldCount && i < first + slots; i++) {
      meta_drawField(i, CARD_MARGIN_X, y, fullW, valueOff);
      y += CARD_FIELD_PITCH;
    }
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
  const int xByte    = meta_iconX() / 2;       // 85, or 0 when flipped

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

  const int tx = meta_textX();
  const int tw = meta_textW();

  // --- Header --------------------------------------------------------------
  // Fixed caption rather than the game title: the title has moved below the
  // rule where it gets a larger font and the full width of the column.
  oled_setfont(CON_HEADER_FONT);
  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setBackgroundColor(SSD1322_BLACK);

  // How many pages the field list needs, worked out before the header is
  // drawn so the caption can be clipped short of the pips rather than run
  // under them.
  const int pinned = meta_pinnedRows();
  const int slots  = meta_pageSlots();
  int pages = meta_pageCount();
  if (fieldPage >= pages) fieldPage = 0;

  int pipCount = (pages > 1) ? (pages < CON_PIP_MAX ? pages : CON_PIP_MAX) : 0;
  int pipBlock = pipCount ? (pipCount * CON_PIP_STRIDE + 2) : 0;

  meta_drawClipped(CON_HEADER_TEXT, tx, CON_HEADER_Y, tw - pipBlock, 0);

  // Page indicator, hard against the icon panel so it reads as belonging to
  // the header row. It used to sit along the bottom, which cost a field row.
  for (int p = 0; p < pipCount; p++) {
    oled.fillRect(tx + tw - pipBlock + 2 + p * CON_PIP_STRIDE, CON_PIP_Y,
                  CON_PIP_W, CON_PIP_H,
                  (p == fieldPage) ? SSD1322_WHITE : 4);
  }

  oled.drawFastHLine(tx - 2, CON_RULE_Y, tw + 2, 6);

  // --- Title, with marquee when it overflows -------------------------------
  oled_setfont(CON_TITLE_FONT);
  const int titleX   = tx;
  const int titleWin = tw;

  u8g2.setForegroundColor(SSD1322_WHITE);

  int titw = meta_textWidth(metaTitle);
  if (titw <= titleWin) {
    titleScrollX = 0;
    meta_drawClipped(metaTitle, titleX, CON_TITLE_Y, titleWin, 0);
  } else {
    meta_drawClipped(metaTitle, titleX, CON_TITLE_Y, titleWin, (int)titleScrollX);
    // Second copy trailing the first so the wrap reads continuously.
    int wrapAt = titw + SCROLL_GAP;
    if (titleScrollX > wrapAt - titleWin) {
      meta_drawClipped(metaTitle, titleX, CON_TITLE_Y, titleWin,
                       (int)titleScrollX - wrapAt);
    }
  }

  // --- Field list ----------------------------------------------------------
  oled_setfont(CON_FIELD_FONT);
  const int valueOff = meta_valueOffset();
  int y = CON_FIELD_Y0;

  // Pinned rows first, identical on every page...
  for (int i = 0; i < pinned; i++) {
    meta_drawField(i, tx, y, tw, valueOff);
    y += CON_FIELD_PITCH;
  }

  // ...then this page's share of the rest.
  int start = pinned + fieldPage * slots;
  for (int i = start; i < metaFieldCount && i < start + slots; i++) {
    meta_drawField(i, tx, y, tw, valueOff);
    y += CON_FIELD_PITCH;
  }

  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setBackgroundColor(SSD1322_BLACK);

  // --- Icon ----------------------------------------------------------------
  meta_blitIcon();
}

// ---------------------------------------------------------------------------
// The rows a page turn changes, for pagefade.h. Everything above them - the
// header, the rule, the title and the pinned fields - is identical on every
// page and must not move or flicker.
//
// Both are derived from the same constants the renderers use, so a layout
// change carries the fade with it; test_meta_layout checks that the first
// paged row's glyphs fall inside the rectangle and the last pinned row's
// fall outside it.
// ---------------------------------------------------------------------------

// Console: the paged field rows, in the text column only - the icon panel
// beside them belongs to neither page.
static void meta_consolePagedRect(int *x, int *w, int *y0, int *y1) {
  const int firstPaged = meta_pinnedRows();          // row index of the first
  *x  = meta_textX();
  *w  = meta_textW();
  // The top row of that field: its baseline less the glyph height above it.
  *y0 = CON_FIELD_Y0 + firstPaged * CON_FIELD_PITCH - CON_FIELD_ASCENT;
  *y1 = DispHeight;
}

// Card: the rows below the pinned grid row, across the whole panel.
static void meta_cardPagedRect(int *x, int *w, int *y0, int *y1) {
  const int firstPaged = meta_cardPairRows(meta_cardPinned());
  *x  = 0;
  *w  = DispWidth;
  *y0 = CARD_FIELD_Y0 + firstPaged * CARD_FIELD_PITCH - CARD_FIELD_ASCENT;
  *y1 = DispHeight;
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
  // A Fade darkens the picture on the panel step by step, so it has to take
  // that picture before the card is rendered over it in the framebuffer.
  if (effect == EFFECT_FADE) transition_prepare();
  meta_renderCard();
  meta_snapshot();

  int savedType = actPicType;
  actPicType = GSC;                 // the card is always 4bpp
  srcBin     = metaBin;
  oled_transition(effect);
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
  oled_transition(effect);
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
  metaNeedsDraw = false;    // whoever drew it, the pending first draw is done
}

// ---------------------------------------------------------------------------
// meta_wakeContrast - the level to return to when the panel wakes.
// metaWakeContrast overrides it; -1 means whatever CMDCON last set, which is
// the user's CONTRAST from the ini.
// ---------------------------------------------------------------------------
static uint8_t meta_wakeContrast(void) {
  if (metaWakeContrast >= 0 && metaWakeContrast <= 255) {
    return (uint8_t)metaWakeContrast;
  }
  return contrast;
}

// ---------------------------------------------------------------------------
// meta_activity - new content arrived.
//
// Restores full brightness if the panel had dimmed and restarts the idle
// timer.
//
// Deliberately NOT called from the draw helpers. The marquee redraws every
// 40ms and the field pager every 2.5s, both through meta_showConsole, so
// treating any draw as activity meant a console game with a long title or a
// second page never went idle and never dimmed. Activity is the arrival of
// something new to show - a command from the MiSTer - not the animation of
// what is already there, which carries on quite happily at reduced
// brightness.
// ---------------------------------------------------------------------------
void meta_activity(void) {
  metaLastActivity = millis();
  if (metaDimmed) {
    contrast_fadeTo(meta_wakeContrast());
    metaDimmed = false;
  }
}

// ---------------------------------------------------------------------------
// meta_dimTick - lower the contrast once nothing has been drawn for a while.
//
// Lowering brightness is half the burn-in story; meta_flipTick moving the
// layout from side to side is the other half, and the two are independent.
// ---------------------------------------------------------------------------
static void meta_dimTick(unsigned long now) {
  if (metaDimAfterMs == 0) return;      // disabled
  if (metaDimmed) return;
  if (now - metaLastActivity < metaDimAfterMs) return;

  // Never above the waking level: a DIM_CONTRAST brighter than CONTRAST would
  // otherwise make "dimming" light the panel up after two idle minutes.
  int level = metaDimContrast;
  if (level < 0)   level = 0;
  if (level > 255) level = 255;
  if (level > meta_wakeContrast()) level = meta_wakeContrast();

  contrast_fadeOver((uint8_t)level, (uint16_t)metaDimFadeMs);
  metaDimmed = true;
}

// ---------------------------------------------------------------------------
// meta_parseDim - CMDDIM,<seconds>,<contrast>,<wake>[,<dim fade ms>]
//
// After <seconds> with nothing new the panel fades, over <dim fade ms>, to
// <contrast> (0..255, never above the waking level); the next command fades
// it back over CONTRAST_FADE_MS. 0 seconds disables. <wake> is the level to
// wake to, or -1 for whatever CMDCON set. The fade time is optional so a
// script that predates it still works, and keeps whatever was set before.
// ---------------------------------------------------------------------------
bool meta_parseDim(const char *cmd) {
  int secs = 0, level = 80, wake = -1, fade = (int)metaDimFadeMs;
  if (sscanf(cmd, "CMDDIM,%d,%d,%d,%d", &secs, &level, &wake, &fade) < 2) return false;
  if (secs < 0) secs = 0;
  if (secs > 36000) secs = 36000;          // ten hours is plenty of rope
  if (fade < 0) fade = 0;
  if (fade > DIM_FADE_MS_MAX) fade = DIM_FADE_MS_MAX;
  metaDimAfterMs   = (unsigned long)secs * 1000UL;
  metaDimContrast  = level;
  metaWakeContrast = wake;
  metaDimFadeMs    = (unsigned long)fade;
  meta_activity();                         // apply the new waking level now
  return true;
}

// ---------------------------------------------------------------------------
// meta_parseCoreBoot - CMDCBOOT,<ms>
//
// Hold the core picture that is about to arrive for <ms> before letting the
// split layout replace it. Sent only on a core change, and only when the
// game is already known, so receiving it at all is the decision; 0 is
// accepted and simply holds nothing.
// ---------------------------------------------------------------------------
bool meta_parseCoreBoot(const char *cmd) {
  int ms = 0;
  if (sscanf(cmd, "CMDCBOOT,%d", &ms) < 1) return false;
  if (ms < 0) ms = 0;
  if (ms > CORE_BOOT_MS_MAX) ms = CORE_BOOT_MS_MAX;
  coreBootMs      = (unsigned long)ms;
  coreBootHolding = (ms > 0);
  coreBootSince   = 0;                  // stamped when the picture is up
  return true;
}

// ---------------------------------------------------------------------------
// meta_tick - non-blocking periodic work, called from the sketch's main loop.
//
// Arcade : artwork, then each page of the card in turn, then the artwork
//          again - one step every metaInterval seconds.
// Console: advance the marquee and the field pager.
//
// Returns true if it drew anything, so the caller can skip its own redraw.
// ---------------------------------------------------------------------------
// The arcade card alternates with the artwork using the same transition as
// the core change - TRANSITION, as CMDCOR last carried it. It used to pass -1
// here, random, whatever TRANSITION said, so a TRANSITION of 5 wiped the
// artwork in with effect 5 and then every page of the card with a lottery.
extern int tEffect;

// The page a fade is turning to, and the callbacks that draw it once the
// rectangle is black. Statics rather than arguments, because pf_start takes a
// plain function pointer - there is no closure to hand it.
static int  pfNextPage = 0;
static void meta_redrawConsolePage(void) {
  fieldPage = pfNextPage;
  meta_renderConsole();
  metaNeedsDraw = false;            // as meta_showConsole would have done
}
static void meta_redrawCardPage(void)    { cardPage  = pfNextPage; meta_renderCard(); }

bool meta_tick(void) {
  unsigned long now = millis();

  meta_dimTick(now);

  // A page fade owns the panel while it runs: the marquee would redraw the
  // whole frame between its steps and undo them.
  if (pf_active()) { pf_tick(); return true; }

  // Swap the layout's sides periodically so no part of the panel holds the
  // same lit pixels indefinitely. Console only: the arcade card and the
  // full-screen artwork already use the whole width.
  if (metaFlipMs > 0 && metaKind == MKIND_CONSOLE &&
      now - metaLastFlip >= metaFlipMs) {
    metaFlipped  = !metaFlipped;
    metaLastFlip = now;
    titleScrollX = 0;             // the column width changed; restart the marquee
    meta_showConsole();
    return true;
  }

  if (metaKind == MKIND_ARCADE && metaInterval > 0 && metaFieldCount > 0) {
    if (now - metaLastSwap >= (unsigned long)metaInterval * 1000UL) {
      if (!metaShowingCard) {
        meta_showCard(tEffect);              // artwork -> first page
      } else if (cardPage + 1 < meta_cardPageCount()) {
        // One page to the next: only the rows below the pinned grid row
        // change, so only those fade. The title, the rule and the pinned row
        // stay lit throughout.
        int x, w, y0, y1;
        meta_cardPagedRect(&x, &w, &y0, &y1);
        pfNextPage = cardPage + 1;
        metaLastSwap = now;
        pf_start(x, w, y0, y1, meta_redrawCardPage);
      } else {
        cardPage = 0;                   // last page -> back to the artwork
        meta_showPicture(tEffect);
      }
      return true;
    }
    return false;
  }

  if (metaKind == MKIND_CONSOLE) {
    bool dirty = false;

    // The core's own artwork, held before the game's layout replaces it.
    // Nothing below this runs while it is up: the marquee and the pager have
    // nothing to animate yet, and the first draw is the thing being delayed.
    if (coreBootHolding) {
      if (tfState != TF_IDLE) return false;   // the picture is still arriving
      if (coreBootSince == 0) {               // it is up now - start counting
        coreBootSince = now;
        return false;
      }
      if (now - coreBootSince < coreBootMs) return false;
      coreBootHolding = false;
      meta_showConsole();                     // clears metaNeedsDraw
      return true;
    }

    // First draw after new metadata, if nothing else has drawn it already.
    if (metaNeedsDraw) {
      meta_showConsole();     // clears metaNeedsDraw
      return true;
    }

    // Field pager. Same page count the renderer uses. The pinned rows above
    // it do not change, so the fade is given the paged rows only.
    int pages = meta_pageCount();
    if (pages > 1 && now - lastPageTick >= VSCROLL_MS) {
      int x, w, y0, y1;
      meta_consolePagedRect(&x, &w, &y0, &y1);
      pfNextPage   = (fieldPage + 1) % pages;
      lastPageTick = now;
      pf_start(x, w, y0, y1, meta_redrawConsolePage);
      return true;
    }

    // Title marquee. Only runs when the title actually overflows. The window
    // is the text column minus the title indent, measured in the same font the
    // renderer uses, so the scroll and the draw agree on when it overflows.
    oled_setfont(CON_TITLE_FONT);
    const int titleWin = TEXT_W - CON_TITLE_X;
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
