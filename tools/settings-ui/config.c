// tty2oledplus_config - tty2oled+'s screens, drawn on the framebuffer.
//
// Runs ON THE MISTER, started by the launcher and the tools behind it from
// the Scripts menu. It is the screen and the keys, nothing else: every
// decision, and everything that is written, stays in the scripts. Over SSH,
// with no framebuffer to draw on, the scripts' dialog menus and plain text do
// the same jobs.
//
//   tty2oledplus_config [settings] --table FILE --out FILE [--preview CMD]
//   tty2oledplus_config menu  --out FILE [--default TAG] -- TAG LABEL HELP ...
//   tty2oledplus_config ask   --out FILE --text TEXT [--buttons "No|Yes"] [--default N]
//   tty2oledplus_config check --out FILE [--ok-label L] -- TAG LABEL on|off ...
//   tty2oledplus_config run   [--nowait] -- COMMAND [ARGS...]
//   tty2oledplus_config probe | release
//
//   all:  [--title T] [--subtitle T] [--status T] [--text T] [--keep]
//         [--fb DEVICE] [--geometry WxHxBPP] [--dump FILE]
//
// settings is the editor (below). menu is a list to pick one of, its tag into
// --out. ask is a question with buttons, the index of the one pressed into
// --out. check is a list of boxes, the ticked tags into --out. run shows a
// command's output as it comes, with a sweep bar while it works, and exits
// with the command's own code. All of them exit 10 on Cancel, 12 when there
// is nothing to draw on, 13 when the keys ran out (tests feed them on a
// pipe). probe only says whether it could draw; release hands the console
// back.
//
// --keep leaves the console in graphics mode and the picture up on the way
// out, for the next screen to replace: the launcher shows several in a row,
// and the console's text must not flash up between them. Whoever started
// keeping ends with release.
//
// The look is the panel's: sixteen levels of one colour on black, in the
// fonts the firmware draws with (fonts.h, generated from them). The canvas is
// 320x240 with everything inside a 16-pixel margin, which is what a 15kHz
// CRT shows; a larger framebuffer gets it scaled by a whole number, centred.
// One with fewer lines than that, down to 224, gets the canvas less its top
// and bottom edge, which are empty; and one whose pixels are not square - a
// 15kHz mode with twice the columns, 640x240 - gets it wider than tall by a
// whole number too (fb_fit).
//
// The table, a line a record, tab separated:
//
//   C <id> <label> <help>                        a section
//   G <caption>                                  a divider above the next setting
//   S <key> <type> <spec> <label> <help>         a setting, in the last section
//   D <key> <value>                              its default
//   V <key> <value>                              what is saved
//   P <key> <value>                              changed, not saved yet
//
//   bool    yes/no                                a switch
//   int     "min max [step]"                      a slider
//   enum    "value=label;value=label"             a selector
//   text    the length limit                      a field, and a keyboard
//   list    the vocabulary, or @KEY for another   an ordered checklist
//           setting's value
//   prefix  KEY: a leading run of that list       a stepper
//
// Out: KEY=VALUE for every setting that differs from what is saved. The exit
// code says what to do with them: 0 save, 10 leave, 12 nothing to draw on,
// 13 the keys ran out.
//
// The preview: CMD is started with a pipe for stdin and told, a line each,
// "focus <key>" when a setting is highlighted and "set <key> <value>" when one
// changes - it is tty2oledplus_preview.sh, which shows it on the display.
//
// Keys are read off the terminal, which is how a pad arrives as well: while a
// script owns the screen MiSTer sends the d-pad as arrows and the buttons as
// Enter and Escape.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <linux/fb.h>
#include <linux/kd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>

#include "fonts.h"

// ---------------------------------------------------------------------------
// The canvas: 320x240, a level 0..15 a pixel.
// ---------------------------------------------------------------------------
#define CW 320
#define CH 240

// What a 15kHz CRT shows of it, with room for its overscan.
#define X0 16
#define X1 304
#define Y0 12
#define Y1 228
// The fewest lines a screen may have: the canvas's rows less eight above and
// below, which leaves four of the empty edge either side of what is drawn.
#define CH_MIN 224

static unsigned char cv[CH][CW];
static int clipx0 = 0, clipx1 = CW, clipy0 = 0, clipy1 = CH;

static void clip_set(int x, int y, int w, int h) {
  clipx0 = x < 0 ? 0 : x; clipy0 = y < 0 ? 0 : y;
  clipx1 = x + w > CW ? CW : x + w; clipy1 = y + h > CH ? CH : y + h;
}
static void clip_off(void) { clipx0 = 0; clipy0 = 0; clipx1 = CW; clipy1 = CH; }

static void px(int x, int y, int lv) {
  if (x >= clipx0 && x < clipx1 && y >= clipy0 && y < clipy1) cv[y][x] = (unsigned char)lv;
}
static void fill(int x, int y, int w, int h, int lv) {
  for (int j = y; j < y + h; j++) for (int i = x; i < x + w; i++) px(i, j, lv);
}
static void frame(int x, int y, int w, int h, int lv) {
  fill(x, y, w, 1, lv); fill(x, y + h - 1, w, 1, lv);
  fill(x, y, 1, h, lv); fill(x + w - 1, y, 1, h, lv);
}
// A frame with its corner pixels left out: as round as one pixel gets.
static void box(int x, int y, int w, int h, int lv) {
  fill(x + 1, y, w - 2, 1, lv); fill(x + 1, y + h - 1, w - 2, 1, lv);
  fill(x, y + 1, 1, h - 2, lv); fill(x + w - 1, y + 1, 1, h - 2, lv);
}

static int text_w(const Font *f, const char *s) {
  int w = 0;
  for (; *s; s++) { int c = (unsigned char)*s; if (c >= 32 && c < 127) w += f->adv[c - 32]; }
  return w;
}
// y is the top row of the font's box, not the baseline.
static int text(const Font *f, int x, int y, const char *s, int lv) {
  for (; *s; s++) {
    int c = (unsigned char)*s;
    if (c < 32 || c >= 127) c = '?';
    const unsigned int *rows = f->rows + (c - 32) * f->height;
    for (int r = 0; r < f->height; r++)
      for (unsigned int b = rows[r], i = 0; b; b >>= 1, i++)
        if (b & 1) px(x + (int)i - FONT_XOFF, y + r, lv);
    x += f->adv[c - 32];
  }
  return x;
}
// One character twice the size, each pixel a 2x2 block: the number editor's
// digits, which have to be read from the sofa.
static void glyph_2x(const Font *f, int x, int y, int c, int lv) {
  const unsigned int *rows = f->rows + (c - 32) * f->height;
  for (int r = 0; r < f->height; r++)
    for (unsigned int b = rows[r], i = 0; b; b >>= 1, i++)
      if (b & 1) fill(x + 2 * ((int)i - FONT_XOFF), y + 2 * r, 2, 2, lv);
}
static void text_right(const Font *f, int xr, int y, const char *s, int lv) {
  text(f, xr - text_w(f, s), y, s, lv);
}
static void text_centre(const Font *f, int x, int w, int y, const char *s, int lv) {
  text(f, x + (w - text_w(f, s)) / 2, y, s, lv);
}

static long long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Text in a window: as it is when it fits, and otherwise scrolled round and
// round while it is the highlighted row - after a second's rest - or cut.
// since < 0 is "not highlighted". Returns whether it is moving.
#define MARQ_REST_MS 1000
#define MARQ_PX_S    30
#define MARQ_GAP     24
static int text_window(const Font *f, int x, int y, int w, const char *s, int lv,
                       long long since, int align_right) {
  int tw = text_w(f, s), sx0 = clipx0, sx1 = clipx1, moving = 0;
  if (tw <= w) {
    text(f, align_right ? x + w - tw : x, y, s, lv);
    return 0;
  }
  if (x > clipx0) clipx0 = x;
  if (x + w < clipx1) clipx1 = x + w;
  if (since < 0) {
    text(f, x, y, s, lv);
  } else {
    long long t = now_ms() - since - MARQ_REST_MS;
    int off = t > 0 ? (int)(t * MARQ_PX_S / 1000 % (tw + MARQ_GAP)) : 0;
    text(f, x - off, y, s, lv);
    text(f, x - off + tw + MARQ_GAP, y, s, lv);
    moving = 1;
  }
  clipx0 = sx0; clipx1 = sx1;
  return moving;
}

// ---------------------------------------------------------------------------
// The framebuffer.
// ---------------------------------------------------------------------------
static struct {
  int fd, w, h, bpp, stride, sx, sy, ox, oy, cy, vh;
  int ro, go, bo, rl, gl, bl;
  unsigned char *mem;
  size_t len;
  unsigned int pal[16];
} fb = { .fd = -1 };

// How the canvas goes on a screen of w x h, into fb: vh of its rows from cy
// on, each pixel sx wide and sy tall, at ox, oy. 1 if it does not fit.
//
// Rows. All 240 where they fit; the middle 224 where the screen has fewer
// lines (640x224), or where that takes a larger whole-number scale (448
// lines). Nothing is drawn in the rows left out: everything is inside Y0..Y1,
// and a 224-line mode is the middle of a 240-line raster, so what a CRT
// shows stays where it was.
//
// Columns. The framebuffer fills the screen whatever its size, so 640x240 on
// a 4:3 screen has pixels half as wide as tall, and the canvas a pixel for a
// pixel was a narrow strip in the middle. A mode far wider than any screen -
// more than five columns to two lines, where 21:9 is seven to three - is
// taken to be that: a 4:3 screen, and the pixel as wide as it comes out. The
// width follows, to the nearest whole number that fits. Anything else has
// square pixels.
static int fb_fit(int w, int h) {
  if (w < CW || h < CH_MIN) return 1;
  fb.vh = CH;
  if (h / CH_MIN > h / CH) fb.vh = CH_MIN;
  fb.cy = (CH - fb.vh) / 2;
  fb.sy = h / fb.vh;
  fb.sx = fb.sy;
  if (w * 2 > h * 5) fb.sx = (2 * 3 * w * fb.sy + 4 * h) / (2 * 4 * h);   // sy x 3w/4h, rounded
  if (fb.sx > w / CW) fb.sx = w / CW;
  if (fb.sx < 1) fb.sx = 1;
  // Square pixels on a screen too narrow for the height's scale: both down.
  if (w * 2 <= h * 5 && fb.sy > fb.sx) fb.sy = fb.sx;
  fb.ox = (w - CW * fb.sx) / 2;
  fb.oy = (h - fb.vh * fb.sy) / 2;
  return 0;
}

