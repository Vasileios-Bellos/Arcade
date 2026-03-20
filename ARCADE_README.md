# MATLAB Arcade

44 games, physics simulations, and interactive tools in pure MATLAB. No toolboxes required.

## Quick Start

```matlab
ArcadeGameLauncher()      % 15 arcade games
SimulationLauncher()      % 24 physics simulations
AppLauncher()             % everything (44 items)
```

Or run any game standalone:
```matlab
games.Pong().play()
games.Tetris().play()
simulations.Smoke().play()
tools.Piano().play()
```

All modes use the same game engine and frame-rate scaling.

---

## Arcade Games (15)

Launched via `ArcadeGameLauncher()`. Scored, competitive games with high score tracking.

| # | Game | Description |
|---|------|-------------|
| 1 | Pong | AI opponent with rally escalation and paddle hit angle |
| 2 | Breakout | 5 levels, power-ups, multi-ball, neon bricks |
| 3 | Snake | Arrow keys or mouse-directed, grid-based, wrap-around |
| 4 | Tetris | Arrow keys to move/rotate, Space for hard drop, scroll to rotate |
| 5 | Asteroids | Wireframe polygons, splitting on destroy, auto-fire |
| 6 | Space Invaders | 3 alien types, 5 wave formations, power-ups, shields |
| 7 | Flappy Bird | Pipe dodge with aggressive gap/speed scaling |
| 8 | Fruit Ninja | Slash fruit arcs, multi-cut bonus, centrality scoring |
| 9 | Target Practice | Hit random targets, combo scoring, difficulty ramp |
| 10 | Fireflies | Chase 5-tier color-coded fireflies with evasive golden snitch |
| 11 | Flick It | Physics orb -- flick it off walls, speed-to-color gradient |
| 12 | Juggling | Keep balls airborne with flicks, gravity pulls them down |
| 13 | Orbital Defense | Hex base, asteroid waves, chain-reaction explosions |
| 14 | Shield Guardian | Rotate a shield arc to deflect projectiles, protect core HP |
| 15 | Rail Shooter | Pseudo-3D depth scaling, 4 monster types, screen shake |

## Physics Simulations (24)

Launched via `SimulationLauncher()`. Interactive physics and mathematical visualizations.

| # | Simulation | Description |
|---|------------|-------------|
| 1 | Molecule Grid | Spring-mass lattice with cursor interaction, 3 physics modes |
| 2 | Fluid Sim | Stam stable fluids with FFT Poisson solver, dye injection |
| 3 | Dobryakov | Fluid sim variant with rainbow/colormap injection modes |
| 4 | Ripple Tank | Wave equation PDE with diffuse shading, 3 source modes |
| 5 | Reaction-Diffusion | Gray-Scott model, 5 pattern presets, 5 color schemes |
| 6 | Wind Tunnel | Lattice Boltzmann D2Q9, Zou-He inlet, cylinder/airfoil obstacles |
| 7 | Elements | 15-material cellular automaton -- sand, water, fire, lava, acid, snow... |
| 8 | String Harmonics | 1D wave equation, pluck or inject pure harmonics, live spectrum |
| 9 | Three-Body | Velocity Verlet N-body: figure-8, Lagrange, and freeplay orbits |
| 10 | Cloth | Verlet spring-mass grid -- curtain, flag, and drum modes |
| 11 | Boids | 150 formation agents -- flock, predator, vortex, murmuration |
| 12 | Double Pendulum | Lagrangian mechanics with RK4, chaos/energy/cascade modes |
| 13 | Smoke | Stam solver with buoyancy and vorticity confinement |
| 14 | Fire | Combustion system -- torch, campfire, wildfire, wall modes |
| 15 | Newton's Cradle | RK4 with elastic collision, chrome balls, 6 configurations |
| 16 | EM Field | Coulomb field quiver plot + cyclotron particle accelerator |
| 17 | Planets | Full N-body solar system (10 bodies) with Velocity Verlet |
| 18 | Strange Attractors | 4 strange attractors -- Lorenz, Rossler, Thomas, Aizawa |
| 19 | Gravity Well | N-body sandbox with 6 colored particles and cursor attractor |
| 20 | Lissajous | N x N parametric table with per-cell rainbow trails |
| 21 | Voronoi | 40 seeds, Delaunay triangulation, Lloyd relaxation |
| 22 | Game of Life | Conway B3/S23, age-based coloring, Gosper gun, 4 presets |
| 23 | Crystal Growth | Directional crystal growth -- dendrite, snowflake, coral, competition |
| 24 | Ecosystem | 5-organism ecology -- plants, herbivores, predators, decomposers, toxin |

