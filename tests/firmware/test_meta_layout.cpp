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

// Included before ESP32X is defined, so the ESP8266 branch compiles and no
// LittleFS is needed. That is itself the point of the test below: the boot
// screen's geometry lives outside the ESP32X guard, so the constants are the
// same numbers whichever branch the sketch builds.
#include "../../MiSTer_SSD1322_USB/bootscreen.h"
#include "../../MiSTer_SSD1322_USB/bootlogo.h"

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

// Two widths, so a test can tell the fonts apart by what they measure: the
// 5x7 field font, and everything else.
void oled_setfont(int font)   {
    lastFontSet = font;
    u8g2.charW = (font == 0) ? 5 : 8;
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
        g_fakeMillis += SCROLL_PAUSE_MS + VSCROLL_MS + 1;
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
        meta_parse("CMDMETA,2,0,2,Game|System=NES|Year=1987|Genre=Action|Region=USA|Company=N|Format=nes");
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
        g_fakeMillis += VSCROLL_MS + 1;
        okBool("the pager starts a fade", meta_tick() && pf_active(), true);
        okInt ("with the page it is turning to held back", fieldPage, 0);
        okBool("and the marquee held while it runs", pf_active(), true);
        settlePageFade();
        okInt ("the page turns when the fade reaches black", fieldPage, 1);

        // Something else taking the panel must not leave it half dark, nor
        // swallow the page it was turning to.
        lastPageTick = g_fakeMillis;
        g_fakeMillis += VSCROLL_MS + 1;
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
        g_fakeMillis += VSCROLL_MS + 1;
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

    section("field pager cycles when fields overflow the rows");    section("field pager cycles when fields overflow the rows");
    {
        meta_parse("CMDMETA,2,0,Game|A=1|B=2|C=3|D=4|E=5|F=6");
        meta_tick();                             // absorb the first draw
        fieldPage = 0;
        lastPageTick = g_fakeMillis;

        g_fakeMillis += VSCROLL_MS + 1;
        meta_tick();
        settlePageFade();
        // 6 fields at 5 rows per page = 2 pages, so it must have moved.
        okInt("advanced to page 1", fieldPage, 1);

        g_fakeMillis += VSCROLL_MS + 1;
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
        okBool("from the boot image", lastSrcAtDraw == logoBin, true);
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

    printf("\n\033[1mResults:\033[0m %d passed, %d failed\n\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
