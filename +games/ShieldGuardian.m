classdef ShieldGuardian < GameBase
    %ShieldGuardian  Defend a core orb by rotating a shield arc to deflect projectiles.
    %   Shield arc faces the finger direction. Projectiles spawn from edges
    %   and target the core. Deflected projectiles can chain-destroy others.
    %   Wave-based progression with increasing speed and spawn rate.
    %
    %   Standalone: games.ShieldGuardian().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Shield Guardian"
    end

    % =================================================================
    % COLOR CONSTANTS (not in GameBase)
    % =================================================================
    properties (Constant, Access = private)
        ColorOrange     (1,3) double = [1, 0.6, 0.15]
    end

    % =================================================================
    % PROJECTILE POOL (20 slots)
    % =================================================================
    properties (Access = private)
        ProjPoolScatter             % cell array of 20 scatter handles (core)
        ProjPoolGlow                % cell array of 20 scatter handles (glow)
        ProjX               (1,20) double = zeros(1, 20)
        ProjY               (1,20) double = zeros(1, 20)
        ProjVx              (1,20) double = zeros(1, 20)
        ProjVy              (1,20) double = zeros(1, 20)
        ProjType            (1,20) string = repmat("", 1, 20)
        ProjSpeed           (1,20) double = zeros(1, 20)
        ProjRadius          (1,20) double = zeros(1, 20)
        ProjColor           (20,3) double = zeros(20, 3)
        ProjActive          (1,20) logical = false(1, 20)
        ProjPrevX           (1,20) double = zeros(1, 20)
        ProjPrevY           (1,20) double = zeros(1, 20)
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        CorePos         (1,2) double = [NaN, NaN]
        CoreRadius      (1,1) double = 6         % data-unit radius of core orb
        HitboxRadius    (1,1) double = 5         % data-unit radius of hitbox disc
        ShieldRadius    (1,1) double = 8         % data-unit radius of shield arc
        Lives           (1,1) double = 3
        MaxLives        (1,1) double = 3
        ShieldAngle     (1,1) double = 0        % shield center angle (radians)
        ShieldArc       (1,1) double = pi        % shield width (radians)
        Wave            (1,1) double = 1
        SpawnTimer      (1,1) double = 0
        GameOver        (1,1) logical = false
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        CorePatchH                      % scatter -- core orb
        HitboxCircleH                   % scatter -- hitbox radius disc
        ShieldLineH                     % line -- shield arc solid
        ShieldGlowH                     % line -- shield arc glow
        LivesTextH                      % text -- lives flash display
        LivesFlashTic   = []            % tic for lives flash animation
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create shield guardian graphics and initialize state.
            arguments
                obj
                ax
                displayRange struct
                ~
            end
            obj.Ax = ax;
            obj.DisplayRange = displayRange;
            obj.Score = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;
            obj.GameOver = false;

            dx = displayRange.X;
            dy = displayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);
            minDim = min(areaW, areaH);

            obj.CorePos = [mean(dx), mean(dy)];
            obj.Lives = 3;
            obj.MaxLives = 3;
            obj.ShieldAngle = 0;
            obj.ShieldArc = pi;
            obj.Wave = 1;
            obj.SpawnTimer = 0;
            obj.LivesFlashTic = [];

            % Reset projectile pool state
            obj.ProjActive(:) = false;
            obj.ProjX(:) = 0;
            obj.ProjY(:) = 0;
            obj.ProjPrevX(:) = 0;
            obj.ProjPrevY(:) = 0;
            obj.ProjVx(:) = 0;
            obj.ProjVy(:) = 0;
            obj.ProjSpeed(:) = 0;
            obj.ProjRadius(:) = 0;
            obj.ProjColor(:) = 0;
            obj.ProjType(:) = "";

            % Data-unit radii (small — ~4% of display for core, ~6% for shield)
            obj.CoreRadius = max(4, minDim * 0.055);
            obj.ShieldRadius = max(7, minDim * 0.08);
            obj.HitboxRadius = obj.ShieldRadius * 0.9;

            % Compute initial SizeData from data-unit radii
            [coreSz, ~] = obj.computeSizeData(ax, displayRange, obj.CoreRadius);
            [hitSz, ~] = obj.computeSizeData(ax, displayRange, obj.HitboxRadius);

            % Hitbox disc (translucent background behind core)
            obj.HitboxCircleH = scatter(ax, obj.CorePos(1), obj.CorePos(2), ...
                hitSz, obj.ColorCyan, "filled", ...
                "MarkerFaceAlpha", 0.6, "Tag", "GT_shieldguardian");

            % Core orb (fully opaque center)
            obj.CorePatchH = scatter(ax, obj.CorePos(1), obj.CorePos(2), ...
                coreSz, obj.ColorCyan, "filled", "MarkerFaceAlpha", 1.0, ...
                "Tag", "GT_shieldguardian");

            % Shield arc
            shieldR = obj.ShieldRadius;
            shieldTheta = linspace(-obj.ShieldArc / 2, obj.ShieldArc / 2, 20);
            sx = obj.CorePos(1) + shieldR * cos(shieldTheta);
            sy = obj.CorePos(2) + shieldR * sin(shieldTheta);

            obj.ShieldGlowH = line(ax, sx, sy, ...
                "Color", [obj.ColorCyan, 0.3], "LineWidth", 6, ...
                "Tag", "GT_shieldguardian");
            obj.ShieldLineH = line(ax, sx, sy, ...
                "Color", obj.ColorCyan, "LineWidth", 2, ...
                "Tag", "GT_shieldguardian");

            % Lives text (centered, hidden, flash on change)
            cx = mean(dx);
            cy = mean(dy);
            obj.LivesTextH = text(ax, cx, cy + diff(dy) * 0.25, "", ...
                "Color", obj.ColorRed, ...
                "FontSize", max(18, round(diff(dy) * 0.1)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_shieldguardian");

            % Pre-allocate projectile pool (20 scatter pairs, all hidden)
            % Use a small placeholder SizeData — updated dynamically each frame
            obj.ProjPoolScatter = cell(1, 20);
            obj.ProjPoolGlow = cell(1, 20);
            placeholderSz = 40;
            for k = 1:20
                obj.ProjPoolGlow{k} = scatter(ax, NaN, NaN, placeholderSz, ...
                    obj.ColorRed, "filled", "MarkerFaceAlpha", 0.12, ...
                    "Visible", "off", "Tag", "GT_shieldguardian");
                obj.ProjPoolScatter{k} = scatter(ax, NaN, NaN, placeholderSz, ...
                    obj.ColorRed, "filled", "MarkerFaceAlpha", 0.8, ...
                    "Visible", "off", "Tag", "GT_shieldguardian");
            end
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame shield guardian logic.
            if obj.GameOver; return; end

            ds = obj.DtScale;

            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            corePos = obj.CorePos;
            shieldR = obj.ShieldRadius;
            hitboxR = obj.HitboxRadius;

            % --- Recompute SizeData from data-unit radii (resize-safe) ---
            pixPos = getpixelposition(ax);
            pxPerData = pixPos(3) / diff(dx);
            dpiVal = get(0, "ScreenPixelsPerInch");
            ptPerPx = 72 / dpiVal;

            % Update core orb and hitbox SizeData
            if ~isempty(obj.CorePatchH) && isvalid(obj.CorePatchH)
                corePts = obj.CoreRadius * pxPerData * ptPerPx;
                obj.CorePatchH.SizeData = corePts^2 * pi;
            end
            if ~isempty(obj.HitboxCircleH) && isvalid(obj.HitboxCircleH)
                hitPts = hitboxR * pxPerData * ptPerPx;
                obj.HitboxCircleH.SizeData = hitPts^2 * pi;
            end

            % --- Update shield angle based on finger position ---
            if ~any(isnan(pos))
                obj.ShieldAngle = atan2( ...
                    pos(2) - corePos(2), pos(1) - corePos(1));
            end

            % --- Update shield graphics ---
            shieldTheta = linspace( ...
                obj.ShieldAngle - obj.ShieldArc / 2, ...
                obj.ShieldAngle + obj.ShieldArc / 2, 20);
            sx = corePos(1) + shieldR * cos(shieldTheta);
            sy = corePos(2) + shieldR * sin(shieldTheta);
            if ~isempty(obj.ShieldLineH) && isvalid(obj.ShieldLineH)
                set(obj.ShieldLineH, "XData", sx, "YData", sy);
            end
            if ~isempty(obj.ShieldGlowH) && isvalid(obj.ShieldGlowH)
                set(obj.ShieldGlowH, "XData", sx, "YData", sy);
            end

            % --- Spawn projectiles ---
            obj.SpawnTimer = obj.SpawnTimer + ds;
            spawnRate = max(19, 72 - obj.Wave * 5);
            if obj.SpawnTimer >= spawnRate
                obj.SpawnTimer = 0;
                obj.spawnProjectile();
            end

            % --- Update projectile SizeData for all active slots ---
            activeIdx = find(obj.ProjActive);
            for ii = 1:numel(activeIdx)
                k = activeIdx(ii);
                rData = obj.ProjRadius(k);
                rPts = rData * pxPerData * ptPerPx;
                coreSz = rPts^2 * pi;
                sH = obj.ProjPoolScatter{k};
                if ~isempty(sH) && isvalid(sH)
                    sH.SizeData = coreSz;
                end
                gH = obj.ProjPoolGlow{k};
                if ~isempty(gH) && isvalid(gH)
                    gH.SizeData = coreSz * 3;
                end
            end

            % --- Move projectiles (iterate active pool slots in reverse) ---
            % Swept collision: check line segment from prev to cur against
            % the shield arc circle, preventing fast projectiles from
            % tunnelling through the shield at high DtScale.
            for ii = numel(activeIdx):-1:1
                k = activeIdx(ii);

                % Save previous position for swept collision
                prevPx = obj.ProjX(k);
                prevPy = obj.ProjY(k);
                obj.ProjPrevX(k) = prevPx;
                obj.ProjPrevY(k) = prevPy;

                % Move
                obj.ProjX(k) = prevPx + obj.ProjVx(k) * ds;
                obj.ProjY(k) = prevPy + obj.ProjVy(k) * ds;
                px = obj.ProjX(k);
                py = obj.ProjY(k);

                % Update scatter positions
                sH = obj.ProjPoolScatter{k};
                gH = obj.ProjPoolGlow{k};
                if ~isempty(sH) && isvalid(sH)
                    sH.XData = px;
                    sH.YData = py;
                end
                if ~isempty(gH) && isvalid(gH)
                    gH.XData = px;
                    gH.YData = py;
                end

                distToCore = sqrt((px - corePos(1))^2 + (py - corePos(2))^2);

                % --- Shield deflection (swept line-segment vs arc) ---
                % Check if the line from prev to current crosses the shield
                % radius circle within the shield angular span.
                deflected = false;
                if obj.ProjType(k) ~= "deflected"
                    % Line segment: P = prev + t*(cur - prev), t in [0,1]
                    % Circle: |P - core|^2 = shieldR^2
                    % Quadratic: a*t^2 + b*t + c = 0
                    segDx = px - prevPx;
                    segDy = py - prevPy;
                    relPx = prevPx - corePos(1);
                    relPy = prevPy - corePos(2);
                    a = segDx^2 + segDy^2;
                    b = 2 * (relPx * segDx + relPy * segDy);
                    c = relPx^2 + relPy^2 - shieldR^2;
                    disc = b^2 - 4 * a * c;
                    if disc >= 0 && a > 1e-12
                        sqrtDisc = sqrt(disc);
                        tVals = [(-b - sqrtDisc) / (2 * a), ...
                                 (-b + sqrtDisc) / (2 * a)];
                        for ti = 1:2
                            tHit = tVals(ti);
                            if tHit >= 0 && tHit <= 1
                                % Intersection point on circle
                                hitX = prevPx + tHit * segDx;
                                hitY = prevPy + tHit * segDy;
                                hitAngle = atan2( ...
                                    hitY - corePos(2), hitX - corePos(1));
                                angleDiff = mod( ...
                                    hitAngle - obj.ShieldAngle + pi, 2*pi) - pi;
                                if abs(angleDiff) < obj.ShieldArc / 2
                                    % Deflect at the hit point
                                    obj.addScore(25);
                                    obj.incrementCombo();
                                    normalVec = [cos(hitAngle), sin(hitAngle)];
                                    vel = [obj.ProjVx(k), obj.ProjVy(k)];
                                    reflected = vel ...
                                        - 2 * dot(vel, normalVec) * normalVec;
                                    obj.ProjVx(k) = reflected(1) * 1.5;
                                    obj.ProjVy(k) = reflected(2) * 1.5;
                                    obj.ProjType(k) = "deflected";
                                    % Place projectile at hit point + small
                                    % outward push to prevent re-triggering
                                    obj.ProjX(k) = hitX + normalVec(1) * 3;
                                    obj.ProjY(k) = hitY + normalVec(2) * 3;
                                    px = obj.ProjX(k);
                                    py = obj.ProjY(k);
                                    if ~isempty(sH) && isvalid(sH)
                                        sH.XData = px;
                                        sH.YData = py;
                                        sH.CData = obj.ColorGreen;
                                    end
                                    if ~isempty(gH) && isvalid(gH)
                                        gH.XData = px;
                                        gH.YData = py;
                                        gH.CData = obj.ColorGreen;
                                    end
                                    obj.spawnBounceEffect( ...
                                        [hitX, hitY], normalVec, 0, 6);
                                    deflected = true;
                                    break;
                                end
                            end
                        end
                    end
                end
                if deflected; continue; end

                % --- Core hit (swept: line segment vs hitbox circle) ---
                if obj.ProjType(k) ~= "deflected"
                    segDx2 = px - prevPx;
                    segDy2 = py - prevPy;
                    relPx2 = prevPx - corePos(1);
                    relPy2 = prevPy - corePos(2);
                    a2 = segDx2^2 + segDy2^2;
                    b2 = 2 * (relPx2 * segDx2 + relPy2 * segDy2);
                    c2 = relPx2^2 + relPy2^2 - hitboxR^2;
                    disc2 = b2^2 - 4 * a2 * c2;
                    coreHit = distToCore < hitboxR;  % fallback: endpoint inside
                    if ~coreHit && disc2 >= 0 && a2 > 1e-12
                        sqrtDisc2 = sqrt(disc2);
                        t1 = (-b2 - sqrtDisc2) / (2 * a2);
                        if t1 >= 0 && t1 <= 1
                            coreHit = true;
                        end
                    end
                    if coreHit
                        obj.Lives = obj.Lives - 1;
                        obj.resetCombo();

                        % Flash lives display
                        if ~isempty(obj.LivesTextH) && isvalid(obj.LivesTextH)
                            obj.LivesTextH.String = sprintf("Lives: %d", ...
                                max(0, obj.Lives));
                            obj.LivesTextH.Color = obj.ColorRed;
                            obj.LivesTextH.Visible = "on";
                            obj.LivesFlashTic = tic;
                        end
                        obj.spawnBounceEffect([px, py], [0, 1], 0, 14);

                        % Deactivate projectile (return to pool)
                        obj.deactivateProjectile(k);

                        if obj.Lives <= 0
                            obj.GameOver = true;
                            obj.IsRunning = false;
                            return;
                        end
                        continue;
                    end
                end

                % --- Off screen ---
                if px < dx(1) - 30 || px > dx(2) + 30 ...
                        || py < dy(1) - 30 || py > dy(2) + 30
                    obj.deactivateProjectile(k);
                    continue;
                end

                % --- Deflected hitting another projectile (chain) ---
                % ProjRadius is in data units — compare directly to distance
                if obj.ProjType(k) == "deflected"
                    activeJ = find(obj.ProjActive);
                    for jj = numel(activeJ):-1:1
                        j = activeJ(jj);
                        if j == k; continue; end
                        if obj.ProjType(j) ~= "deflected" && ...
                                sqrt((px - obj.ProjX(j))^2 + ...
                                     (py - obj.ProjY(j))^2) ...
                                < (obj.ProjRadius(k) + obj.ProjRadius(j))
                            obj.addScore(50);
                            obj.incrementCombo();
                            obj.spawnBounceEffect( ...
                                [obj.ProjX(j), obj.ProjY(j)], [0, -1], 0, 8);
                            obj.deactivateProjectile(j);
                        end
                    end
                end
            end

            % --- Lives flash animation (0.6s hold + 0.4s fade) ---
            if ~isempty(obj.LivesFlashTic) ...
                    && ~isempty(obj.LivesTextH) ...
                    && isgraphics(obj.LivesTextH) && isvalid(obj.LivesTextH)
                el = toc(obj.LivesFlashTic);
                if el < 0.6
                    obj.LivesTextH.Color = obj.ColorRed;
                elseif el < 1.0
                    fadeAlpha = 1 - (el - 0.6) / 0.4;
                    obj.LivesTextH.Color = [obj.ColorRed, max(0, fadeAlpha)];
                else
                    obj.LivesTextH.Visible = "off";
                    obj.LivesFlashTic = [];
                end
            end

            % --- Wave progression (every 30 seconds) ---
            if toc(obj.StartTic) > obj.Wave * 30
                obj.Wave = obj.Wave + 1;
                obj.addScore(200 * obj.Wave);
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all shield guardian graphics.
            handles = {obj.CorePatchH, obj.HitboxCircleH, ...
                obj.ShieldLineH, obj.ShieldGlowH, obj.LivesTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.CorePatchH = [];
            obj.HitboxCircleH = [];
            obj.ShieldLineH = [];
            obj.ShieldGlowH = [];
            obj.LivesTextH = [];
            obj.LivesFlashTic = [];

            % Delete projectile pool handles
            for k = 1:20
                if ~isempty(obj.ProjPoolScatter) && numel(obj.ProjPoolScatter) >= k
                    h = obj.ProjPoolScatter{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
                if ~isempty(obj.ProjPoolGlow) && numel(obj.ProjPoolGlow) >= k
                    h = obj.ProjPoolGlow{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.ProjPoolScatter = {};
            obj.ProjPoolGlow = {};
            obj.ProjActive(:) = false;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_shieldguardian");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for Shield Guardian.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return shield guardian results.
            r.Title = "SHIELD GUARDIAN";
            if obj.Lives <= 0
                statusStr = "GAME OVER";
            else
                statusStr = sprintf("SURVIVED (Lives: %d)", obj.Lives);
            end
            r.Lines = {
                sprintf("Wave: %d  |  %s", obj.Wave, statusStr)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function spawnProjectile(obj)
            %spawnProjectile  Spawn a projectile from a random edge aimed at core.
            %   Activates the first available slot from the pre-allocated pool.
            %   ProjRadius stores data-unit radii; SizeData is recomputed each
            %   frame in onUpdate for resize safety.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            % Find first inactive pool slot
            slot = find(~obj.ProjActive, 1);
            if isempty(slot); return; end  % pool exhausted, skip spawn

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);
            minDim = min(areaW, areaH);

            % Spawn from just beyond visible edge (direction-dependent)
            spawnAngle = rand * 2 * pi;
            halfW = areaW / 2;
            halfH = areaH / 2;
            absCos = max(abs(cos(spawnAngle)), 1e-6);
            absSin = max(abs(sin(spawnAngle)), 1e-6);
            edgeDist = min(halfW / absCos, halfH / absSin);
            spawnR = edgeDist + 10;
            x = obj.CorePos(1) + spawnR * cos(spawnAngle);
            y = obj.CorePos(2) + spawnR * sin(spawnAngle);

            % Aim at core with spread scaled to core size
            toCore = [obj.CorePos(1) - x, obj.CorePos(2) - y];
            toCore = toCore / norm(toCore);
            maxMiss = obj.CoreRadius * 0.6;
            spreadAngle = atan2(maxMiss, spawnR);
            spreadVal = (rand - 0.5) * 2 * spreadAngle;
            ca = cos(spreadVal);
            sa = sin(spreadVal);
            aimed = [toCore(1)*ca - toCore(2)*sa, toCore(1)*sa + toCore(2)*ca];

            baseSpeed = max(0.333, minDim * 0.0083) ...
                * (1 + obj.Wave * 0.1);

            % Random type: fast (red), normal (magenta), heavy (orange)
            % Radii are in data units (~1-2% of display)
            pType = randi(3);
            switch pType
                case 1  % Fast: small, red, 1.5x speed
                    clr = obj.ColorRed;
                    speedMult = 1.5;
                    radiusData = max(0.8, minDim * 0.008);
                case 2  % Normal: medium, magenta, 1x speed
                    clr = obj.ColorMagenta;
                    speedMult = 1.0;
                    radiusData = max(1.2, minDim * 0.012);
                case 3  % Heavy: large, orange, 0.6x speed
                    clr = obj.ColorOrange;
                    speedMult = 0.6;
                    radiusData = max(1.5, minDim * 0.018);
            end

            speedVal = baseSpeed * speedMult;
            vx = aimed(1) * speedVal;
            vy = aimed(2) * speedVal;

            % Compute initial SizeData for immediate display
            [coreSz, ~] = obj.computeSizeData(ax, obj.DisplayRange, radiusData);

            % Populate pool slot
            obj.ProjX(slot) = x;
            obj.ProjY(slot) = y;
            obj.ProjPrevX(slot) = x;
            obj.ProjPrevY(slot) = y;
            obj.ProjVx(slot) = vx;
            obj.ProjVy(slot) = vy;
            obj.ProjType(slot) = "incoming";
            obj.ProjSpeed(slot) = speedVal;
            obj.ProjRadius(slot) = radiusData;
            obj.ProjColor(slot, :) = clr;
            obj.ProjActive(slot) = true;

            % Activate pool scatter handles
            sH = obj.ProjPoolScatter{slot};
            if ~isempty(sH) && isvalid(sH)
                set(sH, "XData", x, "YData", y, "SizeData", coreSz, ...
                    "CData", clr, "Visible", "on");
            end
            gH = obj.ProjPoolGlow{slot};
            if ~isempty(gH) && isvalid(gH)
                set(gH, "XData", x, "YData", y, "SizeData", coreSz * 3, ...
                    "CData", clr, "Visible", "on");
            end
        end

        function deactivateProjectile(obj, slot)
            %deactivateProjectile  Return a pool slot to inactive state.
            obj.ProjActive(slot) = false;
            sH = obj.ProjPoolScatter{slot};
            if ~isempty(sH) && isvalid(sH)
                set(sH, "XData", NaN, "YData", NaN, "Visible", "off");
            end
            gH = obj.ProjPoolGlow{slot};
            if ~isempty(gH) && isvalid(gH)
                set(gH, "XData", NaN, "YData", NaN, "Visible", "off");
            end
        end
    end

    % =================================================================
    % STATIC HELPERS
    % =================================================================
    methods (Static, Access = private)
        function [sz, rPts] = computeSizeData(ax, displayRange, rData)
            %computeSizeData  Convert data-unit radius to scatter SizeData.
            %   SizeData is in points^2. This uses getpixelposition and DPI to
            %   produce correct screen-space sizing that adapts to window resize.
            %
            %   [sz, rPts] = computeSizeData(ax, displayRange, rData)
            %     rData  — radius in data units
            %     sz     — SizeData value (points^2)
            %     rPts   — radius in typographic points
            pixPos = getpixelposition(ax);
            pxPerData = pixPos(3) / diff(displayRange.X);
            dpiVal = get(0, "ScreenPixelsPerInch");
            rPts = rData * pxPerData * 72 / dpiVal;
            sz = rPts^2 * pi;
        end
    end
end
