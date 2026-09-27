# pics/user

Your own core artwork. Nothing here is ever replaced by an update — that is
the whole point of the folder.

A banner is a 256x64 `.gsc`, named after the core name MiSTer writes to
`/tmp/CORENAME` (which `tools/tty2oled-diag.sh` prints): `NES.gsc`,
`MegaDrive.gsc` - or, for an arcade game, its MAME set name, which is what
MiSTer writes there for one: `nbajam.gsc`.

```sh
./tools/png2gsc.py --banner --out pics/user/NES.gsc nes.png
./tools/deploy-mister.sh --pics
```

With `PRIORITIZE_USER_BANNERS="yes"` (the default) a banner here is used
instead of the one in `pics/banner`, or an arcade game's wheel logo in
`pics/arcade`.

Icons are not banners and do not belong here: they are 86x64, they live in
`pics/icon`, and a file of the same name in this folder would be
indistinguishable from a banner.
