# Arcade TODO

Roadmap and issue tracker. See [DEVELOPER.md](DEVELOPER.md) for architecture details.

---

## Future Enhancements

- [ ] Sound effects - hits, combos, bounces, game over, menu navigation. Investigate `audioplayer`/`sound()` with pre-loaded WAV buffers or synthesized tones. Must not block the render loop
- [ ] Improve comet tail visual in menu - tapered width, per-vertex alpha gradient
- [ ] HTML port - test on mobile (touch events)

---

## Known Bugs

- [ ] Tetris: rapidly rotating a piece on low speed can stall it indefinitely on the landing row - instant lock doesn't prevent rotation-based stalling
- [ ] Breakout: corner-hit edge case - ball approaching at shallow angle can sometimes reflect off wrong face at brick corners

---

## Cross-Platform Verification (MATLAB vs HTML)

Full comparison completed across all 15 games. All physics constants, scoring formulas, pool sizes, DtScale scaling, trail systems, wave/level progression, and collision detection are matched between MATLAB and HTML. No discrepancies found.

---

## Resolved Issues

### Frame-Rate Independence
- [x] DtScale smoothing - tested EMA, reverted to raw dt (per-frame rawDt * RefFPS)
- [x] Trail fps-independence - DtScale accumulator + bounce force-record (Pong, Breakout, FlickIt, Juggler)
- [x] SpaceInvaders alien fire rate - scaled by ds
- [x] RailShooter secondary explosions - scaled by ds, reduced to single defeat burst
- [x] RailShooter crosshair breathing - frameCount += ds, ring static

### Breakout
- [x] Brick collision - two-pass earliest-tMin swept detection (MATLAB + HTML)
- [x] Multiball - identical appearance/trails, seamless handle adoption on promotion
- [x] Hit effects - render after game graphics, fixed NaN corruption in HTML
- [x] Serve timing - countdown runs concurrently with level announce, ball launches when text disappears
- [x] Serve trail bug - trail accumulator gated with !Serving to prevent horizontal line during paddle movement
- [x] Dead transition phase - removed unreachable 96-frame brick fade (bricks already destroyed at trigger)
- [x] Trail keeps on paddle hit - no longer cleared on reflection (MATLAB + HTML)

### Pong
- [x] AI paddle jitter - dead zone + DtScale-scaled recalc cooldown
- [x] Removed "PLAYER SCORES"/"CPU SCORES" flash text
- [x] Trail keeps on paddle hit (MATLAB + HTML)

### Visual Consistency (MATLAB + HTML)
- [x] Ball aura opacity - opaque in Pong, Breakout, FlickIt, Juggler
- [x] FlickIt/Juggler core shadowBlur removed
- [x] Asteroids ship shadowBlur removed, core fully opaque
- [x] Flappy Bird - smaller bird (collisionR-based), removed green burst + shadowBlur
- [x] Menu title/subtitle colors - match MATLAB [0, 0.55, 0.65]
- [x] White color - corrected to [255, 255, 255]
- [x] Combo font size - 8*FontScale in Pong/FlickIt/FireflyChase
- [x] NEW HIGH SCORE - gold TeX color in MATLAB, gold in HTML

### Other Fixes
- [x] Menu ESC glitch - timer stop during enterMenu
- [x] RailShooter hit effects - fixed double update/draw NaN corruption
- [x] Fruit Ninja multi-cut - extending slash line + golden color on x2+
- [x] Fruit Ninja slash threshold - lowered from 0.008 to 0.002
- [x] Juggler - "bounces" terminology, "Best Streak"
- [x] F5/F12/Ctrl browser shortcuts - no longer blocked in HTML
- [x] FireflyChase snitch trail - DtScale accumulator, buffer 10
- [x] TargetPractice timeout - wall-clock is correct
- [x] Tetris NextCell - isprop guard for GraphicsPlaceholder
- [x] Checkcode - zero warnings across all 19 source files
- [x] Snake food spawn - moved spawnFood after body update so newHead is included in occupied cell check (MATLAB + HTML)
- [x] Ball reflection contact - all ball games (Pong, Breakout, FlickIt, Juggler) now use parametric contact point for wall and paddle collisions. Force-record captures exact reflection position into trail buffer (MATLAB + HTML)
- [x] Breakout extra ball paddle pass-through - extra balls used post-move position check only, missing the paddle at high speed. Now uses swept parametric detection matching main ball (MATLAB + HTML)
- [x] Asteroids bullet-rock sweep - swept collision segment used unscaled velocity instead of DtScale-scaled step, causing misses on small asteroids at non-60fps (MATLAB + HTML)

### Documentation & Packaging
- [x] DEVELOPER.md - comprehensive architecture, per-game technical notes, all systems documented
- [x] README - per-game descriptions with GIFs, technical highlights, distribution section
- [x] Icon redesign (neon "A" with polybuffer rhombus), preview/splash generation (800x600, 4:3, 300 DPI)
- [x] Packaging - exe + installer with custom branding (icon, splash, logo), web runtime download
- [x] Toolbox - .mltbx with web/ folder included

**Note - wall-clock tic/toc (cosmetic, intentionally real-time):**
Combo decay (FlickIt, FireflyChase, Pong), lives/wave flash animations (Asteroids, Breakout, SpaceInvaders, OrbitalDefense, ShieldGuardian, RailShooter), power-up expiry (Breakout, SpaceInvaders), flick lock cooldown (Juggler), wave advancement timer (ShieldGuardian), difficulty ramp (FireflyChase).
