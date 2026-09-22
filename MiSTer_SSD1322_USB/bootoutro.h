// bootoutro.h - the boot screen as the menu's picture, and how the power-on
// screen gets out of the way when the daemon arrives.
//
// BOOTSCREEN_AS_MENU in the ini makes the daemon send CMDBOOTPIC for the MENU
// core instead of a picture, and the firmware shows the boot image there -
// the stored one, or the built-in logo - with the band below it left black.
//
// At power-on that means the boot screen simply stays: the MiSTer comes up in
// its menu, and the menu's picture is what is already on the panel. So
// nothing transitions. Instead the boot screen finishes on its own terms: the
// sweep bar completes the cycle it is in - filling to the right edge, then
// clearing back - and the version fades out over BOOT_VERFADE_MS, stepping
// its grey from 15 to 0, both starting when the daemon first speaks. The band
// ends empty under the picture.
//
// None of that can happen inside setup(), where the power-on screen runs:
// the daemon's handshake is arriving, and setup() does not read the port - a
// few hundred milliseconds of not reading it overflows the 256-byte receive
// buffer. So the power-on screen hands over the moment the daemon speaks, and
// the rest runs here, ticked from loop(). It waits for the power-on fade-in
// to finish first, if the daemon spoke during it; and it stops drawing the
// instant anything else takes the panel.
//
// bootHolding is what says the boot screen is still what the panel shows. The
// daemon's setup commands leave it alone - contrast, fade times, dimming,
// clock, version query - and so does CMDBOOTPIC itself. Anything else clears
// it, including commands this list has never heard of: a stale "still
// holding" would make the next CMDBOOTPIC skip its transition and leave
// whatever was drawn meanwhile on screen as the menu's picture, while a
// cleared one only costs a transition. So the list is of commands known to
// draw nothing, and everything else is assumed to.
//
// Needs, from the sketch or the tests: oled, u8g2, logoBin, actPicType, GSC,
// DispWidth, DispHeight, millis(), boot_load(), bootlogo_bits, memcpy_P,
// boot_printVersion(), oled_transition(), tfState/TF_IDLE (fadetransition.h).

#ifndef BOOTOUTRO_H
#define BOOTOUTRO_H

#define BOOT_VERFADE_MS  1000        // the version fades out over this long

void boot_printVersion(void);         // the sketch's: font, cursor, BuildVersion

bool          bootHolding = false;    // the power-on screen is still on the panel

bool          boActive    = false;    // an outro is running
bool          boStarted   = false;    // ...and has begun (after any fade-in)
int           boBarX      = 0;        // where the bar starts, past the version
int           boBarPos    = 0;        // next segment to draw
bool          boFilling   = true;     // filling, or clearing back
bool          boBarDone   = true;
unsigned long boBarLast   = 0;
unsigned long boVerStart  = 0;
int           boVerLevel  = 15;
bool          boVerDone   = true;

// The boot image as a full 256x64 picture: the stored image if there is one,
// the built-in logo if not, and the ten rows of band black.
void boot_compose(uint8_t *pic) {
  if (!boot_load(pic, BOOT_PANEL_BYTES))
    memcpy_P(pic, bootlogo_bits, BOOTIMG_BYTES);
  memset(pic + BOOTIMG_BYTES, 0, BOOT_PANEL_BYTES - BOOTIMG_BYTES);
}

// Commands that change nothing on the panel. Everything else is assumed to.
bool boot_quietCommand(const char *cmd) {
  static const char *const quiet[] = {
    "CMDFADE", "CMDTFADE", "CMDCON", "CMDDIM", "CMDFLIP", "CMDSAVER",
    "CMDSETTIME", "CMDHWINF", "CMDMETAOFF", "CMDBOOTPIC", "CMDBOOTINF",
    "CMDTZONE", "CMDNULL",
  };
  size_t n = strlen(cmd);
  if (n >= 6 && strcmp(cmd + n - 6, "QWERTZ") == 0) return true;   // the warm-up line
  for (size_t i = 0; i < sizeof(quiet) / sizeof(quiet[0]); i++) {
    size_t k = strlen(quiet[i]);
    if (strncmp(cmd, quiet[i], k) == 0 && (cmd[k] == '\0' || cmd[k] == ',')) return true;
  }
  return false;
}

