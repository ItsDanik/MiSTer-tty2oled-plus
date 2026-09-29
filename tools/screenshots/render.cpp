// render.cpp - draw the display's own screens on a workstation.
//
// The pictures in the README are not mock-ups: they are the firmware's own
// output. This program compiles the sketch's display headers - metadisplay.h,
// bootscreen.h, bootoutro.h, busybar.h - against the real Adafruit GFX and
// U8g2 libraries, hands them a real 256x64 4bpp framebuffer, and writes what
// lands in it to a .pgm per screen. tools/make-screenshots.sh turns those into
// the PNGs under docs/img/.
//
// So a layout change shows up in the documentation by re-running the tool, and
// a screenshot can never drift from what the panel does: the rows, the fonts,
// the paging and the icon blit are the code that runs on the ESP32.
//
// The one thing it cannot show is the panel itself - its contrast, its
// gamma and the way 16 greys look on glass. Everything geometric is exact.
//
//   g++ -std=c++11 -I stubs -I <libs...> -o render render.cpp ...
//
// Build it through tools/make-screenshots.sh, which finds the Arduino
// libraries and does the PNG conversion.

#include <Arduino.h>
#include <Adafruit_GFX.h>
#include <U8g2_for_Adafruit_GFX.h>

#include <string>
#include <vector>

// --- Arduino core -----------------------------------------------------------
// A clock the scenes drive by hand: nothing here waits for real time.
static unsigned long g_millis = 1000;
unsigned long millis(void)          { return g_millis; }
void          delay(unsigned long)  { }
long random(long howsmall, long howbig) {
  if (howsmall >= howbig) return howsmall;
  return howsmall + (rand() % (howbig - howsmall));
}

#define SSD1322_BLACK 0
#define SSD1322_WHITE 15

// ---------------------------------------------------------------------------
// The panel.
//
// Adafruit_SSD1322 is Adafruit_GrayOLED plus an SPI transport; on a host there
// is no transport, so this is the same 4bpp framebuffer with the same pixel
// packing (two pixels per byte, even x in the high nibble) and display() as a
// no-op. draw4bppBitmap at rotation 0 is the memcpy the real one is, which is
// what makes a .gsc file and the framebuffer the same bytes.
// ---------------------------------------------------------------------------
#define PANEL_W 256
#define PANEL_H 64

class HostSSD1322 : public Adafruit_GFX {
public:
  uint8_t  buf[PANEL_W * PANEL_H / 2];
  uint8_t  contrastLevel = 255;

  HostSSD1322() : Adafruit_GFX(PANEL_W, PANEL_H) { memset(buf, 0, sizeof buf); }

  void drawPixel(int16_t x, int16_t y, uint16_t color) override {
    if (x < 0 || x >= PANEL_W || y < 0 || y >= PANEL_H) return;
    uint8_t *p = &buf[x / 2 + y * (PANEL_W / 2)];
    if (x % 2 == 0) *p = (uint8_t)((*p & 0x0F) | ((color & 0xF) << 4));
    else            *p = (uint8_t)((*p & 0xF0) |  (color & 0xF));
  }

  void     clearDisplay(void)              { memset(buf, 0, sizeof buf); }
  void     display(void)                   { }
  void     setContrast(uint8_t level)      { contrastLevel = level; }
  uint8_t *getBuffer(void)                 { return buf; }
  void     draw4bppBitmap(uint8_t *bitmap) { memcpy(buf, bitmap, sizeof buf); }
  void     draw4bppBitmap(const uint8_t *bitmap) { memcpy(buf, bitmap, sizeof buf); }
};

HostSSD1322          oled;
U8G2_FOR_ADAFRUIT_GFX u8g2;

// --- Globals the sketch owns ------------------------------------------------
uint16_t DispWidth = PANEL_W, DispHeight = PANEL_H;
uint16_t DispLineBytes1bpp = 32, DispLineBytes4bpp = 128;
int      logoBytes1bpp = 2048;
int      logoBytes4bpp = 8192;
uint8_t  logoBin[8192];
uint8_t *srcBin = logoBin;
uint8_t  contrast = 255;

enum picType { NONE, XBM, GSC, TXT };
int actPicType = GSC;
const uint8_t minEffect = 1, maxEffect = 23;
int tEffect = -2;

// The version in the boot band, read from the repo's VERSION at startup so a
// screenshot of the boot screen cannot claim a version that was never built.
char BuildVersionStr[32] = "0.0.0";

#include "../../MiSTer_SSD1322_USB/fonts.h"
// Included before ESP32X, as the layout test does: the geometry is wanted,
// the LittleFS storage is not.
#include "../../MiSTer_SSD1322_USB/bootscreen.h"
#include "../../MiSTer_SSD1322_USB/bootlogo.h"