static int fb_open(const char *dev, const char *geometry) {
  struct fb_var_screeninfo v;
  struct fb_fix_screeninfo fx;
  fb.fd = open(dev, O_RDWR | (geometry ? O_CREAT : 0), 0644);
  if (fb.fd < 0) return -1;
  if (!geometry && ioctl(fb.fd, FBIOGET_VSCREENINFO, &v) == 0 &&
      ioctl(fb.fd, FBIOGET_FSCREENINFO, &fx) == 0) {
    fb.w = (int)v.xres; fb.h = (int)v.yres; fb.bpp = (int)v.bits_per_pixel;
    fb.stride = (int)fx.line_length;
    fb.ro = (int)v.red.offset; fb.go = (int)v.green.offset; fb.bo = (int)v.blue.offset;
    fb.rl = (int)v.red.length; fb.gl = (int)v.green.length; fb.bl = (int)v.blue.length;
    fb.len = (size_t)fb.stride * (size_t)v.yres_virtual;
    if (fb.len < (size_t)fb.stride * (size_t)fb.h) fb.len = (size_t)fb.stride * (size_t)fb.h;
  } else if (geometry && sscanf(geometry, "%dx%dx%d", &fb.w, &fb.h, &fb.bpp) == 3) {
    // A file standing in for the device: tests, and looking at it on a desk.
    fb.stride = fb.w * fb.bpp / 8;
    if (fb.bpp == 16) { fb.ro = 11; fb.go = 5; fb.bo = 0; fb.rl = 5; fb.gl = 6; fb.bl = 5; }
    else              { fb.ro = 16; fb.go = 8; fb.bo = 0; fb.rl = fb.gl = fb.bl = 8; }
    fb.len = (size_t)fb.stride * (size_t)fb.h;
    if (ftruncate(fb.fd, (off_t)fb.len) != 0) return -1;
  } else {
    return -1;
  }
  if ((fb.bpp != 16 && fb.bpp != 32) || fb_fit(fb.w, fb.h)) return -1;
  fb.mem = mmap(NULL, fb.len, PROT_READ | PROT_WRITE, MAP_SHARED, fb.fd, 0);
  if (fb.mem == MAP_FAILED) { fb.mem = NULL; return -1; }

  // Sixteen levels of cyan: no red, green and blue together.
  for (int i = 0; i < 16; i++) {
    unsigned int lv = (unsigned int)i * 17;
    fb.pal[i] = (lv >> (8 - fb.gl)) << fb.go | (lv >> (8 - fb.bl)) << fb.bo;
    if (fb.bpp == 32) fb.pal[i] |= 0xFFu << 24 & ~(0xFFu << fb.ro | 0xFFu << fb.go | 0xFFu << fb.bo);
  }
  return 0;
}

// The canvas onto the screen. The first time, what lies around it is blacked
// - and only that: the last screen's picture stays up until this one's is
// written over it, so two screens in a row do not blink.
static void fb_present(void) {
  static int margins = 0;
  if (!fb.mem) return;
  if (!margins) {
    size_t bytes = (size_t)(fb.bpp / 8), left = (size_t)fb.ox * bytes;
    size_t right = (size_t)(fb.ox + CW * fb.sx) * bytes, width = (size_t)fb.w * bytes;
    for (int y = 0; y < fb.h; y++) {
      unsigned char *line = fb.mem + (size_t)y * (size_t)fb.stride;
      if (y < fb.oy || y >= fb.oy + fb.vh * fb.sy) memset(line, 0, width);
      else { memset(line, 0, left); memset(line + right, 0, width - right); }
    }
    margins = 1;
  }
  for (int r = 0; r < fb.vh; r++) {
    int y = fb.cy + r;
    unsigned char *line = fb.mem + (size_t)(fb.oy + r * fb.sy) * (size_t)fb.stride
                        + (size_t)fb.ox * (size_t)(fb.bpp / 8);
    if (fb.bpp == 32) {
      unsigned int *p = (unsigned int *)(void *)line;
      for (int x = 0; x < CW; x++)
        for (int s = 0; s < fb.sx; s++) *p++ = fb.pal[cv[y][x]];
    } else {
      unsigned short *p = (unsigned short *)(void *)line;
      for (int x = 0; x < CW; x++)
        for (int s = 0; s < fb.sx; s++) *p++ = (unsigned short)fb.pal[cv[y][x]];
    }
    for (int s = 1; s < fb.sy; s++)
      memcpy(line + (size_t)s * (size_t)fb.stride, line, (size_t)CW * (size_t)fb.sx * (size_t)(fb.bpp / 8));
  }
}

// ---------------------------------------------------------------------------
// The terminal: keys in, and the console kept from drawing over us.
// ---------------------------------------------------------------------------
static struct termios tty_saved;
static int tty_raw = 0, tty_graphics = 0, in_tty = 0;
static int keep = 0;                     // --keep: graphics mode outlives us

static void tty_restore(void) {
  if (tty_raw) { tcsetattr(0, TCSANOW, &tty_saved); tty_raw = 0; }
  if (keep) return;
  if (tty_graphics) { ioctl(0, KDSETMODE, KD_TEXT); tty_graphics = 0; }
  if (in_tty) { const char *s = "\033[2J\033[H\033[?25h"; if (write(1, s, strlen(s)) < 0) { } }
}
static void on_signal(int sig) { keep = 0; tty_graphics = 1; tty_restore(); _exit(128 + sig); }

static void tty_setup(void) {
  struct termios t;
  in_tty = isatty(0);
  if (!in_tty) return;
  if (tcgetattr(0, &tty_saved) == 0) {
    t = tty_saved;
    cfmakeraw(&t);
    t.c_cc[VMIN] = 0; t.c_cc[VTIME] = 0;
    if (tcsetattr(0, TCSANOW, &t) == 0) tty_raw = 1;
  }
  // Only a virtual console has a mode to set; over SSH this fails, harmlessly.
  if (ioctl(0, KDSETMODE, KD_GRAPHICS) == 0) tty_graphics = 1;
  signal(SIGINT, on_signal); signal(SIGTERM, on_signal); signal(SIGHUP, on_signal);
}

enum { K_NONE, K_UP, K_DOWN, K_LEFT, K_RIGHT, K_OK, K_CANCEL, K_BACKSPACE, K_TAB,
       K_PGUP, K_PGDN, K_HOME, K_END, K_EOF, K_CHAR = 256 };

static unsigned char inbuf[64];
static int inlen = 0, in_eof = 0;

static int in_fill(int wait_ms) {
  struct pollfd p = { 0, POLLIN, 0 };
  if (in_eof || inlen >= (int)sizeof inbuf) return 0;
  if (poll(&p, 1, wait_ms) <= 0) return 0;
  // Off a pipe, a byte at a time: the keys after this screen's last are the
  // next screen's, and that is another process reading the same pipe.
  ssize_t n = read(0, inbuf + inlen, in_tty ? sizeof inbuf - (size_t)inlen : 1);
  if (n <= 0) { if (n == 0 || errno != EINTR) in_eof = 1; return 0; }
  inlen += (int)n;
  return 1;
}
static void in_drop(int n) { memmove(inbuf, inbuf + n, (size_t)(inlen - n)); inlen -= n; }

// One key, waiting up to wait_ms for it. An Escape on its own is Cancel; one
// that starts an arrow's sequence has the rest right behind it, so on a
// terminal a short wait tells them apart, and on a pipe what follows does.
static int key_read(int wait_ms) {
  if (inlen == 0 && !in_fill(wait_ms)) return in_eof ? K_EOF : K_NONE;
  int c = inbuf[0];
  if (c == 0x1b) {
    if (inlen == 1 && in_tty) in_fill(40);
    if (inlen == 1 && !in_tty) in_fill(0);
    if (inlen >= 2 && (inbuf[1] == '[' || inbuf[1] == 'O')) {
      int i = 2;
      while (i >= inlen || (inbuf[i] >= '0' && inbuf[i] <= '9') || inbuf[i] == ';') {
        if (i >= inlen) { if (!in_fill(in_tty ? 40 : 0)) break; continue; }
        i++;
      }
      if (i >= inlen) { in_drop(inlen); return K_NONE; }
      int fin = inbuf[i], num = inbuf[2] >= '0' && inbuf[2] <= '9' ? atoi((char *)inbuf + 2) : 0;
      in_drop(i + 1);
      switch (fin) {
        case 'A': return K_UP;   case 'B': return K_DOWN;
        case 'C': return K_RIGHT; case 'D': return K_LEFT;
        case 'H': return K_HOME; case 'F': return K_END;
        case '~': return num == 5 ? K_PGUP : num == 6 ? K_PGDN : num == 1 || num == 7 ? K_HOME
                       : num == 4 || num == 8 ? K_END : K_NONE;
      }
      return K_NONE;
    }
    in_drop(1);
    return K_CANCEL;
  }
  in_drop(1);
  if (c == '\r' || c == '\n') return K_OK;
  if (c == 0x7f || c == 0x08) return K_BACKSPACE;
  if (c == '\t') return K_TAB;
  if (c >= 32 && c < 127) return K_CHAR + c;
  return K_NONE;
}

// ---------------------------------------------------------------------------
// The settings.
// ---------------------------------------------------------------------------
typedef enum { T_BOOL, T_INT, T_ENUM, T_TEXT, T_LIST, T_PREFIX } Type;

typedef struct {
  char *key, *label, *help, *spec, *def, *saved, *val;
  char *group;                // the divider above it, if it starts a sub-section
  Type type;
  int cat;
  int min, max, step;         // int
  char **ev, **el; int en;    // enum: values, labels
  int maxlen;                 // text
  long long sent_at; int dirty;
} Setting;

typedef struct { char *id, *label, *help; } Cat;

#define MAX_SETTINGS 256
#define MAX_CATS 24
#define MAX_WORDS 64
static Setting st[MAX_SETTINGS];
static Cat cats[MAX_CATS];
static int nst = 0, ncats = 0;

static char *dupstr(const char *s) {
  char *d = strdup(s ? s : "");
  if (!d) { perror("tty2oledplus_config"); exit(12); }
  return d;
}
static void setstr(char **p, const char *s) { char *d = dupstr(s); free(*p); *p = d; }

static Setting *find(const char *key) {
  for (int i = 0; i < nst; i++) if (!strcmp(st[i].key, key)) return &st[i];
  return NULL;
}

// A list's words, in place: the string is cut up and the pointers kept.
static int words(char *s, char **out, int max) {
  int n = 0;
  for (char *w = strtok(s, " "); w && n < max; w = strtok(NULL, " ")) out[n++] = w;
  return n;
}
static int word_in(const char *w, const char *list) {
  size_t n = strlen(w);
  for (const char *p = list; (p = strstr(p, w)); p += n)
    if ((p == list || p[-1] == ' ') && (p[n] == 0 || p[n] == ' ')) return 1;
  return 0;
}
static int word_count(const char *list) {
  int n = 0, in = 0;
  for (; *list; list++) { if (*list != ' ' && !in) n++; in = *list != ' '; }
  return n;
}
// The first n words of a list, into buf.
static void word_prefix(const char *list, int n, char *buf, size_t size) {
  char tmp[1024], *w[MAX_WORDS];
  snprintf(tmp, sizeof tmp, "%s", list);
  int k = words(tmp, w, MAX_WORDS);
  buf[0] = 0;
  for (int i = 0; i < k && i < n; i++) {
    if (i) strncat(buf, " ", size - strlen(buf) - 1);
    strncat(buf, w[i], size - strlen(buf) - 1);
  }
}

