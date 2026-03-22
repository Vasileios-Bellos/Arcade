# MATLAB Arcade

15 neon-styled arcade games running entirely in MATLAB. No toolboxes, no external dependencies — just pure MATLAB graphics.

A full-featured launcher with animated menus, persistent high scores, frame-rate-independent physics, and automatic display scaling. Every game works with mouse, keyboard, or both.

<!-- TODO: Add hero GIF/screenshot here -->

## Quick Start

```matlab
ArcadeGameLauncher()          % launch the arcade menu
```

Or jump straight into any game:

```matlab
games.Pong().play()
games.Tetris().play()
games.Asteroids().play()
```

---

## The Games

### Classics

| # | Game | Description |
|---|------|-------------|
| 1 | **Pong** | Classic paddle game against an AI that gets smarter as the score climbs. Rally escalation, paddle-angle physics, first to 10 wins. |
| 2 | **Breakout** | 5 levels of neon bricks. Multi-ball power-ups, paddle-angle ball control, level progression with increasing difficulty. |
| 3 | **Snake** | Grid-based snake with wrap-around walls. Steer with arrow keys or let the mouse guide direction. |
| 4 | **Tetris** | Full SRS rotation system with wall kicks, ghost piece, 3-piece preview, and hard drop. |
| 5 | **Asteroids** | Wireframe asteroid field. Asteroids split on destroy, waves escalate. Auto-fire crosshair tracks your cursor. |
| 6 | **Space Invaders** | 3 alien types across 5 wave formations. Shields, power-ups, and increasingly aggressive attack patterns. |
| 7 | **Flappy Bird** | Navigate through pipes with tightening gaps and increasing scroll speed. In standalone mode, Space or click to flap. |
| 8 | **Fruit Ninja** | Slash arcing fruit with your cursor. Multi-cut bonus, centrality scoring, and combo chains. |

### Originals

| # | Game | Description |
|---|------|-------------|
| 9 | **Target Practice** | Touch glowing targets before they vanish. Targets shrink and timeouts shorten as your combo grows. |
| 10 | **Firefly Chase** | Hunt 5 tiers of color-coded fireflies on orbital paths. The rare golden snitch flies Lissajous curves and actively evades you. |
| 11 | **Flick It!** | Flick a physics orb off walls. Speed-to-color gradient from cyan to red, comet trail, re-flick for combo. |
| 12 | **Juggler** | Keep balls airborne with flick physics. Gravity pulls them down — drop one and combo resets. Extra balls spawn at combo milestones. |
| 13 | **Orbital Defense** | Defend a hex base from asteroid waves. Launch interceptors with chain-reaction explosions. |
| 14 | **Shield Guardian** | Rotate a shield arc to deflect incoming projectiles and protect your core HP through escalating waves. |
| 15 | **Rail Shooter** | Pseudo-3D on-rails shooter with 4 monster types, depth scaling, and screen shake. Survive the waves. |

---

## Controls

### Menu

| Input | Action |
|-------|--------|
| Mouse hover / Up-Down arrows | Navigate game list |
| Click / Enter / Space | Start selected game |
| Scroll wheel | Scroll the game list |
| Esc | Quit |

### In-Game

| Input | Action |
|-------|--------|
| Mouse | Move cursor / control game |
| Arrow keys | Alternative cursor movement (fallback) |
| P | Pause / resume |
| R | Restart current game |
| Esc | End game and show results |

### Game-Specific

| Game | Controls |
|------|----------|
| **Snake** | Arrow keys change direction (or mouse-guided) |
| **Tetris** | Left/Right = move, Up/Z = rotate CW, X = rotate CCW, Down = soft drop, Space/Click = hard drop, Scroll = rotate |
| **Flappy Bird** | Space / Click = flap (standalone mode only; in launcher, cursor Y controls bird height) |

All other games use mouse movement only.

### Results Screen

| Input | Action |
|-------|--------|
| R / Enter / Space | Play again |
| Esc | Return to menu |

---

## Features

- **Persistent high scores** — scores, best combos, play counts, and session times saved across sessions
- **Frame-rate independence** — physics scales to real elapsed time, consistent feel on any hardware
- **Auto-scaling display** — text and markers resize smoothly when you resize the window
- **Neon visual style** — consistent color palette, glow effects, and particle bursts across all games
- **Combo system** — shared scoring infrastructure with combo multipliers and animated fade-outs
- **Standalone mode** — every game can run independently with `games.GameName().play()`

---

## High Scores

Scores persist in `ScoreManager_scores.mat` (auto-created on first play).

```matlab
ScoreManager.get("Pong")            % view a game's record
ScoreManager.getAll()               % view all records
ScoreManager.clearGame("Pong")      % reset one game
ScoreManager.clearAll()             % reset everything
```

Each record tracks: high score, best combo, times played, total play time, and last played date.

---

## Requirements

- MATLAB R2020b or later
- No additional toolboxes

---

## File Structure

```
ArcadeGameLauncher.m    main launcher with neon menu and HUD
GameBase.m              abstract base class for all games
GameMenu.m              scrollable neon menu with starfield
ScoreManager.m          persistent high-score storage
+games/                 15 game classes
```

For architecture and developer documentation, see [DEVELOPER.md](DEVELOPER.md).
