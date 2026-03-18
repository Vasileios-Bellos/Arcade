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
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        CorePos         (1,2) double = [NaN, NaN]
        CoreRadius      (1,1) double = 18
        Lives           (1,1) double = 3
        MaxLives        (1,1) double = 3
        ShieldAngle     (1,1) double = 0        % shield center angle (radians)
        ShieldArc       (1,1) double = pi        % shield width (radians)
        Wave            (1,1) double = 1
        SpawnTimer      (1,1) double = 0
        GameOver        (1,1) logical = false
        CachedPtsToData (1,1) double = 1        % points-to-data conversion factor
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
            obj.ProjVx(:) = 0;
            obj.ProjVy(:) = 0;
            obj.ProjSpeed(:) = 0;
            obj.ProjRadius(:) = 0;
            obj.ProjColor(:) = 0;
            obj.ProjType(:) = "";

            % Core sizing
            coreR = max(18, round(min(areaW, areaH) * 0.12));
            obj.CoreRadius = coreR;

            % Shield radius (same as GestureTrainer original)
            shieldR = max(12, round(min(areaW, areaH) * 0.12));

            % Cache DPI/pixel conversion (expensive calls done once)
            axPix = getpixelposition(ax);
            dpiVal = get(0, "ScreenPixelsPerInch");
            pxPerData = axPix(4) / areaH;
            obj.CachedPtsToData = dpiVal / (72 * pxPerData);

            % Hitbox disc (scatter sized to collision radius in data units)
            hitboxR = shieldR * 0.9;
            hitboxPts = hitboxR * pxPerData * 72 / dpiVal;
            obj.HitboxCircleH = scatter(ax, obj.CorePos(1), obj.CorePos(2), ...
                hitboxPts^2 * pi, obj.ColorCyan, "filled", ...
                "MarkerFaceAlpha", 0.6, "Tag", "GT_shieldguardian");

            % Core orb (fully opaque center — convert data radius to screen points)
            corePts = coreR * pxPerData * 72 / dpiVal;
            obj.CorePatchH = scatter(ax, obj.CorePos(1), obj.CorePos(2), ...
                corePts^2 * pi, obj.ColorCyan, "filled", "MarkerFaceAlpha", 1.0, ...
                "Tag", "GT_shieldguardian");

            % Shield arc
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
            obj.ProjPoolScatter = cell(1, 20);
            obj.ProjPoolGlow = cell(1, 20);
            defaultSz = max(40, coreR^2 * pi);
            for k = 1:20
                obj.ProjPoolGlow{k} = scatter(ax, NaN, NaN, defaultSz * 3, ...
                    obj.ColorRed, "filled", "MarkerFaceAlpha", 0.12, ...
                    "Visible", "off", "Tag", "GT_shieldguardian");
                obj.ProjPoolScatter{k} = scatter(ax, NaN, NaN, defaultSz, ...
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
            areaW = diff(dx);
            areaH = diff(dy);
            corePos = obj.CorePos;

            % Use cached points-to-data conversion
            ptsToData = obj.CachedPtsToData;

            % --- Update shield angle based on finger position ---
            if ~any(isnan(pos))
                obj.ShieldAngle = atan2( ...
                    pos(2) - corePos(2), pos(1) - corePos(1));
            end

            % --- Update shield graphics ---
            shieldR = max(12, round(min(areaW, areaH) * 0.12));
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
            spawnRate = max(8, 30 - obj.Wave * 2);
            if obj.SpawnTimer >= spawnRate
                obj.SpawnTimer = 0;
                obj.spawnProjectile();
            end

            % --- Move projectiles (iterate active pool slots in reverse) ---
            hitboxR = shieldR * 0.9;
            activeIdx = find(obj.ProjActive);

            for ii = numel(activeIdx):-1:1
                k = activeIdx(ii);

                % Move
                obj.ProjX(k) = obj.ProjX(k) + obj.ProjVx(k) * ds;
                obj.ProjY(k) = obj.ProjY(k) + obj.ProjVy(k) * ds;
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

                % --- Shield deflection ---
                if distToCore < shieldR + 3 && distToCore > shieldR - 5
                    projAngle = atan2(py - corePos(2), px - corePos(1));
                    angleDiff = mod(projAngle - obj.ShieldAngle + pi, 2*pi) - pi;
                    if abs(angleDiff) < obj.ShieldArc / 2
                        obj.addScore(25);
                        obj.incrementCombo();
                        normalVec = [cos(projAngle), sin(projAngle)];
                        vel = [obj.ProjVx(k), obj.ProjVy(k)];
                        reflected = vel - 2 * dot(vel, normalVec) * normalVec;
                        obj.ProjVx(k) = reflected(1) * 1.5;
                        obj.ProjVy(k) = reflected(2) * 1.5;
                        obj.ProjType(k) = "deflected";
                        if ~isempty(sH) && isvalid(sH)
                            sH.CData = obj.ColorGreen;
                        end
                        if ~isempty(gH) && isvalid(gH)
                            gH.CData = obj.ColorGreen;
                        end
                        obj.spawnBounceEffect([px, py], normalVec, 0, 6);
                        continue;
                    end
                end

                % --- Core hit (hitbox = glow radius) ---
                if distToCore < hitboxR && obj.ProjType(k) ~= "deflected"
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

                % --- Off screen ---
                if px < dx(1) - 30 || px > dx(2) + 30 ...
                        || py < dy(1) - 30 || py > dy(2) + 30
                    obj.deactivateProjectile(k);
                    continue;
                end

                % --- Deflected hitting another projectile (chain) ---
                if obj.ProjType(k) == "deflected"
                    activeJ = find(obj.ProjActive);
                    for jj = numel(activeJ):-1:1
                        j = activeJ(jj);
                        if j == k; continue; end
                        if obj.ProjType(j) ~= "deflected" && ...
                                sqrt((px - obj.ProjX(j))^2 + ...
                                     (py - obj.ProjY(j))^2) ...
                                < (obj.ProjRadius(k) + obj.ProjRadius(j)) * ptsToData
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
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            if obj.Lives <= 0
                statusStr = "GAME OVER";
            else
                statusStr = sprintf("SURVIVED (Lives: %d)", obj.Lives);
            end
            r.Lines = {
                sprintf("Wave: %d  |  %s  |  Score: %d  |  Time: %.0fs  |  Max Combo: %d", ...
                    obj.Wave, statusStr, obj.Score, elapsed, obj.MaxCombo)
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
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            % Find first inactive pool slot
            slot = find(~obj.ProjActive, 1);
            if isempty(slot); return; end  % pool exhausted, skip spawn

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);

            % Spawn from just beyond visible edge (direction-dependent)
            spawnAngle = rand * 2 * pi;
            halfW = areaW / 2;
            halfH = areaH / 2;
            absCos = max(abs(cos(spawnAngle)), 1e-6);
            absSin = max(abs(sin(spawnAngle)), 1e-6);
            edgeDist = min(halfW / absCos, halfH / absSin);
            spawnR = edgeDist + 15;  % 15 data-unit margin beyond edge
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

            baseSpeed = max(0.8, min(areaW, areaH) * 0.02) ...
                * (1 + obj.Wave * 0.1);

            % Random type: fast (red), normal (magenta), heavy (orange)
            pType = randi(3);
            switch pType
                case 1  % Fast: small, red, 1.5x speed
                    clr = obj.ColorRed;
                    speedMult = 1.5;
                    radiusVal = max(4, obj.CoreRadius * 0.2);
                case 2  % Normal: medium, magenta, 1x speed
                    clr = obj.ColorMagenta;
                    speedMult = 1.0;
                    radiusVal = max(6, obj.CoreRadius * 0.3);
                case 3  % Heavy: large, orange, 0.6x speed
                    clr = obj.ColorOrange;
                    speedMult = 0.6;
                    radiusVal = max(8, obj.CoreRadius * 0.45);
            end

            speedVal = baseSpeed * speedMult;
            vx = aimed(1) * speedVal;
            vy = aimed(2) * speedVal;
            % Convert data-unit radius to screen points for SizeData
            radiusPts = radiusVal / obj.CachedPtsToData;
            markerSz = max(40, radiusPts^2 * pi);

            % Populate pool slot
            obj.ProjX(slot) = x;
            obj.ProjY(slot) = y;
            obj.ProjVx(slot) = vx;
            obj.ProjVy(slot) = vy;
            obj.ProjType(slot) = "incoming";
            obj.ProjSpeed(slot) = speedVal;
            obj.ProjRadius(slot) = radiusVal;
            obj.ProjColor(slot, :) = clr;
            obj.ProjActive(slot) = true;

            % Activate pool scatter handles
            sH = obj.ProjPoolScatter{slot};
            if ~isempty(sH) && isvalid(sH)
                set(sH, "XData", x, "YData", y, "SizeData", markerSz, ...
                    "CData", clr, "Visible", "on");
            end
            gH = obj.ProjPoolGlow{slot};
            if ~isempty(gH) && isvalid(gH)
                set(gH, "XData", x, "YData", y, "SizeData", markerSz * 3, ...
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
end
