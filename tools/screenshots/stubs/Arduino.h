// Arduino.h - the slice of the Arduino core the display code needs on a host.
//
// Enough for Adafruit_GFX, U8g2_for_Adafruit_GFX and the sketch's display
// headers to compile and run on a workstation. Not an emulator: there is no
// serial port, no SPI and no panel - the framebuffer is the output.
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>

typedef uint8_t byte;
typedef bool    boolean;

#define PROGMEM
#define PGM_P const char *
#define pgm_read_byte(addr)    (*(const uint8_t *)(addr))
#define pgm_read_word(addr)    (*(const uint16_t *)(addr))
#define pgm_read_dword(addr)   (*(const uint32_t *)(addr))
#define pgm_read_pointer(addr) ((void *)(*(void *const *)(addr)))
#define memcpy_P               memcpy
#define strlen_P               strlen
#define strncpy_P              strncpy

unsigned long millis(void);
void          delay(unsigned long ms);
inline void   yield(void) { }
long          random(long howsmall, long howbig);

// Templates, not macros: the standard headers this file is compiled beside
// have members called min() and max() of their own.
template <typename T, typename U> inline T min(T a, U b) { return a < (T)b ? a : (T)b; }
template <typename T, typename U> inline T max(T a, U b) { return a > (T)b ? a : (T)b; }

#define DEG_TO_RAD 0.017453292519943295
inline float radians(float deg) { return (float)(deg * DEG_TO_RAD); }
inline float degrees(float rad) { return (float)(rad / DEG_TO_RAD); }

// Adafruit_GFX overloads its text API on a flash-string type the host has no
// use for; the type still has to exist for the declarations to compile.
class __FlashStringHelper;
#ifndef _BV
#define _BV(b) (1UL << (b))
#endif

// Adafruit_GFX's text API takes a String for getTextBounds(); nothing here
// calls it, but the signature has to exist.
class String {
public:
  String() { }
  String(const char *s) : s_(s ? s : "") { }
  unsigned length(void) const { return (unsigned)s_.size(); }
  char charAt(unsigned i) const { return i < s_.size() ? s_[i] : 0; }
  const char *c_str(void) const { return s_.c_str(); }
private:
  std::string s_;
};

class Print {
public:
  virtual ~Print() { }
  virtual size_t write(uint8_t c) = 0;
  virtual size_t write(const uint8_t *buf, size_t n) {
    size_t w = 0;
    while (n--) w += write(*buf++);
    return w;
  }
  size_t print(const char *s)   { return s ? write((const uint8_t *)s, strlen(s)) : 0; }
  size_t print(char c)          { return write((uint8_t)c); }
  size_t print(const String &s) { return print(s.c_str()); }
  size_t print(int v)           { char b[24]; snprintf(b, sizeof b, "%d", v);  return print(b); }
  size_t print(unsigned v)      { char b[24]; snprintf(b, sizeof b, "%u", v);  return print(b); }
  size_t print(long v)          { char b[24]; snprintf(b, sizeof b, "%ld", v); return print(b); }
  size_t println(const char *s) { size_t n = print(s); n += write((uint8_t)'\n'); return n; }
};
