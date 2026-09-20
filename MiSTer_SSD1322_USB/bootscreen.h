/*
  bootscreen.h - user-replaceable power-on screen for tty2oled

  Part of the tty2oled game-metadata fork.

  Upstream's start screen is hardcoded: a 120x46 1bpp XBM drawn at x=82 with a
  baked-in sweep animation. This module lets the user replace it with any
  256x64 4bpp (GSC) image, stored in the ESP's own flash so it appears at
  power-up - with the MiSTer switched off, the SD card removed, or the daemon
  never starting.

  ---------------------------------------------------------------------------
  Storage
  ---------------------------------------------------------------------------
  LittleFS rather than NVS/Preferences. The sketch already uses Preferences for
  the d.ti board revision, so NVS was the tempting option, but the default
  ESP32 partition table gives NVS only 20KB total and an 8192-byte blob plus
  per-entry overhead leaves very little headroom - a partition scheme change or
  one more stored setting would start failing writes at runtime. The default
  "ESP32-S3 Dev Module" scheme already carries a ~1.5MB filesystem partition,
  so LittleFS holds an 8KB image with room to spare and degrades cleanly.

  If LittleFS is unavailable for any reason the module reports "no image" and
  the sketch falls back to the built-in logo. A corrupt or wrong-sized file is
  treated the same way, so a failed upload can never brick the boot screen.

  ---------------------------------------------------------------------------
  Wire protocol
  ---------------------------------------------------------------------------
  CMDWRBOOT     followed by exactly 8192 raw bytes; stored and acknowledged
  CMDCLRBOOT    delete the stored image, revert to the built-in logo
  CMDBOOTINF    report whether a custom image is present
*/

#ifndef BOOTSCREEN_H
#define BOOTSCREEN_H

#ifdef ESP32X

#include <FS.h>
#include <LittleFS.h>

#define BOOTIMG_PATH  "/boot.gsc"
#define BOOTIMG_BYTES 8192

bool bootFsReady   = false;
bool bootImgExists = false;

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
    // Only accept an image that is exactly the framebuffer size. A truncated
    // file from an interrupted upload must not be shown.
    bootImgExists = (f.size() == BOOTIMG_BYTES);
    f.close();
  } else {
    bootImgExists = false;
  }
}

// ---------------------------------------------------------------------------
// boot_load - read the stored image into the supplied buffer.
// Returns false if there is no valid image, leaving the buffer untouched.
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
  return true;
}

// ---------------------------------------------------------------------------
// boot_clear - forget the custom image.
// ---------------------------------------------------------------------------
bool boot_clear(void) {
  if (!bootFsReady) return false;
  LittleFS.remove(BOOTIMG_PATH);
  bootImgExists = false;
  return true;
}

// ---------------------------------------------------------------------------
// boot_info - one-line status for CMDBOOTINF / the hardware info screen.
// ---------------------------------------------------------------------------
const char *boot_info(void) {
  if (!bootFsReady)   return "BOOTIMG,nofs";
  if (!bootImgExists) return "BOOTIMG,builtin";
  return "BOOTIMG,custom";
}

#else   // ESP8266 - no filesystem work, built-in logo only

bool bootFsReady   = false;
bool bootImgExists = false;

void        boot_begin(void)                              { }
bool        boot_load(uint8_t *d, size_t c)               { (void)d; (void)c; return false; }
bool        boot_store(const uint8_t *s, size_t l)        { (void)s; (void)l; return false; }
bool        boot_clear(void)                              { return false; }
const char *boot_info(void)                               { return "BOOTIMG,unsupported"; }

#endif  // ESP32X

#endif  // BOOTSCREEN_H
