# Arcade -- Developer Details

Internal documentation for the arcade game architecture, performance patterns, and development conventions.

---

## Architecture

```
ArcadeGameLauncher (handle class)
    |-- State machine:  menu -> active -> paused -> results -> menu
    |-- Timer:          fixedSpacing 0.02s (50 Hz target)
    |-- Mouse tracking: WindowButtonMotionFcn -> [x, y] each frame
    |-- HUD:            score (roll-up), combo (fade), status text, FPS counter
    |-- Key handling:   KeyPressFcn -> state-dependent dispatch
    |-- FontScale:      min(axPx/[854,480]) — absolute scale for creation
    |-- PrevAxPx:       [w,h] vector — previous axes pixel size for relative resize
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

**`ArcadeGameLauncher.m`** -- Main launcher. Creates a maximized figure, timer-based 50 Hz render loop, manages the state machine (menu/active/paused/results). Games launch directly from menu selection with no countdown -- `enterCountdown()` resets scores and calls `launchGame()` immediately. `FontScale` and `PrevAxPx` are initialized in `run()` before any graphics creation.

**`GameBase.m`** -- Abstract base class for all games. Provides scoring, combo, hit effects, color constants, speed-to-color mapping, `scaleScreenSpaceObjects`, `letterboxAxes`, and standalone `play()` method. Key properties: `DtScale` (set by host each frame), `FontScale` (set by host before `init()` and on resize), `RefFPS` (default 60, tunable per game), `ComboAutoFade` (default true, controls host combo fade behavior), `ShowHostCombo` (default true, controls whether host displays combo).

**`GameBase.init()`** -- Concrete public method called by all hosts before `onInit`. Sets `Ax`, `DisplayRange`, and `FontScale`. When the launcher calls `init()`, it sets `game.FontScale = obj.FontScale` first, so `init()` keeps that value. In standalone mode (`play()`), `init()` computes `FontScale` from the axes via `getPixelScale()` since it starts at the default value of 1.

**`GameMenu.m`** -- Sealed handle class. Neon-styled scrollable menu with twinkling starfield, patch-based comet trails (EdgeAlpha interpolation), pill-shaped item slots with key badges and high-score display. Two selection modes: `"click"` (mouse) and `"dwell"` (finger tracking). `scaleFonts()` provides deterministic font sizing computed as `min(axPx / [854, 480])`. Keyboard mode suppresses mouse hover highlighting.

**`ScoreManager.m`** -- Static utility class for persistent high scores. Storage in `ScoreManager_scores.mat` (auto-created on first play, not tracked in git).

---

## State Machine

Games launch directly from the menu with no countdown animation. The `enterCountdown()` method resets score/combo state and calls `launchGame()` immediately.

| State | Display | Keys | Transitions |
|-------|---------|------|-------------|
| **menu** | Title + game list | Up/Down, Enter/Space, Esc=quit | -> active (via enterCountdown -> launchGame) |
| **active** | Game + HUD | P=pause, R=restart, Esc=results | -> paused, results |
| **paused** | "PAUSED" overlay | P=resume, R=restart, Esc=results | -> active, results |
| **results** | Stats + score | R/Enter/Space=replay, Esc=menu | -> active (replay), menu |

Note: The `countdown` and `launching` states still exist in the code (switch cases in `onFrame`) but the normal flow bypasses them. `enterCountdown()` does not set `State` to `"countdown"` -- it goes straight from score reset to `launchGame()` which sets `State = "active"`.

---

## Display Range and Coordinate System

Fixed display range: **854 x 480** (16:9 aspect ratio). Set in `computeDisplayRange()`:

```matlab
obj.DisplayRange = struct("X", [0 854], "Y", [0 480]);
```

`pbaspect([gameAR 1 1])` handles letterboxing when the figure aspect ratio does not match 16:9. The axes use `YDir = "reverse"` (origin at top-left, Y increases downward). `GameBase` also provides a static `letterboxAxes(fig, ax, gameAR)` method that adjusts the axes `Position` property directly for alternative letterboxing.

**Display scale factor**: `sc = min(areaW, areaH) / 180`, where 180 is the reference minimum dimension. Games use `sc` to scale hardcoded pixel constants to the 854x480 display.

---

## Font Scaling Architecture

Two-level font scaling: absolute scale for creation, relative ratio for resize.

### FontScale -- absolute scale for creation

`FontScale = min(axPx(3) / 854, axPx(4) / 480)` -- a deterministic pixel scale computed from the current axes size relative to the 854x480 reference. Used when creating graphics objects:

```matlab
text(ax, x, y, str, "FontSize", baseFontSize * obj.FontScale, ...)
```

**Launcher flow**: `run()` computes `FontScale` and `PrevAxPx` from the axes before creating HUD or menu. Before launching a game, `launchGame()` sets `game.FontScale = obj.FontScale`. The game's `init()` method checks if `FontScale` was already set by the host (not equal to the default 1); if so, it keeps it. In standalone mode (`play()`), `init()` computes it from the axes via `getPixelScale()`.

**GameMenu flow**: `scaleFonts()` computes the same formula independently from the current axes pixel size. Called on menu show, menu enter, and every figure resize.

### scaleScreenSpaceObjects -- relative ratio for resize

`GameBase.scaleScreenSpaceObjects(ax, relScale)` scales all screen-space properties (`FontSize`, `SizeData`, `MarkerSize`, `LineWidth`) of axes children by a relative change ratio. Called on figure resize:

```matlab
relScale = newPs / oldPs;
GameBase.scaleScreenSpaceObjects(ax, relScale);
```

Properties are multiplied directly -- no guards, no rounding, no floors (except `SizeData` which is clamped to `max(1, ...)`). This avoids accumulation drift because each resize is a ratio of absolute scales, not an incremental step.

### PrevAxPx -- tracking previous size for relative scaling

`PrevAxPx` is a `[width, height]` vector stored on the launcher. Set initially in `run()` and updated on every `onFigResize`. Used to compute `oldPs` for the relative scale ratio:

```matlab
oldPs = min(obj.PrevAxPx(1) / 854, obj.PrevAxPx(2) / 480);
newPs = min(axPx(3) / 854, axPx(4) / 480);
relScale = newPs / oldPs;
```

The same pattern is used in `GameBase.play()` standalone mode with a local `prevAxPxPlay` variable.

### Resize flow (onFigResize)

1. Compute `newPs` and `relScale` from current vs. previous axes pixel size
2. Update `PrevAxPx` and `FontScale`
3. During gameplay (`State ~= "menu"`): `pbaspect` + `scaleScreenSpaceObjects(ax, relScale)` + update `ActiveGame.FontScale`
4. During menu state: `pbaspect` + `scaleScreenSpaceObjects(ax, relScale)` (menu has its own `scaleFonts()` in addition)

---

## Combo System

The host (ArcadeGameLauncher) manages combo display. Games manage combo state via `incrementCombo()` and `resetCombo()`.

### ComboAutoFade property (default true)

Controls whether the host auto-fades the combo display after inactivity.

**When true (default -- most games)**: After 1.0 seconds of no score change, the combo text fades out over 0.6 seconds. When the fade completes, the host calls `game.resetCombo()` and sets its own `Combo = 0`. Scoring during a fade cancels it (fade timer cleared).

**When false (Breakout, FruitNinja)**: The combo display stays visible indefinitely until the game explicitly calls `resetCombo()`. The host detects the game's combo dropping to 0 and instantly hides the text (no fade animation). This is used for games where combo should persist across gaps (e.g., between ball bounces in Breakout, between fruit spawns in FruitNinja).

### resetCombo (public method)

`GameBase.resetCombo()` is public so the host can call it when the auto-fade completes. Games can also call it directly (e.g., on life lost).

### Timing constants

| Event | Duration |
|-------|----------|
| Combo text displayed | Until 1.0s of inactivity |
| Fade-out animation | 0.6 seconds |
| Score roll-up speed | `max(3, gap * 0.3)` per frame (accelerates for large gains) |

### Sync flow (updateActive)

Each frame, the host reads `ActiveGame.Score` and `ActiveGame.Combo`:
- Score change -> update `LastScoreChangeTic`, cancel any active fade
- Combo increases -> call `showCombo()` to display and start the idle timer
- Combo drops to 0 -> if `ComboAutoFade`: start fade-out; else: instant hide

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

A 30-frame ring buffer stores raw dt values. Displayed FPS is `1 / mean(valid entries)`. The ring buffer is for display only -- `DtScale` uses the raw per-frame dt directly. FPS counter is visible during `active` and `paused` states when `ShowFPS = true`.

---

## GameBase Interface

Every game is a `GameBase` subclass implementing:

| Method | Required | Purpose |
|--------|----------|---------|
| `onInit(ax, displayRange, caps)` | Yes | Create graphics, initialize state |
| `onUpdate(pos)` | Yes | Physics + rendering. `pos = [x, y]` |
| `onCleanup()` | Yes | Delete all graphics |
| `onKeyPress(key)` | Yes | Game-specific keys. Return `true` if handled |
| `onMouseDown()` | No | Handle mouse click during gameplay |
| `onScroll(delta)` | No | Handle scroll wheel (cycle sub-modes) |
| `onResize(displayRange)` | No | Handle display range change |
| `onPause()` / `onResume()` | No | Handle pause/resume transitions |
| `getResults()` | No | Return struct with Title + Lines for results screen |
| `getHudText()` | No | Return mode-specific HUD string (bottom of screen) |

Games are input-agnostic. They receive `[x, y]` and draw on the axes they are given. They never call `drawnow`.

**`init(ax, displayRange, caps)`**: Concrete public method (not abstract). Sets `Ax`, `DisplayRange`, `FontScale`, then calls `onInit`. If `FontScale` was set by the host before calling `init()`, it is kept. Otherwise (standalone), it is computed from the axes.

**Standalone execution**: `games.FlickIt().play()` creates a maximized figure with its own timer, mouse tracking, HUD (score, combo, FPS), and arrow key cursor fallback.

### getResults() Format

Games return a struct from `getResults()` for the results screen:

```matlab
function r = getResults(obj)
    r.Title = "GAME NAME";       % shown large at the top
    r.Lines = {                   % game-specific detail lines
        sprintf("Wave: %d", obj.Wave)
    };