static int load_table(const char *path) {
  FILE *f = fopen(path, "r");
  char line[4096], *fld[6], *group = NULL;
  if (!f) return -1;
  while (fgets(line, sizeof line, f)) {
    line[strcspn(line, "\r\n")] = 0;
    int n = 0;
    for (char *p = line; n < 6; n++) {
      fld[n] = p;
      char *t = strchr(p, '\t');
      if (!t) { n++; break; }
      *t = 0; p = t + 1;
    }
    for (int i = n; i < 6; i++) fld[i] = (char *)"";
    if (!strcmp(fld[0], "G")) {
      free(group); group = dupstr(fld[1]);
    } else if (!strcmp(fld[0], "C") && ncats < MAX_CATS) {
      free(group); group = NULL;
      cats[ncats].id = dupstr(fld[1]); cats[ncats].label = dupstr(fld[2]);
      cats[ncats].help = dupstr(fld[3]); ncats++;
    } else if (!strcmp(fld[0], "S") && nst < MAX_SETTINGS && ncats > 0) {
      Setting *s = &st[nst++];
      memset(s, 0, sizeof *s);
      s->key = dupstr(fld[1]); s->spec = dupstr(fld[3]);
      s->label = dupstr(fld[4]); s->help = dupstr(fld[5]);
      s->def = dupstr(""); s->saved = dupstr(""); s->val = dupstr("");
      s->cat = ncats - 1;
      s->group = group; group = NULL;
      if (!strcmp(fld[2], "bool")) s->type = T_BOOL;
      else if (!strcmp(fld[2], "int")) {
        s->type = T_INT; s->step = 1;
        sscanf(s->spec, "%d %d %d", &s->min, &s->max, &s->step);
        if (s->step < 1) s->step = 1;
      } else if (!strcmp(fld[2], "enum")) {
        s->type = T_ENUM;
        char *copy = dupstr(s->spec);
        int cnt = 1;
        for (char *p = copy; *p; p++) if (*p == ';') cnt++;
        s->ev = calloc((size_t)cnt, sizeof *s->ev); s->el = calloc((size_t)cnt, sizeof *s->el);
        if (!s->ev || !s->el) exit(12);
        for (char *p = strtok(copy, ";"); p; p = strtok(NULL, ";")) {
          char *eq = strchr(p, '=');
          if (eq) *eq = 0;
          s->ev[s->en] = p; s->el[s->en] = eq ? eq + 1 : p; s->en++;
        }
      } else if (!strcmp(fld[2], "list")) s->type = T_LIST;
      else if (!strcmp(fld[2], "prefix")) s->type = T_PREFIX;
      else { s->type = T_TEXT; s->maxlen = atoi(s->spec); if (s->maxlen < 1) s->maxlen = 32; }
    } else if (fld[0][0] && !fld[0][1] && strchr("DVP", fld[0][0])) {
      Setting *s = find(fld[1]);
      if (!s) continue;
      if (fld[0][0] == 'D') setstr(&s->def, fld[2]);
      if (fld[0][0] == 'V') { setstr(&s->saved, fld[2]); setstr(&s->val, fld[2]); }
      if (fld[0][0] == 'P') setstr(&s->val, fld[2]);
    }
  }
  free(group);
  fclose(f);
  return nst > 0 ? 0 : -1;
}

static int changed(const Setting *s) { return strcmp(s->val, s->saved) != 0; }
static int changes(int cat) {
  int n = 0;
  for (int i = 0; i < nst; i++) if ((cat < 0 || st[i].cat == cat) && changed(&st[i])) n++;
  return n;
}

static int write_out(const char *path) {
  FILE *f = fopen(path, "w");
  if (!f) return -1;
  for (int i = 0; i < nst; i++) if (changed(&st[i])) fprintf(f, "%s=%s\n", st[i].key, st[i].val);
  return fclose(f);
}

// ---------------------------------------------------------------------------
// The preview on the display.
// ---------------------------------------------------------------------------
// A value is sent once it has stopped changing for a moment, and a highlight
// once it has rested on a setting: a slider held down, or a list scrolled
// through, would otherwise queue up a screen for every step.
#define SEND_REST_MS  120
#define FOCUS_REST_MS 300

static int pv_fd = -1;
static pid_t pv_pid = 0;
static const char *focus_want = "-", *focus_sent = "";
static long long focus_at = 0;

static void pv_start(const char *cmd) {
  int p[2];
  if (!cmd || !*cmd || pipe(p) != 0) return;
  pv_pid = fork();
  if (pv_pid == 0) {
    dup2(p[0], 0); close(p[0]); close(p[1]);
    int nul = open("/dev/null", O_WRONLY);
    if (nul >= 0) { dup2(nul, 1); dup2(nul, 2); close(nul); }
    signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGHUP, SIG_DFL);
    execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
    _exit(127);
  }
  close(p[0]);
  if (pv_pid < 0) { close(p[1]); pv_pid = 0; return; }
  pv_fd = p[1];
  fcntl(pv_fd, F_SETFD, FD_CLOEXEC);
}
static void pv_line(const char *fmt, ...) {
  char buf[1200];
  va_list ap;
  if (pv_fd < 0) return;
  va_start(ap, fmt);
  int n = vsnprintf(buf, sizeof buf - 1, fmt, ap);
  va_end(ap);
  if (n < 0) return;
  if (n > (int)sizeof buf - 2) n = (int)sizeof buf - 2;
  buf[n++] = '\n';
  if (write(pv_fd, buf, (size_t)n) < 0) { close(pv_fd); pv_fd = -1; }
}
static void pv_touch(Setting *s) { s->dirty = 1; s->sent_at = now_ms(); }
static void pv_focus(const char *key) {
  if (strcmp(key, focus_want)) { focus_want = key; focus_at = now_ms(); }
}
// What is due; all of it when force. Returns whether something still waits.
static int pv_flush(int force) {
  long long now = now_ms();
  int waiting = 0;
  for (int i = 0; i < nst; i++) {
    if (!st[i].dirty) continue;
    if (force || now - st[i].sent_at >= SEND_REST_MS) { pv_line("set %s %s", st[i].key, st[i].val); st[i].dirty = 0; }
    else waiting = 1;
  }
  if (strcmp(focus_want, focus_sent)) {
    if (force || now - focus_at >= FOCUS_REST_MS) { pv_line("focus %s", focus_want); focus_sent = focus_want; }
    else waiting = 1;
  }
  return waiting;
}
// The preview has the display's port; it must be gone before the script
// starts the daemon again. It leaves at once when its input closes.
static void pv_stop(void) {
  if (pv_fd >= 0) { pv_flush(1); close(pv_fd); pv_fd = -1; }
  if (pv_pid > 0) {
    for (int i = 0; i < 80; i++) {
      if (waitpid(pv_pid, NULL, WNOHANG) != 0) { pv_pid = 0; return; }
      usleep(50000);
    }
    kill(pv_pid, SIGTERM);
    waitpid(pv_pid, NULL, 0);
    pv_pid = 0;
  }
}

// A setting takes a value: what depends on it follows, and the display hears.
// A list another is chosen from (@KEY) keeps only what is still there; a
// leading run of another list (prefix) keeps its length.
static void set_value(Setting *s, const char *v) {
  char old[1024];
  if (!strcmp(s->val, v)) return;
  snprintf(old, sizeof old, "%s", s->val);
  setstr(&s->val, v);
  pv_touch(s);
  for (int i = 0; i < nst; i++) {
    Setting *d = &st[i];
    char buf[1024] = "";
    if (d->type == T_LIST && d->spec[0] == '@' && !strcmp(d->spec + 1, s->key)) {
      char tmp[1024], *w[MAX_WORDS];
      snprintf(tmp, sizeof tmp, "%s", d->val);
      int k = words(tmp, w, MAX_WORDS);
      for (int j = 0; j < k; j++) if (word_in(w[j], s->val)) {
        if (buf[0]) strncat(buf, " ", sizeof buf - strlen(buf) - 1);
        strncat(buf, w[j], sizeof buf - strlen(buf) - 1);
      }
    } else if (d->type == T_PREFIX && !strcmp(d->spec, s->key)) {
      word_prefix(s->val, word_count(d->val), buf, sizeof buf);
    } else continue;
    if (strcmp(d->val, buf)) { setstr(&d->val, buf); pv_touch(d); }
  }
}

// ---------------------------------------------------------------------------
// The screens.
// ---------------------------------------------------------------------------
// Levels, by what they are for.
#define L_TEXT   10   // a row's label
#define L_VALUE  13   // its value
#define L_HOT    15   // anything on the highlighted row
#define L_BAR     3   // the highlight itself
#define L_RULE    6
#define L_DIM     5
#define L_HELP    9
#define L_TRACK   4

#define BAR_H     15                    // title bar: Y0 .. Y0+BAR_H
#define RULE1_Y   (Y0 + BAR_H + 2)
#define ROWS_Y    (RULE1_Y + 4)
#define ROW_H     15
#define ROWS      9
#define RULE2_Y   (ROWS_Y + ROWS * ROW_H + 2)
#define HELP_Y    (RULE2_Y + 4)
#define HELP_LINES 5
#define HELP_PITCH 8
#define HINT_Y    (Y1 - 8)
#define WIDGET_R  (X1 - 8)              // the widgets' right edge; the scrollbar is past it
#define WIDGET_W  118

enum { M_MAIN, M_SECTION, M_LIST };
enum { P_NONE, P_PICK, P_NUM, P_KEYS, P_CONFIRM };
enum { MAIN_DEFAULTS, MAIN_SAVE, MAIN_EXTRA };

static int mode = M_MAIN, popup = P_NONE;
static int main_sel = 0, main_top = 0;
static int sec_cat = 0, sec_sel = 0, sec_top = 0;
static long long sel_since = 0;          // for the highlighted row's marquee
static int animating = 0;                // a marquee or a cursor is moving
static const char *status_text = "";
static int result = -1;                  // the exit code, once decided

// The checklist screen.
static Setting *list_s = NULL;
static char list_buf[2][1024];
static char *list_on[MAX_WORDS], *list_off[MAX_WORDS];
static int list_non = 0, list_noff = 0, list_sel = 0, list_top = 0;

// The popups.
static Setting *pop_s = NULL;
static char pop_before[1024];            // to put back on Cancel
static int pick_sel = 0, pick_top = 0;
static int num_val = 0, num_digit = 0;
static char keys_buf[256];
static int keys_row = 0, keys_col = 0, keys_upper = 0;
static const char *confirm_title = "", *confirm_text = "";
static const char *confirm_btn[3];
static int confirm_n = 0, confirm_sel = 0, confirm_what = 0;
enum { C_EXIT, C_DEFAULTS };

static int cat_first(int cat) { for (int i = 0; i < nst; i++) if (st[i].cat == cat) return i; return 0; }
static int cat_count(int cat) { int n = 0; for (int i = 0; i < nst; i++) if (st[i].cat == cat) n++; return n; }
static Setting *sec_setting(void) { return &st[cat_first(sec_cat) + sec_sel]; }

static void scroll_to(int sel, int *top, int count) {
  if (sel < *top) *top = sel;
  if (sel >= *top + ROWS) *top = sel - ROWS + 1;
  if (*top > count - ROWS) *top = count - ROWS;
  if (*top < 0) *top = 0;
}

// A section's rows on screen: its settings, and a divider's row above each
// that starts a sub-section. The highlight moves over settings only; the
// scrolling counts rows.
static int sec_rows(void) {
  int first = cat_first(sec_cat), n = cat_count(sec_cat), rows = n;
  for (int i = 0; i < n; i++) if (st[first + i].group) rows++;
  return rows;
}
static int sec_row_of(int sel) {
  int first = cat_first(sec_cat), row = 0;
  for (int i = 0; i <= sel; i++) { if (st[first + i].group) row++; if (i < sel) row++; }
  return row;
}
static void sec_scroll(void) {
  int row = sec_row_of(sec_sel), rows = sec_rows();
  // Its divider comes into view with the first setting under it.
  int from = sec_setting()->group ? row - 1 : row;
  if (from < sec_top) sec_top = from;
  if (row >= sec_top + ROWS) sec_top = row - ROWS + 1;
  if (sec_top > rows - ROWS) sec_top = rows - ROWS;
  if (sec_top < 0) sec_top = 0;
}

// A divider: its caption, small, and a rule from there to the right edge.
static void draw_divider(const char *caption, int y) {
  char buf[64];
  snprintf(buf, sizeof buf, "%s", caption);
  for (char *p = buf; *p; p++) if (*p >= 'a' && *p <= 'z') *p = (char)(*p - 32);
  int x = text(&font_small, X0 + 2, y + 6, buf, L_HELP);
  fill(x + 4, y + 9, WIDGET_R - (x + 4), 1, L_RULE);
}

