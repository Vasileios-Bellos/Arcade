# Arcade - Developer Details

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
    |-- FontScale:      min(axPx/[854,480]) - absolute scale for creation
    |-- PrevAxPx:       [w,h] vector - previous axes pixel size for relative resize
    |
    +ui/GameMenu.m (Sealed handle class - shared neon menu)
    |
    +engine/GameBase.m (abstract base class)
    |
    +games/       (15 arcade game classes)
    |
    +services/ScoreManager.m (persistent .mat file)
```

### Core Classes

**`Arcade.m`** - Main launcher. Creates a maximized figure, timer-based 50 Hz render loop, manages the state machine (menu/active/paused/results). Games launch directly from menu selection with no countdown - `enterCountdown()` resets scores and calls `launchGame()` immediately. `FontScale` and `PrevAxPx` are initialized in `run()` before any graphics creation. Timer is stopped during `launchGame()` to prevent `drawnow` race conditions during scatter handle creation.

**`GameBase.m`** - Abstract base class for all games. Provides scoring, combo, hit effects, color constants, speed-to-color mapping, `scaleScreenSpaceObjects`, `letterboxAxes`, and standalone `play()` method. Key properties: `DtScale` (set by host each frame), `FontScale` (set by host before `init()` and on resize), `RefFPS` (default 60, tunable per game), `ComboAutoFade` (default true, controls host combo fade behavior), `ShowHostCombo` (default true, controls whether host displays combo).

**`GameBase.init()`** - Concrete public method called by all hosts before `onInit`. Sets `Ax`, `DisplayRange`, and `FontScale`. When the launcher calls `init()`, it sets `game.FontScale = obj.FontScale` first, so `init()` keeps that value. In standalone mode (`play()`), `init()` computes `FontScale` from the axes via `getPixelScale()` since it starts at the default value of 1.

**`GameMenu.m`** - Sealed handle class. Neon-styled scrollable menu with twinkling starfield (20 pulsing stars at 0.56 Hz + ~90 static dots), 2-slot patch-based comet trails (40 vertices each, `EdgeAlpha = "interp"`, 1.2-2.0s flight time), pill-shaped item slots (rounded rectangles with 64-vertex corners) with key badges and high-score display. Two selection modes: `"click"` (mouse) and `"dwell"` (3s hover auto-select with cyan-to-green color ramp). Up to 5 visible slots with wrap-around scrolling and proportional scroll thumb. `scaleFonts()` provides deterministic font sizing: Title 29\*ps, Subtitle 13\*ps, Names 12\*ps, Keys/Scores 10\*ps. Keyboard mode suppresses mouse hover highlighting - exited on >15 data unit mouse movement.

**`ScoreManager.m`** - Static utility class for persistent high scores. Storage in `data/scores.mat` (auto-created on first play, not tracked in git). Stores high score, max combo, total plays, and cumulative session time per game.

---

## State Machine

Games launch directly from the menu with no countdown animation. The `enterCountdown()` method resets score/combo state and calls `launchGame()` immediately. The timer is stopped during `enterMenu()` to prevent mid-transition render calls on partially-constructed graphics.

| State | Display | Keys | Transitions |
|-------|---------|------|-------------|
| **menu** | Title + game list | Up/Down, Enter/Space, Esc=quit | -> active (via enterCountdown -> launchGame) |
| **active** | Game + HUD | P=pause, R=restart, Esc=results | -> paused, results |
| **paused** | "PAUSED" overlay | P=resume, R=restart, Esc=results | -> active, results |
| **results** | Stats + score | R/Enter/Space=replay, Esc=menu | -> active (replay), menu |

Note: The `countdown` and `launching` states still exist in the code (switch cases in `onFrame`) but the normal flow bypasses them. `enterCountdown()` does not set `State` to `"countdown"` - it goes straight from score reset to `launchGame()` which sets `State = "active"`.

### Timer and Frame Loop

The render timer uses `fixedSpacing` mode with `Period = 0.02` (50 Hz target). `fixedSpacing` waits `Period` seconds between the **end** of one callback and the **start** of the next, so actual FPS = `1 / (Period + callbackDuration)`. If the callback takes 20ms, real FPS is ~25 Hz.

Each `onFrame()` call:

1. Guard: return if Fig/Ax invalid
2. Measure `RawDt = min(toc(FpsLastTic), 0.1)` - capped at 100ms (10 FPS floor)
3. Write `RawDt` to 30-frame ring buffer (for FPS display)
4. Dispatch by State: menu calls `Menu.update()`, active calls `updateActive()`, others are static
5. Update combo fade animation
6. Score roll-up: `ScoreDisplayed += max(3, gap * 0.3)` (accelerates for large gains, min speed 3/frame)
7. FPS text: `1 / mean(validDts)` from ring buffer
8. `drawnow`
9. Error handler: suppresses expected "Invalid or deleted" handle errors during transitions, logs others

### Race Condition Prevention

Two critical guards protect against MATLAB's `drawnow` firing during object construction:

- **`launchGame()`**: Stops timer before `entry.ctor()` and `game.init()`, restarts after `beginGame()`. Prevents `onFrame` -> `drawnow` from rendering partially-created scatter objects
- **`enterMenu()`**: Stops timer before cleanup and menu construction, restarts after `Menu.show()`. Prevents rendering during the swap between game graphics and menu graphics

### Subclass Registry

`Arcade.buildRegistry()` is a protected method designed for override. The default implementation registers all 15 games with numeric keys "1"-"15". Subclasses override it to create custom game sets:

```matlab
classdef MyLauncher < Arcade
    methods (Access = protected)
        function buildRegistry(obj)
            obj.Registry = dictionary;
            obj.RegistryOrder = strings(0);
            obj.registerGame("1", @games.Pong, "Pong");
            % ... custom selection
        end
    end
