# Arcade -- Developer Details

Internal documentation for the arcade game architecture, performance patterns, and development conventions.

---

## Architecture

```
Arcade.m (handle class)
    |-- State machine:  menu -> active -> paused -> results -> menu
    |-- Timer:          fixedSpacing 0.02s (50 Hz target)
    |-- Mouse tracking: WindowButtonMotionFcn -> [x, y] each frame
    |-- HUD:            score (roll-up), combo (fade), status text, FPS counter
    |-- Key handling:   KeyPressFcn -> state-dependent dispatch
    |-- FontScale:      min(axPx/[854,480]) -- absolute scale for creation
    |-- PrevAxPx:       [w,h] vector -- previous axes pixel size for relative resize
    |
    +ui/GameMenu.m (Sealed handle class -- shared neon menu)
    |
    +engine/GameBase.m (abstract base class)
    |
    +games/       (15 arcade game classes)
    |
    +services/ScoreManager.m (persistent .mat file)
```

### Core Classes

**`Arcade.m`** (1,133 lines) -- Main launcher. Creates a maximized figure, timer-based 50 Hz render loop, manages the state machine (menu/active/paused/results). Games launch directly from menu selection with no countdown -- `enterCountdown()` resets scores and calls `launchGame()` immediately. `FontScale` and `PrevAxPx` are initialized in `run()` before any graphics creation. Timer is stopped during `launchGame()` to prevent `drawnow` race conditions during scatter handle creation.

**`GameBase.m`** (728 lines) -- Abstract base class for all games. Provides scoring, combo, hit effects, color constants, speed-to-color mapping, `scaleScreenSpaceObjects`, `letterboxAxes`, and standalone `play()` method. Key properties: `DtScale` (set by host each frame), `FontScale` (set by host before `init()` and on resize), `RefFPS` (default 60, tunable per game), `ComboAutoFade` (default true, controls host combo fade behavior), `ShowHostCombo` (default true, controls whether host displays combo).

**`GameBase.init()`** -- Concrete public method called by all hosts before `onInit`. Sets `Ax`, `DisplayRange`, and `FontScale`. When the launcher calls `init()`, it sets `game.FontScale = obj.FontScale` first, so `init()` keeps that value. In standalone mode (`play()`), `init()` computes `FontScale` from the axes via `getPixelScale()` since it starts at the default value of 1.

**`GameMenu.m`** (1,292 lines) -- Sealed handle class. Neon-styled scrollable menu with twinkling starfield, patch-based comet trails (EdgeAlpha interpolation), pill-shaped item slots with key badges and high-score display. Two selection modes: `"click"` (mouse) and `"dwell"` (finger tracking). `scaleFonts()` provides deterministic font sizing computed as `min(axPx / [854, 480])`. Keyboard mode suppresses mouse hover highlighting. `show()` guards against destroyed axes and empty slot arrays to prevent runtime errors during rapid transitions.

**`ScoreManager.m`** (178 lines) -- Static utility class for persistent high scores. Storage in `ScoreManager_scores.mat` (auto-created on first play, not tracked in git). Stores high score, max combo, total plays, and cumulative session time per game.

---

## State Machine

Games launch directly from the menu with no countdown animation. The `enterCountdown()` method resets score/combo state and calls `launchGame()` immediately. The timer is stopped during `enterMenu()` to prevent mid-transition render calls on partially-constructed graphics.

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
| Random events | `rand < probability * ds` |

**Random event scaling**: Probabilities that are checked per frame must be scaled by `ds`. For example, Space Invaders alien fire rate: `rand < 0.0083 * (1 + wave * 0.3) * ds`. Without this, events fire N times more often at N times the frame rate.

### FPS display

A 30-frame ring buffer stores raw dt values. Displayed FPS is `1 / mean(valid entries)`. The ring buffer is for display only -- `DtScale` uses the raw per-frame dt directly (no EMA smoothing). FPS counter is visible during `active` and `paused` states when `ShowFPS = true`.

---

## Trail System (FPS-Independent)

Ball games (Pong, Breakout, FlickIt, Juggler) use a DtScale accumulator for FPS-independent trail recording. The trail records a position every 2.0 DtScale units instead of every frame, ensuring consistent trail length regardless of frame rate.

### DtScale Accumulator

