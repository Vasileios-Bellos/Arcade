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
    % GAME STATE
    % =================================================================
    properties (Access = private)
        CorePos         (1,2) double = [NaN, NaN]
        CoreRadius      (1,1) double = 18
        Lives           (1,1) double = 3
        MaxLives        (1,1) double = 3
        ShieldAngle     (1,1) double = 0        % shield center angle (radians)
        ShieldArc       (1,1) double = pi        % shield width (radians)
        Projectiles     struct = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                                        "type", {}, "speed", {}, "radius", {}, ...
                                        "color", {}, "scatterH", {}, "glowH", {})
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

            obj.CorePos = [mean(dx), mean(dy)];
            obj.Lives = 3;
            obj.MaxLives = 3;
            obj.ShieldAngle = 0;
            obj.ShieldArc = pi;
            obj.Wave = 1;
            obj.SpawnTimer = 0;
            obj.LivesFlashTic = [];

            obj.Projectiles = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "type", {}, "speed", {}, "radius", {}, "color", {}, ...
                "scatterH", {}, "glowH", {});

            % Core sizing
            coreR = max(18, round(min(areaW, areaH) * 0.12));
            obj.CoreRadius = coreR;

            % Shield radius
            shieldR = max(12, round(min(areaW, areaH) * 0.12));

            % Hitbox disc (scatter sized to collision radius in data units)
            hitboxR = shieldR * 0.9;
            axPix = getpixelposition(ax);
            dpiVal = get(0, "ScreenPixelsPerInch");
            pxPerData = axPix(4) / areaH;
            hitboxPts = hitboxR * pxPerData * 72 / dpiVal;
            obj.HitboxCircleH = scatter(ax, obj.CorePos(1), obj.CorePos(2), ...
                hitboxPts^2 * pi, obj.ColorCyan, "filled", ...
                "MarkerFaceAlpha", 0.6, "Tag", "GT_shieldguardian");

            % Core orb (fully opaque center)
            obj.CorePatchH = scatter(ax, obj.CorePos(1), obj.CorePos(2), ...
                coreR^2 * pi, obj.ColorCyan, "filled", "MarkerFaceAlpha", 1.0, ...
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
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame shield guardian logic.
            if obj.GameOver; return; end

            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);
            corePos = obj.CorePos;

            % Points-to-data conversion for scatter visual radius
            axPix = getpixelposition(ax);
            dpiVal = get(0, "ScreenPixelsPerInch");
            ptsToData = dpiVal / (72 * axPix(4) / areaH);

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
            obj.SpawnTimer = obj.SpawnTimer + 1;
            spawnRate = max(8, 30 - obj.Wave * 2);
            if obj.SpawnTimer >= spawnRate
                obj.SpawnTimer = 0;
                obj.spawnProjectile();
            end

            % --- Move projectiles ---
            hitboxR = shieldR * 0.9;
            idx = 1;
            while idx <= numel(obj.Projectiles)
                p = obj.Projectiles(idx);
                p.x = p.x + p.vx;
                p.y = p.y + p.vy;
                obj.Projectiles(idx) = p;

                if ~isempty(p.scatterH) && isvalid(p.scatterH)
                    p.scatterH.XData = p.x;
                    p.scatterH.YData = p.y;
                end
                if ~isempty(p.glowH) && isvalid(p.glowH)
                    p.glowH.XData = p.x;
                    p.glowH.YData = p.y;
                end

                distToCore = norm([p.x - corePos(1), p.y - corePos(2)]);

                % --- Shield deflection ---
                if distToCore < shieldR + 3 && distToCore > shieldR - 5
                    projAngle = atan2(p.y - corePos(2), p.x - corePos(1));
                    angleDiff = mod(projAngle - obj.ShieldAngle + pi, 2*pi) - pi;
                    if abs(angleDiff) < obj.ShieldArc / 2
                        obj.addScore(25);
                        obj.incrementCombo();
                        normalVec = [cos(projAngle), sin(projAngle)];
                        vel = [p.vx, p.vy];
                        reflected = vel - 2 * dot(vel, normalVec) * normalVec;
                        obj.Projectiles(idx).vx = reflected(1) * 1.5;
                        obj.Projectiles(idx).vy = reflected(2) * 1.5;
                        obj.Projectiles(idx).type = "deflected";
                        if ~isempty(p.scatterH) && isvalid(p.scatterH)
                            p.scatterH.CData = obj.ColorGreen;
                        end
                        if ~isempty(p.glowH) && isvalid(p.glowH)
                            p.glowH.CData = obj.ColorGreen;
                        end
                        obj.spawnBounceEffect([p.x, p.y], normalVec, 0, 6);
                        idx = idx + 1;
                        continue;
                    end
                end

                % --- Core hit (hitbox = glow radius) ---
                if distToCore < hitboxR && p.type ~= "deflected"
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
                    obj.spawnBounceEffect([p.x, p.y], [0, 1], 0, 14);

                    if ~isempty(p.scatterH) && isvalid(p.scatterH)
                        delete(p.scatterH);
                    end
                    if ~isempty(p.glowH) && isvalid(p.glowH)
                        delete(p.glowH);
                    end
                    obj.Projectiles(idx) = [];

                    if obj.Lives <= 0
                        obj.GameOver = true;
                        obj.IsRunning = false;
                        return;
                    end
                    continue;
                end

                % --- Off screen ---
                if p.x < dx(1) - 30 || p.x > dx(2) + 30 ...
                        || p.y < dy(1) - 30 || p.y > dy(2) + 30
                    if ~isempty(p.scatterH) && isvalid(p.scatterH)
                        delete(p.scatterH);
                    end
                    if ~isempty(p.glowH) && isvalid(p.glowH)
                        delete(p.glowH);
                    end
                    obj.Projectiles(idx) = [];
                    continue;
                end

                % --- Deflected hitting another projectile (chain) ---
                if p.type == "deflected"
                    for j = numel(obj.Projectiles):-1:1
                        if j == idx; continue; end
                        other = obj.Projectiles(j);
                        if other.type ~= "deflected" && ...
                                norm([p.x - other.x, p.y - other.y]) ...
                                < (p.radius + other.radius) * ptsToData
                            obj.addScore(50);
                            obj.incrementCombo();
                            obj.spawnBounceEffect( ...
                                [other.x, other.y], [0, -1], 0, 8);
                            if ~isempty(other.scatterH) ...
                                    && isvalid(other.scatterH)
                                delete(other.scatterH);
                            end
                            if ~isempty(other.glowH) ...
                                    && isvalid(other.glowH)
                                delete(other.glowH);
                            end
                            obj.Projectiles(j) = [];
                            if j < idx; idx = idx - 1; end
                        end
                    end
                end

                idx = idx + 1;
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

            for k = 1:numel(obj.Projectiles)
                if ~isempty(obj.Projectiles(k).scatterH) ...
                        && isvalid(obj.Projectiles(k).scatterH)
                    delete(obj.Projectiles(k).scatterH);
                end
                if ~isempty(obj.Projectiles(k).glowH) ...
                        && isvalid(obj.Projectiles(k).glowH)
                    delete(obj.Projectiles(k).glowH);
                end
            end
            obj.Projectiles = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "type", {}, "speed", {}, "radius", {}, "color", {}, ...
                "scatterH", {}, "glowH", {});

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
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);

            % Spawn from random edge
            spawnAngle = rand * 2 * pi;
            spawnR = max(areaW, areaH) * 0.6;
            x = obj.CorePos(1) + spawnR * cos(spawnAngle);
            y = obj.CorePos(2) + spawnR * sin(spawnAngle);

            % Aim at core with some spread
            toCore = [obj.CorePos(1) - x, obj.CorePos(2) - y];
            toCore = toCore / norm(toCore);
            spreadVal = (rand - 0.5) * 0.3;
            ca = cos(spreadVal);
            sa = sin(spreadVal);
            aimed = [toCore(1)*ca - toCore(2)*sa, toCore(1)*sa + toCore(2)*ca];

            baseSpeed = max(0.8, min(areaW, areaH) * 0.008) ...
                * (1 + obj.Wave * 0.1);

            % Random type: fast (red), normal (magenta), heavy (orange)
            pType = randi(3);
            switch pType
                case 1  % Fast: small, red, 1.5x speed
                    clr = obj.ColorRed;
                    speedMult = 1.5;
                    radiusVal = max(4, obj.CoreRadius * 0.6);
                case 2  % Normal: medium, magenta, 1x speed
                    clr = obj.ColorMagenta;
                    speedMult = 1.0;
                    radiusVal = max(6, obj.CoreRadius * 0.8);
                case 3  % Heavy: large, orange, 0.6x speed
                    clr = obj.ColorOrange;
                    speedMult = 0.6;
                    radiusVal = max(8, obj.CoreRadius * 1.0);
            end

            speedVal = baseSpeed * speedMult;
            vx = aimed(1) * speedVal;
            vy = aimed(2) * speedVal;

            markerSz = max(40, radiusVal^2 * pi);
            scatterH = scatter(ax, x, y, markerSz, clr, "filled", ...
                "MarkerFaceAlpha", 0.8, "Tag", "GT_shieldguardian");
            glowH = scatter(ax, x, y, markerSz * 3, clr, "filled", ...
                "MarkerFaceAlpha", 0.12, "Tag", "GT_shieldguardian");

            obj.Projectiles(end + 1) = struct("x", x, "y", y, ...
                "vx", vx, "vy", vy, "type", "incoming", "speed", speedVal, ...
                "radius", radiusVal, "color", clr, ...
                "scatterH", scatterH, "glowH", glowH);
        end
    end
end
