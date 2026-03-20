# Arcade -- Developer Details

Internal documentation for the game architecture, performance patterns, and development conventions.

---

## Architecture

```
ArcadeGameLauncher (handle class, subclassable)
    |-- State machine:  menu -> countdown -> active -> paused -> results -> menu
    |-- Timer:          fixedSpacing 0.02s (50 Hz target)
    |-- Mouse tracking: WindowButtonMotionFcn -> [x, y] each frame
    |-- HUD:            score (roll-up), combo (fade), status text, FPS counter
    |-- Key handling:   KeyPressFcn -> state-dependent dispatch
    |-- No drawnow at startup -- RefPixelSize captured lazily on first resize
    |
    GameMenu (Sealed handle class -- shared neon menu)
    |
    GameBase (abstract base class)
    |
    +games/       (15 arcade game classes)
    +simulations/ (24 simulation classes + FluidUtils + FallingSandUtils)
    +training/    (3 training classes + PathUtils)
    +tools/       (2 tool classes: Piano, Keyboard)
    |
    ScoreManager (persistent .mat file)
```

### Launcher Hierarchy

`ArcadeGameLauncher` is subclassable. Two subclasses override `buildRegistry()` and `getMenuTitles()`:

| Class | Registers | Menu Title |
|-------|-----------|------------|
| `ArcadeGameLauncher` | 15 games from `+games/` | "ARCADE" |
| `SimulationLauncher` | 24 simulations from `+simulations/` | "SIMULATOR" |
| `AppLauncher` | All 44 items from all 4 packages | "A P P   L A U N C H E R" |

### Core Classes

**`ArcadeGameLauncher.m`** -- Main launcher. Creates a maximized figure, timer-based 50 Hz render loop, manages the state machine (menu/countdown/active/paused/results). No `drawnow` at startup -- `RefPixelSize` is captured lazily on the first `onFigResize` callback (after the window manager finishes maximizing).

**`SimulationLauncher.m`** / **`AppLauncher.m`** -- Sealed subclasses of ArcadeGameLauncher. Override `buildRegistry()` to register their respective packages and `getMenuTitles()` for custom title/subtitle strings.

**`GameBase.m`** -- Abstract base class for all games. Provides scoring, combo, hit effects, color constants, speed-to-color mapping, `scaleScreenSpaceObjects`, and standalone `play()` method. Key properties: `DtScale` (set by host each frame), `FontScale` (set by host on resize), `RefFPS` (default 60, tunable per game).

**`GameMenu.m`** -- Sealed handle class. Neon-styled scrollable menu with twinkling starfield, patch-based comet trails (EdgeAlpha interpolation), pill-shaped item slots with key badges and high-score display. Two selection modes: `"click"` (mouse) and `"dwell"` (finger tracking). `scaleFonts()` provides deterministic font sizing computed as `min(axPx / [854, 480])`. Keyboard mode suppresses mouse hover highlighting.

**`ScoreManager.m`** -- Static utility class for persistent high scores. Storage in `ScoreManager_scores.mat`.

---

## Display Range and Coordinate System

Fixed display range: **854 x 480** (16:9 aspect ratio). Set in `computeDisplayRange()`:

```matlab
obj.DisplayRange = struct("X", [0 854], "Y", [0 480]);
```

`pbaspect([gameAR 1 1])` handles letterboxing when the figure aspect ratio does not match 16:9. The axes use `YDir = "reverse"` (origin at top-left, Y increases downward).

**Display scale factor**: `sc = min(areaW, areaH) / 180`, where 180 is the reference minimum dimension from GestureTrainer's original ~240x180 display. Games use `sc` to scale hardcoded pixel constants from the original GestureTrainer coordinate system to the arcade's 854x480 display.

---

## Font Scaling Architecture

Three independent font scaling mechanisms serve different UI layers:

### 1. Menu text -- `GameMenu.scaleFonts()`

Computes a deterministic pixel scale from the current axes pixel size divided by the reference `[854, 480]`:

```matlab
ps = min(axPx(3) / 854, axPx(4) / 480);
```

Called on menu show, menu enter, and every figure resize. Independent of `RefPixelSize` -- the result depends only on current axes dimensions. Font sizes are applied as `max(floor, round(base * ps))`.

### 2. Game text -- `GameBase.scaleScreenSpaceObjects(ax, pixelScale)`

Scales all `FontSize`, `SizeData`, `MarkerSize`, and `LineWidth` properties of axes children. Base values are captured into each object's `UserData` on first call, so subsequent calls scale from the original (no accumulation drift).

The `pixelScale` is computed by the host as:

```matlab
pixelScale = min(axPx(3) / RefPixelSize(1), axPx(4) / RefPixelSize(2));
```

`RefPixelSize` is captured lazily on the first `onFigResize` callback (after the maximize completes). Games that set `FontSize` or `SizeData` dynamically per-frame should multiply by `FontScale` (which the host sets to `pixelScale` on resize).

