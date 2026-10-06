// Host-side type-check and layout tests for the display code in metadisplay.h.
//
// Compiles metadisplay.h with HAS_METADISPLAY fully enabled against stub
// classes whose signatures are transcribed from the real Adafruit GFX, SSD1322
// and U8g2_for_Adafruit_GFX headers (see stubs/arduino_stubs.h). This proves
// the display code is well-formed and calls those APIs correctly; it does not
// prove the pixels look right, which needs the hardware.
//
// The icon blit is exercised against a real 8192-byte buffer so that, built
// with -fsanitize=address, an out-of-bounds write in the geometry would abort.
//
//   g++ -std=c++11 -Wall -Wextra -fsanitize=address,undefined
//       -o test_meta_layout test_meta_layout.cpp && ./test_meta_layout

#include "stubs/arduino_stubs.h"
#include <string>
#include <algorithm>

// Included before ESP32X is defined, so the ESP8266 branch compiles and no
// LittleFS is needed. That is itself the point of the test below: the boot
// screen's geometry lives outside the ESP32X guard, so the constants are the
// same numbers whichever branch the sketch builds.
#include "../../MiSTer_SSD1322_USB/bootscreen.h"
#include "../../MiSTer_SSD1322_USB/bootlogo.h"
#include "../../MiSTer_SSD1322_USB/panelflip.h"

// The library's panel class, as far as a turned panel goes: transcribed from
// Adafruit_GrayOLED::drawPixel and Adafruit_SSD1322::draw4bppBitmap/display,
// rotations 0 and 2 (the only ones the sketch ever asked for). `sent` is what
// display() put on the glass.
class LibPanel {
public:
    LibPanel(int16_t w, int16_t h) : WIDTH(w), HEIGHT(h) {
        buffer = (uint8_t *)calloc(1, (size_t)w * h / 2);
        sent   = (uint8_t *)calloc(1, (size_t)w * h / 2);
        window_x1 = 0; window_y1 = 0; window_x2 = w - 1; window_y2 = h - 1;
    }
    ~LibPanel() { free(buffer); free(sent); }
    LibPanel(const LibPanel &) = delete;
    LibPanel &operator=(const LibPanel &) = delete;
    void     setRotation(uint8_t r) { rotation = r; }
    uint8_t *getBuffer(void)        { return buffer; }
    void drawPixel(int16_t x, int16_t y, uint16_t color) {
        if (x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT) return;
        if (rotation == 2) { x = WIDTH - x - 1; y = HEIGHT - y - 1; }
        uint8_t *p = &buffer[x / 2 + (y * WIDTH / 2)];
        if (x % 2 == 0) *p = (uint8_t)((*p & 0x0F) | ((color & 0xF) << 4));
        else            *p = (uint8_t)((*p & 0xF0) | (color & 0xF));
    }
    void draw4bppBitmap(uint8_t *bitmap) {
        int n = WIDTH * HEIGHT / 2;
        for (int i = 0; i < n; i++) {
            if (rotation == 2) {
                uint8_t v = bitmap[n - i - 1];
                buffer[i] = (uint8_t)((0xF0 & v) >> 4 | (0x0F & v) << 4);
            } else buffer[i] = bitmap[i];
        }
    }
    void display(void) {
        memcpy(sent, buffer, (size_t)WIDTH * HEIGHT / 2);
        sentX1 = window_x1; sentY1 = window_y1; sentX2 = window_x2; sentY2 = window_y2;
        window_x1 = 0; window_y1 = 0; window_x2 = WIDTH - 1; window_y2 = HEIGHT - 1;
    }
    // The grey at a place on the glass.
    int seen(int x, int y) {
        uint8_t b = sent[x / 2 + y * WIDTH / 2];
        return (x % 2 == 0) ? (b >> 4) : (b & 0x0F);
    }
    void dirty(int16_t x1, int16_t y1, int16_t x2, int16_t y2) {
        window_x1 = x1; window_y1 = y1; window_x2 = x2; window_y2 = y2;
    }
    uint8_t *sent;
    int16_t  sentX1 = 0, sentY1 = 0, sentX2 = 0, sentY2 = 0;
protected:
    int16_t  WIDTH, HEIGHT;
    uint8_t *buffer;
    int16_t  window_x1, window_y1, window_x2, window_y2;
    uint8_t  rotation = 0;
};

unsigned long g_fakeMillis = 1000;

// --- Globals the sketch owns, mirrored here ---------------------------------
FakeOled  oled;
FakeU8g2  u8g2;

uint16_t DispWidth = 256, DispHeight = 64;
uint16_t DispLineBytes1bpp = 32, DispLineBytes4bpp = 128;
int      logoBytes1bpp = 2048;
int      logoBytes4bpp = 8192;
uint8_t  logoBin[8192];
uint8_t *srcBin = logoBin;
// The sketch's contrast global: the waking brightness the dim logic scales.
uint8_t contrast = 200;

enum picType { NONE, XBM, GSC, TXT };
int actPicType = NONE;
const uint8_t minEffect = 1, maxEffect = 23;
int tEffect = -1;                     // TRANSITION, as the last CMDCOR carried it

// Sketch functions the display code calls. Recorded so tests can assert which
// transition source was in effect at draw time.
static int   lastEffect   = -999;
static void *lastSrcAtDraw = nullptr;
static int   lastFontSet  = -1;

#define ESP32X 1
#include "../../MiSTer_SSD1322_USB/metadisplay.h"
#include "../../MiSTer_SSD1322_USB/bootoutro.h"
#include "../../MiSTer_SSD1322_USB/busybar.h"
#include "../../MiSTer_SSD1322_USB/bandnote.h"

// The sketch's version line, as the outro redraws it at each grey.
void boot_printVersion(void) { u8g2.setCursor(BOOT_VER_X, BOOT_VER_Y); u8g2.print("0.4.0b"); }

// Defined after the include so they can name the layout constants; the header
// declares both, which is how the real sketch reaches them too.
// The sketch's render and plain draw, as the sketch has them: rendering fills
// the framebuffer and shows nothing; effect 0 renders and then sends the frame
// to the panel. Both really copy the picture - the Fade transition reads the
// framebuffer back to fade it in, and the panel's shownPeak is how a test
// catches a frame that reached the panel when it should not have.
void oled_renderlogo(void) {
    lastEffect = 0; lastSrcAtDraw = srcBin;
    if (srcBin && actPicType == GSC) memcpy(oled.buf, srcBin, sizeof(oled.buf));
}
void oled_drawlogo(uint8_t e) {
    lastEffect = e; lastSrcAtDraw = srcBin;
    if (e == 0) { oled_renderlogo(); oled.display(); }
}

// Widths a test can tell the fonts apart by: the 5x7 field font, the
// header's narrower and smaller fallbacks, and everything else.
void oled_setfont(int font)   {
    lastFontSet = font;
    u8g2.charW = (font == 0) ? 5 : (font == CON_HEADER_FONT_NARROW) ? 7
               : (font == CON_HEADER_FONT_SMALL) ? 6 : 8;
    u8g2.fontAscent = (font == 0) ? 7 : 11;
}

// --- Harness ----------------------------------------------------------------
static int passed = 0, failed = 0;

static void ok(const char *label, const std::string &got, const std::string &want) {
    if (got == want) { passed++; printf("  \033[32mok\033[0m   %s\n", label); }
    else {
        failed++;
        printf("  \033[31mFAIL\033[0m %s\n       want: [%s]\n       got:  [%s]\n",
               label, want.c_str(), got.c_str());
    }
}
static void okInt(const char *label, long got, long want) {
    char g[32], w[32];
    snprintf(g, sizeof(g), "%ld", got);
    snprintf(w, sizeof(w), "%ld", want);
    ok(label, g, w);
}
static void okBool(const char *label, bool got, bool want) {
    okInt(label, got ? 1 : 0, want ? 1 : 0);
}
static void section(const char *s) { printf("\n\033[1m%s\033[0m\n", s); }

// A page turn fades the rows that change, so it finishes over several ticks
// rather than in the one that started it. Run the clock on until it has.
static void settlePageFade(void) {
    for (int i = 0; i < 200 && pf_active(); i++) { g_fakeMillis += 25; meta_tick(); }
}

