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
int           boBarHead   = 0;        // the comet's head, in pixels
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

// ---------------------------------------------------------------------------
// boot_barDraw - one frame of the comet, its head at `head`.
//
// Here rather than in bootscreen.h beside its constants, because it draws:
// bootscreen.h is included before the display object exists, which is what
// lets the tests compile its geometry on its own.
//
// Sixteen rectangles, the tail from the head backwards, each BOOT_BAR_SEG
// wide and one grey darker than the last. The final one is level 0, which is
// what rubs out the pixel the tail has just left behind - so the comet cleans
// up after itself and there is no separate clearing pass.
//
// Everything is clipped to [startX, panel width): the columns left of startX
// belong to the build version.
// ---------------------------------------------------------------------------
// Black the whole bar, from the version's right edge to the panel's. Called
// when a run ends: the comet has drained off the right edge by then, but a
// frame that was interrupted - or one drawn before a jump in the clock - can
// still have pixels on the panel, and a bar that stops has to stop empty.
static inline void boot_barClear(int startX) {
  if (startX < 0) startX = 0;
  if (startX >= BOOT_PANEL_W) return;
  oled.fillRect(startX, BOOT_BAR_Y, BOOT_PANEL_W - startX, BOOT_BAR_H, SSD1322_BLACK);
}

static inline void boot_barDraw(int head, int startX) {
  for (int k = 0; k < BOOT_BAR_LEVELS; k++) {
    int x0 = head - (k + 1) * BOOT_BAR_SEG + 1;
    int w  = BOOT_BAR_SEG;
    if (x0 < startX)  { w -= (startX - x0); x0 = startX; }
    if (w <= 0) continue;
    if (x0 >= BOOT_PANEL_W) continue;
    if (x0 + w > BOOT_PANEL_W) w = BOOT_PANEL_W - x0;
    oled.fillRect(x0, BOOT_BAR_Y, w, BOOT_BAR_H,
                  (uint16_t)(BOOT_BAR_LEVELS - 1 - k));
  }
}

// Commands that change nothing on the panel. Everything else is assumed to.
bool boot_quietCommand(const char *cmd) {
  static const char *const quiet[] = {
    "CMDFADE", "CMDTFADE", "CMDCON", "CMDDIM", "CMDFLIP", "CMDSAVER",
    "CMDSWSAVER",
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

// The daemon has spoken: finish the power-on screen from here. head is where
// the comet had got to, or -1: still in the hold, with no run to finish. It
// carries on to the end of its run - off the right edge, tail and all - which
// leaves the band empty without a clearing pass of its own.
void boot_outroStart(int barX, int head) {
  boBarX     = barX;
  boBarHead  = head;
  boBarDone  = head < 0 || head >= barX + BOOT_BAR_SPAN(barX);
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

  // The bar: one step every BOOT_BAR_PX_MS, exactly as the power-on sweep
  // moves, until the comet has run off the right edge.
  //
  // One step per tick, never a catch-up burst. Catching up on the time the
  // handover took was what made the bar lurch the moment the daemon spoke -
  // and a head that jumps further than the tail's black end leaves the pixels
  // between the two lit, which is where the trails came from.
  if (!boBarDone && now - boBarLast >= BOOT_BAR_PX_MS) {
    boBarLast  = now;
    boBarHead += BOOT_BAR_PX_STEP;
    if (boBarHead >= boBarX + BOOT_BAR_SPAN(boBarX)) {
      boBarDone = true;
      boot_barClear(boBarX);            // ending empty, whatever was mid-frame
    } else {
      boot_barDraw(boBarHead, boBarX);
    }
    drew = true;
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
// picture later - CMDSPIC, the tilt sensor's re-show - shows it too.
// If the power-on screen is still up, that is already what the panel shows:
// there is nothing to transition.
void boot_showAsCore(int effect) {
  boot_compose(logoBin);
  actPicType = GSC;
  if (bootHolding) return;
  oled_transition(effect);
}

#endif  // BOOTOUTRO_H
