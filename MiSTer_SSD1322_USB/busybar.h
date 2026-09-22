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
// CMDBUSY,1 may carry a label - "UPDATING", "Updating TTY2OLED+..." - and then
// the panel is the message: the picture above the band is cleared and the
// label drawn across it, so nothing of the core or the update_all banner shows
// through. Without a label the picture is left alone and only the bar runs,
// which is what the boot screen's own sweep does.
//
// CMDBUSY,0 lets the comet finish its run off the right edge rather than
// leave half a bar on screen, which is how the power-on outro ends too. Anything else that reaches the dispatcher (a
// picture, text, the metadata display) stops it dead: the panel is someone
// else's now, and drawing into their picture would be wrong. A setup command
// that draws nothing - contrast, dimming, the clock - is not "anything else";
// boot_quietCommand() is the list, shared with the boot screen.
//
// Ticked from loop(), one pixel every BOOT_BAR_PX_MS, never blocking: the port
// has to be read throughout. It waits while a Fade transition runs, because
// the transition's palette steps redraw the whole frame from a copy and would
// both wipe the bar and be spoiled by it.
//
// Needs, from the sketch or the tests: oled, u8g2, DispWidth, millis(),
// boot_quietCommand() (bootoutro.h), tfState/TF_IDLE (fadetransition.h), and
// the BOOT_BAR_* and BOOT_BAND_Y constants (bootscreen.h).

#ifndef BUSYBAR_H
#define BUSYBAR_H

// Font 2 is luBS10 - bold, 10px. Big enough to read across a room, small
// enough that the message is a caption over the bar rather than a headline.
// oled_setfont() lives in the sketch; the tests provide their own, as the
// metadata display does.
void oled_setfont(int font);
#define BUSY_LABEL_FONT 2

char          busyLabel[33] = "";      // the message drawn above the band, if any
bool          busyActive   = false;   // the bar is running
bool          busyStopping = false;   // ...and finishing its cycle
int           busyHead     = 0;       // the comet's head, in pixels
unsigned long busyLast     = 0;       // when it last moved

// The label, centred in the rows above the band. Drawn once, when the bar
// starts: the bar only ever touches the band below it, so nothing redraws it.
// The whole panel is blacked first, band included - a bar stopped half way
// through its cycle would otherwise sit there under the new message.
void busy_showLabel(const char *label) {
  oled.fillRect(0, 0, DispWidth, BOOT_PANEL_H, SSD1322_BLACK);
  oled_setfont(BUSY_LABEL_FONT);
  int w = u8g2.getUTF8Width(label);
  int x = (DispWidth - w) / 2;
  if (x < 0) x = 0;
  // Centred in the picture area, not the panel: the band is the bar's.
  u8g2.setCursor(x, (BOOT_BAND_Y + u8g2.getFontAscent()) / 2);
  u8g2.print(label);
  oled.display();
}

void busy_start(void) {
  if (busyActive && !busyStopping) return;             // already running: keep its place
  if (!busyActive) busyHead = 0;
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

// Someone else has taken the panel, so the message is gone with it: the next
// CMDBUSY with the same label has to draw it again.
void busy_forgetLabel(void) {
  busyLabel[0] = '\0';
}

// CMDBUSY,<0|1>[,<label>]
void busy_parse(const char *cmd) {
  const char *p = strchr(cmd, ',');
  if (!p || atoi(p + 1) <= 0) { busy_stop(); return; }
  const char *label = strchr(p + 1, ',');
  // A label restarts the bar from the left, under a freshly drawn message;
  // repeating the same command must not, or a poll every couple of seconds
  // would redraw the panel and reset the sweep each time.
  if (label && label[1]) {
    if (strncmp(busyLabel, label + 1, sizeof(busyLabel) - 1) != 0) {
      strncpy(busyLabel, label + 1, sizeof(busyLabel) - 1);
      busyLabel[sizeof(busyLabel) - 1] = '\0';
      busy_cancel();                                     // so busy_start() rewinds it
      busy_showLabel(busyLabel);
    }
  } else {
    busyLabel[0] = '\0';
  }
  busy_start();
}

// Called for every command before it is handled.
//
// The boot screen's quiet list, with one exception: CMDBOOTPIC draws a
// picture. It counts as quiet for the power-on screen because the picture it
// draws is the boot screen already on the panel - but a bar left sweeping
// across a freshly drawn menu picture is exactly what it looks like, and
// nothing would ever stop it: the daemon sends CMDBOOTPIC and no CMDCOR for
// the MENU core.
void busy_noteCommand(const char *cmd) {
  if (!busyActive) return;
  if (strncmp(cmd, "CMDBUSY", 7) == 0) return;
  if (strncmp(cmd, "CMDBOOTPIC", 10) == 0 || !boot_quietCommand(cmd)) {
    busy_cancel();
    busy_forgetLabel();
  }
}

void busy_tick(void) {
  if (!busyActive) return;
  if (tfState != TF_IDLE) { busyLast = millis(); return; }   // after the transition
  unsigned long now = millis();
  if (now - busyLast < BOOT_BAR_PX_MS) return;

  // One step per tick, whatever the clock says has been missed. A picture
  // transfer holds loop() for a while, and catching up afterwards would both
  // lurch and smear: a head that jumps further than the black end of its own
  // tail leaves the pixels in between lit.
  busyLast   = now;
  busyHead  += BOOT_BAR_PX_STEP;

  if (busyHead >= BOOT_BAR_SPAN(0)) {
    if (busyStopping) {
      // Run over: the comet has drained off the right edge. Black the bar
      // anyway, so a frame cut short by the stop cannot leave anything.
      busy_cancel();
      boot_barClear(0);
      oled.display();
      return;
    }
    busyHead = 0;
  }

  boot_barDraw(busyHead, 0);
  oled.display();
}

#endif  // BUSYBAR_H
