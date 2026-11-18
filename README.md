# DeskCat

A little pixel-art cat that lives on your macOS desktop. She's modeled after a real cat: mostly white with big black spots, a black tail, and a black cap that comes down to the outer edges of her yellow eyes, with a white triangle between them.

## Build and run

Needs macOS 13+ and the Swift toolchain (Xcode or the Command Line Tools).

```bash
./build.sh --install
```

That builds `DeskCat.app` (with her pixel-art icon), copies it into Applications, and opens it. After that you can launch her from Spotlight or Launchpad like any app. Plain `./build.sh` just builds the app in this folder.

She has no Dock icon; she lives in the 🐈 menu bar item and her right-click menu.

- **Respawn:** choose "Respawn" from her menu, or just open DeskCat again. Either one drops her back in from the top of the screen your cursor is on, and never starts a second cat.
- **Open at Login:** toggle it in her menu.
- **Quit:** "Quit DeskCat" in her menu.

## What she does

- Walks, sits, naps, blinks, and runs after your cursor.
- Sometimes swats at your cursor when it comes near.
- Climbs onto the tops of your other windows, walks along them, and hops off. If a window moves or closes under her, she falls and lands on her feet.
- Sometimes conjures ghostly stairs and walks up them (the steps fade behind her), or leaps onto a floating plank.
- Plays with a yarn ball. You can click it or fling it, too.

## Interacting

- **Click** her to pet her.
- **Drag** her to pick her up by the scruff. She swings as you move. Let go mid-motion to toss her.
- **Right-click** her, or use the menu bar item, for: Pet, Come Here, Nap Time, Climb Stairs, Jump Up, Play with Yarn, Respawn, Always on Top, Open at Login, Quit.

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
DeskCat.app/Contents/MacOS/DeskCat --iconset out.iconset        # render the app icon images
DeskCat.app/Contents/MacOS/DeskCat --trace stairs|jump|yarn     # log state/position while running
```
