# Arcade — Developer Details

Internal documentation for the game architecture, performance patterns, and development conventions.

---

## Architecture

```
ArcadeGameLauncher
    ├── State machine:  menu → countdown → active → paused → results → menu
    ├── Timer:          fixedSpacing 0.02s (50 Hz target)
    ├── Mouse tracking: WindowButtonMotionFcn → [x, y] each frame
    ├── HUD:            score (roll-up), combo (fade), status text
    └── Key handling:   KeyPressFcn → state-dependent dispatch
        │
    GameMenu (scrollable neon pill menu)
        │
    GameBase (abstract base class)
        │
    +games/ (43 game classes + 3 utility classes)
        │
    ScoreManager (persistent .mat file)
```

Every game is a `GameBase` subclass. Games implement 4 methods:

| Method | Called | Purpose |
|--------|--------|---------|
| `onInit(ax, displayRange, caps)` | Once | Create graphics, initialize state |
| `onUpdate(pos)` | Every frame | Physics + rendering. `pos = [x, y]` |
| `onCleanup()` | Once | Delete all graphics |
| `onKeyPress(key)` | On keypress | Game-specific keys. Return `true` if handled |

Games are input-agnostic. They receive `[x, y]` and draw on the axes they're given. They never call `drawnow`.

---

## Graphics Pool Pattern

All games use **pre-allocated graphics pools**. Every `line`, `scatter`, `patch`, and `text` object is created once in `onInit` and recycled during gameplay via `Visible` toggling and property updates. No graphics objects are created or deleted inside `onUpdate`.

### Why

MATLAB graphics object creation involves handle registration, renderer sync, and memory allocation — each costing 0.2–1ms. At 50 FPS with multiple objects per frame, those hitches are visible. Property updates on existing handles (`h.XData = newX`) cost under 0.01ms.

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
| Catching | 4 fireflies (dot + aura + trail + trailGlow each) |
| Snake | 60 body segments + 2 food handles |
| FlappyBird | 10 pipe pairs |

### Other conventions

- **Constant arrays** (`linspace(0, 2*pi, 24)` for circles) computed once in `onInit`, stored as properties
- **Expensive queries** (`getpixelposition`, `get(0, "ScreenPixelsPerInch")`) cached at init time
- **HUD dirty flags** — `.String` and `.Color` only set when the displayed value changes

---

## Adding a New Game

1. Create `+games/MyGame.m` extending `GameBase`
2. Set the `Name` constant property
3. Pre-allocate all graphics in `onInit` (see pool pattern above)
4. Tag all graphics with `"GT_mygame"` for orphan cleanup
5. Register in `ArcadeGameLauncher.buildRegistry()`
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
