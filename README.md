# MATLAB Arcade

15 arcade games built entirely in MATLAB. Includes both timeless classic and originals. No toolboxes, no external dependencies, no imported assets. Every pixel is drawn using native MATLAB graphics.

Developed using [MATLAB MCP Server](https://github.com/matlab/matlab-mcp-core-server).

A neon-styled launcher with an animated starfield menu, persistent high scores, frame-rate-independent physics, and automatic display scaling ties everything together. Pick up and play with mouse, keyboard, or both.

<!-- TODO: Replace with actual GIF/screenshot -->
<!-- <p align="center"><img src="assets/arcade_demo.gif" alt="MATLAB Arcade" width="70%"></p> -->

## Quick Start

```matlab
Arcade()
```

Or launch any game directly:

```matlab
games.Pong().play()
games.Tetris().play()
games.Asteroids().play()
```

## The Classics

Eight legendary arcade games, recreated from scratch in pure MATLAB.

| # | Game | Controls | |
|:-:|------|:--------:|---|
| 1 | **Pong** | Mouse / Keyboard | AI opponent that adapts as you score. Paddle-angle physics, rally escalation. First to 10 wins. |
| 2 | **Breakout** | Mouse / Keyboard | 5 levels of bricks with power-ups and multi-ball. Paddle angle controls the ricochet. |
| 3 | **Snake** | Mouse / Keyboard | Grid-based with wrap-around walls. Arrow keys or mouse-guided movement. |
| 4 | **Tetris** | Mouse / Keyboard | Full SRS rotation with wall kicks, ghost piece, 3-piece preview, and instant hard drop. |
| 5 | **Asteroids** | Mouse / Keyboard | Wireframe polygons that split on impact. Auto-fire crosshair tracks your cursor. |
| 6 | **Space Invaders** | Mouse / Keyboard | 3 alien types, 5 wave formations, destructible shields, and power-up drops. |
| 7 | **Flappy Bird** | Mouse / Keyboard | Pipe gaps tighten and scroll speed ramps up. Space, Up, or click to flap. |
| 8 | **Fruit Ninja** | Mouse / Keyboard | Slash arcing fruit with your cursor. Multi-cut combos and centrality scoring. |

## The Originals

Seven original games — physics toys, challenges and shooters that will test your reflexes.

| # | Game | Controls | |
|:-:|------|:--------:|---|
| 9 | **Target Practice** | Mouse / Keyboard | Glowing targets appear and shrink. Hit them before they vanish. Combo tightens the timer. |
| 10 | **Firefly Chase** | Mouse / Keyboard | 5 tiers of fireflies on orbital paths. The "Golden Snitch" firefly traces Lissajous curves and actively evades your cursor. |
| 11 | **Flick It!** | Mouse / Keyboard | Flick a physics orb off walls. It shifts from cyan to red with speed. Re-flick for combo. |
| 12 | **Juggler** | Mouse / Keyboard | Keep balls airborne with flick physics and gravity. Drop one and combo resets. Extra balls spawn at milestones. |
| 13 | **Orbital Defense** | Mouse / Keyboard | Defend a hex base from asteroid waves. Launch interceptors for chain-reaction explosions. |
| 14 | **Shield Guardian** | Mouse / Keyboard | Rotate a shield arc to deflect projectiles and protect your core through escalating waves. |
| 15 | **Rail Shooter** | Mouse / Keyboard | Pseudo-3D on-rails shooter. 4 enemy types approach from a vanishing point with depth scaling. |

## Controls

| Key | Action |
|-----|--------|
| Mouse / Arrow keys | Navigate menu or control cursor in-game |
| Click / Enter / Space | Select game (menu) or game-specific action |
| Scroll wheel | Scroll menu list |
| P | Pause / Resume |
| R | Restart current game |
| Esc | End round (in-game) or quit (menu) |

<details>
<summary>Game-specific controls</summary>

| Game | Controls |
|------|----------|
| **Snake** | Arrow keys for direction (or mouse-guided) |
| **Tetris** | Left/Right = move, Up/Z = rotate CW, X = rotate CCW, Down = soft drop, Space/Click = hard drop, Scroll = rotate |
| **Flappy Bird** | Space / Click = flap (standalone mode; cursor Y controls bird in launcher) |

</details>

## Features

| | |
|---|---|
| **Persistent High Scores** | Scores, combos, play counts, and session times saved across sessions |
| **Frame-Rate Independence** | Physics scales to real elapsed time — consistent speed on any hardware |
| **Auto-Scaling Display** | All text and markers resize smoothly on window resize |
| **Combo System** | Shared scoring with multipliers and animated fade-outs |
| **Standalone Mode** | Every game runs independently: `games.Pong().play()` |
| **Subclassable** | Override `buildRegistry` and `getMenuTitles` for custom game sets |
| **Extensible** | Add your own games by subclassing `engine.GameBase` and registering them in the game launcher |

## High Scores

Scores persist in `data/scores.mat`, auto-created on first play.

```matlab
services.ScoreManager.get("Pong")          % view a game's record
services.ScoreManager.getAll()             % view all records
services.ScoreManager.clearGame("Pong")    % reset one game
services.ScoreManager.clearAll()           % reset everything
```

## Requirements

- **MATLAB R2022b** or later
- No additional toolboxes

## Project Structure

```
Arcade.m                 entry point
+engine/
    GameBase.m           abstract base class for all games
+ui/
    GameMenu.m           animated menu with starfield
+services/
    ScoreManager.m       persistent high-score storage
+games/                  15 game classes
docs/                    developer documentation
```

For architecture details, see [docs/DEVELOPER.md](docs/DEVELOPER.md).