static void draw_bar(const char *title, const Font *f) {
  text(f, X0, Y0 + (BAR_H - f->height) / 2, title, 15);
  if (*status_text) {
    int live = !strncmp(status_text, "OLED", 4);
    int w = text_w(&font_small, status_text);
    text(&font_small, X1 - w, Y0 + 5, status_text, live ? 12 : L_DIM);
    // A lit pixel block for a display that is following along.
    if (live) fill(X1 - w - 7, Y0 + 6, 4, 4, 15);
  }
  fill(X0, RULE1_Y, X1 - X0, 1, L_RULE);
  fill(X0, RULE2_Y, X1 - X0, 1, L_RULE);
}

static void draw_scrollbar(int top, int count) {
  if (count <= ROWS) return;
  int h = ROWS * ROW_H, th = h * ROWS / count, ty = h * top / count;
  if (th < 6) th = 6;
  fill(X1 - 2, ROWS_Y, 1, h, L_TRACK);
  fill(X1 - 3, ROWS_Y + ty, 3, th, 11);
}

// Help text, wrapped at words into the lines under the rows.
static void draw_help(const char *s) {
  int cols = (X1 - X0) / font_small.adv[0], y = HELP_Y;
  for (int line = 0; line < HELP_LINES && *s; line++, y += HELP_PITCH) {
    char buf[96];
    int n = (int)strlen(s);
    if (n > cols) { n = cols; while (n > 0 && s[n] != ' ') n--; if (n == 0) n = cols; }
    snprintf(buf, sizeof buf, "%.*s", n, s);
    text(&font_small, X0, y, buf, L_HELP);
    s += n;
    while (*s == ' ') s++;
  }
}
static void draw_hint(const char *s) { text_right(&font_small, X1, HINT_Y, s, L_DIM); }

static void draw_chevron(int xr, int y, int lv) {
  for (int i = 0; i < 4; i++) { px(xr - 4 + i, y + 3 + i, lv); px(xr - 4 + i, y + 11 - i, lv); }
  px(xr, y + 7, lv);
}
static void draw_arrow(int x, int y, int dir, int lv) {       // a small triangle, dir -1 left, 1 right
  for (int i = 0; i < 4; i++) fill(dir < 0 ? x + 3 - i : x + i, y + 4 + i, 1, 7 - 2 * i, lv);
}
static void draw_check(int x, int y, int on, int lv) {
  box(x, y + 3, 9, 9, lv);
  if (on) fill(x + 2, y + 5, 5, 5, lv);
}

static void draw_switch(int xr, int y, int on, int hot) {
  int w = 24, x = xr - w;
  if (on) { fill(x + 1, y + 3, w - 2, 9, 7); box(x, y + 3, w, 9, 15); fill(x + w - 9, y + 5, 6, 5, 15); }
  else    { box(x, y + 3, w, 9, hot ? 9 : L_DIM); fill(x + 3, y + 5, 6, 5, hot ? 9 : L_DIM); }
  text_right(&font_small, x - 5, y + 4, on ? "ON" : "OFF", on ? (hot ? L_HOT : L_VALUE) : (hot ? 11 : L_DIM));
}

static void draw_slider(int x, int y, int w, int min, int max, int v, int hot) {
  int span = max - min, pos = span > 0 ? (int)((long long)(v - min) * (w - 3) / span) : 0;
  fill(x, y + 7, w, 1, hot ? 7 : L_TRACK);
  fill(x, y + 6, pos, 3, hot ? 12 : 9);
  fill(x + pos, y + 3, 3, 9, hot ? 15 : 12);
}

static const char *enum_label(const Setting *s, const char *v) {
  for (int i = 0; i < s->en; i++) if (!strcmp(s->ev[i], v)) return s->el[i];
  return v;
}
static int enum_index(const Setting *s) {
  for (int i = 0; i < s->en; i++) if (!strcmp(s->ev[i], s->val)) return i;
  return 0;
}
static int prefix_most(const Setting *s) {
  // Three at most: the card has four rows, and pinning them all would leave
  // nothing to page - the firmware caps it one below the row count.
  Setting *base = find(s->spec);
  int n = base ? word_count(base->val) : 0;
  return n > 3 ? 3 : n;
}

// One setting's row: the label left, its widget right.
static void draw_setting(Setting *s, int y, int hot) {
  int ty = y + (ROW_H - font_body.height) / 2;
  long long since = hot ? sel_since : -1;
  // A switch and a slider are narrower than a value in words, and the label
  // has what they leave.
  int ww = s->type == T_BOOL ? 52 : s->type == T_INT ? 88 : WIDGET_W;
  int label_w = WIDGET_R - ww - 8 - (X0 + 8);
  if (hot) fill(X0, y, X1 - X0 - 4, ROW_H, L_BAR);
  if (changed(s)) fill(X0 + 2, y + 6, 3, 3, hot ? 15 : 11);
  animating |= text_window(&font_body, X0 + 8, ty, label_w, s->label, hot ? L_HOT : L_TEXT, since, 0);

  int wx = WIDGET_R - ww, lv = hot ? L_HOT : L_VALUE;
  switch (s->type) {
    case T_BOOL:
      draw_switch(WIDGET_R, y, !strcmp(s->val, "yes"), hot);
      break;
    case T_INT: {
      char buf[16];
      snprintf(buf, sizeof buf, "%d", atoi(s->val));
      draw_slider(wx, y, ww - 38, s->min, s->max, atoi(s->val), hot);
      text_right(&font_body, WIDGET_R, ty, buf, lv);
      break;
    }
    case T_ENUM:
    case T_PREFIX: {
      const char *v = s->type == T_ENUM ? enum_label(s, s->val) : (*s->val ? s->val : "(none)");
      draw_arrow(wx, y, -1, hot ? 12 : L_DIM);
      draw_arrow(WIDGET_R - 4, y, 1, hot ? 12 : L_DIM);
      int w = ww - 16, tw = text_w(&font_body, v);
      if (tw <= w) text(&font_body, wx + 8 + (w - tw) / 2, ty, v, lv);
      else animating |= text_window(&font_body, wx + 8, ty, w, v, lv, since, 0);
      break;
    }
    case T_TEXT:
      frame(wx, y + 1, ww, ROW_H - 2, hot ? 11 : L_DIM);
      animating |= text_window(&font_body, wx + 4, ty, ww - 8, s->val, lv, since, 0);
      break;
    case T_LIST:
      animating |= text_window(&font_body, wx, ty, ww - 10, *s->val ? s->val : "(none)", lv, since, 1);
      draw_chevron(WIDGET_R, y, hot ? 15 : L_DIM);
      break;
  }
}

static const char *hint_for(const Setting *s) {
  switch (s->type) {
    case T_BOOL: return "LEFT/RIGHT OR OK: SWITCH   CANCEL: BACK";
    case T_INT:  return "LEFT/RIGHT: ADJUST   OK: EXACT   CANCEL: BACK";
    case T_ENUM: return "LEFT/RIGHT: CHANGE   OK: LIST   CANCEL: BACK";
    case T_TEXT: return "OK: EDIT   CANCEL: BACK";
    case T_LIST: return "OK: CHOOSE   CANCEL: BACK";
    default:     return "LEFT/RIGHT: CHANGE   CANCEL: BACK";
  }
}

// What the release ships with, at the left of the hint line, when it is
// short enough to say there.
static void draw_default(const Setting *s) {
  char buf[40];
  const char *d = s->type == T_BOOL ? (!strcmp(s->def, "yes") ? "ON" : "OFF")
                : s->type == T_ENUM ? enum_label(s, s->def) : s->def;
  if (s->type == T_LIST || s->type == T_PREFIX || strlen(d) > 12) return;
  snprintf(buf, sizeof buf, "DEFAULT %s", *d ? d : "(EMPTY)");
  for (char *p = buf; *p; p++) if (*p >= 'a' && *p <= 'z') *p = (char)(*p - 32);
  text(&font_small, X0, HINT_Y, buf, changed(s) || strcmp(s->val, s->def) ? L_HELP : L_DIM);
}

static int main_count(void) { return ncats + MAIN_EXTRA; }

static void draw_main(void) {
  int x = text(&font_title, X0, Y0, "tty2oled+", 15);
  text(&font_head, x + 6, Y0 + 3, "settings", 9);
  draw_bar("", &font_head);
  int count = main_count();
  for (int r = 0; r < ROWS && main_top + r < count; r++) {
    int i = main_top + r, y = ROWS_Y + r * ROW_H, hot = i == main_sel;
    int ty = y + (ROW_H - font_body.height) / 2;
    char buf[64] = "";
    const char *label;
    if (hot) fill(X0, y, X1 - X0 - 4, ROW_H, L_BAR);
    if (i < ncats) {
      label = cats[i].label;
      int n = changes(i);
      if (n) snprintf(buf, sizeof buf, "%d changed", n);
      draw_chevron(WIDGET_R, y, hot ? 15 : L_DIM);
      if (n) fill(X0 + 2, y + 6, 3, 3, hot ? 15 : 11);
    } else if (i - ncats == MAIN_DEFAULTS) {
      label = "Put everything back to the defaults";
    } else {
      int n = changes(-1);
      label = n ? "Save and exit" : "Exit";
      if (n) snprintf(buf, sizeof buf, "%d change%s", n, n == 1 ? "" : "s");
    }
    text(&font_body, X0 + 8, ty, label, hot ? L_HOT : L_TEXT);
    if (*buf) text_right(&font_small, WIDGET_R - 10, y + 4, buf, hot ? L_VALUE : L_HELP);
    // The actions stand apart from the sections.
    if (i == ncats && r > 0) fill(X0 + 8, y, X1 - X0 - 20, 1, L_TRACK);
  }
  draw_scrollbar(main_top, count);
  if (main_sel < ncats) draw_help(cats[main_sel].help);
  else if (main_sel - ncats == MAIN_DEFAULTS)
    draw_help("Every setting here goes back to what the release ships with. Nothing is written until you save.");
  else
    draw_help("Changes are written to tty2oled-user.ini and the display restarts with them. Cancel leaves without saving.");
  draw_hint("UP/DOWN: MOVE   OK: OPEN   CANCEL: EXIT");
}

static void draw_section(void) {
  int first = cat_first(sec_cat), count = cat_count(sec_cat);
  draw_bar(cats[sec_cat].label, &font_head);
  for (int i = 0, row = 0; i < count; i++) {
    Setting *s = &st[first + i];
    if (s->group) {
      if (row >= sec_top && row < sec_top + ROWS) draw_divider(s->group, ROWS_Y + (row - sec_top) * ROW_H);
      row++;
    }
    if (row >= sec_top && row < sec_top + ROWS) draw_setting(s, ROWS_Y + (row - sec_top) * ROW_H, i == sec_sel);
    row++;
  }
  draw_scrollbar(sec_top, sec_rows());
  draw_help(sec_setting()->help);
  draw_hint(hint_for(sec_setting()));
  draw_default(sec_setting());
}

