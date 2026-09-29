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

// The status line: what the update is doing right now, in the 5x7 font under
// the label - update_all's last line of output, or the updater's own step.
// 51 characters fit across the panel. Grey, so the label stays the message
// and this reads as the detail. Its baseline leaves BUSY_GAP_LINE blank rows
// above the band (the 5x7 font's one row of descent included); with a line
// up, the label is centred in the rows above it instead of above the band.
#define BUSY_LINE_FONT  0
#define BUSY_LINE_GREY  10
#define BUSY_LINE_ASC   6                                  // 5x7: rows above the baseline
#define BUSY_GAP_LINE   3                                  // blank rows between it and the band
#define BUSY_LINE_Y     (BOOT_BAND_Y - BUSY_GAP_LINE - 2)  // 49: baseline; descent is row 50
#define BUSY_LINE_TOP   (BUSY_LINE_Y - BUSY_LINE_ASC + 1)  // 44: its first row
#define BUSY_LINE_MAX   64

char          busyLabel[33] = "";      // the message drawn above the band, if any
char          busyLine[BUSY_LINE_MAX + 1] = "";   // the status line under it, if any
bool          busyTextDirty = false;  // label or line changed during a transition
bool          busyActive   = false;   // the bar is running
bool          busyStopping = false;   // ...and finishing its cycle
int           busyHead     = 0;       // the comet's head, in pixels
unsigned long busyLast     = 0;       // when it last moved

// The label, centred in the rows above the band. Drawn once, when the bar
// starts: the bar only ever touches the band below it, so nothing redraws it.
// The whole panel is blacked first, band included - a bar stopped half way
// through its cycle would otherwise sit there under the new message.
//
// With an effect it arrives like a picture instead of appearing: rendered
// into the framebuffer and handed to the transition. That is for the screens
// that *replace* what you were looking at - tty2oledplus_update taking over
// from a core's artwork. The downloader's bar sends no effect, because by
// then the panel is already the update_all screen and nothing is being
// replaced; fading from one message to another says something changed when
// nothing did.
//
// BUSY_NO_EFFECT is "drawn, not transitioned", and is not a valid effect
// number - the parsers clamp anything below -2 up to -1.
#define BUSY_NO_EFFECT (-99)

// The label and the status line, into rows the caller has already blacked.
void busy_composeText(const char *label) {
  oled_setfont(BUSY_LABEL_FONT);
  int w = u8g2.getUTF8Width(label);
  int x = (DispWidth - w) / 2;
  if (x < 0) x = 0;
  // Centred in the rows above the status line's place, line or no line: it
  // comes and goes all through an update, and a label centred on whatever
  // was free jumped up and down with it.
  u8g2.setCursor(x, (BUSY_LINE_TOP + u8g2.getFontAscent()) / 2);
  u8g2.print(label);
  if (!busyLine[0]) return;
  oled_setfont(BUSY_LINE_FONT);
  // Centred like the label; a line too long for the panel starts at the left
  // edge and loses its end rather than its beginning. The daemon shortens
  // paths from the left before they get here, so that is rare.
  w = u8g2.getUTF8Width(busyLine);
  x = (DispWidth - w) / 2;
  if (x < 0) x = 0;
  u8g2.setForegroundColor(BUSY_LINE_GREY);
  u8g2.setCursor(x, BUSY_LINE_Y);
  u8g2.print(busyLine);
  u8g2.setForegroundColor(SSD1322_WHITE);
}

void busy_showLabel(const char *label, int effect) {
#ifdef HAS_METADISPLAY
  bool fade = (effect != BUSY_NO_EFFECT);
  if (fade) meta_beginTransitionText(effect);   // the old picture, while it is there
#endif
  oled.fillRect(0, 0, DispWidth, BOOT_PANEL_H, SSD1322_BLACK);
  busy_composeText(label);
  busyTextDirty = false;
#ifdef HAS_METADISPLAY
  if (fade) { meta_transitionToBuffer(effect); return; }
#endif
  oled.display();
}

// The label or the line changed on a screen that is already up: redraw the
// rows above the band and leave the band alone - the bar may be mid-sweep, or
// finishing its last cycle under "Update Complete". A transition in progress
// redraws the whole frame from its own copy on every step, so a change that
// arrives during one waits for busy_tick to find it idle.
void busy_redrawText(void) {
  if (tfState != TF_IDLE) { busyTextDirty = true; return; }
  busyTextDirty = false;
  if (!busyLabel[0]) return;
  oled.fillRect(0, 0, DispWidth, BOOT_BAND_Y, SSD1322_BLACK);
  busy_composeText(busyLabel);
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
  busyLine[0] = '\0';
  busyTextDirty = false;
}