end
```

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

### FontScale - absolute scale for creation

`FontScale = min(axPx(3) / 854, axPx(4) / 480)` - a deterministic pixel scale computed from the current axes size relative to the 854x480 reference. Used when creating graphics objects:

```matlab
text(ax, x, y, str, "FontSize", baseFontSize * obj.FontScale, ...)
```

**Launcher flow**: `run()` computes `FontScale` and `PrevAxPx` from the axes before creating HUD or menu. Before launching a game, `launchGame()` sets `game.FontScale = obj.FontScale`. The game's `init()` method checks if `FontScale` was already set by the host (not equal to the default 1); if so, it keeps it. In standalone mode (`play()`), `init()` computes it from the axes via `getPixelScale()`.

**GameMenu flow**: `scaleFonts()` computes the same formula independently from the current axes pixel size. Called on menu show, menu enter, and every figure resize.

### scaleScreenSpaceObjects - relative ratio for resize

`GameBase.scaleScreenSpaceObjects(ax, relScale)` scales all screen-space properties (`FontSize`, `SizeData`, `MarkerSize`, `LineWidth`) of axes children by a relative change ratio. Called on figure resize:

```matlab
relScale = newPs / oldPs;
GameBase.scaleScreenSpaceObjects(ax, relScale);
```

Properties are multiplied directly - no guards, no rounding, no floors (except `SizeData` which is clamped to `max(1, ...)`). This avoids accumulation drift because each resize is a ratio of absolute scales, not an incremental step.

### PrevAxPx - tracking previous size for relative scaling

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

- **`rawDt`** - elapsed time since last frame, capped at 0.1s (10 FPS floor)
- **`RefFPS`** - reference frame rate (default 60, tunable per game)
- **`DtScale`** - dimensionless multiplier. Exactly 1.0 when running at `RefFPS`

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

A 30-frame ring buffer stores raw dt values. Displayed FPS is `1 / mean(valid entries)`. The ring buffer is for display only - `DtScale` uses the raw per-frame dt directly (no EMA smoothing). FPS counter is visible during `active` and `paused` states when `ShowFPS = true`.

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

The trail is NOT cleared on paddle or wall hits - it continues smoothly through reflections. Only cleared on serve/respawn.

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

**Pass 1 - Find earliest collision**: Test the ball's path segment (prePos -> ballPos) against every brick's AABB expanded by `BallRadius`. For each brick, compute the parametric entry time `tMin` using slab intersection. Track the brick with the smallest `tMin` (earliest contact along the path).

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

**Pass 2 - Process the earliest hit**: Only the brick with the smallest `tMin` is processed. The hit point is computed as `prePos + bestT * [dx, dy]`. Reflection direction is determined by comparing the relative position to the brick center: if `|dcx/w| > |dcy/h|`, reflect X; otherwise reflect Y.

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

% Remove from array (don't delete graphics - they're now main)
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

**When true (default - most games)**: After 1.0 seconds of no score change, the combo text fades out over 0.6 seconds. When the fade completes, the host calls `game.resetCombo()` and sets its own `Combo = 0`. Scoring during a fade cancels it (fade timer cleared).

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

**`spawnHitEffect(pos, color, points, radius)`** - expanding ring + 8 radial burst rays + floating score text. Used for catches, hits, and scoring events.

**`spawnBounceEffect(pos, normal, points, speed)`** - directional spark with 5 rays spread around the impact normal + ring + score text. Color derived from speed via `flickSpeedColor`. Used for wall bounces.

Both methods pre-allocate `gobjects` handles tagged `"GT_fx"`. The host calls `updateHitEffects()` each frame to animate expansion, fade, and cleanup. Effects last 18-22 frames with ease-out alpha and expanding radius.

Games call `spawnHitEffect` / `spawnBounceEffect` from within `onUpdate` - the host handles animation and deletion.

### Hit Effects Rendering Order

Hit effects must be rendered after all game graphics. In the HTML port, `hitEffects.update(ctx, ds)` is a single call that both advances animation and draws. An earlier bug called `hitEffects.update(ds)` for animation and then `hitEffects.draw(ctx)` separately - but `draw(ctx)` internally called `update(ctx)` again, passing `ctx` (a CanvasRenderingContext2D) as the `ds` parameter. This caused `frames -= undefined` which produced `NaN`, permanently corrupting all active effects.

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
    % Skip paddle movement - suppress jitter
    return;
end
```

---

## Glow Rings (scatter-based)

Several games use `scatter` with `MarkerFaceAlpha` for glow rings instead of data-coordinate line circles. Scatter markers are always round regardless of axes aspect ratio (SizeData is in screen-space points^2). Games using this pattern:

- **Pong**: `BallGlowH` - ball glow ring
- **Breakout**: `BallGlowH` - ball glow ring (main and extra balls)
- **FlickIt**: `GlowH` - orb glow ring with dynamic `MarkerFaceAlpha`
- **Juggler**: `BallGlowH` - ball glow rings (one per ball)
- **FlappyBird**: `BirdGlowH` - bird glow
- **Asteroids**: `ShipGlowH` - ship glow
- **ShieldGuardian**: `ProjPoolGlow` - projectile glow pool (20 scatter handles)
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

## Menu System (GameMenu)

### Slot Rendering