```matlab
% Per-frame trail recording
obj.TrailAccum = obj.TrailAccum + ds;
if obj.TrailAccum >= 2.0
    obj.TrailAccum = obj.TrailAccum - 2.0;
    tidx = mod(obj.TrailIdx, obj.TrailLen) + 1;
    obj.TrailBufX(tidx) = obj.BallPos(1);
    obj.TrailBufY(tidx) = obj.BallPos(2);
    obj.TrailIdx = tidx;
end
```

At 60 FPS (`ds = 1.0`), this records every 2nd frame. At 120 FPS (`ds = 0.5`), every 4th frame. At 30 FPS (`ds = 2.0`), every frame. The buffer holds 20 positions, covering ~0.67 seconds of trail at any FPS.

### Bounce Force-Record

The accumulator alone would skip bounce contact points when they fall between recording intervals. This creates visual gaps where the trail appears to pass through walls instead of reflecting off them. The fix: force-record the exact bounce position into the trail buffer immediately, bypassing the accumulator:

```matlab
if bounced
    tidx = mod(obj.TrailIdx, obj.TrailLen) + 1;
    obj.TrailBufX(tidx) = obj.BallPos(1);
    obj.TrailBufY(tidx) = obj.BallPos(2);
    obj.TrailIdx = tidx;
    obj.TrailAccum = 0;  % reset accumulator
end
```

Force-recording is applied at:
- **Wall bounces** (Pong top/bottom walls, Breakout side walls)
- **Paddle hits** (Pong both paddles, Breakout paddle)
- **Brick bounces** (Breakout brick collision)

The trail is NOT cleared on paddle or wall hits -- it continues smoothly through reflections. Only cleared on serve/respawn.

### Trail Rendering

Trail rendering uses speed-dependent width and alpha for a comet-tail effect:

```matlab
speed = norm(obj.BallVel);
sRatio = speed / baseSpeed;
trailWidth = max(0.5, min(3.5, 0.5 + sRatio * 1.5));
trailAlpha = max(0.15, min(0.6, 0.15 + sRatio * 0.2));
```

Both the bright core trail and dim glow trail use these same formulas. Extra balls in Breakout use identical trail rendering to the main ball for visual consistency.

---

## Swept Collision Detection

### Two-Pass Brick Collision (Breakout)

At high ball speeds, the ball can travel through multiple bricks in a single frame. A naive approach (testing each brick and processing the first hit found) can process the wrong brick if iteration order doesn't match the ball's path.

The solution is a two-pass swept collision:

**Pass 1 -- Find earliest collision**: Test the ball's path segment (prePos -> ballPos) against every brick's AABB expanded by `BallRadius`. For each brick, compute the parametric entry time `tMin` using slab intersection. Track the brick with the smallest `tMin` (earliest contact along the path).

```matlab
% Slab intersection for expanded AABB
bx1 = brk.x - ballR;  bx2 = brk.x + brk.w + ballR;
by1 = brk.y - ballR;  by2 = brk.y + brk.h + ballR;

tMin = 1e-6; tMax = 1;
t1 = (bx1 - prePos(1)) / dx;
t2 = (bx2 - prePos(1)) / dx;
if t1 > t2; [t1, t2] = deal(t2, t1); end
tMin = max(tMin, t1);  tMax = min(tMax, t2);
if tMin > tMax; continue; end  % no intersection
% Repeat for Y axis...

if tMin < bestT
    bestT = tMin;
    bestK = k;
end
```

**Pass 2 -- Process the earliest hit**: Only the brick with the smallest `tMin` is processed. The hit point is computed as `prePos + bestT * [dx, dy]`. Reflection direction is determined by comparing the relative position to the brick center: if `|dcx/w| > |dcy/h|`, reflect X; otherwise reflect Y.

**Fireball recursion**: In fireball mode, the ball destroys bricks without reflecting. After processing the hit brick, `brickCollision` recurses with the remaining path segment to handle additional bricks along the same trajectory.

### Parametric Wall Collision (Pong)

Wall bounces use parametric contact time for exact reflection:

```matlab
tHit = min(1, max(0, (wallY - prePos(2)) / stepVel(2)));
obj.BallPos(1) = prePos(1) + tHit * stepVel(1);
obj.BallPos(2) = wallY;
obj.BallVel(2) = -obj.BallVel(2) * obj.Restitution;
```

This prevents the ball from visually penetrating walls at high speed.

---

## Multi-Ball System (Breakout)

### Extra Ball Structure

Extra balls are stored in a struct array with their own independent state:

```matlab
ExtraBalls = struct("pos", {}, "vel", {}, ...
    "coreH", {}, "glowH", {}, "auraH", {}, ...
    "trailH", {}, "trailGlowH", {}, ...
    "trailBufX", {}, "trailBufY", {}, "trailIdx", {}, ...
    "trailAccum", {});
```

Each extra ball has its own graphics handles, trail buffer (same 20-point capacity), and DtScale accumulator. Physics, wall collision, paddle collision, and brick collision use the same algorithms as the main ball.

### Identical Appearance

Extra balls render identically to the main ball:
- **3-layer rendering**: Opaque aura (outer glow), semi-transparent scatter glow ring, white core dot
- **Trail**: Same 20-point buffer, same DtScale accumulator threshold (2.0), same speed-dependent width/alpha formulas
- **Bounce force-record**: Wall, paddle, and brick bounces force-record into the extra ball's individual trail buffer

### Seamless Ball Promotion

When the main ball exits the bottom edge and extra balls exist, the first extra ball is promoted to main ball status:

```matlab
% Delete old main ball graphics
delete(obj.BallCoreH); delete(obj.BallGlowH); ...

% Adopt extra ball's handles and state
obj.BallPos = eb.pos;
obj.BallVel = eb.vel;
obj.BallCoreH = eb.coreH;
obj.BallGlowH = eb.glowH;
obj.BallAuraH = eb.auraH;
obj.BallTrailH = eb.trailH;
obj.BallTrailGlowH = eb.trailGlowH;
obj.TrailBufX = eb.trailBufX;
obj.TrailBufY = eb.trailBufY;
obj.TrailIdx = eb.trailIdx;
obj.TrailAccum = eb.trailAccum;

% Remove from array (don't delete graphics -- they're now main)
obj.ExtraBalls(1) = [];
```

The trail carries over seamlessly because the extra ball's trail buffer is adopted wholesale. No visual discontinuity occurs.

---

## Multi-Cut Slash System (Fruit Ninja)

### Single-Swipe Multi-Fruit Detection

Fruits spawned in clusters can be cut by a single continuous swipe. The system tracks `SwipeGen` (swipe generation counter, incremented on each new swipe) and `FruitSwipeGen` (which swipe generation each fruit entered). Fruits that share the same `SwipeGen` were touched by the same physical swipe motion.

### Slash Extension

The first fruit sliced in a swipe creates a normal white slash effect (core + glow line segments from trace buffer). When a second fruit is cut in the same swipe:

1. The first slash's `idxEnd` is extended to cover the new fruit's exit position
2. Buffer age compensation: `obj.SlashIdxEnd(firstSlot) = idxEnd + firstAge` accounts for the circular trace buffer shifting between cuts
3. The first slash's fade timer resets (stays visible longer)
4. Both slash lines turn golden (core and glow)
5. The second fruit's individual slash is deactivated (first slash covers it)

```matlab
% Age compensation for circular buffer shift
if obj.TraceBufferIdx >= obj.TraceBufferMax
    firstAge = obj.SlashAge(firstSlot);
else
    firstAge = 0;
end
obj.SlashIdxEnd(firstSlot) = idxEnd + firstAge;
```

### Multi-Cut Scoring

Each fruit scores independently at its own position: `100 * centralityBonus * comboMult * multiCut`. The multi-cut multiplier equals the number of fruits sliced in the current swipe (1x for first, 2x for second, etc.). A floating "2x", "3x" text appears at each fruit's position.

### Slash Reset

`SwipeGenSliced` resets to 0 when the first slash effect finishes fading (~0.48s / 29 DtScale units). This prevents stale multi-cut multipliers from carrying across separate swipes. Each hit resets the fade timer, extending the window for additional multi-cuts.

---

## Combo System

The host (Arcade) manages combo display. Games manage combo state via `incrementCombo()` and `resetCombo()`.

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

## Results Screen

The results screen uses the TeX interpreter for colored text. The combo text handle (`ComboTextH`) is repurposed for results display with `Interpreter = "tex"`.

### NEW HIGH SCORE (gold text)

When a new high score is achieved, the line uses TeX `\color[rgb]` for gold coloring:

```matlab
detailLines{end+1} = sprintf( ...
    "\\color[rgb]{%.2f %.2f %.2f}" + char(9733) + "  NEW HIGH SCORE: %d  " + char(9733), ...
    g(1), g(2), g(3), obj.Score);
```

