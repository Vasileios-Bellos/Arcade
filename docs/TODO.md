# Arcade TODO

Working checklist extracted from CLAUDE.md. The master reference remains CLAUDE.md.

---

## Testing

- [ ] Test all 15 arcade games: Pong, Breakout, Snake, Tetris, Asteroids, SpaceInvaders, FlappyBird, FruitNinja, TargetPractice, FireflyChase, FlickIt, Juggler, OrbitalDefense, ShieldGuardian, RailShooter

---

## Screen-Space Scaling

All 15 arcade games plus infrastructure are already scaled (18 files total):
ArcadeGameLauncher.m, GameBase.m, GameMenu.m, +games/Pong.m, +games/Breakout.m,
+games/Snake.m, +games/Tetris.m, +games/Asteroids.m, +games/SpaceInvaders.m,
+games/FlappyBird.m, +games/FruitNinja.m, +games/TargetPractice.m, +games/FireflyChase.m,
+games/FlickIt.m, +games/Juggler.m, +games/OrbitalDefense.m, +games/ShieldGuardian.m,
+games/RailShooter.m.

No pending scaling work for arcade games.

---

## Sound Effects

- [ ] Add sound effects to arcade games -- hits, combos, bounces, game over, menu navigation. Investigate `audioplayer`/`sound()` with pre-loaded WAV buffers or synthesized tones. Must not block the render loop

---

## Per-Game TODOs (from code comments)

- [ ] **TargetPractice**: Target timeout uses wall-clock time (toc), not DtScale — only gameplay-affecting tic/toc usage
- [x] **RailShooter**: Renamed death→defeat terminology (done in this session)

**Note — wall-clock tic/toc (cosmetic, intentionally real-time):**
Combo decay (FlickIt, FireflyChase, Pong), lives/wave flash animations (Asteroids, Breakout, SpaceInvaders, OrbitalDefense, ShieldGuardian, RailShooter), power-up expiry (Breakout, SpaceInvaders), flick lock cooldown (Juggler), wave advancement timer (ShieldGuardian), difficulty ramp (FireflyChase). These are deliberate real-time durations, not physics.

---

## Host-Level Trace Buffer

- [ ] ArcadeGameLauncher should maintain a smoothed trace buffer (shifting array + `smoothdata("gaussian", 9)` cache) identical to GestureMouse's `SmoothedTraceX/Y`, passed to games via `caps.getSmoothedTrace`. FruitNinja and FourierEpicycle should read from host trace instead of maintaining their own buffers

---

## Decoupling from GestureMouse (Pre-Split)

- [ ] **Decouple GlyphTracing from GestureMouse** -- extract `buildGlyphCache()` into `+games/GlyphUtils.m` so GlyphTracing can build its own glyph cache standalone
- [ ] **Decouple FruitNinja from GestureMouse** -- add internal trace buffer (circular buffer of `onUpdate(pos)` positions + `smoothdata`) instead of reading `SmoothedTraceX/Y`

---

## Repo Split and Distribution

- [ ] Split `+games/` -- arcade games stay in `+games/` with `GameBase`; simulations extracted as individual standalones
- [ ] Update `ArcadeGameLauncher.buildRegistry()` to only include arcade games
- [x] Rename ARCADE_README.md to README.md (done)
- [ ] GameHost interface cleanup -- accept generic struct/interface instead of GestureMouse instance directly
- [ ] MATLAB File Exchange listing: "MATLAB Arcade" -- standalone mouse-driven arcade, no webcam needed
- [x] MATLAB Toolbox (.mltbx) — built, packaging/MATLABArcade.mltbx
- [x] Standalone executable — built, packaging/build/MATLABarcade.exe (Windows GUI, no console)
- [x] Installer — built, packaging/installer/MATLABarcadeInstaller.exe (web runtime delivery)

---

## Documentation

- [ ] Move screen-space scaling documentation from CLAUDE.md to DEVELOPER.md — the FontScale system, creation/resize rules, onFigResize flow, standalone vs hosted, scaleScreenSpaceObjects
- [ ] Repurpose DEVELOPER.md into a proper technical details document with per-game breakdowns (physics, scoring formulas, pool sizes, etc.)

## Game Bugs

- [ ] Tetris: rapidly rotating a piece on low speed can stall it indefinitely on the landing row — instant lock doesn't prevent rotation-based stalling

## MATLAB Bugs

- [ ] Menu rendering glitch on ESC back to menu — sometimes shows only shooting stars/partial menu, buttons missing, or split screen between game and menu. **Root cause investigation:** Timer race condition during `enterMenu`. The timer's `onFrame` can fire mid-transition while some handles are deleted but others not yet shown. The `try-catch` in `onFrame` suppresses "Invalid or deleted" errors (line 436), but the visual state is inconsistent for one frame. Stars/comets are NOT running in background during gameplay — they're just hidden MATLAB objects. **Proposed fix:** Stop timer during `enterMenu` (like we do in `launchGame`), execute the transition, restart timer. This prevents the mid-transition render frame

## Performance

- [x] Investigate jumpy/stuttery gameplay at 40+ FPS — EMA dt smoothing tested and reverted (introduced lag-induced jitter). Raw dt with cap at 0.1s is the correct approach. Mouse motion callback overhead during drawnow is a known MATLAB limitation

## HTML Port

- [ ] Remove console.log debug messages from arcade.html before release
- [ ] Fix remaining game launch errors (test all 15 games in browser)
- [ ] Verify all game physics/scoring match MATLAB versions
- [x] Trail rendering — fixed: path-based fireflies use carry-over on loop; Pong/Breakout/FlickIt/Juggler use DtScale accumulator
- [x] FlickIt/Juggler velocity — fixed: raw deltas + 1/ds normalization at flick point
- [x] Ball layer sizes — measured individually from MATLAB getframe (Pong: 1.53r/1.14r/0.43r, FlickIt: 1.50r/0.63r/0.23r)
- [x] Ball layer z-order — aura behind, glow on top (matching MATLAB creation order)
- [x] Firefly rendering — 2 circles only (aura fixed 0.35 alpha + core solid), no white center, no breathing aura
- [ ] Flappy Bird — bird circles too large vs MATLAB, green burst on pipe clear that MATLAB doesn't have
- [ ] Fruit Ninja — multi-cut needs continuous slash line, not per-fruit lines
- [ ] Menu title shadow/glow — add glow text layer behind title to match MATLAB
- [ ] RailShooter — verify defeat effect sizes and score text formatting
- [ ] Pong AI jitter — add TODO to smooth AI paddle when stationary
- [ ] Juggler results text — rename "Best Flick Streak" (in both MATLAB and HTML)
- [ ] Menu scrollbar — mouse drag now working, test on mobile
- [ ] Test on multiple browsers (Chrome, Firefox, Edge)
- [ ] Test on mobile (touch events added)

## Code Quality

- [ ] Checkcode warnings cleanup across arcade files
- [ ] Time-based animation normalization -- convert frame-counting animations (countdown, sweep preview, scored display, gap, hit effects) to elapsed-time (`tic`/`toc`) for frame-rate-independent animation
- [ ] Improve comet tail visual -- tapered width, per-vertex alpha gradient
- [ ] Tune snitch evasion parameters (100px radius, push 8, damping 0.92) -- may need tweaking