#define ESP32X 1
#include "../../MiSTer_SSD1322_USB/metadisplay.h"
#include "../../MiSTer_SSD1322_USB/bootoutro.h"
#include "../../MiSTer_SSD1322_USB/busybar.h"
#include "../../MiSTer_SSD1322_USB/bandnote.h"

// The sketch's font table, verbatim.
void oled_setfont(int font) {
  switch (font) {
    case 0:  u8g2.setFont(u8g2_font_5x7_mf);             break;
    case 1:  u8g2.setFont(u8g2_font_luBS08_tf);          break;
    case 2:  u8g2.setFont(u8g2_font_luBS10_tf);          break;
    case 3:  u8g2.setFont(u8g2_font_luBS14_tf);          break;
    case 4:  u8g2.setFont(u8g2_font_luBS18_tf);          break;
    case 5:  u8g2.setFont(u8g2_font_luBS24_tf);          break;
    case 6:  u8g2.setFont(u8g2_font_lucasarts_scumm_subtitle_o_tf); break;
    case 7:  u8g2.setFont(u8g2_font_tenfatguys_tr);      break;
    case 8:  u8g2.setFont(u8g2_font_7Segments_26x42_mn); break;
    case 9:  u8g2.setFont(u8g2_font_commodore64_tr);     break;
    case 10: u8g2.setFont(u8g2_font_8bitclassic_tf);     break;
    case 11: u8g2.setFont(u8g2_font_tenthinguys_tr);     break;
    default: u8g2.setFont(u8g2_font_tenfatguys_tr);      break;
  }
}

// The sketch's: the build version in the boot band, 5x7, bottom left.
void boot_printVersion(void) {
  oled_setfont(0);
  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setCursor(BOOT_VER_X, BOOT_VER_Y);
  u8g2.print(BuildVersionStr);
}

// The sketch's picture paths: rendering fills the framebuffer, effect 0 sends
// the frame as well - which on a host is the same thing.
void oled_renderlogo(void) {
  if (srcBin && actPicType == GSC) memcpy(oled.buf, srcBin, sizeof(oled.buf));
}
void oled_drawlogo(uint8_t e) { (void)e; oled_renderlogo(); oled.display(); }

