# Arcade TODO

Working checklist extracted from CLAUDE.md. The master reference remains CLAUDE.md.

---

## Sound Effects

- [ ] Add sound effects to arcade games -- hits, combos, bounces, game over, menu navigation. Investigate `audioplayer`/`sound()` with pre-loaded WAV buffers or synthesized tones. Must not block the render loop

---

## Game Bugs

- [ ] Tetris: rapidly rotating a piece on low speed can stall it indefinitely on the landing row — instant lock doesn't prevent rotation-based stalling
- [ ] RailShooter: crosshair ring size needs proper measurement from MATLAB to match HTML
- [ ] Asteroids: ship size may be slightly larger in HTML than MATLAB — needs verification
- [ ] Breakout: corner-hit edge case — ball approaching at shallow angle can reflect off wrong face at brick corners

---

## HTML Port

- [ ] Test on mobile (touch events)
- [ ] Verify all game physics/scoring match MATLAB versions
- [ ] FlickIt/Juggler ball aura opacity — set opaque in HTML, needs user visual confirmation vs MATLAB

---

## Repo Split and Distribution

- [ ] Split `+games/` -- arcade games stay in `+games/` with `GameBase`; simulations extracted as individual standalones
- [ ] Update `ArcadeGameLauncher.buildRegistry()` to only include arcade games
- [ ] GameHost interface cleanup -- accept generic struct/interface instead of GestureMouse instance directly
- [ ] MATLAB File Exchange listing: "MATLAB Arcade" -- standalone mouse-driven arcade, no webcam needed

---

## Documentation

- [ ] Move screen-space scaling documentation from CLAUDE.md to DEVELOPER.md
- [ ] Repurpose DEVELOPER.md into a proper technical details document with per-game breakdowns

---

## Code Quality

- [ ] Checkcode warnings cleanup across arcade files
- [ ] Improve comet tail visual -- tapered width, per-vertex alpha gradient

---

## Completed This Session

- [x] Menu ESC glitch — timer stop during enterMenu
- [x] Pong AI paddle jitter — dead zone + DtScale recalc cooldown
- [x] DtScale smoothing — tested EMA, reverted to raw dt
- [x] SpaceInvaders alien fire rate — scaled by ds
- [x] RailShooter secondary explosions — scaled by ds, reduced to single defeat burst
- [x] RailShooter hit effects — fixed double update/draw NaN corruption
- [x] RailShooter crosshair breathing — frameCount += ds, ring static
- [x] Fruit Ninja multi-cut — extending slash line + golden color on ×2+
- [x] Fruit Ninja slash threshold — lowered from 0.008 to 0.002
- [x] Flappy Bird — smaller bird (collisionR-based), removed green burst + shadowBlur
- [x] Ball aura opacity — opaque in Pong, Breakout, FlickIt, Juggler
- [x] FlickIt/Juggler core shadowBlur removed
- [x] Asteroids ship shadowBlur removed, core fully opaque
- [x] Menu title/subtitle colors — match MATLAB [0, 0.55, 0.65]
- [x] White color — corrected to [255, 255, 255]
- [x] Juggler — "bounces" terminology, "Best Streak"
- [x] Combo font size — 8*FontScale in Pong/FlickIt/FireflyChase
- [x] Pong — removed "PLAYER SCORES"/"CPU SCORES" flash text
- [x] NEW HIGH SCORE — gold TeX color in MATLAB, gold in HTML
- [x] F5/F12/Ctrl browser shortcuts — no longer blocked
- [x] Trail fps-independence — DtScale accumulator + bounce force-record (Pong, Breakout, FlickIt, Juggler)
- [x] Trail keeps on paddle hit — Pong and Breakout (MATLAB + HTML)
- [x] Breakout multiball — identical appearance/trails, seamless handle adoption on promotion
- [x] Breakout brick collision — two-pass earliest-tMin (MATLAB + HTML)
- [x] Breakout hit effects — render after game graphics, fixed NaN corruption
- [x] Breakout serve timing — removed duplicate serveBall call
- [x] FireflyChase snitch trail — DtScale accumulator, buffer 10
- [x] TargetPractice timeout — wall-clock is correct
- [x] Tetris NextCell — isprop guard for GraphicsPlaceholder

**Note — wall-clock tic/toc (cosmetic, intentionally real-time):**
Combo decay (FlickIt, FireflyChase, Pong), lives/wave flash animations (Asteroids, Breakout, SpaceInvaders, OrbitalDefense, ShieldGuardian, RailShooter), power-up expiry (Breakout, SpaceInvaders), flick lock cooldown (Juggler), wave advancement timer (ShieldGuardian), difficulty ramp (FireflyChase).