### 3. Countdown, results, and HUD text -- `ArcadeGameLauncher.getPixelScale()`

Returns a deterministic scale identical in formula to `GameMenu.scaleFonts()`:

```matlab
ps = min(axPx(3) / 854, axPx(4) / 480);
```

Used for countdown number sizing, results screen text, and combo text -- elements managed by the launcher rather than by games or the menu.

---

## FPS Scaling

Frame-rate-independent physics via per-frame time scaling:

```matlab
DtScale = rawDt * RefFPS
```

- **`rawDt`** -- elapsed time since last frame (`toc(FpsLastTic)`), capped at 0.1s (10 FPS floor)
- **`RefFPS`** -- reference frame rate the game's physics constants were tuned at (default 60, stored as a tunable `GameBase` property)
- **`DtScale`** -- dimensionless multiplier. Exactly 1.0 when running at `RefFPS`. Set by the host each frame via `obj.ActiveGame.DtScale = obj.RawDt * obj.ActiveGame.RefFPS`

### Usage in games

| Pattern | Example |
|---------|---------|
| Velocity | `pos = pos + vel * ds` |
| Gravity | `vel = vel + gravity * ds` |
| Friction/damping | `vel = vel * friction ^ ds` |
| Phase/angle | `theta = theta + omega * ds` |
| Substep count | `nSub = round(baseSub * ds)` |
| Discrete CAs | `SimAccum = SimAccum + ds; while SimAccum >= 1; step(); SimAccum = SimAccum - 1; end` |

### FPS display

A 30-frame ring buffer (`DtBuffer`) stores raw dt values. The displayed FPS is `1 / mean(valid entries)`. The ring buffer is for display only -- `DtScale` uses the raw per-frame dt directly (no averaging).

---

## GameBase Interface

Every game is a `GameBase` subclass. Games implement 4 required + 2 optional methods:

| Method | Required | Called | Purpose |
|--------|----------|--------|---------|
| `onInit(ax, displayRange, caps)` | Yes | Once | Create graphics, initialize state |
| `onUpdate(pos)` | Yes | Every frame | Physics + rendering. `pos = [x, y]` |
| `onCleanup()` | Yes | Once | Delete all graphics |
| `onKeyPress(key)` | Yes | On keypress | Game-specific keys. Return `true` if handled |
| `onScroll(delta)` | No | On scroll wheel | Cycle sub-modes. `delta` = +/-1 |
| `getResults()` | No | On game end | Return struct with Title + Lines for results screen |

Games are input-agnostic. They receive `[x, y]` and draw on the axes they are given. They never call `drawnow`.

**Standalone execution**: `GameBase.play()` creates a maximized figure with its own timer, mouse tracking, HUD, and `drawnow` -- any game can run independently via `games.FlickIt().play()`.

---

## Graphics Pool Pattern

All games use **pre-allocated graphics pools**. Every `line`, `scatter`, `patch`, and `text` object is created once in `onInit` and recycled during gameplay via `Visible` toggling and property updates. No graphics objects are created or deleted inside `onUpdate`.

### Why

MATLAB graphics object creation involves handle registration, renderer sync, and memory allocation -- each costing 0.2-1ms. At 50 FPS with multiple objects per frame, those hitches are visible. Property updates on existing handles (`h.XData = newX`) cost under 0.01ms.

### Pattern

```matlab
function onInit(obj, ax, displayRange, ~)
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

### Pool sizes across games

| Game | Pools |
|------|-------|
| SpaceInvaders | 10 player bullets + 15 enemy bullets + 4 power-ups + 1 shield |
| ShieldGuardian | 20 projectiles (scatter pairs) |
| OrbitalDefense | 10 interceptors + 12 explosions + 50 asteroids |
| FruitNinja | 8 fruits + 16 halves + 6 slash effects |
| Fireflies | 4 fireflies (dot + aura + trail + trailGlow each) |
| Snake | 60 body segments + 2 food handles |
| FlappyBird | 10 pipe pairs |

### Other conventions

- **Constant arrays** (`linspace(0, 2*pi, 24)` for circles) computed once in `onInit`, stored as properties
- **Expensive queries** (`getpixelposition`, `get(0, "ScreenPixelsPerInch")`) cached at init time
- **HUD dirty flags** -- `.String` and `.Color` only set when the displayed value changes

---

## Package Structure

```
+games/       15 game classes
    Pong, Breakout, Snake, Tetris, Asteroids, SpaceInvaders,
    FlappyBird, FruitNinja, TargetPractice, Fireflies, FlickIt,
    Juggling, OrbitalDefense, ShieldGuardian, RailShooter

