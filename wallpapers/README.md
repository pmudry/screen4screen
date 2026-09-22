# Your images

This is the default image folder: both the window and
`.\screen4screen.ps1` open on it with no argument, so a fresh clone works
straight away.

```powershell
.\screen4screen.ps1 -Once -Verbose
```

Three ISC backgrounds ship here, already named for the lookup:

```
wallpapers/
  5120x2160.webp     ultrawide at the desk (exact match)
  ratio-16x9.webp    any 1080p / 1440p / 4K external
  default.webp       anything else, including 16:10 laptop panels
```

Add your own next to them, for instance `1920x1200.webp` for a 16:10
laptop panel, which wins over `default` because the exact resolution is
tried first. A folder works too: `1920x1200/` holding several images picks
one of them at random.

Everything else you put here stays git-ignored, including the
`wallpapers.json` written when you pin an image to a monitor. Point the
tool somewhere else entirely with `-WallpaperRoot`, or with the folder
picker in the window.
