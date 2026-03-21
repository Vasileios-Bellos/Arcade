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
        Wave            (1,1) double = 1
        Lives           (1,1) double = 3
        BasePos         (1,2) double = [0, 0]
        BaseRadius      (1,1) double = 12
        FireCD          (1,1) double = 0
        Sc              (1,1) double = 1       % display scale (1.0 at ~180px)
        TierRadii       (1,3) double = [15, 10, 5]
    end

    % =================================================================
    % PRE-COMPUTED CONSTANTS
    % =================================================================
    properties (Access = private)
        ThetaCircle24   (1,24) double   % linspace(0, 2*pi, 24) — computed once
    end

    % =================================================================
    % INTERCEPTOR POOL (10 slots)
    % =================================================================
    properties (Access = private)
        IntPoolLine             % cell array of 10 line handles
        IntX            (1,10) double = zeros(1,10)
        IntY            (1,10) double = zeros(1,10)
        IntTx           (1,10) double = zeros(1,10)
        IntTy           (1,10) double = zeros(1,10)
        IntSpeed        (1,10) double = zeros(1,10)
        IntActive       (1,10) logical = false(1,10)
    end

    % =================================================================
    % EXPLOSION POOL (12 slots)
    % =================================================================
    properties (Access = private)
        ExpPoolPatch            % cell array of 12 patch handles (core)
        ExpPoolGlow             % cell array of 12 patch handles (glow)
        ExpX            (1,12) double = zeros(1,12)
        ExpY            (1,12) double = zeros(1,12)
        ExpRadius       (1,12) double = zeros(1,12)
        ExpMaxRadius    (1,12) double = zeros(1,12)
        ExpPhase        (1,12) double = zeros(1,12)   % 1=expanding, 2=contracting
        ExpActive       (1,12) logical = false(1,12)
    end

    % =================================================================
    % ASTEROID POOL (50 slots)
    % =================================================================
    properties (Access = private)
        AstPoolPatch            % cell array of 50 patch handles
        AstX            (1,50) double = zeros(1,50)
        AstY            (1,50) double = zeros(1,50)
        AstVx           (1,50) double = zeros(1,50)
        AstVy           (1,50) double = zeros(1,50)
        AstRadius       (1,50) double = zeros(1,50)
        AstTier         (1,50) double = zeros(1,50)
        AstAngle        (1,50) double = zeros(1,50)
        AstSpin         (1,50) double = zeros(1,50)
        AstShapeX               % cell array of 50 relative vertex X arrays
        AstShapeY               % cell array of 50 relative vertex Y arrays
        AstActive       (1,50) logical = false(1,50)
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

            areaW = diff(dx);
            areaH = diff(dy);
            obj.Sc = min(areaW, areaH) / 180;
            obj.TierRadii = round([15, 10, 5] * obj.Sc);

            obj.Wave = 1;
            obj.Lives = 3;
            obj.FireCD = 0;

            % Pre-compute constant theta array
            obj.ThetaCircle24 = linspace(0, 2*pi, 24);

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
            ps = obj.getPixelScale();

            obj.BasePatchH = patch(ax, "XData", bpx, "YData", bpy, ...
                "FaceColor", obj.ColorCyan, "FaceAlpha", 0.25, ...
                "EdgeColor", obj.ColorCyan, "LineWidth", 1.1 * ps, "Tag", "GT_orbitaldefense");

            % Crosshair (gold cross + red scatter circle matching fingertip)
            obj.CrossCircleH = scatter(ax, NaN, NaN, 6000, ...
                "MarkerEdgeColor", "r", "LineWidth", 0.8 * ps, ...
                "MarkerFaceColor", "none", "Tag", "GT_orbitaldefense");
            obj.CrossGlowH = line(ax, NaN, NaN, "Color", [obj.ColorGold, 0.3], ...
                "LineWidth", 1.6 * ps, "Tag", "GT_orbitaldefense");
            obj.CrossH = line(ax, NaN, NaN, "Color", obj.ColorGold, ...
                "LineWidth", 0.5 * ps, "Tag", "GT_orbitaldefense");

            % Lives text (centered, hidden, flash on change)
            obj.LivesTextH = text(ax, cx, cy + diff(dy) * 0.2, "", ...
                "Color", obj.ColorRed, "FontSize", 26 * ps, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_orbitaldefense");
            obj.LivesFlashTic = [];

            % Wave text (centered, hidden, flash on change)
            obj.WaveTextH = text(ax, cx, cy - diff(dy) * 0.2, "", ...
                "Color", obj.ColorGold, "FontSize", 21 * ps, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_orbitaldefense");
            obj.WaveFlashTic = [];

            % =============================================================
            % PRE-ALLOCATE INTERCEPTOR POOL (10 lines, Visible="off")
            % =============================================================
            obj.IntPoolLine = cell(1, 10);
            obj.IntActive = false(1, 10);
            for k = 1:10
                obj.IntPoolLine{k} = line(ax, NaN, NaN, ...
                    "Color", obj.ColorCyan, "LineWidth", 0.5 * ps, ...
                    "Visible", "off", "Tag", "GT_orbitaldefense");
            end

            % =============================================================
            % PRE-ALLOCATE EXPLOSION POOL (12 core + 12 glow patches)
            % =============================================================
            cosT = cos(obj.ThetaCircle24);
            sinT = sin(obj.ThetaCircle24);
            obj.ExpPoolPatch = cell(1, 12);
            obj.ExpPoolGlow = cell(1, 12);
            obj.ExpActive = false(1, 12);
            for k = 1:12
                obj.ExpPoolGlow{k} = patch(ax, "XData", cosT * 1.3, ...
                    "YData", sinT * 1.3, ...
                    "FaceColor", obj.ColorOrange, "FaceAlpha", 0.1, ...
                    "EdgeColor", "none", "Visible", "off", ...
                    "Tag", "GT_orbitaldefense");
                obj.ExpPoolPatch{k} = patch(ax, "XData", cosT, ...
                    "YData", sinT, ...
                    "FaceColor", obj.ColorOrange, "FaceAlpha", 0.4, ...
                    "EdgeColor", obj.ColorGold, "LineWidth", 0.5 * ps, ...
                    "Visible", "off", "Tag", "GT_orbitaldefense");
            end

            % =============================================================
            % PRE-ALLOCATE ASTEROID POOL (50 patches)
            % =============================================================
            obj.AstPoolPatch = cell(1, 50);
            obj.AstShapeX = cell(1, 50);
            obj.AstShapeY = cell(1, 50);
            obj.AstActive = false(1, 50);
            for k = 1:50
                obj.AstPoolPatch{k} = patch(ax, "XData", NaN, "YData", NaN, ...
                    "FaceColor", obj.ColorSilver, "FaceAlpha", 0.20, ...
                    "EdgeColor", obj.ColorSilver, "LineWidth", 0.8 * ps, ...
                    "Visible", "off", "Tag", "GT_orbitaldefense");
                obj.AstShapeX{k} = [];
                obj.AstShapeY{k} = [];
            end

            % Spawn first wave
            obj.spawnWave(obj.Wave);
            obj.showWave(obj.Wave);
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame orbital defense logic.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            ds = obj.DtScale;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % --- Update crosshair ---
            if ~any(isnan(pos))
                crSize = round(5 * obj.Sc);
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
                obj.FireCD = obj.FireCD + ds;
                if obj.FireCD >= 36 && distToBase > obj.BaseRadius
                    obj.FireCD = 0;
                    launchX = obj.BasePos(1);
                    launchY = obj.BasePos(2);
                    intSpeed = max(1.667, diff(dy) * 0.0208);

                    % Find inactive interceptor slot
                    slot = find(~obj.IntActive, 1);
                    if ~isempty(slot)
                        obj.IntX(slot) = launchX;
                        obj.IntY(slot) = launchY;
                        obj.IntTx(slot) = pos(1);
                        obj.IntTy(slot) = pos(2);
                        obj.IntSpeed(slot) = intSpeed;
                        obj.IntActive(slot) = true;
                        lnH = obj.IntPoolLine{slot};
                        lnH.XData = [launchX, launchX];
                        lnH.YData = [launchY, launchY];
                        lnH.Visible = "on";
                    end
                end
            end

            % --- Move interceptors ---
            activeInts = find(obj.IntActive);
            for ki = numel(activeInts):-1:1
                k = activeInts(ki);
                dirVec = [obj.IntTx(k) - obj.IntX(k), obj.IntTy(k) - obj.IntY(k)];
                dirDist = norm(dirVec);
                if dirDist < obj.IntSpeed(k) * ds
                    % Reached target -- explode
                    obj.spawnExplosion(obj.IntTx(k), obj.IntTy(k));
                    obj.IntActive(k) = false;
                    obj.IntPoolLine{k}.Visible = "off";
                    continue;
                end
                dirVec = dirVec / dirDist;
                obj.IntX(k) = obj.IntX(k) + dirVec(1) * obj.IntSpeed(k) * ds;
                obj.IntY(k) = obj.IntY(k) + dirVec(2) * obj.IntSpeed(k) * ds;
                % Off-screen -- silently remove (no explosion)
                if obj.IntX(k) < dx(1) - 20 || obj.IntX(k) > dx(2) + 20 || ...
                        obj.IntY(k) < dy(1) - 20 || obj.IntY(k) > dy(2) + 20
                    obj.IntActive(k) = false;
                    obj.IntPoolLine{k}.Visible = "off";
                    continue;
                end
                lnH = obj.IntPoolLine{k};
                lnH.XData = [lnH.XData(1), obj.IntX(k)];
                lnH.YData = [lnH.YData(1), obj.IntY(k)];
            end

            % --- Move asteroids + wrap around edges ---
            activeAsts = find(obj.AstActive);
            for ki = 1:numel(activeAsts)
                a = activeAsts(ki);
                obj.AstX(a) = obj.AstX(a) + obj.AstVx(a) * ds;
                obj.AstY(a) = obj.AstY(a) + obj.AstVy(a) * ds;
                obj.AstAngle(a) = obj.AstAngle(a) + obj.AstSpin(a) * ds;

                margin = obj.AstRadius(a);
                if obj.AstX(a) < dx(1) - margin; obj.AstX(a) = dx(2) + margin; end
                if obj.AstX(a) > dx(2) + margin; obj.AstX(a) = dx(1) - margin; end
                if obj.AstY(a) < dy(1) - margin; obj.AstY(a) = dy(2) + margin; end
                if obj.AstY(a) > dy(2) + margin; obj.AstY(a) = dy(1) - margin; end

                pH = obj.AstPoolPatch{a};
                pH.XData = obj.AstX(a) + obj.AstShapeX{a};
                pH.YData = obj.AstY(a) + obj.AstShapeY{a};
            end

            % --- Update explosions + check explosion-asteroid intersection ---
            cosT = cos(obj.ThetaCircle24);
            sinT = sin(obj.ThetaCircle24);
            tierRadii = obj.TierRadii;
            activeExps = find(obj.ExpActive);
            for ki = numel(activeExps):-1:1
                k = activeExps(ki);
                if obj.ExpPhase(k) == 1
                    obj.ExpRadius(k) = obj.ExpRadius(k) + obj.ExpMaxRadius(k) * 0.0417 * ds;
                    if obj.ExpRadius(k) >= obj.ExpMaxRadius(k)
                        obj.ExpPhase(k) = 2;
                    end
                else
                    obj.ExpRadius(k) = obj.ExpRadius(k) - obj.ExpMaxRadius(k) * 0.0333 * ds;
                end

                % Chain explosion: destroy asteroids caught in blast
                astIdxs = find(obj.AstActive);
                for mi = numel(astIdxs):-1:1
                    m = astIdxs(mi);
                    if norm([obj.AstX(m) - obj.ExpX(k), obj.AstY(m) - obj.ExpY(k)]) < ...
                            obj.ExpRadius(k) + obj.AstRadius(m)
                        pts = round(300 / obj.AstRadius(m) * 10);
                        obj.addScore(pts);
                        obj.incrementCombo();

                        % Split into next tier (15->10->5->destroy)
                        nextTier = obj.AstTier(m) + 1;
                        if nextTier <= numel(tierRadii)
                            for s = 1:2
                                sAngle = rand * 2 * pi;
                                sSpeed = norm([obj.AstVx(m), obj.AstVy(m)]) * (1.2 + rand * 0.5);
                                svx = sSpeed * cos(sAngle);
                                svy = sSpeed * sin(sAngle);
                                obj.createAsteroid(obj.AstX(m), obj.AstY(m), svx, svy, ...
                                    tierRadii(nextTier), nextTier);
                            end
                        end
                        % Chain explosion at asteroid position
                        obj.spawnExplosion(obj.AstX(m), obj.AstY(m));
                        % Deactivate destroyed asteroid
                        obj.AstActive(m) = false;
                        obj.AstPoolPatch{m}.Visible = "off";
                    end
                end

                % Update explosion graphics
                r = obj.ExpRadius(k);
                ex = obj.ExpX(k);
                ey = obj.ExpY(k);
                obj.ExpPoolPatch{k}.XData = ex + r * cosT;
                obj.ExpPoolPatch{k}.YData = ey + r * sinT;
                obj.ExpPoolGlow{k}.XData = ex + r * 1.3 * cosT;
                obj.ExpPoolGlow{k}.YData = ey + r * 1.3 * sinT;

                if obj.ExpRadius(k) <= 0
                    obj.ExpActive(k) = false;
                    obj.ExpPoolPatch{k}.Visible = "off";
                    obj.ExpPoolGlow{k}.Visible = "off";
                end
            end

            % --- Asteroid-base collision ---
            astIdxs = find(obj.AstActive);
            for mi = numel(astIdxs):-1:1
                a = astIdxs(mi);
                if norm([obj.AstX(a) - obj.BasePos(1), obj.AstY(a) - obj.BasePos(2)]) < ...
                        obj.AstRadius(a) + obj.BaseRadius
                    obj.Lives = obj.Lives - 1;
                    obj.resetCombo();

                    % Flash lives
                    if ~isempty(obj.LivesTextH) && isvalid(obj.LivesTextH)
                        obj.LivesTextH.String = sprintf("Lives: %d", obj.Lives);
                        obj.LivesTextH.Color = obj.ColorRed;
                        obj.LivesTextH.Visible = "on";
                        obj.LivesFlashTic = tic;
                    end
                    obj.spawnBounceEffect([obj.AstX(a), obj.AstY(a)], [0, -1], 0, 12);
                    obj.AstActive(a) = false;
                    obj.AstPoolPatch{a}.Visible = "off";
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
            if ~any(obj.AstActive)
                obj.Wave = obj.Wave + 1;
                obj.addScore(200 * obj.Wave);
                obj.spawnWave(obj.Wave);
                obj.showWave(obj.Wave);
            end

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

            % Delete interceptor pool
            if ~isempty(obj.IntPoolLine)
                for k = 1:numel(obj.IntPoolLine)
                    h = obj.IntPoolLine{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.IntPoolLine = {};
            obj.IntActive = false(1, 10);

            % Delete explosion pool
            if ~isempty(obj.ExpPoolPatch)
                for k = 1:numel(obj.ExpPoolPatch)
                    h = obj.ExpPoolPatch{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            if ~isempty(obj.ExpPoolGlow)
                for k = 1:numel(obj.ExpPoolGlow)
                    h = obj.ExpPoolGlow{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.ExpPoolPatch = {};
            obj.ExpPoolGlow = {};
            obj.ExpActive = false(1, 12);

            % Delete asteroid pool
            if ~isempty(obj.AstPoolPatch)
                for k = 1:numel(obj.AstPoolPatch)
                    h = obj.AstPoolPatch{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.AstPoolPatch = {};
            obj.AstActive = false(1, 50);

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
            r.Lines = {
                sprintf("Wave: %d  |  Lives: %d", obj.Wave, obj.Lives)
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

            % Deactivate all existing asteroids before spawning new wave
            activeAsts = find(obj.AstActive);
            for ki = 1:numel(activeAsts)
                a = activeAsts(ki);
                obj.AstActive(a) = false;
                obj.AstPoolPatch{a}.Visible = "off";
            end

            nLarge = 2 + wave;
            nMedium = 1 + floor(wave * 0.8);
            nSmall = floor(wave * 0.6);
            tierRadii = obj.TierRadii;
            tierSpeedMult = [1.0, 1.5, 2.2];
            counts = [nLarge, nMedium, nSmall];
            baseSpeed = max(0.125, min(areaW, areaH) * 0.00167) * (1 + wave * 0.08);

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
            %createAsteroid  Activate a pooled asteroid patch with random shape.
            slot = find(~obj.AstActive, 1);
            if isempty(slot); return; end  % pool exhausted

            nVerts = 8 + randi(4);
            vertAngles = sort(rand(1, nVerts) * 2 * pi);
            vertRadii = rockRadius * (0.7 + 0.3 * rand(1, nVerts));
            shpX = vertRadii .* cos(vertAngles);
            shpY = vertRadii .* sin(vertAngles);
            shpX(end+1) = shpX(1); %#ok<AGROW>
            shpY(end+1) = shpY(1); %#ok<AGROW>

            obj.AstShapeX{slot} = shpX;
            obj.AstShapeY{slot} = shpY;
            obj.AstX(slot) = sx;
            obj.AstY(slot) = sy;
            obj.AstVx(slot) = vx;
            obj.AstVy(slot) = vy;
            obj.AstRadius(slot) = rockRadius;
            obj.AstTier(slot) = tier;
            obj.AstAngle(slot) = 0;
            obj.AstSpin(slot) = (rand - 0.5) * 0.0208;
            obj.AstActive(slot) = true;

            tierColors = {obj.ColorSilver, obj.ColorGold, obj.ColorRed};
            rockColor = tierColors{min(tier, 3)};

            pH = obj.AstPoolPatch{slot};
            pH.XData = sx + shpX;
            pH.YData = sy + shpY;
            pH.FaceColor = rockColor;
            pH.EdgeColor = rockColor;
            pH.Visible = "on";
        end

        function spawnExplosion(obj, ex, ey)
            %spawnExplosion  Activate a pooled explosion at the given position.
            slot = find(~obj.ExpActive, 1);
            if isempty(slot); return; end  % pool exhausted

            maxR = max(8, min(diff(obj.DisplayRange.X), diff(obj.DisplayRange.Y)) * 0.06);
            cosT = cos(obj.ThetaCircle24);
            sinT = sin(obj.ThetaCircle24);

            obj.ExpX(slot) = ex;
            obj.ExpY(slot) = ey;
            obj.ExpRadius(slot) = 1;
            obj.ExpMaxRadius(slot) = maxR;
            obj.ExpPhase(slot) = 1;
            obj.ExpActive(slot) = true;

            obj.ExpPoolPatch{slot}.XData = ex + cosT;
            obj.ExpPoolPatch{slot}.YData = ey + sinT;
            obj.ExpPoolPatch{slot}.Visible = "on";

            obj.ExpPoolGlow{slot}.XData = ex + 1.3 * cosT;
            obj.ExpPoolGlow{slot}.YData = ey + 1.3 * sinT;
            obj.ExpPoolGlow{slot}.Visible = "on";
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