int main() {

    section("geometry constants are self-consistent");
    {
        okInt("icon stride",          ICON_STRIDE, 43);
        okInt("icon bytes",           ICON_BYTES, 2752);
        okInt("icon x is even",       ICON_X % 2, 0);
        // The icon must finish exactly at the right edge of the framebuffer:
        // 85 bytes of text column + 43 bytes of icon = 128 bytes per row.
        okInt("icon fills to edge",   (ICON_X / 2) + ICON_STRIDE, 256 / 2);
        okInt("text width",           TEXT_W, 166);
    }

    section("meta_blitIcon writes only into the icon column");
    {
        meta_reset();
        metaKind = MKIND_CONSOLE;

        // Fill the framebuffer with a sentinel and the icon with a marker.
        memset(oled.buf, 0xAA, sizeof(oled.buf));
        memset(iconBin, 0x5C, sizeof(iconBin));
        metaHasIcon = true;

        meta_blitIcon();

        const int rowBytes = 128, xByte = ICON_X / 2;
        bool leftIntact = true, iconWritten = true;
        for (int row = 0; row < 64; row++) {
            for (int b = 0; b < xByte; b++)
                if (oled.buf[row * rowBytes + b] != 0xAA) leftIntact = false;
            for (int b = xByte; b < rowBytes; b++)
                if (oled.buf[row * rowBytes + b] != 0x5C) iconWritten = false;
        }
        okBool("text column untouched", leftIntact, true);
        okBool("icon column written",   iconWritten, true);
    }

    section("meta_blitIcon is a no-op without an icon");
    {
        memset(oled.buf, 0x11, sizeof(oled.buf));
        metaHasIcon = false;
        meta_blitIcon();
        bool untouched = true;
        for (size_t i = 0; i < sizeof(oled.buf); i++)
            if (oled.buf[i] != 0x11) untouched = false;
        okBool("buffer untouched", untouched, true);
    }

    section("console layout keeps text out of the icon column");
    {
        meta_parse("CMDMETA,2,0,A Very Long Game Title That Overflows The Column"
                   "|System=SNES|Region=USA|Year=1990|Company=Nintendo");
        metaHasIcon = false;
        u8g2.resetProbe();

        meta_renderConsole();

        // Nothing drawn may extend past the start of the icon column.
        okBool("no draw past ICON_X", u8g2.maxRight <= ICON_X, true);
        okBool("something was drawn",  u8g2.printCalls > 0, true);
    }

    section("console layout: header, then bare title, then fields");
    {
        meta_parse("CMDMETA,2,0,Tetris|System=GAMEBOY|Region=USA|Format=GB");
        metaHasIcon = false;
        u8g2.resetProbe();

        meta_renderConsole();

        okBool("header drawn",
               u8g2.printLog.find("Now playing") != std::string::npos, true);
        okBool("title carries no label",
               u8g2.printLog.find("Title:") == std::string::npos, true);
        okBool("game title drawn",
               u8g2.printLog.find("Tetris") != std::string::npos, true);
        okBool("field labels drawn",
               u8g2.printLog.find("System") != std::string::npos, true);
        // The old layout put the game title above the rule; the header is
        // fixed text now, so the title must not be there any more.
        okBool("rows stay on screen",
               CON_FIELD_Y0 + (CON_FIELD_ROWS - 1) * CON_FIELD_PITCH < DispHeight, true);
        okBool("title sits below the rule", CON_TITLE_Y > CON_RULE_Y, true);
        okBool("fields sit below the title", CON_FIELD_Y0 > CON_TITLE_Y, true);
        okBool("no draw past ICON_X", u8g2.maxRight <= ICON_X, true);
    }

    section("a short console title is drawn without a marquee to trigger it");
    {
        // The Airwolf case. A game change sends CMDMETA and nothing else: the
        // core has not changed so no CMDCOR follows, and NES ships no icon so
        // no CMDICON either. A title this short never marquees and two fields
        // never page, so before the pending-draw flag nothing ever put it on
        // screen and the previous game stayed up.
        meta_parse("CMDMETA,2,12,Airwolf|System=NES|Format=NES");
        metaHasIcon = false;
        u8g2.resetProbe();

        okBool("tick draws it", meta_tick(), true);
        okBool("title reached the screen",
               u8g2.printLog.find("Airwolf") != std::string::npos, true);

        // ...and exactly once. A short title has nothing to animate, so the
        // ticks after it must go back to doing nothing.
        g_fakeMillis += SCROLL_PAUSE_MS + meta_pageDwellMs() + 1;
        okBool("the next tick is idle", meta_tick(), false);
    }

    section("a draw from CMDCOR or CMDICON satisfies the pending first draw");
    {
        meta_parse("CMDMETA,2,12,Airwolf|System=NES|Format=NES");
        metaHasIcon = false;
        meta_showConsole();            // as the CMDCOR handler does
        okBool("tick does not draw it again", meta_tick(), false);
    }

    section("arcade metadata does not ask for a console draw");
    {
        // Arcade alternates from its own timer and must show the artwork
        // first, so a fresh card must not jump the queue.
        meta_parse("CMDMETA,1,12,Pong|Year=1972");
        okBool("no pending console draw", metaNeedsDraw, false);
    }

    section("title marquee measures the unlabelled window");
    {
        // The window is the whole text column bar the 2px indent now. A title
        // that fits it must sit still; one just past it must scroll. A tick
        // still measuring against a label width would move the first one.
        oled_setfont(CON_TITLE_FONT);
        int charW      = meta_textWidth("M");
        int fitsWindow = (TEXT_W - CON_TITLE_X) / charW;

        std::string fits((size_t)(fitsWindow - 1), 'M');
        std::string cmd = "CMDMETA,2,0," + fits + "|System=SNES";
        meta_parse(cmd.c_str());

        titleScrollX    = 0;
        scrollHoldUntil = 0;
        lastScrollTick  = 0;
        g_fakeMillis   += SCROLL_PAUSE_MS + 1;
        g_fakeMillis   += SCROLL_STEP_MS + 1;
        meta_tick();
        okBool("a title that fits stays put", titleScrollX == 0, true);

        std::string over((size_t)(fitsWindow + 2), 'M');
        cmd = "CMDMETA,2,0," + over + "|System=SNES";
        meta_parse(cmd.c_str());

        titleScrollX    = 0;
        scrollHoldUntil = 0;
        lastScrollTick  = 0;
        g_fakeMillis   += SCROLL_PAUSE_MS + 1;
        g_fakeMillis   += SCROLL_STEP_MS + 1;
        meta_tick();                             // absorbed by the first draw
        meta_tick();
        okBool("a title that overflows scrolls", titleScrollX > 0, true);
    }

    section("arcade card keeps a short title whole and clips a long one");
    {
        meta_parse("CMDMETA,1,12,Pong|Year=1972");
        u8g2.resetProbe();
        meta_renderCard();
        okBool("short title fits on screen", u8g2.maxRight <= (int)DispWidth, true);
        okBool("short title not negative",   u8g2.minLeft >= 0, true);

        std::string longTitle(60, 'W');
        std::string cmd = "CMDMETA,1,12," + longTitle + "|Year=1972";
        meta_parse(cmd.c_str());
        u8g2.resetProbe();
        meta_renderCard();
        okBool("long title clipped to width", u8g2.maxRight <= (int)DispWidth, true);
        okBool("long title starts at x=0",    u8g2.minLeft >= 0, true);
    }

    section("arcade card: the console's header, rule and title, and the Arcade cell");
    {
        // The card is the console layout's top half across the whole width,
        // so its rows are the console's rather than numbers of its own.
        okInt ("fields start where the console's do", CARD_FIELD_Y0, CON_FIELD_Y0);
        okInt ("on the console's pitch",             CARD_FIELD_PITCH, CON_FIELD_PITCH);
        okInt ("four field rows",                    CARD_FIELD_ROWS, 4);
        okBool("every field row is on the panel",
               CARD_FIELD_Y0 + (CARD_FIELD_ROWS - 1) * CARD_FIELD_PITCH
                   <= (int)DispHeight - 1, true);
        // The cell encloses the rows above the rule: its text's top row is on
        // the panel and its descender row is above the rule.
        okBool("the cell's text is below the top edge",
               CARD_CELL_Y - CARD_CELL_ASCENT >= 0, true);
        okBool("and above the rule", CARD_CELL_Y < CON_RULE_Y, true);

        // Two columns and a gutter, filling the width between the margins.
        okInt("columns fill the width",
              meta_cardColX(1) + CARD_COL_W, (int)DispWidth - CARD_MARGIN_X);
        okInt("gutter between the columns",
              meta_cardColX(1) - (meta_cardColX(0) + CARD_COL_W), CARD_COL_GAP);

        meta_parse("CMDMETA,1,12,2,8,NBA Jam"
                   "|Year=1993|Manufctr=Midway|Region=World|Orient=Horizontal"
                   "|Core=tunit|Author=someone|Set=nbajam|MAME=0289|Buttons=Shoot");
        for (int page = 0; page < 2; page++) {
            cardPage = page;
            u8g2.resetProbe();
            oled.resetProbe();
            meta_renderCard();

            const FakeU8g2::Draw *head  = u8g2.find(CON_HEADER_TEXT);
            const FakeU8g2::Draw *title = u8g2.find("NBA Jam");
            const FakeU8g2::Draw *cell  = u8g2.find(CARD_CELL_TEXT);
            okBool("the header is drawn", head != nullptr, true);
            okBool("the title is drawn",  title != nullptr, true);
            okBool("the cell is drawn",   cell != nullptr, true);
            if (!head || !title || !cell) break;

            okInt("header at the console's baseline", head->y, CON_HEADER_Y);
            okInt("at the left margin",               head->x, CARD_MARGIN_X);
            okInt("title at the console's baseline",  title->y, CON_TITLE_Y);
            okInt("at the left margin",               title->x, CARD_MARGIN_X);
            okInt("the cell's text on its baseline",  cell->y, CARD_CELL_Y);
            // Centred between the cell's rule and the right edge, to a pixel.
            const int left  = cell->x - (CARD_CELL_X + 1);
            const int right = (int)DispWidth - (cell->x + (int)cell->text.size() * cell->charW);
            okBool("centred in the cell", left >= 0 && right >= 0
                                          && left - right <= 1 && right - left <= 1, true);

            okInt("one rule across the panel",   (int)oled.hlines.size(), 1);
            okInt("at the console's rule row",   oled.hlines[0].y, CON_RULE_Y);
            okInt("from the left edge",          oled.hlines[0].x, 0);
            okInt("to the right edge",           oled.hlines[0].w, DispWidth);
            okInt("one rule closing the cell",   (int)oled.vlines.size(), 1);
            okInt("at the cell's column",        oled.vlines[0].x, CARD_CELL_X);
            okInt("from the top edge",           oled.vlines[0].y, 0);
            okInt("down to the rule it meets",   oled.vlines[0].y + oled.vlines[0].h,
                                                 CON_RULE_Y);
        }
        cardPage = 0;
    }

    section("the arcade card: a grid page, then a wide page under the pinned row");
    {
        // The shape asked for. Eight short values pair up on page 0; the
        // three long ones get a row each on page 1, under a repeat of the
        // pinned Year/Manufctr row.
        meta_parse("CMDMETA,1,12,2,8,NBA Jam (rev 3.01 04/07/93)"
                   "|Year=1993|Manufctr=Midway|Region=World|Orient=Horizontal"
                   "|Core=blahmid_tunit|Author=rejectedcoins|Set=nbajam|MAME=0289"
                   "|Players=4|Controls=8-way|Buttons=Turbo/Shoot / Block/Pass / Steal");

        okInt("fields",      metaFieldCount, 11);
        okInt("paired",      meta_cardGridCount(), 8);
        okInt("pinned",      meta_cardPinned(), 2);
        okInt("grid pages",  meta_cardGridPages(), 1);
        okInt("wide pages",  meta_cardWidePages(), 1);
        okInt("two pages in all", meta_cardPageCount(), 2);

        // --- page 0: four rows of two -------------------------------------
        cardPage = 0;
        u8g2.resetProbe();
        meta_renderCard();

        okInt("header, cell and title, then eight labels and eight values",
              u8g2.printCalls, 3 + 16);

        okInt("Year is row 0, left",      u8g2.xOf("Year"),     meta_cardColX(0));
        okInt("Manufctr is row 0, right", u8g2.xOf("Manufctr"), meta_cardColX(1));
        okInt("Set is row 3, left",       u8g2.xOf("Set"),      meta_cardColX(0));
        okInt("MAME is row 3, right",     u8g2.xOf("MAME"),     meta_cardColX(1));
        // Row-major: the pairs read across, not down, so the third field
        // starts the second row rather than continuing the first column.
        int regionY = -1;
        for (size_t i = 0; i < u8g2.draws.size(); i++)
            if (u8g2.draws[i].text == "Region") regionY = u8g2.draws[i].y;
        okInt("Region is on the row below Year",
              regionY, CARD_FIELD_Y0 + CARD_FIELD_PITCH);
        okBool("nothing runs off the panel", u8g2.maxRight <= (int)DispWidth, true);
        okBool("nothing on a fifth row",
               u8g2.draws.back().y <= CARD_FIELD_Y0 + 3 * CARD_FIELD_PITCH, true);
        okBool("page 0 has none of the long values",
               u8g2.printLog.find("Buttons") == std::string::npos, true);

        // --- page 1: the pinned pair, then one field per row ---------------
        cardPage = 1;
        u8g2.resetProbe();
        meta_renderCard();

        okBool("pinned Year repeats",     u8g2.printLog.find("Year")     != std::string::npos, true);
        okBool("pinned Manufctr repeats", u8g2.printLog.find("Manufctr") != std::string::npos, true);
        okInt ("the pinned pair is still a grid row",
               u8g2.xOf("Manufctr"), meta_cardColX(1));
        okBool("Players is on its own row",  u8g2.printLog.find("Players")  != std::string::npos, true);
        okBool("Controls is on its own row", u8g2.printLog.find("Controls") != std::string::npos, true);
        okBool("Buttons is on its own row",  u8g2.printLog.find("Buttons")  != std::string::npos, true);
        okBool("the long value survives whole",
               u8g2.printLog.find("Turbo/Shoot / Block/Pass / Steal") != std::string::npos, true);
        okBool("no grid field bar the pinned pair",
               u8g2.printLog.find("Core") == std::string::npos, true);

        // Wide rows start in the left column, not the right one.
        okInt("Buttons starts at the left margin", u8g2.xOf("Buttons"), CARD_MARGIN_X);
        okBool("still nothing off the panel", u8g2.maxRight <= (int)DispWidth, true);

        // Every value on the card starts at the same x, paired or not.
        okBool("paired and wide values share a column",
               u8g2.xOf("8-way") == u8g2.xOf("1993"), true);

        cardPage = 0;
    }

    section("card pages: artwork, page 1, page 2, artwork");
    {
        meta_parse("CMDMETA,1,10,2,8,NBA Jam"
                   "|Year=1993|Manufctr=Midway|Region=World|Orient=Horizontal"
                   "|Core=blahmid_tunit|Author=rejectedcoins|Set=nbajam|MAME=0289"
                   "|Players=4|Controls=8-way|Buttons=Turbo/Shoot");

        g_fakeMillis    = 700000;
        metaLastSwap    = g_fakeMillis;
        metaShowingCard = false;
        cardPage        = 0;

        okBool("nothing before the interval", meta_tick(), false);

        g_fakeMillis += 11000;
        u8g2.resetProbe();
        okBool("artwork -> page 1",   meta_tick(), true);
        okBool("card is up",          metaShowingCard, true);
        okInt ("on the grid page",    cardPage, 0);
        okBool("grid page drawn",     u8g2.printLog.find("Core") != std::string::npos, true);

        g_fakeMillis += 11000;
        u8g2.resetProbe();
        okBool("page 1 -> page 2",    meta_tick(), true);
        okBool("the pinned rows do not move for it", pf_active(), true);
        settlePageFade();
        okBool("card still up",       metaShowingCard, true);
        okInt ("on the wide page",    cardPage, 1);
        okBool("wide page drawn",     u8g2.printLog.find("Buttons") != std::string::npos, true);

        g_fakeMillis += 11000;
        okBool("last page -> artwork", meta_tick(), true);
        okBool("artwork is up",        metaShowingCard, false);
        okBool("drawn from logoBin",   lastSrcAtDraw == logoBin, true);
        okInt ("rewound to page 1",    cardPage, 0);

        g_fakeMillis += 11000;
        okBool("and round again", meta_tick(), true);
        okBool("card is up",      metaShowingCard, true);
        okInt ("from the top",    cardPage, 0);
    }

    section("a card with only grid fields is one page and does not page");
    {
        meta_parse("CMDMETA,1,12,2,4,Pong|Year=1972|Manufctr=Atari"
                   "|Region=World|Orient=Horizontal");
        okInt("one page", meta_cardPageCount(), 1);

        u8g2.resetProbe();
        oled.resetProbe();
        meta_renderCard();
        okInt("no page indicator", (int)oled.rects.size(), 0);

        metaLastSwap    = g_fakeMillis;
        metaShowingCard = true;
        g_fakeMillis   += 13000;
        okBool("swaps straight back to the artwork", meta_tick(), true);
        okBool("artwork is up", metaShowingCard, false);
        okInt ("page unmoved",  cardPage, 0);
    }

    section("a card the script sent no counts for still shows everything");
    {
        // An older script, or ARCADE_FIELDS left holding only wide names:
        // no pairing, no pinning, one field per row, paged. The fields must
        // still all reach the screen.
        std::string cmd = "CMDMETA,1,12,Game";
        const int nfields = 10;
        for (int i = 0; i < nfields; i++) {
            char seg[32];
            snprintf(seg, sizeof(seg), "|L%02d=V%02d", i, i);  // L1 is no prefix of L10
            cmd += seg;
        }
        meta_parse(cmd.c_str());

        okInt("nothing paired", meta_cardGridCount(), 0);
        okInt("no grid pages",  meta_cardGridPages(), 0);
        okInt("three pages",    meta_cardPageCount(), 3);

        int seen[nfields];
        for (int i = 0; i < nfields; i++) seen[i] = 0;

        for (int page = 0; page < meta_cardPageCount(); page++) {
            cardPage = page;
            u8g2.resetProbe();
            meta_renderCard();
            for (int i = 0; i < nfields; i++) {
                char label[8];
                snprintf(label, sizeof(label), "L%02d", i);
                if (u8g2.printLog.find(label) != std::string::npos) seen[i]++;
            }
        }

        bool everyFieldOnce = true;
        for (int i = 0; i < nfields; i++) if (seen[i] != 1) everyFieldOnce = false;
        okBool("every field appears exactly once", everyFieldOnce, true);

        cardPage = 0;
    }

    section("card page indicator tracks the page and stays on the panel");
    {
        meta_parse("CMDMETA,1,12,2,8,Game"
                   "|Year=1993|Manufctr=Midway|Region=World|Orient=Horizontal"
                   "|Core=tunit|Author=someone|Set=nbajam|MAME=0289"
                   "|Buttons=Turbo/Shoot");

        cardPage = 1;
        u8g2.resetProbe();
        oled.resetProbe();
        meta_renderCard();

        okInt("one pip per page", (int)oled.rects.size(), meta_cardPageCount());

        int lit = -1, leftmost = DispWidth, right = 0;
        bool onPanel = true;
        for (size_t i = 0; i < oled.rects.size(); i++) {
            const FakeOled::Rect &r = oled.rects[i];
            if (r.color == SSD1322_WHITE) lit = (int)i;
            if (r.x < leftmost) leftmost = r.x;
            if (r.x + r.w > right) right = r.x + r.w;
            if (r.x < 0 || r.y < 0 || r.x + r.w > (int)DispWidth
                || r.y + r.h > (int)DispHeight) onPanel = false;
        }
        okInt ("the current page is the lit pip", lit, 1);
        okBool("pips are on the panel",           onPanel, true);
        okInt ("pips end short of the cell",      right, CARD_CELL_X - CARD_PIP_GAP);
        okBool("on the header's row",             oled.rects[0].y == CON_PIP_Y, true);

        // The header is drawn first, and must be clipped short of the pips
        // rather than run underneath them. Its width is what the stub font
        // measured at the time, which is recorded with the draw.
        const FakeU8g2::Draw &head = u8g2.draws[0];
        ok    ("the header comes first", head.text, CON_HEADER_TEXT);
        okBool("header stops short of the pips",
               head.x + (int)head.text.size() * head.charW <= leftmost, true);

        // The most pages a card can have - every field wide, none pinned -
        // still leaves the header whole beside their pips.
        std::string cmd = "CMDMETA,1,12,Game";
        for (int i = 0; i < META_MAX_FIELDS; i++) {
            char seg[32];
            snprintf(seg, sizeof(seg), "|L%02d=V%02d", i, i);
            cmd += seg;
        }
        meta_parse(cmd.c_str());
        u8g2.resetProbe();
        oled.resetProbe();
        meta_renderCard();
        okInt ("a pip per page", (int)oled.rects.size(), meta_cardPageCount());
        okBool("of which there are several", meta_cardPageCount() >= 4, true);
        ok    ("header whole beside them", u8g2.draws[0].text, CON_HEADER_TEXT);
        okBool("and clear of them",
               u8g2.draws[0].x + (int)strlen(CON_HEADER_TEXT) * u8g2.draws[0].charW
                   <= oled.rects[0].x, true);

        cardPage = 0;
    }

    section("a long arcade title scrolls, once the card is up");
    {
        // 40 characters is 320px in the title face, wider than the panel.
        std::string title(40, 'W');
        std::string cmd = "CMDMETA,1,12," + title + "|Year=1989";
        g_fakeMillis = 800000;
        meta_parse(cmd.c_str());

        uint16_t keepFade = tfFadeMs;
        tfFadeMs = 0;
        actPicType = GSC;
        metaShowingCard = false;
        okBool("nothing scrolls behind the artwork",
               !meta_tick() && titleScrollX == 0, true);

        meta_showCard(0);
        okInt ("the card starts at the beginning", titleScrollX, 0);
        // The pause is timed from the card landing, not from the request:
        // however long the transition took, the first tick only starts it.
        g_fakeMillis += 5000;
        okBool("the first tick on the card starts the hold", meta_tick(), false);
        okInt ("so nothing moved",                           titleScrollX, 0);
        g_fakeMillis += SCROLL_STEP_MS + 1;
        meta_tick();
        okInt ("still holding",                              titleScrollX, 0);
        g_fakeMillis += SCROLL_PAUSE_MS;
        oled.resetProbe();
        okBool("then it scrolls", meta_tick(), true);
        okInt ("a pixel",         titleScrollX, 1);
        okBool("and is pushed to the panel", oled.displayCalls > 0, true);

        u8g2.resetProbe();
        meta_renderCard();
        const FakeU8g2::Draw *t = u8g2.find("W");
        okBool("drawn a pixel to the left",
               t && t->x == CARD_MARGIN_X - 1 && t->y == CON_TITLE_Y, true);
        okBool("clipped to the panel", u8g2.maxRight <= (int)DispWidth, true);

        // A title that fits never moves.
        meta_parse("CMDMETA,1,12,Pong|Year=1972");
        meta_showCard(0);
        g_fakeMillis += 1;
        meta_tick();
        g_fakeMillis += SCROLL_PAUSE_MS + SCROLL_STEP_MS + 1;
        okBool("a short title stays put", !meta_tick() && titleScrollX == 0, true);
        tfFadeMs = keepFade;
    }

    section("a Buttons value too long for its row scrolls under its label");
    {
        std::string buttons = "Turbo/Shoot / Block/Pass / Steal / Start / Coin"
                              " / Service / Test / Tilt";
        std::string cmd = "CMDMETA,1,12,2,2,Game|Year=1993|Manufctr=Midway"
                          "|Buttons=" + buttons;
        meta_parse(cmd.c_str());
        okInt("a grid page and a wide page", meta_cardPageCount(), 2);

        cardPage = 0;
        okInt("nothing to scroll on the grid page", meta_cardValueWrap(), 0);
        cardPage = 1;
        okBool("the wide page has", meta_cardValueWrap() > 0, true);

        g_fakeMillis = 900000;
        uint16_t keepFade = tfFadeMs;
        tfFadeMs = 0;
        meta_showCard(0);
        okInt("on the wide page", cardPage, 1);
        g_fakeMillis += 1;
        meta_tick();                                  // lands: starts the hold
        g_fakeMillis += SCROLL_PAUSE_MS + SCROLL_STEP_MS + 1;
        okBool("it scrolls", meta_tick(), true);
        okInt ("a pixel",    valueScrollX, 1);
        okInt ("the title does not", titleScrollX, 0);

        oled_setfont(CARD_FIELD_FONT);
        const int col = CARD_MARGIN_X + meta_fieldValueX(2, meta_cardValueOffset());
        u8g2.resetProbe();
        oled.resetProbe();
        meta_renderCard();
        const FakeU8g2::Draw *v = u8g2.find("Turbo");
        okBool("the value moved left of its column", v && v->x == col - 1, true);
        const FakeU8g2::Draw *label = nullptr;
        for (size_t i = 0; i < u8g2.draws.size(); i++)
            if (u8g2.draws[i].text == "Buttons") label = &u8g2.draws[i];
        okBool("the label is drawn last, over it",
               label && label == &u8g2.draws.back(), true);
        bool masked = false;
        for (size_t i = 0; i < oled.rects.size(); i++) {
            const FakeOled::Rect &r = oled.rects[i];
            if (r.color == SSD1322_BLACK && r.x == 0 && r.x + r.w == col
                && r.y == label->y - CARD_FIELD_ASCENT) masked = true;
        }
        okBool("with the label's side of the row blacked first", masked, true);
        okBool("nothing past the right edge", u8g2.maxRight <= (int)DispWidth, true);

        // A page turn starts the values over.
        valueScrollX = 25;
        pfNextPage = 1;
        meta_redrawCardPage();
        okInt("a new page starts from the start", valueScrollX, 0);

        // Round the whole wrap: back to 0, and held there again.
        const int wrap = meta_cardValueWrap();
        valueScrollX   = wrap - 1;
        valueHoldUntil = 0;
        g_fakeMillis  += SCROLL_STEP_MS + 1;
        meta_tick();
        okInt ("wraps to the start",   valueScrollX, 0);
        g_fakeMillis  += SCROLL_STEP_MS + 1;
        meta_tick();
        okInt ("and pauses there",     valueScrollX, 0);

        cardPage = 0;
        tfFadeMs = keepFade;
    }

    section("meta_showCard animates from metaBin then restores srcBin");
    {
        meta_parse("CMDMETA,1,12,Donkey Kong|Year=1981");
        actPicType = GSC;
        srcBin = logoBin;

        meta_showCard(7);

        okInt ("effect passed through",     lastEffect, 7);
        okBool("drew from metaBin",         lastSrcAtDraw == metaBin, true);
        okBool("srcBin restored to logoBin", srcBin == logoBin, true);
        okInt ("actPicType restored",        actPicType, GSC);
        okBool("card flag set",              metaShowingCard, true);
    }

    section("meta_showPicture animates from logoBin");
    {
        meta_showPicture(3);
        okInt ("effect passed through", lastEffect, 3);
        okBool("drew from logoBin",     lastSrcAtDraw == logoBin, true);
        okBool("card flag cleared",     metaShowingCard, false);
    }

    section("a core name drawn as text comes back after the card");
    {
        // No artwork: the sketch drew the name straight into the framebuffer
        // and left actPicType NONE. Coming back from the card rendered
        // nothing, so the artwork half of the alternation was a blank panel.
        meta_parse("CMDMETA,1,12,NBA Hang Time|Year=1996");
        memset(logoBin, 0, sizeof(logoBin));
        memset(oled.buf, 0, sizeof(oled.buf));
        oled.buf[4000] = 0xF0;                  // the name, as far as this cares
        actPicType = NONE;
        srcBin = logoBin;

        meta_showCard(7);
        okInt ("kept as a 4bpp picture", actPicType, GSC);
        okInt ("the name is in logoBin", logoBin[4000], 0xF0);

        memset(oled.buf, 0, sizeof(oled.buf));  // the card is on the panel now
        meta_showPicture(0);
        okInt ("and is drawn again",     oled.buf[4000], 0xF0);
    }

    section("arcade alternation respects the interval");
    {
        meta_parse("CMDMETA,1,10,Donkey Kong|Year=1981");
        g_fakeMillis = 100000;
        metaLastSwap = g_fakeMillis;
        metaShowingCard = false;

        okBool("no swap before interval", meta_tick(), false);

        g_fakeMillis += 9000;
        okBool("still no swap at 9s", meta_tick(), false);

        g_fakeMillis += 2000;            // 11s total, past the 10s interval
        okBool("swaps at 11s",       meta_tick(), true);
        okBool("now showing card",   metaShowingCard, true);

        g_fakeMillis += 11000;
        okBool("swaps back",         meta_tick(), true);
        okBool("now showing picture", metaShowingCard, false);
    }

    section("arcade alternation is disabled with interval 0 or no fields");
    {
        meta_parse("CMDMETA,1,0,Game|Year=1981");
        g_fakeMillis += 60000;
        okBool("interval 0 never swaps", meta_tick(), false);

        meta_parse("CMDMETA,1,10,Game");     // no fields at all
        g_fakeMillis += 60000;
        okBool("no fields never swaps",  meta_tick(), false);
    }

    section("core boot screen: the artwork is held before the layout");
    {
        // CMDCBOOT arms the hold; the picture arriving is what starts it, and
        // that is stamped on the first tick after the transition goes idle -
        // so a slow fade in front of the artwork does not eat the hold.
        meta_reset();
        meta_parse("CMDMETA,2,0,Sonic|System=MegaDrive");
        okBool("metadata alone wants drawing", metaNeedsDraw, true);

        meta_parseCoreBoot("CMDCBOOT,3000");
        okBool("CMDCBOOT arms the hold", coreBootHolding, true);

        // While the picture is still transitioning in, nothing is drawn and
        // nothing is timed: the clock has not started.
        tfState = TF_IN;
        g_fakeMillis += 5000;
        okBool("nothing is drawn while the picture arrives", meta_tick(), false);
        okBool("and the hold has not started counting", coreBootSince == 0, true);

        // Up. The first idle tick stamps it and still draws nothing.
        tfState = TF_IDLE;
        okBool("the tick it lands on draws nothing", meta_tick(), false);
        okBool("but starts the clock", coreBootSince != 0, true);
        okBool("the layout is still owed", metaNeedsDraw, true);

        // Most of the way through, still the artwork.
        g_fakeMillis += 2500;
        okBool("part way through, the artwork stays", meta_tick(), false);
        okBool("and the hold is still on", coreBootHolding, true);

        // Past it: the layout goes up, and it is transitioned to rather than
        // drawn - the artwork has been on the panel for three seconds and
        // swapping it for the layout between two frames is the one place in
        // the console path where a cut is visible.
        tEffect = 7;                                  // a wipe, so it completes
        lastEffect = -999; lastSrcAtDraw = nullptr;
        g_fakeMillis += 600;
        okBool("past the hold, the layout is drawn", meta_tick(), true);
        okInt ("through the core's own transition", lastEffect, 7);
        okBool("from the layout, not the artwork", lastSrcAtDraw == metaBin, true);
        okBool("and srcBin is put back afterwards", srcBin == logoBin, true);
        okBool("and the hold is over", coreBootHolding, false);
        okBool("with nothing left owed", metaNeedsDraw, false);

        // A Fade is a state machine, so the layout arrives seconds later. The
        // marquee must not redraw the frame underneath it while it runs: it
        // animates from a copy towards a copy, so anything drawn between two
        // steps is simply overwritten by the next.
        meta_reset();
        std::string wide(60, 'W');                    // long enough to marquee
        meta_parse(("CMDMETA,2,0," + wide + "|System=SNES").c_str());
        meta_parseCoreBoot("CMDCBOOT,3000");
        tEffect = EFFECT_FADE;
        meta_tick();                                  // stamps the clock
        g_fakeMillis += 3100;
        okBool("the fade is started", meta_tick(), true);
        okBool("and it is running", tfState != TF_IDLE, true);
        bool drewDuringFade = false;
        for (int i = 0; i < 40; i++) {
            g_fakeMillis += SCROLL_STEP_MS + 1;
            if (meta_tick()) drewDuringFade = true;
        }
        okBool("nothing animates over a running transition", drewDuringFade, false);

        // Drained before leaving, or every test after this one would find the
        // panel still owned by a fade that nothing was ticking.
        // Both clocks: the fade ends when its palette steps are done AND the
        // contrast veil has come back up, and only contrast_tick moves that.
        for (int i = 0; i < 400 && tfState != TF_IDLE; i++) {
            g_fakeMillis += 25; contrast_tick(); transition_tick();
        }
        okBool("and the fade finishes", tfState == TF_IDLE, true);
        okBool("after which the marquee runs again", meta_tick(), true);
        tEffect = -1;

        // Without a CMDCBOOT nothing is held - a game loaded into a core that
        // is already running appears at once, as it always did - but it is
        // still transitioned to rather than cut to. Whatever is on the panel,
        // the core's artwork with no game yet or the game before this one, is
        // a different picture.
        meta_reset();
        tEffect = 5;
        meta_parse("CMDMETA,2,0,Sonic 2|System=MegaDrive");
        okBool("no CMDCBOOT, no hold", coreBootHolding, false);
        lastEffect = -999; lastSrcAtDraw = nullptr;
        okBool("and the layout is drawn on the next tick", meta_tick(), true);
        okInt ("through a transition, not as a cut", lastEffect, 5);
        okBool("from the layout", lastSrcAtDraw == metaBin, true);
        tEffect = -1;

        // CMDCBOOT,0 is the setting turned off: accepted, holds nothing.
        meta_reset();
        meta_parse("CMDMETA,2,0,Sonic 3|System=MegaDrive");
        meta_parseCoreBoot("CMDCBOOT,0");
        okBool("CMDCBOOT,0 holds nothing", coreBootHolding, false);
        okBool("and the layout is drawn at once", meta_tick(), true);

        // The sequence a real MiSTer actually produces, taken from the daemon's
        // own log: the core is published seconds before the game, so the hold
        // is armed while there is no metadata at all, and the artwork goes up
        // full-screen. The clock has to run from the artwork, not from the
        // game's arrival, or every game would wait out a fresh hold.
        meta_reset();
        tEffect = 0;
        meta_parseCoreBoot("CMDCBOOT,3000");      // armed with metaKind still OFF
        okBool("armed before any metadata", coreBootHolding, true);
        meta_tick();                              // artwork is up: stamps the clock
        okBool("the clock starts with no metadata at all", coreBootSince != 0, true);

        g_fakeMillis += 1000;                     // a second later the game lands
        meta_parse("CMDMETA,2,0,Sonic|System=MegaDrive");
        okBool("two seconds still owed, so nothing is drawn", meta_tick(), false);
        g_fakeMillis += 2100;
        okBool("then the layout arrives", meta_tick(), true);
        okBool("and the hold is spent", coreBootHolding, false);

        // A game that turns up long after the hold has run is not made to wait
        // for a second one.
        meta_reset();
        meta_parseCoreBoot("CMDCBOOT,3000");
        meta_tick();                              // stamp
        g_fakeMillis += 60000;                    // a minute of staring at artwork
        meta_parse("CMDMETA,2,0,Streets|System=MegaDrive");
        okBool("a late game is drawn at once", meta_tick(), true);
        tEffect = -1;

        // A new core change while one is still held replaces it rather than
        // stacking: meta_reset clears the hold with everything else.
        meta_parse("CMDMETA,2,0,Streets|System=MegaDrive");
        meta_parseCoreBoot("CMDCBOOT,3000");
        meta_reset();
        okBool("meta_reset drops a hold in progress", coreBootHolding, false);

        meta_reset();
    }

    section("a core launched with its game, replayed in the daemon's order");
    {
        // The firmware acts on each command as it lands: between two of them
        // loop() runs the tickers, meta_tick included, whenever the port is
        // quiet. So what the daemon sends first is what happens first, and
        // the order is the whole of the behaviour. This replays it.
        const uint16_t keepFade = tfFadeMs, keepBlank = tfBlankMs;
        tfFadeMs = 800; tfBlankMs = 1000;           // the shipped defaults
        auto quiet = [](unsigned long ms) {         // loop(), port idle
            for (unsigned long t = 0; t < ms; t += 5) {
                g_fakeMillis += 5; contrast_tick(); transition_tick(); meta_tick();
            }
        };
        auto settle = []() {                        // drain whatever is running
            for (int i = 0; i < 400 && tfState != TF_IDLE; i++) {
                g_fakeMillis += 25; contrast_tick(); transition_tick();
            }
        };
        // A picture arriving: the 8KB read blocks, so nothing ticks for its
        // length. draw is CMDCOR, and then the sketch's own branch, which
        // test-wire.sh holds the sketch to; CMDAPD only stores.
        auto picture = [](bool draw) {
            g_fakeMillis += 900;
            memset(logoBin, 0x99, sizeof(logoBin));
            actPicType = GSC;
            tEffect = EFFECT_FADE;
            if (!draw) return;
            if (metaKind == MKIND_CONSOLE && !coreBootHolding) meta_showConsole();
            else oled_transition(tEffect);
        };
        const char *game = "CMDMETA,2,0,Advance Wars|System=GBA|Region=USA";
        tEffect = EFFECT_FADE;                      // what the last CMDCOR carried

        // Why the order matters, pinned so that nobody puts it back. CMDMETA
        // first: the layout's transition is under way before anything behind
        // it - the hold, the picture - has arrived.
        meta_reset();
        meta_parse(game);
        quiet(200);
        okBool("old order: CMDMETA alone starts the layout's transition",
               tfState != TF_IDLE && tfSrc == metaBin, true);
        settle();
        // And CMDCBOOT ahead of the picture starts its clock in the gap
        // before CMDCOR, so the transfer and the fade spend the hold.
        meta_reset();
        meta_parseCoreBoot("CMDCBOOT,3000");
        quiet(50);
        okBool("old order: a hold sent before the picture starts too soon",
               coreBootSince != 0, true);

        // Now as sent: off, picture, hold, game, description, icon.
        meta_reset();
        quiet(200);                                 // CMDMETAOFF's wait
        okBool("nothing moves before the picture", tfState == TF_IDLE, true);
        picture(true);
        okBool("the picture's own transition starts as it lands",
               tfState != TF_IDLE && tfSrc == logoBin, true);
        quiet(50);
        meta_parseCoreBoot("CMDCBOOT,3000");
        quiet(50);
        meta_parse(game);
        quiet(200);
        meta_setDesc("A war game.", 11);
        quiet(400);
        metaHasIcon = true;                         // the icon, 2752 bytes later
        quiet(450);
        okBool("everything after it lands without redirecting the fade",
               tfState != TF_IDLE && tfSrc == logoBin, true);
        okBool("and the hold has not started counting", coreBootSince == 0, true);

        unsigned long up = 0, layoutAt = 0;
        for (int i = 0; i < 2000 && !layoutAt; i++) {
            g_fakeMillis += 5; contrast_tick(); transition_tick(); meta_tick();
            if (!up && tfState == TF_IDLE) up = g_fakeMillis;
            if (up && tfState != TF_IDLE) layoutAt = g_fakeMillis;
        }
        okBool("the artwork reaches the panel", up != 0, true);
        okBool("then the layout's transition follows", layoutAt != 0, true);
        okBool("towards the layout", tfSrc == metaBin, true);
        okBool("after the whole hold, counted from the artwork",
               layoutAt - up >= 3000 && layoutAt - up < 3100, true);
        settle();

        // core_bootscreen_time=0: the picture is stored, not drawn, and the
        // layout is the only transition.
        meta_reset();
        quiet(200);
        picture(false);
        okBool("no hold: the picture is stored and nothing moves", tfState == TF_IDLE, true);
        meta_parse(game);
        quiet(20);
        okBool("and the game's layout is the one transition",
               tfState != TF_IDLE && tfSrc == metaBin, true);
        settle();

        meta_reset();
        tEffect = -1;
        tfFadeMs = keepFade; tfBlankMs = keepBlank;
    }

    section("an icon still in flight makes the fade-in");
    {
        // The daemon sends the console icon just after the metadata, so when a
        // fade starts there may be no icon yet. Composing the layout only at
        // the moment the fade was asked for meant it faded in with a black
        // panel beside the text, and the icon appeared on top afterwards.
        // Composing it again at the bottom of the fade - dead time the panel
        // is not using - gives the transfer the whole fade-out and blank to
        // arrive in.
        auto pump = [](unsigned long ms) {
            g_fakeMillis += ms; contrast_tick(); transition_tick();
        };
        meta_reset();
        tEffect = EFFECT_FADE;
        transition_parse("CMDTFADE,800,1000");
        veil_fadeOver(255, 0);

        metaHasIcon = false;                       // nothing has arrived yet
        memset(iconBin, 0xFF, ICON_BYTES);         // the icon, when it does
        meta_parse("CMDMETA,2,0,Sonic|System=MegaDrive");
        okBool("the fade starts", meta_tick(), true);
        okBool("with the layout composed fresh at black", tfRender != NULL, true);

        // It lands part way through the fade-out, as it does on hardware.
        pump(200);
        metaHasIcon = true;

        // Run to the bottom of the fade and look at what was composed. Not the
        // framebuffer: entering TF_IN blacks that to show the first step. What
        // the fade-in walks back up from is the copy tf_capture took, which is
        // the composed picture itself.
        for (int i = 0; i < 3000 && tfState != TF_IN; i++) pump(5);
        int iconPixels = 0;
        for (int y = 0; y < DispHeight; y++)
            for (int x = meta_iconX() / 2; x < (meta_iconX() + ICON_W) / 2; x++)
                if (fadeBin[y * 128 + x]) iconPixels++;
        okBool("the icon is in the picture the fade-in reveals", iconPixels > 0, true);

        for (int i = 0; i < 3000 && tfState != TF_IDLE; i++) pump(5);
        okBool("and the fade finishes", tfState == TF_IDLE, true);
        okBool("with no redraw left owed", metaIconRedraw, false);

        tEffect = -1; metaHasIcon = false; meta_reset();
    }

    section("computer mode does nothing");
    {
        meta_parse("CMDMETA,3,10,Amiga|System=Minimig");
        g_fakeMillis += 60000;
        okBool("computer mode is inert", meta_tick(), false);
    }

    section("console title marquee advances then wraps");
    {
        // 60 chars at 8px in the title font is far wider than TEXT_W.
        std::string longTitle(60, 'M');
        std::string cmd = "CMDMETA,2,0," + longTitle + "|System=SNES";
        meta_parse(cmd.c_str());
        meta_tick();                             // absorb the first draw

        g_fakeMillis += SCROLL_PAUSE_MS + 1;     // clear the initial hold
        lastScrollTick = 0;

        long before = titleScrollX;
        g_fakeMillis += SCROLL_STEP_MS + 1;
        meta_tick();
        okBool("scroll advanced", titleScrollX > before, true);

        // Run it well past the wrap point and confirm it resets rather than
        // running away to infinity.
        for (int i = 0; i < 2000; i++) {
            g_fakeMillis += SCROLL_STEP_MS + 1;
            meta_tick();
        }
        oled_setfont(7);
        int tw = meta_textWidth(metaTitle);
        okBool("scroll stays bounded", titleScrollX < tw + SCROLL_GAP, true);
        okBool("scroll never negative", titleScrollX >= 0, true);
    }

    section("short console title does not scroll");
    {
        meta_parse("CMDMETA,2,0,Pong|System=Atari");
        titleScrollX = 0;
        for (int i = 0; i < 50; i++) {
            g_fakeMillis += SCROLL_STEP_MS + 1;
            meta_tick();
        }
        // renderConsole zeroes the offset for a title that fits.
        meta_renderConsole();
        okInt("offset stays zero", titleScrollX, 0);
    }

    section("a page turn fades only the rows that change");
    {
        // Two pinned fields and four paged ones: the header, rule, title and
        // the two pinned rows are identical on both pages.
        meta_parse("CMDMETA,2,12,2,Game|System=NES|Year=1987|Genre=Action|Region=USA|Company=N|Format=nes");
        metaFlipped = false;
        meta_tick();                            // first draw
        settlePageFade();

        int x, w, y0, y1;
        meta_consolePagedRect(&x, &w, &y0, &y1);
        okInt ("the rectangle starts at the first paged row",
               y0, CON_FIELD_Y0 + 2 * CON_FIELD_PITCH - CON_FIELD_ASCENT);
        okBool("below the last pinned baseline",
               y0 > CON_FIELD_Y0 + 1 * CON_FIELD_PITCH, true);
        okInt ("and runs to the bottom", y1, DispHeight);
        okInt ("across the text column only", w, meta_textW());
        okBool("so the icon panel is outside it", x + w <= meta_iconX(), true);

        lastPageTick = g_fakeMillis;
        g_fakeMillis += meta_pageDwellMs() + 1;
        okBool("the pager starts a fade", meta_tick() && pf_active(), true);
        okInt ("with the page it is turning to held back", fieldPage, 0);
        okBool("and still running a tick later", pf_active(), true);
        settlePageFade();
        okInt ("the page turns when the fade reaches black", fieldPage, 1);

        // Something else taking the panel must not leave it half dark, nor
        // swallow the page it was turning to.
        lastPageTick = g_fakeMillis;
        g_fakeMillis += meta_pageDwellMs() + 1;
        meta_tick();
        g_fakeMillis += PF_FADE_MAX_MS / 2; meta_tick();
        okBool("a fade is under way", pf_active(), true);
        pf_cancel();
        okBool("cancelling ends it", pf_active(), false);
        okInt ("with the page it was turning to drawn", fieldPage, 0);

        // TRANSITION_FADE_MS=0 means no fading, here as everywhere.
        uint16_t keepFade = tfFadeMs;
        tfFadeMs = 0;
        lastPageTick = g_fakeMillis;
        g_fakeMillis += meta_pageDwellMs() + 1;
        meta_tick();
        okBool("with fading off the page just turns", pf_active(), false);
        okInt ("straight away", fieldPage, 1);
        tfFadeMs = keepFade;
    }

    section("a card page turn keeps its pinned row lit");
    {
        meta_parse("CMDMETA,1,10,2,4,NBA Jam|Year=1993|Manufctr=Midway|Region=World|Orient=Horizontal"
                   "|Players=4|Controls=8-way|Buttons=Shoot");
        int x, w, y0, y1;
        meta_cardPagedRect(&x, &w, &y0, &y1);
        okInt ("the rectangle starts below the pinned grid row",
               y0, CARD_FIELD_Y0 + 1 * CARD_FIELD_PITCH - CARD_FIELD_ASCENT);
        okInt ("and is the full width", w, DispWidth);
        okBool("the pinned row's baseline is above it", CARD_FIELD_Y0 < y0, true);

        metaShowingCard = true;
        cardPage        = 0;
        metaLastSwap    = g_fakeMillis;
        meta_showCard(0);

        g_fakeMillis += 11000;
        okBool("the next page fades rather than transitioning the panel",
               meta_tick() && pf_active(), true);
        okInt ("the page is held back until it is black", cardPage, 0);
        settlePageFade();
        okInt ("the card turned its page", cardPage, 1);
        okBool("without leaving the card", metaShowingCard, true);

        // The last page still goes back to the artwork with a whole-panel
        // transition: that is a different picture, not a page turn.
        g_fakeMillis += 11000;
        okBool("the last page goes back to the artwork", meta_tick(), true);
        okBool("with the picture transition", lastSrcAtDraw == logoBin, true);
        okBool("and no page fade", pf_active(), false);
    }

    section("the title keeps scrolling while the page fades");
    {
        // A title that overflows, and more fields than one page holds.
        meta_parse("CMDMETA,2,12,1,An Extremely Long Game Title That Overflows The Column"
                   "|System=NES|Year=1987|Genre=Action|Region=USA|Company=N|Format=nes");
        metaFlipped = false;
        meta_tick();
        settlePageFade();
        lastPageTick = g_fakeMillis;
        g_fakeMillis += SCROLL_PAUSE_MS + 1;          // past the pause at the start
        meta_tick();

        lastPageTick = g_fakeMillis - meta_pageDwellMs() - 1;
        okBool("a page fade starts", meta_tick() && pf_active(), true);
        // Paint what the fade steps from, so a step undone shows: the render
        // clears the frame, and only pf_reshow puts the rectangle back.
        memset(fadeBin, 0xFF, 8192);
        const long before = titleScrollX;
        bool rectKept = true, sawOut = false;
        for (int i = 0; i < 6 && pfState == PF_OUT; i++) {
            g_fakeMillis += SCROLL_STEP_MS + 1;
            meta_tick();
            if (pfState != PF_OUT) break;
            sawOut = true;
            const uint8_t lvl = (uint8_t)(pfStep >= 15 ? 0 : 15 - pfStep);   // white, pfStep down
            const uint8_t want = (uint8_t)((lvl << 4) | lvl);
            if (oled.getBuffer()[pfY0 * (DispWidth / 2) + pfX0] != want) rectKept = false;
        }
        okBool("the fade was still going out", sawOut, true);
        okBool("the title moved meanwhile", titleScrollX > before, true);
        okBool("without undoing the fade's step in its rectangle", rectKept, true);
        settlePageFade();
        okInt ("and the page turned as before", fieldPage, 1);
    }

    section("the current page's pip blinks");
    {
        meta_parse("CMDMETA,2,12,1,Game|System=NES|Year=1987|Genre=Action|Region=USA|Company=N");
        metaFlipped = false;
        meta_tick();
        settlePageFade();
        okBool("more than one page, so pips", meta_pageCount() > 1, true);

        struct Lit { static int count(void) {
            oled.resetProbe(); meta_renderConsole();
            int n = 0;
            for (size_t i = 0; i < oled.rects.size(); i++)
                if (oled.rects[i].color == SSD1322_WHITE) n++;
            return n;
        } };
        lastPageTick = g_fakeMillis;
        pipLastBlink = g_fakeMillis;
        okInt ("lit to begin with", Lit::count(), 1);
        g_fakeMillis += PIP_BLINK_MS - 1;
        okBool("not before its time", meta_tick(), false);
        g_fakeMillis += 1;
        okBool("then the panel is redrawn", meta_tick(), true);
        okInt ("with the pip dark", Lit::count(), 0);
        g_fakeMillis += PIP_BLINK_MS;
        meta_tick();
        okInt ("and lit again", Lit::count(), 1);
        g_fakeMillis += PIP_BLINK_MS;
        meta_tick();
        okInt ("dark", Lit::count(), 0);

        // A page turn lights the new page's pip at once.
        lastPageTick = g_fakeMillis - meta_pageDwellMs() - 1;
        meta_tick();
        settlePageFade();
        okInt ("on the next page", fieldPage, 1);
        okBool("its pip lit from the start", pipLit, true);

        // One page has no pips, and nothing to blink.
        meta_parse("CMDMETA,2,12,1,Game|System=NES");
        meta_tick();
        settlePageFade();
        lastPageTick = g_fakeMillis;
        g_fakeMillis += 3 * PIP_BLINK_MS;
        okBool("a single page is not redrawn for it", meta_tick(), false);
    }

    section("the card's pip blinks while the card is up, not over the artwork");
    {
        meta_parse("CMDMETA,1,10,2,8,NBA Jam"
                   "|Year=1993|Manufctr=Midway|Region=World|Orient=Horizontal"
                   "|Core=blahmid_tunit|Author=rejectedcoins|Set=nbajam|MAME=0289"
                   "|Players=4|Controls=8-way|Buttons=Turbo/Shoot");
        g_fakeMillis   += 1;
        metaShowingCard = false;
        metaLastSwap    = g_fakeMillis;
        g_fakeMillis   += 3 * PIP_BLINK_MS;
        const bool litBefore = pipLit;
        meta_tick();
        okBool("over the artwork nothing blinks", pipLit == litBefore, true);

        meta_showCard(0);
        metaLastSwap = g_fakeMillis;
        meta_tick();                                  // lands: arms the marquees
        g_fakeMillis += PIP_BLINK_MS;
        okBool("on the card it redraws", meta_tick(), true);
        okBool("with the pip dark", pipLit, false);
        cardPage = 0;
        metaShowingCard = false;
    }

    section("a grid field left alone on a page goes beside the first wide field");
    {
        // Nine grid fields: eight fill page 0 and MAME would be alone on the
        // next. It joins Controls on the wide page instead.
        const char *nine = "CMDMETA,1,12,2,9,NBA Jam"
                           "|Year=1993|Manufctr=Midway|Players=4|Rating=8/10|Developr=Midway"
                           "|Region=World|Orient=Horizontal|Core=blahmid_tunit|MAME=0289"
                           "|Controls=8-way|Buttons=Turbo/Shoot / Block/Pass / Steal";
        meta_parse(nine);
        okInt ("one grid page, not two", meta_cardGridPages(), 1);
        okInt ("two pages in all",       meta_cardPageCount(), 2);

        struct At { static int y(const char *t) {
            for (size_t i = 0; i < u8g2.draws.size(); i++)
                if (u8g2.draws[i].text == t) return u8g2.draws[i].y;
            return -1;
        } };
        cardPage = 0;
        u8g2.resetProbe();
        meta_renderCard();
        okBool("page 0 has not got MAME", u8g2.printLog.find("MAME") == std::string::npos, true);

        cardPage = 1;
        u8g2.resetProbe();
        meta_renderCard();
        okInt ("Controls on the left half",  u8g2.xOf("Controls"), meta_cardColX(0));
        okInt ("MAME on the right",          u8g2.xOf("MAME"),     meta_cardColX(1));
        okInt ("on one row",                 At::y("MAME"),        At::y("Controls"));
        okInt ("the row under the pinned one", At::y("Controls"),
               CARD_FIELD_Y0 + CARD_FIELD_PITCH);
        okInt ("Buttons keeps a whole row below", u8g2.xOf("Buttons"), CARD_MARGIN_X);
        okInt ("on the next",                At::y("Buttons"), At::y("Controls") + CARD_FIELD_PITCH);
        okBool("Controls' value in its half", u8g2.maxRight <= (int)DispWidth, true);

        // A wide value that would not fit half a row keeps its row, and MAME
        // its page: halving it would make it scroll.
        meta_parse("CMDMETA,1,12,2,9,NBA Jam"
                   "|Year=1993|Manufctr=Midway|Players=4|Rating=8/10|Developr=Midway"
                   "|Region=World|Orient=Horizontal|Core=blahmid_tunit|MAME=0289"
                   "|Controls=8-way joystick with a very long name|Buttons=Shoot");
        okInt ("a long Controls keeps two grid pages", meta_cardGridPages(), 2);
        okInt ("three pages in all",                   meta_cardPageCount(), 3);

        // Two fields on the last grid page are a row, not a waste of one.
        meta_parse("CMDMETA,1,12,2,10,NBA Jam"
                   "|Year=1993|Manufctr=Midway|Players=4|Rating=8/10|Developr=Midway"
                   "|Region=World|Orient=Horizontal|Core=blahmid_tunit|Set=nbajam|MAME=0289"
                   "|Controls=8-way|Buttons=Shoot");
        okInt ("two left over stay a page", meta_cardGridPages(), 2);

        // Nothing wide to join: the lone field keeps its page.
        meta_parse("CMDMETA,1,12,2,9,NBA Jam"
                   "|Year=1993|Manufctr=Midway|Players=4|Rating=8/10|Developr=Midway"
                   "|Region=World|Orient=Horizontal|Core=blahmid_tunit|MAME=0289");
        okInt ("no wide field, no merge", meta_cardGridPages(), 2);

        // Across the pages of the merged card, every field exactly once.
        meta_parse(nine);
        std::string all;
        for (cardPage = 0; cardPage < meta_cardPageCount(); cardPage++) {
            u8g2.resetProbe();
            meta_renderCard();
            all += u8g2.printLog;
        }
        const char *labels[] = { "Players", "Rating", "Developr", "Region", "Orient",
                                 "Core", "MAME", "Controls", "Buttons" };
        bool once = true;
        for (const char *l : labels) {
            size_t a = all.find(l);
            if (a == std::string::npos || all.find(l, a + 1) != std::string::npos) once = false;
        }
        okBool("every field appears exactly once", once, true);
        cardPage = 0;
    }

    section("the region fade darkens its rectangle and nothing else");
    {
        // The stub does not rasterise text, so the arithmetic is tested on a
        // framebuffer painted by hand: every pixel white.
        uint8_t *fb = oled.getBuffer();
        const int stride = DispWidth / 2;
        pf_cancel();
        memset(fb, 0xFF, 8192);

        // Stands in for meta_renderConsole: counts, and paints the frame the
        // way a render leaves it - the fade-in has to come back to that, not
        // to what was there before.
        static int redraws = 0;
        redraws = 0;
        struct R { static void go(void) { redraws++; memset(oled.getBuffer(), 0xFF, 8192); } };

        const int X = 8, W = 40, Y0 = 32, Y1 = 48;
        pf_start(X, W, Y0, Y1, R::go);
        okBool("it starts", pf_active(), true);
        okInt ("and does not redraw yet", redraws, 0);

        // Half way: inside the rectangle is darker, outside is untouched.
        g_fakeMillis += PF_FADE_MAX_MS / 2; pf_tick();
        okBool("inside the rectangle is darker", fb[(Y0 + 1) * stride + X / 2] < 0xFF, true);
        okInt ("the row above is untouched", fb[(Y0 - 1) * stride + X / 2], 0xFF);
        okInt ("the row below is untouched", fb[Y1 * stride + X / 2], 0xFF);
        okInt ("the column left of it is untouched", fb[(Y0 + 1) * stride + X / 2 - 1], 0xFF);
        okInt ("the column right of it is untouched",
               fb[(Y0 + 1) * stride + (X + W) / 2], 0xFF);

        // The bottom of the fade is black, and that is when the new page is
        // drawn - never before, or it would show through undarkened.
        for (int i = 0; i < 40 && pfState == PF_OUT; i++) { g_fakeMillis += 25; pf_tick(); }
        okInt ("it redraws at the bottom of the fade", redraws, 1);
        okInt ("where the rectangle is black", fb[(Y0 + 1) * stride + X / 2], 0x00);
        okInt ("and everything else is still lit", fb[(Y0 - 1) * stride + X / 2], 0xFF);

        // ...and back up to what the redraw left behind (white, here).
        for (int i = 0; i < 40 && pf_active(); i++) { g_fakeMillis += 25; pf_tick(); }
        okInt ("the fade-in restores it", fb[(Y0 + 1) * stride + X / 2], 0xFF);
        okBool("and it is done", pf_active(), false);

        // An odd x rounds outwards, so no byte is half faded.
        pf_start(9, 7, Y0, Y1, R::go);
        okInt ("an odd x rounds down to its byte", pfX0, 4);
        okInt ("and the width up to the next", pfX1, 8);
        pf_cancel();
    }

    section("console pages turn every METADATA_INTERVAL, as the arcade card's do");
    {
        uint16_t keepFade = tfFadeMs;
        unsigned long keepFlip = metaFlipMs;
        tfFadeMs   = 0;                           // page turns land at once
        metaFlipMs = 0;                           // and no side swap in ten minutes
        meta_parse("CMDMETA,2,12,1,Game|System=NES|A=1|B=2|C=3|D=4|E=5");
        meta_tick();                              // absorb the first draw
        okInt ("12 seconds a page", (long)meta_pageDwellMs(), 12000);
        fieldPage    = 0;
        lastPageTick = g_fakeMillis;
        g_fakeMillis += 2600;                     // the old fixed dwell, and then some
        meta_tick();
        okInt ("not after the old 2.5s", fieldPage, 0);
        g_fakeMillis += 12000 - 2600 - 1;
        meta_tick();
        okInt ("not a millisecond early", fieldPage, 0);
        g_fakeMillis += 1;
        meta_tick();
        okInt ("but at 12s", fieldPage, 1);

        meta_parse("CMDMETA,2,5,1,Game|System=NES|A=1|B=2|C=3|D=4|E=5");
        meta_tick();
        fieldPage    = 0;
        lastPageTick = g_fakeMillis;
        g_fakeMillis += 5000;
        meta_tick();
        okInt ("another interval, another dwell", fieldPage, 1);

        meta_parse("CMDMETA,2,0,1,Game|System=NES|A=1|B=2|C=3|D=4|E=5");
        meta_tick();
        fieldPage    = 0;
        lastPageTick = g_fakeMillis;
        g_fakeMillis += 600000;
        meta_tick();
        okInt ("0 never turns a page", fieldPage, 0);
        tfFadeMs   = keepFade;
        metaFlipMs = keepFlip;
    }

    section("field pager cycles when fields overflow the rows");    section("field pager cycles when fields overflow the rows");
    {
        meta_parse("CMDMETA,2,12,Game|A=1|B=2|C=3|D=4|E=5|F=6");
        meta_tick();                             // absorb the first draw
        fieldPage = 0;
        lastPageTick = g_fakeMillis;

        g_fakeMillis += meta_pageDwellMs() + 1;
        meta_tick();
        settlePageFade();
        // 6 fields at 5 rows per page = 2 pages, so it must have moved.
        okInt("advanced to page 1", fieldPage, 1);

        g_fakeMillis += meta_pageDwellMs() + 1;
        meta_tick();
        settlePageFade();
        okInt("wrapped back to page 0", fieldPage, 0);
    }


    section("layout spacing: one blank row at each break");
    {
        // The gaps are the numbers to tune on glass; these pin the arithmetic
        // so a change to one constant cannot silently overlap two elements.
        okInt("blank row between header and rule",
              CON_RULE_Y - CON_HEADER_Y - 1, CON_GAP_HEADER);
        okInt("blank row between rule and title top",
              (CON_TITLE_Y - CON_TITLE_ASCENT) - CON_RULE_Y - 1, CON_GAP_RULE);
        okInt("blank row between title and first field",
              (CON_FIELD_Y0 - CON_FIELD_ASCENT) - (CON_TITLE_Y + CON_TITLE_DESC) - 1,
              CON_GAP_TITLE);
        okBool("every field row is on the panel",
               CON_FIELD_Y0 + (CON_FIELD_ROWS - 1) * CON_FIELD_PITCH <= (int)DispHeight - 1,
               true);
        okBool("field rows do not overlap",
               CON_FIELD_PITCH > CON_FIELD_ASCENT, true);
        // Moving the pips off the bottom is what bought the fourth row.
        okInt("four field rows", CON_FIELD_ROWS, 4);
    }

    section("page indicator sits by the header, not along the bottom");
    {
        meta_parse("CMDMETA,2,0,Game|A=1|B=2|C=3|D=4|E=5|F=6");   // 6 -> 2 pages
        metaHasIcon = false;
        u8g2.resetProbe();
        meta_renderConsole();

        // Nothing may be drawn on the bottom rows any more: that space is the
        // fourth field row now.
        okBool("pips are in the header band",
               CON_PIP_Y + CON_PIP_H <= CON_RULE_Y, true);
        okBool("pips stop short of the icon column",
               TEXT_W + 2 <= ICON_X, true);
        okBool("no draw past ICON_X", u8g2.maxRight <= ICON_X, true);
    }

    section("side flip mirrors the layout");
    {
        meta_parse("CMDMETA,2,0,Tetris|System=GAMEBOY");
        metaHasIcon = false;
        metaFlipped = false;
        u8g2.resetProbe();
        meta_renderConsole();
        okBool("normal: text left of the icon", u8g2.maxRight <= ICON_X, true);
        okBool("normal: text starts at the left edge", u8g2.minLeft < 40, true);

        metaFlipped = true;
        u8g2.resetProbe();
        meta_renderConsole();
        okBool("flipped: text clear of the icon panel",
               u8g2.minLeft >= ICON_W, true);
        okBool("flipped: text stays on the panel",
               u8g2.maxRight <= (int)DispWidth, true);

        // The icon must land on a byte boundary or the blit shears.
        metaFlipped = false; okInt("normal icon x is even",  ICON_X % 2, 0);
        metaFlipped = true;  okInt("flipped icon x is even", 0 % 2, 0);
        metaFlipped = false;
    }

    section("the icon blits to whichever side is active");
    {
        meta_parse("CMDMETA,2,0,Game|A=1");
        memset(iconBin, 0x77, sizeof(iconBin));
        metaHasIcon = true;

        metaFlipped = false;
        memset(oled.buf, 0, sizeof(oled.buf));
        meta_blitIcon();
        const int rowBytes = DispWidth / 2;
        okInt("normal: icon at byte 85", oled.buf[85], 0x77);
        okInt("normal: nothing at byte 0", oled.buf[0], 0x00);

        metaFlipped = true;
        memset(oled.buf, 0, sizeof(oled.buf));
        meta_blitIcon();
        okInt("flipped: icon at byte 0",   oled.buf[0], 0x77);
        okInt("flipped: nothing at byte 85", oled.buf[85], 0x00);
        // ...and the last icon row lands where it should, not off the end.
        okInt("flipped: last row present",
              oled.buf[(ICON_H - 1) * rowBytes + ICON_STRIDE - 1], 0x77);

        metaFlipped = false;
        metaHasIcon = false;
    }

    section("side flip runs on its own timer");
    {
        meta_parse("CMDMETA,2,0,Game|A=1");
        metaHasIcon = false;
        metaFlipMs  = 60000;
        metaFlipped = false;
        metaLastFlip = g_fakeMillis;
        meta_tick();                       // absorb the first draw

        g_fakeMillis += 59000;
        meta_tick();
        okBool("not yet", metaFlipped, false);

        g_fakeMillis += 2000;
        okBool("tick reports the flip", meta_tick(), true);
        okBool("flipped", metaFlipped, true);

        g_fakeMillis += 61000;
        meta_tick();
        okBool("flips back", metaFlipped, false);

        // The flip is a change of picture like any other, so it uses
        // TRANSITION - the layout jumping to the other side of the panel
        // between two frames was the most abrupt thing console mode did, and
        // it happens unattended, which is when it is most worth easing.
        {
            auto pump = [](unsigned long ms) {
                g_fakeMillis += ms; contrast_tick(); transition_tick();
            };
            tEffect = EFFECT_FADE;
            transition_parse("CMDTFADE,800,1000");
            veil_fadeOver(255, 0);
            metaLastFlip = g_fakeMillis;
            bool wasFlipped = metaFlipped;

            g_fakeMillis += 61000;
            lastEffect = -999; lastSrcAtDraw = nullptr;
            okBool("the flip draws", meta_tick(), true);
            okBool("and the side changed", metaFlipped != wasFlipped, true);
            okBool("through a transition, not a jump", tfState != TF_IDLE, true);
            okBool("composed fresh at black, so the icon comes with it",
                   tfRender != NULL, true);

            // Nothing animates over it, and it finishes.
            bool drewDuring = false;
            for (int i = 0; i < 2000 && tfState != TF_IDLE; i++) {
                pump(5);
                if (meta_tick()) drewDuring = true;
            }
            okBool("nothing animates over the flip's fade", drewDuring, false);
            okBool("and it finishes", tfState == TF_IDLE, true);
            tEffect = -1;
            metaFlipped = false;        // as the checks below expect to find it
        }

        // 0 disables it.
        metaFlipMs = 0;
        metaLastFlip = g_fakeMillis;
        g_fakeMillis += 600000;
        meta_tick();
        okBool("0 never flips", metaFlipped, false);
        metaFlipMs = 300000;
    }

    section("idle dimming");
    {
        // Instant fades here, so each level can be read straight off the
        // panel; the fade itself has a section of its own below.
        fadeMs = 0;
        metaDimFadeMs = 0;
        contrast = 200;
        contrast_jump(200);
        meta_parse("CMDMETA,2,0,Game|A=1");
        metaHasIcon = false;
        metaDimAfterMs = 120000;
        metaDimContrast = 80;
        metaWakeContrast = -1;
        metaFlipMs = 0;                    // keep the flip out of this
        meta_tick();                       // absorb the pending first draw,
        meta_activity();                   // which would itself reset the clock
        oled.contrastCalls = 0;

        g_fakeMillis += 119000;
        meta_tick();
        okBool("bright while active", metaDimmed, false);
        okInt("contrast untouched", oled.contrastCalls, 0);

        g_fakeMillis += 2000;
        meta_tick();
        okBool("dims once idle", metaDimmed, true);
        // A level of its own now, not a share of CONTRAST: it used to be
        // DIM_PERCENT, and "50" meant 100 here and 127 below.
        okInt("dimmed to DIM_CONTRAST itself", (int)oled.contrastLevel, 80);

        // Idle again: it must not keep calling setContrast.
        oled.contrastCalls = 0;
        g_fakeMillis += 120000;
        meta_tick();
        okInt("does not re-dim", oled.contrastCalls, 0);

        // Anything drawn wakes it at full brightness.
        meta_activity();
        okBool("woken", metaDimmed, false);
        okInt("back to the waking level", (int)oled.contrastLevel, 200);

        // An explicit wake level overrides CONTRAST; the dim level does not
        // depend on it.
        metaWakeContrast = 255;
        g_fakeMillis += 121000;
        meta_tick();
        okInt("the same dim level under an override", (int)oled.contrastLevel, 80);
        meta_activity();
        okInt("wakes to the override", (int)oled.contrastLevel, 255);
        metaWakeContrast = -1;
        meta_activity();

        // A dim level above the waking level would make "dimming" brighten
        // the panel after two idle minutes. It stops at the waking level.
        contrast = 60;
        contrast_jump(60);
        metaDimContrast = 200;
        g_fakeMillis += 121000;
        meta_tick();
        okInt("never dims above the waking level", (int)oled.contrastLevel, 60);
        contrast = 200;
        metaDimContrast = 80;
        meta_activity();
        contrast_jump(200);

        // 0 disables dimming entirely.
        metaDimAfterMs = 0;
        g_fakeMillis += 600000;
        meta_tick();
        okBool("0 never dims", metaDimmed, false);

        // Animation must NOT count as activity. The marquee redraws every
        // 40ms and the pager every 2.5s, both through meta_showConsole; when
        // those counted, a console game with a long title or a second page
        // never went idle and the panel never dimmed at all.
        metaDimAfterMs = 120000;
        meta_activity();
        g_fakeMillis += 121000;
        meta_tick();
        okBool("dimmed with a game on screen", metaDimmed, true);
        meta_showConsole();
        okBool("a redraw does not wake it", metaDimmed, true);
        g_fakeMillis += 5000;
        meta_tick();
        okBool("and it stays dim", metaDimmed, true);

        // Only new content does.
        meta_activity();
        okBool("new content wakes it", metaDimmed, false);
        okInt("at the waking level", (int)oled.contrastLevel, 200);

        metaDimAfterMs = 120000;
        metaDimFadeMs = DIM_FADE_MS_DEFAULT;
        metaFlipMs = 300000;
    }

    section("contrast fades rather than jumps");
    {
        auto at = [](unsigned long ms) { g_fakeMillis += ms; contrast_tick(); return (int)oled.contrastLevel; };

        fadeMs = 500;
        contrast_jump(200);
        contrast_fadeTo(100);
        okInt("nothing moves until time passes", at(0), 200);
        okInt("halfway, halfway", at(250), 150);
        okInt("there at the fade time", at(250), 100);
        okBool("and finished", fadeActive, false);

        // A new target mid-fade turns around from where the panel is, not
        // from where the old fade began: waking while still dimming.
        contrast_jump(200);
        contrast_fadeTo(0);
        okInt("dimming, halfway down", at(250), 100);
        contrast_fadeTo(200);
        okInt("turned around, not snapped back", at(0), 100);
        okInt("rising from where it was", at(250), 150);
        okInt("up again at the fade time", at(250), 200);

        // The picture paths re-assert the contrast on every draw. A target
        // already being faded to must not restart the clock, or a fade stalls
        // for as long as pictures keep arriving.
        contrast_jump(200);
        contrast_fadeTo(100);
        at(250);
        contrast_fadeTo(100);
        okInt("a re-assert does not restart the fade", at(250), 100);

        // One panel write per level actually reached, not one per tick.
        contrast_jump(200);
        oled.contrastCalls = 0;
        contrast_fadeTo(100);
        for (int i = 0; i < 600; i++) at(1);
        okBool("writes only when the level changes", oled.contrastCalls <= 100, true);
        okInt("and lands exactly", (int)oled.contrastLevel, 100);

        // The longest fade: it lands.
        fadeMs = 4000;
        contrast_jump(255);
        contrast_fadeTo(0);
        okInt("a 4s fade is halfway at 2s", at(2000), 128);    // 127.5, rounded toward the start
        okInt("and down at 4s", at(2000), 0);
        okInt("the default before CMDFADE is 0.8s", FADE_MS_DEFAULT, 800);

        fadeMs = 0;
        contrast_fadeTo(30);
        okInt("CONTRAST_FADE_MS=0 jumps, as it used to", (int)oled.contrastLevel, 30);

        // Idle dimming and waking both fade.
        fadeMs = 500;
        metaDimFadeMs = 500;
        contrast = 200;
        contrast_jump(200);
        metaDimAfterMs = 120000;
        metaDimContrast = 80;
        metaFlipMs = 0;
        meta_activity();
        g_fakeMillis += 121000;
        meta_tick();
        okInt("going dim, it fades", at(250), 140);
        meta_activity();
        okInt("woken mid-fade, it turns around", at(250), 170);
        okInt("and reaches the waking level", at(250), 200);

        // Going dim is slow on purpose - burn-in protection nobody should see
        // happen - and waking is not: something new has arrived.
        fadeMs = 800;
        metaDimFadeMs = DIM_FADE_MS_DEFAULT;
        okInt("going dim takes 6s by default", (int)metaDimFadeMs, 6000);
        meta_activity();
        at(0);
        g_fakeMillis += 121000;
        meta_tick();
        okInt("a second in, it has barely moved", at(1000), 180);
        okInt("halfway at 3s", at(2000), 140);
        okInt("dim at 6s", at(3000), 80);
        meta_activity();
        okInt("but wakes over CONTRAST_FADE_MS", at(400), 140);
        okInt("fully awake at 0.8s", at(400), 200);

        // Woken halfway down, it comes back quickly from where it got to.
        g_fakeMillis += 121000;
        meta_tick();
        at(3000);
        meta_activity();
        okInt("woken mid-dim, from where it was", at(0), 140);
        okInt("back up in 0.8s, not 6", at(800), 200);
        metaDimFadeMs = DIM_FADE_MS_DEFAULT;
        metaFlipMs = 300000;
    }

    section("CMDDIM");
    {
        metaDimFadeMs = DIM_FADE_MS_DEFAULT;
        okBool("parsed", meta_parseDim("CMDDIM,90,60,-1,4500"), true);
        okInt("after", (int)(metaDimAfterMs / 1000), 90);
        okInt("to", metaDimContrast, 60);
        okInt("over", (int)metaDimFadeMs, 4500);
        meta_parseDim("CMDDIM,90,60,-1,20000");
        okInt("the dim fade is capped at 10s", (int)metaDimFadeMs, 10000);
        meta_parseDim("CMDDIM,90,60,-1,-3");
        okInt("and floored at 0", (int)metaDimFadeMs, 0);
        meta_parseDim("CMDDIM,90,60,-1,4500");
        meta_parseDim("CMDDIM,120,80,-1");
        okInt("a script that sends no fade time keeps the last one", (int)metaDimFadeMs, 4500);
        okInt("while the rest still applies", metaDimContrast, 80);
        okBool("junk is refused", meta_parseDim("CMDDIM,soon"), false);
        metaDimFadeMs = DIM_FADE_MS_DEFAULT;
        metaDimAfterMs = 120000;
        metaDimContrast = 80;
    }

    section("CMDFADE");
    {
        fadeMs = 500;
        okBool("parsed", contrast_parseFade("CMDFADE,1200"), true);
        okInt("to that many ms", fadeMs, 1200);
        contrast_parseFade("CMDFADE,-5");
        okInt("negative is no fade", fadeMs, 0);
        contrast_parseFade("CMDFADE,4000");
        okInt("four seconds is allowed", fadeMs, 4000);
        contrast_parseFade("CMDFADE,4001");
        okInt("and is the most", fadeMs, 4000);
        contrast_parseFade("CMDFADE,99999");
        okInt("capped at FADE_MS_MAX", fadeMs, FADE_MS_MAX);
        okBool("junk is refused", contrast_parseFade("CMDFADE,soon"), false);
        okInt("and changes nothing", fadeMs, FADE_MS_MAX);
        fadeMs = 0;
    }

    section("the power-on screen fades in, palette and contrast together");
    {
        auto at = [](unsigned long ms) { g_fakeMillis += ms; contrast_tick(); transition_tick();
                                         return (int)oled.contrastLevel; };
        auto px = [](int i) { return (int)oled.buf[i]; };
        okInt("over 0.8 seconds", BOOT_FADE_MS, 800);
        // The palette steps redraw the whole frame from a copy; overlapping
        // the sweep would wipe its bar out. The fade has to be done first.
        okBool("inside the hold, so it is done before the sweep", BOOT_FADE_MS <= BOOT_HOLD_MS, true);

        // As setup() and oled_showStartScreen(true) do it: black the panel,
        // compose the frame into the framebuffer, hand it to the fade-in.
        fadeMs = 800;
        veil_fadeOver(0, 0);
        contrast_jump(255);
        okInt("the panel starts black", (int)oled.contrastLevel, 0);
        memset(oled.buf, 0xF8, sizeof(oled.buf));  // the composed boot screen
        oled.shownPeak = 0;
        transition_fadeIn(BOOT_FADE_MS);
        okInt("the first frame the panel gets is fully dark", oled.shownPeak, 0);
        okInt("at contrast 0", at(0), 0);
        at(50);
        okInt("one sixteenth in, still nothing above 0", px(0), 0x00);
        at(350);
        okInt("halfway, the greys are eight levels down", px(0), 0x70);
        okInt("and the contrast halfway up", (int)oled.contrastLevel, 127);
        at(400);
        okInt("at 0.8s, the screen is itself", px(0), 0xF8);
        okInt("at full contrast", (int)oled.contrastLevel, 255);
        okBool("and the fade is over before the sweep's first bar", tfState == TF_IDLE, true);

        // The daemon can speak mid-fade. Its CMDCON moves the base level; the
        // fade carries on over it rather than being restarted or cut short.
        veil_fadeOver(0, 0);
        contrast_jump(255);
        memset(oled.buf, 0xF8, sizeof(oled.buf));
        transition_fadeIn(BOOT_FADE_MS);
        at(400);
        contrast_fadeTo(100);
        okInt("a CMDCON mid-fade starts from where it got to", at(0), 127);
        at(400);
        okInt("the fade finishes", px(0), 0xF8);
        at(400);
        okInt("and settles on the CMDCON's level", (int)oled.contrastLevel, 100);
        fadeMs = 0;
        contrast = 200; contrast_jump(200);
    }

    section("TRANSITION=-2 fades out, holds black, fades in");
    {
        auto at = [](unsigned long ms) { g_fakeMillis += ms; contrast_tick(); transition_tick();
                                         return (int)oled.contrastLevel; };
        uint8_t picA[8192], picB[8192];
        fadeMs = 0;
        contrast = 200;
        contrast_jump(200);
        veil_fadeOver(255, 0);
        tfFadeMs = 2000; tfBlankMs = 1000;
        memset(oled.buf, 0x77, sizeof(oled.buf));

        srcBin = picA; actPicType = GSC;
        lastEffect = -999;
        oled_transition(EFFECT_FADE);
        okInt("nothing is drawn straight away", lastEffect, -999);
        okInt("the old picture fades out", at(1000), 100);
        okInt("to black", at(1000), 0);
        at(0);
        okBool("and the panel is cleared, not just dark", oled.buf[0] == 0 && oled.buf[8191] == 0, true);
        okInt("still nothing drawn while black", (at(999), lastEffect), -999);
        at(1);
        okInt("then the new picture, drawn plainly", lastEffect, 0);
        okBool("from the buffer asked for", lastSrcAtDraw == picA, true);
        okInt("at black", (int)oled.contrastLevel, 0);
        okInt("fading in", at(1000), 100);
        okInt("to where it was", at(1000), 200);
        at(0);
        okBool("and done", tfState == TF_IDLE, true);

        // On a dimmed panel it returns to the dim level, not to CONTRAST.
        contrast_jump(80);
        oled_transition(EFFECT_FADE);
        at(2000); at(0); at(1000);
        okInt("a dimmed panel fades back to its dim level", at(2000), 80);
        at(0);
        contrast_jump(200);

        // The card alternation puts srcBin back the moment it returns; the
        // picture shown seconds later must still be the one asked for.
        srcBin = picB;
        oled_transition(EFFECT_FADE);
        srcBin = picA;
        at(2000); at(0); at(1000);
        okBool("the buffer is taken at the request", lastSrcAtDraw == picB, true);
        okBool("and srcBin is left as it was", srcBin == picA, true);
        at(2000); at(0);

        // A second request while going dark: the newer picture wins and the
        // clock carries on, rather than starting the fade-out again.
        srcBin = picA;
        oled_transition(EFFECT_FADE);
        at(1000);
        srcBin = picB;
        oled_transition(EFFECT_FADE);
        okInt("a request while fading out does not restart it", at(1000), 0);
        at(0); at(1000);
        okBool("and the newer picture is the one shown", lastSrcAtDraw == picB, true);

        // While fading in: turn around from where it had got to.
        at(1000);
        int midway = (int)oled.contrastLevel;
        oled_transition(EFFECT_FADE);
        okInt("a request while fading in turns around", at(0), midway);
        okBool("heading back down", at(500) < midway, true);
        at(2000); at(0); at(1000); at(2000); at(0);

        // Any other effect cancels a fade and draws at once, at full veil.
        oled_transition(EFFECT_FADE);
        at(1000);
        oled_transition(7);
        okInt("another effect cancels the fade", lastEffect, 7);
        okInt("and the panel is back to its level at once", at(0), 200);
        okBool("with nothing left running", tfState == TF_IDLE, true);

        // -1 is still random, and never the fade.
        oled_transition(EFFECT_RANDOM);
        okBool("-1 picks a wipe", lastEffect >= minEffect && lastEffect <= maxEffect, true);
        okBool("not a fade", tfState == TF_IDLE, true);

        // Zero times: done within a few passes of the loop.
        tfFadeMs = 0; tfBlankMs = 0;
        lastEffect = -999;
        oled_transition(EFFECT_FADE);
        at(0); at(0); at(0);
        okInt("0ms fade and blank still draw", lastEffect, 0);
        okInt("and end at full", at(0), 200);

        okBool("CMDTFADE parsed", transition_parse("CMDTFADE,1500,300"), true);
        okInt("fade time", tfFadeMs, 1500);
        okInt("blank time", tfBlankMs, 300);
        transition_parse("CMDTFADE,9999,-4");
        okInt("fade capped at 4000", tfFadeMs, 4000);
        okInt("blank floored at 0", tfBlankMs, 0);
        okBool("one number is not enough", transition_parse("CMDTFADE,500"), false);
        tfFadeMs = TFADE_MS_DEFAULT; tfBlankMs = TBLANK_MS_DEFAULT;
        okInt("defaults: 0.8s fades", TFADE_MS_DEFAULT, 800);
        okInt("and 1s of black", TBLANK_MS_DEFAULT, 1000);
    }


    section("the Fade steps the picture's own greys down, then up");
    {
        auto at = [](unsigned long ms) { g_fakeMillis += ms; contrast_tick(); transition_tick();
                                         return (int)oled.contrastLevel; };
        auto px = [](int i) { return (int)oled.buf[i]; };
        static uint8_t oldPic[8192], newPic[8192];
        memset(oldPic, 0xF8, sizeof(oldPic)); oldPic[1] = 0x21;
        memset(newPic, 0x5F, sizeof(newPic));
        fadeMs = 0; contrast = 200; contrast_jump(200); veil_fadeOver(255, 0);
        tfFadeMs = 1600; tfBlankMs = 500;          // 100ms a palette step

        memcpy(oled.buf, oldPic, sizeof(oldPic)); // what the panel shows
        srcBin = newPic; actPicType = GSC;
        oled_transition(EFFECT_FADE);
        at(99);
        okInt("nothing moves before the first sixteenth", px(0), 0xF8);
        at(1);
        okInt("then every pixel is one level darker", px(0), 0xE7);
        at(100);
        okInt("floored at 0, never wrapped round to white", px(1), 0x00);
        at(600);
        okInt("halfway, eight levels down", px(0), 0x70);
        okInt("with the contrast halfway down too", (int)oled.contrastLevel, 100);
        at(700);
        okInt("F is gone by the fifteenth step", px(0), 0x00);
        at(100);
        okInt("the sixteenth lands as the contrast reaches 0", (int)oled.contrastLevel, 0);
        okBool("and the panel is held black", tfState == TF_BLANK, true);

        // The flash: effect 0 used to draw the new picture and send it to the
        // panel before it was darkened, so for one frame transfer it was up
        // undarkened at contrast 0 - which on this panel is far from dark.
        oled.shownPeak = 0;
        at(500);
        okBool("the new picture is drawn", lastSrcAtDraw == newPic, true);
        okInt("but shown fully dark", px(0), 0x00);
        okInt("and no frame of it reached the panel undarkened", oled.shownPeak, 0);
        at(100);
        okInt("one step in, still nothing above 0", px(0), 0x00);
        at(100);
        okInt("the brightest pixels come back first", px(0), 0x01);
        at(600);
        okInt("halfway up", px(0), 0x07);
        at(800);
        okInt("and it ends as itself", px(0), 0x5F);
        okBool("every byte of it", memcmp(oled.buf, newPic, sizeof(newPic)) == 0, true);
        okInt("at full contrast", (int)oled.contrastLevel, 200);
        okBool("finished", tfState == TF_IDLE, true);

        // CONTRAST and the palette are separate. With CONTRAST=120 the
        // brightness runs 120 -> 0 -> 120, but the grey levels still step the
        // full 0..F, sixteen of them - they are not scaled down to match.
        contrast = 120; contrast_jump(120); veil_fadeOver(255, 0);
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(EFFECT_FADE);
        okInt("CONTRAST=120 starts from 120", at(0), 120);
        at(800);
        okInt("is at 60 halfway out", (int)oled.contrastLevel, 60);
        okInt("while the greys are eight levels down, not scaled", px(0), 0x70);
        at(800);
        okInt("reaches 0", (int)oled.contrastLevel, 0);
        okInt("with the greys at 0 too", px(0), 0x00);
        at(500); at(800);
        okInt("halfway in, back at 60", (int)oled.contrastLevel, 60);
        okInt("with the greys eight levels up", px(0), 0x07);
        at(800);
        okInt("and back to 120, never above it", (int)oled.contrastLevel, 120);
        okBool("with the picture exactly itself", memcmp(oled.buf, newPic, sizeof(newPic)) == 0, true);
        contrast = 200; contrast_jump(200);

        // One panel write per palette step, not one per pass of the loop.
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        int before = oled.displayCalls;
        oled_transition(EFFECT_FADE);
        for (int i = 0; i < 1600; i++) at(1);
        okInt("16 frames out, and one to clear", oled.displayCalls - before, 17);
        at(500); for (int i = 0; i < 1600; i++) at(1);

        // Turning around mid fade-in carries on from what is showing.
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(EFFECT_FADE);
        at(1600); at(500); at(800);
        okInt("fading in, halfway", px(0), 0x07);
        oled_transition(EFFECT_FADE);
        at(100);
        okInt("turned around: one level down from there, no jump", px(0), 0x06);
        at(800); at(0); at(500); at(1600);
        okBool("and it still completes", tfState == TF_IDLE, true);

        // The card renders the new card into the framebuffer before it asks
        // for the transition. The fade must darken what was on the panel.
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        meta_parse("CMDMETA,1,12,Galaga|Year=1981");
        meta_showCard(EFFECT_FADE);
        at(100);
        okInt("the card fades out the picture that was there, not itself", px(0), 0xE7);
        at(1600); at(500); at(1600);
        okBool("then fades itself in", lastSrcAtDraw == metaBin, true);
        meta_reset();
        srcBin = logoBin;
        tfFadeMs = TFADE_MS_DEFAULT; tfBlankMs = TBLANK_MS_DEFAULT;
    }

    section("fade-slide: the picture drifts as it fades, and lands centred");
    {
        auto at = [](unsigned long ms) { g_fakeMillis += ms; contrast_tick(); transition_tick(); };
        static uint8_t oldPic[8192], newPic[8192];
        auto setPx = [](uint8_t *b, int x, int y, uint8_t v) {
            uint8_t &t = b[y * 128 + (x >> 1)];
            t = (x & 1) ? (uint8_t)((t & 0xF0) | v) : (uint8_t)((t & 0x0F) | (v << 4));
        };
        auto getPx = [](const uint8_t *b, int x, int y) -> int {
            uint8_t t = b[y * 128 + (x >> 1)];
            return (x & 1) ? (int)(t & 0x0F) : (int)(t >> 4);
        };
        // A cross on black: one lit column and one lit row, so where the
        // picture has got to can be read straight off the panel on either
        // axis. Row 5 and column 5 carry only the one bar each.
        auto cross = [&](uint8_t *b, int cx, int cy) {
            memset(b, 0, 8192);
            for (int y = 0; y < 64; y++)  setPx(b, cx, y, 15);
            for (int x = 0; x < 256; x++) setPx(b, x, cy, 15);
        };
        auto colNow = [&]() { for (int x = 0; x < 256; x++) if (getPx(oled.buf, x, 5)) return x; return -1; };
        auto rowNow = [&]() { for (int y = 0; y < 64; y++) if (getPx(oled.buf, 5, y)) return y; return -1; };

        cross(oldPic, 100, 30);
        cross(newPic, 100, 30);
        fadeMs = 0; contrast = 200; contrast_jump(200); veil_fadeOver(255, 0);
        tfFadeMs = 1600; tfBlankMs = 500;          // 100ms a palette step
        srcBin = newPic; actPicType = GSC;

        // --- 30: one pixel left a step -------------------------------------
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(30);
        okBool("30 is a fade, not a wipe", tfState == TF_OUT, true);
        at(100);
        okInt("one step out, one pixel left", colNow(), 99);
        at(400);
        okInt("five steps, five pixels", colNow(), 95);
        okInt("and nothing has moved vertically", rowNow(), 30);
        at(900);
        okInt("fourteen steps, fourteen pixels", colNow(), 86);

        // The pre-offset: the fade-in starts a whole travel's worth out on the
        // *opposite* side and slides back, so the movement reads as one
        // continuous drift rather than a bounce - and ends centred.
        at(200); at(500);                          // last steps out, then the blank
        okBool("black in between", tfState == TF_IN, true);
        at(200);                                   // two steps in: level 15 - 14 = 1
        okInt("coming in from the right, 14 steps to go", colNow(), 114);
        at(400);
        okInt("still sliding the same way", colNow(), 110);
        at(1000);
        okInt("and it lands centred", colNow(), 100);
        okBool("exactly the picture it was given", memcmp(oled.buf, newPic, sizeof(newPic)) == 0, true);
        okBool("finished", tfState == TF_IDLE, true);
        okInt("at full contrast", (int)oled.contrastLevel, 200);

        // --- 31: two pixels a step -----------------------------------------
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(31);
        at(100);
        okInt("31 moves two pixels a step", colNow(), 98);
        at(400);
        okInt("so five steps is ten pixels", colNow(), 90);
        at(1100); at(500); at(200);
        okInt("and it comes in from twice as far out", colNow(), 128);
        at(1400);
        okBool("landing centred all the same", memcmp(oled.buf, newPic, sizeof(newPic)) == 0, true);

        // --- 32..37: the other three directions ----------------------------
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(32);
        at(300);
        okInt("32 slides right", colNow(), 103);
        okInt("and not up or down", rowNow(), 30);
        at(1300); at(500); at(1600); at(0);

        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(34);
        at(300);
        okInt("34 slides up", rowNow(), 27);
        okInt("and not left or right", colNow(), 100);
        at(1300); at(500); at(1600); at(0);

        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(36);
        at(300);
        okInt("36 slides down", rowNow(), 33);
        at(1300); at(500); at(200);
        okInt("coming in from above, 14 steps to go", rowNow(), 16);
        at(1400);
        okBool("centred again", memcmp(oled.buf, newPic, sizeof(newPic)) == 0, true);

        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(37);
        at(300);
        okInt("37 is the same at two pixels a step", rowNow(), 36);
        at(1300); at(500); at(1600); at(0);

        // --- 38, 39: a direction per transition, not per step ---------------
        // Each is run enough times to see every direction come up, and each
        // run must be one axis only - a diagonal is not one of the ten.
        int seen1 = 0, seen2 = 0, oddSpeed = 0, diagonal = 0;
        for (int i = 0; i < 200; i++) {
            oled_transition(38);
            int dx = tfSlideDX, dy = tfSlideDY;
            if (dx && dy) diagonal++;
            if (abs(dx) + abs(dy) != 1) oddSpeed++;
            seen1 |= (dx < 0) | ((dx > 0) << 1) | ((dy < 0) << 2) | ((dy > 0) << 3);
            transition_cancel();
            oled_transition(39);
            dx = tfSlideDX; dy = tfSlideDY;
            if (dx && dy) diagonal++;
            if (abs(dx) + abs(dy) != 2) oddSpeed++;
            seen2 |= (dx < 0) | ((dx > 0) << 1) | ((dy < 0) << 2) | ((dy > 0) << 3);
            transition_cancel();
        }
        okInt("38 comes up in all four directions", seen1, 15);
        okInt("39 too", seen2, 15);
        okInt("the dice never changes the speed", oddSpeed, 0);
        okInt("and never picks a diagonal", diagonal, 0);

        // One direction for the whole transition. A picture that changed its
        // mind every sixteenth of a second would be a shake, not a slide.
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(38);
        int dx0 = tfSlideDX, dy0 = tfSlideDY;
        for (int i = 0; i < 16; i++) at(100);
        at(500);
        for (int i = 0; i < 16; i++) at(100);
        okBool("the direction holds for the whole transition",
               tfSlideDX == dx0 && tfSlideDY == dy0, true);
        okBool("and it still lands centred", memcmp(oled.buf, newPic, sizeof(newPic)) == 0, true);

        // --- the plain Fade does not move ----------------------------------
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(EFFECT_FADE);
        okBool("-2 clears any slide left over", tfSlideDX == 0 && tfSlideDY == 0, true);
        at(500);
        okInt("and stays where it is", colNow(), 100);
        at(1100); at(500); at(1600); at(0);

        // A wipe cancels the slide with everything else, so the next plain
        // Fade cannot inherit one.
        oled_transition(30);
        oled_transition(7);
        okBool("a wipe clears it too", tfSlideDX == 0 && tfSlideDY == 0, true);
        veil_fadeOver(255, 0);

        // --- turning around mid fade-in ------------------------------------
        // The picture carries on from where it is rather than jumping to the
        // mirror of its own position, which is what a base of 0 would do.
        memcpy(oled.buf, oldPic, sizeof(oldPic));
        oled_transition(30);
        at(1600); at(500); at(800);                // fading in, halfway: 8 to go
        okInt("halfway in, eight pixels out", colNow(), 108);
        oled_transition(30);
        at(100);
        okInt("turned around: one more pixel the same way, no jump", colNow(), 107);
        at(700); at(0); at(500); at(1600);
        okBool("and it still completes", tfState == TF_IDLE, true);
        okBool("centred", memcmp(oled.buf, newPic, sizeof(newPic)) == 0, true);

        // --- what the wire is allowed to ask for ---------------------------
        okInt("effect_clamp lets the first fade-slide through", effect_clamp(30), 30);
        okInt("and the last",                                  effect_clamp(39), 39);
        okInt("the gap below them pins to maxEffect",           effect_clamp(29), (int)maxEffect);
        okInt("and anything above them too",                    effect_clamp(40), (int)maxEffect);
        okInt("-2 is still the Fade",                           effect_clamp(-2), EFFECT_FADE);
        okInt("and anything under it is random",                effect_clamp(-3), EFFECT_RANDOM);
        okBool("a fade-slide counts as a fade for the card",    effect_is_fade(30), true);
        okBool("so does -2",                                    effect_is_fade(EFFECT_FADE), true);
        okBool("a wipe does not",                               effect_is_fade(7), false);
        okInt("the numbers are the ini's",   EFFECT_SLIDE_FIRST, 30);
        okInt("ten of them",                 EFFECT_SLIDE_COUNT, 10);
        okBool("clear of the wipes",         EFFECT_SLIDE_FIRST > (int)maxEffect, true);

        srcBin = logoBin;
        tfFadeMs = TFADE_MS_DEFAULT; tfBlankMs = TBLANK_MS_DEFAULT;
        tfSlideDX = tfSlideDY = 0;
    }

    section("the card alternates with TRANSITION, not at random");
    {
        tfFadeMs = 0; tfBlankMs = 0;
        meta_parse("CMDMETA,1,12,Galaga|Year=1981");
        tEffect = 5;
        lastEffect = -999;
        g_fakeMillis += 13000;
        meta_tick();
        okInt("a TRANSITION of 5 wipes the card in with 5", lastEffect, 5);
        tEffect = EFFECT_FADE;
        lastEffect = -999;
        g_fakeMillis += 13000;
        meta_tick();
        okBool("-2 fades the card in", tfState != TF_IDLE, true);
        for (int i = 0; i < 5; i++) { contrast_tick(); transition_tick(); }
        okInt("drawn plainly once dark", lastEffect, 0);
        tEffect = -1;
        tfFadeMs = TFADE_MS_DEFAULT; tfBlankMs = TBLANK_MS_DEFAULT;
        meta_reset();
    }


    section("BOOTSCREEN_AS_MENU: what counts as drawing over the boot screen");
    {
        const char *quiet[] = { "QWERTZ", "CMDCON,255", "CMDFADE,800", "CMDTFADE,800,1000",
                                "CMDDIM,120,80,-1,6000", "CMDFLIP,300", "CMDSAVER,0,0,0",
                                "CMDSETTIME,1700000000", "CMDHWINF", "CMDMETAOFF",
                                "CMDBOOTPIC,MENU,-2", "CMDBOOTINF" };
        for (const char *c : quiet) {
            bootHolding = true;
            boot_noteCommand(c);
            okBool((std::string("still holding after ") + c).c_str(), bootHolding, true);
        }
        // Anything not known to be quiet is assumed to draw - including
        // commands the list has never heard of, and a prefix that only
        // looks like a quiet one.
        const char *drawing[] = { "CMDCOR,NES,-2", "CMDSPIC", "CMDTXT,1,15,0,0,20,Hi",
                                  "CMDSORG", "CMDROT,1", "CMDMETA,1,12,Galaga", "CMDCONTRAST",
                                  "NES", "CMDSOMETHINGNEW" };
        for (const char *c : drawing) {
            bootHolding = true;
            boot_noteCommand(c);
            okBool((std::string("released by ") + c).c_str(), bootHolding, false);
        }
    }

    section("BOOTSCREEN_AS_MENU: the boot image as the menu's picture");
    {
        tfFadeMs = 800; tfBlankMs = 1000;
        memset(logoBin, 0xAA, sizeof(logoBin));
        actPicType = XBM;
        bootHolding = true;
        lastEffect = -999;
        boot_showAsCore(EFFECT_FADE);
        okBool("the boot image goes where core pictures go",
               memcmp(logoBin, bootlogo_bits, BOOTIMG_BYTES) == 0, true);
        bool bandBlack = true;
        for (int i = BOOTIMG_BYTES; i < BOOT_PANEL_BYTES; i++) if (logoBin[i]) bandBlack = false;
        okBool("with the band below it black", bandBlack, true);
        okInt("as a 4bpp picture", actPicType, GSC);
        okInt("at power-on, nothing is drawn", lastEffect, -999);
        okBool("and nothing transitions", tfState == TF_IDLE, true);

        bootHolding = false;
        boot_showAsCore(5);
        okInt("back to the menu later, it transitions like any picture", lastEffect, 5);
        // Composed first, so the band's notice can come with it.
        okBool("from the boot image, composed", lastSrcAtDraw == metaBin
               && memcmp(metaBin, bootlogo_bits, BOOTIMG_BYTES) == 0, true);
        boot_showAsCore(EFFECT_FADE);
        okBool("the Fade included", tfState == TF_OUT, true);
        transition_cancel();
    }

    section("BOOTSCREEN_AS_MENU: the power-on screen's outro");
    {
        auto tick = [](unsigned long ms) { g_fakeMillis += ms; contrast_tick(); transition_tick(); boot_outroTick(); };
        // Where the comet's head is, frame by frame: the head is the right
        // edge of the brightest rectangle drawn in that frame.
        auto barHeads = []() {
            std::string out;
            int last = -1;
            for (const auto &r : oled.rects) {
                if (r.y != BOOT_BAR_Y || r.color != BOOT_BAR_LEVELS - 1) continue;
                int head = r.x + r.w - 1;
                if (head != last) { out += std::to_string(head) + " "; last = head; }
            }
            return out;
        };
        auto barDrew = []() {
            for (const auto &r : oled.rects) if (r.y == BOOT_BAR_Y) return true;
            return false;
        };
        const int barX = 32;
        veil_fadeOver(255, 0);

        // Interrupted part way: the comet runs off the right edge and stops,
        // which leaves the band empty with no clearing pass of its own.
        bootHolding = true;
        oled.resetProbe(); u8g2.draws.clear();
        boot_outroStart(barX, 128);
        // Long enough for both halves: the comet's run, and the version's
        // one-second fade.
        for (int i = 0; i < 700; i++) tick(BOOT_BAR_PX_MS);
        okBool("it carries on from where the sweep was",
               barHeads().rfind(std::to_string(128 + BOOT_BAR_PX_STEP) + " ", 0) == 0, true);
        okBool("to the right edge of the panel",
               barHeads().find(std::to_string(BOOT_PANEL_W - 1) + " ") != std::string::npos, true);
        okBool("and it is over", boActive, false);

        // The head never moves further in one frame than the black end of its
        // own tail covers, however long the tick that drew it took. It used to
        // catch up on the time the handover cost - lurching, and leaving the
        // pixels between the old tail and the new one lit behind it.
        bool smooth = true, coveredByTail = true;
        {
            int prev = -1;
            for (const auto &r : oled.rects) {
                if (r.y != BOOT_BAR_Y || r.color != BOOT_BAR_LEVELS - 1) continue;
                int head = r.x + r.w - 1;
                if (prev >= 0 && head - prev > BOOT_BAR_PX_STEP) smooth = false;
                prev = head;
            }
        }
        if (BOOT_BAR_PX_STEP > BOOT_BAR_SEG) coveredByTail = false;
        okBool("the head advances a step at a time, never a burst", smooth, true);
        okBool("and a step never outruns the tail's black end", coveredByTail, true);

        // Every frame carries the whole gradient, and only the bar's rows.
        int levels[BOOT_BAR_LEVELS] = {0};
        bool ownRows = true;
        for (const auto &r : oled.rects) {
            if (r.y != BOOT_BAR_Y) continue;
            if (r.h != BOOT_BAR_H) ownRows = false;
            if (r.color < BOOT_BAR_LEVELS) levels[r.color]++;
        }
        bool allGreys = true;
        for (int i = 0; i < BOOT_BAR_LEVELS; i++) if (!levels[i]) allGreys = false;
        okBool("every one of the sixteen greys is drawn", allGreys, true);
        okBool("and only in the bar's own rows", ownRows, true);

        // The version fades 15 -> 0 over a second, one grey at a time.
        std::string greys;
        for (const auto &d : u8g2.draws) if (d.text == "0.4.0b") greys += std::to_string(d.fg) + " ";
        ok("the version steps down through every grey", greys, "14 13 12 11 10 9 8 7 6 5 4 3 2 1 ");
        okBool("and is blacked out at the end", !oled.rects.empty() &&
               oled.rects.back().x == 0 && oled.rects.back().y == BOOT_BAND_Y &&
               oled.rects.back().color == SSD1322_BLACK, true);
        okInt("leaving the text colour as it was", u8g2.fgColor, SSD1322_WHITE);

        // The tail drains off the right edge after the head does, so the band
        // is left empty without a clearing pass of its own.
        oled.resetProbe();
        for (int i = 0; i < 100; i++) tick(BOOT_BAR_PX_MS);
        okBool("nothing is still being drawn afterwards", barDrew(), false);

        // A tick that arrives late - the handover, a picture transfer - moves
        // the bar one step, not the twenty the clock is owed.
        bootHolding = true;
        oled.resetProbe();
        boot_outroStart(barX, 128);
        tick(0);
        tick(BOOT_BAR_PX_MS);          // the first frame, to measure from
        int headBefore = -1, headAfter = -1;
        for (const auto &r : oled.rects)
            if (r.y == BOOT_BAR_Y && r.color == BOOT_BAR_LEVELS - 1) headBefore = r.x + r.w - 1;
        oled.resetProbe();
        tick(40);                      // twenty frames' worth of clock in one tick
        for (const auto &r : oled.rects)
            if (r.y == BOOT_BAR_Y && r.color == BOOT_BAR_LEVELS - 1) headAfter = r.x + r.w - 1;
        okInt ("a late tick still moves one step", headAfter - headBefore, BOOT_BAR_PX_STEP);

        // And when the run ends the bar is blacked across its whole width, so
        // a frame cut short by the ending cannot leave a trail.
        oled.resetProbe();
        for (int i = 0; i < 700; i++) tick(BOOT_BAR_PX_MS);
        bool cleared = false;
        for (const auto &r : oled.rects)
            if (r.y == BOOT_BAR_Y && r.color == SSD1322_BLACK &&
                r.x == barX && r.x + r.w == BOOT_PANEL_W) cleared = true;
        okBool("the bar is blacked when the run ends", cleared, true);

        // Timing: the version takes BOOT_VERFADE_MS - measured from where it
        // now starts, which is the moment the comet leaves the panel, not the
        // moment the daemon spoke. Driven a frame at a time, because one tick
        // moves the bar one step however much clock it carries.
        bootHolding = true;
        oled.resetProbe(); u8g2.draws.clear();
        boot_outroStart(barX, 128);
        for (int i = 0; i < 700 && !boBarDone; i++) tick(BOOT_BAR_PX_MS);
        okBool("the bar finishes first", boBarDone, true);
        okBool("and the version has not begun to fade", boVerDone, false);
        tick(BOOT_VERFADE_MS / 2);
        okBool("half its fade in, the version is still going", boVerDone, false);
        tick(BOOT_VERFADE_MS / 2 + 1);
        okBool("gone at the end of it", boVerDone, true);

        // The two halves are sequential, never simultaneous. Each version step
        // blacks the whole left half of the band and re-renders the text into
        // it, which is a far heavier frame than the bar's few columns; drawing
        // both in one tick made the comet stutter as it ran off the edge.
        //
        // Checked by watching which one drew first: no version text may appear
        // before the bar has finished its run.
        bootHolding = true;
        oled.resetProbe(); u8g2.draws.clear();
        boot_outroStart(barX, 128);
        {
            bool textBeforeBarDone = false;
            for (int i = 0; i < 700; i++) {
                bool wasDone = boBarDone;
                size_t before = u8g2.draws.size();
                tick(BOOT_BAR_PX_MS);
                if (!wasDone && u8g2.draws.size() > before) textBeforeBarDone = true;
            }
            okBool("the version does not fade while the bar is still running",
                   textBeforeBarDone, false);
            okBool("and both are finished by the end", boActive, false);
        }

        // ...and it does fade once the bar is done, rather than being skipped.
        bootHolding = true;
        oled.resetProbe(); u8g2.draws.clear();
        boot_outroStart(barX, 128);
        for (int i = 0; i < 700; i++) tick(BOOT_BAR_PX_MS);
        okBool("the version fades after it", u8g2.draws.size() >= 14, true);

        // A head already past the end of its run has nothing left to do: the
        // tail has drained and the band is empty.
        bootHolding = true;
        oled.resetProbe();
        boot_outroStart(barX, barX + BOOT_BAR_SPAN(barX));
        for (int i = 0; i < 700; i++) tick(BOOT_BAR_PX_MS);
        okBool("a run already finished draws no bar", barDrew(), false);

        // The daemon spoke during the hold: no bar yet, only the version.
        bootHolding = true;
        oled.resetProbe(); u8g2.draws.clear();
        boot_outroStart(barX, -1);
        for (int i = 0; i < 100; i++) tick(20);
        okBool("spoken to during the hold, no bar is drawn", barDrew(), false);
        okBool("but the version still fades", u8g2.draws.size() >= 14, true);

        // It waits for the power-on fade-in, which redraws the whole frame
        // from a copy every step and would undo its drawing.
        bootHolding = true;
        oled.resetProbe(); u8g2.draws.clear();
        transition_fadeIn(800);
        boot_outroStart(barX, 128);
        tick(20); tick(20);
        okBool("nothing while the fade-in is running", barDrew(), false);
        for (int i = 0; i < 40; i++) tick(20);
        okBool("then it runs", barDrew(), true);

        // Anything that takes the panel stops it on the spot.
        bootHolding = true;
        oled.resetProbe(); u8g2.draws.clear();
        boot_outroStart(barX, 128);
        tick(0); tick(20); tick(20);
        size_t before = oled.rects.size(), drawsBefore = u8g2.draws.size();
        boot_noteCommand("CMDCOR,NES,-2");
        for (int i = 0; i < 100; i++) tick(20);
        okBool("a picture arriving stops the bar", oled.rects.size() == before, true);
        okBool("and the version fade", u8g2.draws.size() == drawsBefore, true);
        okBool("for good", boActive, false);
    }

    section("pinned rows stay, the rest page under them");
    {
        // The shape asked for: System and Year fixed, Genre/Region on page 1,
        // Format on page 2.
        meta_parse("CMDMETA,2,0,2,Airwolf|System=NES|Year=1989, Acclaim"
                   "|Genre=Shooter|Region=USA|Format=NES");
        okInt("pinned count parsed", metaPinned, 2);
        okInt("fields",              metaFieldCount, 5);
        okInt("rows",                CON_FIELD_ROWS, 4);
        okInt("slots left to page",  meta_pageSlots(), 2);
        okInt("pages",               meta_pageCount(), 2);

        metaHasIcon = false;
        fieldPage = 0;
        u8g2.resetProbe();
        meta_renderConsole();
        okBool("page 0 shows System", u8g2.printLog.find("System") != std::string::npos, true);
        okBool("page 0 shows Year",   u8g2.printLog.find("Year")   != std::string::npos, true);
        okBool("page 0 shows Genre",  u8g2.printLog.find("Genre")  != std::string::npos, true);
        okBool("page 0 shows Region", u8g2.printLog.find("Region") != std::string::npos, true);
        okBool("page 0 hides Format", u8g2.printLog.find("Format") == std::string::npos, true);

        fieldPage = 1;
        u8g2.resetProbe();
        meta_renderConsole();
        okBool("page 1 still shows System", u8g2.printLog.find("System") != std::string::npos, true);
        okBool("page 1 still shows Year",   u8g2.printLog.find("Year")   != std::string::npos, true);
        okBool("page 1 shows Format",       u8g2.printLog.find("Format") != std::string::npos, true);
        okBool("page 1 hides Genre",        u8g2.printLog.find("Genre")  == std::string::npos, true);
        fieldPage = 0;
    }

    section("a script that sends fewer counts still works");
    {
        // The title cannot contain a comma - metasanitize strips them - so a
        // comma-terminated run of digits is the only thing that can be a
        // count. A script that sends neither, or only the first, must still
        // leave the title intact.
        meta_parse("CMDMETA,2,12,Super Mario World|System=SNES");
        okInt("no pinned count",  metaPinned, 0);
        okInt("no compact count", metaCompact, 0);
        ok   ("title intact",     metaTitle, "Super Mario World");

        meta_parse("CMDMETA,2,12,2,Super Mario World|System=SNES|Year=1990");
        okInt("pinned alone parsed",   metaPinned, 2);
        okInt("compact defaults to 0", metaCompact, 0);
        ok   ("title after one count", metaTitle, "Super Mario World");

        meta_parse("CMDMETA,1,12,2,8,NBA Jam|Year=1993|Manufctr=Midway");
        okInt("both counts parsed", metaPinned, 2);
        // Clamped to what actually arrived - the script counts fields it
        // emitted, and a field with an empty value is never emitted.
        okInt("compact clamped to the fields", metaCompact, 2);
        ok   ("title after both counts", metaTitle, "NBA Jam");

        // ...and a title that happens to start with digits is not eaten,
        // whichever count it lands after.
        meta_parse("CMDMETA,2,12,1943 The Battle of Midway|System=NES");
        okInt("digits are not a count", metaPinned, 0);
        ok   ("numeric title intact",   metaTitle, "1943 The Battle of Midway");

        meta_parse("CMDMETA,2,12,0,1943 The Battle of Midway|System=NES");
        okInt("explicit zero",        metaPinned, 0);
        ok   ("title after a zero",   metaTitle, "1943 The Battle of Midway");

        meta_parse("CMDMETA,1,12,0,0,1943 The Battle of Midway|Year=1984");
        okInt("two explicit zeros",    metaCompact, 0);
        ok   ("title after two zeros", metaTitle, "1943 The Battle of Midway");
    }

    section("pinning cannot swallow the whole list");
    {
        meta_parse("CMDMETA,2,0,9,Game|A=1|B=2|C=3|D=4|E=5");
        okBool("pinned capped below the row count",
               meta_pinnedRows() <= CON_FIELD_ROWS - 1, true);
        okBool("always a slot to page with", meta_pageSlots() >= 1, true);
        okBool("page count is sane",         meta_pageCount() >= 1, true);

        // Fewer fields than pinned asks for.
        meta_parse("CMDMETA,2,0,3,Game|A=1");
        okBool("pinned never exceeds the fields",
               meta_pinnedRows() <= metaFieldCount, true);
        okInt ("one page",                   meta_pageCount(), 1);
    }

    section("no pinning behaves as before");
    {
        meta_parse("CMDMETA,2,0,0,Game|A=1|B=2|C=3|D=4|E=5|F=6");
        okInt("all four rows page", meta_pageSlots(), 4);
        okInt("six fields, two pages", meta_pageCount(), 2);
    }


    section("pinned and paged rows share a column");
    {
        meta_parse("CMDMETA,2,0,2,Airwolf|System=NES|Year=1989, Acclaim"
                   "|Genre=Shooter|Region=USA|Format=NES");
        metaHasIcon = false;
        fieldPage = 0;
        u8g2.resetProbe();
        meta_renderConsole();

        int16_t xSystem = u8g2.xOf("System");
        int16_t xYear   = u8g2.xOf("Year");
        int16_t xGenre  = u8g2.xOf("Genre");
        int16_t xRegion = u8g2.xOf("Region");

        okInt("System label x", xSystem, meta_textX());
        okInt("Year label x",   xYear,   meta_textX());
        okInt("Genre label x",  xGenre,  meta_textX());
        okInt("Region label x", xRegion, meta_textX());
        okBool("pinned and paged labels share a column",
               xSystem == xGenre && xYear == xRegion, true);

        // Values share one column too. They used to start immediately after
        // each label, so "Year" and "System" put theirs in different places
        // and the rows read as misaligned.
        int16_t vSystem = u8g2.xOf("NES");
        int16_t vYear   = u8g2.xOf("1989");
        int16_t vGenre  = u8g2.xOf("Shooter");
        int16_t vRegion = u8g2.xOf("USA");
        okBool("all four values share a column",
               vSystem == vYear && vYear == vGenre && vGenre == vRegion, true);
        okBool("the column clears the widest label",
               vSystem >= meta_textX() + meta_textWidth("System"), true);

        // ...and it does not move when the page turns.
        fieldPage = 1;
        u8g2.resetProbe();
        meta_renderConsole();
        okInt("column unchanged on page 2", u8g2.xOf("NES"), vSystem);
        fieldPage = 0;
    }

    section("boot screen - the band the firmware keeps for itself");
    {
        // A user image is the panel above the band, and the band holds the
        // power-on sweep and then the build version. Everything here is
        // arithmetic over the constants, which is what quietly goes wrong when
        // one of them is tuned: too small a band and the sweep is drawn over
        // the picture, too large and the picture loses rows for nothing.
        okInt ("band reaches the bottom of the panel",
               BOOT_BAND_Y + BOOT_BAND_H, BOOT_PANEL_H);
        okInt ("image plus band is the whole panel",
               BOOTIMG_H + BOOT_BAND_H, BOOT_PANEL_H);
        okInt ("image is 54 rows",   BOOTIMG_H, 54);
        okInt ("image is 256 wide",  BOOTIMG_W, 256);
        okInt ("image bytes at 4bpp", BOOTIMG_BYTES, 6912);
        okInt ("legacy image bytes",  BOOTIMG_LEGACY_BYTES, 8192);

        // oled_showStartScreen() blacks metaBin from BOOTIMG_BYTES to the end
        // of the framebuffer before handing it to draw4bppBitmap(). That tail
        // has to be the band exactly - short and the sweep runs over a strip
        // of stale picture, long and it eats the bottom of the image.
        okInt ("panel is a whole framebuffer", BOOT_PANEL_BYTES, 8192);
        okInt ("blanked tail is exactly the band",
               (BOOT_PANEL_BYTES - BOOTIMG_BYTES) / (BOOT_PANEL_W / 2),
               BOOT_BAND_H);

        // The built-in picture goes through the same buffer as a stored one,
        // so it has to be exactly the same shape. Regenerated at the wrong
        // size it would either leave a strip of stale buffer above the band or
        // be copied over the band the sweep needs.
        okInt ("built-in logo is the image size",
               (int)sizeof(bootlogo_bits), BOOTIMG_BYTES);
        okInt ("built-in logo width",  bootlogo_width,  BOOTIMG_W);
        okInt ("built-in logo height", bootlogo_height, BOOTIMG_H);

        okInt ("blank row above the sweep bar",
               BOOT_BAR_Y - BOOT_BAND_Y, BOOT_GAP_BAND);
        okInt ("sweep bar ends one row off the bottom",
               BOOT_BAR_Y + BOOT_BAR_H - 1, BOOT_PANEL_H - 2);
        okBool("sweep bar starts below the image",
               BOOT_BAR_Y >= BOOTIMG_H, true);
        // The comet's tail carries every 4bpp level, and its brightest is
        // white: one level per BOOT_BAR_SEG pixels, sixteen of them.
        okInt ("the tail is one segment per grey",
               BOOT_BAR_TAIL, BOOT_BAR_LEVELS * BOOT_BAR_SEG);
        okInt ("its head is white", BOOT_BAR_LEVELS - 1, SSD1322_WHITE);
        okBool("and the tail is shorter than the panel",
               BOOT_BAR_TAIL < BOOT_PANEL_W, true);
        okBool("a re-show's sweep repeats at least once",
               BOOT_SWEEP_REPEATS >= 1, true);
        okBool("a pixel of sweep takes time", BOOT_BAR_PX_MS > 0, true);
        // The run is the panel plus the tail, so the comet leaves the edge
        // completely rather than vanishing whole.
        okInt ("a run clears the panel and drains the tail",
               BOOT_BAR_SPAN(0), BOOT_PANEL_W + BOOT_BAR_TAIL);

        okInt ("version sits on the last row", BOOT_VER_Y, BOOT_PANEL_H - 1);
        okBool("version text stays below the image",
               BOOT_VER_Y - BOOT_VER_H + 1 >= BOOTIMG_H, true);

        // The picture and the version go up together and the bar starts a
        // second later, which is long enough to register as a still frame and
        // short enough that somebody watching sees it start.
        okInt ("bar starts one second in", BOOT_HOLD_MS, 1000);

        // The whole reason the bar has to be pushed right: the version is
        // drawn first and stays up, and the two occupy the same rows. Nothing
        // but the column reservation keeps the sweep off the glyphs.
        okBool("version and sweep bar share rows",
               BOOT_VER_Y - BOOT_VER_H + 1 <= BOOT_BAR_Y + BOOT_BAR_H - 1, true);

        // boot_barStartX is the only thing that decides where the bar may
        // start, so the invariants it has to hold are checked over the whole
        // range of widths a version string could measure rather than for the
        // one string this build happens to carry.
        bool inRange = true, clearsText = true, keepsGap = true;
        for (int w = 0; w < BOOT_BAR_X_MAX; w++) {
            int x = boot_barStartX(w);
            if (x < BOOT_BAR_SEG || x > BOOT_BAR_X_MAX)  inRange    = false;
            if (x <= w)                                  clearsText = false;
            if (w <= BOOT_BAR_X_MAX - BOOT_VER_GAP &&
                x < w + BOOT_VER_GAP)                    keepsGap   = false;
        }
        okBool("bar start stays inside the panel",   inRange,    true);
        okBool("bar never starts on the version",    clearsText, true);
        okBool("bar leaves the gap after the text",  keepsGap,   true);
        okInt ("a wide version string is clamped",
               boot_barStartX(BOOT_PANEL_W), BOOT_BAR_X_MAX);

        // The comet clipped against a start column: nothing is drawn left of
        // it, whatever of the tail would have fallen there.
        oled.resetProbe();
        boot_barDraw(BOOT_BAR_X_MAX + 8, BOOT_BAR_X_MAX);
        bool insideStart = true, insidePanel = true;
        for (const auto &r : oled.rects) {
            if (r.x < BOOT_BAR_X_MAX)            insideStart = false;
            if (r.x + r.w > BOOT_PANEL_W)        insidePanel = false;
        }
        okBool("the tail is clipped at the start column", insideStart, true);
        okBool("and at the panel edge",                   insidePanel, true);
        oled.resetProbe();
    }

    section("busy bar: a label takes the panel above the band");
    {
        busy_cancel();
        busy_forgetLabel();
        tfState = TF_IDLE;
        oled.resetProbe();
        u8g2.resetProbe();

        busy_parse("CMDBUSY,1,UPDATING");
        okBool("CMDBUSY,1,<label> starts the bar", busyActive, true);
        ok    ("and draws the label", u8g2.lastPrint, "UPDATING");

        // The whole panel is blacked first: the band included, or a bar
        // stopped half way through a cycle would show under the message.
        okInt ("the panel is cleared for it", (long)oled.rects.size(), 1);
        okInt ("all 64 rows of it", oled.rects[0].h, BOOT_PANEL_H);
        okInt ("from the top", oled.rects[0].y, 0);
        okInt ("in black", oled.rects[0].color, SSD1322_BLACK);

        // Centred across the panel, and inside the rows above the band - the
        // band belongs to the bar.
        const auto &d = u8g2.draws[0];
        okInt ("centred across the panel",
               d.x, (BOOT_PANEL_W - (int)strlen("UPDATING") * d.charW) / 2);
        okBool("its baseline is above the band", d.y < BOOT_BAND_Y, true);

        // A poll every couple of seconds re-sends the same command: redrawing
        // would rewind the sweep and flash the panel each time.
        for (int i = 0; i < 4; i++) { g_fakeMillis += BOOT_BAR_PX_MS; busy_tick(); }
        int posBefore = busyHead;
        oled.resetProbe();
        u8g2.resetProbe();
        busy_parse("CMDBUSY,1,UPDATING");
        okInt ("the same label again draws nothing", u8g2.printCalls, 0);
        okInt ("and does not rewind the sweep", busyHead, posBefore);

        // A different one is a different message, so it starts over.
        busy_parse("CMDBUSY,1,Updating TTY2OLED+...");
        ok    ("a new label is drawn", u8g2.lastPrint, "Updating TTY2OLED+...");
        okInt ("and the sweep starts from the left", busyHead, 0);

        // Whoever takes the panel takes the message with it, so the next
        // CMDBUSY carrying it has to draw it again.
        busy_noteCommand("CMDCOR,nes,-2");
        okBool("a picture cancels the bar", busyActive, false);
        u8g2.resetProbe();
        busy_parse("CMDBUSY,1,Updating TTY2OLED+...");
        ok    ("and the label is drawn afresh", u8g2.lastPrint, "Updating TTY2OLED+...");

        // CMDBOOTPIC draws a picture - the boot image as the menu's - even
        // though the boot screen counts it as quiet. A bar left running over
        // it never stopped: the MENU core sends no CMDCOR to cancel it, and
        // that is what was left sweeping after every self-update.
        busy_cancel(); busy_forgetLabel();
        busy_parse("CMDBUSY,1,UPDATING");
        busy_noteCommand("CMDBOOTPIC,MENU,-2");
        okBool("the menu picture stops the bar", busyActive, false);
        busy_parse("CMDBUSY,1,UPDATING");
        busy_noteCommand("CMDCON,120");
        okBool("but a setting still does not", busyActive, true);

        // Without a label the picture underneath is left alone - that is the
        // bar as update_all's settings screen and the boot sweep use it.
        busy_cancel(); busy_forgetLabel();
        oled.resetProbe(); u8g2.resetProbe();
        busy_parse("CMDBUSY,1");
        okInt ("no label, nothing drawn over the picture", u8g2.printCalls, 0);
        okInt ("and nothing cleared", (long)oled.rects.size(), 0);
        busy_cancel(); busy_forgetLabel();
    }

    section("busy bar: the label comes back after the screen it was on is redrawn");
    {
        // update_all runs the downloader twice - its own update, then the
        // real one. Between them the daemon stops the bar and puts the
        // update_all screen back, and by then the bar has drained: it is
        // not running when the screen is drawn over the label. The second
        // run sends the same label, and it has to be drawn again - the one
        // the firmware remembers is no longer on the panel.
        busy_cancel();
        busy_forgetLabel();
        tfState = TF_IDLE;
        busy_parse("CMDBUSY,1,Updating System ...");
        busy_parse("CMDBUSY,0");
        for (int i = 0; i < 1000 && busyActive; i++) { g_fakeMillis += BOOT_BAR_PX_MS; busy_tick(); }
        okBool("the bar has run off before the next screen", busyActive, false);

        busy_noteCommand("CMDMETAOFF");                // quiet: the label is still up
        busy_noteCommand("CMDMSG,-2,update_all");      // the update_all screen, over it
        u8g2.resetProbe();
        busy_parse("CMDBUSY,1,Updating System ...");
        okBool("the second run's label is drawn",
               u8g2.printCalls == 1 && u8g2.find("Updating System ...") != nullptr, true);
        okBool("with the bar under it", busyActive, true);

        // A quiet command in between leaves the label on the panel, so the
        // same label again is still nothing to draw.
        busy_parse("CMDBUSY,0");
        for (int i = 0; i < 1000 && busyActive; i++) { g_fakeMillis += BOOT_BAR_PX_MS; busy_tick(); }
        busy_noteCommand("CMDCON,120");
        u8g2.resetProbe();
        busy_parse("CMDBUSY,1,Updating System ...");
        okInt ("a label still on the panel is not drawn twice", u8g2.printCalls, 0);
        busy_cancel();
        busy_forgetLabel();
    }

    section("busy bar: a label that replaces a picture transitions in");
    {
        // The updater's screen takes over from whatever core was loaded, so
        // it is a change of picture and arrives like one. The downloader's
        // bar is not: by then the panel is already the update_all screen, and
        // fading from one message to another says something changed when
        // nothing did. The effect on the end of the command is that
        // distinction, and the daemon is what knows which case it is in.
        auto at = [](unsigned long ms) { g_fakeMillis += ms; contrast_tick(); transition_tick(); };
        busy_cancel(); busy_forgetLabel();
        transition_cancel();
        tfState = TF_IDLE;
        tfFadeMs = 1600; tfBlankMs = 500;
        fadeMs = 0; contrast = 200; contrast_jump(200); veil_fadeOver(255, 0);
        memset(oled.buf, 0xCC, sizeof(oled.buf));      // a core's artwork

        busy_parse("CMDBUSY,1,Updating TTY2OLED+...,-2");
        okBool("an effect makes it a transition", tfState == TF_OUT, true);
        okBool("the bar waits for it", (busy_tick(), busyHead) == 0, true);
        // It fades from the artwork, not from the message: the old picture has
        // to be taken before the label is rendered over it.
        at(100);
        okInt ("the artwork is what fades out", (int)oled.buf[0], 0xBB);
        for (int i = 0; i < 400 && tfState != TF_IDLE; i++) at(10);
        okBool("and it finishes", tfState == TF_IDLE, true);
        ok    ("with the message on the panel", u8g2.lastPrint, "Updating TTY2OLED+...");
        okBool("the bar runs once it is over", (at(BOOT_BAR_PX_MS), busy_tick(), busyHead) > 0, true);

        // No effect: drawn, exactly as before. This is the downloader's bar.
        busy_cancel(); busy_forgetLabel();
        transition_cancel();
        memset(oled.buf, 0xCC, sizeof(oled.buf));
        u8g2.resetProbe();
        busy_parse("CMDBUSY,1,Updating System ...");
        okBool("no effect, no transition", tfState == TF_IDLE, true);
        ok    ("the message is simply drawn", u8g2.lastPrint, "Updating System ...");

        // The effect is not part of the label, and not part of what makes two
        // CMDBUSYs the same: a poll every couple of seconds must not redraw.
        busy_cancel(); busy_forgetLabel();
        transition_cancel();
        busy_parse("CMDBUSY,1,UPDATING,-2");
        for (int i = 0; i < 400 && tfState != TF_IDLE; i++) at(10);
        ok    ("the label stops at the effect", busyLabel, "UPDATING");
        u8g2.resetProbe();
        busy_parse("CMDBUSY,1,UPDATING,-2");
        okInt ("the same label and effect draws nothing", u8g2.printCalls, 0);
        busy_parse("CMDBUSY,1,UPDATING");
        okInt ("nor the same label without one", u8g2.printCalls, 0);
        okBool("and neither starts a transition", tfState == TF_IDLE, true);

        // A fade-slide is an effect like any other here.
        busy_cancel(); busy_forgetLabel();
        transition_cancel();
        busy_parse("CMDBUSY,1,SLIDING,30");
        okBool("a fade-slide works too", tfState == TF_OUT, true);
        okBool("and slides", tfSlideDX != 0, true);
        for (int i = 0; i < 400 && tfState != TF_IDLE; i++) at(10);
        ok    ("landing on the message", u8g2.lastPrint, "SLIDING");
        okBool("with the bar still to run", busyActive, true);
        {
            int head0 = busyHead;
            for (int i = 0; i < 20; i++) { g_fakeMillis += BOOT_BAR_PX_MS; busy_tick(); }
            okBool("and it sweeps once the slide is over", busyHead > head0, true);
        }

        busy_cancel(); busy_forgetLabel();
        transition_cancel();
        tfSlideDX = tfSlideDY = 0;
        tfFadeMs = TFADE_MS_DEFAULT; tfBlankMs = TBLANK_MS_DEFAULT;
    }

    section("busy bar: a status line under the label, and the finish");
    {
        auto at = [](unsigned long ms) { g_fakeMillis += ms; contrast_tick(); transition_tick(); };
        auto rowsCleared = []() {
            int h = -1;
            for (const auto &r : oled.rects)
                if (r.x == 0 && r.y == 0 && r.w == BOOT_PANEL_W && r.color == SSD1322_BLACK) h = r.h;
            return h;
        };
        busy_cancel(); busy_forgetLabel();
        transition_cancel();
        tfState = TF_IDLE;

        // The geometry, off the band: the line's rows and a gap, then the bar.
        okInt ("the line's first row",           BUSY_LINE_TOP, BUSY_LINE_Y - BUSY_LINE_ASC + 1);
        okInt ("its descent, then BUSY_GAP_LINE blank rows, then the band",
               BUSY_LINE_Y + 1 + BUSY_GAP_LINE + 1, BOOT_BAND_Y);
        okBool("the whole line fits the panel's 51 columns of 5x7", 51 * 5 <= BOOT_PANEL_W, true);

        busy_parse("CMDBUSY,1,Updating System ...");
        u8g2.resetProbe();
        int bareY = -1;
        busy_forgetLabel(); busy_cancel();
        busy_parse("CMDBUSY,1,Updating System ...");
        for (const auto &d : u8g2.draws) if (d.text == "Updating System ...") bareY = d.y;
        for (int i = 0; i < 6; i++) { g_fakeMillis += BOOT_BAR_PX_MS; busy_tick(); }
        int head = busyHead;

        oled.resetProbe(); u8g2.resetProbe();
        busy_lineParse("CMDBUSYLINE,SECTION: jtcores");
        ok    ("the line is drawn", busyLine, "SECTION: jtcores");
        const FakeU8g2::Draw *label = nullptr, *line = nullptr;
        for (const auto &d : u8g2.draws) {
            if (d.text == "Updating System ...") label = &d;
            if (d.text == "SECTION: jtcores")   line  = &d;
        }
        okBool("with the label redrawn above it", label && line, true);
        if (label && line) {
            okInt ("on its baseline", line->y, BUSY_LINE_Y);
            okInt ("in the small font", line->charW, 5);
            okInt ("centred", line->x, (BOOT_PANEL_W - 16 * 5) / 2);
            okBool("in grey, not white", line->fg == BUSY_LINE_GREY && BUSY_LINE_GREY < SSD1322_WHITE, true);
            okInt ("the label stays where it was", label->y, bareY);
            okBool("clear of it", label->y < BUSY_LINE_TOP, true);
            okInt ("and is white", label->fg, SSD1322_WHITE);
        }
        okInt ("only the rows above the band are cleared", rowsCleared(), BOOT_BAND_Y);
        okBool("the bar keeps its place", busyActive && busyHead == head, true);

        u8g2.resetProbe();
        busy_lineParse("CMDBUSYLINE,SECTION: jtcores");
        okInt ("the same line again draws nothing", u8g2.printCalls, 0);

        // Longer than the buffer: kept to BUSY_LINE_MAX, from the left.
        std::string longLine = "CMDBUSYLINE," + std::string(100, 'x');
        busy_lineParse(longLine.c_str());
        okInt ("a long line is cut to the buffer", (long)strlen(busyLine), BUSY_LINE_MAX);
        okInt ("and starts at the left edge", u8g2.draws.back().x, 0);

        // Empty takes it down, and the label does not move.
        u8g2.resetProbe();
        busy_lineParse("CMDBUSYLINE,");
        okInt ("an empty line removes it", (long)strlen(busyLine), 0);
        okBool("and the label stays put",
               u8g2.draws.size() == 1 && u8g2.draws[0].y == bareY, true);

        // A drawing command takes the screen, the line with it.
        busy_lineParse("CMDBUSYLINE,Installing scripts");
        busy_noteCommand("CMDCOR,nes,-2");
        okInt ("a picture forgets the line", (long)strlen(busyLine), 0);
        u8g2.resetProbe();
        busy_lineParse("CMDBUSYLINE,Installing scripts");
        okInt ("and a line with no busy screen is not drawn", u8g2.printCalls, 0);

        // A quiet command does not.
        busy_parse("CMDBUSY,1,Updating System ...");
        busy_lineParse("CMDBUSYLINE,Installing scripts");
        busy_noteCommand("CMDCON,120");
        ok    ("a setting leaves it", busyLine, "Installing scripts");
        busy_noteCommand("CMDBUSYLINE,next");
        ok    ("and so does the line command itself", busyLine, "Installing scripts");

        // A new label is a new screen, with no detail until one is sent.
        busy_parse("CMDBUSY,1,Updating TTY2OLED+...");
        okInt ("a new label clears the line", (long)strlen(busyLine), 0);

        // The finish, on a running bar: the label changes, the band is left
        // to the comet, which runs its cycle off the edge.
        busy_lineParse("CMDBUSYLINE,Flashing");
        for (int i = 0; i < 6; i++) { g_fakeMillis += BOOT_BAR_PX_MS; busy_tick(); }
        oled.resetProbe(); u8g2.resetProbe();
        busy_parse("CMDBUSY,0,Update Complete");
        ok    ("CMDBUSY,0,<label> changes the label", u8g2.lastPrint, "Update Complete");
        okInt ("and drops the line", (long)strlen(busyLine), 0);
        okInt ("above the band only", rowsCleared(), BOOT_BAND_Y);
        okBool("the bar finishes its cycle", busyActive && busyStopping, true);
        for (int i = 0; i < 1000 && busyActive; i++) { g_fakeMillis += BOOT_BAR_PX_MS; busy_tick(); }
        okBool("and stops", busyActive, false);
        u8g2.resetProbe();
        busy_parse("CMDBUSY,0,Update Complete");
        okInt ("the same finish again draws nothing", u8g2.printCalls, 0);
        busy_lineParse("CMDBUSYLINE,tty2oled+ 0.7.0b");
        ok    ("a line can follow it", u8g2.lastPrint, "tty2oled+ 0.7.0b");
        okBool("with no bar", busyActive, false);

        // The finish on a panel that is not the busy screen - the display
        // has just been reset by a flash - is a whole new screen, no bar.
        busy_cancel(); busy_forgetLabel();
        oled.resetProbe(); u8g2.resetProbe();
        busy_parse("CMDBUSY,0,Update Complete");
        ok    ("after a reset it is drawn", u8g2.lastPrint, "Update Complete");
        okInt ("over the whole panel", rowsCleared(), BOOT_PANEL_H);
        okBool("with no bar started", busyActive, false);

        // Without a label, CMDBUSY,0 is what it always was.
        busy_parse("CMDBUSY,1,Updating System ...");
        u8g2.resetProbe();
        busy_parse("CMDBUSY,0");
        okInt ("a bare CMDBUSY,0 draws nothing", u8g2.printCalls, 0);
        okBool("and lets the bar finish", busyStopping, true);
        ok    ("keeping the label", busyLabel, "Updating System ...");

        // A line that arrives mid-transition waits for it: the transition
        // redraws the frame from its own copy every step.
        busy_cancel(); busy_forgetLabel();
        tfFadeMs = 1600; tfBlankMs = 500;
        fadeMs = 0; contrast = 200; contrast_jump(200); veil_fadeOver(255, 0);
        busy_parse("CMDBUSY,1,Updating TTY2OLED+...,-2");
        okBool("the label transitions in", tfState == TF_OUT, true);
        u8g2.resetProbe();
        busy_lineParse("CMDBUSYLINE,Downloading");
        okInt ("a line meanwhile is not drawn yet", u8g2.printCalls, 0);
        for (int i = 0; i < 400 && tfState != TF_IDLE; i++) { at(10); busy_tick(); }
        okBool("the transition ends", tfState == TF_IDLE, true);
        busy_tick();
        okBool("and the line is drawn after it", u8g2.find("Downloading") != nullptr, true);
        okBool("once", busyTextDirty, false);

        busy_cancel(); busy_forgetLabel();
        transition_cancel();
        tfSlideDX = tfSlideDY = 0;
        tfFadeMs = TFADE_MS_DEFAULT; tfBlankMs = TBLANK_MS_DEFAULT;
    }

    section("CMDMSG: a message that arrives like a picture");
    {
        // The update_all screen whenever the artwork pack has no
        // update_all.gsc, which is the usual case. A bare line is what the
        // firmware draws for any command it does not know, and carries no
        // effect, so the daemon asks for this by name instead.
        auto at = [](unsigned long ms) { g_fakeMillis += ms; contrast_tick(); transition_tick(); };
        busy_cancel(); busy_forgetLabel();
        transition_cancel();
        tfState = TF_IDLE;
        tfFadeMs = 1600; tfBlankMs = 500;
        fadeMs = 0; contrast = 200; contrast_jump(200); veil_fadeOver(255, 0);
        memset(oled.buf, 0xCC, sizeof(oled.buf));
        u8g2.resetProbe();

        msg_parse("CMDMSG,-2,update_all");
        okBool("it starts a transition", tfState == TF_OUT, true);
        at(100);
        okInt ("from what was on the panel", (int)oled.buf[0], 0xBB);
        for (int i = 0; i < 400 && tfState != TF_IDLE; i++) at(10);
        ok    ("and lands on the message", u8g2.lastPrint, "update_all");
        okBool("with nothing left running", tfState == TF_IDLE, true);

        // The text is the rest of the line, so it needs no quoting and a
        // comma in it cannot be mistaken for anything.
        transition_cancel();
        msg_parse("CMDMSG,0,Updating, please wait");
        ok    ("the text is the whole rest of the line", u8g2.lastPrint, "Updating, please wait");

        ok    ("and the text is remembered for a re-show", msgText, "Updating, please wait");

        transition_cancel();
        tfSlideDX = tfSlideDY = 0;
        tfFadeMs = TFADE_MS_DEFAULT; tfBlankMs = TBLANK_MS_DEFAULT;
        srcBin = logoBin;
    }

    section("busy bar: the boot sweep in the band while the downloader runs");
    {
        busy_cancel();
        tfState = TF_IDLE;
        oled.resetProbe();
        busy_parse("CMDBUSY,1");
        okBool("CMDBUSY,1 starts it", busyActive, true);
        busy_tick();
        okInt ("nothing before the first step", (long)oled.rects.size(), 0);

        // One frame: the whole comet, every grey once, on the bar's rows only.
        // Taken once the head is clear of the left edge, since until then the
        // tail is clipped and only part of the gradient is on the panel.
        for (int i = 0; i < BOOT_BAR_TAIL; i++) { g_fakeMillis += BOOT_BAR_PX_MS; busy_tick(); }
        oled.resetProbe();
        g_fakeMillis += BOOT_BAR_PX_MS; busy_tick();
        okInt ("a frame is one rectangle per grey",
               (long)oled.rects.size(), BOOT_BAR_LEVELS);
        bool rows = true;
        int seen[BOOT_BAR_LEVELS] = {0};
        for (const auto &r : oled.rects) {
            if (r.y != BOOT_BAR_Y || r.h != BOOT_BAR_H) rows = false;
            if (r.color < BOOT_BAR_LEVELS) seen[r.color]++;
        }
        bool everyGrey = true;
        for (int i = 0; i < BOOT_BAR_LEVELS; i++) if (seen[i] != 1) everyGrey = false;
        okBool("on the boot bar's rows, nowhere above the band", rows, true);
        okBool("all sixteen greys, one segment each", everyGrey, true);

        // The head moves a single pixel per frame - what makes it smooth -
        // and it is the brightest thing drawn.
        auto headOf = []() {
            for (const auto &r : oled.rects)
                if (r.color == BOOT_BAR_LEVELS - 1) return (int)(r.x + r.w - 1);
            return -1;
        };
        int h0 = headOf();
        oled.resetProbe();
        g_fakeMillis += BOOT_BAR_PX_MS; busy_tick();
        okInt ("the head advances one step a frame", headOf() - h0, BOOT_BAR_PX_STEP);
        okBool("and it keeps going", busyActive, true);

        // A stall - a picture arriving - does not come back as a burst: the
        // head resumes a pixel on, not wherever the clock says it should be.
        h0 = headOf();
        oled.resetProbe();
        g_fakeMillis += 5000; busy_tick();
        okInt ("a stall resumes with one step, not a leap", headOf() - h0, BOOT_BAR_PX_STEP);

        // CMDBUSY,0 lets the comet run off the right edge, which leaves the
        // band empty without a clearing pass of its own.
        busy_parse("CMDBUSY,0");
        okBool("CMDBUSY,0 lets it finish", busyActive, true);
        for (int i = 0; i < BOOT_BAR_SPAN(0) + 8 && busyActive; i++) {
            g_fakeMillis += BOOT_BAR_PX_MS; busy_tick();
        }
        okBool("then it stops", busyActive, false);
        bool busyCleared = false;
        for (const auto &r : oled.rects)
            if (r.y == BOOT_BAR_Y && r.color == SSD1322_BLACK &&
                r.x == 0 && r.w == BOOT_PANEL_W) busyCleared = true;
        okBool("blacking the bar on its way out", busyCleared, true);
        oled.resetProbe();
        g_fakeMillis += 100 * BOOT_BAR_PX_MS; busy_tick();
        okInt ("with nothing left on the panel", (long)oled.rects.size(), 0);

        // Something else taking the panel stops it at once; setup does not.
        busy_start();
        busy_noteCommand("CMDCON,120");
        okBool("a quiet command leaves it running", busyActive, true);
        busy_noteCommand("CMDBUSY,1");
        okBool("and so does its own", busyActive, true);
        busy_noteCommand("CMDCOR,nes,-2");
        okBool("a picture stops it dead", busyActive, false);
        oled.resetProbe();
        g_fakeMillis += 10 * BOOT_BAR_PX_MS; busy_tick();
        okInt ("without another frame", (long)oled.rects.size(), 0);

        // It waits out a Fade transition rather than draw into it.
        busy_start();
        tfState = TF_BLANK;
        oled.resetProbe();
        g_fakeMillis += 10 * BOOT_BAR_PX_MS; busy_tick();
        okInt ("nothing drawn during a Fade", (long)oled.rects.size(), 0);
        tfState = TF_IDLE;
        g_fakeMillis += BOOT_BAR_PX_MS; busy_tick();
        okInt ("and it starts after", (long)oled.rects.size(), 1);
        busy_cancel();
    }

    section("CMDSCROLL sets both speeds, in pixels per second");
    {
        okBool("parsed",                   meta_parseScroll("CMDSCROLL,10,4"), true);
        okInt ("10 px/s is 100ms a pixel", (long)metaHStepMs, 100);
        okInt ("4 px/s is 250ms a pixel",  (long)metaVStepMs, 250);
        meta_parseScroll("CMDSCROLL,0,0");
        okInt ("nothing slower than 1 px/s", (long)metaHStepMs, 1000);
        okInt ("either way",                 (long)metaVStepMs, 1000);
        meta_parseScroll("CMDSCROLL,9999,9999");
        okInt ("nor faster than the cap",    (long)metaHStepMs, 1000 / HSCROLL_SPEED_MAX);
        okInt ("vertically too",             (long)metaVStepMs, 1000 / VSCROLL_SPEED_MAX);
        okBool("junk is refused", meta_parseScroll("CMDSCROLL,x"), false);
        okBool("it changes nothing on the panel, so the boot screen stays",
               boot_quietCommand("CMDSCROLL,25,5"), true);

        // The marquee runs at the period it was given, not the old constant.
        meta_parseScroll("CMDSCROLL,10,5");
        std::string cmd = "CMDMETA,2,0,An Extraordinarily Long Title That Overflows|System=NES";
        meta_parse(cmd.c_str());
        metaNeedsDraw   = false;
        g_fakeMillis   += 100000;
        scrollHoldUntil = 0;
        lastScrollTick  = g_fakeMillis;
        titleScrollX    = 0;
        g_fakeMillis   += 60;
        meta_tick();
        okInt("not a pixel before its 100ms are up", titleScrollX, 0);
        g_fakeMillis   += 41;
        meta_tick();
        okInt("one when they are",                   titleScrollX, 1);
        meta_parseScroll("CMDSCROLL,25,6");
        okInt("the default marquee is the old 40ms",    (long)metaHStepMs, SCROLL_STEP_MS);
        okInt("and the description 6 pixels a second",  (long)metaVStepMs, DESC_STEP_MS);
        okInt("which is a pixel every 166ms",           (long)DESC_STEP_MS, 166);
    }

    section("CMDDESC: the length, and what is kept of the bytes");
    {
        okInt("a length",            meta_parseDescLength("CMDDESC,120"), 120);
        okInt("none is refused",     meta_parseDescLength("CMDDESC,"), -1);
        okInt("negative is refused", meta_parseDescLength("CMDDESC,-4"), -1);

        meta_reset();
        const char raw[] = "Tab\there\nnewline\x01 and \xc3\xa9";
        meta_setDesc(raw, sizeof(raw) - 1);
        ok("anything unprintable becomes a space", metaDesc,
           std::string("Tab here newline  and   "));

        std::string big(DESC_MAX + 300, 'a');
        meta_setDesc(big.c_str(), big.size());
        okInt("cut to DESC_MAX", metaDescLen, DESC_MAX);
        meta_setDesc("", 0);
        okInt("an empty one is none", metaDescLen, 0);
    }

    section("the description is a page after the fields");
    {
        meta_parse("CMDMETA,2,0,2,Sonic The Hedgehog|System=Mega Drive|Year=1991"
                   "|Genre=Platform|Region=USA|Format=MD");
        okInt ("three fields paged under two pinned: two pages", meta_pageCount(), 2);
        meta_setDesc("A blue hedgehog runs very fast.", 31);
        okInt ("the description adds one",  meta_pageCount(), 3);
        okBool("after the fields",          meta_isDescPage(2), true);
        okBool("page 0 is still fields",    meta_isDescPage(0), false);

        meta_parse("CMDMETA,2,0,2,Sonic|System=Mega Drive");
        okInt ("a new game drops the last one's description", metaDescLen, 0);
        okInt ("and its page",                                meta_pageCount(), 1);
        meta_setDesc("Text.", 5);
        meta_reset();
        okInt ("so does leaving metadata", metaDescLen, 0);
    }

    section("the description wraps to the text column");
    {
        meta_parse("CMDMETA,2,0,Game|System=NES");
        std::string text = "Sonic the Hedgehog is a platform game developed by Sonic Team "
                           "and published by Sega for the Mega Drive in 1991. "
                           "Supercalifragilisticexpialidociousandthensomemoreletters ends it.";
        meta_setDesc(text.c_str(), text.size());
        meta_descEnsureWrapped();

        const int tw = meta_textW();
        bool fits = true, noLead = true;
        std::string joined;
        for (int l = 0; l < descLineCount; l++) {
            std::string line(metaDesc + descLineStart[l], descLineLen[l]);
            if ((int)line.size() * 5 > tw) fits = false;           // 5px a character
            if (!line.empty() && line[0] == ' ') noLead = false;
            joined += line;
        }
        okBool("several lines",            descLineCount > 3, true);
        okBool("each within the column",   fits, true);
        okBool("none starting with a space", noLead, true);
        // Every character but the spaces the wrap broke at is still there, in
        // order: nothing dropped, nothing doubled.
        std::string want, got;
        for (char c : text)   if (c != ' ') want += c;
        for (char c : joined) if (c != ' ') got  += c;
        ok("nothing lost", got, want);
        // "Sonic the Hedgehog is a platform game" is 37 characters, more
        // than the 33 that fit, so the first line stops at a word.
        ok("words stay whole", std::string(metaDesc + descLineStart[0], descLineLen[0]),
           "Sonic the Hedgehog is a platform");

        // The side swap changes the column's width, and the lines with it.
        int before = descWrapW;
        metaFlipped = true;
        meta_descEnsureWrapped();
        okBool("re-wrapped for the other side", descWrapW != before && descWrapW == meta_textW(), true);
        metaFlipped = false;
        meta_descEnsureWrapped();

        // The line table has room for the most lines a full description can
        // make - one-letter words, the narrow console column - so raising
        // DESC_MAX without DESC_MAX_LINES cannot quietly drop its end.
        std::string worst;
        while (worst.size() + 2 <= DESC_MAX) worst += "a ";
        meta_setDesc(worst.c_str(), worst.size());
        meta_descEnsureWrapped();
        const int last = descLineCount - 1;
        okInt ("a full description of one-letter words is kept whole", (int)worst.size(), DESC_MAX);
        okBool("and every line of it has a place in the table",
               last >= 0 && last < DESC_MAX_LINES - 1 &&
               descLineStart[last] + descLineLen[last] >= (int)worst.size() - 1, true);
    }

    section("the description page: header, title and icon, then the text");
    {
        meta_parse("CMDMETA,2,0,2,Sonic|System=Mega Drive|Year=1991");
        std::string text;
        for (int i = 0; i < 12; i++) { char w[16]; snprintf(w, sizeof w, "line%02d ", i); text += w; text += "xxxxxxxxxxxxxxxxxxxxxxxxx "; }
        meta_setDesc(text.c_str(), text.size());
        fieldPage = meta_fieldPageCount();
        okBool("on it", meta_onDescPage(), true);

        descScrollY = 0;
        u8g2.resetProbe();
        oled.resetProbe();
        meta_renderConsole();
        okBool("the header is still there", u8g2.find(CON_HEADER_TEXT) != nullptr, true);
        okBool("and the title",             u8g2.find("Sonic") != nullptr, true);
        okBool("but not the pinned fields", u8g2.find("System") == nullptr, true);
        const FakeU8g2::Draw *first = u8g2.find("line00");
        okBool("the first line sits where the first field would",
               first && first->y == CON_FIELD_Y0 && first->x == meta_textX(), true);
        int lines = 0;
        for (size_t i = 0; i < u8g2.draws.size(); i++)
            if (u8g2.draws[i].text.rfind("line", 0) == 0 || u8g2.draws[i].text.rfind("xxx", 0) == 0) lines++;
        okInt("as many lines as the area holds", lines, CON_FIELD_ROWS);
        okBool("and every page's pip, the description's included",
               (int)oled.rects.size() >= meta_pageCount(), true);

        // Scrolled so that the first line is half out: it is drawn - and the
        // strip above the area is blacked afterwards, so it cannot reach the
        // title - and a line that is wholly out is not drawn at all.
        descScrollY = CON_FIELD_PITCH + 3;
        u8g2.resetProbe();
        oled.resetProbe();
        meta_renderConsole();
        okBool("a line wholly past the top is not drawn", u8g2.find("line00") == nullptr, true);
        bool clipped = false, above = false;
        for (size_t i = 0; i < oled.rects.size(); i++) {
            const FakeOled::Rect &r = oled.rects[i];
            if (r.color == SSD1322_BLACK && r.y == 0 && r.h == DESC_TOP && r.w == (int)DispWidth) clipped = true;
        }
        for (size_t i = 0; i < u8g2.draws.size(); i++)
            if (u8g2.draws[i].y < DESC_TOP && u8g2.draws[i].text.rfind("xxx", 0) == 0) above = true;
        okBool("the strip above the area is blacked", clipped, true);
        okBool("no line is drawn with its baseline above the area", above, false);
        okBool("nothing wider than the panel", u8g2.maxRight <= (int)DispWidth, true);
        fieldPage = 0;
        descScrollY = 0;
    }

    section("the description scrolls through, then the pager moves on");
    {
        uint16_t keepFade = tfFadeMs;
        tfFadeMs = 0;                             // page turns land at once
        meta_parseScroll("CMDSCROLL,25,6");
        meta_parse("CMDMETA,2,12,2,Sonic|System=Mega Drive|Year=1991");
        metaNeedsDraw = false;
        std::string text = "One two three four five six seven eight nine ten eleven twelve "
                           "thirteen fourteen fifteen sixteen seventeen eighteen nineteen.";
        meta_setDesc(text.c_str(), text.size());
        okInt("fields fit on one page, so two pages", meta_pageCount(), 2);

        g_fakeMillis += 100000;
        lastPageTick  = g_fakeMillis;
        fieldPage     = 0;
        g_fakeMillis += meta_pageDwellMs() + 1;
        meta_tick();
        okInt ("the fields dwell, then the description", fieldPage, 1);
        okInt ("from its first line",                   descScrollY, 0);

        // The turn to it fades the whole area, pinned rows too.
        int x, w, y0, y1;
        meta_consolePagedRect(&x, &w, &y0, &y1, true);
        okInt ("a turn to it covers the whole area", y0, DESC_TOP);

        g_fakeMillis += DESC_HOLD_MS - 10;
        meta_tick();
        okInt ("it holds before moving", descScrollY, 0);
        g_fakeMillis += 20;
        meta_tick();
        okInt ("then moves a pixel",    descScrollY, 1);
        g_fakeMillis += DESC_STEP_MS - 1;
        meta_tick();
        okInt ("not before the next period", descScrollY, 1);
        g_fakeMillis += 1;
        meta_tick();
        okInt ("then another",               descScrollY, 2);

        // It stays on its page, however long it takes, until the last line
        // has gone - the dwell that turns field pages does not apply here.
        const long travel = meta_descTravel();
        okBool("a travel of several lines", travel > 3 * CON_FIELD_PITCH, true);
        int guard = 0;
        while (fieldPage == 1 && guard++ < 10000) {
            g_fakeMillis += DESC_STEP_MS;
            meta_tick();
        }
        okInt ("back to the fields after exactly the travel", guard, (int)travel - 2);
        okInt ("on page 0",                                   fieldPage, 0);
        tfFadeMs = keepFade;
    }

    section("the arcade card: the description is a page after the fields");
    {
        meta_parse("CMDMETA,1,10,2,8,NBA Jam"
                   "|Year=1993|Manufctr=Midway|Region=World|Orient=Horizontal"
                   "|Core=blahmid_tunit|Author=rejectedcoins|Set=nbajam|MAME=0289"
                   "|Players=4|Controls=8-way|Buttons=Turbo/Shoot");
        okInt ("a grid page and a wide page", meta_cardPageCount(), 2);
        meta_setDesc("Two on two basketball.", 22);
        okInt ("the description adds one",   meta_cardPageCount(), 3);
        okBool("after the fields",           meta_cardIsDescPage(2), true);
        okBool("page 0 is still the grid",   meta_cardIsDescPage(0), false);
        okInt ("and it has no wide fields",  (cardPage = 2, meta_cardWideFirst()), -1);
        cardPage = 0;

        // Wrapped across the whole card, which has no icon to share it with.
        std::string text;
        for (int i = 0; i < 20; i++) text += "wordy ";
        meta_setDesc(text.c_str(), text.size());
        meta_descEnsureWrapped();
        okInt ("wrapped to the card's width", descWrapW, CARD_FULL_W);
        okInt ("drawn from the card's margin", meta_descX(), CARD_MARGIN_X);

        // A card that is nothing but a description is not an empty page and
        // then the text.
        meta_parse("CMDMETA,1,10,Game");
        meta_setDesc("Only words.", 11);
        okInt ("no fields and a description: one page", meta_cardPageCount(), 1);
        okBool("which is the description",              meta_cardIsDescPage(0), true);
        meta_reset();
    }

    section("the arcade description page: header, title and cell, then the text");
    {
        meta_parse("CMDMETA,1,10,2,2,Pac-Man|Year=1980|Manufctr=Namco");
        std::string text;
        for (int i = 0; i < 12; i++) { char w[16]; snprintf(w, sizeof w, "line%02d ", i); text += w; text += "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx "; }
        meta_setDesc(text.c_str(), text.size());
        cardPage    = meta_cardFieldPageCount();
        descScrollY = 0;
        u8g2.resetProbe();
        oled.resetProbe();
        meta_renderCard();
        okBool("the header is still there", u8g2.find(CON_HEADER_TEXT) != nullptr, true);
        okBool("and the cell",              u8g2.find(CARD_CELL_TEXT) != nullptr, true);
        okBool("and the title",             u8g2.find("Pac-Man") != nullptr, true);
        okBool("but not the pinned row",    u8g2.find("Year") == nullptr, true);
        const FakeU8g2::Draw *first = u8g2.find("line00");
        okBool("the first line sits where the first row would, at the margin",
               first && first->y == CARD_FIELD_Y0 && first->x == CARD_MARGIN_X, true);
        int lines = 0;
        for (size_t i = 0; i < u8g2.draws.size(); i++)
            if (u8g2.draws[i].text.rfind("line", 0) == 0 || u8g2.draws[i].text.rfind("xxx", 0) == 0) lines++;
        okInt ("as many lines as the area holds", lines, CARD_FIELD_ROWS);
        okBool("nothing wider than the panel", u8g2.maxRight <= (int)DispWidth, true);

        descScrollY = CARD_FIELD_PITCH + 3;
        u8g2.resetProbe();
        oled.resetProbe();
        meta_renderCard();
        bool above = false;
        for (size_t i = 0; i < u8g2.draws.size(); i++)
            if (u8g2.draws[i].y < DESC_TOP && u8g2.draws[i].text.rfind("xxx", 0) == 0) above = true;
        okBool("scrolled, no line is drawn above the area", above, false);
        okBool("and the title is drawn after the text",
               u8g2.find("Pac-Man") != nullptr, true);
        cardPage = 0;
        descScrollY = 0;
        meta_reset();
    }

    section("arcade: artwork, the fields, the description scrolled through, artwork");
    {
        uint16_t keepFade = tfFadeMs;
        tfFadeMs = 0;
        meta_parseScroll("CMDSCROLL,25,6");
        meta_parse("CMDMETA,1,10,2,4,Pong|Year=1972|Manufctr=Atari"
                   "|Region=World|Orient=Horizontal");
        std::string text = "One two three four five six seven eight nine ten eleven twelve "
                           "thirteen fourteen fifteen sixteen seventeen eighteen nineteen "
                           "twenty twentyone twentytwo twentythree twentyfour twentyfive "
                           "twentysix twentyseven twentyeight twentynine thirty.";
        text = text + " " + text;
        meta_setDesc(text.c_str(), text.size());
        okInt("one grid page and the description", meta_cardPageCount(), 2);

        g_fakeMillis    = 900000;
        metaLastSwap    = g_fakeMillis;
        metaShowingCard = false;
        cardPage        = 0;

        g_fakeMillis += 11000;
        okBool("artwork -> the grid", meta_tick(), true);
        okInt ("on the grid page",    cardPage, 0);
        meta_tick();                               // the card has landed

        g_fakeMillis += 11000;
        okBool("grid -> the description", meta_tick(), true);
        int x, w, y0, y1;
        meta_cardPagedRect(&x, &w, &y0, &y1, true);
        okBool("a turn to it fades the whole area, pinned row included",
               y0 == DESC_TOP && x == 0 && w == (int)DispWidth, true);
        settlePageFade();
        okInt ("on the description",      cardPage, 1);
        okInt ("from its first line",     descScrollY, 0);

        g_fakeMillis += DESC_HOLD_MS - 50;
        meta_tick();
        okInt ("it holds before moving",  descScrollY, 0);
        g_fakeMillis += 60;
        meta_tick();
        okInt ("then moves a pixel",      descScrollY, 1);

        // The interval that turns field pages does not apply: however long
        // the text is, it all goes past before the artwork comes back.
        const long travel = meta_descTravel();
        okBool("a travel longer than an interval's worth of pixels",
               travel * (long)DESC_STEP_MS > 10000L, true);
        int guard = 0;
        while (metaShowingCard && guard++ < 10000) {
            g_fakeMillis += DESC_STEP_MS;
            meta_tick();
        }
        okInt ("back to the artwork after exactly the travel", guard, (int)travel - 1);
        okBool("drawn from logoBin",                          lastSrcAtDraw == logoBin, true);
        okInt ("rewound to the first page",                   cardPage, 0);

        g_fakeMillis += 11000;
        okBool("and round again", meta_tick(), true);
        okInt ("from the grid",   cardPage, 0);
        tfFadeMs = keepFade;
        meta_reset();
    }

    section("a description arriving for a layout already up redraws it");
    {
        meta_parse("CMDMETA,2,0,Sonic|System=Mega Drive");
        metaNeedsDraw   = false;
        coreBootHolding = false;
        metaIconRedraw  = false;
        oled.resetProbe();
        meta_setDesc("Text.", 5);
        okBool("drawn at once when the panel is idle", oled.displayCalls > 0, true);

        meta_parse("CMDMETA,2,0,Sonic|System=Mega Drive");
        oled.resetProbe();
        meta_setDesc("Text.", 5);
        okBool("not before the layout's own first draw", oled.displayCalls == 0 && !metaIconRedraw, true);
        meta_reset();
    }

    section("CMDHEAD: the header's caption, console and card");
    {
        const char *SAM = "Super Attract Mode";
        meta_parseHead((std::string("CMDHEAD,") + SAM).c_str());
        meta_parse("CMDMETA,2,0,Sonic|System=Mega Drive");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        okBool("the console says it",            u8g2.find(SAM) != nullptr, true);
        okBool("in place of Now playing",        u8g2.find(CON_HEADER_TEXT) == nullptr, true);
        const FakeU8g2::Draw *h = u8g2.find(SAM);
        if (h) okInt("at the header's baseline",  h->y, CON_HEADER_Y);
        okBool("the rest as it was",             u8g2.find("Sonic") && u8g2.find("System"), true);

        meta_parse("CMDMETA,1,12,NBA Jam|Year=1993|Manufctr=Midway");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderCard();
        okBool("the card says it",               u8g2.find(SAM) != nullptr, true);

        // The most pages a card can have: the caption still whole beside
        // their pips, as Now playing is.
        std::string cmd = "CMDMETA,1,12,Game";
        for (int i = 0; i < META_MAX_FIELDS; i++) {
            char seg[32];
            snprintf(seg, sizeof(seg), "|L%02d=V%02d", i, i);
            cmd += seg;
        }
        meta_parse(cmd.c_str());
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderCard();
        ok    ("whole beside every pip", u8g2.draws[0].text, SAM);
        okBool("and clear of them",
               u8g2.draws[0].x + (int)strlen(SAM) * u8g2.draws[0].charW <= oled.rects[0].x, true);

        // The console with the most pips: too wide for the header font and
        // its narrower cut there, so the smaller one - whole, not clipped.
        cmd = "CMDMETA,2,0,3,Game";
        for (int i = 0; i < 12; i++) {
            char seg[32];
            snprintf(seg, sizeof(seg), "|L%02d=V%02d", i, i);
            cmd += seg;
        }
        meta_parse(cmd.c_str());
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        ok    ("eight pips: still whole",            u8g2.draws[0].text, SAM);
        okInt ("in the smaller font",                u8g2.draws[0].charW, 6);
        okBool("short of the pips",
               u8g2.draws[0].x + (int)strlen(SAM) * u8g2.draws[0].charW <= oled.rects[0].x, true);
        meta_parse("CMDMETA,2,0,3,Game|A=1|B=2|C=3|D=4|E=5");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        okInt ("two pips: the header font itself",   u8g2.draws[0].charW, 8);
        meta_parseHead("CMDHEAD,");
        meta_parse(cmd.c_str());
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        ok    ("Now playing beside eight pips",      u8g2.draws[0].text, CON_HEADER_TEXT);
        okInt ("in the header font, as ever",        u8g2.draws[0].charW, 8);
        meta_parseHead((std::string("CMDHEAD,") + SAM).c_str());

        // Kept across CMDMETAOFF and the next game: the daemon sends it only
        // when it changes.
        meta_reset();
        meta_parse("CMDMETA,2,0,Sonic|System=Mega Drive");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        okBool("kept across CMDMETAOFF", u8g2.find(SAM) != nullptr, true);

        meta_parseHead("CMDHEAD,");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        okBool("nothing after the comma is Now playing again",
               u8g2.find(CON_HEADER_TEXT) != nullptr && u8g2.find(SAM) == nullptr, true);

        meta_parseHead("CMDHEAD,An\x01overlong caption that runs on and on");
        ok    ("cut to META_HEAD_MAX, printable only", metaHeader,
               std::string("An overlong caption that runs on and on").substr(0, META_HEAD_MAX));
        okBool("quiet: the boot screen, bar and band stay", boot_quietCommand("CMDHEAD,x"), true);
        meta_parseHead("CMDHEAD,");
        meta_reset();
    }

    section("CMDHEAD over a layout already up: redrawn there, once idle");
    {
        const char *SAM = "Super Attract Mode";
        meta_parse("CMDMETA,2,0,Sonic|System=Mega Drive");
        metaNeedsDraw = false; coreBootHolding = false; metaIconRedraw = false;
        transition_cancel();
        u8g2.resetProbe(); oled.resetProbe();
        meta_parseHead((std::string("CMDHEAD,") + SAM).c_str());
        okBool("nothing drawn as it arrives", oled.displayCalls == 0 && u8g2.draws.empty(), true);
        okBool("the next tick draws it",      meta_tick(), true);
        okBool("with the new caption",        u8g2.find(SAM) != nullptr, true);
        okBool("the same layout under it",    u8g2.find("Sonic") && u8g2.find("System"), true);
        okBool("a cut, not a transition",     tfState == TF_IDLE, true);
        u8g2.resetProbe(); oled.resetProbe();
        meta_tick();
        okBool("once",                        u8g2.find(SAM) == nullptr, true);

        // Before the layout's own first draw, that draw has it.
        meta_parse("CMDMETA,2,0,Sonic|System=Mega Drive");
        meta_parseHead("CMDHEAD,");
        okBool("not before the first draw, which is the layout's own",
               meta_tick() && !metaNeedsDraw, true);
        transition_cancel();

        // The card: redrawn while it is the picture, not over its artwork.
        meta_parse("CMDMETA,1,0,NBA Jam|Year=1993");
        metaShowingCard = false;
        u8g2.resetProbe(); oled.resetProbe();
        meta_parseHead((std::string("CMDHEAD,") + SAM).c_str());
        meta_tick();
        okBool("not over the card's artwork", oled.displayCalls == 0, true);
        metaShowingCard = true;
        meta_parseHead("CMDHEAD,");
        u8g2.resetProbe(); oled.resetProbe();
        okBool("the card, while it is up",    meta_tick(), true);
        okBool("drawn again, Now playing",    u8g2.find(CON_HEADER_TEXT) != nullptr && oled.displayCalls > 0, true);
        meta_reset();
    }

    section("CMDHTIMER: Super Attract Mode's countdown, after the caption");
    {
        const char *SAM = "Super Attract Mode";
        transition_cancel();
        meta_parseHead((std::string("CMDHEAD,") + SAM).c_str());
        meta_parseTimer("CMDHTIMER,102");
        meta_parse("CMDMETA,2,0,Sonic|System=Mega Drive|Year=1991");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        const FakeU8g2::Draw *c = u8g2.find(SAM);
        const FakeU8g2::Draw *t = u8g2.find("1:42");
        okBool("the caption, whole",                 c != nullptr, true);
        okBool("and the time left, m:ss",            t != nullptr, true);
        if (c && t) {
            okInt ("in 5x7",                         t->charW, 5);
            okInt ("after the caption, a gap between",
                   t->x, c->x + (int)strlen(SAM) * c->charW + HEAD_TIMER_GAP);
            // Centred on the caption: each glyph sits on its ascent's rows
            // above the baseline (the fakes: 11 for the header, 7 for 5x7).
            okInt ("centred on the caption's height",  t->y, CON_HEADER_Y - (11 - 7) / 2);
        }

        // Counted down by the firmware itself, a second at a time.
        metaNeedsDraw = false; coreBootHolding = false; metaIconRedraw = false;
        metaHeadRedraw = false;
        meta_showConsole();
        u8g2.resetProbe(); oled.resetProbe();
        g_fakeMillis += 400;
        meta_tick();
        okBool("nothing redrawn inside the second",  u8g2.find("1:42") == nullptr && u8g2.find("1:41") == nullptr, true);
        g_fakeMillis += 700;
        u8g2.resetProbe(); oled.resetProbe();
        okBool("the next second redraws it",         meta_tick(), true);
        okBool("one less",                           u8g2.find("1:41") != nullptr, true);
        // Past the end SAM is still busy - downloading its next clip, with
        // the game up - so the count's place says NEXT, flashing at 2Hz.
        metaTimerAt = g_fakeMillis; metaTimerSecs = 2;
        meta_showConsole();
        g_fakeMillis += 1000;
        u8g2.resetProbe(); oled.resetProbe(); meta_tick();
        okBool("0:01 before the end",                u8g2.find("0:01") != nullptr, true);
        g_fakeMillis += 1000;
        u8g2.resetProbe(); oled.resetProbe(); meta_tick();
        const FakeU8g2::Draw *nx = u8g2.find(HEAD_TIMER_DONE);
        okBool("at the end, NEXT, not 0:00",         nx != nullptr && u8g2.find("0:00") == nullptr, true);
        if (nx) {
            okInt ("in the count's place",           nx->x, u8g2.find(SAM)->x + (int)strlen(SAM) * u8g2.find(SAM)->charW + HEAD_TIMER_GAP);
            okInt ("in the count's font",            nx->charW, 5);
        }
        const int capW = u8g2.find(SAM) ? u8g2.find(SAM)->charW : -1;
        g_fakeMillis += 100;
        u8g2.resetProbe(); oled.resetProbe();
        okBool("lit for its first 250ms",            meta_tick() == false && u8g2.draws.empty(), true);
        g_fakeMillis += 150;
        u8g2.resetProbe(); oled.resetProbe();
        okBool("then dark: drawn again",             meta_tick(), true);
        okBool("without it",                         u8g2.find(HEAD_TIMER_DONE) == nullptr && u8g2.find(SAM) != nullptr, true);
        if (u8g2.find(SAM)) okInt("the caption where it was, dark or lit", u8g2.find(SAM)->charW, capW);
        g_fakeMillis += 250;
        u8g2.resetProbe(); oled.resetProbe(); meta_tick();
        okBool("and lit again 250ms on",             u8g2.find(HEAD_TIMER_DONE) != nullptr, true);
        g_fakeMillis += 60000;
        int flips = 0; bool lit = true;
        for (int i = 0; i < 40; i++) {
            g_fakeMillis += 50;
            u8g2.resetProbe(); oled.resetProbe();
            if (meta_tick()) { bool now = u8g2.find(HEAD_TIMER_DONE) != nullptr; if (now != lit) flips++; lit = now; }
        }
        okInt ("flashing on for as long as it takes: 2s is 8 turns", flips, 8);
        meta_parseTimer("CMDHTIMER,90");
        u8g2.resetProbe(); oled.resetProbe(); meta_renderConsole();
        okBool("the next game's count replaces it",  u8g2.find("1:30") != nullptr && u8g2.find(HEAD_TIMER_DONE) == nullptr, true);

        // The caption steps down its fonts to leave the timer room, to 5x7
        // beside the most pips; clear of them either way.
        std::string cmd = "CMDMETA,2,0,3,Game";
        for (int i = 0; i < 12; i++) {
            char seg[32];
            snprintf(seg, sizeof(seg), "|L%02d=V%02d", i, i);
            cmd += seg;
        }
        meta_parse(cmd.c_str());
        meta_parseTimer("CMDHTIMER,59");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        c = u8g2.find(SAM); t = u8g2.find("0:59");
        okBool("eight pips and a timer: both drawn", c && t, true);
        if (c && t) {
            okInt ("the caption in 5x7 now",          c->charW, 5);
            okBool("the timer clear of the pips",
                   t->x + (int)strlen("0:59") * t->charW <= oled.rects[0].x, true);
        }
        meta_parse("CMDMETA,2,0,Sonic|System=Mega Drive");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        c = u8g2.find(SAM);
        okBool("with one page, the room for more",  c && c->charW > 5, true);

        meta_parse("CMDMETA,1,12,NBA Jam|Year=1993|Manufctr=Midway");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderCard();
        okBool("the card has it too",                u8g2.find("0:59") != nullptr, true);

        meta_parseTimer("CMDHTIMER,");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderCard();
        okBool("nothing after the comma: gone",      u8g2.find("0:59") == nullptr && u8g2.find(SAM) != nullptr, true);
        meta_parseTimer("CMDHTIMER,-1");
        okInt ("a negative one too",                 metaTimerSecs, -1);
        meta_parseTimer("CMDHTIMER,999999");
        okInt ("capped at 99:59",                    metaTimerSecs, HEAD_TIMER_MAX);
        okBool("quiet: the boot screen, bar and band stay", boot_quietCommand("CMDHTIMER,5"), true);
        meta_parseTimer("CMDHTIMER,");
        meta_parseHead("CMDHEAD,");
        meta_reset();
        transition_cancel();
    }

    section("CMDMEDIA: the transport band's rows");
    {
        okInt ("the band is the last field row",       MEDIA_BAND_Y, CON_FIELD_Y0 + 3 * CON_FIELD_PITCH);
        okInt ("its glyphs start on row 56",           MEDIA_BAND_TOP, 56);
        okBool("and end on the panel",                 MEDIA_BAND_Y <= DispHeight - 1, true);
        okInt ("the icon keeps rows 0..54",            MEDIA_ICON_ROWS, 55);
        okInt ("one blank row above the band",         MEDIA_BAND_TOP - MEDIA_ICON_ROWS, 1);
        okBool("the bar inside the glyphs' rows",
               MEDIA_BAR_Y >= MEDIA_BAND_TOP && MEDIA_BAR_Y + MEDIA_BAR_H <= MEDIA_BAND_Y + 1, true);
        okInt ("centred on them",                      (MEDIA_BAR_Y - MEDIA_BAND_TOP) * 2 + MEDIA_BAR_H, MEDIA_ICON_H);
        // The last field row left above the band ends above the blank row.
        okBool("the fields stop above it",
               CON_FIELD_Y0 + (CON_FIELD_ROWS - MEDIA_ROWS) * CON_FIELD_PITCH < MEDIA_BAND_TOP - 1, true);
        okBool("quiet: the boot screen, bar and band stay", boot_quietCommand("CMDMEDIA,1,0,0,0,0"), true);
    }

    section("CMDMEDIA: parsed and clamped");
    {
        meta_reset();
        meta_parseMedia("CMDMEDIA,1,1945,6219,8,25");
        okInt ("state",            mediaState, MEDIA_PLAY);
        okInt ("seconds in",       mediaPos, 1945);
        okInt ("seconds long",     mediaTotal, 6219);
        okInt ("chapter",          mediaChapter, 8);
        okInt ("of",               mediaChapters, 25);
        meta_parseMedia("CMDMEDIA,2,-5,999999999,-1,5000");
        okInt ("a negative place is 0",  mediaPos, 0);
        okInt ("a length capped",        mediaTotal, MEDIA_MAX_SECS);
        okInt ("a chapter not below 0",  mediaChapter, 0);
        okInt ("nor above 999",          mediaChapters, MEDIA_MAX_CHAPTER);
        meta_parseMedia("CMDMEDIA,9,1,2,3,4");
        okInt ("an unknown state is none", mediaState, MEDIA_OFF);
        meta_parseMedia("CMDMEDIA,1,1,2,3,4");
        meta_parseMedia("CMDMEDIA,");
        okInt ("nothing after the comma: none", mediaState, MEDIA_OFF);
        meta_parseMedia("CMDMEDIA,4");
        okInt ("the state alone",        mediaState, MEDIA_MENU);
        meta_parseMedia("CMDMEDIA");
        okInt ("no comma at all: none",  mediaState, MEDIA_OFF);

        char t[16];
        media_timeText(65, 6219, t, sizeof(t));   ok("an hour long: h:mm:ss", t, "0:01:05");
        media_timeText(65, 40000, t, sizeof(t));  ok("ten hours: hh:mm:ss",   t, "00:01:05");
        media_timeText(65, 1200, t, sizeof(t));   ok("ten minutes: mm:ss",    t, "01:05");
        media_timeText(65, 300, t, sizeof(t));    ok("under that: m:ss",      t, "1:05");
        media_timeText(3725, 300, t, sizeof(t));  ok("more than its length: still minutes", t, "62:05");
    }

    section("CMDMEDIA: the split layout with a disc's place under it");
    {
        transition_cancel();
        meta_reset();
        meta_parse("CMDMETA,2,10,0,0,Queen on Fire - Live at the Bowl|Year=2004|Studio=EMI/Parlophone"
                   "|Genre=Rock|Director=Gavin Taylor");
        meta_parseMedia("CMDMEDIA,1,1945,6219,8,25");
        metaNeedsDraw = false; coreBootHolding = false;
        okInt ("two field rows left",                  meta_conRows(), 2);
        okInt ("four fields: two pages",               meta_pageCount(), 2);
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        const FakeU8g2::Draw *lab = u8g2.find(MEDIA_LABEL);
        const FakeU8g2::Draw *ch  = u8g2.find("8/25");
        const FakeU8g2::Draw *yr  = u8g2.find("Year");
        okBool("the chapter row",                      lab && ch, true);
        if (lab) okInt("first, on the first field row", lab->y, CON_FIELD_Y0);
        okBool("its label dimmed",                     lab && lab->fg == MEDIA_DIM, true);
        if (yr)  okInt("the fields after it",          yr->y, CON_FIELD_Y0 + CON_FIELD_PITCH);
        // "Chapter" is the widest label, so the values line up after it.
        const FakeU8g2::Draw *yv = u8g2.find("2004");
        if (ch && yv) okInt("one value column, the chapter's included", ch->x, yv->x);
        if (yv) okInt("past the widest label, Director", yv->x, meta_textX() + 8 * 5 + 5);
        okBool("this page's two fields",               u8g2.find("Studio") != nullptr && u8g2.find("Genre") == nullptr, true);
        bool fieldInBand = false;
        for (const auto &d : u8g2.draws)
            if (d.y > MEDIA_BAND_TOP - 2 && d.y != MEDIA_BAND_Y) fieldInBand = true;
        okBool("nothing between the fields and the band", fieldInBand, false);

        const FakeU8g2::Draw *in  = u8g2.find("0:32:25");
        const FakeU8g2::Draw *len = u8g2.find("1:43:39");
        okBool("the time in, and the length",          in && len, true);
        if (in && len) {
            okInt ("on the band's baseline",           in->y, MEDIA_BAND_Y);
            okInt ("in 5x7",                           in->charW, 5);
            okInt ("after the icon and a gap",         in->x, MEDIA_X + MEDIA_ICON_W + MEDIA_GAP);
            okInt ("the length against the right edge", len->x + 7 * 5, DispWidth - CON_TITLE_X);
            okBool("the length dimmed",                len->fg == MEDIA_DIM, true);
        }
        // The bar between them: a track, the part played, and the place.
        const int barX = MEDIA_X + MEDIA_ICON_W + MEDIA_GAP + 35 + MEDIA_GAP;
        const int barW = (DispWidth - CON_TITLE_X - 35) - MEDIA_GAP - barX;
        bool track = false, played = false, knob = false;
        for (const auto &r : oled.rects) {
            if (r.x == barX && r.y == MEDIA_BAR_Y && r.w == barW && r.color == MEDIA_TRACK) track = true;
            if (r.x == barX && r.y == MEDIA_BAR_Y && r.w == barW * 1945 / 6219 && r.color == SSD1322_WHITE) played = true;
            if (r.y == MEDIA_BAND_TOP && r.h == MEDIA_ICON_H && r.w == MEDIA_KNOB_W &&
                r.x == barX + barW * 1945 / 6219 - 1) knob = true;
        }
        okBool("the track, the bar's width",           track, true);
        okBool("the part played, in proportion",       played, true);
        okBool("the place on it",                      knob, true);
        // The play arrow: seven columns, 7, 7, 5, 5, 3, 3, 1 high.
        int cols = 0;
        for (const auto &v : oled.vlines) if (v.x >= MEDIA_X && v.x < MEDIA_X + MEDIA_ICON_W && v.y >= MEDIA_BAND_TOP) cols++;
        okInt ("the play arrow",                       cols, MEDIA_ICON_W);
        okBool("no text past the icon column",         u8g2.maxRight <= DispWidth, true);

        // The seconds count on with no command; the arrow flashes. One page,
        // and a short title: no pip blinks and no marquee to muddle what a
        // tick drew.
        meta_parse("CMDMETA,2,10,0,0,Queen on Fire|Year=2004|Studio=EMI/Parlophone");
        meta_parseMedia("CMDMEDIA,1,1945,6219,8,25");
        metaNeedsDraw = false; mediaRedraw = false; metaHeadRedraw = false;
        meta_showConsole();
        u8g2.resetProbe(); oled.resetProbe();
        g_fakeMillis += 300;
        okBool("nothing to draw inside the half second", meta_tick(), false);
        g_fakeMillis += 250;
        u8g2.resetProbe(); oled.resetProbe();
        okBool("the arrow's dark half: drawn",         meta_tick(), true);
        cols = 0;
        for (const auto &v : oled.vlines) if (v.x >= MEDIA_X && v.x < MEDIA_X + MEDIA_ICON_W && v.y >= MEDIA_BAND_TOP) cols++;
        okInt ("without it",                           cols, 0);
        g_fakeMillis += 500;
        u8g2.resetProbe(); oled.resetProbe();
        okBool("a second on: drawn",                   meta_tick(), true);
        okBool("a second more",                        u8g2.find("0:32:26") != nullptr, true);

        // Paused: nothing moves, nothing is drawn.
        meta_parseMedia("CMDMEDIA,2,1946,6219,8,25");
        okBool("arriving over the layout: drawn",      meta_tick(), true);
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        okInt ("paused: two bars",                     (int)std::count_if(oled.rects.begin(), oled.rects.end(),
               [](const FakeOled::Rect &r) { return r.y == MEDIA_BAND_TOP && r.h == MEDIA_ICON_H && r.w == 2 && r.x < MEDIA_X + MEDIA_ICON_W; }), 2);
        meta_showConsole();
        bool still = true;
        for (int i = 0; i < 20; i++) { g_fakeMillis += 250; if (meta_tick()) still = false; }
        okBool("and five seconds of nothing",          still, true);
        okBool("the same second",                      media_elapsed(g_fakeMillis) == 1946, true);

        // Playing on to the end stops there.
        meta_parseMedia("CMDMEDIA,1,6218,6219,25,25");
        g_fakeMillis += 10000;
        okInt ("never past the length",                media_elapsed(g_fakeMillis), 6219);

        // The menu: no time to tell, so its name; no chapter.
        meta_parseMedia("CMDMEDIA,4,0,6219,0,25");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        okBool("the disc's menu, in words",            u8g2.find("Disc menu") != nullptr, true);
        okBool("no bar",                               std::none_of(oled.rects.begin(), oled.rects.end(),
               [](const FakeOled::Rect &r) { return r.y == MEDIA_BAR_Y && r.h == MEDIA_BAR_H; }), true);
        okBool("no times",                             u8g2.find("1:43:39") == nullptr, true);
        const FakeU8g2::Draw *dash = u8g2.find("-");
        okBool("no chapter",                           dash && dash->y == CON_FIELD_Y0, true);
        okInt ("three lines for an icon",              (int)std::count_if(oled.hlines.begin(), oled.hlines.end(),
               [](const FakeOled::HLine &h) { return h.y >= MEDIA_BAND_TOP && h.w == MEDIA_ICON_W; }), 3);

        // No length known yet: the state in words.
        meta_parseMedia("CMDMEDIA,1,0,0,0,0");
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        okBool("no length: Playing, no bar",           u8g2.find("Playing") != nullptr &&
               std::none_of(oled.rects.begin(), oled.rects.end(),
               [](const FakeOled::Rect &r) { return r.y == MEDIA_BAR_Y && r.h == MEDIA_BAR_H; }), true);

        // The page fade turns only the rows between the chapter and the band.
        meta_parse("CMDMETA,2,10,0,0,Queen on Fire - Live at the Bowl|Year=2004|Studio=EMI/Parlophone"
                   "|Genre=Rock|Director=Gavin Taylor");
        meta_parseMedia("CMDMEDIA,1,100,6219,2,25");
        metaNeedsDraw = false; mediaRedraw = false;
        int x, w, y0, y1;
        meta_consolePagedRect(&x, &w, &y0, &y1);
        okInt ("the page fade starts under the chapter", y0, CON_FIELD_Y0 + CON_FIELD_PITCH - CON_FIELD_ASCENT);
        okInt ("and stops above the band",             y1, MEDIA_BAND_TOP - 1);
        meta_consolePagedRect(&x, &w, &y0, &y1, true);
        okInt ("to the description: the chapter too",  y0, DESC_TOP);
        // ...and the band keeps counting through it.
        meta_showConsole();
        lastPageTick = g_fakeMillis - 10000;
        okBool("a page turns",                         meta_tick() && pf_active(), true);
        g_fakeMillis += 1000;
        u8g2.resetProbe(); oled.resetProbe();
        meta_tick();
        okBool("the band counts during the fade",      u8g2.find("0:01:41") != nullptr, true);
        settlePageFade();

        // The description page: the band stays, the chapter row is its.
        meta_setDesc("A concert.", 10);
        fieldPage = meta_fieldPageCount();
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderConsole();
        okBool("the description",                      u8g2.find("A concert.") != nullptr, true);
        okBool("no chapter row on it",                 u8g2.find(MEDIA_LABEL) == nullptr, true);
        okBool("the band under it",                    u8g2.find("1:43:39") != nullptr, true);
        fieldPage = 0;

        // The icon stops above the band.
        memset(oled.buf, 0xAA, sizeof(oled.buf));
        memset(iconBin, 0x5C, sizeof(iconBin));
        metaHasIcon = true;
        meta_blitIcon();
        okInt ("the icon's last row above the band",   oled.buf[54 * 128 + ICON_X / 2], 0x5C);
        okInt ("and none on the blank row",            oled.buf[55 * 128 + ICON_X / 2], 0xAA);
        okInt ("nor in the band",                      oled.buf[63 * 128 + ICON_X / 2], 0xAA);
        metaHasIcon = false;

        // Waking: a pause is someone at the MiSTer; the seconds are not.
        metaDimmed = true;
        meta_parseMedia("CMDMEDIA,1,200,6219,3,25");
        okBool("the seconds moving: still dim",        metaDimmed, true);
        meta_parseMedia("CMDMEDIA,2,200,6219,3,25");
        okBool("paused: awake",                        metaDimmed, false);

        // Kept across a new CMDMETA - the same disc, found on Wikipedia.
        meta_parse("CMDMETA,2,10,0,0,Queen on Fire|Year=2004");
        okInt ("a new CMDMETA keeps it",               mediaState, MEDIA_PAUSE);
        // The card has no band, whatever is set.
        meta_parse("CMDMETA,1,12,NBA Jam|Year=1993|Manufctr=Midway");
        okBool("not on the arcade card",               meta_mediaOn(), false);
        u8g2.resetProbe(); oled.resetProbe();
        meta_renderCard();
        okBool("nothing of it drawn there",            u8g2.find(MEDIA_LABEL) == nullptr && u8g2.find("Paused") == nullptr, true);
        meta_reset();
        okInt ("CMDMETAOFF forgets it",                mediaState, MEDIA_OFF);
        transition_cancel();
    }

    section("meta_reset returns to plain picture display");
    {
        meta_parse("CMDMETA,2,0,Game|A=1");
        metaHasIcon = true;
        meta_reset();
        okInt ("kind off",      metaKind, MKIND_OFF);
        okInt ("no fields",     metaFieldCount, 0);
        okBool("icon dropped",  metaHasIcon, false);
        okBool("tick inert",    meta_tick(), false);
    }

    // --- The frontends' band and its notice (bandnote.h) --------------------
    auto bandReset = []() {
        transition_cancel();
        bandShown = false; picBand = false;
        noteText[0] = noteDrawn[0] = '\0'; noteLevel = 0; noteLast = 0;
        boActive = false; busyActive = false; bootHolding = false;
        oled.resetProbe(); u8g2.resetProbe();
    };
    auto bandTick = [](unsigned long ms) {
        g_fakeMillis += ms;
        contrast_tick(); transition_tick(); boot_outroTick(); busy_tick(); band_tick();
    };
    // The grey of each drawing of `text`, in order: how the notice faded.
    auto noteGreys = [](const char *text) {
        std::string out;
        for (const auto &d : u8g2.draws)
            if (d.text == text) out += std::to_string(d.fg) + " ";
        return out;
    };
    const char *NOTE = "TTY2OLED+ update available";

    section("band: the notice's rows are inside the band, under a blank row");
    {
        okInt ("the band is the boot screen's ten rows", BOOT_BAND_H, 10);
        okBool("a blank row at least between picture and notice", BNOTE_TOP >= BOOT_BAND_Y + 1, true);
        // u8g2 puts a glyph on the BNOTE_ASC rows above the baseline and its
        // descent on the baseline itself.
        okInt ("its first row is the baseline less the ascent", BNOTE_TOP, BNOTE_Y - BNOTE_ASC);
        okBool("its descent is still on the panel", BNOTE_Y <= BOOT_PANEL_H - 1, true);
        okInt ("centred: the odd blank row goes above it",
               (BNOTE_TOP - BOOT_BAND_Y) - (BOOT_PANEL_H - 1 - BNOTE_Y), 1);
        okBool("half the panel's grey", BNOTE_GREY == 8, true);
        okBool("its longest line fits across the panel in 5x7", BNOTE_COLS * 5 <= BOOT_PANEL_W, true);
        okBool("the fade takes BNOTE_FADE_MS in whole steps", BNOTE_STEP_MS * BNOTE_GREY <= BNOTE_FADE_MS, true);
    }

    section("band: a picture marked band is a frontend's");
    {
        band_parsePicture("CMDCOR,MENU,-2,band");       okBool("CMDCOR,MENU,-2,band", picBand, true);
        band_parsePicture("CMDCOR,misterzine,30,band"); okBool("any effect", picBand, true);
        band_parsePicture("CMDAPD,degauss,5,band");     okBool("CMDAPD too", picBand, true);
        band_parsePicture("CMDCOR,NES,-2");             okBool("a core's is not", picBand, false);
        band_parsePicture("CMDCOR,band,5");             okBool("nor a core called band", picBand, false);
        band_parsePicture("CMDCOR,NES");                okBool("nor one with no effect", picBand, false);
        band_parsePicture("CMDCOR,NES,-2,bandits");     okBool("the word, not a prefix of it", picBand, false);
    }

    section("band: a frontend's picture is cut to 54 rows and composed");
    {
        bandReset();
        memset(logoBin, 0xFF, sizeof(logoBin));
        actPicType = GSC;
        lastEffect = -999;
        band_showPicture(5);
        bool band = true, pic = true;
        for (int i = 0; i < BOOTIMG_BYTES; i++) if (logoBin[i] != 0xFF) pic = false;
        for (int i = BOOTIMG_BYTES; i < BOOT_PANEL_BYTES; i++) if (logoBin[i]) band = false;
        okBool("the 54 rows of picture are kept", pic, true);
        okBool("the ten under them are black", band, true);
        okInt ("it transitions with the effect asked for", lastEffect, 5);
        okBool("from the composed frame", lastSrcAtDraw == metaBin, true);
        okBool("which is the picture", memcmp(metaBin, logoBin, BOOT_PANEL_BYTES) == 0, true);
        okBool("and the panel is now a frontend's", bandShown, true);
        okInt ("no notice, nothing drawn in the band", noteLevel, 0);
        okBool("the srcBin a core picture uses is back", srcBin == logoBin, true);
    }

    section("band: a notice already set comes with the picture");
    {
        bandReset();
        band_noteParse((std::string("CMDNOTE,") + NOTE).c_str());
        okBool("CMDNOTE alone draws nothing", u8g2.draws.empty() && oled.displayCalls == 0, true);
        memset(logoBin, 0x11, sizeof(logoBin));
        actPicType = GSC;
        band_showPicture(5);
        const auto *d = u8g2.find(NOTE);
        okBool("the notice is in the frame", d != nullptr, true);
        if (d) {
            okInt("at half grey",  d->fg, BNOTE_GREY);
            okInt("on its row",    d->y, BNOTE_Y);
            okInt("centred",       d->x, (DispWidth - (int)strlen(NOTE) * d->charW) / 2);
        }
        okInt ("so it is up at full grey", noteLevel, BNOTE_GREY);
        u8g2.resetProbe(); oled.resetProbe();
        for (int i = 0; i < 40; i++) bandTick(50);
        okBool("and there is nothing left to fade in", u8g2.draws.empty(), true);
    }

    section("band: a notice arriving on a frontend's picture fades in there");
    {
        bandReset();
        memset(logoBin, 0x11, sizeof(logoBin));
        actPicType = GSC;
        band_showPicture(0);
        u8g2.resetProbe(); oled.resetProbe();
        const unsigned long t0 = g_fakeMillis;
        band_noteParse((std::string("CMDNOTE,") + NOTE).c_str());
        unsigned long done = 0;
        for (int i = 0; i < 100 && !done; i++) { bandTick(25); if (noteLevel == BNOTE_GREY) done = g_fakeMillis; }
        ok("a grey level at a time, up to half", noteGreys(NOTE), "1 2 3 4 5 6 7 8 ");
        okBool("over about BNOTE_FADE_MS",
               done - t0 >= BNOTE_FADE_MS - BNOTE_STEP_MS && done - t0 <= BNOTE_FADE_MS + 100, true);
        bool inBand = !oled.rects.empty();
        for (const auto &r : oled.rects)
            if (r.y != BOOT_BAND_Y || r.h != BOOT_BAND_H || r.x != 0 || r.w != BOOT_PANEL_W) inBand = false;
        okBool("blacking the band and nothing else", inBand, true);

        u8g2.resetProbe();
        band_noteParse("CMDNOTE,");
        for (int i = 0; i < 100; i++) bandTick(25);
        ok("an empty one fades it back out", noteGreys(NOTE), "7 6 5 4 3 2 1 ");
        okInt("to nothing", noteLevel, 0);

        // A different notice replaces it the same way: out, then in.
        band_noteParse((std::string("CMDNOTE,") + NOTE).c_str());
        for (int i = 0; i < 100; i++) bandTick(25);
        u8g2.resetProbe();
        band_noteParse("CMDNOTE,Something else");
        for (int i = 0; i < 200; i++) bandTick(25);
        ok("the old one goes out", noteGreys(NOTE), "7 6 5 4 3 2 1 ");
        ok("before the new one comes in", noteGreys("Something else"), "1 2 3 4 5 6 7 8 ");
    }

    section("band: the notice waits for the band to be free");
    {
        bandReset();
        memset(logoBin, 0x11, sizeof(logoBin));
        actPicType = GSC;
        band_showPicture(0);
        band_noteParse((std::string("CMDNOTE,") + NOTE).c_str());
        u8g2.resetProbe();
        boActive = true; bootHolding = true;
        boot_outroStart(32, -1);
        for (int i = 0; i < 20; i++) { g_fakeMillis += 25; band_tick(); }
        okBool("not while the boot outro has the band", u8g2.find(NOTE) == nullptr, true);
        boActive = false;
        busyActive = true;
        for (int i = 0; i < 20; i++) { g_fakeMillis += 25; band_tick(); }
        okBool("nor the busy bar", u8g2.find(NOTE) == nullptr, true);
        busyActive = false;
        tfState = TF_OUT;
        for (int i = 0; i < 20; i++) { g_fakeMillis += 25; band_tick(); }
        okBool("nor a transition", u8g2.find(NOTE) == nullptr, true);
        tfState = TF_IDLE;
        for (int i = 0; i < 100; i++) { g_fakeMillis += 25; band_tick(); }
        okInt("then it fades in", noteLevel, BNOTE_GREY);
        bootHolding = false;
    }

    section("band: a core's picture has no band, and the notice waits for a frontend");
    {
        bandReset();
        memset(logoBin, 0x11, sizeof(logoBin));
        actPicType = GSC;
        band_showPicture(0);
        band_noteCommand("CMDCOR,SNES,5");
        okBool("any drawing command takes the panel", bandShown, false);
        band_noteParse((std::string("CMDNOTE,") + NOTE).c_str());
        u8g2.resetProbe(); oled.resetProbe();
        for (int i = 0; i < 100; i++) bandTick(25);
        okBool("so a notice set in a game is not drawn over it", u8g2.find(NOTE) == nullptr, true);
        okBool("and nothing is sent to the panel", oled.displayCalls == 0, true);

        // Back to the menu: it arrives with the picture, whatever the effect.
        band_noteCommand("CMDBOOTPIC,MENU,5");
        boot_showAsCore(5);
        okBool("the menu's picture brings it", u8g2.find(NOTE) != nullptr, true);
        okInt ("at full grey", noteLevel, BNOTE_GREY);
        okBool("and the menu is a frontend", bandShown, true);

        // CMDNOTE itself is quiet: the boot screen, the busy bar and the
        // frontend's picture all stay as they are.
        bootHolding = true;
        boot_noteCommand("CMDNOTE,x");
        okBool("the boot screen still holds", bootHolding, true);
        band_noteCommand("CMDNOTE,x");
        okBool("the frontend's picture is still up", bandShown, true);
        busy_parse("CMDBUSY,1,UPDATING");
        busy_noteCommand("CMDNOTE,x");
        okBool("the busy bar runs on", busyActive, true);
        busy_cancel(); busy_forgetLabel(); bootHolding = false;
    }

    section("band: the power-on screen is the menu's picture, and the outro goes first");
    {
        bandReset();
        band_noteParse((std::string("CMDNOTE,") + NOTE).c_str());
        bootHolding = true;
        lastEffect = -999;
        boot_showAsCore(EFFECT_FADE);
        okInt ("nothing transitions", lastEffect, -999);
        okBool("the menu's picture is up: the power-on screen", bandShown, true);
        okInt ("with the band not yet the notice's", noteLevel, 0);
        boot_outroStart(32, 200);
        bool under = false;
        for (int i = 0; i < 700 && boActive; i++) {
            g_fakeMillis += BOOT_BAR_PX_MS;
            contrast_tick(); transition_tick(); busy_tick();
            band_tick();                       // before the outro's tick, so a draw here is under it
            if (u8g2.find(NOTE)) under = true;
            boot_outroTick();
        }
        okBool("the outro runs to its end", boActive, false);
        okBool("without the notice drawn under it", under, false);
        for (int i = 0; i < 100; i++) bandTick(25);
        ok("then the notice fades in", noteGreys(NOTE), "1 2 3 4 5 6 7 8 ");
        bootHolding = false;
    }

    section("band: a notice arriving while a Fade goes out makes its fade-in");
    {
        bandReset();
        tfFadeMs = 800; tfBlankMs = 1000;
        veil_fadeOver(255, 0);
        memset(logoBin, 0x11, sizeof(logoBin));
        actPicType = GSC;
        boot_showAsCore(EFFECT_FADE);
        okBool("the menu fades", tfState == TF_OUT, true);
        okBool("composed with no notice", u8g2.find(NOTE) == nullptr, true);
        band_noteParse((std::string("CMDNOTE,") + NOTE).c_str());
        u8g2.resetProbe();
        for (int i = 0; i < 400 && tfState != TF_IDLE; i++) bandTick(10);
        okBool("the fade is over", tfState == TF_IDLE, true);
        const auto *d = u8g2.find(NOTE);
        okBool("composed again at the bottom, notice and all", d != nullptr, true);
        if (d) okInt("at full grey, fading in with the picture", d->fg, BNOTE_GREY);
        okInt("so it is up once the picture is", noteLevel, BNOTE_GREY);
        tfFadeMs = TFADE_MS_DEFAULT; tfBlankMs = TBLANK_MS_DEFAULT;
        bandReset();
    }

    section("band: the clock, when no notice is waiting");
    {
        const long T = 1790789640L;        // 2026-09-30 17:34:00, local
        auto clockDraw = [](const char *text) { return u8g2.find(text); };
        bandReset();
        clockFmt[0] = '\0'; clockSet = false;
        memset(logoBin, 0x11, sizeof(logoBin));
        actPicType = GSC;
        band_clockParse("CMDCLOCK,%d/%m/%y|%H:%M");
        band_showPicture(0);
        okBool("no time yet, no clock", clockDraw("30/09/26") == nullptr, true);
        band_setTime(T);
        u8g2.resetProbe();
        for (int i = 0; i < 100; i++) bandTick(25);
        const FakeU8g2::Draw *d = clockDraw("30/09/26");
        const FakeU8g2::Draw *h = clockDraw("17:34");
        okBool("the date and the time, once it has one", d && h, true);
        ok    ("fading in as a notice does", noteGreys("30/09/26"), "1 2 3 4 5 6 7 8 ");
        if (d && h) {
            okInt ("the date at the left",     d->x, BCLOCK_MARGIN);
            okInt ("the time at the right",    h->x, DispWidth - BCLOCK_MARGIN - 5 * h->charW);
            okInt ("on the notice's row",      d->y, BNOTE_Y);
            okInt ("in its grey, half the panel's", u8g2.draws.back().fg, BNOTE_GREY);
        }

        // A new minute is drawn over the old one where it stands.
        u8g2.resetProbe(); oled.resetProbe();
        g_fakeMillis += 60000;
        bandTick(25);
        ok    ("a minute on: drawn again at once, at its grey", noteGreys("17:35"), "8 ");
        okBool("sent to the panel",        oled.displayCalls > 0, true);
        okBool("without going out first",  noteGreys("17:34").empty(), true);

        // An update waiting takes the band: the clock goes, the notice comes.
        u8g2.resetProbe();
        band_noteParse((std::string("CMDNOTE,") + NOTE).c_str());
        for (int i = 0; i < 200; i++) bandTick(25);
        ok    ("a notice: the clock goes out", noteGreys("17:35"), "7 6 5 4 3 2 1 ");
        ok    ("and the notice comes in",      noteGreys(NOTE), "1 2 3 4 5 6 7 8 ");
        u8g2.resetProbe();
        band_noteParse("CMDNOTE,");
        for (int i = 0; i < 200; i++) bandTick(25);
        okBool("dealt with: the clock is back", clockDraw("30/09/26") != nullptr && noteLevel == BNOTE_GREY, true);

        // A picture composed with the band has it from the start.
        band_showPicture(0);
        okBool("composed into a frontend's picture", clockDraw("30/09/26") != nullptr, true);
        okInt ("up at once", noteLevel, BNOTE_GREY);

        // Not over a core's picture, and not under the busy bar.
        band_noteCommand("CMDCOR,SNES,5");
        u8g2.resetProbe(); oled.resetProbe();
        g_fakeMillis += 60000;
        for (int i = 0; i < 40; i++) bandTick(25);
        okBool("a core's picture has no clock", u8g2.draws.empty() && oled.displayCalls == 0, true);
        band_showPicture(0);
        busyActive = true;
        u8g2.resetProbe(); oled.resetProbe();
        g_fakeMillis += 60000;
        for (int i = 0; i < 40; i++) { g_fakeMillis += 25; band_tick(); }
        okBool("nor the busy bar's band", u8g2.draws.empty(), true);
        busyActive = false;

        // One format alone is centred, like a notice.
        band_clockParse("CMDCLOCK,%H:%M");
        u8g2.resetProbe();
        band_showPicture(0);
        const FakeU8g2::Draw *c = u8g2.find("17:37");
        okBool("one format, no bar: one piece", c != nullptr, true);
        if (c) okInt("centred", c->x, (DispWidth - 5 * c->charW) / 2);

        // Nothing after the comma: no clock, and it goes out.
        band_clockParse("CMDCLOCK,%d/%m/%y|%H:%M");
        band_showPicture(0);
        u8g2.resetProbe();
        band_clockParse("CMDCLOCK,");
        for (int i = 0; i < 100; i++) bandTick(25);
        okInt ("CMDCLOCK, turns it off", noteLevel, 0);
        okBool("quiet: CMDCLOCK",   boot_quietCommand("CMDCLOCK,%H"), true);
        okBool("quiet: CMDSETTIME", boot_quietCommand("CMDSETTIME,1"), true);
        clockSet = false;
        bandReset();
    }

    section("band: a feed's headlines take turns with the clock");
    {
        const long T = 1790789640L;        // 2026-09-30 17:34:00, local
        const char *H[3] = { "Alpha headline one", "Bravo headline two", "Charlie headline three" };
        const std::string FEED = std::string(H[0]) + "\n" + H[1] + "\n" + H[2];
        // Which headline a draw opens, by its first letter: a headline coming
        // in at the right edge is drawn as however much of it is on the panel.
        auto opens = [&](const FakeU8g2::Draw &d) {
            for (int i = 0; i < 3; i++)
                if (!d.text.empty() && d.x >= 0 && std::string(H[i]).rfind(d.text, 0) == 0) return i;
            return -1;
        };
        auto headlineDraws = [&]() {
            int n = 0;
            for (const auto &d : u8g2.draws)
                for (int i = 0; i < 3; i++)
                    if (!d.text.empty() && std::string(H[i]).find(d.text) != std::string::npos) { n++; break; }
            return n;
        };
        auto feedOn = [&](const char *line) {
            const long n = band_rssParse((std::string(line) + std::to_string(FEED.size())).c_str());
            band_rssSet(FEED.c_str(), (size_t)n);
            return n;
        };
        auto rssReset = [&]() {
            bandReset();
            rssCount = 0; rssPhase = RSS_CLOCK; rssFirst = 0; rssAdmit = 0; rssClosing = false;
            memset(logoBin, 0x11, sizeof(logoBin));
            actPicType = GSC;
            band_clockParse("CMDCLOCK,%d/%m/%y|%H:%M");
            band_setTime(T);
        };

        rssReset();
        okInt ("CMDRSS says how many bytes follow", (int)feedOn("CMDRSS,30,60,40,"), (int)FEED.size());
        okInt ("a headline a line", rssCount, 3);
        okInt ("the clock's turn, in ms", (int)rssClockMs, 30000);
        okInt ("the ticker's", (int)rssScrollMs, 60000);
        okInt ("40 pixels a second is one every 25ms", (int)rssStepMs, 25);
        band_showPicture(0);
        okBool("a frontend's picture opens with the clock", u8g2.find("30/09/26") != nullptr && noteLevel == BNOTE_GREY, true);

        // The clock has its 30 seconds.
        u8g2.resetProbe();
        for (int i = 0; i < 29900 / 25; i++) bandTick(25);
        okInt ("for 30 seconds nothing scrolls", headlineDraws(), 0);
        okBool("and the clock is up", rssPhase == RSS_CLOCK && noteLevel == BNOTE_GREY, true);
        u8g2.resetProbe();
        for (int i = 0; i < 200 && rssPhase != RSS_SCROLL; i++) bandTick(25);
        okInt ("then the ticker's turn", rssPhase, RSS_SCROLL);
        ok    ("with the clock faded out first", noteGreys("30/09/26"), "7 6 5 4 3 2 1 ");
        okInt ("and no headline before it is gone", headlineDraws(), 0);

        // The ticker: in from the right edge, a pixel a step.
        const unsigned long t0 = g_fakeMillis;
        u8g2.resetProbe(); oled.resetProbe();
        bandTick(25);
        okBool("the first headline comes in at the right edge",
               u8g2.draws.size() == 1 && opens(u8g2.draws[0]) == 0 && u8g2.draws[0].x == DispWidth - 1, true);
        if (!u8g2.draws.empty()) {
            okInt ("on the notice's row", u8g2.draws[0].y, BNOTE_Y);
            okInt ("in its grey", u8g2.draws[0].fg, BNOTE_GREY);
        }
        okBool("sent to the panel", oled.displayCalls > 0, true);
        bool smooth = true;
        for (int i = 2; i <= 200; i++) {
            u8g2.resetProbe();
            bandTick(25);
            if (u8g2.draws.empty() || opens(u8g2.draws[0]) != 0 || u8g2.draws[0].x != DispWidth - i) smooth = false;
        }
        okBool("and moves left a pixel every step", smooth, true);
        okBool("the next follows it, a gap behind", rssAdmit >= 2, true);
        bool dot = false;
        for (const auto &r : oled.rects)
            if (r.w == RSS_DOT && r.h == RSS_DOT && r.y >= BOOT_BAND_Y && r.y + r.h <= BOOT_PANEL_H) dot = true;
        okBool("with a dot between the two, inside the band", dot, true);

        // A late tick makes up a few pixels, never a jump.
        u8g2.resetProbe();
        const int xBefore = rssX;
        bandTick(2000);
        okInt ("a stalled loop moves it RSS_CATCHUP pixels at most", xBefore - rssX, RSS_CATCHUP);

        // Time up: nothing new comes in, and what is on the panel runs out.
        bool clockSeen = false, grew = false, lateDraw = false;
        int lastIn = -1, admitAtClose = -1;
        unsigned long tEnd = 0;
        for (int i = 0; i < 200000 && !tEnd; i++) {
            u8g2.resetProbe(); oled.resetProbe();
            const bool wasClosing = rssClosing;
            const int admitBefore = rssAdmit;
            bandTick(25);
            if (u8g2.find("30/09/26") && rssPhase == RSS_SCROLL) clockSeen = true;
            if (rssClosing && !wasClosing) { admitAtClose = rssAdmit; lastIn = (rssFirst + rssAdmit - 1) % rssCount; }
            if (wasClosing && rssAdmit > admitBefore) grew = true;
            if (wasClosing && headlineDraws() > 0) lateDraw = true;
            if (rssPhase != RSS_SCROLL) tEnd = g_fakeMillis;
        }
        okBool("no clock while it runs", clockSeen, false);
        okBool("after 60 seconds a headline is still on the panel", admitAtClose > 0, true);
        okBool("and is let finish", lateDraw && tEnd - t0 > 60000, true);
        okBool("but none new comes in", grew, false);
        okBool("it ends within the time the longest takes to cross",
               tEnd - t0 <= 60000 + (unsigned long)(DispWidth + 22 * 5 + 2 * RSS_GAP + 22 * 5) * 25 + 2100, true);
        okInt ("with the band empty", headlineDraws(), 0);
        okBool("...and sent so", oled.displayCalls > 0, true);
        okInt ("the next turn starts after the last one shown", rssFirst, (lastIn + 1) % 3);

        // The clock again, faded in, for its whole time. Its first step is
        // drawn in the tick the ticker ended in.
        for (int i = 0; i < 200 && noteLevel < BNOTE_GREY; i++) bandTick(25);
        ok    ("the clock fades back in", noteGreys("30/09/26"), "1 2 3 4 5 6 7 8 ");
        const unsigned long tUp = g_fakeMillis;
        for (int i = 0; i < 4000 && rssPhase == RSS_CLOCK; i++) bandTick(25);
        okBool("and stays its whole 30 seconds from when it is up, whatever the ticker overran",
               g_fakeMillis - tUp >= 30000 && g_fakeMillis - tUp <= 30100, true);
        const int resume = rssFirst;
        for (int i = 0; i < 200 && rssPhase != RSS_SCROLL; i++) bandTick(25);
        u8g2.resetProbe();
        bandTick(25);
        okBool("the second run opens with the next headline",
               u8g2.draws.size() == 1 && opens(u8g2.draws[0]) == resume, true);

        // An update waiting takes the band at once, and keeps it.
        for (int i = 0; i < 80; i++) bandTick(25);
        u8g2.resetProbe(); oled.resetProbe();
        band_noteParse((std::string("CMDNOTE,") + NOTE).c_str());
        bandTick(25);
        okBool("a notice: the ticker is taken off", headlineDraws() == 0 && rssPhase == RSS_CLOCK && oled.displayCalls > 0, true);
        for (int i = 0; i < 100000 / 25; i++) bandTick(25);
        ok    ("and the notice fades in", noteGreys(NOTE), "1 2 3 4 5 6 7 8 ");
        okInt ("no headlines while it waits, however long", headlineDraws(), 0);
        band_noteParse("CMDNOTE,");
        u8g2.resetProbe();
        for (int i = 0; i < 200 && !(noteLevel == BNOTE_GREY && u8g2.find("30/09/26")); i++) bandTick(25);
        okBool("dealt with: the clock is back", u8g2.find("30/09/26") != nullptr && rssPhase == RSS_CLOCK, true);
        for (int i = 0; i < 29000 / 25; i++) bandTick(25);
        okInt ("for its whole time", rssPhase, RSS_CLOCK);
        for (int i = 0; i < 4000 / 25; i++) bandTick(25);
        okInt ("then the headlines again", rssPhase, RSS_SCROLL);

        // Only on a frontend's picture; a new one starts with the clock.
        band_noteCommand("CMDCOR,SNES,5");
        u8g2.resetProbe(); oled.resetProbe();
        for (int i = 0; i < 400; i++) bandTick(25);
        okBool("a core's picture has no ticker", u8g2.draws.empty() && oled.displayCalls == 0, true);
        band_showPicture(0);
        okBool("back at the menu: the clock's turn, from the start", rssPhase == RSS_CLOCK && noteLevel == BNOTE_GREY, true);
        busyActive = true;
        u8g2.resetProbe();
        for (int i = 0; i < 40000 / 25; i++) bandTick(25);
        okInt ("nor under the busy bar", headlineDraws(), 0);
        busyActive = false;

        // New headlines mid-run: off the band, and from the top next turn.
        band_showPicture(0);
        for (int i = 0; i < 4000 && rssPhase != RSS_SCROLL; i++) bandTick(25);
        for (int i = 0; i < 400; i++) bandTick(25);
        feedOn("CMDRSS,30,60,40,");
        u8g2.resetProbe();
        for (int i = 0; i < 4; i++) bandTick(25);
        okBool("a new feed mid-run takes the old one off", headlineDraws() == 0 && rssPhase == RSS_CLOCK && rssFirst == 0, true);

        // No bytes: no feed, and the clock is left alone.
        okInt ("CMDRSS with no bytes", (int)band_rssParse("CMDRSS,30,60,40,0"), 0);
        band_rssSet("", 0);
        band_showPicture(0);
        u8g2.resetProbe();
        for (int i = 0; i < 100000 / 25; i++) bandTick(25);
        okBool("is no feed: the clock stays", rssCount == 0 && noteLevel == BNOTE_GREY
               && noteGreys("30/09/26").find("7") == std::string::npos, true);

        // The clock's turn at 0: the ticker alone.
        feedOn("CMDRSS,0,5,40,");
        u8g2.resetProbe();
        band_showPicture(0);
        okBool("0 seconds of clock: none composed into the picture", u8g2.find("30/09/26") == nullptr && noteLevel == 0, true);
        for (int i = 0; i < 3; i++) bandTick(25);
        okInt ("the headlines at once", rssPhase, RSS_SCROLL);
        u8g2.resetProbe();
        for (int i = 0; i < 60000 / 25; i++) bandTick(25);
        okBool("and never the clock between runs", u8g2.find("30/09/26") == nullptr && headlineDraws() > 0, true);

        // What CMDRSS takes.
        okInt ("not CMDRSS's shape", (int)band_rssParse("CMDRSS,30,60"), -1);
        okInt ("a negative count", (int)band_rssParse("CMDRSS,30,60,40,-5"), -1);
        band_rssParse("CMDRSS,99999,0,1000,1");
        okBool("times and speed kept in bounds", rssClockMs == 3600000UL && rssScrollMs == 1000UL && rssStepMs == 5, true);
        band_rssParse("CMDRSS,-3,60,1,1");
        okBool("...at both ends", rssClockMs == 0 && rssStepMs == 200, true);
        const char raw[] = "one\n\ntw\x01o\r\nthree";
        band_rssSet(raw, sizeof(raw) - 1);
        okInt ("empty lines are no headline", rssCount, 3);
        ok    ("anything unprintable is a space", std::string(rssBuf + rssOff[1], rssLen[1]), "tw o ");
        ok    ("the last line needs no newline", std::string(rssBuf + rssOff[2], rssLen[2]), "three");
        std::string many;
        for (int i = 0; i < RSS_ITEMS_MAX + 20; i++) many += "h" + std::to_string(i) + "\n";
        band_rssSet(many.c_str(), many.size());
        okInt ("no more than RSS_ITEMS_MAX", rssCount, RSS_ITEMS_MAX);
        std::string big(RSS_MAX + 500, 'x');
        band_rssSet(big.c_str(), big.size());
        okBool("no more than RSS_MAX bytes", rssCount == 1 && rssLen[0] == RSS_MAX, true);
        okBool("quiet: CMDRSS", boot_quietCommand("CMDRSS,30,60,40,0"), true);
        bootHolding = true; boot_noteCommand("CMDRSS,30,60,40,0");
        okBool("so the boot screen holds under it", bootHolding, true);
        bootHolding = false;
        band_rssSet("", 0);
        band_rssParse("CMDRSS,30,60,40,0");
        clockSet = false; clockFmt[0] = '\0';
        bandReset();
    }

    section("a panel mounted the other way up: turned on the way out, not in the framebuffer");
    {
        // What the layouts do with the framebuffer, in small: draw, copy the
        // frame out, put an icon's bytes straight into the copy's place, hand
        // the frame back as a picture, show it.
        struct Play {
            static void run(FlippablePanel<LibPanel> &p) {
                static uint8_t shot[8192];
                p.drawPixel(3, 1, 15);                      // text, top left
                p.drawPixel(100, 40, 9);
                memcpy(shot, p.getBuffer(), sizeof(shot));  // metaBin
                memset(p.getBuffer(), 0, 8192);
                p.draw4bppBitmap(shot);                     // a transition's source
                p.getBuffer()[170 / 2 + 10 * 128] = 0x7C;   // the icon: (170,10) and (171,10)
                p.display();
            }
        };
        FlippablePanel<LibPanel> up(256, 64);
        Play::run(up);
        okBool("upright: the text where it was drawn",
               up.seen(3, 1) == 15 && up.seen(100, 40) == 9, true);
        okBool("...and the icon beside it", up.seen(170, 10) == 7 && up.seen(171, 10) == 12, true);

        FlippablePanel<LibPanel> turned(256, 64);
        turned.setFlipped(true);
        okBool("flipped says so", turned.flipped(), true);
        Play::run(turned);
        bool same = true;
        for (int y = 0; y < 64 && same; y++)
            for (int x = 0; x < 256; x++)
                if (turned.seen(255 - x, 63 - y) != up.seen(x, y)) { same = false; break; }
        okBool("turned: the same frame, every pixel a half turn away", same, true);
        okBool("...the icon too, its two pixels in order",
               turned.seen(255 - 170, 53) == 7 && turned.seen(255 - 171, 53) == 12, true);
        okBool("the framebuffer itself stays the right way up",
               (turned.getBuffer()[3 / 2 + 1 * 128] & 0x0F) == 15 &&
               turned.getBuffer()[170 / 2 + 10 * 128] == 0x7C, true);

        // The library's own rotation, which is what the sketch used: the
        // copied-out frame is turned a second time and the icon is not turned
        // at all. This is the bug, kept here so the stand-in is known to show it.
        FlippablePanel<LibPanel> lib(256, 64);
        lib.setRotation(2);
        Play::run(lib);
        okBool("the library's rotation turns a copied-out frame twice",
               lib.seen(3, 1) == 15 && lib.seen(255 - 3, 63 - 1) == 0, true);
        okBool("...and leaves the icon where the bytes were put", lib.seen(170, 10) == 7, true);

        turned.dirty(10, 2, 41, 7);
        turned.display();
        okBool("the dirty window turns with the picture",
               turned.sentX1 == 255 - 41 && turned.sentX2 == 255 - 10 &&
               turned.sentY1 == 63 - 7  && turned.sentY2 == 63 - 2, true);
        up.dirty(10, 2, 41, 7);
        up.display();
        okBool("...and stays put upright", up.sentX1 == 10 && up.sentX2 == 41 &&
               up.sentY1 == 2 && up.sentY2 == 7, true);

        uint8_t odd[3] = { 0x12, 0x34, 0x56 };
        panel_flipBytes(odd, 3);
        okBool("an odd count turns its middle byte too",
               odd[0] == 0x65 && odd[1] == 0x43 && odd[2] == 0x21, true);
        panel_flipBytes(nullptr, 8192);                     // no framebuffer: nothing to do
    }

    printf("\n\033[1mResults:\033[0m %d passed, %d failed\n\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
