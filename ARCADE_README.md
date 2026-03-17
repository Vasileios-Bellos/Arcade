# MATLAB Arcade

43 games and physics simulations, all playable with mouse or webcam finger tracking.

---

## Quick Start

```matlab
% Mouse mode (no webcam needed)
ArcadeGameLauncher.launch()

% Finger tracking mode (requires webcam + calibration)
gm = GestureMouse("ShowFPS", true);
gm.start();   % press G to open game menu
```

---

## How It Works

### Architecture

```
ArcadeGameLauncher        GameHost
  (mouse input)        (finger input via GestureMouse)
        \                  /
         \                /
          GameMenu (shared neon menu)
              |
          GameBase (abstract base class)
              |
     +games/ package (43 game classes)
              |
         ScoreManager (persistent high scores)
```

**GameBase** is the abstract base class. Every game implements 4 methods:

| Method | Purpose |
|--------|---------|
| `onInit(ax, displayRange, caps)` | Create graphics, initialize state |
| `onUpdate(pos)` | Per-frame physics + rendering. `pos = [x, y]` |
| `onCleanup()` | Delete all graphics |
| `onKeyPress(key)` | Handle game-specific keys |

Games never call `drawnow` and never know where their input comes from. They receive `[x, y]` each frame and draw on the axes they're given.

### Performance

All games use **pre-allocated graphics pools** — every graphics object (`line`, `scatter`, `patch`, `text`) is created once in `onInit` and recycled during gameplay by toggling `Visible` and updating `XData`/`YData`. No graphics are created or deleted inside `onUpdate`.

This matters because MATLAB graphics object creation triggers handle registration, renderer sync, and memory allocation — each taking 0.2–1ms. At 50 FPS with multiple objects per frame, those hitches are visible. Property updates on existing handles (`h.XData = newX`) cost <0.01ms.

The pool pattern for a typical game:

```matlab
function onInit(obj, ax, displayRange, ~)
    % Pre-allocate pool (all hidden)
    obj.BulletPool = cell(1, 10);
    obj.BulletActive = false(1, 10);
    for k = 1:10
        obj.BulletPool{k} = line(ax, NaN, NaN, ...
            "Visible", "off", "Tag", "GT_mygame");
    end
end

function fireBullet(obj, x, y)
    slot = find(~obj.BulletActive, 1);     % find idle slot
    if isempty(slot); return; end           % pool full, skip
    obj.BulletActive(slot) = true;
    set(obj.BulletPool{slot}, "XData", x, "YData", y, "Visible", "on");
end

function deactivateBullet(obj, slot)
    obj.BulletActive(slot) = false;
    obj.BulletPool{slot}.Visible = "off";  % hide, don't delete
end
```

Other performance conventions:
- **Constant arrays** (`linspace(0, 2*pi, 24)` for circles) are computed once in `onInit` and stored as properties
- **Expensive queries** (`getpixelposition`, `get(0, "ScreenPixelsPerInch")`) are cached at init time
- **HUD text** uses dirty flags — `.String` and `.Color` are only set when the displayed value actually changes

**Two hosts** can run any game:

- **ArcadeGameLauncher** — standalone figure, mouse input, click-based menu
- **GameHost** — overlays on GestureMouse's axes, finger input, 3-second dwell menu

Both share the same `GameMenu` component, game registry, state machine (menu → countdown → active → paused → results), HUD, and score tracking.

### Standalone Mode

Any game can also run directly without the menu:

```matlab
game = games.FlickBall();
game.play();   % opens figure, mouse input, ESC to quit
```

---

## Game List

### Action / Arcade (keys 1-9, Shift+1-9)

