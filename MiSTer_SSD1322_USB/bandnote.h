// bandnote.h - the frontends' band, and the notice that lives in it.
//
// The menu, MisterZine and Degauss are where you choose what to play, and the
// panel shows them the way the boot screen is shown: a picture 54 rows tall,
// and the ten rows under it - the boot screen's band - left to the firmware.
// The daemon marks such a picture "band" (CMDCOR,<core>,<effect>,band; the
// menu's CMDBOOTPIC always is one) and the firmware blacks those ten rows
// whatever the picture had there, so a 256x64 banner is shown cut down to 54
// rows until it is replaced with one drawn for the shape.
//
// What goes in the band is a notice: one line of the 5x7 font in BNOTE_GREY,
// centred - "TTY2OLED+ update available" when the daemon has found a newer
// release. CMDNOTE,<text> sets it and CMDNOTE, with nothing after the comma
// takes it away. It is kept until then, across every picture, and belongs
// only to the frontends: a core's picture has no band and never shows it.
//
// How it appears depends on what the panel is doing when it arrives:
//
//   - on a frontend's picture, it fades in on its own over BNOTE_FADE_MS, grey
//     stepping up a level at a time, and fades out the same way when taken
//     away. Nothing else on the panel moves.
//   - anywhere else it waits, and is part of the next frontend picture from
//     the start: composed into the frame the transition animates towards, so
//     it arrives with the picture - faded in with it, wiped in with it.
//
// The band is shared. At power-on the boot screen's outro runs there (the
// sweep finishing, the version fading), and a busy screen's bar runs there;
// the notice waits for both, and for any picture transition, rather than
// animating one band twice at once.
//
// Needs, from the sketch or the tests: oled, u8g2, logoBin, srcBin,
// actPicType, GSC, DispWidth, millis(), oled_setfont(), oled_transition(),
// tfState/TF_IDLE/tfRenderHook (fadetransition.h), meta_transitionToBuffer()
// (metadisplay.h), boActive (bootoutro.h), busyActive (busybar.h),
// boot_quietCommand(), and the BOOT_BAND_* constants (bootscreen.h).

#ifndef BANDNOTE_H
#define BANDNOTE_H

// The line: the 5x7 font the busy screen's status line uses, at half the
// panel's brightness - it is a footnote to the picture, not part of it.
#define BNOTE_FONT     0
#define BNOTE_GREY     8
#define BNOTE_ASC      6                              // 5x7: rows above the baseline
// Centred in the band's ten rows: seven rows of glyph with its descent leave
// three blank, and the odd one goes above, between the notice and the
// picture: rows 54..55 blank, the glyphs 56..61, descent 62, row 63 blank.
// u8g2 draws a glyph on the rows above its baseline and the descent on it -
// measured with the real library (tools/screenshots), not assumed.
#define BNOTE_GAP      ((BOOT_BAND_H - (BNOTE_ASC + 1) + 1) / 2)   // 2 blank rows above
#define BNOTE_TOP      (BOOT_BAND_Y + BNOTE_GAP)       // 56, its first row
#define BNOTE_Y        (BNOTE_TOP + BNOTE_ASC)          // 62, its baseline: the descent's row
#define BNOTE_COLS      51                             // 256 pixels of 5x7
// A grey level every BNOTE_FADE_MS / BNOTE_GREY: the version's fade at the end
// of the boot screen takes a second, and so does this.
#define BNOTE_FADE_MS  1000
#define BNOTE_STEP_MS  (BNOTE_FADE_MS / BNOTE_GREY)

#ifdef HAS_METADISPLAY

char          noteText[BNOTE_COLS + 1]  = "";   // what CMDNOTE last said
char          noteDrawn[BNOTE_COLS + 1] = "";   // what is in the band now, at noteLevel
int           noteLevel  = 0;                 // its grey on the panel; 0 is not there
unsigned long noteLast   = 0;                 // when it last stepped
bool          bandShown  = false;             // the panel shows a frontend's picture
bool          picBand    = false;             // the picture just received is one

// The band as it should look at `level`: black, and the notice over it.
static void band_drawNote(int level) {
  oled.fillRect(0, BOOT_BAND_Y, DispWidth, BOOT_BAND_H, SSD1322_BLACK);
  if (level <= 0 || !noteDrawn[0]) return;
  oled_setfont(BNOTE_FONT);
  int x = (DispWidth - u8g2.getUTF8Width(noteDrawn)) / 2;
  if (x < 0) x = 0;
  u8g2.setForegroundColor((uint16_t)level);
  u8g2.setCursor(x, BNOTE_Y);
  u8g2.print(noteDrawn);
  u8g2.setForegroundColor(SSD1322_WHITE);
}

