# pics/user

Your own core artwork. Nothing here is ever replaced by an update — that is
the whole point of the folder.

A banner is a 256x64 `.gsc`, named after the core name MiSTer writes to
`/tmp/CORENAME` (which `tools/tty2oled-diag.sh` prints): `NES.gsc`,
`MegaDrive.gsc`, `nbajam.gsc`.

```sh
./tools/png2gsc.py --banner --out pics/user/NES.gsc nes.png
./tools/deploy-mister.sh --pics
```

With `PRIORITIZE_USER_BANNERS="yes"` (the default) a banner here is used
instead of the one in `pics/banner`. Alternatives of your own go here too, as
`NES_alt1.gsc`, `NES_alt2.gsc` and so on; they are only diced between when
`RANDOMIZE_ALT_BANNERS="yes"`.

Icons are not banners and do not belong here: they are 86x64, they live in
`pics/icon`, and a file of the same name in this folder would be
indistinguishable from a banner.
