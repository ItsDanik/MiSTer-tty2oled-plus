// fadetransition.h - TRANSITION=-2: fade the old picture out, hold the panel
// black, fade the new one in.
//
// Two things fade together, in step. The contrast, through the veil in
// contrastfade.h - and the picture itself: sixteen palette steps, each taking
// every pixel one grey level darker, floored at 0, one step every sixteenth
// of the fade time. Contrast on its own was not enough. At contrast 0 an
// SSD1322 is dim, not dark, and the picture was still plainly there at the
// bottom of the fade. The fade-in is the same in reverse: the new picture
// starts all 0 and gains a level a step until it is itself again.
//
// The palette steps need the picture being faded as 4bpp, so it is kept in
// fadeBin: the old picture, copied off the framebuffer when the fade out
// starts, then the new one, copied back after it is drawn. Every step is
// computed from fadeBin rather than by darkening the framebuffer in place, so
// anything that scribbles on the framebuffer meanwhile - the card being
// rendered for the next page - is simply overwritten by the next step.
// ESP32 only: an ESP8266 has not got 8KB to spare, and keeps the
// contrast-only fade.
//
// The card is the one caller that draws *before* asking: meta_showCard
// renders the new card into the framebuffer, then transitions. So it calls
// transition_prepare() first, to take the old picture while it is still
// there.
//
// It cannot block. Every other transition is a wipe drawn in a blocking loop
// of about a second; the daemon sends the metadata and icon straight after
// the picture, and seconds of not reading the port would overflow a 256-byte
// receive buffer. So it is a small state machine, started by
// oled_transition() and moved on by transition_tick() from loop().
//
// A request that arrives mid-transition does the obvious thing. While fading
// out or black, the new picture simply replaces the one waiting to be shown
// and the clock carries on; while fading in, it turns around and fades out
// from wherever it had got to. Any other effect cancels it outright.
//
// Needs, from the sketch or the tests: oled, srcBin, actPicType,
// oled_drawlogo(), random(), minEffect/maxEffect, and contrastfade.h.

#ifndef FADETRANSITION_H
#define FADETRANSITION_H

void oled_drawlogo(uint8_t e);          // the sketch's; declared later there
void oled_renderlogo(void);             // draws into the framebuffer, shows nothing
void pf_cancel(void);                   // pagefade.h's, included just after this

#define EFFECT_RANDOM   -1
#define EFFECT_FADE     -2

// The fade-slides: a Fade that also moves the picture a pixel or two every
// palette step, so it drifts off one edge as it darkens and drifts in from
// the other as it comes back. Ten of them, numbered 30..39 - clear of the
// wipes (1..maxEffect) with room to spare, so adding a wipe cannot collide
// with one. Each direction twice: "1" moves a pixel a step, "2" moves two,
// which over TF_STEPS steps is 16 or 32 pixels of travel.
#define EFFECT_SLIDE_FIRST  30
#define EFFECT_SLIDE_LAST   39
#define EFFECT_SLIDE_COUNT  (EFFECT_SLIDE_LAST - EFFECT_SLIDE_FIRST + 1)

#define TFADE_MS_DEFAULT   800
#define TBLANK_MS_DEFAULT  1000
#define TFADE_MS_MAX       4000
#define TF_STEPS           16            // palette steps each way

enum { TF_IDLE, TF_OUT, TF_BLANK, TF_IN };

uint16_t      tfFadeMs     = TFADE_MS_DEFAULT;
uint16_t      tfBlankMs    = TBLANK_MS_DEFAULT;
uint8_t       tfState      = TF_IDLE;

