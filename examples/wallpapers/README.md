# Example layout

Drop images here to try the script against this folder:

```powershell
.\Set-WallpaperByResolution.ps1 -Once -Verbose -WallpaperRoot .\examples\wallpapers
```

Three ISC backgrounds ship here, already named for the lookup:

```
examples/wallpapers/
  5120x2160.webp     ultrawide at the desk (exact match)
  ratio-16x9.webp    any 1080p / 1440p / 4K external
  default.webp       anything else, including 16:10 laptop panels
```

Add your own next to them, for instance `1920x1200.webp` for a 16:10
laptop panel, which wins over `default` because the exact resolution is
tried first.

Any other image dropped in this folder stays git-ignored.
