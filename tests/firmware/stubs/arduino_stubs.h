/*
  arduino_stubs.h - minimal Arduino/library surface for host type-checking.

  The Arduino toolchain cannot be installed in every environment, so this stub
  set lets the display code in metadisplay.h be compiled and type-checked on a
  normal machine. It is NOT an emulator: it proves the code is well-formed and
  calls real APIs with the right types, not that it renders correctly.

  Every signature below is transcribed from the upstream headers so that a
  mismatch here is a real mismatch on device:

    Adafruit_GFX.h / Adafruit_GrayOLED.h  - adafruit/Adafruit-GFX-Library
        void     clearDisplay(void);
        void     drawPixel(int16_t x, int16_t y, uint16_t color);
        uint8_t *getBuffer(void);
        virtual void drawFastHLine(int16_t x, int16_t y, int16_t w, uint16_t color);
        virtual void drawFastVLine(int16_t x, int16_t y, int16_t h, uint16_t color);
        virtual void fillRect(int16_t x, int16_t y, int16_t w, int16_t h, uint16_t color);

    SSD1322_for_Adafruit_GFX.h            - venice1200/SSD1322_for_Adafruit_GFX
        void display();
        void setContrast(uint8_t level);
        void draw4bppBitmap(uint8_t *bitmap);

    U8g2_for_Adafruit_GFX.h               - olikraus/U8g2_for_Adafruit_GFX
        void    setCursor(int16_t x, int16_t y);
        void    setForegroundColor(uint16_t fg);
        void    setBackgroundColor(uint16_t bg);
        int16_t getUTF8Width(const char *str);
*/

#ifndef ARDUINO_STUBS_H
#define ARDUINO_STUBS_H

#include <string>
#include <vector>

#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdio>

// --- Arduino core -----------------------------------------------------------
extern unsigned long g_fakeMillis;
inline unsigned long millis() { return g_fakeMillis; }
inline long random(long howsmall, long howbig) {
    if (howsmall >= howbig) return howsmall;
    return howsmall + (rand() % (howbig - howsmall));
}

#define SSD1322_BLACK 0
#define SSD1322_WHITE 15

// Flash-resident data is ordinary memory on the host, as it is on the ESP32.
#define PROGMEM
#define memcpy_P memcpy

// --- Display ----------------------------------------------------------------
// Backed by a real 256x64 4bpp buffer so the geometry in meta_blitIcon can be
// checked for out-of-bounds writes under ASan.
class FakeOled {
public:
    static const int W = 256, H = 64;
    uint8_t buf[W * H / 2];

    FakeOled() { memset(buf, 0, sizeof(buf)); }

    void     clearDisplay(void)                     { memset(buf, 0, sizeof(buf)); }
    // Remembers the brightest grey ever sent to the panel since shownPeak was
    // last reset - what someone watching would have seen flash, however
    // briefly.
    void     display(void) {
        displayCalls++;
        for (size_t i = 0; i < sizeof(buf); i++) {
            int hi = buf[i] >> 4, lo = buf[i] & 0x0F;
            if (hi > shownPeak) shownPeak = hi;
            if (lo > shownPeak) shownPeak = lo;
        }
    }
    int      shownPeak = 0;
    void     setContrast(uint8_t level)             { contrastLevel = level; contrastCalls++; }
    uint8_t  contrastLevel = 200;
    int      contrastCalls = 0;
    uint8_t *getBuffer(void)                        { return buf; }
    void     draw4bppBitmap(uint8_t *bitmap)        { memcpy(buf, bitmap, sizeof(buf)); }
    void     drawPixel(int16_t x, int16_t y, uint16_t color) { (void)x; (void)y; (void)color; }
    // Recorded rather than rasterised: the page indicator is a handful of
    // fillRects, and a test wants to know where they landed and which one is
    // lit, not which pixels changed.
    struct Rect { int16_t x, y, w, h; uint16_t color; };
    struct HLine { int16_t x, y, w; uint16_t color; };
    struct VLine { int16_t x, y, h; uint16_t color; };
    std::vector<Rect>  rects;
    std::vector<HLine> hlines;
    std::vector<VLine> vlines;

    void     drawFastHLine(int16_t x, int16_t y, int16_t w, uint16_t color) {
        hlines.push_back({x, y, w, color});
    }
    void     drawFastVLine(int16_t x, int16_t y, int16_t h, uint16_t color) {
        vlines.push_back({x, y, h, color});
    }
    void     fillRect(int16_t x, int16_t y, int16_t w, int16_t h, uint16_t color) {
        rects.push_back({x, y, w, h, color});
    }
    void     resetProbe(void) { rects.clear(); hlines.clear(); vlines.clear(); displayCalls = 0; }
    int16_t  width(void)  { return W; }
    int16_t  height(void) { return H; }

    int displayCalls = 0;
};

// --- U8g2 text layer --------------------------------------------------------
// getUTF8Width returns a deterministic width per character, set by the
// harness's oled_setfont, so layout and clipping maths can be asserted
// exactly in tests.
class FakeU8g2 {
public:
    void    setCursor(int16_t x, int16_t y)     { curX = x; curY = y; }
    void    setForegroundColor(uint16_t fg)     { fgColor = fg; }
    void    setBackgroundColor(uint16_t bg)     { bgColor = bg; }
    void    setFont(const uint8_t *f)           { (void)f; }
    int16_t getUTF8Width(const char *str)       { return (int16_t)(strlen(str) * charW); }
    // Cap height of the font in force, as u8g2 reports it: the harness's
    // oled_setfont sets it beside charW.
    int16_t getFontAscent(void)                 { return fontAscent; }

    void print(const char *s) {
        lastPrint = s;
        printLog += s;
        printLog += "\n";
        printCalls++;
        // Every draw with the x and y it happened at, so a test can assert
        // that two rows share a column rather than just that both appeared.
        draws.push_back({std::string(s), curX, curY, charW, fgColor});
        // Record the right-most pixel any draw would touch, so tests can prove
        // nothing is drawn outside its column.
        int16_t right = (int16_t)(curX + getUTF8Width(s));
        if (right > maxRight) maxRight = right;
        if (curX < minLeft) minLeft = curX;
    }

    int16_t curX = 0, curY = 0;
    uint16_t fgColor = 0, bgColor = 0;
    int charW = 6;
    int fontAscent = 7;
    const char *lastPrint = "";
    std::string printLog;          // every string drawn since the last reset
    int printCalls = 0;
    int16_t maxRight = -32768;
    int16_t minLeft  = 32767;

    // charW is recorded with each draw so a test can tell which font size was
    // in force when a string was drawn - the arcade title drops a size rather
    // than lose its end, and that is otherwise invisible from the outside.
    struct Draw { std::string text; int16_t x, y; int charW; uint16_t fg; };
    std::vector<Draw> draws;

    // x of the first draw whose text starts with `prefix`, or -1.
    int16_t xOf(const char *prefix) const {
        for (const auto &d : draws) {
            if (d.text.rfind(prefix, 0) == 0) return d.x;
        }
        return -1;
    }
    // The whole first draw whose text starts with `prefix`, or null.
    const Draw *find(const char *prefix) const {
        for (const auto &d : draws) {
            if (d.text.rfind(prefix, 0) == 0) return &d;
        }
        return nullptr;
    }

    void resetProbe() {
        maxRight = -32768; minLeft = 32767; printCalls = 0; printLog.clear();
        draws.clear();
    }
};

#endif // ARDUINO_STUBS_H
