// busybar.h - the boot screen's sweep, as a "something is working" bar.
//
// While update_all runs the daemon shows its picture cropped to the top 54
// rows, the same shape as a boot image, which leaves the boot screen's band
// free. When the downloader starts - the actual update, as opposed to the
// settings screen in front of it - the daemon sends CMDBUSY,1 and the sweep
// runs in that band until CMDBUSY,0: same bar, same rows, same step and speed
// as at power-on, and across the full width, since there is no version to
// leave room for.
//
// CMDBUSY,0 lets the bar finish the cycle it is in - on to the edge, then
// clearing back - rather than leave half a bar on screen, which is how the
// power-on outro ends too. Anything else that reaches the dispatcher (a
// picture, text, the metadata display) stops it dead: the panel is someone
// else's now, and drawing into their picture would be wrong. A setup command
// that draws nothing - contrast, dimming, the clock - is not "anything else";
// boot_quietCommand() is the list, shared with the boot screen.
//
// Ticked from loop(), one segment every BOOT_BAR_MS, never blocking: the port
// has to be read throughout. It waits while a Fade transition runs, because
// the transition's palette steps redraw the whole frame from a copy and would
// both wipe the bar and be spoiled by it.
//
// Needs, from the sketch or the tests: oled, DispWidth, millis(),
// boot_quietCommand() (bootoutro.h), tfState/TF_IDLE (fadetransition.h), and
// the BOOT_BAR_* constants (bootscreen.h).

#ifndef BUSYBAR_H
#define BUSYBAR_H

bool          busyActive   = false;   // the bar is running
bool          busyStopping = false;   // ...and finishing its cycle
bool          busyFilling  = true;    // filling, or clearing back
int           busyPos      = 0;       // next segment to draw
unsigned long busyLast     = 0;

void busy_start(void) {
  if (busyActive && !busyStopping) return;             // already running: keep its place
  if (!busyActive) {
    busyPos     = 0;
    busyFilling = true;
  }
  busyActive   = true;
  busyStopping = false;
  busyLast     = millis();
}

void busy_stop(void) {
  if (busyActive) busyStopping = true;
}

// Something else has the panel: stop without drawing another segment.
void busy_cancel(void) {
  busyActive   = false;
  busyStopping = false;
}

// CMDBUSY,<0|1>
void busy_parse(const char *cmd) {
  const char *p = strchr(cmd, ',');
  if (p && atoi(p + 1) > 0) busy_start();
  else                      busy_stop();
}

// Called for every command before it is handled.
void busy_noteCommand(const char *cmd) {
  if (!busyActive) return;
  if (strncmp(cmd, "CMDBUSY", 7) == 0) return;
  if (!boot_quietCommand(cmd)) busy_cancel();
}

void busy_tick(void) {
  if (!busyActive) return;
  if (tfState != TF_IDLE) { busyLast = millis(); return; }   // after the transition
  unsigned long now = millis();
  bool drew = false;

  // After a stall - a picture transfer holds loop() for a while - carry on
  // from here rather than drawing every missed segment in one go.
  if (now - busyLast > 4 * BOOT_BAR_MS) busyLast = now - BOOT_BAR_MS;

  while (busyActive && now - busyLast >= BOOT_BAR_MS) {
    busyLast += BOOT_BAR_MS;
    // The bar's grey is its position, as on the boot screen: 0 at the left
    // edge, 15 at the right.
    oled.fillRect(busyPos, BOOT_BAR_Y, BOOT_BAR_STEP, BOOT_BAR_H,
                  busyFilling ? busyPos / BOOT_BAR_STEP : SSD1322_BLACK);
    drew = true;
    busyPos += BOOT_BAR_STEP;
    if (busyPos >= DispWidth) {
      busyPos = 0;
      if (busyFilling)       busyFilling = false;
      else if (busyStopping) busy_cancel();              // a whole cycle done: stop here
      else                   busyFilling = true;
    }
  }

  if (drew) oled.display();
}

#endif  // BUSYBAR_H