| Key | Game | Description |
|-----|------|-------------|
| 1 | Pointing | Hit random targets, combo scoring, difficulty scales with combo |
| 2 | Tracing | Follow path corridors, coverage tracking |
| 3 | Catching | Chase 5-tier color-coded fireflies with Lissajous snitch |
| 4 | Flick Ball | Physics orb — flick it, bounce off walls, speed-to-color |
| 5 | Pong | AI opponent, rally escalation, paddle hit angle |
| 6 | Juggling | Keep balls airborne with flicks, gravity pulls them down |
| 7 | Glyph Trace | Trace letter-shaped corridors from font outlines |
| 8 | Keyboard | QWERTY layout, dwell-based key press |
| 9 | Breakout | 5 levels, power-ups, multi-ball, neon bricks |
| Shift+1 | Flappy Bird | Pipe dodge, gap/speed scaling |
| Shift+2 | Fruit Ninja | Slash fruit arcs, centrality scoring |
| Shift+3 | Space Invaders | 3 alien types, 5 wave formations, power-ups |
| Shift+4 | Snake | Finger-directed, grid-based, wrap-around |
| Shift+5 | Asteroids | Wireframe polygons, splitting, auto-fire |
| Shift+6 | Orbital Defense | Hex base, asteroid waves, chain-reaction explosions |
| Shift+7 | Gravity Well | N-body sandbox, 6 colored particles, finger attractor |
| Shift+8 | Shield Guardian | Shield arc deflects projectiles, core HP, waves |
| Shift+9 | FPS Rail Shooter | Pseudo-3D, 4 monster types, wave-based, screen shake |

### Physics Simulations (Alt+1-9, Numpad)

| Key | Game | Description |
|-----|------|-------------|
| Alt+1 | Molecule Grid | Spring-mass lattice, finger repulsion, 3 physics modes |
| Alt+2 | Fluid Sim | Stam stable fluids, FFT Poisson, dye injection |
| Alt+3 | Dobryakov | Fluid sim variant with different injection modes |
| Alt+4 | Ripple Tank | Wave equation PDE, diffuse shading, 3 source modes |
| Alt+5 | Reaction-Diffusion | Gray-Scott, 5 pattern presets, 5 color schemes |
| Alt+6 | Wind Tunnel | LBM D2Q9, Zou-He inlet, cylinder/airfoil obstacles |
| Alt+7 | Elements | 15-material cellular automaton (sand, water, fire, lava...) |
| Alt+8 | String Harmonics | 1D wave equation, pluck/inject harmonics, spectrum bars |
| Alt+9 | Three-Body | Velocity Verlet N-body, figure-8 / Lagrange / freeplay |
| Num1 | Cloth | Verlet spring-mass grid, curtain/flag/drum modes |
| Num2 | Boids | 150 formation agents, flock/predator/vortex/murmuration |
| Num3 | Double Pendulum | Lagrangian, RK4, chaos/energy/cascade modes |
| Num4 | Smoke | Stam solver + buoyancy + vorticity, chimney/incense/explosion/wind |
| Num5 | Fire | Combustion system, fire colormap, torch/campfire/wildfire/wall |
| Num6 | Newton's Cradle | RK4, elastic collision, chrome balls, 6 configurations |
| Num7 | EM Field | Coulomb quiver + cyclotron particle accelerator |
| Num8 | Planets | Full N-body solar system (10 bodies), Velocity Verlet |
| Num9 | Lorenz | 4 strange attractors (Lorenz/Rossler/Thomas/Aizawa), RK4 |

### Art / Music / Misc (0, Shift+0, Alt+0, Alt+P, Alt+C, Num0, Shift+Num1)

| Key | Game | Description |
|-----|------|-------------|
| 0 | Game of Life | Conway B3/S23, age coloring, Gosper gun, 4 presets |
| Shift+0 | Lissajous | N x N parametric table with rainbow trails |
| Alt+0 | Voronoi | 40 seeds, Delaunay, Lloyd relaxation |
| Alt+P | Piano | Playable piano keyboard |
| Alt+C | Crystal Growth | Crystal growth simulation |
| Num0 | Fourier Epicycle | DFT decomposition, animated epicycle reconstruction |
| Shift+Num1 | Ecosystem | Ecosystem simulation |

---

## Controls

