# MATLAB Arcade

43 games and physics simulations in pure MATLAB. No toolboxes required.

```matlab
ArcadeGameLauncher.launch()
```

A fullscreen neon menu opens. Pick a game with the keyboard or mouse.

Any game can also be launched directly:

```matlab
games.FlickBall().play()
games.Smoke().play()
games.SpaceInvaders().play()
```

---

## Games

### Action / Arcade

| Key | Game | Description |
|-----|------|-------------|
| 1 | Target Practice | Hit random targets, combo scoring, difficulty ramp |
| 2 | Tracing | Follow path corridors, coverage tracking |
| 3 | Catching | Chase 5-tier color-coded fireflies with evasive golden snitch |
| 4 | Flick Ball | Physics orb — flick it, bounce off walls, speed-to-color gradient |
| 5 | Pong | AI opponent with rally escalation and paddle hit angle |
| 6 | Juggling | Keep balls airborne with flicks, gravity pulls them down |
| 7 | Glyph Trace | Trace letter-shaped corridors rendered from font outlines |
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
| Shift+9 | FPS Rail Shooter | Pseudo-3D depth scaling, 4 monster types, screen shake |

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
| Num9 | Lorenz | 4 strange attractors — Lorenz, Rossler, Thomas, Aizawa |

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
ScoreManager.get("FlickBall")       % view one game's record
ScoreManager.getAll()               % view all records
ScoreManager.clearGame("FlickBall") % reset one game
ScoreManager.clearAll()             % reset everything
```

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
