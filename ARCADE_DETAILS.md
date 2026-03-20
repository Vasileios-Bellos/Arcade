# Arcade -- Developer Details

Internal documentation for the arcade game architecture, performance patterns, and development conventions.

---

## Architecture

```
ArcadeGameLauncher (handle class)
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
    |
    ScoreManager (persistent .mat file)
```

### Core Classes

**`ArcadeGameLauncher.m`** -- Main launcher. Creates a maximized figure, timer-based 50 Hz render loop, manages the state machine (menu/countdown/active/paused/results). No `drawnow` at startup -- `RefPixelSize` is captured lazily on the first `onFigResize` callback (after the window manager finishes maximizing).

**`GameBase.m`** -- Abstract base class for all games. Provides scoring, combo, hit effects, color constants, speed-to-color mapping, `scaleScreenSpaceObjects`, and standalone `play()` method. Key properties: `DtScale` (set by host each frame), `FontScale` (set by host on resize), `RefFPS` (default 60, tunable per game).

**`GameMenu.m`** -- Sealed handle class. Neon-styled scrollable menu with twinkling starfield, patch-based comet trails (EdgeAlpha interpolation), pill-shaped item slots with key badges and high-score display. Two selection modes: `"click"` (mouse) and `"dwell"` (finger tracking). `scaleFonts()` provides deterministic font sizing computed as `min(axPx / [854, 480])`. Keyboard mode suppresses mouse hover highlighting.

**`ScoreManager.m`** -- Static utility class for persistent high scores. Storage in `ScoreManager_scores.mat` (auto-created on first play, not tracked in git).

---

## Display Range and Coordinate System

Fixed display range: **854 x 480** (16:9 aspect ratio). Set in `computeDisplayRange()`:

```matlab
obj.DisplayRange = struct("X", [0 854], "Y", [0 480]);
```

`pbaspect([gameAR 1 1])` handles letterboxing when the figure aspect ratio does not match 16:9. The axes use `YDir = "reverse"` (origin at top-left, Y increases downward).

**Display scale factor**: `sc = min(areaW, areaH) / 180`, where 180 is the reference minimum dimension. Games use `sc` to scale hardcoded pixel constants to the 854x480 display.

---

## Font Scaling Architecture

Three independent font scaling mechanisms serve different UI layers:

### 1. Menu text -- `GameMenu.scaleFonts()`

Computes a deterministic pixel scale from the current axes pixel size divided by the reference `[854, 480]`:

```matlab
ps = min(axPx(3) / 854, axPx(4) / 480);
```

Called on menu show, menu enter, and every figure resize. Independent of `RefPixelSize`.

### 2. Game text -- `GameBase.scaleScreenSpaceObjects(ax, pixelScale)`

Scales all `FontSize`, `SizeData`, `MarkerSize`, and `LineWidth` properties of axes children. Base values are captured into each object's `UserData` on first call, so subsequent calls scale from the original (no accumulation drift).

`RefPixelSize` is captured lazily on the first `onFigResize` callback (after the maximize completes).

### 3. Countdown, results, and HUD text -- `ArcadeGameLauncher.getPixelScale()`

Returns a deterministic scale identical in formula to `GameMenu.scaleFonts()`. Used for countdown number sizing, results screen text, and combo text.

---

## FPS Scaling

Frame-rate-independent physics via per-frame time scaling:

```matlab
DtScale = rawDt * RefFPS
```

- **`rawDt`** -- elapsed time since last frame, capped at 0.1s (10 FPS floor)
- **`RefFPS`** -- reference frame rate (default 60, tunable per game)
- **`DtScale`** -- dimensionless multiplier. Exactly 1.0 when running at `RefFPS`

### Usage in games

| Pattern | Example |
|---------|---------|
| Velocity | `pos = pos + vel * ds` |
| Gravity | `vel = vel + gravity * ds` |
| Friction/damping | `vel = vel * friction ^ ds` |
| Phase/angle | `theta = theta + omega * ds` |

### FPS display

A 30-frame ring buffer stores raw dt values. Displayed FPS is `1 / mean(valid entries)`. The ring buffer is for display only -- `DtScale` uses the raw per-frame dt directly.

---

## GameBase Interface

Every game is a `GameBase` subclass implementing:

| Method | Required | Purpose |
|--------|----------|---------|
| `onInit(ax, displayRange, caps)` | Yes | Create graphics, initialize state |
| `onUpdate(pos)` | Yes | Physics + rendering. `pos = [x, y]` |
| `onCleanup()` | Yes | Delete all graphics |
| `onKeyPress(key)` | Yes | Game-specific keys. Return `true` if handled |
| `onScroll(delta)` | No | Cycle sub-modes |
| `getResults()` | No | Return struct with Title + Lines for results screen |

Games are input-agnostic. They receive `[x, y]` and draw on the axes they are given. They never call `drawnow`.

**Standalone execution**: `games.FlickIt().play()` creates a maximized figure with its own timer and HUD.

---

## Graphics Pool Pattern

All games use **pre-allocated graphics pools**. Every `line`, `scatter`, `patch`, and `text` object is created once in `onInit` and recycled via `Visible` toggling and property updates. No graphics objects are created or deleted inside `onUpdate`.

MATLAB graphics object creation involves handle registration, renderer sync, and memory allocation -- each costing 0.2-1ms. Property updates on existing handles cost under 0.01ms.

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

---

## Games (15)

```
+games/
    Pong, Breakout, Snake, Tetris, Asteroids, SpaceInvaders,
    FlappyBird, FruitNinja, TargetPractice, Fireflies, FlickIt,
    Juggling, OrbitalDefense, ShieldGuardian, RailShooter
```

---

## Adding a New Game

1. Create `+games/MyGame.m` extending `GameBase`
2. Set the `Name` constant property
3. Pre-allocate all graphics in `onInit` (see pool pattern above)
4. Tag all graphics with `"GT_mygame"` for orphan cleanup
5. Register in `ArcadeGameLauncher.buildRegistry()`
6. High scores are tracked automatically on first play

---

## State Machine

| State | Display | Keys | Transitions |
|-------|---------|------|-------------|
| **menu** | Title + game list | Up/Down, Enter, Esc=quit | -> countdown |
| **countdown** | 3-2-1-GO! | Esc=menu | -> active |
| **active** | Game + HUD | P=pause, R=restart, Esc=results | -> paused, results |
| **paused** | "PAUSED" overlay | P=resume, Esc=results | -> active, results |
| **results** | Stats + score | R/Enter/Space=replay, Esc=menu | -> menu, countdown |

---

## Input Handling

### Mouse
`WindowButtonMotionFcn` updates `MousePos` each frame from `obj.Ax.CurrentPoint`.

### Arrow keys
Generic cursor fallback: when a game does not handle arrow keys, the host moves `MousePos` at `4% * min(displayW, displayH) * DtScale` per frame. Snake has dedicated arrow direction control. Keyboard mode suppresses mouse hover in GameMenu.

### Scroll wheel
`WindowScrollWheelFcn` calls `ActiveGame.onScroll(delta)` during gameplay.

### Key routing
Two-pass dispatch: modifier+key first (e.g., `"shift+2"`), plain key fallback. UK/US keyboard layout mapping via `shiftMap` dictionary.

---

## Resize Handling

1. `onFigResize` fires on any figure size change
2. First call: captures `RefPixelSize = getpixelposition(ax)(3:4)`
3. Subsequent calls during gameplay: `pbaspect` + `scaleScreenSpaceObjects` + `FontScale`
4. During menu state: `pbaspect` + `GameMenu.scaleFonts()`