static void list_load(void) {
  Setting *s = list_s, *src = s->spec[0] == '@' ? find(s->spec + 1) : NULL;
  snprintf(list_buf[0], sizeof list_buf[0], "%s", s->val);
  snprintf(list_buf[1], sizeof list_buf[1], "%s", src ? src->val : s->spec);
  char *all[MAX_WORDS], *on[MAX_WORDS];
  int non = words(list_buf[0], on, MAX_WORDS), nall = words(list_buf[1], all, MAX_WORDS);
  list_non = list_noff = 0;
  // Chosen first, in their own order: the order the display draws them in.
  for (int i = 0; i < non; i++)
    for (int j = 0; j < nall; j++) if (!strcmp(on[i], all[j])) { list_on[list_non++] = all[j]; break; }
  for (int j = 0; j < nall; j++) {
    int have = 0;
    for (int i = 0; i < list_non; i++) if (list_on[i] == all[j]) have = 1;
    if (!have) list_off[list_noff++] = all[j];
  }
}
static void list_store(void) {
  char buf[1024] = "";
  for (int i = 0; i < list_non; i++) {
    if (i) strncat(buf, " ", sizeof buf - strlen(buf) - 1);
    strncat(buf, list_on[i], sizeof buf - strlen(buf) - 1);
  }
  set_value(list_s, buf);
  list_load();
}

static void draw_list(void) {
  int count = list_non + list_noff;
  draw_bar(list_s->label, &font_head);
  if (count == 0)
    text(&font_body, X0 + 8, ROWS_Y + 3, "Nothing to choose from yet.", L_TEXT);
  for (int r = 0; r < ROWS && list_top + r < count; r++) {
    int i = list_top + r, y = ROWS_Y + r * ROW_H, hot = i == list_sel, on = i < list_non;
    int ty = y + (ROW_H - font_body.height) / 2;
    char num[16];
    if (hot) fill(X0, y, X1 - X0 - 4, ROW_H, L_BAR);
    draw_check(X0 + 6, y, on, hot ? 15 : on ? L_VALUE : L_DIM);
    text(&font_body, X0 + 22, ty, on ? list_on[i] : list_off[i - list_non], hot ? L_HOT : on ? L_VALUE : L_DIM + 2);
    if (on) {
      snprintf(num, sizeof num, "%d", i + 1);
      text_right(&font_small, WIDGET_R - 14, y + 4, num, hot ? L_VALUE : L_HELP);
      if (hot) { draw_arrow(WIDGET_R - 10, y, -1, i > 0 ? 12 : L_TRACK); draw_arrow(WIDGET_R - 4, y, 1, i < list_non - 1 ? 12 : L_TRACK); }
    }
  }
  draw_scrollbar(list_top, count);
  draw_help(list_s->help);
  draw_hint("OK: TICK   LEFT/RIGHT: MOVE EARLIER/LATER   CANCEL: DONE");
}

// A popup's panel: black, framed, the title in its top edge.
static void draw_panel(int x, int y, int w, int h, const char *title) {
  fill(x - 2, y - 2, w + 4, h + 4, 0);
  frame(x, y, w, h, 12);
  fill(x + 1, y + 1, w - 2, 13, L_BAR);
  text_window(&font_body, x + 5, y + 3, w - 10, title, 15, -1, 0);
  fill(x + 1, y + 14, w - 2, 1, 12);
}

#define PICK_ROWS 9
#define PICK_X 36
#define PICK_W 248
#define PICK_Y 36
#define PICK_ROW_H 14
static void draw_pick(void) {
  Setting *s = pop_s;
  draw_panel(PICK_X, PICK_Y, PICK_W, 18 + PICK_ROWS * PICK_ROW_H + 3, s->label);
  for (int r = 0; r < PICK_ROWS && pick_top + r < s->en; r++) {
    int i = pick_top + r, y = PICK_Y + 17 + r * PICK_ROW_H, hot = i == pick_sel;
    if (hot) fill(PICK_X + 3, y, PICK_W - 10, PICK_ROW_H, L_BAR);
    // The one in force when the list opened keeps its mark.
    if (!strcmp(s->ev[i], pop_before)) fill(PICK_X + 6, y + 5, 4, 4, hot ? 15 : 11);
    animating |= text_window(&font_body, PICK_X + 14, y + 2, PICK_W - 28, s->el[i], hot ? L_HOT : L_TEXT,
                             hot ? sel_since : -1, 0);
  }
  if (s->en > PICK_ROWS) {
    int h = PICK_ROWS * PICK_ROW_H, th = h * PICK_ROWS / s->en, ty = h * pick_top / s->en;
    fill(PICK_X + PICK_W - 4, PICK_Y + 17, 1, h, L_TRACK);
    fill(PICK_X + PICK_W - 5, PICK_Y + 17 + ty, 3, th < 6 ? 6 : th, 11);
  }
}

static int pow10i(int n) { int p = 1; while (n-- > 0) p *= 10; return p; }
static int num_digits(const Setting *s) {
  int m = abs(s->max) > abs(s->min) ? abs(s->max) : abs(s->min), d = 1;
  while (m >= 10) { m /= 10; d++; }
  return d;
}
static void draw_num(void) {
  Setting *s = pop_s;
  int x = 46, y = 70, w = 228, h = 92, digits = num_digits(s);
  char buf[64];
  draw_panel(x, y, w, h, s->label);
  // The digits, in fixed cells, the one being changed marked above and below.
  int cell = 16, total = digits * cell + (s->min < 0 ? cell : 0), dx = x + (w - total) / 2;
  if (s->min < 0) { if (num_val < 0) glyph_2x(&font_body, dx + 2, y + 25, '-', 15); dx += cell; }
  for (int d = digits - 1; d >= 0; d--, dx += cell) {
    int hot = d == num_digit, lead = abs(num_val) < pow10i(d) && d > 0;
    glyph_2x(&font_body, dx + 2, y + 25, '0' + abs(num_val) / pow10i(d) % 10, hot ? 15 : lead ? L_DIM : 11);
    if (hot) {
      for (int i = 0; i < 4; i++) { fill(dx + 7 - i, y + 20 + i, 2 * i + 2, 1, 12); fill(dx + 7 - i, y + 47 - i, 2 * i + 2, 1, 12); }
    }
  }
  draw_slider(x + 20, y + 52, w - 40, s->min, s->max, num_val, 1);
  snprintf(buf, sizeof buf, "%d TO %d   DEFAULT %s", s->min, s->max, s->def);
  text_centre(&font_small, x, w, y + 70, buf, L_HELP);
  text_centre(&font_small, x, w, y + 80, "UP/DOWN: DIGIT   OK: SET   CANCEL: UNDO", L_DIM);
}

// The keyboard: thirteen keys a row, and a row of actions.
#define KEYS_COLS 13
#define KEYS_ROWS 4
static const char *const keys_rows[KEYS_ROWS] = { "abcdefghijklm", "nopqrstuvwxyz", "0123456789.-_", "/:%!?&+=#@~()" };
static const char *const keys_act[] = { "Aa", "Space", "Delete", "Clear", "Done" };
enum { KA_SHIFT, KA_SPACE, KA_DELETE, KA_CLEAR, KA_DONE, KA_N };
#define KEYS_X 30
#define KEYS_W 260
#define KEYS_Y 46
#define KEY_W 20
#define KEY_H 16

static void draw_keys(void) {
  Setting *s = pop_s;
  int x = KEYS_X, y = KEYS_Y, gx = x + (KEYS_W - KEYS_COLS * KEY_W) / 2;
  char buf[32];
  draw_panel(x, y, KEYS_W, 150, s->label);
  // The text so far: its end, when it is longer than the field.
  frame(x + 8, y + 20, KEYS_W - 16, 15, 11);
  int fw = KEYS_W - 16 - 12, tw = text_w(&font_body, keys_buf), tx = x + 12;
  clip_set(tx, y + 20, fw + 4, 15);
  if (tw > fw) tx -= tw - fw;
  int cx = text(&font_body, tx, y + 23, keys_buf, 15);
  if (now_ms() / 400 % 2) fill(cx + 1, y + 23, 1, 10, 15);
  clip_off();
  animating = 1;
  snprintf(buf, sizeof buf, "%d/%d", (int)strlen(keys_buf), s->maxlen);
  text_right(&font_small, x + KEYS_W - 8, y + 38, buf, L_DIM);

  for (int r = 0; r < KEYS_ROWS; r++)
    for (int c = 0; c < KEYS_COLS; c++) {
      int kx = gx + c * KEY_W, ky = y + 48 + r * KEY_H, hot = r == keys_row && c == keys_col;
      char ch[2] = { keys_rows[r][c], 0 };
      if (keys_upper && ch[0] >= 'a' && ch[0] <= 'z') ch[0] = (char)(ch[0] - 32);
      if (hot) fill(kx + 1, ky + 1, KEY_W - 2, KEY_H - 2, 6);
      text_centre(&font_body, kx, KEY_W, ky + 3, ch, hot ? 15 : L_TEXT);
    }
  int ay = y + 48 + KEYS_ROWS * KEY_H + 4, aw = KEYS_COLS * KEY_W / KA_N;
  for (int a = 0; a < KA_N; a++) {
    int ax = gx + a * aw, hot = keys_row == KEYS_ROWS && keys_col * KA_N / KEYS_COLS == a;
    if (hot) fill(ax + 1, ay, aw - 2, 15, 6);
    box(ax + 1, ay, aw - 2, 15, hot ? 15 : (a == KA_SHIFT && keys_upper) ? 12 : L_DIM);
    text_centre(&font_body, ax, aw, ay + 2, keys_act[a], hot ? 15 : L_TEXT);
  }
  text_centre(&font_small, x, KEYS_W, y + 150 - 11, "OK: PRESS   CANCEL: UNDO   OR JUST TYPE", L_DIM);
}

static void draw_confirm(void) {
  int w = 240, h = 86, x = (CW - w) / 2, y = (CH - h) / 2;
  draw_panel(x, y, w, h, confirm_title);
  // Two lines of text at most, split at a newline.
  const char *nl = strchr(confirm_text, '\n');
  char l1[64];
  snprintf(l1, sizeof l1, "%.*s", nl ? (int)(nl - confirm_text) : 60, confirm_text);
  text_centre(&font_body, x, w, y + 24, l1, L_VALUE);
  if (nl) text_centre(&font_body, x, w, y + 37, nl + 1, L_VALUE);
  int bw = (w - 16) / confirm_n;
  for (int i = 0; i < confirm_n; i++) {
    int bx = x + 8 + i * bw, hot = i == confirm_sel;
    if (hot) fill(bx + 2, y + 60, bw - 4, 16, 6);
    box(bx + 2, y + 60, bw - 4, 16, hot ? 15 : L_DIM);
    text_centre(&font_body, bx, bw, y + 63, confirm_btn[i], hot ? 15 : L_TEXT);
  }
}

static void draw(void) {
  memset(cv, 0, sizeof cv);
  animating = 0;
  switch (mode) {
    case M_MAIN:    draw_main(); break;
    case M_SECTION: draw_section(); break;
    case M_LIST:    draw_list(); break;
  }
  if (popup != P_NONE) {
    // What is behind a popup steps back: every other level, so it reads as dimmed.
    for (int y = 0; y < CH; y++) for (int x = 0; x < CW; x++) cv[y][x] = (unsigned char)(cv[y][x] * 2 / 5);
    animating = 0;
  }
  switch (popup) {
    case P_PICK:    draw_pick(); break;
    case P_NUM:     draw_num(); break;
    case P_KEYS:    draw_keys(); break;
    case P_CONFIRM: draw_confirm(); break;
  }
  fb_present();
}

// ---------------------------------------------------------------------------
// The keys.
// ---------------------------------------------------------------------------
static void confirm_open(int what, const char *title, const char *msg, const char *b0, const char *b1, const char *b2, int sel) {
  popup = P_CONFIRM; confirm_what = what; confirm_title = title; confirm_text = msg;
  confirm_btn[0] = b0; confirm_btn[1] = b1; confirm_btn[2] = b2;
  confirm_n = b2 ? 3 : 2; confirm_sel = sel;
}