// A frontend's whole frame: the picture in logoBin, and the notice as it
// stands now at full grey. Also the Fade's render hook, so a notice that
// arrives while the old picture is fading out still makes the fade-in.
static void band_render(void) {
  oled.clearDisplay();
  oled.draw4bppBitmap(logoBin);
  strcpy(noteDrawn, noteText);
  noteLevel = noteDrawn[0] ? BNOTE_GREY : 0;
  band_drawNote(noteLevel);
}

// Black the band of the picture in logoBin: a frontend's picture is 54 rows,
// whatever shape the file it came from was.
static void band_crop(void) {
  memset(logoBin + BOOTIMG_BYTES, 0, BOOT_PANEL_BYTES - BOOTIMG_BYTES);
}

// Transition to the frontend's picture in logoBin, notice and all. The
// text-screen idiom: rendered into the framebuffer, copied to metaBin, and
// the transition pointed there. metaBin is free - a frontend's picture is
// always preceded by CMDMETAOFF, and with metadata off there is no card.
void band_showPicture(int effect) {
  band_crop();
  bandShown = true;
  meta_beginTransitionText(effect);        // the old picture, while it is there
  band_render();
  tfRenderHook = band_render;              // taken by a Fade, dropped by a wipe
  meta_transitionToBuffer(effect);
}

// The power-on screen is the menu's picture already, and its outro is running
// in the band: there is nothing to transition, and the notice waits for the
// band to empty before it fades in.
void band_heldUnder(void) {
  band_crop();
  bandShown = true;
  noteDrawn[0] = '\0';
  noteLevel = 0;
}

// CMDCOR, or CMDAPD: did this picture come marked as a frontend's? The third
// field, after the effect - which firmware before 0.7.1b reads past, since the
// effect is taken with toInt() and that stops at the comma.
void band_parsePicture(const char *cmd) {
  const char *p = strchr(cmd, ',');                // after the command
  p = p ? strchr(p + 1, ',') : nullptr;            // after the core name
  p = p ? strchr(p + 1, ',') : nullptr;            // after the effect
  picBand = p && strcmp(p + 1, "band") == 0;
}

// CMDNOTE,<text> - the rest of the line; nothing after the comma is none.
// Draws nothing here: band_tick fades it in or out when the band is free.
void band_noteParse(const char *cmd) {
  const char *text = strchr(cmd, ',');
  text = text ? text + 1 : "";
  size_t len = strlen(text);
  if (len > BNOTE_COLS) len = BNOTE_COLS;
  memcpy(noteText, text, len);
  noteText[len] = '\0';
}

// Called for every command before it is handled. Anything that draws takes
// the panel away from the frontend's picture; CMDBOOTPIC and CMDCOR put one
// back up, and say so themselves. CMDNOTE is on the quiet list.
void band_noteCommand(const char *cmd) {
  if (strncmp(cmd, "CMDBOOTPIC", 10) == 0 || !boot_quietCommand(cmd)) bandShown = false;
}

// A step of the notice's fade, when the band is the notice's to draw in.
void band_tick(void) {
  if (!bandShown) return;
  if (tfState != TF_IDLE || boActive || busyActive || pf_active()) return;
  bool changed = strcmp(noteDrawn, noteText) != 0;
  // A different text goes out before the new one comes in.
  if (changed && noteLevel == 0) { strcpy(noteDrawn, noteText); changed = false; }
  int target = (!changed && noteDrawn[0]) ? BNOTE_GREY : 0;
  if (noteLevel == target) return;
  unsigned long now = millis();
  if (now - noteLast < BNOTE_STEP_MS) return;
  noteLast = now;
  noteLevel += (target > noteLevel) ? 1 : -1;
  band_drawNote(noteLevel);
  oled.display();
}

#else   // !HAS_METADISPLAY - no buffer to compose in: frontends are plain pictures

bool bandShown = false;
bool picBand   = false;
void band_showPicture(int effect)          { oled_transition(effect); }
void band_heldUnder(void)                  { }
void band_parsePicture(const char *cmd)    { (void)cmd; }
void band_noteParse(const char *cmd)       { (void)cmd; }
void band_noteCommand(const char *cmd)     { (void)cmd; }
void band_tick(void)                       { }

#endif  // HAS_METADISPLAY

#endif  // BANDNOTE_H