// ---------------------------------------------------------------------------
// .gsc files: three header lines, then hex digits - two per byte, whitespace
// and 0X prefixes ignored. The daemon's `tail -n +4 | xxd -r -p`, in C.
// ---------------------------------------------------------------------------
static bool gsc_load(const char *path, uint8_t *out, size_t want) {
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "render: cannot open %s\n", path); return false; }
  int lines = 0, c;
  while (lines < 3 && (c = fgetc(f)) != EOF) if (c == '\n') lines++;
  size_t n = 0;
  int hi = -1;
  while ((c = fgetc(f)) != EOF && n < want) {
    int v;
    if      (c >= '0' && c <= '9') v = c - '0';
    else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
    else if (c == 'x' || c == 'X') { hi = -1; continue; }   // the 0X prefix
    else continue;
    if (hi < 0) hi = v;
    else { out[n++] = (uint8_t)((hi << 4) | v); hi = -1; }
  }
  fclose(f);
  if (n < want) {
    fprintf(stderr, "render: %s is %zu bytes, wanted %zu\n", path, n, want);
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Output: one 256x64 greyscale PGM per screen, a pixel per byte, 0..15 scaled
// to 0..255. make-screenshots.sh scales them, grids and tints them.
// ---------------------------------------------------------------------------
static std::string outDir = ".";

static void save(const char *name) {
  std::string path = outDir + "/" + name + ".pgm";
  FILE *f = fopen(path.c_str(), "wb");
  if (!f) { fprintf(stderr, "render: cannot write %s\n", path.c_str()); exit(1); }
  fprintf(f, "P5\n%d %d\n255\n", PANEL_W, PANEL_H);
  for (int y = 0; y < PANEL_H; y++)
    for (int x = 0; x < PANEL_W; x++) {
      uint8_t b = oled.buf[x / 2 + y * (PANEL_W / 2)];
      uint8_t g = (x % 2 == 0) ? (b >> 4) : (b & 0x0F);
      fputc(g * 17, f);
    }
  fclose(f);
  printf("  %s\n", path.c_str());
}

// ---------------------------------------------------------------------------
// The scenes.
// ---------------------------------------------------------------------------
static std::string repoRoot = "..";

static void scene_console(const char *name, const char *cmd, const char *icon,
                          bool flipped = false) {
  meta_reset();
  metaFlipped = flipped;
  meta_parse(cmd);
  metaHasIcon = icon && gsc_load((repoRoot + "/" + icon).c_str(), iconBin, ICON_BYTES);
  meta_renderConsole();
  save(name);
}

// The description page, scrolled a little way in: what a game Scrape metadata
// found a description for shows after its fields.
static void scene_description(const char *name, const char *cmd, const char *icon,
                              const char *desc, int scroll) {
  meta_reset();
  meta_parse(cmd);
  metaHasIcon = icon && gsc_load((repoRoot + "/" + icon).c_str(), iconBin, ICON_BYTES);
  meta_setDesc(desc, strlen(desc));
  fieldPage   = meta_fieldPageCount();
  descScrollY = scroll;
  meta_renderConsole();
  save(name);
}

static void scene_card(const char *name, const char *cmd, int page,
                       const char *desc = nullptr, int scroll = 0) {
  meta_reset();
  meta_parse(cmd);
  if (desc) meta_setDesc(desc, strlen(desc));
  cardPage    = page;
  descScrollY = scroll;
  meta_renderCard();
  save(name);
}

// An arcade set's wheel logo, cut out of the pack the way the daemon does:
// its frame in pics/arcade/wheels.idx, 8192 bytes at frame * 8192 of
// wheels.bin.
static void scene_wheel(const char *name, const char *set) {
  std::string idx = repoRoot + "/pics/arcade/wheels.idx";
  FILE *f = fopen(idx.c_str(), "r");
  if (!f) { fprintf(stderr, "render: cannot open %s\n", idx.c_str()); return; }
  char line[256];
  long frame = -1;
  size_t len = strlen(set);
  while (fgets(line, sizeof line, f)) {
    if (!strncmp(line, set, len) && line[len] == '|') { frame = atol(line + len + 1); break; }
  }
  fclose(f);
  if (frame < 0) { fprintf(stderr, "render: %s is not in %s\n", set, idx.c_str()); return; }
  std::string bin = repoRoot + "/pics/arcade/wheels.bin";
  f = fopen(bin.c_str(), "rb");
  if (!f) { fprintf(stderr, "render: cannot open %s\n", bin.c_str()); return; }
  bool ok = fseek(f, frame * (long)sizeof logoBin, SEEK_SET) == 0 &&
            fread(logoBin, 1, sizeof logoBin, f) == sizeof logoBin;
  fclose(f);
  if (!ok) { fprintf(stderr, "render: frame %ld is not in %s\n", frame, bin.c_str()); return; }
  srcBin = logoBin;
  actPicType = GSC;
  oled_drawlogo(0);
  save(name);
}

static void scene_picture(const char *name, const char *gsc) {
  if (!gsc_load((repoRoot + "/" + gsc).c_str(), logoBin, sizeof logoBin)) return;
  srcBin = logoBin;
  actPicType = GSC;
  oled_drawlogo(0);
  save(name);
}

// The power-on screen: picture and version in the first frame, the comet
// partway through its run - what the panel shows while the MiSTer boots.
static void scene_boot(const char *name, const char *gsc, int head) {
  uint8_t pic[BOOT_PANEL_BYTES];
  if (gsc) {
    if (!gsc_load((repoRoot + "/" + gsc).c_str(), pic, BOOTIMG_BYTES)) return;
  } else {
    memcpy(pic, bootlogo_bits, BOOTIMG_BYTES);
  }
  memset(pic + BOOTIMG_BYTES, 0, BOOT_PANEL_BYTES - BOOTIMG_BYTES);
  oled.draw4bppBitmap(pic);
  boot_printVersion();
  if (head >= 0) {
    oled_setfont(0);
    boot_barDraw(head, boot_barStartX(u8g2.getUTF8Width(BuildVersionStr)));
  }
  save(name);
}

// CMDBUSY with a label: the message takes the panel, the comet runs in the band.
// With a status line under it, when `line` is not empty.
static void scene_busy(const char *name, const char *label, const char *line, int head) {
  oled.clearDisplay();
  busy_forgetLabel();
  snprintf(busyLine, sizeof(busyLine), "%s", line);
  busy_showLabel(label, BUSY_NO_EFFECT);
  if (head >= 0) boot_barDraw(head, 0);
  save(name);
}

// A frontend's picture - the menu's, the boot image - with the notice the
// band carries when a newer tty2oled+ is out.
static void scene_menu(const char *name, const char *note) {
  boot_compose(logoBin);
  snprintf(noteText, sizeof(noteText), "%s", note);
  band_render();
  save(name);
}

int main(int argc, char **argv) {
  if (argc > 1) outDir  = argv[1];
  if (argc > 2) repoRoot = argv[2];

  FILE *v = fopen((repoRoot + "/VERSION").c_str(), "r");
  if (v) { if (fscanf(v, "%31s", BuildVersionStr) != 1) BuildVersionStr[0] = 0; fclose(v); }

  u8g2.begin(oled);
  u8g2.setFontMode(0);
  u8g2.setForegroundColor(SSD1322_WHITE);
  u8g2.setBackgroundColor(SSD1322_BLACK);

  printf("rendering into %s\n", outDir.c_str());

  // Console split layout. Four field rows, the first two pinned; the icon is
  // the one the daemon would send for this core.
  scene_console("console-nes",
                "CMDMETA,2,0,1,The Legend of Zelda"
                "|System=Nintendo NES|Year=1987|Company=Nintendo|Region=USA",
                "pics/icon/NES.gsc");

  // The same layout on the other side - what FLIP_MINUTES swaps to.
  scene_console("console-flipped",
                "CMDMETA,2,0,1,Sonic The Hedgehog"
                "|System=Mega Drive|Year=1992|Company=Sega|Genre=Action",
                "pics/icon/MegaDrive.gsc", true);

  // Five fields into four rows: the last two take turns under the pinned pair,
  // and the pips by the header count the pages. Caught mid-marquee, since the
  // title is wider than the column.
  scene_console("console-paging",
                "CMDMETA,2,0,1,Castlevania Aria of Sorrow"
                "|System=Game Boy Advance|Year=2003|Company=Konami|Region=USA|Format=gba",
                "pics/icon/GBA.gsc");

  // A ScummVM game's first page: the CMDMETA the daemon sent for Fate of
  // Atlantis on the MiSTer, and the icon it converted from ScummVM's icon pack
  // (cache/scummvm/icons/scumm-atlantis.gsc there).
  scene_console("console-scummvm",
                "CMDMETA,2,12,1,0,Indiana Jones and the Fate of Atlantis"
                "|System=ScummVM|Year=1992  LucasArts|Platform=DOS|Engine=SCUMM"
                "|Language=English|Series=Indiana Jones",
                "tools/screenshots/scumm-atlantis.gsc");

  // The description page, three pixels into its scroll.
  scene_description("console-description",
                    "CMDMETA,2,0,1,Sonic The Hedgehog"
                    "|System=Mega Drive|Year=1991|Players=1|Rating=8/10",
                    "pics/icon/MegaDrive.gsc",
                    "Sonic the Hedgehog is a platform game in which the player "
                    "controls Sonic as he races through six zones to stop Doctor "
                    "Robotnik, who has imprisoned the animals of South Island in "
                    "robots. Collect rings, find the Chaos Emeralds and rescue "
                    "your friends.", 3);

  // Arcade card, as the shipped lists lay it out for a set an imported
  // gamelist describes: the grid's first page, the wide fields under a repeat
  // of the pinned row, and the description. 2 pinned, 11 paired two to a row
  // - two grid pages - then the wide page, then the description.
  const char *nbajam =
      "CMDMETA,1,12,2,11,NBA Jam (rev 3.01 04/07/93)"
      "|Year=1993|Manufctr=Midway|Players=4|Rating=8/10|Developr=Midway"
      "|Region=World|Orient=Horizontal|Core=blahmid_tunit|Author=rejectedcoins"
      "|Set=nbajam|MAME=0289"
      "|Controls=8-way|Buttons=Turbo/Shoot / Block/Pass / Steal";
  const char *nbajamDesc =
      "NBA Jam is a two-on-two basketball game with exaggerated dunks, "
      "real NBA players and a ball that catches fire after three baskets in a "
      "row. Up to four players can join in, two on each side.";
  scene_card("arcade-card-1", nbajam, 0);
  scene_card("arcade-card-2", nbajam, 2);
  scene_card("arcade-description", nbajam, 3, nbajamDesc, 3);

  // The wheel logo the card alternates with, and a computer core's banner -
  // which is the whole of what a computer core shows.
  scene_wheel("arcade-art", "nbajam");
  scene_picture("computer-art", "pics/banner/C64.gsc");

  // Power-on: the built-in logo, the version, and the comet mid-run.
  scene_boot("boot", nullptr, 150);

  // The menu, when updates are waiting: the notice in the band under it.
  scene_menu("menu-update", "TTY2OLED+ & System Update Available");

  // update_all: the message owns the panel, the bar says it is working.
  scene_busy("busy", "Updating System ...", "_Arcade/cores/Arcade-NamcoS2_SG_20260927.rbf", 150);
  scene_busy("busy-done", "Update Complete", "", -1);

  printf("done\n");
  return 0;
}