// What composes the new picture when the fade reaches black. NULL copies the
// captured srcBin, which is right for a picture that is already complete. A
// layout built from several pieces sets tfRenderHook just before asking for
// the transition, so it is composed at the bottom of the fade instead - see
// TF_BLANK. Taken into tfRender when the fade starts, exactly as srcBin is,
// because the fade outlives the call that asked for it.
void        (*tfRenderHook)(void) = NULL;
void        (*tfRender)(void)     = NULL;
unsigned long tfPhaseStart = 0;        // when this phase's step 0 was
uint16_t      tfPhaseMs    = TFADE_MS_DEFAULT; // and how long this phase fades
uint8_t       tfStep       = 0;        // palette steps shown in this phase
uint8_t      *tfSrc        = nullptr;  // what to show once the panel is dark
int           tfType       = 0;        // and how to read it (XBM or GSC)
bool          tfPrepared   = false;    // fadeBin already holds the old picture
int8_t        tfSlideDX    = 0;        // pixels per palette step, -1/-2 is leftwards
int8_t        tfSlideDY    = 0;        // and upwards
int           tfSlideBaseX = 0;        // where the outward half starts from
int           tfSlideBaseY = 0;
int           tfSlidePosX  = 0;        // and where the last step drew it
int           tfSlidePosY  = 0;

// Where the picture sits at step `step` of a phase, in pixels.
//
// Going out it starts wherever the phase began - centred, normally - and
// travels a step's worth at a time, so after all TF_STEPS it has moved
// TF_STEPS * speed pixels. Coming in it has to *end* centred, so it starts
// that same distance out on the opposite side and travels back: the same
// direction of motion throughout, which is what makes the two halves read as
// one movement rather than a bounce.
static inline int tf_slideAt(uint8_t step, bool in, int8_t d, int base) {
  return in ? -(int)d * (TF_STEPS - step) : base + (int)d * step;
}

// Every direction a fade-slide can take, in effect order: left, right, up,
// down, each at one pixel a step and then two.
static void tf_slideDirs(uint8_t idx, int8_t *dx, int8_t *dy) {
  static const int8_t sx[4] = { -1,  1,  0,  0 };
  static const int8_t sy[4] = {  0,  0, -1,  1 };
  uint8_t dir   = (uint8_t)(idx >> 1);        // 0..3
  int8_t  speed = (int8_t)((idx & 1) ? 2 : 1);
  *dx = (int8_t)(sx[dir] * speed);
  *dy = (int8_t)(sy[dir] * speed);
}

