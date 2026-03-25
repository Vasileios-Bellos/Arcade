# v1.0.1 - Bug Fixes

## Collision Fixes
- Pong + Breakout: parametric contact point on paddle collisions
- Breakout: swept paddle collision for extra balls
- Asteroids: bullet-rock sweep uses DtScale-scaled step

## Trail System
- FlickIt + Juggler: DtScale trail accumulator for fps-independent trail length
- FlickIt + Juggler: trail no longer resets on flick/bounce
- All 4 ball games now have identical trail behavior across MATLAB and HTML

## Visual Fixes
- SpaceInvaders: wave and lives text brought to front
- RailShooter: wave text lowered to avoid overlap with combo display

## Other
- Snake: food spawn moved after body update
- Breakout: serve countdown runs concurrently with level announce
- Legacy comment cleanup

---

# v1.0.0 - Initial Release

15 arcade games built entirely in MATLAB - 8 timeless classics and 7 originals. No toolboxes, no external dependencies, no imported assets. Every pixel is drawn using native MATLAB graphics.

## Games

**Classics**: Pong, Breakout, Snake, Tetris, Asteroids, Space Invaders, Flappy Bird, Fruit Ninja

**Originals**: Target Practice, Firefly Chase, Flick It!, Juggler, Orbital Defense, Shield Guardian, Rail Shooter

## Highlights

- Neon-styled launcher with animated starfield menu, persistent high scores, and automatic display scaling
- Frame-rate-independent physics (`DtScale = rawDt * RefFPS`) - consistent from 10 to 240+ FPS
- Every game runs standalone: `games.Pong().play();`
- HTML5 Canvas port - all 15 games in a single self-contained file, verified identical physics and scoring
- Subclassable - override `buildRegistry` and `getMenuTitles` for custom game sets
- Extensible - add your own games by subclassing `engine.GameBase`

## Requirements

- **MATLAB R2022b** or later
- No additional toolboxes
- Windows installer requires MATLAB Runtime R2025b (downloaded automatically)
