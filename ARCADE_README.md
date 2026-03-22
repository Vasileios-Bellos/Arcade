# MATLAB Arcade

15 arcade games in pure MATLAB. No toolboxes required.

## Quick Start

```matlab
ArcadeGameLauncher()
```

Or run any game standalone:
```matlab
games.Pong().play()
games.Tetris().play()
```

---

## Games

| # | Game | Description |
|---|------|-------------|
| 1 | Pong | AI opponent with rally escalation and paddle hit angle |
| 2 | Breakout | 5 levels, power-ups, multi-ball, neon bricks |
| 3 | Snake | Arrow keys or mouse-directed, grid-based, wrap-around |
| 4 | Tetris | SRS rotation, wall kicks, ghost piece, 3-piece preview, instant lock |
| 5 | Asteroids | Wireframe polygons, splitting on destroy, auto-fire |
| 6 | Space Invaders | 3 alien types, 5 wave formations, power-ups, shields |
| 7 | Flappy Bird | Pipe dodge with aggressive gap/speed scaling |
| 8 | Fruit Ninja | Slash fruit arcs, multi-cut bonus, centrality scoring |
| 9 | Target Practice | Hit random targets, combo scoring, difficulty ramp |
| 10 | Firefly Chase | Chase 5-tier color-coded fireflies with evasive golden snitch |
| 11 | Flick It! | Physics orb -- flick it off walls, speed-to-color gradient |
| 12 | Juggling | Keep balls airborne with flicks, gravity pulls them down |
| 13 | Orbital Defense | Hex base, asteroid waves, chain-reaction explosions |
| 14 | Shield Guardian | Rotate a shield arc to deflect projectiles, protect core HP |
| 15 | Rail Shooter | Pseudo-3D depth scaling, 4 monster types, screen shake |

---

## Controls

### Menu
- **Up/Down arrows** or **mouse hover** -- navigate
- **Enter / Space / left-click** -- select game
- **Scroll wheel** -- scroll the game list
- **Esc** -- quit

### In-Game (all games)
- **Mouse** -- move cursor (or arrow keys as fallback)
- **Left-click** -- game-specific action (hard drop in Tetris, forward to game)
- **P** -- pause / resume
- **R** -- restart current game
- **Esc** -- end game, show results

### Results Screen
- **R / Enter / Space** -- play again
- **Esc** -- return to menu

### Game-Specific Controls

**Snake**: Arrow keys to change direction (or mouse-directed movement)

**Tetris**: Left/Right arrows to move, Up/Z to rotate clockwise, X to rotate counter-clockwise, Down arrow or right-click for soft drop, Space or left-click for hard drop, scroll wheel to rotate. Pieces lock instantly on landing (no lock delay).

---

## High Scores

Scores persist across sessions in `ScoreManager_scores.mat`. Per-game tracking includes high score, best combo, times played, total play time, and last played date.

```matlab
ScoreManager.get("FlickIt")         % view one game's record
ScoreManager.getAll()               % view all records
ScoreManager.clearGame("FlickIt")   % reset one game
ScoreManager.clearAll()             % reset everything
```

---

## Frame-Rate Independence

All games run at the same perceived speed regardless of actual frame rate. Each frame, the engine measures real elapsed time and scales all physics proportionally.

Every game has a `RefFPS` property (default 60). Each frame:

1. The host measures `rawDt` -- actual seconds since the last frame
2. Computes `DtScale = rawDt * RefFPS`
3. Passes `DtScale` to the game before calling `onUpdate`

At the target FPS, `DtScale = 1.0`. At half the target FPS, `DtScale = 2.0`.

| Quantity | Unscaled | FPS-scaled |
|----------|----------|------------|
| Velocity | `pos += vel` | `pos += vel * ds` |
| Gravity | `vel += g` | `vel += g * ds` |
| Friction | `vel *= 0.99` | `vel *= 0.99 ^ ds` |
| Phase | `phase += 0.1` | `phase += 0.1 * ds` |
| Timer | `timer -= 1` | `timer -= ds` |

Where `ds = obj.DtScale`.

---

## Requirements

- MATLAB R2020b or later
- No additional toolboxes

## File Structure

```
ArcadeGameLauncher.m    -- launcher with neon menu and HUD
GameBase.m              -- abstract base class for all games
GameMenu.m              -- scrollable neon menu
ScoreManager.m          -- persistent high scores
+games/                 -- 15 game classes
```

For developer documentation, see [ARCADE_DETAILS.md](ARCADE_DETAILS.md).
