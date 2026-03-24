# Arcade TODO

Working checklist and future implementations extracted from CLAUDE.md (master reference remains).

---

## Sound Effects

- [ ] Add sound effects to arcade games - hits, combos, bounces, game over, menu navigation. Investigate `audioplayer`/`sound()` with pre-loaded WAV buffers or synthesized tones. Must not block the render loop

---

## Known Bugs

- [ ] Tetris: rapidly rotating a piece on low speed can stall it indefinitely on the landing row - instant lock doesn't prevent rotation-based stalling
- [ ] Breakout: corner-hit edge case - ball approaching at shallow angle can sometime reflect off wrong face at brick corners

---

## HTML Port

- [ ] Test on mobile (touch events)
- [ ] Verify all game physics/scoring match MATLAB versions

---

## Code Quality

- [ ] Checkcode warnings cleanup across arcade files
- [ ] Improve comet tail visual - tapered width, per-vertex alpha gradient

---

## Documentation

- [x] Move screen-space scaling documentation from CLAUDE.md to DEVELOPER.md
- [x] Repurpose DEVELOPER.md into a proper technical details document with per-game breakdowns
- [x] README overhaul with per-game descriptions, technical highlights, distribution section
- [x] Icon redesign (neon "A" with polybuffer rhombus), preview/splash generation
- [x] Packaging scripts updated (exe + installer with custom branding, toolbox with web port)

---

## Resolved Issued

- [x] Menu ESC glitch - timer stop during enterMenu
- [x] Pong AI paddle jitter - dead zone + DtScale recalc cooldown
- [x] DtScale smoothing - tested EMA, reverted to raw dt
- [x] SpaceInvaders alien fire rate - scaled by ds
- [x] RailShooter secondary explosions - scaled by ds, reduced to single defeat burst
- [x] RailShooter hit effects - fixed double update/draw NaN corruption
- [x] RailShooter crosshair breathing - frameCount += ds, ring static
- [x] Fruit Ninja multi-cut - extending slash line + golden color on ×2+
- [x] Fruit Ninja slash threshold - lowered from 0.008 to 0.002
- [x] Flappy Bird - smaller bird (collisionR-based), removed green burst + shadowBlur
- [x] Ball aura opacity - opaque in Pong, Breakout, FlickIt, Juggler
- [x] FlickIt/Juggler core shadowBlur removed
- [x] Asteroids ship shadowBlur removed, core fully opaque
- [x] Menu title/subtitle colors - match MATLAB [0, 0.55, 0.65]
- [x] White color - corrected to [255, 255, 255]
- [x] Juggler - "bounces" terminology, "Best Streak"
- [x] Combo font size - 8*FontScale in Pong/FlickIt/FireflyChase
- [x] Pong - removed "PLAYER SCORES"/"CPU SCORES" flash text
- [x] NEW HIGH SCORE - gold TeX color in MATLAB, gold in HTML
- [x] F5/F12/Ctrl browser shortcuts - no longer blocked
- [x] Trail fps-independence - DtScale accumulator + bounce force-record (Pong, Breakout, FlickIt, Juggler)
- [x] Trail keeps on paddle hit - Pong and Breakout (MATLAB + HTML)
- [x] Breakout multiball - identical appearance/trails, seamless handle adoption on promotion
- [x] Breakout brick collision - two-pass earliest-tMin (MATLAB + HTML)
- [x] Breakout hit effects - render after game graphics, fixed NaN corruption
- [x] Breakout serve timing - removed duplicate serveBall call
- [x] FireflyChase snitch trail - DtScale accumulator, buffer 10
- [x] TargetPractice timeout - wall-clock is correct
- [x] Tetris NextCell - isprop guard for GraphicsPlaceholder

**Note - wall-clock tic/toc (cosmetic, intentionally real-time):**
Combo decay (FlickIt, FireflyChase, Pong), lives/wave flash animations (Asteroids, Breakout, SpaceInvaders, OrbitalDefense, ShieldGuardian, RailShooter), power-up expiry (Breakout, SpaceInvaders), flick lock cooldown (Juggler), wave advancement timer (ShieldGuardian), difficulty ramp (FireflyChase).
