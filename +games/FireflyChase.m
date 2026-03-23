classdef FireflyChase < engine.GameBase
    %FireflyChase  Catch color-coded fireflies on closed orbits.
    %   5 tiers from cyan to gold, each faster than the last. Gold snitch
    %   evades the cursor. Combo decays after 2 seconds of inactivity.

    properties (Constant)
        Name = "Firefly Chase"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Firefly management
        BaseSpeed       (1,1) double = 2.1875   % base speed (idx/frame), tiers multiply 1x-3.2x
        ActiveFF                                 % active firefly struct array
        SpawnCooldown   (1,1) double = 0         % frames until next spawn
        CatchRadiusBonus (1,1) double = 0        % extra catch radius for mouse input

        % Display scale factor (1.0 at ~180px GestureTrainer height)
        Sc              (1,1) double = 1

        % Timing
        CatchStartTic   uint64                   % tic for difficulty ramp
        LastCatchTic     uint64                   % tic of last catch (combo decay)

        % Combo text fade
        ComboFadeTic     uint64                   % tic when combo fade-out started (empty = not fading)
        ComboFadeColor   (1,3) double = [0.2, 1, 0.4]
        ComboShowTic     uint64                   % tic when combo text was last shown

        % Stats
        FirefliesCaught  (1,1) double = 0
        FirefliesMissed  (1,1) double = 0
    end

    % =================================================================
    % FIREFLY GRAPHICS POOL (4 slots — max 3 on screen + 1 spare)
    % =================================================================
    properties (Access = private)
        FFPoolDotH      cell               % {1x4} scatter handles (core dot)
        FFPoolAuraH     cell               % {1x4} scatter handles (aura glow)
        FFPoolTrailH    cell               % {1x4} line handles (solid trail)
        FFPoolTrailGlowH cell              % {1x4} line handles (glow trail)
        FFPoolActive    (1,4) logical = false  % true = slot in use
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ComboTextH                               % text — combo multiplier display
    end

    % =================================================================
    % COLOR CONSTANTS (not in GameBase)
    % =================================================================
    properties (Constant, Access = private)
        ColorPurple     (1,3) double = [0.7, 0.3, 1]
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create initial state and spawn first firefly.
            obj.Ax = ax;
            obj.DisplayRange = displayRange;
            obj.Score = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;
            obj.ShowHostCombo = false;

            areaW = diff(displayRange.X);
            areaH = diff(displayRange.Y);
            obj.Sc = min(areaW, areaH) / 180;

            obj.ActiveFF = [];
            obj.SpawnCooldown = 96;
            obj.CatchStartTic = tic;
            obj.LastCatchTic = tic;
            obj.ComboFadeTic = [];
            obj.ComboShowTic = [];
            obj.ComboTextH = [];
            obj.FirefliesCaught = 0;
            obj.FirefliesMissed = 0;

            % Combo text (pre-allocated, hidden until needed)
            obj.ComboTextH = text(ax, 0, 0, "", ...
                "Color", obj.ColorGold * 0.8, "FontSize", 7 * obj.FontScale, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "top", "Visible", "off", "Tag", "GT_fireflies");

            % Pre-allocate firefly graphics pool (4 slots, all hidden)
            nPool = 4;
            obj.FFPoolDotH = cell(1, nPool);
            obj.FFPoolAuraH = cell(1, nPool);
            obj.FFPoolTrailH = cell(1, nPool);
            obj.FFPoolTrailGlowH = cell(1, nPool);
            obj.FFPoolActive = false(1, nPool);
            for k = 1:nPool
                obj.FFPoolAuraH{k} = scatter(ax, NaN, NaN, 1, ...
                    "MarkerFaceColor", [1 1 1], "MarkerFaceAlpha", 0.35, ...
                    "MarkerEdgeColor", "none", "Visible", "off", "Tag", "GT_fireflies");
                obj.FFPoolTrailGlowH{k} = line(ax, NaN, NaN, ...
                    "Color", [1 1 1 0.2], "LineWidth", 0.54 * obj.FontScale, ...
                    "Visible", "off", "Tag", "GT_fireflies");
                obj.FFPoolTrailH{k} = line(ax, NaN, NaN, ...
                    "Color", [1 1 1 0.4], "LineWidth", 1.1 * obj.FontScale, ...
                    "Visible", "off", "Tag", "GT_fireflies");
                obj.FFPoolDotH{k} = scatter(ax, NaN, NaN, 1, ...
                    "MarkerFaceColor", [1 1 1], "MarkerFaceAlpha", 1, ...
                    "MarkerEdgeColor", "none", "Visible", "off", "Tag", "GT_fireflies");
            end

            % Mouse input needs larger catch radius — finger tracking has
            % a natural ~30px "fat finger" zone from scatter marker + wobble
            obj.CatchRadiusBonus = 0;

            % Spawn first firefly
            obj.spawnFirefly();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame: advance fireflies, check catches, manage spawns.

            ds = obj.DtScale;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % Advance and check each firefly (reverse for safe deletion)
            for i = numel(obj.ActiveFF):-1:1
                ff = obj.ActiveFF(i);
                ff.phase = ff.phase + 0.0625 * ds;

                if ff.isSnitch
                    % Golden snitch: Lissajous base trajectory + evasion
                    ff.theta = ff.theta + ff.speed * 0.00167 * ds;

                    cx = (dx(1) + dx(2)) / 2;
                    cy = (dy(1) + dy(2)) / 2;
                    ampX = (dx(2) - dx(1)) * 0.4;
                    ampY = (dy(2) - dy(1)) * 0.4;
                    baseX = cx + ampX * sin(ff.theta * ff.freqX + ff.phaseX);
                    baseY = cy + ampY * sin(ff.theta * ff.freqY + ff.phaseY);

                    % Evasion offset — push away from finger
                    evadeX = 0;
                    evadeY = 0;
                    if ~any(isnan(pos))
                        snitchX = baseX + ff.evadeX;
                        snitchY = baseY + ff.evadeY;
                        ddx = snitchX - pos(1);
                        ddy = snitchY - pos(2);
                        dFinger = hypot(ddx, ddy);
                        evadeR = round(100 * obj.Sc);
                        if dFinger < evadeR && dFinger > 0.1
                            push = ((evadeR - dFinger) / evadeR)^2 * 8 * obj.Sc;
                            evadeX = ddx / dFinger * push;
                            evadeY = ddy / dFinger * push;
                        end
                    end
                    ff.evadeX = ff.evadeX * 0.9664 ^ ds + evadeX;
                    ff.evadeY = ff.evadeY * 0.9664 ^ ds + evadeY;

                    ff.posX = baseX + ff.evadeX;
                    ff.posY = baseY + ff.evadeY;

                    % Clamp to bounds
                    pad = 5;
                    ff.posX = max(dx(1) + pad, min(dx(2) - pad, ff.posX));
                    ff.posY = max(dy(1) + pad, min(dy(2) - pad, ff.posY));
                    ffPos = [ff.posX, ff.posY];

                    % Update trail history (circular buffer)
                    ff.trailIdx = ff.trailIdx + 1;
                    bi = mod(ff.trailIdx - 1, ff.trailLen) + 1;
                    ff.trailBufX(bi) = ff.posX;
                    ff.trailBufY(bi) = ff.posY;
                    nFilled = min(ff.trailIdx, ff.trailLen);
                    indices = mod((bi - nFilled):(bi - 1), ff.trailLen) + 1;
                    tx = ff.trailBufX(indices);
                    ty = ff.trailBufY(indices);
                else
                    % Path-based firefly
                    ff.idx = ff.idx + ff.speed * ds;

                    % Reached end of path — loop or reverse
                    if ff.idx >= numel(ff.pathX)
                        obj.onMiss(i);
                        continue
                    end

                    pidx = max(1, round(ff.idx));
                    ffPos = [ff.pathX(pidx), ff.pathY(pidx)];

                    % Comet tail from path history (scales with speed)
                    % Subsample to max ~40 points for rendering performance
                    trailSpan = round(45 * ff.speed / obj.BaseSpeed);
                    if pidx > trailSpan
                        tStart = pidx - trailSpan;
                        step = max(1, floor(trailSpan / 40));
                        idx = tStart:step:pidx;
                        if idx(end) ~= pidx; idx(end+1) = pidx; end
                        tx = ff.pathX(idx);
                        ty = ff.pathY(idx);
                    else
                        % Near start of path — append carry-over from previous loop
                        txFull = [ff.trailCarryX, ff.pathX(1:pidx)];
                        tyFull = [ff.trailCarryY, ff.pathY(1:pidx)];
                        if numel(txFull) > trailSpan
                            txFull = txFull(end - trailSpan + 1:end);
                            tyFull = tyFull(end - trailSpan + 1:end);
                        end
                        step = max(1, floor(numel(txFull) / 40));
                        idx = 1:step:numel(txFull);
                        if idx(end) ~= numel(txFull); idx(end+1) = numel(txFull); end
                        tx = txFull(idx);
                        ty = tyFull(idx);
                    end
                end

                % Check catch (mouse gets bonus radius for precision parity)
                if ~any(isnan(pos))
                    dist = norm(pos - ffPos);
                    if dist <= ff.radius + obj.CatchRadiusBonus
                        obj.onCatch(i, ffPos);
                        continue
                    end
                end

                % Update graphics via pool handles
                si = ff.poolIdx;
                set(obj.FFPoolDotH{si}, "XData", ffPos(1), "YData", ffPos(2));
                set(obj.FFPoolAuraH{si}, "XData", ffPos(1), "YData", ffPos(2));
                set(obj.FFPoolTrailH{si}, "XData", tx, "YData", ty);
                set(obj.FFPoolTrailGlowH{si}, "XData", tx, "YData", ty);

                obj.ActiveFF(i) = ff;
            end

            % Combo decay — fade out over 2 seconds, then reset
            if obj.Combo > 0 && ~isempty(obj.LastCatchTic)
                comboAge = toc(obj.LastCatchTic);
                if comboAge > 2
                    obj.resetCombo();
                    % Start shared fade-out
                    if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                        obj.ComboFadeTic = tic;
                        obj.ComboFadeColor = obj.ColorGreen * 0.9;
                    end
                elseif comboAge > 0.5 && ~isempty(obj.ComboTextH) ...
                        && isvalid(obj.ComboTextH)
                    % Pre-reset fade: 0.5s -> 2s window
                    fade = 1 - (comboAge - 0.5) / 1.5;
                    obj.ComboTextH.Color = [obj.ColorGreen * 0.9, max(fade, 0)];
                end
            end

            % Spawn on cooldown, max 3 on screen
            obj.SpawnCooldown = obj.SpawnCooldown - ds;
            if obj.SpawnCooldown <= 0 && numel(obj.ActiveFF) < 3
                obj.spawnFirefly();
                elapsed = toc(obj.CatchStartTic);
                obj.SpawnCooldown = max(19, round(72 - elapsed * 0.3));
            end

            % Animate combo text fade
            obj.updateComboFade();

        end

        function onCleanup(obj)
            %onCleanup  Delete all firefly pool and combo graphics.

            % Delete firefly pool handles
            pools = {obj.FFPoolDotH, obj.FFPoolAuraH, obj.FFPoolTrailH, obj.FFPoolTrailGlowH};
            for p = 1:numel(pools)
                pool = pools{p};
                for k = 1:numel(pool)
                    if ~isempty(pool{k}) && isvalid(pool{k})
                        delete(pool{k});
                    end
                end
            end
            obj.FFPoolDotH = {};
            obj.FFPoolAuraH = {};
            obj.FFPoolTrailH = {};
            obj.FFPoolTrailGlowH = {};
            obj.FFPoolActive = false(1, 4);
            obj.ActiveFF = [];

            % Delete combo text
            if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                delete(obj.ComboTextH);
            end
            obj.ComboTextH = [];

            % Orphan guard
            engine.GameBase.deleteTaggedGraphics(obj.Ax, "^GT_fireflies");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for fireflies.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return catching-specific results.
            r.Title = "FIREFLY CHASE";
            r.Lines = {
                sprintf("Caught: %d", obj.FirefliesCaught)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function spawnFirefly(obj)
            %spawnFirefly  Activate a pool slot for a new firefly on a random path.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            % Find idle pool slot
            slot = find(~obj.FFPoolActive, 1);
            if isempty(slot); return; end

            % Tier selection (weighted random — 5 tiers, rarer = more points)
            bs = obj.BaseSpeed;
            sc = obj.Sc;
            tierRoll = rand;
            if tierRoll < 0.35
                % Cyan — common, large, slow (35%)
                clr = obj.ColorCyan;
                pts = 100; radius = round(14 * sc); spd = bs * 1.5;
            elseif tierRoll < 0.65
                % Green — common (30%)
                clr = obj.ColorGreen;
                pts = 200; radius = round(13 * sc); spd = bs * 2.7;
            elseif tierRoll < 0.85
                % Magenta — medium (20%)
                clr = obj.ColorMagenta;
                pts = 300; radius = round(12 * sc); spd = bs * 3.75;
            elseif tierRoll < 0.95
                % Purple — uncommon (10%)
                clr = obj.ColorPurple;
                pts = 400; radius = round(11 * sc); spd = bs * 4.8;
            else
                % Gold — legendary, small and fast (5%)
                clr = obj.ColorGold;
                pts = 500; radius = round(10 * sc); spd = bs * 3;
            end

            isGold = (tierRoll >= 0.95);
            ff.speed = spd;
            ff.radius = radius;
            ff.color = clr;
            ff.points = pts;
            ff.phase = rand * 2 * pi;
            ff.isSnitch = isGold;
            ff.poolIdx = slot;

            drx = obj.DisplayRange.X;
            dry = obj.DisplayRange.Y;

            if isGold
                % Golden snitch: free-roaming Lissajous, no path
                ff.pathX = []; ff.pathY = [];
                ff.idx = 0;
                ff.theta = rand * 2 * pi;
                freqPairs = [3, 2; 5, 4; 3, 4; 5, 2; 7, 4; 5, 6];
                pick = freqPairs(randi(size(freqPairs, 1)), :);
                ff.freqX = pick(1);
                ff.freqY = pick(2);
                ff.phaseX = rand * 2 * pi;
                ff.phaseY = rand * 2 * pi;
                ff.evadeX = 0; ff.evadeY = 0;
                cx = (drx(1) + drx(2)) / 2;
                cy = (dry(1) + dry(2)) / 2;
                ampX = (drx(2) - drx(1)) * 0.4;
                ampY = (dry(2) - dry(1)) * 0.4;
                ff.posX = cx + ampX * sin(ff.theta * ff.freqX + ff.phaseX);
                ff.posY = cy + ampY * sin(ff.theta * ff.freqY + ff.phaseY);
                ff.trailLen = 12;
                ff.trailBufX = NaN(1, 12);
                ff.trailBufY = NaN(1, 12);
                ff.trailIdx = 0;
                ff.trailCarryX = []; ff.trailCarryY = [];
                startX = ff.posX; startY = ff.posY;
            else
                % Path-based firefly — closed orbits only (loop, figure8)
                corridorW = round(10 * obj.Sc);
                for attempt = 1:50 
                    p = games.FireflyChase.generatePath(3, drx, dry, corridorW, true);
                    if ismember(p.Type, ["loop", "figure8"])
                        break
                    end
                end
                ff.pathX = p.X;
                ff.pathY = p.Y;
                ff.idx = 1;
                ff.posX = 0; ff.posY = 0;
                ff.theta = 0;
                ff.freqX = 0; ff.freqY = 0;
                ff.phaseX = 0; ff.phaseY = 0;
                ff.evadeX = 0; ff.evadeY = 0;
                ff.trailLen = 0;
                ff.trailBufX = []; ff.trailBufY = [];
                ff.trailIdx = 0;
                ff.trailCarryX = []; ff.trailCarryY = [];
                startX = p.X(1); startY = p.Y(1);
            end

            % SizeData is in screen points² — use unscaled base sizes
            % so markers look the same physical size at any display scale.
            % Collision uses data-space radius (scaled); visuals use fixed pts.
            baseRadius = radius / max(obj.Sc, 0.5);  % unscale back to ~10-14
            dotSize = baseRadius;
            auraSize = baseRadius * 3.5;

            % Activate pool slot — update properties, make visible
            hDot = obj.FFPoolDotH{slot};
            hAura = obj.FFPoolAuraH{slot};
            hTrail = obj.FFPoolTrailH{slot};
            hTrailGlow = obj.FFPoolTrailGlowH{slot};

            ffps = obj.FontScale;
            set(hAura, "XData", startX, "YData", startY, ...
                "SizeData", (auraSize * ffps)^2, "MarkerFaceColor", clr, "Visible", "on");
            set(hTrailGlow, "XData", NaN, "YData", NaN, ...
                "Color", [clr, 0.2], "LineWidth", dotSize * 0.8 * ffps, "Visible", "on");
            set(hTrail, "XData", NaN, "YData", NaN, ...
                "Color", [clr, 0.4], "Visible", "on");
            set(hDot, "XData", startX, "YData", startY, ...
                "SizeData", (dotSize * ffps)^2, "MarkerFaceColor", clr, "Visible", "on");

            obj.FFPoolActive(slot) = true;

            if isempty(obj.ActiveFF)
                obj.ActiveFF = ff;
            else
                obj.ActiveFF(end + 1) = ff;
            end
        end

        function onCatch(obj, idx, hitPos)
            %onCatch  Score a caught firefly with burst effect.
            ff = obj.ActiveFF(idx);

            obj.incrementCombo();
            obj.LastCatchTic = tic;
            comboMult = obj.Combo * 0.1;
            totalPoints = round(ff.points * comboMult);
            obj.addScore(totalPoints);
            obj.FirefliesCaught = obj.FirefliesCaught + 1;

            obj.spawnHitEffect(hitPos, ff.color, totalPoints, ff.radius);
            obj.showComboText(hitPos + [0, 12]);

            % Return pool slot — hide graphics
            si = ff.poolIdx;
            obj.FFPoolDotH{si}.Visible = "off";
            obj.FFPoolAuraH{si}.Visible = "off";
            obj.FFPoolTrailH{si}.Visible = "off";
            obj.FFPoolTrailGlowH{si}.Visible = "off";
            obj.FFPoolActive(si) = false;
            obj.ActiveFF(idx) = [];

            % Immediately spawn a replacement (respecting max)
            if numel(obj.ActiveFF) < 3
                obj.spawnFirefly();
            end
        end

        function onMiss(obj, idx)
            %onMiss  Firefly reached end of path — loop or reverse.
            ff = obj.ActiveFF(idx);

            % Save trail carry-over (last trailSpan points from current path end)
            trailSpan = round(45 * ff.speed / obj.BaseSpeed);
            nPath = numel(ff.pathX);
            cStart = max(1, nPath - trailSpan);
            ff.trailCarryX = ff.pathX(cStart:nPath);
            ff.trailCarryY = ff.pathY(cStart:nPath);

            gapDist = hypot(ff.pathX(end) - ff.pathX(1), ...
                            ff.pathY(end) - ff.pathY(1));
            if gapDist < 5
                ff.idx = 1;
            else
                ff.pathX = fliplr(ff.pathX);
                ff.pathY = fliplr(ff.pathY);
                ff.idx = 1;
            end
            obj.ActiveFF(idx) = ff;
        end

        function showComboText(obj, hitPos)
            %showComboText  Show combo text briefly at hit location.
            if obj.Combo >= 2
                % Cancel any active fade
                obj.ComboFadeTic = [];
                if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH); return; end
                obj.ComboTextH.String = sprintf("%dx Combo", obj.Combo);
                obj.ComboTextH.Color = obj.ColorGreen * 0.9;
                if ~any(isnan(hitPos))
                    obj.ComboTextH.Position = [hitPos(1), hitPos(2) + 12, 0];
                end
                obj.ComboTextH.Visible = "on";
                obj.ComboShowTic = tic;
            else
                % Start fade-out instead of immediate delete
                if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                    obj.ComboFadeTic = tic;
                    obj.ComboFadeColor = obj.ColorGreen * 0.9;
                end
            end
        end

        function updateComboFade(obj)
            %updateComboFade  Animate combo text fade-out, delete when done.
            if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH)
                obj.ComboFadeTic = [];
                obj.ComboShowTic = [];
                return;
            end

            % Auto-trigger fade after 1s display
            if ~isempty(obj.ComboShowTic) && isempty(obj.ComboFadeTic)
                if toc(obj.ComboShowTic) >= 1.0
                    obj.ComboFadeTic = tic;
                    obj.ComboFadeColor = obj.ColorGreen * 0.9;
                    obj.ComboShowTic = [];
                end
            end

            % Animate fade-out
            if isempty(obj.ComboFadeTic); return; end
            elapsed = toc(obj.ComboFadeTic);
            fadeDur = 0.6;
            if elapsed >= fadeDur
                obj.ComboTextH.Visible = "off";
                obj.ComboFadeTic = [];
            else
                fadeAlpha = max(0, 1 - elapsed / fadeDur);
                obj.ComboTextH.Color = [obj.ComboFadeColor, fadeAlpha];
            end
        end
    end

    % =================================================================
    % STATIC UTILITIES — path generation (from GestureTrainer)
    % =================================================================
    methods (Static, Access = private)

        function pathStruct = generatePath(tier, displayRangeX, displayRangeY, corridorWidth, applyRotation)
            %generatePath  Generate smooth closed-orbit paths for fireflies.
            %   pathStruct = generatePath(tier, rangeX, rangeY, cw, applyRotation)

            if nargin < 5; applyRotation = true; end
            if nargin < 4; corridorWidth = 20; end

            localSc = min(diff(displayRangeX), diff(displayRangeY)) / 180;
            margin = round(25 * localSc);
            xMin = displayRangeX(1) + margin;
            xMax = displayRangeX(2) - margin;
            yMin = displayRangeY(1) + margin;
            yMax = displayRangeY(2) - margin;

            xSpan = max(20, xMax - xMin);
            ySpan = max(20, yMax - yMin);
            cx = (xMin + xMax) / 2;
            cy = (yMin + yMax) / 2;
            spanVal = min(xSpan, ySpan);

            % Path types by tier
            switch tier
                case 1;  types = ["curve", "sCurve"];
                case 2;  types = ["wave", "oscillate", "arc"];
                case 3;  types = ["loop", "figure8", "spiral"];
                otherwise; types = "longSpiral";
            end
            pathType = types(randi(numel(types)));

            switch pathType
                case "curve"
                    p0 = [xMin + rand * xSpan * 0.1, cy + (rand - 0.5) * ySpan * 0.5];
                    p3 = [xMax - rand * xSpan * 0.1, cy + (rand - 0.5) * ySpan * 0.5];
                    c1 = [cx - xSpan * 0.1 + (rand - 0.5) * xSpan * 0.2, ...
                          cy + (rand - 0.5) * ySpan * 0.7];
                    c2 = [cx + xSpan * 0.1 + (rand - 0.5) * xSpan * 0.2, ...
                          cy + (rand - 0.5) * ySpan * 0.7];
                    t = linspace(0, 1, 400)';
                    rawX = (1-t).^3*p0(1) + 3*(1-t).^2.*t*c1(1) + 3*(1-t).*t.^2*c2(1) + t.^3*p3(1);
                    rawY = (1-t).^3*p0(2) + 3*(1-t).^2.*t*c1(2) + 3*(1-t).*t.^2*c2(2) + t.^3*p3(2);
                    rawX = rawX'; rawY = rawY';

                case "sCurve"
                    t = linspace(0, 1, 400);
                    rawY = yMin + t * ySpan;
                    rawX = cx - sin(t * 2 * pi) * xSpan * 0.38;

                case "wave"
                    t = linspace(0, 1, 500);
                    rawX = xMin + t * xSpan;
                    rawY = cy + sin(t * 2 * pi * 1.5) * ySpan * 0.35;

                case "oscillate"
                    t = linspace(0, 1, 600);
                    rawX = xMin + t * xSpan;
                    rawY = cy + sin(t * 2 * pi * 2) * ySpan * 0.35;

                case "arc"
                    arcAngle = pi * (0.6 + rand * 0.5);
                    startAngle = rand * 2 * pi;
                    theta = linspace(startAngle, startAngle + arcAngle, 400);
                    r = spanVal * 0.42;
                    rawX = cx + r * cos(theta);
                    rawY = cy + r * sin(theta);

                case "loop"
                    theta = linspace(0, 2*pi, 500);
                    rx = xSpan * 0.40;
                    ry = ySpan * 0.40;
                    rawX = cx + rx * cos(theta);
                    rawY = cy + ry * sin(theta);

                case "figure8"
                    theta = linspace(0, 2*pi, 600);
                    rx = xSpan * 0.38;
                    ry = ySpan * 0.38;
                    rawX = cx + rx * sin(theta);
                    rawY = cy + ry * sin(2 * theta);

                case "spiral"
                    maxR = spanVal * 0.47;
                    minR = corridorWidth * 0.5;
                    minSpacing = corridorWidth * 1.3;
                    maxSafeTurns = max(1, maxR / minSpacing);
                    nTurns = min(1.5 + rand * 0.5, maxSafeTurns);
                    theta = linspace(0, 2 * pi * nTurns, 600);
                    r = minR + (maxR - minR) * theta / max(theta);
                    rawX = cx + r .* cos(theta);
                    rawY = cy + r .* sin(theta);

                case "longSpiral"
                    maxR = spanVal * 0.48;
                    minR = corridorWidth * 0.5;
                    minSpacing = corridorWidth * 1.3;
                    maxSafeTurns = max(1.5, maxR / minSpacing);
                    nTurns = min(2 + rand * 0.5, maxSafeTurns);
                    theta = linspace(0, 2 * pi * nTurns, 700);
                    r = minR + (maxR - minR) * theta / max(theta);
                    rawX = cx + r .* cos(theta);
                    rawY = cy + r .* sin(theta);

                otherwise
                    t = linspace(0, 1, 300);
                    rawX = xMin + t * xSpan;
                    rawY = cy + sin(t * pi) * ySpan * 0.35;
            end

            rawX = rawX(:)';
            rawY = rawY(:)';

            % Random rotation around centroid
            rotAngle = 0;
            if applyRotation
                rotAngle = rand * 2 * pi;
            end
            if rotAngle ~= 0
                centX = mean(rawX);
                centY = mean(rawY);
                ddx = rawX - centX;
                ddy = rawY - centY;
                cosA = cos(rotAngle);
                sinA = sin(rotAngle);
                rawX = centX + ddx * cosA - ddy * sinA;
                rawY = centY + ddx * sinA + ddy * cosA;
            end

            % 50% chance to reverse direction
            if rand > 0.5
                rawX = fliplr(rawX);
                rawY = fliplr(rawY);
            end

            % Scale to fit within display bounds
            pad = 5;
            xLo = displayRangeX(1) + pad;
            xHi = displayRangeX(2) - pad;
            yLo = displayRangeY(1) + pad;
            yHi = displayRangeY(2) - pad;
            centX = mean(rawX);
            centY = mean(rawY);
            extR = max(rawX) - centX;
            extL = centX - min(rawX);
            extD = max(rawY) - centY;
            extU = centY - min(rawY);
            scales = ones(1, 4);
            if extR > 0; scales(1) = (xHi - centX) / extR; end
            if extL > 0; scales(2) = (centX - xLo) / extL; end
            if extD > 0; scales(3) = (yHi - centY) / extD; end
            if extU > 0; scales(4) = (centY - yLo) / extU; end
            scaleFactor = min(scales);
            if scaleFactor < 1
                rawX = centX + (rawX - centX) * scaleFactor;
                rawY = centY + (rawY - centY) * scaleFactor;
            end
            rawX = max(xLo, min(xHi, rawX));
            rawY = max(yLo, min(yHi, rawY));

            % Random translation
            if applyRotation
                maxShiftR = xHi - max(rawX);
                maxShiftL = xLo - min(rawX);
                maxShiftD = yHi - max(rawY);
                maxShiftU = yLo - min(rawY);
                offX = maxShiftL + rand * (maxShiftR - maxShiftL);
                offY = maxShiftU + rand * (maxShiftD - maxShiftU);
                rawX = rawX + offX;
                rawY = rawY + offY;
            end

            % Resample to uniform ~1px spacing
            [X, Y, cumDist] = games.FireflyChase.resampleUniform(rawX, rawY);

            pathStruct.X = X;
            pathStruct.Y = Y;
            pathStruct.CumDist = cumDist;
            pathStruct.TotalLen = cumDist(end);
            pathStruct.Type = pathType;
            pathStruct.Difficulty = tier;
        end

        function [X, Y, cumDist] = resampleUniform(x, y)
            %resampleUniform  Resample a path to approximately 1px point spacing.

            segLen = hypot(diff(x), diff(y));
            cumLen = [0, cumsum(segLen)];
            totalLen = cumLen(end);

            if totalLen < 2
                X = x;
                Y = y;
                cumDist = cumLen;
                return
            end

            nPts = max(3, round(totalLen));
            cumDist = linspace(0, totalLen, nPts);
            X = interp1(cumLen, x, cumDist, "pchip");
            Y = interp1(cumLen, y, cumDist, "pchip");
        end
    end
end