Star characters use `char(9733)` (Unicode black star) which renders correctly in the TeX interpreter. The "PLAY AGAIN" instruction line uses a separate `\color[rgb]` reset to prevent the gold color from bleeding into subsequent lines.

---

## Hit Effects

`GameBase` provides a shared hit-effect pool with two spawn methods:

**`spawnHitEffect(pos, color, points, radius)`** -- expanding ring + 8 radial burst rays + floating score text. Used for catches, hits, and scoring events.

**`spawnBounceEffect(pos, normal, points, speed)`** -- directional spark with 5 rays spread around the impact normal + ring + score text. Color derived from speed via `flickSpeedColor`. Used for wall bounces.

Both methods pre-allocate `gobjects` handles tagged `"GT_fx"`. The host calls `updateHitEffects()` each frame to animate expansion, fade, and cleanup. Effects last 18-22 frames with ease-out alpha and expanding radius.

Games call `spawnHitEffect` / `spawnBounceEffect` from within `onUpdate` -- the host handles animation and deletion.

### Hit Effects Rendering Order

Hit effects must be rendered after all game graphics. In the HTML port, `hitEffects.update(ctx, ds)` is a single call that both advances animation and draws. An earlier bug called `hitEffects.update(ds)` for animation and then `hitEffects.draw(ctx)` separately -- but `draw(ctx)` internally called `update(ctx)` again, passing `ctx` (a CanvasRenderingContext2D) as the `ds` parameter. This caused `frames -= undefined` which produced `NaN`, permanently corrupting all active effects.

---

## AI System (Pong)

### Adaptive AI

The AI paddle tracks a predicted intercept point (`AITargetY`) with intentional error that decreases as the opponent's score increases:

```matlab
aiError = obj.AIErrorPx * max(0, 1 - obj.PlayerScore / (obj.WinScore * 0.8));
aiSpeed = obj.AIBaseSpeed * (1 + obj.PlayerScore / obj.WinScore * 0.5);
```

### DtScale-Scaled Recalculation Cooldown

The AI recalculates its target prediction on a cooldown. The cooldown decrements by `obj.DtScale` per frame instead of 1, ensuring the AI reacts at a consistent rate regardless of frame rate:

```matlab
obj.AIRecalcCD = obj.AIRecalcCD - obj.DtScale;
if obj.AIRecalcCD <= 0
    obj.recalcAITarget();
    obj.AIRecalcCD = 15;  % ~0.25s at 60 FPS
end
```

### Dead Zone Jitter Suppression

When the AI paddle is near its target and the ball is moving away, a dead zone prevents micro-corrections that cause visible jitter:

```matlab
nearTarget = abs(obj.AIPaddleY - obj.AITargetY) < 3;
ballMovingAway = obj.BallVel(1) > 0;
if nearTarget && ballMovingAway
    % Skip paddle movement -- suppress jitter
    return;
end
```

---

## Glow Rings (scatter-based)

Several games use `scatter` with `MarkerFaceAlpha` for glow rings instead of data-coordinate line circles. Scatter markers are always round regardless of axes aspect ratio (SizeData is in screen-space points^2). Games using this pattern:

- **Pong**: `BallGlowH` -- ball glow ring
- **Breakout**: `BallGlowH` -- ball glow ring (main and extra balls)
- **FlickIt**: `GlowH` -- orb glow ring with dynamic `MarkerFaceAlpha`
- **Juggler**: `BallGlowH` -- ball glow rings (one per ball)
- **FlappyBird**: `BirdGlowH` -- bird glow
- **Asteroids**: `ShipGlowH` -- ship glow
- **ShieldGuardian**: `ProjPoolGlow` -- projectile glow pool (20 scatter handles)
- **RailShooter**: detail scatter handles with alpha for monster glow

### 3-Layer Ball Rendering

Ball games (Pong, Breakout, FlickIt, Juggler) use a consistent 3-layer rendering stack:

1. **Aura** (outermost): Large opaque line marker. Provides the soft outer glow. Drawn first (behind).
2. **Glow ring**: Scatter marker with `MarkerFaceAlpha = 0.4`. Mid-layer bloom.
3. **Core**: Small white dot. Drawn last (front).

The aura is fully opaque in both MATLAB and HTML to match MATLAB's line marker rendering, which does not support per-marker alpha transparency.

### Flappy Bird Collision Radius

`FlpCollisionR` is computed from the bird's scatter `SizeData`:

```
SizeData -> diameter_pts = 2*sqrt(SizeData/pi)
         -> pixels = pts * DPI/72
         -> data_units = pixels / (axes_px / data_range)
```