Each slot is a pill-shaped rounded rectangle built from 4 circular arc corners (16 points each, 64 total vertices). Three layers per slot:

1. **Glow patch** (behind): expanded by 8x6 pixels, alpha 0 normally, 0.10 when selected, ramps to 0.50 during dwell
2. **Background pill**: dark face `[0.045, 0.048, 0.065]`, dim border `[0.09, 0.10, 0.13]`, border thickens 1.2->1.8px on select
3. **Key badge**: small circle inside slot with game number text

Selection colors: name text switches from muted `[0.40, 0.42, 0.50]` to white, key badge brightens from 0.25 to 0.50 of teal. Glow pulses at `0.10 + 0.06 * sin(t * 3.5)`.

### Title Rendering

Two-layer text: dark shadow at `[0, 0.12, 0.17]` offset by `(2*scale, 1.5*scale)` pixels, bright teal `[0.0, 0.55, 0.65]` on top. Font size 29\*ps. The decorative line below uses the same teal at two widths: glow (6px, alpha 0.25) and core (1.2px, alpha 0.6), spanning 13% of display width on each side of center.

### Starfield and Twinkle Stars

Static background: ~90 random dot markers at `[0.35, 0.40, 0.55]` alpha 0.4. 20 animated twinkle stars pulse brightness `0.2 + 0.8 * sin(t * speed + phase)` with base color `[0.4, 0.6, 0.9]` and 15% size variation. Speed per star: 1.5-4.0 rad/s.

### Comet Trails

2 pre-allocated `patch` objects with 40 vertices each, connected by 39 two-vertex faces (`FaceColor = "none"`, `EdgeAlpha = "interp"`). Per-vertex alpha gradient: head=1 to tail=0. Per-vertex color: head `[0.85, 0.90, 0.95]` to tail `[0.30, 0.35, 0.50]`. Head dot rendered as a separate `line` marker at `MarkerSize = 6`.

- Spawn interval: 1.5-3.5s (randomized). Flight duration: 1.2-2.0s
- Trajectory: ~45 degrees, 50/50 left-to-right or right-to-left
- Trail grows during first 10% of flight, fades in over first 15%
- Deactivates when head exits bounds (with 15% margin)

---

## Graphics Pool Pattern

All games use **pre-allocated graphics pools**. Every `line`, `scatter`, `patch`, and `text` object is created once in `onInit` and recycled via `Visible` toggling and property updates. No graphics objects are created or deleted inside `onUpdate`.

MATLAB graphics object creation involves handle registration, renderer sync, and memory allocation - each costing 0.2-1ms. Property updates on existing handles cost under 0.01ms.

### Pool sizes across games

| Game | Pools |
|------|-------|
| SpaceInvaders | 10 player bullets + 15 enemy bullets + 4 power-ups + 1 shield |
| ShieldGuardian | 20 projectiles (scatter pairs) |
| OrbitalDefense | 10 interceptors + 12 explosions + 50 asteroids |
| FruitNinja | 8 fruits + 16 halves + 6 slash effects |
| Firefly Chase | 4 fireflies (dot + aura + trail + trailGlow each) |
| Snake | 100 body segments + 2 food handles |
| FlappyBird | 6 pipe pairs (top + bottom each) |
| Breakout | 60 bricks (10x6) + dynamic power-ups + 3 extra ball sets |
| Tetris | 220 cells (22x10) + 12 next-preview cells + 4 ghost cells |

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

**Standalone execution**: `games.FlickIt().play()` creates a maximized figure with its own timer (50 Hz `fixedSpacing`), mouse tracking via closure variables, HUD (score, combo, FPS), arrow key cursor fallback (4% of screen per DtScale unit), and figure resize handling with `letterboxAxes`. The `play()` method uses nested functions as closures to capture the game instance, timer handle, and mouse state. On figure close, it submits the score to `ScoreManager`, stops the timer, calls `onCleanup()`, and deletes the figure.

### Speed-to-Color Mapping

`GameBase.flickSpeedColor(speed)` maps ball speed to an RGB color through 4 linear interpolation zones:

| Speed Range | Color Transition |
|-------------|-----------------|
| 0 - 3 | Cyan `[0, 0.92, 1]` |
| 3 - 7 | Cyan -> Green `[0.2, 1, 0.4]` |
| 7 - 12 | Green -> Gold `[1, 0.85, 0.2]` |
| 12+ | Gold -> Red `[1, 0.3, 0.2]` (saturates at ~17) |

Used by FlickIt, Juggler, Pong, and Breakout for ball core color and bounce effect coloring.

### Combo Multiplier

`comboMultiplier()` returns `max(1, Combo / 10)`. Combo 0-9 yields 1x, combo 20 yields 2x, combo 50 yields 5x. Games call `incrementCombo()` on success and `resetCombo()` on failure. The host reads `ActiveGame.Combo` each frame and manages the combo text display (show, fade, reset).

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

The host appends a summary line (`Score: N | Max Combo: N | Time: Ns`), a high score line, and play-again instructions below the game's lines. Games should not duplicate score/combo/time - the host handles those.

---

## Input Handling

### Mouse
`WindowButtonMotionFcn` updates `MousePos` each frame from `obj.Ax.CurrentPoint`. `WindowButtonDownFcn` forwards clicks to `ActiveGame.onMouseDown()` during gameplay, or handles menu item clicks and scroll thumb drag during menu state.

