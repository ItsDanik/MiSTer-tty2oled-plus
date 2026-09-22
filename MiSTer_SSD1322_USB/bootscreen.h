/*
  bootscreen.h - user-replaceable power-on screen for tty2oled

  Part of the tty2oled game-metadata fork.

  Upstream's start screen is hardcoded: a 120x46 1bpp XBM drawn at x=82 with a
  baked-in sweep animation. This fork's built-in screen is a full-width 4bpp
  picture instead (bootlogo.h, compiled in), and this module lets the user
  replace it with any 256x54 4bpp (GSC) image of their own, stored in the ESP's
  own flash so it appears at power-up - with the MiSTer switched off, the SD
  card removed, or the daemon never starting.

  Both are the same kind of thing and take the same path through
  oled_showStartScreen(): a stored image is simply preferred to the built-in
  one. Nothing else about the start screen changes either way.

  ---------------------------------------------------------------------------
  Why 256x54 and not 256x64
  ---------------------------------------------------------------------------
  The bottom BOOT_BAND_H rows of the panel belong to the firmware, not to the
  picture. The power-on sweep animates there and the build version is printed
  there when the sweep finishes, and both have to happen whatever image is
  stored - a display that boots into somebody's artwork and never says which
  firmware it is running cannot answer the one question the boot screen exists
  to answer.

  A full-screen image would leave nowhere for either, which is what the first
  version of this module did: storing a picture switched the animation and the
  version off entirely.

  Ten rows is what the two elements actually need, measured off the stock
  screen rather than guessed. The sweep is an 8-row bar on row 55 (rows
  55..62); the version is the 5x7 font on baseline 63 (rows 57..63). Their
  union is rows 55..63, and the tenth row is the blank one that keeps the
  picture from sitting directly on the bar.

  ---------------------------------------------------------------------------
  Storage
  ---------------------------------------------------------------------------
  LittleFS rather than NVS/Preferences. The sketch already uses Preferences for
  the d.ti board revision, so NVS was the tempting option, but the default
  ESP32 partition table gives NVS only 20KB total and a 6912-byte blob plus
  per-entry overhead leaves very little headroom - a partition scheme change or
  one more stored setting would start failing writes at runtime. The default
  "ESP32-S3 Dev Module" scheme already carries a ~1.5MB filesystem partition,
  so LittleFS holds a 7KB image with room to spare and degrades cleanly.

  If LittleFS is unavailable for any reason the module reports "no image" and
  the sketch falls back to the built-in logo. A corrupt or wrong-sized file is
  treated the same way, so a failed upload can never brick the boot screen.

  ---------------------------------------------------------------------------
  Wire protocol
  ---------------------------------------------------------------------------
  CMDWRBOOT     followed by exactly BOOTIMG_BYTES raw bytes; acknowledged
  CMDCLRBOOT    delete the stored image, revert to the built-in logo
  CMDBOOTINF    report whether a custom image is present
*/

#ifndef BOOTSCREEN_H
#define BOOTSCREEN_H

// ---------------------------------------------------------------------------
// Panel geometry
// ---------------------------------------------------------------------------
// Literals rather than the sketch's DispWidth/DispHeight globals because these
// size a buffer and a Serial.readBytes() count, which are needed at compile
// time. This fork is an SSD1322 256x64 throughout; see bitmaps.h.
//
// Each element below is placed off BOOT_BAND_Y so the band cannot be resized
// without the bar and the version moving with it.
#define BOOT_PANEL_W   256
#define BOOT_PANEL_H   64

#define BOOT_BAND_H    10                            // firmware's rows: 54..63
#define BOOT_BAND_Y    (BOOT_PANEL_H - BOOT_BAND_H)  // 54, first reserved row
#define BOOT_GAP_BAND  1                             // blank row above the bar
#define BOOT_BAR_H     8                             // sweep bar height
#define BOOT_BAR_Y     (BOOT_BAND_Y + BOOT_GAP_BAND) // 55, bar rows 55..62
// The sweep is a comet: the head is the brightest pixel column, and behind it
// a tail that steps down one grey level every BOOT_BAR_SEG pixels until it
// reaches black. All sixteen levels are in it, which is the point - a bar
// drawn as whole 16-pixel blocks showed its gradient in four or five visible
// steps, the dark end of it being invisible against the panel.
#define BOOT_BAR_LEVELS 16                           // greys in the tail
#define BOOT_BAR_SEG   4                             // pixels per grey level
#define BOOT_BAR_TAIL  (BOOT_BAR_LEVELS * BOOT_BAR_SEG)   // 64, the whole comet
#define BOOT_VER_H     7                             // 5x7 font cell height
#define BOOT_VER_Y     (BOOT_PANEL_H - 1)            // 63, version baseline