// Called for every command before it is handled.
void boot_noteCommand(const char *cmd) {
  if (bootHolding && !boot_quietCommand(cmd)) bootHolding = false;
}

// The daemon has spoken: finish the power-on screen from here. barPos is the
// next segment the sweep would have drawn and filling says which half of the
// cycle it was in, or barPos is -1: still in the hold, no cycle to finish. A
// fill that had just reached the edge still has its clearing half to do; a
// clear that had, has nothing left.
void boot_outroStart(int barX, int barPos, bool filling) {
  boBarX     = barX;
  boBarPos   = barPos;
  boFilling  = filling;
  boBarDone  = barPos < 0;
  if (!boBarDone && barPos >= DispWidth) {
    if (filling) { boFilling = false; boBarPos = barX; }
    else         boBarDone = true;
  }
  boVerDone  = false;
  boVerLevel = 15;
  boStarted  = false;
  boActive   = true;
}

static void bo_start(unsigned long now) {
  boStarted  = true;
  boBarLast  = now;
  boVerStart = now;
}

void boot_outroTick(void) {
  if (!boActive) return;
  if (!bootHolding) { boActive = false; return; }      // something else has the panel
  if (tfState != TF_IDLE) return;                       // the fade-in first
  unsigned long now = millis();
  if (!boStarted) bo_start(now);
  bool drew = false;

  // The bar: one segment every BOOT_BAR_MS, as the sweep itself does, to the
  // edge; then, if it was filling, clear back across; then stop.
  while (!boBarDone && now - boBarLast >= BOOT_BAR_MS) {
    boBarLast += BOOT_BAR_MS;
    oled.fillRect(boBarPos, BOOT_BAR_Y, BOOT_BAR_STEP, BOOT_BAR_H,
                  boFilling ? boBarPos / BOOT_BAR_STEP : SSD1322_BLACK);
    drew = true;
    boBarPos += BOOT_BAR_STEP;
    if (boBarPos >= DispWidth) {
      if (boFilling) { boFilling = false; boBarPos = boBarX; }
      else           boBarDone = true;
    }
  }

  // The version: its grey steps from 15 down to 0 over BOOT_VERFADE_MS.
  if (!boVerDone) {
    unsigned long elapsed = now - boVerStart;
    int level = 15 - (int)(elapsed * 16 / BOOT_VERFADE_MS);
    if (level < 0 || elapsed >= BOOT_VERFADE_MS) level = 0;
    if (level != boVerLevel) {
      boVerLevel = level;
      // Everything left of the bar is the version's; black it and redraw.
      oled.fillRect(0, BOOT_BAND_Y, boBarX, DispHeight - BOOT_BAND_Y, SSD1322_BLACK);
      if (level > 0) {
        u8g2.setForegroundColor(level);
        boot_printVersion();
        u8g2.setForegroundColor(SSD1322_WHITE);
      } else {
        boVerDone = true;
      }
      drew = true;
    }
  }

  if (drew) oled.display();
  if (boBarDone && boVerDone) boActive = false;
}

// CMDBOOTPIC,<core>,<effect> - the boot image is this core's picture. Put
// into logoBin like any core picture, so everything that redraws the core's
// picture later - the screensaver's picture screen, CMDSPIC - shows it too.
// If the power-on screen is still up, that is already what the panel shows:
// there is nothing to transition.
void boot_showAsCore(int effect) {
  boot_compose(logoBin);
  actPicType = GSC;
  if (bootHolding) return;
  oled_transition(effect);
}

#endif  // BOOTOUTRO_H
