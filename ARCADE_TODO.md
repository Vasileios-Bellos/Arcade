# Arcade TODO

Working checklist extracted from CLAUDE.md. The master reference remains CLAUDE.md.

---

## Testing

- [ ] Test all 15 arcade games: Pong, Breakout, Snake, Tetris, Asteroids, SpaceInvaders, FlappyBird, FruitNinja, TargetPractice, Fireflies, FlickIt, Juggling, OrbitalDefense, ShieldGuardian, RailShooter

---

## Screen-Space Scaling

All 15 arcade games plus infrastructure are already scaled (18 files total):
ArcadeGameLauncher.m, GameBase.m, GameMenu.m, +games/Pong.m, +games/Breakout.m,
+games/Snake.m, +games/Tetris.m, +games/Asteroids.m, +games/SpaceInvaders.m,
+games/FlappyBird.m, +games/FruitNinja.m, +games/TargetPractice.m, +games/Fireflies.m,
+games/FlickIt.m, +games/Juggling.m, +games/OrbitalDefense.m, +games/ShieldGuardian.m,
+games/RailShooter.m.

No pending scaling work for arcade games.

---

## Sound Effects

- [ ] Add sound effects to arcade games -- hits, combos, bounces, game over, menu navigation. Investigate `audioplayer`/`sound()` with pre-loaded WAV buffers or synthesized tones. Must not block the render loop

---

## Per-Game TODOs (from code comments)

- [ ] **TargetPractice**: Target timeout uses wall-clock time (toc), not DtScale. If RefFPS is changed, timeout duration stays the same. Consider scaling timeout by RefFPS ratio
- [ ] **RailShooter**: Rename "death" terminology (deathFrame, deathMaxFrames, deathAlpha, dying) to "defeat" or "elimination". Also affects Juggling.m

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
- [ ] Rename ARCADE_README.md to README.md in the arcade portion
- [ ] GameHost interface cleanup -- accept generic struct/interface instead of GestureMouse instance directly
- [ ] MATLAB File Exchange listing: "MATLAB Arcade" -- standalone mouse-driven arcade, no webcam needed
- [ ] Optional: MATLAB Toolbox (.mltbx) packaging as GitHub release asset

---

## Code Quality

- [ ] Checkcode warnings cleanup across arcade files
- [ ] Time-based animation normalization -- convert frame-counting animations (countdown, sweep preview, scored display, gap, hit effects) to elapsed-time (`tic`/`toc`) for frame-rate-independent animation
- [ ] Improve comet tail visual -- tapered width, per-vertex alpha gradient
- [ ] Tune snitch evasion parameters (100px radius, push 8, damping 0.92) -- may need tweaking