## Training (3)

Finger-tracking exercises (also usable with mouse via `AppLauncher()`).

| # | Exercise | Description |
|---|----------|-------------|
| 1 | Shape Tracing | Follow path corridors, coverage tracking |
| 2 | Glyph Tracing | Trace letter-shaped corridors rendered from font outlines |
| 3 | Fourier Epicycle | DFT decomposition with animated epicycle reconstruction |

## Tools (2)

| # | Tool | Description |
|---|------|-------------|
| 1 | Piano | 25-key piano (C3-C5), ADSR synthesis, dwell-based press |
| 2 | Keyboard | QWERTY layout with dwell-based key press |

---

## Controls

### Menu
- **Up/Down arrows** or **mouse hover** -- navigate
- **Enter / Space / left-click** -- select game
- **Scroll wheel** -- scroll the game list
- **ESC** -- quit

### In-Game (all games)
- **Mouse** -- move cursor (or arrow keys as fallback)
- **P** -- pause / resume
- **R** -- restart current game
- **ESC** -- end game, show results

### Results Screen
- **R / Enter / Space** -- play again
- **ESC** -- return to menu

### Game-Specific Controls

**Snake**: Arrow keys to change direction (or mouse-directed movement)

**Tetris**: Left/Right arrows to move, Up arrow or Z to rotate clockwise, X to rotate counter-clockwise, Down arrow for soft drop, Space for hard drop, left-click for hard drop, right-click for soft drop, scroll wheel to rotate

**Many simulations**: M to cycle sub-modes, N to cycle variants, B to toggle visuals, Up/Down for grid density, Left/Right for speed/parameters, scroll wheel to cycle sub-modes. Each simulation shows its controls in the HUD.

---

## High Scores

Scores persist across MATLAB sessions in `ScoreManager_scores.mat`. Per-game tracking includes high score, best combo, times played, total play time, and last played date. Scores appear on the results screen and next to each game in the menu.

New games are tracked automatically on first play -- no setup needed.

```matlab
ScoreManager.get("FlickIt")         % view one game's record
ScoreManager.getAll()               % view all records
ScoreManager.clearGame("FlickIt")   % reset one game
ScoreManager.clearAll()             % reset everything
```

---

## Frame-Rate Independence

All games run at the same perceived speed regardless of the machine's actual frame rate. Each frame, the engine measures the real elapsed time and scales all physics proportionally.

Every game has a `RefFPS` property (default 60) -- the reference frame rate the physics constants are tuned for. Each frame:

1. The host measures `rawDt` -- actual seconds since the last frame
2. Computes `DtScale = rawDt * RefFPS`
3. Passes `DtScale` to the game before calling `onUpdate`

At the target FPS, `DtScale = 1.0`. At half the target FPS, `DtScale = 2.0` -- each frame moves objects twice as far. The product `DtScale * actual_FPS` always equals `RefFPS`, so total movement per second is constant.

### Scaling rules

| Quantity | Unscaled | FPS-scaled |
|----------|----------|------------|
| Velocity | `pos += vel` | `pos += vel * ds` |
| Gravity | `vel += g` | `vel += g * ds` |
| Friction | `vel *= 0.99` | `vel *= 0.99 ^ ds` |
| Phase / animation | `phase += 0.1` | `phase += 0.1 * ds` |
| Frame timer | `timer -= 1` | `timer -= ds` |
| Substep count | `nSub = 10` | `nSub = round(10 * ds)` |

Where `ds = obj.DtScale`.

### FPS display

The launcher shows a real-time FPS counter (top-right) during gameplay, computed from a 30-frame ring buffer of frame times. Standalone `play()` mode also shows FPS.

---

## Requirements

- MATLAB R2020b or later
- No additional toolboxes

## File Structure

```
ArcadeGameLauncher.m    -- arcade launcher (15 games)
SimulationLauncher.m    -- simulation launcher (24 simulations)
AppLauncher.m           -- universal launcher (all 44 items)
GameBase.m              -- abstract base class for all games
GameMenu.m              -- scrollable neon menu
ScoreManager.m          -- persistent high scores
+games/                 -- 15 arcade game classes
+simulations/           -- 24 simulation classes + 2 shared utilities
+training/              -- 3 training exercises + 1 shared utility
+tools/                 -- 2 interactive tools
```

For developer documentation (architecture, performance patterns, adding new games), see [ARCADE_DETAILS.md](ARCADE_DETAILS.md).