+simulations/ 24 simulation classes + 2 utility classes
    MoleculeGrid, FluidSim, Dobryakov, RippleTank, ReactionDiffusion,
    WindTunnel, Elements, StringHarmonics, ThreeBody, Cloth, Boids,
    DoublePendulum, Smoke, Fire, NewtonsCradle, EmField, Planets,
    StrangeAttractors, GravityWell, Lissajous, Voronoi, GameOfLife,
    CrystalGrowth, Ecosystem
    --- utilities ---
    FluidUtils (shared fldAdvect, fldProject, fastBilerp)
    FallingSandUtils (shared fsdFallingMask, fsdFallingMaskTurbulent)

+training/    3 training classes + 1 utility class
    ShapeTracing, GlyphTracing, FourierEpicycle
    --- utilities ---
    PathUtils (generatePath, resampleUniform, computeCorridorBounds,
              buildBandPatch, buildBandPolyshape, filterGlowBoundary)

+tools/       2 tool classes
    Piano, Keyboard
```

`+package/` is a MATLAB package -- accessed as `games.FlickIt()`. Avoids name collisions with builtins (MATLAB has a `voronoi` function). The `+` prefix is MATLAB's package convention. No `addpath` needed -- MATLAB finds `+package/` automatically from the working directory.

---

## Adding a New Game

1. Create `+games/MyGame.m` (or appropriate package) extending `GameBase`
2. Set the `Name` constant property
3. Pre-allocate all graphics in `onInit` (see pool pattern above)
4. Tag all graphics with `"GT_mygame"` for orphan cleanup
5. Register in the appropriate launcher's `buildRegistry()` method
6. High scores are tracked automatically on first play

```matlab
classdef MyGame < GameBase
    properties (Constant)
        Name = "My Game"
    end
    properties (Access = private)
        EnemyPool   cell
        EnemyActive (1,20) logical = false
    end
    methods
        function onInit(obj, ax, displayRange, ~)
            obj.EnemyPool = cell(1, 20);
            for k = 1:20
                obj.EnemyPool{k} = scatter(ax, NaN, NaN, 100, ...
                    "filled", "Visible", "off", "Tag", "GT_mygame");
            end
        end
        function onUpdate(obj, pos)
            % Physics + rendering each frame
        end
        function onCleanup(obj)
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

## ScoreManager

Static utility class. No instances, no setup.

```matlab
ScoreManager.submit(gameId, score, maxCombo, elapsed)  % record a session
ScoreManager.get(gameId)                                % per-game record
ScoreManager.getAll()                                   % all records
ScoreManager.isHighScore(gameId, score)                 % check without saving
ScoreManager.clearGame(gameId)                          % reset one game
ScoreManager.clearAll()                                 % reset everything
```

Per-game record:
```
highScore, highScoreDate, maxCombo, maxComboDate,
timesPlayed, totalTime, lastPlayed
```

Storage: `ScoreManager_scores.mat` next to `ScoreManager.m`. Versioned (V1). Missing or corrupt files recovered gracefully.

---

## State Machine

| State | Display | Keys | Transitions |
|-------|---------|------|-------------|
| **menu** | Title + game list via GameMenu | Game keys, Escape=quit | -> countdown |
| **countdown** | 3-2-1-GO! pulse animation | Escape=menu | -> active |
| **active** | Game + HUD | P=pause, R=restart, 0=in-game reset, Escape=results, arrows=cursor, scroll=mode, game keys forwarded | -> paused, results |
| **paused** | "PAUSED" overlay | P=resume, Escape=results | -> active, results |
| **results** | Stats + score | R/Enter/Space=replay, Escape=menu | -> menu, countdown |

---

## Input Handling

### Mouse

`WindowButtonMotionFcn` updates `MousePos` each frame from `obj.Ax.CurrentPoint`.

### Arrow keys

Generic cursor fallback: when a game does not handle arrow keys, the host moves `MousePos` at `4% * min(displayW, displayH) * DtScale` per frame. Snake has dedicated arrow direction control. Keyboard mode (`KeyboardMode` flag) suppresses mouse hover in GameMenu.

### Scroll wheel

`WindowScrollWheelFcn` calls `ActiveGame.onScroll(delta)` during gameplay. `delta` = +/-1. Used by 22 games/simulations to cycle sub-modes.

### Key routing

Two-pass dispatch: modifier+key first (e.g., `"shift+2"`), plain key fallback. UK/US keyboard layout mapping via `shiftMap` dictionary for Shift+number differences.

---

## Resize Handling

1. `onFigResize` fires on any figure size change
2. First call: captures `RefPixelSize = getpixelposition(ax)(3:4)` -- the initial axes pixel dimensions after maximize
3. Subsequent calls during gameplay:
   - `pbaspect([gameAR 1 1])` maintains aspect ratio (MATLAB auto-letterboxes)
   - `pixelScale = min(axPx(3) / RefPixelSize(1), axPx(4) / RefPixelSize(2))`
   - `GameBase.scaleScreenSpaceObjects(ax, pixelScale)` scales all static text/markers
   - `ActiveGame.FontScale = pixelScale` for games that scale dynamic elements
4. During menu state: same `pbaspect` + `GameMenu.scaleFonts()` for deterministic menu sizing
