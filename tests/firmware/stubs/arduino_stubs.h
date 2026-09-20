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

// --- Display ----------------------------------------------------------------
// Backed by a real 256x64 4bpp buffer so the geometry in meta_blitIcon can be
// checked for out-of-bounds writes under ASan.
class FakeOled {
public:
    static const int W = 256, H = 64;
    uint8_t buf[W * H / 2];

    FakeOled() { memset(buf, 0, sizeof(buf)); }

    void     clearDisplay(void)                     { memset(buf, 0, sizeof(buf)); }
    void     display(void)                          { displayCalls++; }
    void     setContrast(uint8_t level)             { (void)level; }
    uint8_t *getBuffer(void)                        { return buf; }
    void     draw4bppBitmap(uint8_t *bitmap)        { memcpy(buf, bitmap, sizeof(buf)); }
    void     drawPixel(int16_t x, int16_t y, uint16_t color) { (void)x; (void)y; (void)color; }
    void     drawFastHLine(int16_t x, int16_t y, int16_t w, uint16_t color) {
        (void)x; (void)y; (void)w; (void)color;
    }
    void     fillRect(int16_t x, int16_t y, int16_t w, int16_t h, uint16_t color) {
        (void)x; (void)y; (void)w; (void)h; (void)color;
    }
    int16_t  width(void)  { return W; }
    int16_t  height(void) { return H; }

    int displayCalls = 0;
};

// --- U8g2 text layer --------------------------------------------------------
// getUTF8Width returns a deterministic 6px-per-character width so layout and
// clipping maths can be asserted exactly in tests.
class FakeU8g2 {
public:
    void    setCursor(int16_t x, int16_t y)     { curX = x; curY = y; }
    void    setForegroundColor(uint16_t fg)     { fgColor = fg; }
    void    setBackgroundColor(uint16_t bg)     { bgColor = bg; }
    void    setFont(const uint8_t *f)           { (void)f; }
    int16_t getUTF8Width(const char *str)       { return (int16_t)(strlen(str) * charW); }

    void print(const char *s) {
        lastPrint = s;
        printLog += s;
        printLog += "\n";
        printCalls++;
        // Record the right-most pixel any draw would touch, so tests can prove
        // nothing is drawn outside its column.
        int16_t right = (int16_t)(curX + getUTF8Width(s));
        if (right > maxRight) maxRight = right;
        if (curX < minLeft) minLeft = curX;
    }

    int16_t curX = 0, curY = 0;
    uint16_t fgColor = 0, bgColor = 0;
    int charW = 6;
    const char *lastPrint = "";
    std::string printLog;          // every string drawn since the last reset
    int printCalls = 0;
    int16_t maxRight = -32768;
    int16_t minLeft  = 32767;

    void resetProbe() {
        maxRight = -32768; minLeft = 32767; printCalls = 0; printLog.clear();
    }
};

#endif // ARDUINO_STUBS_H
