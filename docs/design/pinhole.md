# Pinhole, the app's mark

A disc with a hole. The design is the owner's canvas "小孔 Pinhole" (claude.ai/artifact/C4YZAczVF4c3nM62RQJJfJ);
the app draws it in three places, all from the same geometry.

| | |
|---|---|
| Disc | R, its diameter 824 × 0.618 on the 1024 icon grid |
| Hole | radius R/5, its center R/φ from the disc's, up and to the right at 45° |
| Ink | ultramarine #2A3AA0, #6B7AE6 in dark mode |
| Paper | #FBF9F4 to #ECE8DE, with a rim of black at 7% |

## App icon

`node scripts/make_app_icon.mjs` writes every PNG of `AppIcon.appiconset`. Small sizes are corrected as the design
draws them: 64 and under lose the shadow and the gradient, 32 and under enlarge the disc and the hole. The 1024
master matches the design's own SVG pixel for pixel.

## Menu bar

An 18-point template image (`MenuBarIcon`), so macOS tints it for light and dark menu bars. At rest it is a ring
with the hole as a dot; while the mini window is open it is the filled disc with the hole cut out, its hole widened
to R/4.3 so it stays open at 1×.

## Reply mark

`SpotMark` fills the `Pinhole` shape with the hole cut out. Marks under 32 points across use the R/4.3 hole.
It is the one color besides the system accent color, as the app's own mark.