### Menu
- **Up/Down arrows** or **mouse hover** — navigate
- **Enter / Space** — select game
- **Number keys** — quick select (1-9, Shift+1-9, Alt+1-9, etc.)
- **ESC** — quit

### In-Game (universal)
- **P** — pause / resume
- **R** or **0** — restart
- **ESC** — end game (shows results)

### In-Game (game-specific)
- **M** — cycle sub-modes (most physics sims)
- **N** — cycle variants / finger mode
- **B** — toggle visuals / flow mode
- **Up/Down** — adjust grid density / particle count / difficulty
- **Left/Right** — adjust speed / parameters

Each game documents its own controls in the HUD at the bottom of the screen.

---

## High Scores

**ScoreManager** tracks persistent high scores for every game. Scores are saved to `ScoreManager_scores.mat` and survive across MATLAB sessions.

### What Gets Tracked (per game)

- **High score** + date achieved
- **Best combo** + date achieved
- **Times played**
- **Total time played**
- **Last played** date

### Where Scores Appear

- **Results screen** — after each game: shows "NEW HIGH SCORE: X" if you beat your record, or "High Score: X" if you didn't
- **Game menu** — each game shows its high score on the right side of the menu item (gold star + number)
- **Standalone mode** — `game.play()` silently records scores when the figure closes

### How It Works

ScoreManager is a static utility class. No instances, no setup. It auto-creates a record the first time you play any game. New games added to `+games/` are automatically tracked on first play.

```matlab
% Check a high score
rec = ScoreManager.get("FlickBall");
fprintf("High: %d, Played: %d times\n", rec.highScore, rec.timesPlayed);

% Check all scores
allScores = ScoreManager.getAll();

% Reset one game
ScoreManager.clearGame("FlickBall");

% Reset everything
ScoreManager.clearAll();
```

### Storage

Scores are stored in `ScoreManager_scores.mat` (same directory as `ScoreManager.m`). The file is versioned for future-proofing. Missing or corrupt files are handled gracefully — you just start fresh.

---

## Adding a New Game

1. Create `+games/MyGame.m` extending `GameBase`
2. Implement `onInit`, `onUpdate`, `onCleanup`, `onKeyPress`
3. Set the `Name` constant property
4. **Pre-allocate all graphics in `onInit`** — see [Performance](#performance) above
5. Register in `ArcadeGameLauncher.buildRegistry()` and `GameHost.buildRegistry()`
6. High scores are tracked automatically on first play

```matlab
classdef MyGame < GameBase
    properties (Constant)
        Name = "My Game"
    end
    properties (Access = private)
        EnemyPool   cell                    % pre-allocated handles
        EnemyActive (1,20) logical = false  % pool bookkeeping
    end
    methods
        function onInit(obj, ax, displayRange, caps)
            % Pre-allocate all graphics here (Visible="off")
            obj.EnemyPool = cell(1, 20);
            for k = 1:20
                obj.EnemyPool{k} = scatter(ax, NaN, NaN, 100, ...
                    "filled", "Visible", "off", "Tag", "GT_mygame");
            end
        end
        function onUpdate(obj, pos)
            % pos = [x, y] — physics + rendering each frame
            % Activate/deactivate pool slots, never create or delete
        end
        function onCleanup(obj)
            % Delete all pool handles + orphan guard
            for k = 1:numel(obj.EnemyPool)
                h = obj.EnemyPool{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_mygame");
        end
        function handled = onKeyPress(obj, key)
            handled = false;
        end
    end
end
```

---

## File Structure

```
ArcadeGameLauncher.m    — standalone mouse-driven arcade launcher
GameHost.m              — GestureMouse-integrated host (finger input)
GameBase.m              — abstract base class for all games
GameMenu.m              — shared neon menu component
ScoreManager.m          — persistent high score tracking
+games/
    Pointing.m          — (43 game classes)
    FlickBall.m
    Pong.m
    ...
    FluidUtils.m        — shared fluid sim utilities
    PathUtils.m         — shared path tracing utilities
    FallingSandUtils.m  — shared Elements utilities
```
