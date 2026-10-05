# Your images

This is the default image folder: both the window and
`.\screen4screen.ps1` open on it with no argument, so a fresh clone works
straight away.

```powershell
.\screen4screen.ps1 -Once -Verbose
```

Four ISC backgrounds ship here, one per kind of screen, already named for the lookup:

```
wallpapers/
  5120x2160.webp     ultrawide at the desk (exact match)
  ratio-16x9.webp    any 1080p / 1440p / 4K external
  ratio-8x5.webp     any 16:10 laptop panel (1920x1200, 2560x1600, ...)
  default.webp       anything else, from a 1080p image
```

Add your own next to them, for instance `3440x1440.webp` for a 34-inch
ultrawide, which wins over `default` because the exact resolution is
tried first. A folder works too: `3440x1440/` holding several images picks
one of them at random.

Everything else you put here stays git-ignored, including the
`wallpapers.json` written when you pin an image to a monitor. Point the
tool somewhere else entirely with `-WallpaperRoot`, or with the folder
picker in the window.
