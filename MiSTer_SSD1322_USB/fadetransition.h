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

#define TFADE_MS_DEFAULT   800
#define TBLANK_MS_DEFAULT  1000
#define TFADE_MS_MAX       4000
#define TF_STEPS           16            // palette steps each way

enum { TF_IDLE, TF_OUT, TF_BLANK, TF_IN };

uint16_t      tfFadeMs     = TFADE_MS_DEFAULT;
uint16_t      tfBlankMs    = TBLANK_MS_DEFAULT;
uint8_t       tfState      = TF_IDLE;
unsigned long tfPhaseStart = 0;        // when this phase's step 0 was
uint16_t      tfPhaseMs    = TFADE_MS_DEFAULT; // and how long this phase fades
uint8_t       tfStep       = 0;        // palette steps shown in this phase
uint8_t      *tfSrc        = nullptr;  // what to show once the panel is dark
int           tfType       = 0;        // and how to read it (XBM or GSC)
bool          tfPrepared   = false;    // fadeBin already holds the old picture

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
  if (tfState == TF_IDLE) {
#ifdef TF_PALETTE
    if (!tfPrepared) tf_capture();
#endif
    tfPrepared   = false;
    tfState      = TF_OUT;
    tfStep       = 0;
    tfPhaseStart = millis();
    tfPhaseMs    = tfFadeMs;
    veil_fadeOver(0, tfFadeMs);
  } else if (tfState == TF_IN) {
    // Turn around from where it is: tfStep steps back towards the picture
    // means 16 - tfStep steps down, and the rest of the way out takes the
    // time those remaining steps would.
    uint8_t down = TF_STEPS - tfStep;
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
  tfPrepared = false;
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
      if (due > tfStep) { tfStep = due; tf_showDarkened(tfStep); }
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
      {
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
      tf_showDarkened(TF_STEPS);
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
      if (due > tfStep) { tfStep = due; tf_showDarkened(TF_STEPS - tfStep); }
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

// Every transition goes through here: -2 fades, -1 (or anything else below 0)
// picks one of the wipes at random, and 0..maxEffect is that effect.
void oled_transition(int e) {
  // A new picture ends any page fade: its steps are computed from a copy of
  // the panel as it was, and left running they would paint the old page's
  // rows back over the new picture.
  pf_cancel();
  if (e == EFFECT_FADE) { transition_fade(); return; }
  transition_cancel();
  if (e < 0) e = random(minEffect, maxEffect + 1);
  oled_drawlogo((uint8_t)e);
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
