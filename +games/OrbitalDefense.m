classdef OrbitalDefense < GameBase
    %OrbitalDefense  Defend a hex base from approaching asteroids.
    %   Stationary hexagonal base at center. Asteroids approach from edges.
    %   Auto-fire interceptors toward finger position. Explosions chain-react
    %   to destroy nearby asteroids. Wave-based progression with splitting.
    %
    %   Standalone: games.OrbitalDefense().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Orbital Defense"
    end

    % =================================================================
    % COLOR CONSTANTS (not in GameBase)
    % =================================================================
    properties (Constant, Access = private)
        ColorOrange     (1,3) double = [1, 0.6, 0.15]
        ColorSilver     (1,3) double = [0.75, 0.78, 0.82]
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        Asteroids       struct = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                                        "radius", {}, "tier", {}, "angle", {}, ...
                                        "spin", {}, "patchH", {})
        Explosions      struct = struct("x", {}, "y", {}, "radius", {}, ...
                                        "maxRadius", {}, "phase", {}, ...
                                        "patchH", {}, "glowH", {})
        Interceptors    struct = struct("x", {}, "y", {}, "tx", {}, "ty", {}, ...
                                        "speed", {}, "lineH", {})
        Wave            (1,1) double = 1
        Lives           (1,1) double = 3
        BasePos         (1,2) double = [0, 0]
        BaseRadius      (1,1) double = 12
        FireCD          (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BasePatchH                      % patch  -- hex base station
        BaseGlowH                       % scatter -- base glow
        CrossH                          % line   -- crosshair lines
        CrossGlowH                      % line   -- crosshair glow
        CrossCircleH                    % scatter -- crosshair red circle
        LivesTextH                      % text   -- lives flash display
        LivesFlashTic   = []            % tic for lives flash animation
        WaveTextH                       % text   -- wave flash display
        WaveFlashTic    = []            % tic for wave flash animation
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize state.
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

            dx = displayRange.X;
            dy = displayRange.Y;

            obj.Wave = 1;
            obj.Lives = 3;
            obj.FireCD = 0;
            obj.Asteroids = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "radius", {}, "tier", {}, "angle", {}, "spin", {}, "patchH", {});
            obj.Explosions = struct("x", {}, "y", {}, "radius", {}, ...
                "maxRadius", {}, "phase", {}, "patchH", {}, "glowH", {});
            obj.Interceptors = struct("x", {}, "y", {}, "tx", {}, "ty", {}, ...
                "speed", {}, "lineH", {});

            % Base station at center (hexagonal shape)
            cx = mean(dx);
            cy = mean(dy);
            obj.BasePos = [cx, cy];
            baseR = max(8, round(min(diff(dx), diff(dy)) * 0.035));
            obj.BaseRadius = baseR;
            hexTheta = linspace(0, 2*pi, 7);
            bpx = cx + baseR * cos(hexTheta);
            bpy = cy + baseR * sin(hexTheta);

            obj.BaseGlowH = scatter(ax, cx, cy, (baseR * 4)^2, obj.ColorCyan, ...
                "filled", "MarkerFaceAlpha", 0.15, "Tag", "GT_orbitaldefense");
            obj.BasePatchH = patch(ax, "XData", bpx, "YData", bpy, ...
                "FaceColor", obj.ColorCyan, "FaceAlpha", 0.25, ...
                "EdgeColor", obj.ColorCyan, "LineWidth", 2, "Tag", "GT_orbitaldefense");

            % Crosshair (gold cross + red scatter circle matching fingertip)
            obj.CrossCircleH = scatter(ax, NaN, NaN, 6000, ...
                "MarkerEdgeColor", "r", "LineWidth", 1.5, ...
                "MarkerFaceColor", "none", "Tag", "GT_orbitaldefense");
            obj.CrossGlowH = line(ax, NaN, NaN, "Color", [obj.ColorGold, 0.3], ...
                "LineWidth", 3, "Tag", "GT_orbitaldefense");
            obj.CrossH = line(ax, NaN, NaN, "Color", obj.ColorGold, ...
                "LineWidth", 1, "Tag", "GT_orbitaldefense");

            % Lives text (centered, hidden, flash on change)
            obj.LivesTextH = text(ax, cx, cy + diff(dy) * 0.2, "", ...
                "Color", obj.ColorRed, "FontSize", max(18, round(diff(dy) * 0.1)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_orbitaldefense");
            obj.LivesFlashTic = [];

            % Wave text (centered, hidden, flash on change)
            obj.WaveTextH = text(ax, cx, cy - diff(dy) * 0.2, "", ...
                "Color", obj.ColorGold, "FontSize", max(16, round(diff(dy) * 0.08)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_orbitaldefense");
            obj.WaveFlashTic = [];

            % Spawn first wave
            obj.spawnWave(obj.Wave);
            obj.showWave(obj.Wave);
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame orbital defense logic.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % --- Update crosshair ---
            if ~any(isnan(pos))
                crSize = 5;
                crX = [pos(1)-crSize, pos(1)+crSize, NaN, ...
                       pos(1), pos(1)];
                crY = [pos(2), pos(2), NaN, ...
                       pos(2)-crSize, pos(2)+crSize];
                if ~isempty(obj.CrossCircleH) && isvalid(obj.CrossCircleH)
                    obj.CrossCircleH.XData = pos(1);
                    obj.CrossCircleH.YData = pos(2);
                end
                if ~isempty(obj.CrossH) && isvalid(obj.CrossH)
                    obj.CrossH.XData = crX;
                    obj.CrossH.YData = crY;
                end
                if ~isempty(obj.CrossGlowH) && isvalid(obj.CrossGlowH)
                    obj.CrossGlowH.XData = crX;
                    obj.CrossGlowH.YData = crY;
                end

                % Auto-fire interceptors from base toward crosshair
                distToBase = norm(pos - obj.BasePos);
                obj.FireCD = obj.FireCD + 1;
                if obj.FireCD >= 15 && distToBase > obj.BaseRadius
                    obj.FireCD = 0;
                    launchX = obj.BasePos(1);
                    launchY = obj.BasePos(2);
                    lineH = line(ax, [launchX, launchX], [launchY, launchY], ...
                        "Color", obj.ColorCyan, "LineWidth", 1, ...
                        "Tag", "GT_orbitaldefense");
                    intSpeed = max(2, diff(dy) * 0.025);
                    obj.Interceptors(end + 1) = struct("x", launchX, "y", launchY, ...
                        "tx", pos(1), "ty", pos(2), ...
                        "speed", intSpeed, "lineH", lineH);
                end
            end

            % --- Move interceptors ---
            k = 1;
            while k <= numel(obj.Interceptors)
                ic = obj.Interceptors(k);
                dirVec = [ic.tx - ic.x, ic.ty - ic.y];
                dirDist = norm(dirVec);
                if dirDist < ic.speed
                    % Reached target -- explode
                    obj.spawnExplosion(ic.tx, ic.ty);
                    if ~isempty(ic.lineH) && isvalid(ic.lineH); delete(ic.lineH); end
                    obj.Interceptors(k) = [];
                    continue;
                end
                dirVec = dirVec / dirDist;
                ic.x = ic.x + dirVec(1) * ic.speed;
                ic.y = ic.y + dirVec(2) * ic.speed;
                % Off-screen -- silently remove (no explosion)
                if ic.x < dx(1) - 20 || ic.x > dx(2) + 20 || ...
                        ic.y < dy(1) - 20 || ic.y > dy(2) + 20
                    if ~isempty(ic.lineH) && isvalid(ic.lineH); delete(ic.lineH); end
                    obj.Interceptors(k) = [];
                    continue;
                end
                obj.Interceptors(k) = ic;
                if ~isempty(ic.lineH) && isvalid(ic.lineH)
                    ic.lineH.XData = [ic.lineH.XData(1), ic.x];
                    ic.lineH.YData = [ic.lineH.YData(1), ic.y];
                end
                k = k + 1;
            end

            % --- Move asteroids + wrap around edges ---
            for a = 1:numel(obj.Asteroids)
                ast = obj.Asteroids(a);
                ast.x = ast.x + ast.vx;
                ast.y = ast.y + ast.vy;
                ast.angle = ast.angle + ast.spin;

                margin = ast.radius;
                if ast.x < dx(1) - margin; ast.x = dx(2) + margin; end
                if ast.x > dx(2) + margin; ast.x = dx(1) - margin; end
                if ast.y < dy(1) - margin; ast.y = dy(2) + margin; end
                if ast.y > dy(2) + margin; ast.y = dy(1) - margin; end

                obj.Asteroids(a) = ast;

                if ~isempty(ast.patchH) && isvalid(ast.patchH)
                    origCX = mean(ast.patchH.XData);
                    origCY = mean(ast.patchH.YData);
                    ast.patchH.XData = ast.patchH.XData - origCX + ast.x;
                    ast.patchH.YData = ast.patchH.YData - origCY + ast.y;
                end
            end

            % --- Update explosions + check explosion-asteroid intersection ---
            k = 1;
            while k <= numel(obj.Explosions)
                ex = obj.Explosions(k);
                if ex.phase == 1
                    ex.radius = ex.radius + ex.maxRadius * 0.1;
                    if ex.radius >= ex.maxRadius; ex.phase = 2; end
                else
                    ex.radius = ex.radius - ex.maxRadius * 0.08;
                end
                obj.Explosions(k) = ex;

                % Chain explosion: destroy asteroids caught in blast
                tierRadii = [15, 10, 5];
                for m = numel(obj.Asteroids):-1:1
                    ast = obj.Asteroids(m);
                    if norm([ast.x - ex.x, ast.y - ex.y]) < ex.radius + ast.radius
                        pts = round(300 / ast.radius * 10);
                        obj.addScore(pts);
                        obj.incrementCombo();

                        % Split into next tier (15->10->5->destroy)
                        nextTier = ast.tier + 1;
                        if nextTier <= numel(tierRadii)
                            for s = 1:2
                                sAngle = rand * 2 * pi;
                                sSpeed = norm([ast.vx, ast.vy]) * (1.2 + rand * 0.5);
                                svx = sSpeed * cos(sAngle);
                                svy = sSpeed * sin(sAngle);
                                obj.createAsteroid(ast.x, ast.y, svx, svy, ...
                                    tierRadii(nextTier), nextTier);
                            end
                        end
                        if ~isempty(ast.patchH) && isvalid(ast.patchH); delete(ast.patchH); end
                        obj.Asteroids(m) = [];
                        % Chain explosion at asteroid position
                        obj.spawnExplosion(ast.x, ast.y);
                    end
                end

                % Update explosion graphics
                circTheta = linspace(0, 2*pi, 24);
                if ~isempty(ex.patchH) && isvalid(ex.patchH)
                    ex.patchH.XData = ex.x + ex.radius * cos(circTheta);
                    ex.patchH.YData = ex.y + ex.radius * sin(circTheta);
                end
                if ~isempty(ex.glowH) && isvalid(ex.glowH)
                    ex.glowH.XData = ex.x + ex.radius * 1.3 * cos(circTheta);
                    ex.glowH.YData = ex.y + ex.radius * 1.3 * sin(circTheta);
                end

                if ex.radius <= 0
                    if ~isempty(ex.patchH) && isvalid(ex.patchH); delete(ex.patchH); end
                    if ~isempty(ex.glowH) && isvalid(ex.glowH); delete(ex.glowH); end
                    obj.Explosions(k) = [];
                    continue;
                end
                k = k + 1;
            end

            % --- Asteroid-base collision ---
            for a = numel(obj.Asteroids):-1:1
                ast = obj.Asteroids(a);
                if norm([ast.x - obj.BasePos(1), ast.y - obj.BasePos(2)]) < ...
                        ast.radius + obj.BaseRadius
                    obj.Lives = obj.Lives - 1;
                    obj.resetCombo();

                    % Flash lives
                    if ~isempty(obj.LivesTextH) && isvalid(obj.LivesTextH)
                        obj.LivesTextH.String = sprintf("Lives: %d", obj.Lives);
                        obj.LivesTextH.Color = obj.ColorRed;
                        obj.LivesTextH.Visible = "on";
                        obj.LivesFlashTic = tic;
                    end
                    obj.spawnBounceEffect([ast.x, ast.y], [0, -1], 0, 12);
                    if ~isempty(ast.patchH) && isvalid(ast.patchH); delete(ast.patchH); end
                    obj.Asteroids(a) = [];
                    if obj.Lives <= 0
                        obj.IsRunning = false;
                        return;
                    end
                end
            end

            % --- Lives flash animation (0.6s hold + 0.4s fade) ---
            if ~isempty(obj.LivesFlashTic) && ~isempty(obj.LivesTextH) && ...
                    isgraphics(obj.LivesTextH) && isvalid(obj.LivesTextH)
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

            % --- Wave flash animation (1.2s hold + 0.5s fade) ---
            if ~isempty(obj.WaveFlashTic) && ~isempty(obj.WaveTextH) && ...
                    isgraphics(obj.WaveTextH) && isvalid(obj.WaveTextH)
                wEl = toc(obj.WaveFlashTic);
                if wEl < 1.2
                    obj.WaveTextH.Color = obj.ColorGold;
                elseif wEl < 1.7
                    wFadeAlpha = 1 - (wEl - 1.2) / 0.5;
                    obj.WaveTextH.Color = [obj.ColorGold, max(0, wFadeAlpha)];
                else
                    obj.WaveTextH.Visible = "off";
                    obj.WaveFlashTic = [];
                end
            end

            % --- Wave cleared? (don't wait for explosions -- they're cosmetic) ---
            if isempty(obj.Asteroids)
                obj.Wave = obj.Wave + 1;
                obj.addScore(200 * obj.Wave);
                obj.spawnWave(obj.Wave);
                obj.showWave(obj.Wave);
            end

            % --- Hit effects ---
            obj.updateHitEffects();
        end

        function onCleanup(obj)
            %onCleanup  Delete all orbital defense graphics.
            handles = {obj.CrossH, obj.CrossGlowH, obj.CrossCircleH, ...
                       obj.BasePatchH, obj.BaseGlowH, ...
                       obj.LivesTextH, obj.WaveTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.CrossH = [];
            obj.CrossGlowH = [];
            obj.CrossCircleH = [];
            obj.BasePatchH = [];
            obj.BaseGlowH = [];
            obj.LivesTextH = [];
            obj.WaveTextH = [];

            % Delete asteroid patches
            for k = 1:numel(obj.Asteroids)
                if ~isempty(obj.Asteroids(k).patchH) && isvalid(obj.Asteroids(k).patchH)
                    delete(obj.Asteroids(k).patchH);
                end
            end
            obj.Asteroids = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "radius", {}, "tier", {}, "angle", {}, "spin", {}, "patchH", {});

            % Delete explosion patches
            for k = 1:numel(obj.Explosions)
                if ~isempty(obj.Explosions(k).patchH) && isvalid(obj.Explosions(k).patchH)
                    delete(obj.Explosions(k).patchH);
                end
                if ~isempty(obj.Explosions(k).glowH) && isvalid(obj.Explosions(k).glowH)
                    delete(obj.Explosions(k).glowH);
                end
            end
            obj.Explosions = struct("x", {}, "y", {}, "radius", {}, ...
                "maxRadius", {}, "phase", {}, "patchH", {}, "glowH", {});

            % Delete interceptor lines
            for k = 1:numel(obj.Interceptors)
                if ~isempty(obj.Interceptors(k).lineH) && isvalid(obj.Interceptors(k).lineH)
                    delete(obj.Interceptors(k).lineH);
                end
            end
            obj.Interceptors = struct("x", {}, "y", {}, "tx", {}, "ty", {}, ...
                "speed", {}, "lineH", {});

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_orbitaldefense");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for orbital defense.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return orbital defense results.
            r.Title = "ORBITAL DEFENSE";
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            r.Lines = {
                sprintf("Wave: %d  |  Lives: %d  |  Score: %d  |  Time: %.0fs  |  Max Combo: %d", ...
                    obj.Wave, obj.Lives, obj.Score, elapsed, obj.MaxCombo)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function spawnWave(obj, wave)
            %spawnWave  Spawn asteroids for the given wave number.
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);

            nLarge = 2 + wave;
            nMedium = 1 + floor(wave * 0.8);
            nSmall = floor(wave * 0.6);
            tierRadii = [15, 10, 5];
            tierSpeedMult = [1.0, 1.5, 2.2];
            counts = [nLarge, nMedium, nSmall];
            baseSpeed = max(0.3, min(areaW, areaH) * 0.004) * (1 + wave * 0.08);

            for tier = 1:3
                for m = 1:counts(tier)
                    edgeIdx = randi(4);
                    rockR = tierRadii(tier);
                    switch edgeIdx
                        case 1; sx = dx(1) - rockR; sy = dy(1) + rand * areaH;
                        case 2; sx = dx(2) + rockR; sy = dy(1) + rand * areaH;
                        case 3; sx = dx(1) + rand * areaW; sy = dy(1) - rockR;
                        case 4; sx = dx(1) + rand * areaW; sy = dy(2) + rockR;
                    end

                    toBase = obj.BasePos - [sx, sy];
                    toBase = toBase / norm(toBase);
                    spread = (rand - 0.5) * 1.5;
                    launchAngle = atan2(toBase(2), toBase(1)) + spread;
                    spawnSpeed = baseSpeed * tierSpeedMult(tier) * (0.6 + rand * 0.8);
                    vx = spawnSpeed * cos(launchAngle);
                    vy = spawnSpeed * sin(launchAngle);

                    obj.createAsteroid(sx, sy, vx, vy, rockR, tier);
                end
            end
        end

        function createAsteroid(obj, sx, sy, vx, vy, rockRadius, tier)
            %createAsteroid  Create a single asteroid with neon wireframe.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            nVerts = 8 + randi(4);
            vertAngles = sort(rand(1, nVerts) * 2 * pi);
            vertRadii = rockRadius * (0.7 + 0.3 * rand(1, nVerts));
            px = sx + vertRadii .* cos(vertAngles);
            py = sy + vertRadii .* sin(vertAngles);
            px(end+1) = px(1);
            py(end+1) = py(1);

            tierColors = {obj.ColorSilver, obj.ColorGold, obj.ColorRed};
            rockColor = tierColors{min(tier, 3)};

            pH = patch(ax, "XData", px, "YData", py, ...
                "FaceColor", rockColor, "FaceAlpha", 0.20, ...
                "EdgeColor", rockColor, "LineWidth", 1.5, ...
                "Tag", "GT_orbitaldefense");

            obj.Asteroids(end + 1) = struct("x", sx, "y", sy, ...
                "vx", vx, "vy", vy, ...
                "radius", rockRadius, "tier", tier, "angle", 0, ...
                "spin", (rand - 0.5) * 0.05, "patchH", pH);
        end

        function spawnExplosion(obj, ex, ey)
            %spawnExplosion  Create an expanding/contracting explosion.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end
            maxR = max(8, min(diff(obj.DisplayRange.X), diff(obj.DisplayRange.Y)) * 0.06);
            circTheta = linspace(0, 2*pi, 24);
            pH = patch(ax, "XData", ex + cos(circTheta), ...
                "YData", ey + sin(circTheta), ...
                "FaceColor", obj.ColorOrange, "FaceAlpha", 0.4, ...
                "EdgeColor", obj.ColorGold, "LineWidth", 1, ...
                "Tag", "GT_orbitaldefense");
            gH = patch(ax, "XData", ex + 1.3*cos(circTheta), ...
                "YData", ey + 1.3*sin(circTheta), ...
                "FaceColor", obj.ColorOrange, "FaceAlpha", 0.1, ...
                "EdgeColor", "none", "Tag", "GT_orbitaldefense");
            obj.Explosions(end + 1) = struct("x", ex, "y", ey, "radius", 1, ...
                "maxRadius", maxR, "phase", 1, "patchH", pH, "glowH", gH);
        end

        function showWave(obj, wave)
            %showWave  Flash wave number on screen.
            if ~isempty(obj.WaveTextH) && isvalid(obj.WaveTextH)
                obj.WaveTextH.String = sprintf("Wave %d", wave);
                obj.WaveTextH.Color = obj.ColorGold;
                obj.WaveTextH.Visible = "on";
                obj.WaveFlashTic = tic;
            end
        end
    end
end