// Where the version sits and how much room the sweep has to leave it. The
// version is drawn with the picture and stays up for the whole animation, so
// the bar can no longer use the full width of the band - it would erase the
// glyphs on its way past. BOOT_VER_X is the left edge, BOOT_VER_GAP the blank
// columns between the text and the first bar segment.
#define BOOT_VER_X     0
#define BOOT_VER_GAP   4

// The bar never starts later than this, whatever the version string measures.
// A pathological string would otherwise leave no bar at all; past this point
// the text wins the columns instead, which only a testing build carrying every
// marker could reach. Generous enough that it never does in practice.
#define BOOT_BAR_X_MAX 96

// How long the picture and version are shown before the bar starts moving.
// Short: the picture is not the point any more - the panel now stays on this
// screen for as long as the MiSTer takes to boot, and the animation is what
// says the display is alive and waiting rather than hung.
#define BOOT_HOLD_MS   1000
// The power-on screen fades in from black to full over this long - palette
// steps and contrast together, like a Fade transition - and the same 0.8s
// every fade defaults to. It must fit inside the hold: the palette steps
// redraw the whole frame from a copy, and would wipe out the sweep's bar if
// they overlapped it (test_meta_layout checks). boot_waitOrCommand ticks it,
// and if the daemon speaks first it finishes in loop(). Fixed rather than
// taken from the ini: nothing from the ini has arrived yet.
#define BOOT_FADE_MS   800

// One frame of the sweep, and how far the head moves in it. Two pixels every
// 2ms: 160 frames across the panel, a run in about a third of a second.
//
// Not one pixel every millisecond, which is the same speed on paper: a frame
// costs about a millisecond of SPI even when only the bar's eight rows are
// sent, so asking for one every 1ms would simply run as fast as the wire
// allows - and then the bar's speed would be whatever the panel and the rest
// of loop() left over, which is exactly the jerkiness this replaced. A step
// of 2 with room to spare in the frame keeps the speed the same everywhere.
//
// BOOT_BAR_SEG is 4, so a step never exceeds the black segment at the end of
// the tail: whatever the head leaves behind is covered by the tail's own
// last level, and the comet cannot smear.
#define BOOT_BAR_PX_MS   2
#define BOOT_BAR_PX_STEP 2

// How far the head travels in one cycle: across the panel, and then the
// length of the tail again so the comet drains off the right edge instead of
// vanishing whole.
#define BOOT_BAR_SPAN(startX) ((BOOT_PANEL_W - (startX)) + BOOT_BAR_TAIL)

// How many fill-then-erase cycles a *re-show* runs - CMDSORG, or the tilt
// sensor flipping the panel while the daemon is connected and silent. The
// power-on sweep does not use this: it repeats until the daemon says something
// (see boot_waitOrCommand), which is the only honest definition of "until the
// MiSTer is ready".
#define BOOT_SWEEP_REPEATS 8

// ---------------------------------------------------------------------------
// boot_barStartX - the first column the sweep may use, given the width the
// version text actually measured.
//
// No rounding any more: a pixel's grey is its distance from the head, not its
// absolute position, so the comet looks the same wherever it starts.
// ---------------------------------------------------------------------------
static inline int boot_barStartX(int verWidth) {
  int x = (verWidth > 0 ? verWidth : 0) + BOOT_VER_GAP;
  if (x < BOOT_BAR_SEG)    x = BOOT_BAR_SEG;
  if (x > BOOT_BAR_X_MAX)  x = BOOT_BAR_X_MAX;
  return x;
}

// A whole framebuffer, which is what draw4bppBitmap() copies whatever the
// picture is - so the rows past the image have to be blacked out by hand.
#define BOOT_PANEL_BYTES (BOOT_PANEL_W * BOOT_PANEL_H / 2)   // 8192

// What a user image is: the panel above the band.
#define BOOTIMG_W      BOOT_PANEL_W
#define BOOTIMG_H      BOOT_BAND_Y                   // 54
#define BOOTIMG_BYTES  (BOOTIMG_W * BOOTIMG_H / 2)   // 6912, 4bpp

// Images stored before the band existed are full-screen. They are still shown
// - cropped to the top BOOTIMG_H rows - rather than discarded, so an update
// does not silently blank a boot screen somebody already installed.
#define BOOTIMG_LEGACY_BYTES BOOT_PANEL_BYTES        // 8192

#ifdef ESP32X

#include <FS.h>
#include <LittleFS.h>

#define BOOTIMG_PATH  "/boot.gsc"

