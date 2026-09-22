// pagefade.h - when a metadata page turns, fade only the rows that change.
//
// A page turn is not a new picture. The title, the rule and the pinned fields
// are the same before and after, and fading the whole panel for them made the
// screen blink every few seconds while saying nothing: what moved was three
// or four rows of text near the bottom. So only the paged rows fade - out to
// black, redrawn, back in - and everything above them stays lit and still.
//
// The same sixteen palette steps as fadetransition.h, over the same clock,
// but applied to a rectangle instead of the frame; there is no contrast veil,
// because contrast is a property of the whole panel and dimming it would fade
// exactly what has to stay put. It borrows fadetransition.h's fadeBin for the
// copy it steps from: a page fade and a picture fade cannot run at once - the
// card is either turning a page or being transitioned to - and pf_start()
// gives way to any picture fade in progress rather than share it.
//
// The rectangle is bytes, not pixels: the framebuffer is 4bpp, so a pixel
// column is half a byte and only an even x is a byte boundary. Both console
// layouts put the text column at an even x, which is what makes the console's
// icon panel safe: it sits outside the rectangle and never fades.
//
// Not a blocking loop, for the same reason nothing else here is: the port has
// to be read throughout. pf_tick() from loop() moves it on.
//
// ESP32 only, like the picture fade. Without fadeBin there is nothing to step
// from, and a page simply changes.
//
// Needs, from the sketch or the tests: oled, millis(), DispWidth/DispHeight,
// and fadetransition.h (fadeBin, tfState, TF_IDLE, TF_STEPS, tfFadeMs).

#ifndef PAGEFADE_H
#define PAGEFADE_H

enum { PF_IDLE, PF_OUT, PF_IN };

uint8_t       pfState   = PF_IDLE;
uint8_t       pfStep    = 0;
int           pfX0      = 0, pfX1 = 0;   // byte columns, [x0, x1)
int           pfY0      = 0, pfY1 = 0;   // rows, [y0, y1)
unsigned long pfStart   = 0;
uint16_t      pfPhaseMs = 0;
void        (*pfRedraw)(void) = nullptr; // draws the new page into the framebuffer

// Half the picture fade, and never more than PF_FADE_MAX_MS. The console
// pager turns every VSCROLL_MS - 2.5s - and a fade that does not finish well
// inside that would still be running when the next page is due. 0 keeps the
// setting's meaning: TRANSITION_FADE_MS=0 means do not fade.
#define PF_FADE_MAX_MS 400

static uint16_t pf_fadeMs(void) {
  uint16_t ms = (uint16_t)(tfFadeMs / 2);
  return ms > PF_FADE_MAX_MS ? PF_FADE_MAX_MS : ms;
}

bool pf_active(void) { return pfState != PF_IDLE; }

#ifdef TF_PALETTE

// The rectangle from fadeBin, every pixel `down` levels darker, floored at 0.
// Everything outside it is left exactly as the framebuffer has it.
static void pf_showDarkened(uint8_t down) {
  uint8_t *fb = oled.getBuffer();
  if (!fb) return;
  const int stride = DispWidth / 2;
  for (int y = pfY0; y < pfY1; y++) {
    for (int b = pfX0; b < pfX1; b++) {
      int i = y * stride + b;
      uint8_t hi = fadeBin[i] >> 4, lo = fadeBin[i] & 0x0F;
      hi = hi > down ? hi - down : 0;
      lo = lo > down ? lo - down : 0;
      fb[i] = (uint8_t)((hi << 4) | lo);
    }
  }
  oled.display();
}

static void pf_capture(void) {
  uint8_t *fb = oled.getBuffer();
  if (fb) memcpy(fadeBin, fb, 8192);
}

static uint8_t pf_stepsDue(void) {
  if (pfPhaseMs == 0) return TF_STEPS;
  unsigned long due = (millis() - pfStart) * TF_STEPS / pfPhaseMs;
  return (uint8_t)(due > TF_STEPS ? TF_STEPS : due);
}

#endif  // TF_PALETTE

// Fade the rectangle out, call redraw(), fade it back in. x is in pixels and
// rounded outwards to whole bytes; redraw() must draw the new page into the
// framebuffer and show nothing, since the fade decides what reaches the panel.
//
// Falls back to redrawing at once - and that is the whole behaviour on an
// ESP8266, with no fade time set, or while a picture fade has fadeBin.
void pf_start(int x, int w, int y0, int y1, void (*redraw)(void)) {
#ifdef TF_PALETTE
  if (pf_fadeMs() > 0 && tfState == TF_IDLE && y1 > y0 && w > 0) {
    pfX0      = x / 2;
    pfX1      = (x + w + 1) / 2;
    if (pfX0 < 0) pfX0 = 0;
    if (pfX1 > DispWidth / 2) pfX1 = DispWidth / 2;
    pfY0      = y0 < 0 ? 0 : y0;
    pfY1      = y1 > DispHeight ? DispHeight : y1;
    pfRedraw  = redraw;
    pfStep    = 0;
    pfPhaseMs = pf_fadeMs();
    pfStart   = millis();
    pfState   = PF_OUT;
    pf_capture();
    return;
  }
#else
  (void)x; (void)w; (void)y0; (void)y1;
#endif
  redraw();
  oled.display();
}

// Stop where it is and leave the page drawn in full: something else is taking
// the panel, and a rectangle frozen half dark would stay that way.
void pf_cancel(void) {
  if (pfState == PF_IDLE) return;
  uint8_t state = pfState;
  pfState = PF_IDLE;
#ifdef TF_PALETTE
  // Mid fade-out the new page has not been drawn yet, so it still owes the
  // redraw its caller asked for.
  if (state == PF_OUT && pfRedraw) { pfRedraw(); oled.display(); }
  else                             { pf_showDarkened(0); }
#else
  (void)state;
#endif
}

void pf_tick(void) {
#ifdef TF_PALETTE
  if (pfState == PF_IDLE) return;
  uint8_t due = pf_stepsDue();

  if (pfState == PF_OUT) {
    if (due > pfStep) { pfStep = due; pf_showDarkened(pfStep); }
    if (pfStep < TF_STEPS) return;
    // Black, and the new page goes in behind it: rendered, never shown, so
    // nothing of it reaches the panel undarkened.
    if (pfRedraw) pfRedraw();
    pf_capture();
    pf_showDarkened(TF_STEPS);
    pfStep  = 0;
    pfStart = millis();
    pfState = PF_IN;
    return;
  }

  if (due > pfStep) { pfStep = due; pf_showDarkened((uint8_t)(TF_STEPS - pfStep)); }
  if (pfStep >= TF_STEPS) pfState = PF_IDLE;
#endif
}

#endif  // PAGEFADE_H