end
```

The host appends a summary line (`Score: N | Max Combo: N | Time: Ns`), a high score line, and play-again instructions below the game's lines. Games should not duplicate score/combo/time — the host handles those.

---

## Hit Effects

`GameBase` provides a shared hit-effect pool with two spawn methods:

**`spawnHitEffect(pos, color, points, radius)`** — expanding ring + 8 radial burst rays + floating score text. Used for catches, hits, and scoring events.

**`spawnBounceEffect(pos, normal, points, speed)`** — directional spark with 5 rays spread around the impact normal + ring + score text. Color derived from speed via `flickSpeedColor`. Used for wall bounces.

Both methods pre-allocate `gobjects` handles tagged `"GT_fx"`. The host calls `updateHitEffects()` each frame to animate expansion, fade, and cleanup. Effects last 18-22 frames with ease-out alpha and expanding radius.

Games call `spawnHitEffect` / `spawnBounceEffect` from within `onUpdate` — the host handles animation and deletion.

---

## Glow Rings (scatter-based)

Several games use `scatter` with `MarkerFaceAlpha` for glow rings instead of data-coordinate line circles. Scatter markers are always round regardless of axes aspect ratio (SizeData is in screen-space points^2). Games using this pattern:

- **Pong**: `BallGlowH` -- ball glow ring
- **Breakout**: `BallGlowH` -- ball glow ring
- **FlickIt**: `GlowH` -- orb glow ring with dynamic `MarkerFaceAlpha`
- **Juggler**: `BallGlowH` -- ball glow rings (one per ball)
- **FlappyBird**: `BirdGlowH` -- bird glow
- **Asteroids**: `ShipGlowH` -- ship glow
- **ShieldGuardian**: `ProjPoolGlow` -- projectile glow pool (20 scatter handles)
- **RailShooter**: detail scatter handles with alpha for monster glow

---

## Comet Trails (GameMenu)

Patch-based shooting star comets in the menu background. 2 pre-allocated comet slots, each a `patch` object with `EdgeAlpha = "interp"` for smooth per-vertex alpha fading.

### Structure
- 40 vertices per trail, connected by 39 separate 2-vertex faces
- `FaceColor = "none"`, `EdgeColor = "interp"` -- trail rendered as line segments
- `FaceVertexAlphaData` provides per-vertex transparency (head=1, tail=0)
- `FaceVertexCData` provides per-vertex color (head bright -> tail dim)
- Separate `line` handle for the bright head dot (`MarkerSize = 6`)

### Timing
- Spawned on `toc`-based intervals (1.5-3.5s between spawns)
- Each comet lasts 1.2-2.0 seconds
- Diagonal trajectory across the screen (meteor shower pattern)
- Fade-in at start, fade-out at end via alpha multiplier

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
| Firefly Chase | 4 fireflies (dot + aura + trail + trailGlow each) |
| Snake | 60 body segments + 2 food handles |
| FlappyBird | 10 pipe pairs |

---

## Games (15)

```
+games/
    Pong, Breakout, Snake, Tetris, Asteroids, SpaceInvaders,
    FlappyBird, FruitNinja, TargetPractice, FireflyChase, FlickIt,
    Juggler, OrbitalDefense, ShieldGuardian, RailShooter