#ifdef ESP32X
  #define TF_PALETTE 1
  uint8_t fadeBin[8192];               // the 4bpp picture being faded

  // Show fadeBin with every pixel `down` grey levels darker, floored at 0.
  static void tf_showDarkened(uint8_t down) {
    uint8_t *fb = oled.getBuffer();
    if (!fb) return;
    for (int i = 0; i < 8192; i++) {
      uint8_t hi = fadeBin[i] >> 4, lo = fadeBin[i] & 0x0F;
      hi = hi > down ? hi - down : 0;
      lo = lo > down ? lo - down : 0;
      fb[i] = (uint8_t)((hi << 4) | lo);
    }
    oled.display();
  }

  // The same, with the picture offset by (dx, dy) pixels; anything that falls
  // off an edge is gone and what moves in behind it is black.
  //
  // A row is 128 bytes of 4bpp pixels, high nibble to the left, so a vertical
  // offset is whole rows and a horizontal one of two pixels is whole bytes -
  // but an odd dx lands mid-byte, which is exactly why the one-pixel speeds
  // exist. So this works a pixel at a time rather than memmove-ing rows: 16K
  // nibble reads a step, against the 8K byte reads the plain fade does, and
  // sixteen of them over the best part of a second.
  static void tf_showShifted(uint8_t down, int dx, int dy) {
    uint8_t *fb = oled.getBuffer();
    if (!fb) return;
    for (int y = 0; y < 64; y++) {
      uint8_t *drow = fb + y * 128;
      int sy = y - dy;
      if (sy < 0 || sy >= 64) { memset(drow, 0, 128); continue; }
      const uint8_t *srow = fadeBin + sy * 128;
      for (int bx = 0; bx < 128; bx++) {
        int sx = (bx << 1) - dx;
        uint8_t hi = 0, lo = 0;
        if (sx >= 0 && sx < 256)
          hi = (sx & 1) ? (uint8_t)(srow[sx >> 1] & 0x0F) : (uint8_t)(srow[sx >> 1] >> 4);
        int sx2 = sx + 1;
        if (sx2 >= 0 && sx2 < 256)
          lo = (sx2 & 1) ? (uint8_t)(srow[sx2 >> 1] & 0x0F) : (uint8_t)(srow[sx2 >> 1] >> 4);
        hi = hi > down ? (uint8_t)(hi - down) : 0;
        lo = lo > down ? (uint8_t)(lo - down) : 0;
        drow[bx] = (uint8_t)((hi << 4) | lo);
      }
    }
    oled.display();
  }

  // One entry point for both, so a caller never has to know which it wants:
  // with no slide set this is the plain fade, byte for byte as it was.
  static void tf_showStep(uint8_t down, uint8_t step, bool in) {
    if (tfSlideDX == 0 && tfSlideDY == 0) {
      tfSlidePosX = tfSlidePosY = 0;
      tf_showDarkened(down);
      return;
    }
    tfSlidePosX = tf_slideAt(step, in, tfSlideDX, tfSlideBaseX);
    tfSlidePosY = tf_slideAt(step, in, tfSlideDY, tfSlideBaseY);
    tf_showShifted(down, tfSlidePosX, tfSlidePosY);
  }

  static void tf_capture(void) {
    uint8_t *fb = oled.getBuffer();
    if (fb) memcpy(fadeBin, fb, sizeof(fadeBin));
  }
#endif

// How many palette steps are due this far into a phase: one per sixteenth of
// the fade, so the last lands exactly as the contrast reaches its end.
static uint8_t tf_stepsDue(void) {
  if (tfPhaseMs == 0) return TF_STEPS;
  unsigned long elapsed = millis() - tfPhaseStart;
  unsigned long due = elapsed * TF_STEPS / tfPhaseMs;
  return (uint8_t)(due > TF_STEPS ? TF_STEPS : due);
}

// Take the picture on the panel now, before the caller draws over it. Only
// meta_showCard needs this; everything else asks before drawing anything.
void transition_prepare(void) {
#ifdef TF_PALETTE
  if (tfState != TF_IDLE) return;       // mid-transition, fadeBin is already right
  tf_capture();
  tfPrepared = true;
#endif
}

// Fade from what is on the panel to srcBin. srcBin and actPicType are taken
// now, because the draw happens seconds later and the card alternation puts
// both back the moment this returns.
void transition_fade(void) {
  tfSrc  = srcBin;
  tfType = actPicType;
  tfRender     = tfRenderHook;    // taken now, like srcBin, for the same reason
  tfRenderHook = NULL;
  if (tfState == TF_IDLE) {
#ifdef TF_PALETTE
    if (!tfPrepared) tf_capture();
#endif
    tfPrepared   = false;
    tfState      = TF_OUT;
    tfStep       = 0;
    tfSlideBaseX = tfSlideBaseY = 0;    // this half starts from where it is
    tfSlidePosX  = tfSlidePosY  = 0;
    tfPhaseStart = millis();
    tfPhaseMs    = tfFadeMs;
    veil_fadeOver(0, tfFadeMs);
  } else if (tfState == TF_IN) {
    // Turn around from where it is: tfStep steps back towards the picture
    // means 16 - tfStep steps down, and the rest of the way out takes the
    // time those remaining steps would.
    uint8_t down = TF_STEPS - tfStep;
    // Carry on from where the picture actually is rather than from centre, or
    // turning a fade-slide around would jump it to the mirror of its own
    // position before carrying on. Taken from the last step drawn, so it is
    // right even when the new effect slides a different way from the old one.
    tfSlideBaseX = tfSlidePosX - (int)tfSlideDX * down;
    tfSlideBaseY = tfSlidePosY - (int)tfSlideDY * down;
    tfState      = TF_OUT;
    tfStep       = down;
    tfPhaseStart = millis() - (unsigned long)down * tfFadeMs / TF_STEPS;
    tfPhaseMs    = tfFadeMs;
    veil_fadeOver(0, (uint16_t)((unsigned long)(TF_STEPS - down) * tfFadeMs / TF_STEPS));
  }
  // TF_OUT, TF_BLANK: already going dark; the picture waiting is replaced.
}