bool bootFsReady   = false;
bool bootImgExists = false;
bool bootImgLegacy = false;      // stored full-screen, predates the band

// ---------------------------------------------------------------------------
// boot_begin - mount the filesystem and note whether a custom image is there.
// Called once from setup(), before the start screen is drawn.
//
// begin(true) formats on first run. That only ever touches the dedicated
// filesystem partition, never the sketch or NVS.
// ---------------------------------------------------------------------------
void boot_begin(void) {
  bootFsReady = LittleFS.begin(true);
  if (!bootFsReady) {
    bootImgExists = false;
    return;
  }
  File f = LittleFS.open(BOOTIMG_PATH, "r");
  if (f) {
    // Only accept one of the two exact sizes. Anything else is a truncated
    // upload and must not be shown: the reader takes a fixed byte count, so a
    // short file would be drawn with whatever happened to follow it.
    size_t sz    = f.size();
    bootImgLegacy = (sz == BOOTIMG_LEGACY_BYTES);
    bootImgExists = (sz == BOOTIMG_BYTES) || bootImgLegacy;
    f.close();
  } else {
    bootImgExists = false;
    bootImgLegacy = false;
  }
}

// ---------------------------------------------------------------------------
// boot_load - read the stored image into the supplied buffer.
// Returns false if there is no valid image, leaving the buffer untouched.
//
// BOOTIMG_BYTES either way: a legacy full-screen image is simply read down to
// the top of the band and the rest of the file ignored, which crops it rather
// than scaling it. Cropping is the honest option - the band was carved out of
// the bottom of the panel, so the rows that go are exactly the rows the
// firmware now draws over.
// ---------------------------------------------------------------------------
bool boot_load(uint8_t *dst, size_t cap) {
  if (!bootFsReady || !bootImgExists || cap < BOOTIMG_BYTES) return false;

  File f = LittleFS.open(BOOTIMG_PATH, "r");
  if (!f) return false;

  size_t got = f.read(dst, BOOTIMG_BYTES);
  f.close();

  if (got != BOOTIMG_BYTES) {
    // Short read means the file is damaged; stop trusting it.
    bootImgExists = false;
    bootImgLegacy = false;
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// boot_store - persist an image already read into a buffer.
//
// Written to a temporary path and renamed, so an interrupted write cannot
// leave a half-image where the good one used to be.
// ---------------------------------------------------------------------------
bool boot_store(const uint8_t *src, size_t len) {
  if (!bootFsReady || len != BOOTIMG_BYTES) return false;

  const char *tmp = BOOTIMG_PATH ".tmp";
  LittleFS.remove(tmp);

  File f = LittleFS.open(tmp, "w");
  if (!f) return false;

  size_t put = f.write(src, len);
  f.close();

  if (put != len) {
    LittleFS.remove(tmp);
    return false;
  }

  LittleFS.remove(BOOTIMG_PATH);
  if (!LittleFS.rename(tmp, BOOTIMG_PATH)) {
    LittleFS.remove(tmp);
    return false;
  }

  bootImgExists = true;
  bootImgLegacy = false;
  return true;
}

// ---------------------------------------------------------------------------
// boot_clear - forget the custom image.
// ---------------------------------------------------------------------------
bool boot_clear(void) {
  if (!bootFsReady) return false;
  LittleFS.remove(BOOTIMG_PATH);
  bootImgExists = false;
  bootImgLegacy = false;
  return true;
}

// ---------------------------------------------------------------------------
// boot_info - one-line status for CMDBOOTINF / the hardware info screen.
// ---------------------------------------------------------------------------
// "legacy" is its own answer rather than "custom" so `tty2oled-bootimg.sh
// status` can say the image is being cropped and a 256x54 one would not be.
const char *boot_info(void) {
  if (!bootFsReady)   return "BOOTIMG,nofs";
  if (!bootImgExists) return "BOOTIMG,builtin";
  if (bootImgLegacy)  return "BOOTIMG,legacy";
  return "BOOTIMG,custom";
}

#else   // ESP8266 - no filesystem work, built-in logo only

bool bootFsReady   = false;
bool bootImgExists = false;
bool bootImgLegacy = false;

void        boot_begin(void)                              { }
bool        boot_load(uint8_t *d, size_t c)               { (void)d; (void)c; return false; }
bool        boot_store(const uint8_t *s, size_t l)        { (void)s; (void)l; return false; }
bool        boot_clear(void)                              { return false; }
const char *boot_info(void)                               { return "BOOTIMG,unsupported"; }

#endif  // ESP32X

#endif  // BOOTSCREEN_H
