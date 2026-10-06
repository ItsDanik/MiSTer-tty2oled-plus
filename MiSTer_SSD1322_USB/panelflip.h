/*
  panelflip.h - a panel mounted the other way up

  Part of the tty2oled game-metadata fork.

  The library turns a display by rotation 2: every drawing call and
  draw4bppBitmap() then write the framebuffer upside down. That only holds
  while nothing else touches the framebuffer, and most of this fork does - a
  layout is drawn, copied out of the framebuffer and handed back as a picture
  (metadisplay.h), the icon is copied into it by rows, the fades write it a
  byte at a time. On a turned panel the copied-out layout was turned a second
  time, the icon landed in the opposite corner and the text beside it stayed
  where it was (0.8.7b and before, with XROTATE, ROTATE="yes" or a tilt
  sensor).

  So the library's rotation stays 0 and the framebuffer is always the picture
  the right way up, the same bytes as a .gsc. The half turn happens once, on
  the way to the panel: display() reverses the framebuffer, sends it, and
  reverses it back.

  A template, so the host tests can put it over a stand-in for the library's
  class (tests/firmware/test_meta_layout.cpp).
*/

#ifndef PANELFLIP_H
#define PANELFLIP_H

#include <stdint.h>
#include <stddef.h>

// A 4bpp picture turned 180 degrees, in place: the bytes in reverse order and
// the two pixels in each swapped. Doing it twice is the picture again.
static inline void panel_flipBytes(uint8_t *buf, size_t n) {
  if (!buf) return;
  for (size_t i = 0, j = n; i < j; i++) {
    j--;
    uint8_t a = buf[i], b = buf[j];
    buf[i] = (uint8_t)((b << 4) | (b >> 4));
    if (i != j) buf[j] = (uint8_t)((a << 4) | (a >> 4));
  }
}

template <class Panel>
class FlippablePanel : public Panel {
public:
  using Panel::Panel;

  void setFlipped(bool on) { panelFlipped = on; }
  bool flipped(void) const { return panelFlipped; }

  void display(void) {
    if (!panelFlipped) { Panel::display(); return; }
    size_t n = (size_t)this->WIDTH * (size_t)this->HEIGHT / 2;
    // The dirty window turns with the picture.
    int16_t x1 = this->window_x1, y1 = this->window_y1;
    this->window_x1 = (int16_t)(this->WIDTH  - 1 - this->window_x2);
    this->window_y1 = (int16_t)(this->HEIGHT - 1 - this->window_y2);
    this->window_x2 = (int16_t)(this->WIDTH  - 1 - x1);
    this->window_y2 = (int16_t)(this->HEIGHT - 1 - y1);
    panel_flipBytes(this->buffer, n);
    Panel::display();
    panel_flipBytes(this->buffer, n);
  }

private:
  bool panelFlipped = false;
};

#endif  // PANELFLIP_H