### Arrow keys
Generic cursor fallback: when a game does not handle arrow keys, the host moves `MousePos` at `4% * min(displayW, displayH) * DtScale` per frame. Snake has dedicated arrow direction control. Keyboard mode suppresses mouse hover in GameMenu - exited when mouse moves more than 15 pixels.

### Scroll wheel
`WindowScrollWheelFcn` scrolls the game list during menu state, or calls `ActiveGame.onScroll(-delta)` during gameplay (sign inverted).

### Key routing (onKeyPress -> dispatchKey)
Two-pass dispatch: modifier+key first (e.g., `"shift+2"`), plain key fallback. UK/US keyboard layout mapping via `shiftMap` dictionary. During `active` state, keys are tried in order: host keys (P, R, Esc) -> `ActiveGame.onKeyPress(key)` -> arrow fallback.

---

## Per-Game Technical Notes

### Pong

- **AI difficulty**: Adapts based on total score. Error = `AIErrorPx * max(0, 1 - score/(WinScore*0.8))`, speed = `AIBaseSpeed * (1 + score/WinScore * 0.5)`. Prediction uses 10-iteration bounce simulation. Recalc cooldown decrements by `DtScale` per frame. Dead zone suppresses jitter when paddle is near target and ball is moving away
- **Paddle-angle physics**: Hit offset from paddle center mapped to return angle within +-60 degrees. Both paddles use the same formula
- **Rally escalation**: `BallSpeedGain = 1.08x` per paddle hit, `wallSpeedGain = 1 + (BallSpeedGain - 1) * 0.5` per wall bounce
- **Scoring**: Paddle hit = `round(10 * Combo)`, goal = `100 + RallyHits * 10`
- **Parametric wall collision**: Exact contact time `tHit = (wallY - prePos) / stepVel` for precise reflection at any speed
- **Trail**: 20-point circular buffer, DtScale accumulator records every 2.0 units. Force-record on wall bounces and paddle hits. Not cleared on reflections, only on serve
- **Serve**: 120-frame countdown at center, ball launches at random angle within +-60 degrees toward player

### Breakout

- **Level layouts**: 5 levels with escalating brick HP. Level 1: 4 rows HP1. Level 3: sandwich (HP3/HP2/HP1/HP1/HP2/HP3). Levels 4-5: indestructible shield rows (HP=-1, silver, 0.5 alpha). 10 columns, 6 row colors (red, orange, gold, green, cyan, magenta)
- **Power-ups**: 30% spawn chance per brick destroyed. 5 types: Fireball (red), Multi-ball (cyan), Slow (blue), Wide Paddle (green), Extra Life (magenta). Capsule = 24-point circle at `5*Sc` radius
- **Two-pass swept collision**: Pass 1 finds brick with smallest parametric `tMin` (slab intersection on AABB expanded by ball radius). Pass 2 processes only that brick. Fireball mode recurses for remaining path
- **Multi-ball**: Up to `MaxBalls = 3`. Each extra ball has independent trail buffer (20-point), DtScale accumulator, and bounce force-record. Promotion deletes old handles and adopts extra ball's handles wholesale
- **Speed**: `SpeedGain = 1.04x` per paddle hit, `1.008x` per brick collision. Ball offset from paddle top: -5 data units
- **Trail**: 20-point DtScale accumulator (threshold 2.0). Force-record on wall, paddle, and brick bounces. Speed-dependent width/alpha for comet effect
- **Level transition**: 60-frame announce, then play. Life display: green flash on gain, red on loss

### Snake

- **Grid**: `GridCols = max(10, round(25 * areaW / max(areaW, areaH)))`, same for rows. Wrap-around via `mod(newHead - 1, GridDim) + 1`
- **Body pool**: 100 pre-allocated line handles with gradient colormap (256-row cyan-to-green LUT)
- **Direction**: `QueuedDir` buffer prevents 180-degree reversal and missed turns. Arrow keys or mouse-guided
- **Speed**: `StepInterval = max(1.5, 4 - (bodyLen - 5) * 0.05)` - decreases as snake grows
- **Self-collision**: Ignores first 3 neck segments to prevent false hits
- **Food spawn**: Random empty cell (200 attempts, fallback full scan). Score: `round(100 * comboMultiplier())`

### Tetris

- **SRS rotation**: 7 pieces (I/O/T/S/Z/J/L) with 4 rotation states each. I-piece uses 4x4 bounding box, others use 3x3. Wall kick tables with 5-test offsets per rotation. 7-bag randomizer ensures all pieces per cycle
- **Gravity**: Tetris Guideline formula `(0.8 - (level-1)*0.007)^(level-1)` seconds per row. Soft drop = 20x multiplier. Hard drop = instant placement + `2 * dropDistance` points
- **Lock delay**: 30 frames (0.5s at 60 FPS). Move/rotate resets the timer. DAS: 10 DtScale initial delay, 2 DtScale repeat period
- **Scoring**: 1 line=100, 2=300, 3=500, 4 (Tetris)=800 with 1.5x back-to-back bonus. Combo: `50 * ComboCount * Level`. Level = `floor(TotalLines / 10) + 1`
- **Board**: 22 rows x 10 cols (rows 1-2 hidden buffer). 220 pre-allocated cell patches + 12 next-preview + 4 ghost cells
- **Ghost piece**: Preview of landing position. `isprop(h, "XData")` guard for `GraphicsPlaceholder` handles

### Asteroids

