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

enum picType { NONE, XBM, GSC, TXT };
int actPicType = NONE;
const uint8_t minEffect = 1, maxEffect = 23;

// Sketch functions the display code calls. Recorded so tests can assert which
// transition source was in effect at draw time.
static int   lastEffect   = -999;
static void *lastSrcAtDraw = nullptr;
static int   lastFontSet  = -1;

void oled_drawlogo(uint8_t e) { lastEffect = e; lastSrcAtDraw = srcBin; }
void oled_setfont(int font)   { lastFontSet = font; u8g2.charW = (font == 0) ? 5 : 8; }

#define ESP32X 1
#include "../../MiSTer_SSD1322_USB/metadisplay.h"

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

    section("arcade card centres a short title and clips a long one");
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

    section("field pager cycles when fields overflow the rows");
    {
        meta_parse("CMDMETA,2,0,Game|A=1|B=2|C=3|D=4|E=5|F=6");
        meta_tick();                             // absorb the first draw
        fieldPage = 0;
        lastPageTick = g_fakeMillis;

        g_fakeMillis += VSCROLL_MS + 1;
        meta_tick();
        // 6 fields at 5 rows per page = 2 pages, so it must have moved.
        okInt("advanced to page 1", fieldPage, 1);

        g_fakeMillis += VSCROLL_MS + 1;
        meta_tick();
        okInt("wrapped back to page 0", fieldPage, 0);
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
