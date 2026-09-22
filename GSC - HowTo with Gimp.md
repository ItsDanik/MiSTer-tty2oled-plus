------------------------ ENGLISH ------------------------

Have a look for a banner or logo of the desired picture which roughly could
be scaled down to 256\*64 pixels without losing too much details and contrast.
Start Gimp, load or insert the found picture and

- if there is a transparent layer, remove it by /Layer/Transparency/Remove Alpha Channel
- /Colours/Desaturate/Colour to Grey
~~- /Colours/Invert~~ Let image2lcd do the invert
- /Image/Mode/Indexed/Generate optimum palette (16 Colours)
- /Image/Scale Image/256\*64 if possible. It might be needful to resize
  the picture non-proportional. Otherwise resize to 256\*Y or X\*64 and
- use /Image/Canvas Size afterwards to move the whole thing so that it fits
- /File/Export as/ and save your work as GIF
- Start image2lcd, load your GIF, check *Reverse color* and save the result as \*.C file
  without "head data"
- Edit the created \*.C file and replace the line
  "const unsigned char gImage_x[8192]" by

//  
//  
const unsigned char _bits[8192] PROGMEM = {

Done.
------------------------ ------ ------------------------
![image2lcd settings](https://github.com/venice1200/MiSTer_tty2oled/blob/main/Pictures/image2lcd.png?raw=true)