The result (~3.0 data units) matches the visual core radius. Using `FlpBirdRadius` (0.15 of display height, ~18-27 data units) for collision would be ~3x too large.

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
| Breakout | 60 bricks + 5 power-ups + 3 extra ball sets |
| Tetris | 200 cells + 12 next-preview cells + 10 ghost cells |

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

The host appends a summary line (`Score: N | Max Combo: N | Time: Ns`), a high score line, and play-again instructions below the game's lines. Games should not duplicate score/combo/time -- the host handles those.

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

## Per-Game Technical Notes

### Pong (783 lines)

- AI opponent with adaptive difficulty (error decreases, speed increases with player score)
- Paddle-angle physics: hit offset from paddle center determines reflection angle
- Rally escalation: ball speed multiplied by `BallSpeedGain` (1.08x) per paddle hit
- Parametric wall collision for exact contact point
- Trail: 20-point DtScale accumulator with wall/paddle force-record
- AI recalc cooldown scaled by DtScale; dead zone suppresses jitter

### Breakout (1,605 lines)

- 5 levels with escalating brick layouts and row counts
- Power-ups: Fireball (destroy any brick), Wide Paddle, Slow Ball, Multi-Ball, Extra Life
- Two-pass swept brick collision (see above)
- Multi-ball: up to 3 balls with identical appearance, independent trail buffers, seamless promotion
- Trail: 20-point DtScale accumulator with wall/paddle/brick force-record
- Serve countdown: 120-frame timer with pulsing font animation
- Paddle-angle physics with configurable restitution
- Speed gate: `BallSpeed * SpeedGain` (1.04x) per brick hit, 1.008x per collision
- Level announce: centered text for 2 seconds between levels (no transition delay)
- Life display: center-screen flash, green on gain, red on loss

### Snake (543 lines)

- Grid-based movement with wrap-around walls
- Arrow keys for direction; mouse-guided mode as alternative
- Speed increases with body length
- Pre-allocated body segment pool (60 segments)

### Tetris (1,338 lines)

- Full SRS (Super Rotation System) with wall kicks
- Ghost piece preview showing landing position
- 3-piece next preview
- Hard drop (Space/Click), soft drop (Down), instant placement
- Level progression: gravity increases every 10 lines
- `isprop` guard for `GraphicsPlaceholder` handles (avoids invalid `XData` access on cleared axes children)

### Asteroids (507 lines)

- Wireframe polygon rendering (line-based, no fill)
- Asteroids split into smaller pieces on hit
- Auto-fire crosshair tracks cursor position
- Wave-based difficulty: asteroid count and speed increase
- Ship glow: scatter marker (always round)
- Core fully opaque, no shadowBlur (matches MATLAB line rendering)

### Space Invaders (938 lines)

- 3 alien types (top, middle, bottom) with different point values
- 5 wave formations with varying row/column layouts
- Destructible shields (pixel-based damage)
- Power-up drops: laser (rapid fire), shield (temporary invincibility)
- Alien fire rate: `rand < 0.0083 * (1 + wave * 0.3) * ds` (FPS-scaled)
- Step-based movement: aliens move in grid steps, accelerating as count decreases
- Life display: green flash on gain, red on loss

### Flappy Bird (482 lines)

- Gravity and flap impulse scaled to display size
- Pipe gaps tighten with consecutive passes (combo)
- Scroll speed ramps with combo multiplier
- Bird: scatter-based glow ring (always round)
- Collision radius: computed from SizeData, not display height fraction
- No green burst or shadowBlur effects

### Fruit Ninja (959 lines)

- 8-fruit pool with gravity-based arcs
- Centrality scoring: cuts through center score higher (0.5x edge to 1.5x center)
- Multi-cut system with extending golden slash line (see above)
- 16-half pool: sliced fruit pieces with spin and momentum inheritance
- 6-slash pool: line effects with fade animation (29 DtScale units)
- Slash threshold: 1.5 data units (lowered from higher values for responsiveness)
- Cluster spawning: 2-3 fruits near same X position for multi-cut opportunities
- ComboAutoFade = false: combo persists between fruit spawns

### Target Practice (485 lines)

- Glowing targets appear and shrink on countdown timer
- Hit targets before they vanish for points
- Combo tightens the timer (faster targets)
- Color shifts cyan -> red as time runs out (per-target)

### Firefly Chase (773 lines)