static void focus_now(void) {
  if (popup != P_NONE && pop_s) pv_focus(pop_s->key);
  else if (mode == M_SECTION) pv_focus(sec_setting()->key);
  else if (mode == M_LIST) pv_focus(list_s->key);
  else pv_focus("-");
}

// A held direction: the terminal repeats the key, and a run of repeats moves
// a slider faster the longer it goes on.
static long long rep_at = 0;
static int rep_key = 0, rep_run = 0;
static int repeat_gain(int key) {
  long long now = now_ms();
  if (key == rep_key && now - rep_at < 200) rep_run++; else rep_run = 0;
  rep_key = key; rep_at = now;
  return rep_run < 8 ? 1 : rep_run < 24 ? 5 : 20;
}

static void set_int(Setting *s, int v) {
  char buf[16];
  if (v < s->min) v = s->min;
  if (v > s->max) v = s->max;
  snprintf(buf, sizeof buf, "%d", v);
  set_value(s, buf);
}

static void adjust(Setting *s, int dir, int key) {
  switch (s->type) {
    case T_BOOL: set_value(s, dir > 0 ? "yes" : "no"); break;
    case T_INT: {
      // On the step's grid: 0, 50, 100 rather than 37, 87, 137.
      int v = atoi(s->val), step = s->step * repeat_gain(key);
      int off = (v % step + step) % step;
      if (off) v = dir > 0 ? v - off + step : v - off;
      else v += dir * step;
      set_int(s, v);
      break;
    }
    case T_ENUM: {
      int i = enum_index(s) + dir;
      if (s->en) set_value(s, s->ev[(i + s->en) % s->en]);
      break;
    }
    case T_PREFIX: {
      Setting *base = find(s->spec);
      char buf[1024];
      int n = word_count(s->val) + dir, most = prefix_most(s);
      if (n < 0) n = 0;
      if (n > most) n = most;
      word_prefix(base ? base->val : "", n, buf, sizeof buf);
      set_value(s, buf);
      break;
    }
    default: break;
  }
}

static void open_editor(Setting *s) {
  pop_s = s;
  snprintf(pop_before, sizeof pop_before, "%s", s->val);
  sel_since = now_ms();
  switch (s->type) {
    case T_BOOL: set_value(s, strcmp(s->val, "yes") ? "yes" : "no"); break;
    case T_INT:  popup = P_NUM; num_val = atoi(s->val); num_digit = 0; break;
    case T_ENUM:
      popup = P_PICK; pick_sel = enum_index(s);
      pick_top = pick_sel - PICK_ROWS / 2;
      if (pick_top > s->en - PICK_ROWS) pick_top = s->en - PICK_ROWS;
      if (pick_top < 0) pick_top = 0;
      break;
    case T_TEXT:
      popup = P_KEYS; snprintf(keys_buf, sizeof keys_buf, "%s", s->val);
      keys_row = 0; keys_col = 0; keys_upper = 0;
      break;
    case T_LIST:
      mode = M_LIST; list_s = s; list_sel = 0; list_top = 0; list_load();
      break;
    case T_PREFIX: adjust(s, 1, K_RIGHT); break;
  }
}

static void move(int *sel, int *top, int count, int key) {
  if (count <= 0) return;
  switch (key) {
    case K_UP:   *sel = (*sel + count - 1) % count; break;
    case K_DOWN: *sel = (*sel + 1) % count; break;
    case K_PGUP: *sel = *sel - ROWS < 0 ? 0 : *sel - ROWS; break;
    case K_PGDN: *sel = *sel + ROWS >= count ? count - 1 : *sel + ROWS; break;
    case K_HOME: *sel = 0; break;
    case K_END:  *sel = count - 1; break;
  }
  scroll_to(*sel, top, count);
  sel_since = now_ms();
}
static int is_move(int key) { return key == K_UP || key == K_DOWN || key == K_PGUP || key == K_PGDN || key == K_HOME || key == K_END; }

static void leave(void) {
  if (changes(-1))
    confirm_open(C_EXIT, "Unsaved changes", "Save what you changed\nbefore leaving?", "Save", "Discard", "Stay", 0);
  else result = 10;
}

static void key_main(int key) {
  if (is_move(key)) { move(&main_sel, &main_top, main_count(), key); return; }
  if (key == K_CANCEL || key == K_BACKSPACE) { leave(); return; }
  if (key != K_OK && key != K_RIGHT && key != K_CHAR + ' ') return;
  if (main_sel < ncats) {
    if (cat_count(main_sel) == 0) return;
    mode = M_SECTION; sec_cat = main_sel; sec_sel = 0; sec_top = 0; sel_since = now_ms();
  } else if (key == K_RIGHT) {
    return;
  } else if (main_sel - ncats == MAIN_DEFAULTS) {
    confirm_open(C_DEFAULTS, "Back to the defaults", "Put every setting back to\nwhat the release ships with?", "No", "Yes", NULL, 0);
  } else {
    result = changes(-1) ? 0 : 10;
  }
}

static void key_section(int key) {
  Setting *s = sec_setting();
  if (is_move(key)) {
    int top = 0;                       // move() scrolls by settings; here rows count
    move(&sec_sel, &top, cat_count(sec_cat), key);
    sec_scroll();
    return;
  }
  switch (key) {
    case K_CANCEL: case K_BACKSPACE: mode = M_MAIN; sel_since = now_ms(); break;
    case K_LEFT:  adjust(s, -1, key); break;
    case K_RIGHT: if (s->type == T_LIST || s->type == T_TEXT) open_editor(s); else adjust(s, 1, key); break;
    case K_OK: case K_CHAR + ' ': open_editor(s); break;
  }
}

static void key_list(int key) {
  int count = list_non + list_noff;
  if (is_move(key)) { move(&list_sel, &list_top, count, key); return; }
  if (key == K_CANCEL || key == K_BACKSPACE) { mode = M_SECTION; sel_since = now_ms(); return; }
  if (count == 0) return;
  if (key == K_OK || key == K_CHAR + ' ') {
    if (list_sel < list_non) {
      // Unticked: out of the order, and the highlight stays where it was.
      for (int i = list_sel; i < list_non - 1; i++) list_on[i] = list_on[i + 1];
      list_non--;
    } else {
      char *w = list_off[list_sel - list_non];
      list_on[list_non] = w;
      list_sel = list_non++;
    }
    list_store();
    if (list_sel >= list_non + list_noff) list_sel = list_non + list_noff - 1;
    scroll_to(list_sel, &list_top, list_non + list_noff);
  } else if ((key == K_LEFT || key == K_RIGHT) && list_sel < list_non) {
    int to = list_sel + (key == K_LEFT ? -1 : 1);
    if (to < 0 || to >= list_non) return;
    char *t = list_on[to]; list_on[to] = list_on[list_sel]; list_on[list_sel] = t;
    list_sel = to;
    list_store();
    scroll_to(list_sel, &list_top, list_non + list_noff);
  }
}

static void key_pick(int key) {
  Setting *s = pop_s;
  if (is_move(key)) {
    int before = pick_sel, top = pick_top;
    switch (key) {
      case K_UP:   pick_sel = (pick_sel + s->en - 1) % s->en; break;
      case K_DOWN: pick_sel = (pick_sel + 1) % s->en; break;
      case K_PGUP: pick_sel = pick_sel - PICK_ROWS < 0 ? 0 : pick_sel - PICK_ROWS; break;
      case K_PGDN: pick_sel = pick_sel + PICK_ROWS >= s->en ? s->en - 1 : pick_sel + PICK_ROWS; break;
      case K_HOME: pick_sel = 0; break;
      case K_END:  pick_sel = s->en - 1; break;
    }
    if (pick_sel < top) top = pick_sel;
    if (pick_sel >= top + PICK_ROWS) top = pick_sel - PICK_ROWS + 1;
    pick_top = top;
    // The display follows the highlight: this is how an effect is tried out.
    if (pick_sel != before) { set_value(s, s->ev[pick_sel]); sel_since = now_ms(); }
  } else if (key == K_OK || key == K_CHAR + ' ') {
    set_value(s, s->ev[pick_sel]); popup = P_NONE;
  } else if (key == K_CANCEL || key == K_BACKSPACE) {
    set_value(s, pop_before); popup = P_NONE;
  }
}

static void key_num(int key) {
  Setting *s = pop_s;
  int digits = num_digits(s);
  switch (key) {
    case K_LEFT:  if (num_digit < digits - 1) num_digit++; break;
    case K_RIGHT: if (num_digit > 0) num_digit--; break;
    case K_UP:    num_val += pow10i(num_digit); break;
    case K_DOWN:  num_val -= pow10i(num_digit); break;
    case K_OK:    popup = P_NONE; break;
    case K_CANCEL: set_value(s, pop_before); popup = P_NONE; return;
    case K_BACKSPACE: num_val /= 10; break;
    case K_CHAR + '-': num_val = -num_val; break;
    default:
      // A keyboard's digits go in at the right, as on a calculator.
      if (key >= K_CHAR + '0' && key <= K_CHAR + '9' && abs(num_val) < 100000)
        num_val = num_val * 10 + (num_val < 0 ? -1 : 1) * (key - K_CHAR - '0');
      else return;
  }
  if (num_val < s->min) num_val = s->min;
  if (num_val > s->max) num_val = s->max;
  set_int(s, num_val);
}

// What an ini value cannot hold: it is written between double quotes and
// sourced by the daemon.
static int keys_allowed(int c) { return c >= 32 && c < 127 && !strchr("\"'\\`$", c); }
static void keys_add(int c) {
  size_t n = strlen(keys_buf);
  if (!keys_allowed(c) || (int)n >= pop_s->maxlen || n + 1 >= sizeof keys_buf) return;
  keys_buf[n] = (char)c; keys_buf[n + 1] = 0;
  set_value(pop_s, keys_buf);
}
static void keys_del(void) {
  size_t n = strlen(keys_buf);
  if (n) { keys_buf[n - 1] = 0; set_value(pop_s, keys_buf); }
}

static void key_keys(int key) {
  switch (key) {
    case K_UP:    keys_row = (keys_row + KEYS_ROWS) % (KEYS_ROWS + 1); break;
    case K_DOWN:  keys_row = (keys_row + 1) % (KEYS_ROWS + 1); break;
    case K_LEFT:
      if (keys_row == KEYS_ROWS) { int a = (keys_col * KA_N / KEYS_COLS + KA_N - 1) % KA_N; keys_col = (a * KEYS_COLS + KEYS_COLS / 2) / KA_N; }
      else keys_col = (keys_col + KEYS_COLS - 1) % KEYS_COLS;
      break;
    case K_RIGHT:
      if (keys_row == KEYS_ROWS) { int a = (keys_col * KA_N / KEYS_COLS + 1) % KA_N; keys_col = (a * KEYS_COLS + KEYS_COLS / 2) / KA_N; }
      else keys_col = (keys_col + 1) % KEYS_COLS;
      break;
    case K_CANCEL: set_value(pop_s, pop_before); popup = P_NONE; break;
    case K_BACKSPACE: keys_del(); break;
    case K_TAB: keys_row = KEYS_ROWS; keys_col = KEYS_COLS - 1; break;
    case K_OK:
      if (keys_row < KEYS_ROWS) {
        int c = keys_rows[keys_row][keys_col];
        if (keys_upper && c >= 'a' && c <= 'z') c -= 32;
        keys_add(c);
      } else switch (keys_col * KA_N / KEYS_COLS) {
        case KA_SHIFT:  keys_upper = !keys_upper; break;
        case KA_SPACE:  keys_add(' '); break;
        case KA_DELETE: keys_del(); break;
        case KA_CLEAR:  keys_buf[0] = 0; set_value(pop_s, keys_buf); break;
        case KA_DONE:   popup = P_NONE; break;
      }
      break;
    default:
      // A real keyboard types straight in, and its Enter then means Done.
      if (key >= K_CHAR) { keys_add(key - K_CHAR); keys_row = KEYS_ROWS; keys_col = KEYS_COLS - 1; }
  }
}

