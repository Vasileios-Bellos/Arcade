# v1.0.0 - Arcade

15 arcade games built entirely in MATLAB - 8 timeless classics and 7 originals. No toolboxes, no external dependencies, no imported assets. Every pixel is drawn using native MATLAB graphics.

## Games

**Classics**: Pong, Breakout, Snake, Tetris, Asteroids, Space Invaders, Flappy Bird, Fruit Ninja

**Originals**: Target Practice, Firefly Chase, Flick It!, Juggler, Orbital Defense, Shield Guardian, Rail Shooter

## Highlights

- Neon-styled launcher with animated starfield menu, persistent high scores, and automatic display scaling
- Frame-rate-independent physics (`DtScale = rawDt * RefFPS`) - consistent from 20 to 240+ FPS
- Every game runs standalone: `games.Pong().play()`
- HTML5 Canvas port (`index.html`) - all 15 games in a single self-contained file, verified identical physics and scoring
- Subclassable launcher - override `buildRegistry` for custom game sets

## Downloads

| File | Description |
|------|-------------|
| `Arcade.mltbx` | MATLAB Toolbox - install via Add-On Manager |
| `ArcadeInstaller.exe` | Windows installer - downloads MATLAB Runtime automatically |
| Source code (zip) | Full repository with HTML port, docs, recording scripts |

## Requirements

- **MATLAB R2022b** or later (toolbox and source)
- No additional toolboxes
- Windows installer requires MATLAB Runtime R2025b (downloaded automatically)

## Quick Start

```matlab
Arcade();           % launch the menu
games.Pong().play();  % or play any game directly
```
