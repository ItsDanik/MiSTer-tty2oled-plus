// contrastfade.h - every change to the panel's contrast goes through here, and
// fades rather than jumps.
//
// Contrast used to be set with oled.setContrast() from about ten places - the
// CMDCON handler, idle dimming and waking, the screensaver, and the picture
// paths re-asserting it - and each one jumped. Now they all say where the
// level should go, contrast_fadeTo(), and contrast_tick() in the main loop
// moves the panel there over fadeMs, the ini's CONTRAST_FADE_MS.
//
// A fade always starts from wherever the panel is at that moment, so a new
// target arriving halfway through - waking while it is still dimming - turns
// around smoothly instead of snapping back to where the old fade began. And a
// target it is already heading for is not a new fade: the picture paths
// re-assert the contrast on every draw, and restarting the clock each time
// would stall a fade that is under way.
//
// Two levels are faded independently and multiplied: the base - CONTRAST,
// dimming, the screensaver, everything above - and the veil, 255 unless a
// Fade transition (fadetransition.h) is darkening the panel between two
// pictures. Kept apart so neither has to know about the other: a transition
// on a dimmed panel goes 80 -> 0 -> 80 rather than 80 -> 0 -> 255, and a dim
// that starts mid-transition lands where it should once the veil lifts.
//
// Needs oled.setContrast() and millis() from the sketch (or the test stubs).

#ifndef CONTRASTFADE_H
#define CONTRASTFADE_H

#define FADE_MS_DEFAULT  800     // what the firmware does before CMDFADE arrives
#define FADE_MS_MAX      4000    // the same ceiling as every other fade time

uint16_t      fadeMs     = FADE_MS_DEFAULT;
uint8_t       fadeNow    = 255;  // what the panel is set to right now
uint8_t       fadeFrom   = 255;
uint8_t       fadeTo     = 255;
uint16_t      fadeDur    = 0;
unsigned long fadeStart  = 0;
bool          fadeActive = false;

uint8_t       veilNow    = 255;  // 255 = no veil
uint8_t       veilFrom   = 255;
uint8_t       veilTo     = 255;
uint16_t      veilDur    = 0;
unsigned long veilStart  = 0;
bool          veilActive = false;

int           panelLevel = -1;   // what the panel was last told, -1 = nothing yet

// Base times veil, rounded - and exactly the base whenever the veil is 255.
static void contrast_apply(void) {
  int level = ((int)fadeNow * (int)veilNow + 127) / 255;
  if (level != panelLevel) {
    panelLevel = level;
    oled.setContrast((uint8_t)level);
  }
}

static uint8_t fade_step(uint8_t from, uint8_t to, unsigned long elapsed, uint16_t dur) {
  return (uint8_t)((int)from + ((int)to - (int)from) * (long)elapsed / (long)dur);
}

// Set the level outright. For the one place a jump is the point: blacking the
// panel at power-up, before the boot screen fades it in.
void contrast_jump(uint8_t level) {
  fadeNow = fadeFrom = fadeTo = level;
  fadeActive = false;
  panelLevel = -1;                            // a jump always reaches the panel
  contrast_apply();
}

// Fade to level over ms, from wherever the panel is now.
void contrast_fadeOver(uint8_t level, uint16_t ms) {
  if (level == fadeTo) return;                // already there, or on the way
  if (ms == 0) { contrast_jump(level); return; }
  fadeFrom   = fadeNow;
  fadeTo     = level;
  fadeDur    = ms;
  fadeStart  = millis();
  fadeActive = true;
}

// Fade to level over the configured time.
void contrast_fadeTo(uint8_t level) {
  contrast_fadeOver(level, fadeMs);
}

// Move the veil to level over ms, from wherever it is. 0 is black, 255 is
// no veil at all.
void veil_fadeOver(uint8_t level, uint16_t ms) {
  if (ms == 0 || level == veilNow) {
    veilNow = veilFrom = veilTo = level;
    veilActive = false;
    contrast_apply();
    return;
  }
  veilFrom   = veilNow;
  veilTo     = level;
  veilDur    = ms;
  veilStart  = millis();
  veilActive = true;
}

bool veil_done(void) { return !veilActive; }

// Advance whichever fades are in progress. Cheap when there are none; writes
// to the panel only when the level actually changes, which over a 0.8s fade of
// 175 steps is every five milliseconds or so rather than every call.
void contrast_tick(void) {
  if (fadeActive) {
    unsigned long elapsed = millis() - fadeStart;
    if (elapsed >= fadeDur) { fadeNow = fadeTo; fadeActive = false; }
    else fadeNow = fade_step(fadeFrom, fadeTo, elapsed, fadeDur);
  }
  if (veilActive) {
    unsigned long elapsed = millis() - veilStart;
    if (elapsed >= veilDur) { veilNow = veilTo; veilActive = false; }
    else veilNow = fade_step(veilFrom, veilTo, elapsed, veilDur);
  }
  contrast_apply();
}

// CMDFADE,<ms> - how long a contrast change takes. 0 jumps, as before.
bool contrast_parseFade(const char *cmd) {
  int ms = 0;
  if (sscanf(cmd, "CMDFADE,%d", &ms) != 1) return false;
  if (ms < 0) ms = 0;
  if (ms > FADE_MS_MAX) ms = FADE_MS_MAX;
  fadeMs = (uint16_t)ms;
  return true;
}

#endif  // CONTRASTFADE_H