// Abandon a fade in progress and put the veil back, for an effect that draws
// immediately.
void transition_cancel(void) {
  tfPrepared   = false;
  tfSlideDX    = tfSlideDY = 0;
  tfRender     = NULL;
  tfRenderHook = NULL;
  if (tfState == TF_IDLE) return;
  tfState = TF_IDLE;
  veil_fadeOver(255, 0);
}

void transition_tick(void) {
  uint8_t due;
  switch (tfState) {
    case TF_OUT:
      due = tf_stepsDue();
#ifdef TF_PALETTE
      if (due > tfStep) { tfStep = due; tf_showStep(tfStep, tfStep, false); }
#else
      tfStep = due;
#endif
      if (tfStep < TF_STEPS || !veil_done()) break;
      // Truly black while waiting.
      oled.clearDisplay();
      oled.display();
      tfPhaseStart = millis();
      tfState = TF_BLANK;
      break;

    case TF_BLANK:
      if (millis() - tfPhaseStart < tfBlankMs) break;
      // The new picture is composed here, at the bottom of the fade, and not
      // before: this is the latest moment it can be, and the black phase is
      // dead time the panel is not using for anything else. Anything that was
      // still arriving when the fade began - the console icon, which the
      // daemon sends just after the metadata - has had the whole fade-out and
      // blank to get here, so it makes the fade-in rather than popping in
      // afterwards.
      if (tfRender) {
        tfRender();               // compose it fresh, whatever it is made of now
      } else {
        // Rendered, not drawn: oled_renderlogo() fills the framebuffer and
        // shows nothing. The plain draw (effect 0) also sends the frame to the
        // panel, which put the new picture up undarkened for one transfer's
        // worth of time - at contrast 0, which on this panel is far from dark -
        // and it flashed just before every fade-in.
        uint8_t *keepSrc  = srcBin;
        int      keepType = actPicType;
        srcBin     = tfSrc;
        actPicType = tfType;
        oled_renderlogo();
        srcBin     = keepSrc;
        actPicType = keepType;
      }
#ifdef TF_PALETTE
      // Take what was rendered - XBM or GSC, it is 4bpp in the framebuffer
      // now - and the first frame the panel sees of it is fully dark.
      tf_capture();
      tf_showStep(TF_STEPS, 0, true);    // black either way; placed where it will come in from
#else
      oled.display();                    // no palette steps: the veil is all there is
#endif
      tfStep       = 0;
      tfPhaseStart = millis();
      tfPhaseMs    = tfFadeMs;
      veil_fadeOver(255, tfFadeMs);
      tfState = TF_IN;
      break;

    case TF_IN:
      due = tf_stepsDue();
#ifdef TF_PALETTE
      if (due > tfStep) { tfStep = due; tf_showStep((uint8_t)(TF_STEPS - tfStep), tfStep, true); }
#else
      tfStep = due;
#endif
      if (tfStep >= TF_STEPS && veil_done()) tfState = TF_IDLE;
      break;
  }
}