```

---

## Input Handling

### Mouse
`WindowButtonMotionFcn` updates `MousePos` each frame from `obj.Ax.CurrentPoint`. `WindowButtonDownFcn` forwards clicks to `ActiveGame.onMouseDown()` during gameplay, or handles menu item clicks and scroll thumb drag during menu state.

### Arrow keys
Generic cursor fallback: when a game does not handle arrow keys, the host moves `MousePos` at `4% * min(displayW, displayH) * DtScale` per frame. Snake has dedicated arrow direction control. Keyboard mode suppresses mouse hover in GameMenu -- exited when mouse moves more than 15 pixels.

### Scroll wheel
`WindowScrollWheelFcn` scrolls the game list during menu state, or calls `ActiveGame.onScroll(-delta)` during gameplay (sign inverted).

### Key routing (onKeyPress -> dispatchKey)
Two-pass dispatch: modifier+key first (e.g., `"shift+2"`), plain key fallback. UK/US keyboard layout mapping via `shiftMap` dictionary. During `active` state, keys are tried in order: host keys (P, R, Esc) -> `ActiveGame.onKeyPress(key)` -> arrow fallback.

---

## Adding a New Game

1. Create `+games/MyGame.m` extending `GameBase`
2. Set the `Name` constant property
3. Pre-allocate all graphics in `onInit` (see pool pattern above)
4. Tag all graphics with `"GT_mygame"` for orphan cleanup
5. Register in `ArcadeGameLauncher.buildRegistry()`
6. High scores are tracked automatically on first play