// CMDBUSY,<0|1>[,<label>[,<effect>]]
//
// The effect is last rather than before the label because the label is the
// rest of the line in the older form, and an install one version behind must
// keep working. It is unambiguous despite that: metasanitize strips commas
// from everything the daemon puts on the wire, so a comma after the label has
// to be one of ours.
//
// CMDBUSY,0 with a label is the end of the job: "Update Complete" replaces
// the label, the status line goes, and the bar finishes the cycle it is in.
// On a screen that is already the busy screen only the rows above the band
// are redrawn, so the comet can run off the edge undisturbed; on anything
// else - the display just reset by a flash - it is a new screen, drawn (or
// transitioned) whole, with no bar. Firmware before 0.7.0b ignores the label
// and only stops the bar.
void busy_parse(const char *cmd) {
  const char *p = strchr(cmd, ',');
  bool on = p && atoi(p + 1) > 0;
  const char *label = p ? strchr(p + 1, ',') : nullptr;
  if (label && label[1]) {
    // A third comma, if there is one, ends the label and begins the effect.
    const char *eff = strrchr(label + 1, ',');
    size_t len = eff ? (size_t)(eff - (label + 1)) : strlen(label + 1);
    if (len > sizeof(busyLabel) - 1) len = sizeof(busyLabel) - 1;
    int effect = eff ? effect_clamp(atoi(eff + 1)) : BUSY_NO_EFFECT;
    // A label restarts the bar from the left, under a freshly drawn message;
    // repeating the same command must not, or a poll every couple of seconds
    // would redraw the panel and reset the sweep each time. The effect is not
    // part of that comparison: the same message is the same screen however it
    // was asked to arrive.
    if (strncmp(busyLabel, label + 1, len) != 0 || strlen(busyLabel) != len) {
      bool screenUp = busyLabel[0] != '\0';
      memcpy(busyLabel, label + 1, len);
      busyLabel[len] = '\0';
      busyLine[0] = '\0';                                 // a new message, no detail yet
      if (on) {
        busy_cancel();                                   // so busy_start() rewinds it
        busy_showLabel(busyLabel, effect);
      } else if (screenUp || busyActive) {
        busy_redrawText();
      } else {
        busy_showLabel(busyLabel, effect);
      }
    }
  } else if (on) {
    busyLabel[0] = '\0';
    busyLine[0] = '\0';
  }
  if (on) busy_start(); else busy_stop();
}

// CMDBUSYLINE,<text> - the status line under the label; the text is the rest
// of the line, and an empty one takes the line down. Only on a busy screen
// with a label: over a picture there is nowhere to put it. The same text again
// draws nothing, so the daemon may repeat itself.
void busy_lineParse(const char *cmd) {
  const char *text = strchr(cmd, ',');
  text = text ? text + 1 : "";
  if (!busyLabel[0]) return;
  size_t len = strlen(text);
  if (len > BUSY_LINE_MAX) len = BUSY_LINE_MAX;
  if (strncmp(busyLine, text, len) == 0 && strlen(busyLine) == len) return;
  memcpy(busyLine, text, len);
  busyLine[len] = '\0';
  busy_redrawText();
}

// Called for every command before it is handled.
//
// The boot screen's quiet list, with one exception: CMDBOOTPIC draws a
// picture. It counts as quiet for the power-on screen because the picture it
// draws is the boot screen already on the panel - but a bar left sweeping
// across a freshly drawn menu picture is exactly what it looks like, and
// nothing would ever stop it: the daemon sends CMDBOOTPIC and no CMDCOR for
// the MENU core.
//
// The label is forgotten whether the bar is running or not. It used to be
// only while it ran, and update_all runs its downloader twice: between the two
// the bar drains off the edge within a third of a second, and only then does
// the update_all screen go back up over the label. The second run's label was
// the one remembered, so it was taken for a repeat and never drawn - the bar
// swept along under the update_all screen with no message above it.
void busy_noteCommand(const char *cmd) {
  if (strncmp(cmd, "CMDBUSY", 7) == 0) return;
  if (strncmp(cmd, "CMDBOOTPIC", 10) == 0 || !boot_quietCommand(cmd)) {
    busy_forgetLabel();
    if (busyActive) busy_cancel();
  }
}

void busy_tick(void) {
  // Text that changed during a transition, drawn once it is over.
  if (busyTextDirty && tfState == TF_IDLE) busy_redrawText();
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