- **Asteroid tiers**: Large (15px), Medium (10px), Small (5px). Wireframe = 8-12 random vertices per asteroid. Angular velocity (spin) = `(rand - 0.5) * 0.0208` rad/frame
- **Split mechanics**: Large -> 2 Medium, Medium -> 2 Small. Children speed `*= 1.2 + rand*0.5`
- **Autofire**: Cooldown 24 DtScale units. Bullet speed = `max(2.5, minDim*0.025)`. Swept collision: closest point on bullet segment to rock center
- **Scoring**: `round(300 / radius * 10)` per hit (smaller = more). Wave clear: `500 * Wave`. Wave progression: `nAsteroid = 3 + waveNum`, speed `*= 1 + 0.15 * (wave - 1)`
- **Lives**: 3 initial. Invulnerability = 144 frames with blinking. Ship glow: scatter marker (always round), core fully opaque

### Space Invaders

- **5 wave formations**: Wave 1 "Scouts" 8x2, Wave 2 "Battalion" 9x3 (HP 3/2/1), Wave 3 "Armada" 10x3 (HP2 all), Wave 4 "Elites" 8x4, Wave 5 "Onslaught" 10x4 (HP3 all). Speed multipliers 1.0x-1.6x
- **Bullet pools**: 10 player (cyan/red), 15 enemy (red). Player fire rate: 29 frames (12 with laser = 2x faster). Alien fire: `rand < 0.0083 * (1 + wave * 0.3) * ds` (FPS-scaled)
- **Power-ups**: 4-slot pool. 8% spawn chance per kill. Laser (8s, doubles fire rate), Shield (10s, radius = `ShipW*0.8`, 32-point cyan circle at alpha 0.08), Life
- **Scoring**: `50 * alienType` per kill (Green=1, Magenta=2, Red=3). Wave clear: `500 * Wave`. Victory at wave 5
- **Step movement**: Aliens advance in grid steps, accelerating as count decreases. Direction reversal and drop on wall contact

### Flappy Bird

- **Pipe generation**: 6-slot ring buffer. Gap = `max(35, round(areaH * 0.35))` shrinks with combo: `*= max(0.25, 1 - 0.05 * Combo)`. Pipe width = `max(12, round(areaW * 0.08))`. Spacing = `max(40, round(areaW * 0.35))`
- **Physics**: Gravity = `areaH * 0.0008` px/frame^2. Flap impulse = `-areaH * 0.013` px/frame (upward). Bird fixed at X = 25% of display width
- **Speed ramp**: Base = `max(0.333, areaW * 0.0033)`. Target = `1 + 0.06 * Combo` (6% per pipe). Decay rate: `0.0021 * PipeSpeed * ds` per frame
- **Collision**: Radius computed from scatter SizeData via `sqrt(SizeData/pi) * DPI/72 / pxPerUnit` (~3.0 data units). Using display height fraction (~18-27 units) would be 3x too large
- **Invulnerability**: 96 frames on hit, blinking red. Speed and gap revert to base on collision

### Fruit Ninja

- **Fruit pool**: 8 slots, 24-point polygon each. Gravity = `max(0.025, areaH * 0.000333)`. Launch velocity: `sqrt(2 * g * areaH * [0.55, 0.90])` (clears 55-90% height). Wall bounce coefficient 0.8
- **Slash detection**: Entry when `dist < radius + 3 && speed > threshold`. Exit when `dist > radius + 3`. Centrality = `1 - cos(smallerArc / 2)` (0=edge, 1=center)
- **Scoring**: `round(100 * (0.5 + centrality) * comboMult * multiCut)`. Multi-cut multiplier = number of fruits in same swipe
- **Multi-cut system**: First slash renders white. On 2nd+ fruit, first slash's `idxEnd` extended (age-compensated for buffer shift), fade timer reset, lines turn golden. `SwipeGenSliced` resets when first slash fades
- **Half physics**: 16-slot pool. Split velocity = fruit vel + perpendicular push + swipe momentum. Spin = +-0.025 rad/frame. Alpha decay = `0.0167 * ds`
- **Slash effects**: 6-slot pool. 29-frame fade with `sqrt(progress)` easing. Core (white 0.9 alpha) + glow (cyan 0.5 alpha). `ComboAutoFade = false`

### Target Practice

- **Difficulty progression**: Target radius shrinks `baseRadius - combo * 0.5` (min 3px). Timeout tightens `baseTimeout - combo * 0.06` (min 0.1s). 50 random spawn attempts with minimum separation from finger and previous target
- **Swept collision**: Segment (PrevPos -> Pos) vs target circle using parametric line-to-point distance. Allows fast cursor swipes to register
- **Color urgency**: Cyan -> red gradient at 60% of timeout. Trail alpha scales inversely with urgency
- **Animation**: Breathing ring `1 + 0.12 * sin(PulsePhase)`. Time bar: patch pair (background + foreground)

### Firefly Chase

- **5 tiers**: Cyan (35% spawn, 100 pts, 1.5x speed), Green (30%, 200 pts, 2.7x), Magenta (20%, 300 pts, 3.75x), Purple (10%, 400 pts, 4.8x), Gold/Snitch (5%, 500 pts, 3x + evasion)
- **Path generation**: Tier-dependent types. Tier 1: curves/S-curves. Tier 2: waves/oscillations/arcs. Tier 3: closed loops/figure-8s/spirals. PCHIP resampling to ~1px spacing. Random rotation and 50% direction flip
- **Snitch evasion**: Lissajous base trajectory with frequency pairs [3,2]/[5,4]/[3,4]/[5,2]/[7,4]/[5,6]. Quadratic push falloff over 100*Sc radius, strength 8*Sc, damping `0.9664^ds`
- **Graphics pool**: 4 slots, each with dot + aura + trail + trailGlow handles. Snitch trail: 10-point circular buffer, DtScale accumulator
- **Spawn**: Up to 3 simultaneous. Cooldown = `max(19, 72 - elapsed * 0.3)` frames

