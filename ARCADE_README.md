# MATLAB Arcade

43 games and physics simulations in pure MATLAB. No toolboxes required.

## Launching Games

### Arcade Launcher (recommended)
Fullscreen neon menu with score tracking, combos, FPS counter, and high scores.
```matlab
ArcadeGameLauncher()
```

### Standalone
Any game can run on its own — creates a fullscreen figure with mouse/keyboard input, FPS counter, score and combo display.
```matlab
games.FlickIt().play()
games.Breakout().play()
games.Smoke().play()
```

### Webcam (finger tracking)
Games run inside the GestureMouse camera app, controlled by finger position.
```matlab
gm = GestureMouse(ShowFPS=true);
% press G to open the game menu, hover to select
```

All three modes use the same game classes and the same FPS scaling.

---

## Games

### Action / Arcade

| Key | Game | Description |
|-----|------|-------------|
| 1 | Target Practice | Hit random targets, combo scoring, difficulty ramp |
| 2 | Shape Tracing | Follow path corridors, coverage tracking |
| 3 | Fireflies | Chase 5-tier color-coded fireflies with evasive golden snitch |
| 4 | Flick It | Physics orb — flick it, bounce off walls, speed-to-color gradient |
| 5 | Pong | AI opponent with rally escalation and paddle hit angle |
| 6 | Juggling | Keep balls airborne with flicks, gravity pulls them down |
| 7 | Glyph Tracing | Trace letter-shaped corridors rendered from font outlines |
| 8 | Keyboard | QWERTY layout with dwell-based key press |
| 9 | Breakout | 5 levels, power-ups, multi-ball, neon bricks |
| Shift+1 | Flappy Bird | Pipe dodge with aggressive gap/speed scaling |
| Shift+2 | Fruit Ninja | Slash fruit arcs, multi-cut bonus (×N), centrality scoring, 8 colors |
| Shift+3 | Space Invaders | 3 alien types, 5 wave formations, power-ups, shields |
| Shift+4 | Snake | Arrow keys or mouse-directed, grid-based movement, wrap-around |
| Shift+5 | Asteroids | Wireframe polygons, splitting on destroy, auto-fire |
| Shift+6 | Orbital Defense | Hex base, asteroid waves, chain-reaction explosions |
| Shift+7 | Gravity Well | N-body sandbox with 6 colored particles and cursor attractor |
| Shift+8 | Shield Guardian | Rotate a shield arc to deflect projectiles, protect core HP |
| Shift+9 | Rail Shooter | Pseudo-3D depth scaling, 4 monster types, screen shake |

### Physics Simulations

| Key | Game | Description |
|-----|------|-------------|
| Alt+1 | Molecule Grid | Spring-mass lattice with cursor interaction, 3 physics modes |
| Alt+2 | Fluid Sim | Stam stable fluids with FFT Poisson solver, dye injection |
| Alt+3 | Dobryakov | Fluid sim variant with rainbow/colormap injection modes |
| Alt+4 | Ripple Tank | Wave equation PDE with diffuse shading, 3 source modes |
| Alt+5 | Reaction-Diffusion | Gray-Scott model, 5 pattern presets, 5 color schemes |
| Alt+6 | Wind Tunnel | Lattice Boltzmann D2Q9, Zou-He inlet, cylinder/airfoil obstacles |
| Alt+7 | Elements | 15-material cellular automaton — sand, water, fire, lava, acid, snow... Tunable speed (1-6) |
| Alt+8 | String Harmonics | 1D wave equation, pluck or inject pure harmonics, live spectrum |
| Alt+9 | Three-Body | Velocity Verlet N-body: figure-8, Lagrange, and freeplay orbits |
| Num1 | Cloth | Verlet spring-mass grid — curtain, flag, and drum modes |
| Num2 | Boids | 150 formation agents — flock, predator, vortex, murmuration |
| Num3 | Double Pendulum | Lagrangian mechanics with RK4, chaos/energy/cascade modes |
| Num4 | Smoke | Stam solver with buoyancy and vorticity confinement |
| Num5 | Fire | Combustion system — torch, campfire, wildfire, wall modes |
| Num6 | Newton's Cradle | RK4 with elastic collision, chrome balls, 6 configurations |
| Num7 | EM Field | Coulomb field quiver plot + cyclotron particle accelerator |
| Num8 | Planets | Full N-body solar system (10 bodies) with Velocity Verlet |
| Num9 | Strange Attractors | 4 strange attractors — Lorenz, Rossler, Thomas, Aizawa |

