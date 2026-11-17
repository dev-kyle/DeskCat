# DeskCat

A little pixel-art cat that lives on your macOS desktop. She's modeled after a real cat: mostly white with big black spots, a black tail, and a black cap that comes down to the outer edges of her yellow eyes, with a white triangle between them.

## Build and run

Needs macOS 13+ and the Swift toolchain (Xcode or the Command Line Tools).

```bash
./build.sh
open DeskCat.app
```

She has no Dock icon. Quit from the 🐈 menu bar item or by right-clicking her. To start her at login, add `DeskCat.app` in System Settings → General → Login Items.

## What she does

- Walks, sits, naps, blinks, and runs after your cursor.
- Sometimes swats at your cursor when it comes near.
- Climbs onto the tops of your other windows, walks along them, and hops off. If a window moves or closes under her, she falls and lands on her feet.
- Sometimes conjures ghostly stairs and walks up them (the steps fade behind her), or leaps onto a floating plank.
- Plays with a yarn ball. You can click it or fling it, too.

## Interacting

- **Click** her to pet her.
- **Drag** her to pick her up by the scruff. She swings as you move. Let go mid-motion to toss her.
- **Right-click** her, or use the menu bar item, for: Pet, Come Here, Nap Time, Climb Stairs, Jump Up, Play with Yarn, Always on Top, Quit.

## How it works

Everything is in `DeskCat.swift`. Each pose is built from simple shapes (ellipses, tapered curves, triangles) in "design units", rasterized onto a 28×30 pixel grid, cel-shaded with a small palette, outlined, and drawn at 4pt per pixel. The face (eyes, nose, blush) is stamped on as hand-placed pixels.

Window ledges come from `CGWindowListCopyWindowInfo` (positions and sizes only), so no Screen Recording permission is needed.

### Handy knobs

- `S`: points per pixel (overall size).
- `Raster.headScale`: head size.
- `whiteTones` / `blackTones` / `pinkTones`: palette.
- `CatView.stepRun` / `CatView.stepRise`: stair size.

### Debug flags

```bash
DeskCat.app/Contents/MacOS/DeskCat --snapshot out.png           # sprite sheet of all poses
DeskCat.app/Contents/MacOS/DeskCat --snapshot out.png --zoom    # close-up of a few poses
DeskCat.app/Contents/MacOS/DeskCat --compare-head out.png       # head sizes side by side
DeskCat.app/Contents/MacOS/DeskCat --ledges                     # print the ledges she sees
DeskCat.app/Contents/MacOS/DeskCat --trace stairs|jump|yarn     # log state/position while running
```