### Flick It!

- **Flick detection**: 5-frame velocity ring buffer. Minimum threshold: `3 / SpeedScale`. Lock prevents double-flick. Velocity boost: 1.3x on flick
- **Physics**: Friction = `0.9958^ds` per frame. Restitution = 0.80 on wall bounce. Stop threshold: `norm(vel) < 0.3 / SpeedScale`. Parametric wall collision for exact contact time
- **Speed-to-color**: `flickSpeedColor(speed * SpeedScale)` via `GameBase` - cyan at rest, red at max speed. Affects core, glow, and trail rendering
- **Scoring**: Flick = `round(speed * SpeedScale * 5 * max(1, Combo * 0.5))`. Bounce = `round((5 + speed * SpeedScale * 2) * max(1, Combo * 0.5))`. Combo increments on re-flick of moving ball
- **Trail**: 30-point circular buffer with DtScale accumulator. 3-layer rendering: aura (opaque), glow (alpha 0.4), core (white)

### Juggler

- **Gravity**: `max(0.021, areaH * 0.000417)` per frame. No bottom wall - ball drops out
- **Flick vs natural bounce**: Active flick (finger velocity >= threshold): `vel = fingerVel * 1.3`. Natural bounce (fall onto stationary hand): `vy = -|vy| * 0.75`, clamped to min bounce. Lock: 0.15s after contact
- **Multi-ball**: Extra ball spawned every 10 combo. Promotion on main ball drop: adopt position, velocity, trail buffers, lock state, flick count from first extra ball
- **Stats**: `Bounces` (per-ball), `BestStreak` (longest chain), `Drops` (total), `MaxSpeed` (peak)
- **Danger zone**: Red line near bottom, alpha increases with proximity + pulse `0.08 * sin(phase * 3)`

### Orbital Defense

- **Base**: Hexagonal shape at display center. Radius = `max(8, round(minDim * 0.035))`
- **3 asteroid tiers**: Large (15*Sc, 1.0x speed), Medium (10*Sc, 1.5x), Small (5*Sc, 2.2x). 8-12 random wireframe vertices. Split on destroy: 2 children at `speed *= 1.2 + rand*0.5`
- **Pools**: 10 interceptors + 12 explosions + 50 asteroids. Fire cooldown: 36 frames
- **Chain explosions**: Expanding explosion circles destroy asteroids within `ExpRadius + AstRadius`. Contraction follows expansion (visual fade). Chain cascades when explosions overlap
- **Wave scaling**: `nLarge = 2 + wave`, `nMedium = 1 + floor(wave*0.8)`, `nSmall = floor(wave*0.6)`. Speed = `baseSpeed * (1 + wave * 0.08)`. Clear bonus: `200 * wave`

### Shield Guardian

- **Shield**: 180-degree arc at `ShieldRadius = max(7, minDim * 0.08)` from center. Follows cursor angle. Core hitbox = `CoreRadius * 0.9`
- **3 projectile types**: Fast (red, 1.5x speed, small), Normal (magenta, 1.0x, medium), Heavy (orange, 0.6x, large). 20-slot pool
- **Swept quadratic collision**: Line segment vs shield arc circle. Quadratic `a*t^2 + b*t + c = 0` for intersection, then angle check within shield span. Deflection: `vel - 2*dot(vel,normal)*normal`, boosted 1.5x with outward push
- **Chain deflection**: Deflected projectiles can hit incoming ones (50 pts per chain hit)
- **Wave scaling**: Spawn interval = `max(19, 72 - Wave * 5)` frames. Speed = `baseSpeed * (1 + Wave * 0.1)`

### Rail Shooter

- **Perspective**: Vanishing point at display center. Depth scale = `0.15 + (1 - depth) * 0.85`. Screen projection: `screenPos = vpPos + (spawnPos - vpPos) * scale`
- **4 enemy types**: Fighter (HP 3, speed 0.003, 14 vertices), Cruiser (HP 8, speed 0.0018, 28 vertices, 1.5x size), Interceptor (HP 2, speed 0.0038, 18 vertices, 0.7x), Dreadnought (HP 25, speed 0.0012, 35 vertices, 2.2x boss). HP scales `+floor(Wave/3)` per wave
- **Wave structure**: Waves 1-5 hand-crafted compositions. Wave 6+: procedural mix of `4+floor(N/2)` grunts, `1+floor(N/3)` cruisers, `1+floor(N/2)` interceptors, `floor(N/5)` bosses
- **Defeat animation**: 4-phase color transition (white -> yellow-red -> dark orange) with expansion `1 + progress^0.7 * 2.5`, jitter, and `(1-progress)^0.6` alpha decay
- **Combat**: Auto-fire cooldown = 7 frames. Breathing crosshair: `frameCount += ds`. Damage flash: 19-frame fade. Screen shake on hit. HP bars: green (>50%) -> gold (>25%) -> red
- **Boss weak point**: Pulsing scatter at center with `0.2 + 0.08 * sin(phase*3)` modulation

---

## HTML5 Canvas Port

The browser port (`web/arcade.html`) replicates all 15 games in a single self-contained HTML file. No external dependencies - all rendering, physics, and menu logic is inline.

All physics constants, scoring formulas, pool sizes, DtScale scaling, trail systems, wave/level progression, and collision detection have been verified identical between the MATLAB and HTML implementations across all 15 games.