### Art / Misc

| Key | Game | Description |
|-----|------|-------------|
| 0 | Game of Life | Conway B3/S23, age-based coloring, Gosper gun, 4 presets |
| Shift+0 | Lissajous | N x N parametric table with per-cell rainbow trails |
| Alt+0 | Voronoi | 40 seeds, Delaunay triangulation, Lloyd relaxation |
| Alt+P | Piano | 25-key piano (C3-C5), ADSR synthesis, dwell-based press |
| Alt+C | Crystal Growth | Directional crystal growth — dendrite, snowflake, coral, competition |
| Num0 | Fourier Epicycle | DFT decomposition with animated epicycle reconstruction |
| Alt+E | Ecosystem | 5-organism ecology — plants, herbivores, predators, decomposers, toxin |

---

## Controls

### Menu
- **Up/Down** or **mouse hover** — navigate
- **Enter / Space** — select
- **Number keys** — quick select (1-9, Shift+1-9, Alt+1-9, Numpad)
- **ESC** — quit

### In-Game
- **P** — pause / resume
- **R** — restart
- **0** — in-game reset (mode-specific)
- **ESC** — end game and show results
- **M** — cycle sub-modes (or scroll wheel)
- **N** — cycle variants / interaction mode
- **B** — toggle visuals
- **Arrow keys** — cursor movement (games that don't bind them)
- **Up/Down** — grid density / particle count
- **Left/Right** — speed / parameters
- **Scroll wheel** — cycle sub-modes

Each game shows its specific controls in the HUD.

---

## High Scores

Scores persist across MATLAB sessions in `ScoreManager_scores.mat`. Per-game tracking includes high score, best combo, times played, total play time, and last played date. Scores appear on the results screen and next to each game in the menu.

New games are tracked automatically on first play — no setup needed.

```matlab
ScoreManager.get("FlickIt")         % view one game's record
ScoreManager.getAll()               % view all records
ScoreManager.clearGame("FlickIt")   % reset one game
ScoreManager.clearAll()             % reset everything
```

---

## Frame-Rate Independence

All games run at the same perceived speed regardless of the machine's actual frame rate. The system measures the real time elapsed each frame and scales all game physics proportionally.

### How it works

Each game has a `RefFPS` property (default 25) — the reference frame rate the physics constants were calibrated at. At `RefFPS`, `DtScale = 1.0`. Every frame:

1. The host measures `rawDt` — actual seconds since the last frame (via `toc`)
2. Computes `DtScale = rawDt × RefFPS`
3. Sets `DtScale` on the game before calling `onUpdate`

At the target FPS, `DtScale = 1.0` — identical to unscaled frame-based code. At half the target FPS, `DtScale = 2.0` — each frame moves objects twice as far. The product `DtScale × actual_FPS` is always equal to `RefFPS`, so total movement per second is constant.

### Scaling rules inside games

| Quantity | Frame-based (unscaled) | FPS-scaled |
|----------|----------------------|------------|
| Velocity | `pos += vel` | `pos += vel * ds` |
| Gravity | `vel += g` | `vel += g * ds` |
| Friction | `vel *= 0.99` | `vel *= 0.99 ^ ds` |
| Phase / animation | `phase += 0.1` | `phase += 0.1 * ds` |
| Frame timer | `timer -= 1` | `timer -= ds` |
| Substep count | `nSub = 10` | `nSub = round(10 * ds)` |

Where `ds = obj.DtScale`.

### Tuning at runtime

`RefFPS` is a public property on every game. Change it live to speed up or slow down:

```matlab
% Through the arcade launcher
a = ArcadeGameLauncher();
% ... start a game, then:
a.ActiveGame.RefFPS = 12;   % 2× slower than default

% Through standalone play
g = games.FlickIt();
g.play();
g.RefFPS = 50;  % 2× faster than default
```

### FPS display

The arcade launcher shows a real-time FPS counter (top-right) during gameplay, computed from a 30-frame ring buffer of frame times. Toggle with the `ShowFPS` property. The standalone `play()` mode also shows FPS.

---

## Requirements

- MATLAB R2020b or later
- No additional toolboxes

## File Structure

```
ArcadeGameLauncher.m    — game launcher
GameBase.m              — abstract base class
GameMenu.m              — scrollable neon menu
ScoreManager.m          — persistent high scores
+games/                 — 43 game classes + 3 shared utilities
```

For developer documentation (architecture, performance patterns, adding new games), see [ARCADE_DETAILS.md](ARCADE_DETAILS.md).