static void key_confirm(int key) {
  switch (key) {
    case K_LEFT:  confirm_sel = (confirm_sel + confirm_n - 1) % confirm_n; break;
    case K_RIGHT: confirm_sel = (confirm_sel + 1) % confirm_n; break;
    case K_CANCEL: case K_BACKSPACE: popup = P_NONE; break;
    case K_OK: case K_CHAR + ' ':
      popup = P_NONE;
      if (confirm_what == C_EXIT) {
        if (confirm_sel == 0) result = 0;
        if (confirm_sel == 1) {
          // Discarded: nothing differs from what is saved, so nothing goes out.
          for (int i = 0; i < nst; i++) setstr(&st[i].val, st[i].saved);
          result = 10;
        }
      } else if (confirm_what == C_DEFAULTS && confirm_sel == 1) {
        for (int i = 0; i < nst; i++) set_value(&st[i], st[i].def);
      }
      break;
  }
}

static void handle(int key) {
  switch (popup) {
    case P_PICK:    key_pick(key); break;
    case P_NUM:     key_num(key); break;
    case P_KEYS:    key_keys(key); break;
    case P_CONFIRM: key_confirm(key); break;
    default:
      switch (mode) {
        case M_MAIN:    key_main(key); break;
        case M_SECTION: key_section(key); break;
        case M_LIST:    key_list(key); break;
      }
  }
  if (popup == P_NONE) pop_s = NULL;
  focus_now();
}

// The canvas as a PGM, levels spread over 0..255: for tests and for looking.
static void dump(const char *path) {
  FILE *f = fopen(path, "wb");
  if (!f) return;
  fprintf(f, "P5\n%d %d\n255\n", CW, CH);
  for (int y = 0; y < CH; y++) for (int x = 0; x < CW; x++) fputc(cv[y][x] * 17, f);
  fclose(f);
}

// ===========================================================================
// The other screens: a menu, a question, a checklist, a command's output.
// One a run, driven by the scripts as they would drive dialog.
// ===========================================================================
static const char *o_title = "tty2oled+", *o_subtitle = "", *o_text = "", *o_buttons = "OK";
static const char *o_default = "", *o_oklabel = "Done";
static char **items = NULL;
static int nitems = 0;

static void draw_titlebar(void) {
  // The name in the panel's header face; anything longer in the bolder small one.
  const Font *f = text_w(&font_title, o_title) <= 140 ? &font_title : &font_head;
  int x = text(f, X0, Y0 + (f == &font_title ? 0 : (BAR_H - f->height) / 2), o_title, 15);
  if (*o_subtitle) text(&font_head, x + 6, Y0 + 3, o_subtitle, 9);
  if (*status_text) text_right(&font_small, X1, Y0 + 5, status_text, L_HELP);
  fill(X0, RULE1_Y, X1 - X0, 1, L_RULE);
}

static int write_text(const char *path, const char *textout) {
  FILE *f = path ? fopen(path, "w") : NULL;
  if (!f) return -1;
  fputs(textout, f);
  return fclose(f);
}

// ---- menu -----------------------------------------------------------------
static int gm_sel = 0, gm_top = 0;
static void draw_gmenu(void) {
  int count = nitems / 3;
  memset(cv, 0, sizeof cv);
  draw_titlebar();
  fill(X0, RULE2_Y, X1 - X0, 1, L_RULE);
  for (int r = 0; r < ROWS && gm_top + r < count; r++) {
    int i = gm_top + r, y = ROWS_Y + r * ROW_H, hot = i == gm_sel;
    if (hot) fill(X0, y, X1 - X0 - 4, ROW_H, L_BAR);
    text(&font_body, X0 + 8, y + (ROW_H - font_body.height) / 2, items[i * 3 + 1], hot ? L_HOT : L_TEXT);
    draw_chevron(WIDGET_R, y, hot ? 15 : L_DIM);
  }
  draw_scrollbar(gm_top, count);
  draw_help(*items[gm_sel * 3 + 2] ? items[gm_sel * 3 + 2] : o_text);
  draw_hint("UP/DOWN: MOVE   OK: OPEN   CANCEL: BACK");
  fb_present();
}
static int mode_menu(const char *out) {
  int count = nitems / 3;
  if (count < 1) return 12;
  for (int i = 0; i < count; i++) if (!strcmp(items[i * 3], o_default)) gm_sel = i;
  scroll_to(gm_sel, &gm_top, count);
  for (;;) {
    draw_gmenu();
    int key = key_read(1000);
    if (key == K_EOF) return 13;
    if (is_move(key)) move(&gm_sel, &gm_top, count, key);
    else if (key == K_CANCEL || key == K_BACKSPACE) return 10;
    else if (key == K_OK || key == K_RIGHT || key == K_CHAR + ' ')
      return write_text(out, items[gm_sel * 3]) == 0 ? 0 : 12;
  }
}

// ---- text, wrapped --------------------------------------------------------
// Lines of at most cols characters, broken at spaces and at newlines; each
// handed to put() with its number. Returns how many there were.
static int wrap(const char *s, int cols, void (*put)(int, const char *, int)) {
  int n = 0;
  while (*s) {
    int len = (int)strcspn(s, "\n"), take = len;
    if (take > cols) { take = cols; while (take > 0 && s[take] != ' ') take--; if (take == 0) take = cols; }
    if (put) put(n, s, take);
    n++;
    s += take;
    if (take < len) { while (*s == ' ') s++; } else if (*s == '\n') s++;
  }
  return n;
}

// ---- ask ------------------------------------------------------------------
#define ASK_COLS 46
#define ASK_PITCH 12
static int ask_sel = 0, ask_n = 0, ask_lines = 0;
static char ask_btn[4][24];
static void ask_put(int n, const char *s, int len) {
  char buf[64];
  // Centred in the room above the buttons, when there is room to centre in.
  int room = 13, y = ROWS_Y + 4 + (ask_lines < room ? (room - ask_lines) / 2 : 0) * ASK_PITCH;
  if (n >= room) return;
  snprintf(buf, sizeof buf, "%.*s", len, s);
  text(&font_body, X0 + 6, y + n * ASK_PITCH, buf, L_VALUE);
}
static void draw_ask(void) {
  memset(cv, 0, sizeof cv);
  draw_titlebar();
  ask_lines = wrap(o_text, ASK_COLS, NULL);
  wrap(o_text, ASK_COLS, ask_put);
  int bw = (X1 - X0) / (ask_n > 2 ? ask_n : 2), bx0 = X0 + ((X1 - X0) - bw * ask_n) / 2;
  for (int i = 0; i < ask_n; i++) {
    int bx = bx0 + i * bw, hot = i == ask_sel;
    if (hot) fill(bx + 3, 196, bw - 6, 18, 6);
    box(bx + 3, 196, bw - 6, 18, hot ? 15 : L_DIM);
    text_centre(&font_body, bx, bw, 200, ask_btn[i], hot ? 15 : L_TEXT);
  }
  draw_hint(ask_n > 1 ? "LEFT/RIGHT: CHOOSE   OK: PRESS   CANCEL: BACK" : "OK: CONTINUE");
  fb_present();
}
static int mode_ask(const char *out) {
  const char *b = o_buttons;
  while (*b && ask_n < 4) {
    int len = (int)strcspn(b, "|");
    snprintf(ask_btn[ask_n++], sizeof ask_btn[0], "%.*s", len, b);
    b += len;
    if (*b == '|') b++;
  }
  if (ask_n == 0) return 12;
  ask_sel = atoi(o_default);
  if (ask_sel < 0 || ask_sel >= ask_n) ask_sel = 0;
  for (;;) {
    char idx[8];
    draw_ask();
    int key = key_read(1000);
    if (key == K_EOF) return 13;
    if (key == K_LEFT) ask_sel = (ask_sel + ask_n - 1) % ask_n;
    else if (key == K_RIGHT) ask_sel = (ask_sel + 1) % ask_n;
    else if (key == K_CANCEL || key == K_BACKSPACE) return 10;
    else if (key == K_OK || key == K_CHAR + ' ') {
      snprintf(idx, sizeof idx, "%d", ask_sel);
      return write_text(out, idx) == 0 ? 0 : 12;
    }
  }
}

// ---- check ----------------------------------------------------------------
static int ck_sel = 0, ck_top = 0;
static unsigned char ck_on[MAX_SETTINGS];
static void draw_gcheck(void) {
  int count = nitems / 3;
  memset(cv, 0, sizeof cv);
  draw_titlebar();
  fill(X0, RULE2_Y, X1 - X0, 1, L_RULE);
  for (int r = 0; r < ROWS && ck_top + r <= count; r++) {
    int i = ck_top + r, y = ROWS_Y + r * ROW_H, hot = i == ck_sel;
    int ty = y + (ROW_H - font_body.height) / 2;
    if (hot) fill(X0, y, X1 - X0 - 4, ROW_H, L_BAR);
    if (i < count) {
      draw_check(X0 + 6, y, ck_on[i], hot ? 15 : ck_on[i] ? L_VALUE : L_DIM);
      text_window(&font_body, X0 + 22, ty, WIDGET_R - X0 - 22, items[i * 3 + 1], hot ? L_HOT : ck_on[i] ? L_VALUE : L_DIM + 2, -1, 0);
    } else {
      // The way on: the last row, apart from the boxes.
      if (r > 0) fill(X0 + 8, y, X1 - X0 - 20, 1, L_TRACK);
      text(&font_body, X0 + 8, ty, o_oklabel, hot ? L_HOT : L_TEXT);
      draw_chevron(WIDGET_R, y, hot ? 15 : L_DIM);
    }
  }
  draw_scrollbar(ck_top, count + 1);
  draw_help(o_text);
  draw_hint("OK: TICK   LEFT: NONE   RIGHT: ALL   CANCEL: BACK");
  fb_present();
}
static int mode_check(const char *out) {
  int count = nitems / 3;
  if (count < 1 || count > MAX_SETTINGS) return 12;
  for (int i = 0; i < count; i++) ck_on[i] = !strcmp(items[i * 3 + 2], "on");
  for (;;) {
    draw_gcheck();
    int key = key_read(1000);
    if (key == K_EOF) return 13;
    if (is_move(key)) move(&ck_sel, &ck_top, count + 1, key);
    else if (key == K_CANCEL || key == K_BACKSPACE) return 10;
    else if (key == K_LEFT)  memset(ck_on, 0, (size_t)count);
    else if (key == K_RIGHT) memset(ck_on, 1, (size_t)count);
    else if (key == K_OK || key == K_CHAR + ' ') {
      if (ck_sel < count) { ck_on[ck_sel] = !ck_on[ck_sel]; continue; }
      FILE *f = out ? fopen(out, "w") : NULL;
      if (!f) return 12;
      for (int i = 0, first = 1; i < count; i++)
        if (ck_on[i]) { fprintf(f, "%s%s", first ? "" : " ", items[i * 3]); first = 0; }
      return fclose(f) == 0 ? 0 : 12;
    }
  }
}