- 5 tiers: cyan, green, magenta, purple, gold
- Orbital paths with tier-dependent speed multipliers (1x-5x)
- "Golden Snitch" firefly traces Lissajous curves and actively evades cursor
- Snitch trail: 10-point DtScale accumulator
- Combo multiplier rewards rapid sequential catches
- Combo font size: 8 * FontScale

### Flick It! (631 lines)

- Physics orb with flick-based velocity input
- Wall collision with parametric contact time
- Speed-to-color gradient via `flickSpeedColor` (cyan -> red)
- 3-layer ball rendering: opaque aura, alpha glow, white core
- Trail: 20-point DtScale accumulator with wall force-record
- Re-flick a moving ball for combo bonus
- Combo font size: 8 * FontScale

### Juggler (754 lines)

- Keep balls airborne with flick physics
- Gravity pulls balls down; flick upward to keep aloft
- Drop a ball: combo resets
- Extra balls spawn at score milestones
- All balls share identical 3-layer rendering
- Trail: per-ball 20-point DtScale accumulator with wall force-record
- "Bounces" terminology in results; "Best Streak" for max combo

### Orbital Defense (651 lines)

- Hex base at center with surrounding shields
- Asteroid waves approach from edges
- Launch interceptors at cursor position
- Chain-reaction explosions when interceptors detonate near asteroids
- Escalating difficulty with wave-based asteroid count and speed

### Shield Guardian (625 lines)

- Rotate a shield arc to deflect incoming projectiles
- Swept quadratic collision prediction for accurate deflection angles
- Protect the central core from damage
- Waves escalate in speed, density, and projectile patterns
- Lives system with center-screen flash on damage

### Rail Shooter (1,194 lines)

- Pseudo-3D on-rails perspective with depth scaling
- 4 enemy types: grunt, heavy, interceptor, boss
- Enemies approach from a vanishing point with depth-based size scaling
- Breathing crosshair animation: `frameCount += ds` (FPS-scaled)
- Auto-fire DPS system with crosshair targeting
- Hit flash: decrement counter per frame for fade-out
- Single defeat burst (large red explosion, no secondary side explosions)

---

## HTML5 Canvas Port

The browser port (`web/arcade.html`, 10,723 lines) replicates all 15 games in a single self-contained HTML file with identical physics and scoring.

### Key Differences from MATLAB

| Aspect | MATLAB | HTML5 Canvas |
|--------|--------|--------------|
| Coordinate origin | Top-left (YDir=reverse) | Top-left (canvas default) |
| Marker rendering | Opaque line markers | `fillStyle` with `globalAlpha` |
| Ball aura | Line marker (opaque) | `arc()` fill (opaque, matching MATLAB) |
| Trail rendering | Line/patch with property updates | `strokeStyle` + `lineWidth` per segment |
| Text coloring | TeX `\color[rgb]` | `fillStyle` with hex/rgb |
| Hit effects | Pre-allocated gobjects pool | Array of effect objects |
| Timer | `fixedSpacing` timer | `requestAnimationFrame` |

### Scatter SizeData to Canvas Conversion

MATLAB scatter `SizeData` is in points^2. To convert to canvas pixel radius:

```javascript
// SizeData -> radius in points -> radius in pixels
radiusPts = Math.sqrt(SizeData / Math.PI);
radiusPx = radiusPts * (DPI / 72);
```

For ball glow effects, a measured correction factor of 1.20x is applied: `glow_radius = sqrt(SizeData / PI) * 1.20`.

---

## Adding a New Game

1. Create `+games/MyGame.m` extending `engine.GameBase`
2. Set the `Name` constant property
3. Pre-allocate all graphics in `onInit` (see pool pattern above)
4. Tag all graphics with `"GT_mygame"` for orphan cleanup
5. Register in `Arcade.buildRegistry()`
6. High scores are tracked automatically on first play

### Checklist

- [ ] All physics multiplied by `obj.DtScale` (velocity, gravity, phase)
- [ ] All random events scaled by `obj.DtScale` (spawn rates, fire rates)
- [ ] All font sizes use `base * obj.FontScale`
- [ ] No `getpixelposition` or `get(0, "ScreenPixelsPerInch")` in per-frame code
- [ ] No graphics creation/deletion in `onUpdate`
- [ ] Trail buffers use DtScale accumulator (if applicable)
- [ ] `getResults()` returns game-specific stats (host adds score/combo/time)
- [ ] `onCleanup()` deletes all handles + orphan guard