// Fade in whatever is in the framebuffer now, from black, over ms - palette
// steps and contrast together, exactly as a transition's fade-in does. This
// is the power-on screen's fade-in: it composes its first frame into the
// framebuffer and hands it over here rather than sending it to the panel.
// Sending it first would put it up undarkened at contrast 0, which on this
// panel is plainly visible - the same flash the transition had.
void transition_fadeIn(uint16_t ms) {
  tfPrepared = false;
  // Never slides. This is the power-on screen coming up, not one picture
  // replacing another, and there is nothing for it to slide in from.
  tfSlideDX = tfSlideDY = 0;
  tfSlideBaseX = tfSlideBaseY = tfSlidePosX = tfSlidePosY = 0;
  veil_fadeOver(0, 0);
#ifdef TF_PALETTE
  tf_capture();
  tf_showDarkened(TF_STEPS);            // the first frame the panel gets is black
#else
  oled.display();                       // no palette: the veil is all there is
#endif
  tfStep       = 0;
  tfPhaseStart = millis();
  tfPhaseMs    = ms;
  veil_fadeOver(255, ms);
  tfState      = TF_IN;
}

// Every transition goes through here: -2 fades, 30..39 fades and slides with
// it, -1 (or anything else below 0) picks one of the wipes at random, and
// 0..maxEffect is that effect.
void oled_transition(int e) {
  // A new picture ends any page fade: its steps are computed from a copy of
  // the panel as it was, and left running they would paint the old page's
  // rows back over the new picture.
  pf_cancel();
  if (e >= EFFECT_SLIDE_FIRST && e <= EFFECT_SLIDE_LAST) {
    uint8_t idx = (uint8_t)(e - EFFECT_SLIDE_FIRST);
    // The last two are the random ones, and they pick a direction per
    // transition rather than per step - a picture that changed its mind every
    // sixteenth of a second would be a shake, not a slide. The low bit is the
    // speed, so it survives the dice: 38 stays a one-pixel slide, 39 a two.
    if (idx >= 8) idx = (uint8_t)((random(0, 4) << 1) | (idx & 1));
    tf_slideDirs(idx, &tfSlideDX, &tfSlideDY);
    transition_fade();
    return;
  }
  if (e == EFFECT_FADE) { tfSlideDX = tfSlideDY = 0; transition_fade(); return; }
  transition_cancel();
  if (e < 0) e = random(minEffect, maxEffect + 1);
  oled_drawlogo((uint8_t)e);
}

// Is this effect one that fadetransition.h handles - a Fade, or a fade-slide?
// The callers that have to snapshot the old picture before drawing the new
// one (meta_showCard) ask this rather than testing for EFFECT_FADE.
static inline bool effect_is_fade(int e) {
  return e == EFFECT_FADE || (e >= EFFECT_SLIDE_FIRST && e <= EFFECT_SLIDE_LAST);
}

// Clamp an effect from the wire to something oled_transition understands:
// -2, -1, 0..maxEffect, or one of the fade-slides. Anything below -2 becomes
// a random wipe, anything above maxEffect that is not a fade-slide is pinned
// to maxEffect. One copy, because there are four parsers and they used to
// each have their own.
static inline int effect_clamp(int e) {
  if (e < EFFECT_FADE) return EFFECT_RANDOM;
  if (e >= EFFECT_SLIDE_FIRST && e <= EFFECT_SLIDE_LAST) return e;
  if (e > (int)maxEffect) return (int)maxEffect;
  return e;
}

// CMDTFADE,<fade ms>,<blank ms> - the Fade transition's timings, 0..4000 each.
bool transition_parse(const char *cmd) {
  int fade = 0, blank = 0;
  if (sscanf(cmd, "CMDTFADE,%d,%d", &fade, &blank) != 2) return false;
  if (fade < 0) fade = 0;
  if (fade > TFADE_MS_MAX) fade = TFADE_MS_MAX;
  if (blank < 0) blank = 0;
  if (blank > TFADE_MS_MAX) blank = TFADE_MS_MAX;
  tfFadeMs  = (uint16_t)fade;
  tfBlankMs = (uint16_t)blank;
  return true;
}

#endif  // FADETRANSITION_H