// ---- run ------------------------------------------------------------------
// A command's output, a line a row, the newest at the bottom. "==> " starts a
// step and "*** " is something going wrong - how every script here talks -
// and both are drawn brighter, without the marker.
#define LOG_MAX  600
#define LOG_COLS 45
#define LOG_ROWS 15
#define LOG_PITCH 12
#define SWEEP_Y  214
#define SWEEP_TAIL 64
enum { LK_PLAIN, LK_STEP, LK_ERROR };
static char lg[LOG_MAX][LOG_COLS + 1];
static unsigned char lg_kind[LOG_MAX];
static int lg_n = 0, lg_back = 0, lg_cur_kind = LK_PLAIN;
static char lg_raw[400];
static int lg_rawn = 0, lg_esc = 0;

#define LK_MORE 4                        // the rest of a line that was wrapped: no marker of its own
static void lg_put(int n, const char *s, int len) {
  if (lg_n == LOG_MAX) {
    memmove(lg, lg + 1, sizeof lg - sizeof lg[0]);
    memmove(lg_kind, lg_kind + 1, sizeof lg_kind - 1);
    lg_n--;
  }
  snprintf(lg[lg_n], sizeof lg[0], "%.*s", len, s);
  lg_kind[lg_n++] = (unsigned char)(lg_cur_kind | (n ? LK_MORE : 0));
  if (lg_back) lg_back++;                 // reading further up: stay there
}
static void lg_commit(void) {
  char *s = lg_raw;
  lg_raw[lg_rawn] = 0;
  lg_rawn = 0;
  lg_cur_kind = LK_PLAIN;
  if (!strncmp(s, "==> ", 4)) { lg_cur_kind = LK_STEP; s += 4; }
  else if (!strncmp(s, "*** ", 4)) { lg_cur_kind = LK_ERROR; s += 4; }
  else while (s[0] == ' ' && s[1] == ' ') s++;   // the scripts' indent: one space is enough here
  if (!*s || !s[strspn(s, " ")]) return;         // blank lines are the scripts' spacing, not ours
  wrap(s, LOG_COLS, lg_put);
}
static void lg_feed(const char *buf, int n) {
  for (int i = 0; i < n; i++) {
    unsigned char c = (unsigned char)buf[i];
    if (lg_esc) {                          // a colour or cursor sequence: not text
      if (lg_esc == 1) lg_esc = c == '[' ? 2 : 0;
      else if (c >= 0x40 && c <= 0x7e) lg_esc = 0;
      continue;
    }
    if (c == 0x1b) lg_esc = 1;
    else if (c == '\n') lg_commit();
    else if (c == '\r') lg_rawn = 0;       // a line redrawn in place: the last version counts
    else if (c == '\t') { if (lg_rawn < (int)sizeof lg_raw - 1) lg_raw[lg_rawn++] = ' '; }
    else if (c >= 32 && c < 127 && lg_rawn < (int)sizeof lg_raw - 1) lg_raw[lg_rawn++] = (char)c;
  }
}

static void draw_run(int running, int code) {
  memset(cv, 0, sizeof cv);
  draw_titlebar();
  int last = lg_n - lg_back, first = last - LOG_ROWS;
  if (first < 0) first = 0;
  for (int i = first, r = 0; i < last; i++, r++) {
    int y = ROWS_Y + r * LOG_PITCH, more = lg_kind[i] & LK_MORE, k = lg_kind[i] & ~LK_MORE;
    if (k != LK_PLAIN && !more) fill(X0 + 1, y + 3, 3, 3, 15);
    text(&font_body, X0 + (k == LK_PLAIN ? 12 : 8), y, lg[i], k == LK_PLAIN ? L_TEXT : 15);
  }
  if (lg_n > LOG_ROWS) {
    int h = LOG_ROWS * LOG_PITCH, th = h * LOG_ROWS / lg_n, ty = h * first / lg_n;
    fill(X1 - 2, ROWS_Y, 1, h, L_TRACK);
    fill(X1 - 3, ROWS_Y + ty, 3, th < 6 ? 6 : th, 11);
  }
  if (running) {
    // The panel's own busy bar: a bright head and a tail fading behind it.
    int span = X1 - X0, head = (int)(now_ms() / 8 % (span + SWEEP_TAIL));
    for (int i = 0; i < SWEEP_TAIL; i++) {
      int x = X0 + head - i;
      if (x >= X0 && x < X1) fill(x, SWEEP_Y, 1, 3, 15 - i / 4);
    }
    draw_hint("WORKING");
  } else {
    char buf[64];
    fill(X0, SWEEP_Y + 1, X1 - X0, 1, L_RULE);
    if (code == 0) snprintf(buf, sizeof buf, "DONE");
    else snprintf(buf, sizeof buf, "STOPPED WITH AN ERROR (%d)", code);
    text(&font_small, X0, HINT_Y, buf, 15);
    draw_hint(lg_n > LOG_ROWS ? "UP/DOWN: READ BACK   OK: CONTINUE" : "OK: CONTINUE");
  }
  fb_present();
}

static int mode_run(int nowait) {
  int p[2], code = 0, running = 1;
  char buf[1024];
  if (nitems < 1 || pipe(p) != 0) return 12;
  pid_t pid = fork();
  if (pid < 0) return 12;
  if (pid == 0) {
    // Its words come here; the keys stay ours, so it reads nothing.
    int nul = open("/dev/null", O_RDONLY);
    if (nul >= 0) { dup2(nul, 0); close(nul); }
    dup2(p[1], 1); dup2(p[1], 2); close(p[0]); close(p[1]);
    signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGHUP, SIG_DFL); signal(SIGPIPE, SIG_DFL);
    execvp(items[0], items);
    fprintf(stderr, "*** cannot run %s\n", items[0]);
    _exit(127);
  }
  close(p[1]);
  fcntl(p[0], F_SETFL, O_NONBLOCK);
  fcntl(p[0], F_SETFD, FD_CLOEXEC);

  for (;;) {
    ssize_t n;
    while ((n = read(p[0], buf, sizeof buf)) > 0) lg_feed(buf, (int)n);
    if (running) {
      int st_;
      // Its exit is the end, not the pipe's: a daemon it started may hold the
      // pipe open for good.
      if (waitpid(pid, &st_, WNOHANG) == pid) {
        while ((n = read(p[0], buf, sizeof buf)) > 0) lg_feed(buf, (int)n);
        if (lg_rawn) lg_commit();
        running = 0;
        code = WIFEXITED(st_) ? WEXITSTATUS(st_) : 1;
        // Nothing to read and nothing wrong: on to the next screen.
        if (nowait && code == 0) break;
      }
    }
    draw_run(running, code);
    if (!running && in_eof) break;
    int key = running && in_eof ? (usleep(40000), K_NONE) : key_read(running ? 40 : 1000);
    int most = lg_n > LOG_ROWS ? lg_n - LOG_ROWS : 0;
    if (key == K_UP)   lg_back = lg_back < most ? lg_back + 1 : most;
    if (key == K_DOWN) lg_back = lg_back > 0 ? lg_back - 1 : 0;
    if (key == K_PGUP) lg_back = lg_back + LOG_ROWS < most ? lg_back + LOG_ROWS : most;
    if (key == K_PGDN) lg_back = lg_back > LOG_ROWS ? lg_back - LOG_ROWS : 0;
    if (!running && (key == K_OK || key == K_CANCEL || key == K_CHAR + ' ')) break;
  }
  close(p[0]);
  draw_run(0, code);
  return code;
}

// ---- the editor -----------------------------------------------------------
static int mode_settings(const char *table, const char *out, const char *preview) {
  if (!table || !out) { fprintf(stderr, "tty2oledplus_config: --table and --out are needed\n"); return 12; }
  pv_start(preview);
  // Changed before this run and not saved is told to the display again: it
  // starts from what is saved.
  for (int i = 0; i < nst; i++) if (changed(&st[i])) pv_touch(&st[i]);
  focus_now();
  sel_since = now_ms();

  int dirty = 1;
  while (result < 0) {
    if (dirty || animating) draw();
    dirty = 0;
    int waiting = pv_flush(0);
    int key = key_read(animating ? 40 : waiting ? 60 : 1000);
    if (key == K_EOF) { result = 13; break; }
    if (key == K_NONE) continue;
    handle(key);
    dirty = 1;
  }
  draw();
  pv_stop();
  if (write_out(out) != 0) { fprintf(stderr, "tty2oledplus_config: cannot write %s\n", out); return 12; }
  return result;
}

int main(int argc, char **argv) {
  const char *table = NULL, *out = NULL, *preview = NULL, *dev = "/dev/fb0", *geometry = NULL, *dumpto = NULL;
  const char *what = "settings";
  int nowait = 0, i = 1, rc;
  if (argc > 1 && argv[1][0] != '-') what = argv[i++];
  for (; i < argc; i++) {
    const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
    if (!strcmp(a, "--")) { items = argv + i + 1; nitems = argc - i - 1; break; }
    if (!strcmp(a, "--keep")) { keep = 1; continue; }
    if (!strcmp(a, "--nowait")) { nowait = 1; continue; }
    if (!v) { fprintf(stderr, "tty2oledplus_config: %s needs a value\n", a); return 12; }
    if (!strcmp(a, "--table")) table = v;
    else if (!strcmp(a, "--out")) out = v;
    else if (!strcmp(a, "--preview")) preview = v;
    else if (!strcmp(a, "--status")) status_text = v;
    else if (!strcmp(a, "--title")) o_title = v;
    else if (!strcmp(a, "--subtitle")) o_subtitle = v;
    else if (!strcmp(a, "--text")) o_text = v;
    else if (!strcmp(a, "--buttons")) o_buttons = v;
    else if (!strcmp(a, "--default")) o_default = v;
    else if (!strcmp(a, "--ok-label")) o_oklabel = v;
    else if (!strcmp(a, "--fb")) dev = v;
    else if (!strcmp(a, "--geometry")) geometry = v;
    else if (!strcmp(a, "--dump")) dumpto = v;
    else { fprintf(stderr, "tty2oledplus_config: unknown option %s\n", a); return 12; }
    i++;
  }
  int is_settings = !strcmp(what, "settings");
  if (is_settings && table && load_table(table) != 0) {
    fprintf(stderr, "tty2oledplus_config: no settings in %s\n", table);
    return 12;
  }
  if (fb_open(dev, geometry) != 0) {
    fprintf(stderr, "tty2oledplus_config: %s is not a framebuffer of 320x240 or more, 16 or 32 bits\n", dev);
    return 12;
  }
  if (!strcmp(what, "probe")) return 0;

  signal(SIGPIPE, SIG_IGN);
  if (!strcmp(what, "release")) {
    // The console back as a console: text mode, and nothing of ours on it.
    in_tty = isatty(0); tty_graphics = 1; keep = 0;
    memset(fb.mem, 0, (size_t)fb.stride * (size_t)fb.h);
    tty_restore();
    return 0;
  }
  tty_setup();

  if (is_settings)                    rc = mode_settings(table, out, preview);
  else if (!strcmp(what, "menu"))     rc = nitems % 3 ? 12 : mode_menu(out);
  else if (!strcmp(what, "ask"))      rc = mode_ask(out);
  else if (!strcmp(what, "check"))    rc = nitems % 3 ? 12 : mode_check(out);
  else if (!strcmp(what, "run"))      rc = mode_run(nowait);
  else { fprintf(stderr, "tty2oledplus_config: unknown screen %s\n", what); rc = 12; }

  if (dumpto) dump(dumpto);
  if (!keep) {
    memset(cv, 0, sizeof cv);
    if (!geometry) fb_present();
  }
  tty_restore();
  return rc;
}