### Architecture

A single `<canvas>` element with `requestAnimationFrame` game loop. Each game is a class with `init()`, `update(pos, ds)`, `render(ctx)`, and `cleanup()` methods mirroring the MATLAB `GameBase` interface. The menu is a dedicated render mode with the same starfield, comets, and pill-shaped slots.

### Key Differences from MATLAB

| Aspect | MATLAB | HTML5 Canvas |
|--------|--------|--------------|
| Coordinate origin | Top-left (`YDir = "reverse"`) | Top-left (canvas default) |
| Marker rendering | Opaque line markers | `fillStyle` with `globalAlpha` |
| Ball aura | Line marker (always opaque) | `arc()` fill (opaque, to match MATLAB) |
| Trail rendering | Line/patch with property updates | `strokeStyle` + `lineWidth` per segment |
| Text coloring | TeX `\color[rgb]{r g b}` | `ctx.fillStyle` with `rgb()` |
| Hit effects | Pre-allocated `gobjects` pool | Array of plain JS objects |
| Timer | `fixedSpacing` at 0.02s | `requestAnimationFrame` (~60 Hz) |
| Alpha on lines | RGBA 4th element (undocumented) | `globalAlpha` before stroke |
| Font units | Points (72 per inch) | Pixels (CSS pixels) |
| Keyboard | `KeyPressFcn` on figure | `addEventListener("keydown")` |

### Scatter SizeData to Canvas Conversion

MATLAB scatter `SizeData` is in points^2. To convert to canvas pixel radius:

```javascript
// SizeData -> radius in points -> radius in pixels
radiusPts = Math.sqrt(SizeData / Math.PI);
radiusPx = radiusPts * (DPI / 72);
```

For ball glow effects, a measured correction factor of 1.20x is applied: `glow_radius = sqrt(SizeData / PI) * 1.20`.

### Hit Effects in HTML

A single `hitEffects.update(ctx, ds)` call both advances animation and draws to canvas. An earlier bug had separate `update(ds)` and `draw(ctx)` calls - but `draw(ctx)` internally called `update(ctx)` again, passing the canvas context as the `ds` number. This caused `frames -= undefined` which produced `NaN`, permanently corrupting all active effects. The fix: one combined call.

### Browser Shortcut Passthrough

F5, F12, and Ctrl+key combinations are not intercepted by the game's `keydown` handler - they pass through to the browser. Only game-specific keys (arrows, P, R, Esc, Space) are captured with `preventDefault()`.

---

## Orphan Cleanup

Every game tags its graphics with a prefix like `"GT_pong"`, `"GT_breakout"`, etc. Hit effects use `"GT_fx"`. The host's HUD uses `"GT_arc"`.

On game exit, `enterMenu()` and `enterResults()` call:

```matlab
orphans = findall(obj.Ax, "-regexp", "Tag", "^GT_(?!arc)");
delete(orphans);
```

The regex `^GT_(?!arc)` matches all `GT_`-prefixed tags except `GT_arc*` (the arcade HUD), ensuring game graphics are cleaned up without destroying the launcher's own text handles. Each game's `onCleanup()` also deletes its own handles explicitly, but the orphan guard catches anything missed (e.g., hit effects still animating).

---

## ScoreManager

`services.ScoreManager` is a static utility class. All methods are static - no instance needed.

### Storage

Scores persist in `data/scores.mat` (auto-created in the project root on first play, excluded from git). The MAT-file contains a single `scores` struct where each field is a game ID (e.g., `Pong`, `Breakout`) mapping to a record struct:

```matlab
record.highScore    % highest score achieved
record.maxCombo     % highest combo achieved
record.plays        % total number of plays
record.totalTime    % cumulative session time (seconds)
```

### Game ID

`ScoreManager.classToId(game)` converts a game class name to an ID string. For package-qualified names like `games.Pong`, it extracts `"Pong"`. This ID is used as the struct field name in the scores file.

### Submission

`ScoreManager.submit(gameId, score, maxCombo, elapsed)` updates the record:
- `highScore = max(existing, score)`
- `maxCombo = max(existing, maxCombo)`
- `plays = plays + 1`
- `totalTime = totalTime + elapsed`

Returns `[isNewHigh, record]` where `isNewHigh` is true if the submitted score exceeds the previous high.

---

## Packaging

Three scripts in `packaging/` produce distributable artifacts:

### generateIcon.m

Generates `icon.png` (256x256 via `getframe` + `imresize`), `icon.ico` (multi-resolution 16/32/48/256 via custom PNG-based ICO writer), `splash.png` and `preview.png` (800x600 4:3 at 300 DPI via `exportgraphics`). The preview features the neon "A" ship with inner polybuffer rhombus, menu-style title with shadow, 4 symmetric comet trails, and starfield.

### buildToolbox.m

Creates `Arcade.mltbx` via `matlab.addons.toolbox.ToolboxOptions` (R2023b+). Includes `Arcade.m`, all 4 packages (`+engine`, `+games`, `+services`, `+ui`), `web/` folder (HTML port), `README.md`, and `docs/DEVELOPER.md`. Excludes `recording/`, `assets/`, `data/`, `docs/TODO.md`, and `packaging/`. Uses `icon.png` as `ToolboxImageFile`.

### buildExecutable.m

Two-phase build:

1. **Standalone exe**: `compiler.build.standaloneWindowsApplication` with `ExecutableIcon` (icon.png, converted to .ico internally by MATLAB Compiler) and `ExecutableSplashScreen` (splash.png). Includes all 4 package folders as `AdditionalFiles`.
2. **Installer**: `compiler.package.installer` with `InstallerIcon`, `InstallerSplash`, `InstallerLogo` (preview.png), `RuntimeDelivery = "web"` (downloads MATLAB Runtime during installation), and full metadata (name, author, version, description, default install path).

Output: `build/Arcade.exe` (~1.5 MB) + `installer/ArcadeInstaller.exe` (~2.8 MB).

### GitHub Releases

The project uses GitHub Releases for versioned distribution. Each release consists of:

- **Git tag** pointing to a specific commit (e.g., `v1.0`)
- **Release notes** describing changes (see `RELEASE_NOTES.md` for template)
- **Binary assets** attached manually: `Arcade.mltbx` and `ArcadeInstaller.exe`
- **Source archives** auto-generated by GitHub (zip and tar.gz of the repo at that tag)

File Exchange (linked via GitHub Releases mode) detects the `.mltbx` attachment and offers it as a "Download Toolbox" option. If no `.mltbx` is attached, File Exchange falls back to the source zip.

To create a release:

```bash
git tag v1.0
git push origin v1.0
gh release create v1.0 --title "v1.0 - Arcade" --notes-file RELEASE_NOTES.md
gh release upload v1.0 packaging/Arcade.mltbx packaging/installer/ArcadeInstaller.exe
```

---

## Recording

Scripts in `recording/` capture gameplay and menu animations for documentation GIFs:

- **`recordGame.m`**: Records a game session to GIF + MP4. Creates a figure, runs the game via `play()`-like loop, captures frames via `getframe`, builds GIF with global colormap via `rgb2ind`
- **`recordPlay.m`**: Live recording with real input. Optional frame limit. Save prompt offers custom FPS (`f`), target duration (`s`), or discard (`n`)
- **`recordMenu*.m`**: 4 variants of menu scroll recording with different navigation speeds
- **`recordAll.m`**: Batch orchestrator for all recordings
- **`createHeroGif.m`**: Generates hero GIF from captured frames

All GIFs use `rgb2ind` with a shared global colormap built from sampled frames for consistent palette. MP4s use `VideoWriter` with MPEG-4 at 95% quality.

---

## Color Palette

All games share 6 named color constants defined in `GameBase`:

| Name | RGB | Usage |
|------|-----|-------|
| `ColorCyan` | `[0, 0.92, 1]` | Primary neon - balls, trails, menus, targets, shields |
| `ColorGreen` | `[0.2, 1, 0.4]` | Scoring events, combo text, life gain flash |
| `ColorGold` | `[1, 0.85, 0.2]` | High score, multi-cut slash, boss highlights |
| `ColorRed` | `[1, 0.3, 0.2]` | Damage, life loss flash, high-speed ball, enemies |
| `ColorWhite` | `[1, 1, 1]` | Ball core, text, UI chrome |
| `ColorMagenta` | `[1, 0.3, 0.85]` | Tier 3 enemies, mid-tier fireflies |

The background color is `[0.015, 0.015, 0.03]` - near-black with a slight blue tint. The menu title and decorative elements use a muted teal `[0.0, 0.55, 0.65]` with a dark shadow `[0, 0.12, 0.17]`.

---

## Adding a New Game

### Steps

1. Create `+games/MyGame.m` extending `engine.GameBase`
2. Set the `Name` constant property (display name in menu and results)
3. Implement the 4 required methods: `onInit`, `onUpdate`, `onCleanup`, `onKeyPress`
4. Pre-allocate all graphics in `onInit` - no `line()`, `scatter()`, `patch()`, or `text()` in `onUpdate`
5. Tag all graphics with `"GT_mygame"` for orphan cleanup
6. Register in `Arcade.buildRegistry()`:
   ```matlab
   obj.registerGame("16", @games.MyGame, "My Game");
   ```
7. High scores are tracked automatically on first play (no additional setup)

### Minimal Example

```matlab
classdef MyGame < engine.GameBase
    properties (Constant)
        Name = "My Game"
    end
    properties (Access = private)
        DotH    % scatter handle
    end
    methods
        function onInit(obj, ax, ~, ~)
            ps = obj.FontScale;
            obj.DotH = scatter(ax, NaN, NaN, 200 * ps^2, ...
                obj.ColorCyan, "filled", "Tag", "GT_mygame");
        end
        function onUpdate(obj, pos)
            obj.DotH.XData = pos(1);
            obj.DotH.YData = pos(2);
            obj.addScore(1);
        end
        function onCleanup(obj)
            if ~isempty(obj.DotH) && isvalid(obj.DotH)
                delete(obj.DotH);
            end
            obj.DotH = [];
            engine.GameBase.deleteTaggedGraphics(obj.Ax, "^GT_mygame");
        end
        function handled = onKeyPress(~, ~)
            handled = false;
        end
    end
end
```

### Checklist

- [x] All physics multiplied by `obj.DtScale` (velocity, gravity, phase)
- [x] All random events scaled by `obj.DtScale` (spawn rates, fire rates)
- [x] All font sizes use `base * obj.FontScale`
- [x] No `getpixelposition` or `get(0, "ScreenPixelsPerInch")` in per-frame code
- [x] No graphics creation/deletion in `onUpdate`
- [x] Trail buffers use DtScale accumulator (if applicable)
- [x] `getResults()` returns game-specific stats (host adds score/combo/time)
- [x] `onCleanup()` deletes all handles + orphan guard
- [x] `ComboAutoFade = false` if combo should persist between events (e.g., Breakout, FruitNinja)
