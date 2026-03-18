classdef Planets < GameBase
    %Planets  Full N-body solar system simulator.
    %   8 planets + Moon + Sun (10 bodies). Velocity Verlet integrator with
    %   cached acceleration. G = 4*pi^2 AU^3/(Msun*yr^2). Sqrt radial display
    %   mapping. Finger force uses display-space distances for magnitude but
    %   sim-space direction.
    %
    %   Controls:
    %     M          — cycle finger mode: neutral / attract / repel
    %     Up/Down    — adjust finger mass (0..100 Msun)
    %     Left/Right — adjust time scale (0.1x..3x)
    %     0          — reset orbits
    %
    %   Standalone: games.Planets().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Planets"
    end

    % =================================================================
    % SIMULATION STATE
    % =================================================================
    properties (Access = private)
        % Body state (9 bodies: 8 planets + Moon)
        PosX            (:,1) double
        PosY            (:,1) double
        VelX            (:,1) double
        VelY            (:,1) double
        BodyMass        (:,1) double
        BodyColors      (:,3) double
        BodyRadii       (:,1) double
        SemiMajor       (:,1) double    % planets only (8)
        Ecc             (:,1) double    % planets only (8)

        % Constants & parameters
        GravConst       (1,1) double = 4 * pi^2
        SunMass         (1,1) double = 1
        TimeScale       (1,1) double = 1.0
        BaseDt          (1,1) double = 0.0005
        SubSteps        (1,1) double = 10

        % Sun dynamics
        SunPosX         (1,1) double = 0
        SunPosY         (1,1) double = 0
        SunVelX         (1,1) double = 0
        SunVelY         (1,1) double = 0

        % Display mapping
        SqrtScale       (1,1) double = 1
        CenterX         (1,1) double = 0
        CenterY         (1,1) double = 0
        MaxOrbitR       (1,1) double = 32.0

        % Finger interaction
        FingerMass      (1,1) double = 1
        FingerMode      (1,1) string = "neutral"

        % Trails (circular buffer)
        TrailX          (:,:) double
        TrailY          (:,:) double
        TrailIdx        (1,1) double = 0
        TrailLen        (1,1) double = 2000
        SunTrailX       (:,1) double
        SunTrailY       (:,1) double

        % Counters
        SimTime         (1,1) double = 0
        FrameCount      (1,1) double = 0
        BoundCount      (1,1) double = 9
        EscapeR         (1,1) double = 100
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BgImageH
        StarsH
        OrbitGuideH

        SunCoreH
        SunGlowH
        SunOuterH
        SunTrailH
        SunTrailGlowH

        PlanetCoreH
        PlanetGlowH

        TrailLines      = {}
        TrailGlowLines  = {}

        FingerCoreH
        FingerGlowH
        FingerOuterH

        NameLabels      = {}
        LabelOffsets    (:,1) double

        ModeTextH
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize solar system state.
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

            obj.initSolarSystem();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame N-body integration and rendering.
            if isempty(obj.PosX) || isempty(obj.TrailX); return; end

            obj.FrameCount = obj.FrameCount + 1;
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            gravG = obj.GravConst;
            sunM = obj.SunMass;
            dt = obj.BaseDt;
            ds = obj.DtScale;
            nSub = max(1, round(obj.SubSteps * obj.TimeScale * ds));
            nP = 9;
            nBodies = nP;
            softening2 = 0.0001^2;
            bMass = obj.BodyMass;

            posX = obj.PosX(1:nP);
            posY = obj.PosY(1:nP);
            velX = obj.VelX(1:nP);
            velY = obj.VelY(1:nP);

            sunPX = obj.SunPosX;  sunPY = obj.SunPosY;
            sunVX = obj.SunVelX;  sunVY = obj.SunVelY;

            % --- Finger force setup ---
            fingerDispX = NaN;  fingerDispY = NaN;
            fMag = obj.FingerMass;
            if obj.FingerMode == "repel"
                fMag = -fMag;
            elseif obj.FingerMode == "neutral"
                fMag = 0;
            end
            fAbsX = NaN;  fAbsY = NaN;
            fingerActive = ~any(isnan(pos)) && fMag ~= 0;
            fDispSoft2 = 15^2;
            fScale = 2e4;
            if fingerActive
                fingerDispX = pos(1);
                fingerDispY = pos(2);
                [fAbsX, fAbsY] = obj.simDisplayToSim(fingerDispX, fingerDispY);
            end

            % --- Velocity Verlet (9 bodies + dynamic Sun) ---
            accX = [];  accY = [];
            sunAccX = 0;  sunAccY = 0;
            for iSub = 1:nSub
                if isempty(accX)
                    [accX, accY, sunAccX, sunAccY] = obj.computeAccelerations( ...
                        posX, posY, sunPX, sunPY, gravG, sunM, bMass, ...
                        nP, softening2, fingerActive, fingerDispX, ...
                        fingerDispY, fAbsX, fAbsY, fScale, fMag, fDispSoft2);
                end
                % First half-kick
                halfDt = dt / 2;
                velX = velX + accX * halfDt;
                velY = velY + accY * halfDt;
                sunVX = sunVX + sunAccX * halfDt;
                sunVY = sunVY + sunAccY * halfDt;
                % Drift
                posX = posX + velX * dt;
                posY = posY + velY * dt;
                sunPX = sunPX + sunVX * dt;
                sunPY = sunPY + sunVY * dt;
                % Accelerations at new positions
                [accX, accY, sunAccX, sunAccY] = obj.computeAccelerations( ...
                    posX, posY, sunPX, sunPY, gravG, sunM, bMass, ...
                    nP, softening2, fingerActive, fingerDispX, ...
                    fingerDispY, fAbsX, fAbsY, fScale, fMag, fDispSoft2);
                % Second half-kick
                velX = velX + accX * halfDt;
                velY = velY + accY * halfDt;
                sunVX = sunVX + sunAccX * halfDt;
                sunVY = sunVY + sunAccY * halfDt;
            end

            obj.PosX = posX;
            obj.PosY = posY;
            obj.VelX = velX;
            obj.VelY = velY;
            obj.SunPosX = sunPX;  obj.SunPosY = sunPY;
            obj.SunVelX = sunVX;  obj.SunVelY = sunVY;
            obj.SimTime = obj.SimTime + dt * nSub;

            tLen = obj.TrailLen;
            obj.TrailIdx = mod(obj.TrailIdx, tLen) + 1;
            tidx = obj.TrailIdx;
            trailOrd = mod((tidx:tidx + tLen - 2), tLen) + 1;
            planetDispX = zeros(nBodies, 1);
            planetDispY = zeros(nBodies, 1);
            for k = 1:nBodies
                [planetDispX(k), planetDispY(k)] = obj.simToDisplay( ...
                    posX(k), posY(k));
            end

            % Moon display: amplified visual offset from Earth
            moonOffX = posX(9) - posX(3);
            moonOffY = posY(9) - posY(3);
            moonOffR = sqrt(moonOffX^2 + moonOffY^2);
            nominalMoonR = 0.00257;
            if moonOffR > 1e-10
                moonAngle = atan2(moonOffY, moonOffX);
                moonVisR = max(1, moonOffR / (2 * nominalMoonR));
                planetDispX(9) = planetDispX(3) + moonVisR * cos(moonAngle);
                planetDispY(9) = planetDispY(3) + moonVisR * sin(moonAngle);
            end
            for k = 1:8
                obj.TrailX(tidx, k) = planetDispX(k);
                obj.TrailY(tidx, k) = planetDispY(k);
            end

            if ~isempty(obj.PlanetCoreH) && isvalid(obj.PlanetCoreH)
                obj.PlanetCoreH.XData = planetDispX;
                obj.PlanetCoreH.YData = planetDispY;
            end
            if ~isempty(obj.PlanetGlowH) && isvalid(obj.PlanetGlowH)
                obj.PlanetGlowH.XData = planetDispX;
                obj.PlanetGlowH.YData = planetDispY;
            end

            % --- Sun display ---
            [sunDX, sunDY] = obj.simToDisplay(sunPX, sunPY);
            maxTrailDist = 20;
            obj.SunTrailX(tidx) = sunDX;
            obj.SunTrailY(tidx) = sunDY;
            if ~isempty(obj.SunTrailH) && isvalid(obj.SunTrailH)
                obj.renderTrailPatch(obj.SunTrailH, ...
                    obj.SunTrailX(trailOrd), obj.SunTrailY(trailOrd), ...
                    [1 0.85 0.2], maxTrailDist);
            end
            if ~isempty(obj.SunCoreH) && isvalid(obj.SunCoreH)
                obj.SunCoreH.XData = sunDX;
                obj.SunCoreH.YData = sunDY;
            end
            if ~isempty(obj.SunGlowH) && isvalid(obj.SunGlowH)
                obj.SunGlowH.XData = sunDX;
                obj.SunGlowH.YData = sunDY;
            end
            if ~isempty(obj.SunOuterH) && isvalid(obj.SunOuterH)
                obj.SunOuterH.XData = sunDX;
                obj.SunOuterH.YData = sunDY;
                breath = 0.06 + 0.02 * sin(obj.FrameCount * 0.05);
                obj.SunOuterH.MarkerFaceAlpha = breath;
            end

            % --- Finger mass visual ---
            obj.updateFingerVisual(fingerDispX, fingerDispY);

            % --- Planet trails + escape detection ---
            boundCount = 0;
            allEscaped = true;
            for k = 1:nBodies
                if numel(obj.TrailLines) >= k ...
                        && ~isempty(obj.TrailLines{k}) ...
                        && isvalid(obj.TrailLines{k})
                    obj.renderTrailPatch(obj.TrailLines{k}, ...
                        obj.TrailX(trailOrd, k), obj.TrailY(trailOrd, k), ...
                        obj.BodyColors(k, :), maxTrailDist);
                end
                if k <= 8 && numel(obj.NameLabels) >= k ...
                        && ~isempty(obj.NameLabels{k}) ...
                        && isvalid(obj.NameLabels{k})
                    lOff = 0;
                    if numel(obj.LabelOffsets) >= k
                        lOff = obj.LabelOffsets(k);
                    end
                    obj.NameLabels{k}.Position = ...
                        [planetDispX(k), planetDispY(k) - lOff, 0];
                end
                if k <= 8
                    relX = obj.PosX(k) - obj.SunPosX;
                    relY = obj.PosY(k) - obj.SunPosY;
                    rSun = sqrt(relX^2 + relY^2);
                    relVx = obj.VelX(k) - obj.SunVelX;
                    relVy = obj.VelY(k) - obj.SunVelY;
                    v2 = relVx^2 + relVy^2;
                    muGrav = obj.GravConst * (obj.SunMass + bMass(k));
                    orbitalE = 0.5 * v2 - muGrav / max(rSun, 1e-4);
                    if orbitalE < 0
                        boundCount = boundCount + 1;
                    end
                    escaped = (rSun > obj.EscapeR && orbitalE >= 0) ...
                        || planetDispX(k) < dx(1) - 50 ...
                        || planetDispX(k) > dx(2) + 50 ...
                        || planetDispY(k) < dy(1) - 50 ...
                        || planetDispY(k) > dy(2) + 50;
                    if ~escaped
                        allEscaped = false;
                    end
                end
            end
            if allEscaped
                obj.resetOrbits();
            end
            obj.BoundCount = boundCount;
            obj.Score = obj.Score + boundCount;

            if mod(obj.FrameCount, 15) == 0
                obj.updateHud();
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all planetary orbit graphics.
            handles = {obj.BgImageH, obj.SunCoreH, obj.SunGlowH, ...
                obj.SunOuterH, obj.SunTrailH, obj.SunTrailGlowH, ...
                obj.PlanetCoreH, obj.PlanetGlowH, obj.OrbitGuideH, ...
                obj.StarsH, obj.ModeTextH, obj.FingerCoreH, ...
                obj.FingerGlowH, obj.FingerOuterH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            cellArrays = {obj.TrailLines, obj.TrailGlowLines, ...
                obj.NameLabels};
            for j = 1:numel(cellArrays)
                arr = cellArrays{j};
                for k = 1:numel(arr)
                    h = arr{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end

            obj.BgImageH = []; obj.SunCoreH = [];
            obj.SunGlowH = []; obj.SunOuterH = [];
            obj.SunTrailH = []; obj.SunTrailGlowH = [];
            obj.SunTrailX = []; obj.SunTrailY = [];
            obj.PlanetCoreH = []; obj.PlanetGlowH = [];
            obj.OrbitGuideH = []; obj.StarsH = [];
            obj.ModeTextH = []; obj.FingerCoreH = [];
            obj.FingerGlowH = []; obj.FingerOuterH = [];
            obj.TrailLines = {};
            obj.TrailGlowLines = {}; obj.NameLabels = {};
            obj.TrailX = []; obj.TrailY = [];
            obj.PosX = zeros(9, 1);
            obj.FrameCount = 0;
            obj.SimTime = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_planets");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle mode-specific keys.
            handled = true;
            switch key
                case "m"
                    modes = ["neutral", "attract", "repel"];
                    idx = find(modes == obj.FingerMode, 1);
                    obj.FingerMode = modes(mod(idx, 3) + 1);
                    obj.updateHud();
                case {"uparrow", "downarrow"}
                    massLevels = [0, 0.5, 1, 2, 5, 10, 20, 50, 100];
                    [~, idx] = min(abs(massLevels - obj.FingerMass));
                    if key == "uparrow"
                        idx = min(idx + 1, numel(massLevels));
                    else
                        idx = max(idx - 1, 1);
                    end
                    obj.FingerMass = massLevels(idx);
                    obj.updateHud();
                case {"leftarrow", "rightarrow"}
                    obj.changeTimeScale(key);
                case "0"
                    obj.resetOrbits();
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return planets-specific results.
            r.Title = "SOLAR SYSTEM";
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            r.Lines = {
                sprintf("Sim Time: %.2f yr  |  Bound: %d/8  |  Score: %d  |  Wall: %.0fs", ...
                    obj.SimTime, obj.BoundCount, obj.Score, elapsed)
            };
        end

    end

    % =================================================================
    % PRIVATE — INITIALIZATION
    % =================================================================
    methods (Access = private)
        function initSolarSystem(obj)
            %initSolarSystem  Set up 9 bodies with real orbital data.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);

            % Real orbital elements (semi-major axis AU, eccentricity)
            sma = [0.387; 0.723; 1.000; 1.524; 5.203; 9.537; 19.19; 30.07];
            ecc = [0.206; 0.007; 0.017; 0.093; 0.049; 0.057; 0.047; 0.011];

            colors = [0.7, 0.7, 0.7;     % Mercury
                      0.9, 0.8, 0.3;      % Venus
                      0.2, 0.5, 1.0;      % Earth
                      0.9, 0.3, 0.2;      % Mars
                      0.8, 0.6, 0.3;      % Jupiter
                      0.9, 0.8, 0.5;      % Saturn
                      0.5, 0.8, 0.9;      % Uranus
                      0.3, 0.4, 0.9;      % Neptune
                      0.75, 0.75, 0.72];   % Moon

            radii = [3; 4; 4.5; 3.5; 9; 8; 6; 6; 1.2];
            nBodies = 9;

            obj.SemiMajor = sma;
            obj.Ecc = ecc;
            obj.BodyColors = colors;
            obj.BodyRadii = radii;
            obj.BodyMass = [0.166e-6; 2.448e-6; 3.003e-6; 0.323e-6; ...
                            954.8e-6; 285.9e-6; 43.66e-6; 51.51e-6; ...
                            3.694e-8];
            obj.GravConst = 4 * pi^2;
            obj.SunMass = 1;

            gravG = obj.GravConst;
            sunM = obj.SunMass;

            % Random orbital phases (Keplerian initial conditions)
            mBody = obj.BodyMass(1:8);
            theta = rand(8, 1) * 2 * pi;
            pSLR = sma .* (1 - ecc.^2);
            rOrb = pSLR ./ (1 + ecc .* cos(theta));
            pltPX = rOrb .* cos(theta);
            pltPY = rOrb .* sin(theta);

            mu = gravG * (sunM + mBody);
            sqrtMuP = sqrt(mu ./ pSLR);
            vrPlt = sqrtMuP .* ecc .* sin(theta);
            vtPlt = sqrtMuP .* (1 + ecc .* cos(theta));
            pltVX = vrPlt .* cos(theta) - vtPlt .* sin(theta);
            pltVY = vrPlt .* sin(theta) + vtPlt .* cos(theta);

            % Moon: real N-body particle
            moonAngle = rand() * 2 * pi;
            aMoon = 0.00257;
            mEarth = 3.003e-6;  mMoon = 3.694e-8;
            moonPX = pltPX(3) + aMoon * cos(moonAngle);
            moonPY = pltPY(3) + aMoon * sin(moonAngle);
            vMoon = sqrt(gravG * (mEarth + mMoon) / aMoon);
            moonVX = pltVX(3) - vMoon * sin(moonAngle);
            moonVY = pltVY(3) + vMoon * cos(moonAngle);
            obj.PosX = [pltPX; moonPX];
            obj.PosY = [pltPY; moonPY];
            obj.VelX = [pltVX; moonVX];
            obj.VelY = [pltVY; moonVY];

            % Sun barycentric correction: total momentum = 0
            allVX = [pltVX; moonVX];
            allVY = [pltVY; moonVY];
            obj.SunPosX = 0; obj.SunPosY = 0;
            obj.SunVelX = -sum(obj.BodyMass .* allVX) / sunM;
            obj.SunVelY = -sum(obj.BodyMass .* allVY) / sunM;

            obj.TimeScale = 1.0;
            obj.BaseDt = 0.0005;
            obj.SubSteps = 10;
            obj.SimTime = 0;
            obj.FrameCount = 0;
            obj.FingerMass = 1;
            obj.FingerMode = "neutral";

            obj.MaxOrbitR = 32.0;
            displayRadius = min(areaW, areaH) * 0.45;
            obj.SqrtScale = displayRadius;
            obj.CenterX = mean(dx);
            obj.CenterY = mean(dy);

            tLen = obj.TrailLen;
            obj.TrailX = NaN(tLen, nBodies);
            obj.TrailY = NaN(tLen, nBodies);
            obj.TrailIdx = 0;

            % Dark background
            obj.BgImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.95, ...
                "AlphaDataMapping", "none", "Tag", "GT_planets");
            uistack(obj.BgImageH, "bottom");
            uistack(obj.BgImageH, "up");

            % Star background
            nStars = 120;
            sx = dx(1) + rand(nStars, 1) * areaW;
            sy = dy(1) + rand(nStars, 1) * areaH;
            starSizes = 1 + rand(nStars, 1) * 4;
            obj.StarsH = scatter(ax, sx, sy, starSizes, ...
                ones(nStars, 1) * [0.8, 0.85, 1.0], "filled", ...
                "MarkerFaceAlpha", 0.5, "Tag", "GT_planets");

            % Trail patches per body
            obj.TrailGlowLines = {};
            obj.TrailLines = cell(nBodies, 1);
            for k = 1:nBodies
                obj.TrailLines{k} = patch(ax, ...
                    "XData", NaN, "YData", NaN, ...
                    "CData", zeros(1, 1, 3), "FaceColor", "none", ...
                    "EdgeColor", "interp", "EdgeAlpha", "interp", ...
                    "FaceVertexAlphaData", 0, "AlphaDataMapping", "none", ...
                    "LineWidth", 2.0, "Tag", "GT_planets");
            end

            % Orbit guide ellipses (planets only)
            thGuide = linspace(0, 2 * pi, 100)';
            guideX = []; guideY = [];
            for k = 1:8
                rx = sma(k);
                ry = sma(k) * sqrt(1 - ecc(k)^2);
                cxE = -sma(k) * ecc(k);
                ex = cxE + rx * cos(thGuide);
                ey = ry * sin(thGuide);
                [gx, gy] = obj.simToDisplay(ex, ey);
                if ~isempty(guideX)
                    guideX = [guideX; NaN]; %#ok<AGROW>
                    guideY = [guideY; NaN]; %#ok<AGROW>
                end
                guideX = [guideX; gx]; %#ok<AGROW>
                guideY = [guideY; gy]; %#ok<AGROW>
            end
            obj.OrbitGuideH = line(ax, guideX, guideY, ...
                "Color", [1, 1, 1, 0.08], "LineWidth", 0.5, ...
                "Tag", "GT_planets");

            % Sun trail patch (behind Sun scatter)
            obj.SunTrailGlowH = [];
            obj.SunTrailH = patch(ax, ...
                "XData", NaN, "YData", NaN, ...
                "CData", zeros(1, 1, 3), "FaceColor", "none", ...
                "EdgeColor", "interp", "EdgeAlpha", "interp", ...
                "FaceVertexAlphaData", 0, "AlphaDataMapping", "none", ...
                "LineWidth", 2.0, "Tag", "GT_planets");
            obj.SunTrailX = NaN(tLen, 1);
            obj.SunTrailY = NaN(tLen, 1);

            % Sun (3-layer)
            [sunDX, sunDY] = obj.simToDisplay(0, 0);
            obj.SunOuterH = scatter(ax, sunDX, sunDY, 1600, ...
                obj.ColorGold, "filled", "MarkerFaceAlpha", 0.06, ...
                "Tag", "GT_planets");
            obj.SunGlowH = scatter(ax, sunDX, sunDY, 600, ...
                obj.ColorGold, "filled", "MarkerFaceAlpha", 0.2, ...
                "Tag", "GT_planets");
            obj.SunCoreH = scatter(ax, sunDX, sunDY, 120, ...
                obj.ColorGold, "filled", "MarkerFaceAlpha", 1.0, ...
                "Tag", "GT_planets");

            % Bodies (8 planets + Moon)
            initDispX = zeros(nBodies, 1);
            initDispY = zeros(nBodies, 1);
            for k = 1:nBodies
                [initDispX(k), initDispY(k)] = obj.simToDisplay( ...
                    obj.PosX(k), obj.PosY(k));
            end
            % Amplify Moon visual offset
            moonOffX = obj.PosX(9) - obj.PosX(3);
            moonOffY = obj.PosY(9) - obj.PosY(3);
            moonOffR = sqrt(moonOffX^2 + moonOffY^2);
            if moonOffR > 1e-10
                moonVisR = 1;
                initDispX(9) = initDispX(3) + moonVisR * moonOffX / moonOffR;
                initDispY(9) = initDispY(3) + moonVisR * moonOffY / moonOffR;
            end
            glowSizes = (radii * 3).^2;
            obj.PlanetGlowH = scatter(ax, initDispX, initDispY, ...
                glowSizes, colors, "filled", "MarkerFaceAlpha", 0.2, ...
                "Tag", "GT_planets");
            coreSizes = radii.^2 * 3;
            obj.PlanetCoreH = scatter(ax, initDispX, initDispY, ...
                coreSizes, colors, "filled", "MarkerFaceAlpha", 1.0, ...
                "Tag", "GT_planets");

            % Finger mass visual (3-layer)
            obj.FingerOuterH = scatter(ax, NaN, NaN, 1600, ...
                obj.ColorGold, "filled", "MarkerFaceAlpha", 0.06, ...
                "Visible", "off", "Tag", "GT_planets");
            obj.FingerGlowH = scatter(ax, NaN, NaN, 600, ...
                obj.ColorGold, "filled", "MarkerFaceAlpha", 0.2, ...
                "Visible", "off", "Tag", "GT_planets");
            obj.FingerCoreH = scatter(ax, NaN, NaN, 120, ...
                obj.ColorGold, "filled", "MarkerFaceAlpha", 1.0, ...
                "Visible", "off", "Tag", "GT_planets");

            % Name labels
            pltNames = {"Me", "Ve", "Ea", "Ma", "Ju", "Sa", "Ur", "Ne"};
            obj.LabelOffsets = repmat(2, nBodies, 1);
            obj.NameLabels = cell(nBodies, 1);
            for k = 1:8
                obj.NameLabels{k} = text(ax, initDispX(k), ...
                    initDispY(k) - obj.LabelOffsets(k), pltNames{k}, ...
                    "Color", [colors(k, :), 0.7], "FontSize", 9, ...
                    "FontWeight", "bold", "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "bottom", "Tag", "GT_planets");
            end

            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, "", ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_planets");
            obj.updateHud();
        end
    end

    % =================================================================
    % PRIVATE — PHYSICS
    % =================================================================
    methods (Access = private)
        function [accX, accY, sunAX, sunAY] = computeAccelerations(obj, ...
                posX, posY, sunPX, sunPY, gravG, sunM, bMass, ...
                nP, softening2, fingerActive, fingerDispX, ...
                fingerDispY, fAbsX, fAbsY, fScale, fMag, fDispSoft2)
            %computeAccelerations  N-body gravitational + finger forces.
            accX = zeros(nP, 1);
            accY = zeros(nP, 1);
            sunAX = 0;  sunAY = 0;
            % Sun <-> body
            for k = 1:nP
                ddx = sunPX - posX(k);
                ddy = sunPY - posY(k);
                r2 = ddx^2 + ddy^2 + softening2;
                r3inv = 1 / (r2 * sqrt(r2));
                accX(k) = gravG * sunM * ddx * r3inv;
                accY(k) = gravG * sunM * ddy * r3inv;
                sunAX = sunAX - gravG * bMass(k) * ddx * r3inv;
                sunAY = sunAY - gravG * bMass(k) * ddy * r3inv;
            end
            % Body <-> body (Newton's 3rd)
            for k = 1:nP - 1
                for j = k + 1:nP
                    ddx = posX(j) - posX(k);
                    ddy = posY(j) - posY(k);
                    r2 = ddx^2 + ddy^2 + softening2;
                    fR3 = gravG / (r2 * sqrt(r2));
                    accX(k) = accX(k) + bMass(j) * fR3 * ddx;
                    accY(k) = accY(k) + bMass(j) * fR3 * ddy;
                    accX(j) = accX(j) - bMass(k) * fR3 * ddx;
                    accY(j) = accY(j) - bMass(k) * fR3 * ddy;
                end
            end
            % Finger force: display-distance magnitude, sim-space direction
            if fingerActive
                for k = 1:nP
                    [bDispX, bDispY] = obj.simToDisplay(posX(k), posY(k));
                    dDispX = fingerDispX - bDispX;
                    dDispY = fingerDispY - bDispY;
                    dDisp2 = dDispX^2 + dDispY^2 + fDispSoft2;
                    sDx = fAbsX - posX(k);
                    sDy = fAbsY - posY(k);
                    sR = sqrt(sDx^2 + sDy^2);
                    if sR > 1e-12
                        aF = fScale * fMag / dDisp2;
                        accX(k) = accX(k) + aF * sDx / sR;
                        accY(k) = accY(k) + aF * sDy / sR;
                    end
                end
                % Sun
                [sDispX, sDispY] = obj.simToDisplay(sunPX, sunPY);
                dDispX = fingerDispX - sDispX;
                dDispY = fingerDispY - sDispY;
                dDisp2 = dDispX^2 + dDispY^2 + fDispSoft2;
                sDx = fAbsX - sunPX;
                sDy = fAbsY - sunPY;
                sR = sqrt(sDx^2 + sDy^2);
                if sR > 1e-12
                    aF = fScale * fMag / dDisp2;
                    sunAX = sunAX + aF * sDx / sR;
                    sunAY = sunAY + aF * sDy / sR;
                end
            end
        end

        function resetOrbits(obj)
            %resetOrbits  Reset all bodies to fresh random Keplerian orbits.
            sma = obj.SemiMajor;
            ecc = obj.Ecc;
            gravG = obj.GravConst;
            sunM = obj.SunMass;

            mBody = obj.BodyMass(1:8);
            theta = rand(8, 1) * 2 * pi;
            pSLR = sma .* (1 - ecc.^2);
            rOrb = pSLR ./ (1 + ecc .* cos(theta));
            pltPX = rOrb .* cos(theta);
            pltPY = rOrb .* sin(theta);

            mu = gravG * (sunM + mBody);
            sqrtMuP = sqrt(mu ./ pSLR);
            vrPlt = sqrtMuP .* ecc .* sin(theta);
            vtPlt = sqrtMuP .* (1 + ecc .* cos(theta));
            pltVX = vrPlt .* cos(theta) - vtPlt .* sin(theta);
            pltVY = vrPlt .* sin(theta) + vtPlt .* cos(theta);

            moonAngle = rand() * 2 * pi;
            aMoon = 0.00257;
            mEarth = 3.003e-6;  mMoon = 3.694e-8;
            moonPX = pltPX(3) + aMoon * cos(moonAngle);
            moonPY = pltPY(3) + aMoon * sin(moonAngle);
            vMoon = sqrt(gravG * (mEarth + mMoon) / aMoon);
            moonVX = pltVX(3) - vMoon * sin(moonAngle);
            moonVY = pltVY(3) + vMoon * cos(moonAngle);
            obj.PosX = [pltPX; moonPX];
            obj.PosY = [pltPY; moonPY];
            obj.VelX = [pltVX; moonVX];
            obj.VelY = [pltVY; moonVY];

            allVX = [pltVX; moonVX];
            allVY = [pltVY; moonVY];
            obj.SunPosX = 0; obj.SunPosY = 0;
            obj.SunVelX = -sum(obj.BodyMass .* allVX) / sunM;
            obj.SunVelY = -sum(obj.BodyMass .* allVY) / sunM;

            obj.SimTime = 0;
            obj.FrameCount = 0;

            nBodies = numel(obj.PosX);
            tLen = obj.TrailLen;
            obj.TrailX = NaN(tLen, nBodies);
            obj.TrailY = NaN(tLen, nBodies);
            obj.SunTrailX = NaN(tLen, 1);
            obj.SunTrailY = NaN(tLen, 1);
            obj.TrailIdx = 0;
            obj.updateHud();
        end

        function changeTimeScale(obj, key)
            %changeTimeScale  Step through discrete time scale levels.
            levels = [0.1, 0.2, 0.3, 0.5, 1, 1.5, 2, 3];
            [~, idx] = min(abs(levels - obj.TimeScale));
            if key == "rightarrow"
                idx = min(idx + 1, numel(levels));
            else
                idx = max(idx - 1, 1);
            end
            obj.TimeScale = levels(idx);
            obj.updateHud();
        end
    end

    % =================================================================
    % PRIVATE — DISPLAY MAPPING
    % =================================================================
    methods (Access = private)
        function [dispX, dispY] = simToDisplay(obj, simX, simY)
            %simToDisplay  Map simulation AU to display pixels (sqrt radial).
            simR = sqrt(simX.^2 + simY.^2);
            displayR = sqrt(simR / obj.MaxOrbitR) .* obj.SqrtScale;
            theta = atan2(simY, simX);
            dispX = obj.CenterX + displayR .* cos(theta);
            dispY = obj.CenterY + displayR .* sin(theta);
        end

        function [simX, simY] = simDisplayToSim(obj, dispX, dispY)
            %simDisplayToSim  Inverse mapping: display to simulation AU.
            relX = dispX - obj.CenterX;
            relY = dispY - obj.CenterY;
            displayR = sqrt(relX.^2 + relY.^2);
            simR = obj.MaxOrbitR * (displayR / obj.SqrtScale).^2;
            theta = atan2(relY, relX);
            simX = simR .* cos(theta);
            simY = simR .* sin(theta);
        end

        function computeViewParams(obj)
            %computeViewParams  Recompute sqrt mapping parameters.
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            displayRadius = min(dx(2) - dx(1), dy(2) - dy(1)) * 0.45;
            obj.MaxOrbitR = 32.0;
            obj.SqrtScale = displayRadius;
            obj.CenterX = mean(dx);
            obj.CenterY = mean(dy);
        end
    end

    % =================================================================
    % PRIVATE — VISUALIZATION
    % =================================================================
    methods (Access = private)
        function updateHud(obj)
            %updateHud  Update HUD text with stellar classification.
            if isempty(obj.ModeTextH) || ~isvalid(obj.ModeTextH); return; end
            lr = char(8592) + string(char(8594));
            ud = char(8593) + string(char(8595));
            modeStr = upper(obj.FingerMode);
            massVal = obj.FingerMass;
            sunSymbol = char(9737);
            if massVal == 0 || obj.FingerMode == "neutral"
                starStr = sprintf("%g", massVal) + "M" + sunSymbol;
            elseif obj.FingerMode == "attract"
                sMasses = [0.5, 1, 2, 5, 10, 20, 50, 100];
                sLabels = ["Red Dwarf", "Yellow Dwarf", "White Star", ...
                    "Blue-White", "Blue Star", "Blue Giant", ...
                    "Blue Supergiant", "Blue Hypergiant"];
                sNames = ["Proxima Centauri", "Sun", "Sirius", ...
                    "Achernar", "Beta Centauri", "Zeta Ophiuchi", ...
                    char(952) + "1 Ori C", "Eta Carinae"];
                [~, sIdx] = min(abs(log2(sMasses) - log2(max(0.5, massVal))));
                starStr = sprintf("%g", massVal) + "M" + sunSymbol + ...
                    " " + sLabels(sIdx) + " (" + sNames(sIdx) + ")";
            else
                starStr = sprintf("%g", massVal) + "M" + sunSymbol + ...
                    " Exotic Matter";
            end
            obj.ModeTextH.String = ...
                "Speed " + sprintf("%.1fx", obj.TimeScale) + ...
                " [" + lr + "]" + ...
                "  |  " + modeStr + " [M]  " + ...
                starStr + " [" + ud + "]" + ...
                "  |  Bound " + obj.BoundCount + "/8" + ...
                "  |  " + sprintf("%.1f yr", obj.SimTime) + ...
                "  |  0=Reset";
        end

        function updateFingerVisual(obj, fpx, fpy)
            %updateFingerVisual  Render finger mass star visual.
            hasVis = ~isempty(obj.FingerCoreH) && isvalid(obj.FingerCoreH);
            if ~hasVis; return; end

            if isnan(fpx) || obj.FingerMass == 0
                obj.FingerCoreH.Visible = "off";
                obj.FingerGlowH.Visible = "off";
                obj.FingerOuterH.Visible = "off";
                return;
            end

            massFrac = min(1, max(0, ...
                (log2(obj.FingerMass) - log2(0.5)) / (log2(100) - log2(0.5))));

            % Size scales with mass
            sSzM = [0.5, 1, 2, 5, 10, 20, 50, 100];
            sCoreS  = [50,  120, 160, 220, 280, 340, 400, 460];
            sGlowS  = [200, 600, 720, 840, 960, 1080, 1200, 1320];
            sOuterS = [400, 1600, 1850, 2100, 2350, 2600, 2900, 3200];
            logSzM = log2(sSzM);
            logSzC = log2(max(0.5, min(100, obj.FingerMass)));
            coreSize = interp1(logSzM, sCoreS, logSzC, "linear", "extrap");
            glowSize = interp1(logSzM, sGlowS, logSzC, "linear", "extrap");
            outerSize = interp1(logSzM, sOuterS, logSzC, "linear", "extrap");

            breathPhase = sin(obj.FrameCount * 0.08);

            if obj.FingerMode == "attract"
                % Main-sequence star colors by mass
                sMasses = [0.5, 1, 2, 5, 10, 20, 50, 100];
                sRGB = [1.00, 0.40, 0.20; ...
                        1.00, 0.85, 0.20; ...
                        0.80, 0.85, 1.00; ...
                        0.60, 0.70, 1.00; ...
                        0.50, 0.60, 1.00; ...
                        0.45, 0.50, 1.00; ...
                        0.40, 0.45, 1.00; ...
                        0.35, 0.40, 1.00];
                logM = log2(sMasses);
                logCur = log2(max(0.5, min(100, obj.FingerMass)));
                coreColor = max(0, min(1, interp1(logM, sRGB, logCur, "linear", "extrap")));
                glowColor = coreColor * 0.82;
                outerColor = coreColor * 0.65;
                coreAlpha = 0.9;
                glowAlpha = 0.25 + 0.1 * massFrac;
                outerAlpha = 0.06 + 0.06 * massFrac + 0.02 * breathPhase;
            else
                % Exotic matter: bright violet/purple aura
                coreColor = [0.65 + 0.2 * massFrac, ...
                             0.35 - 0.05 * massFrac, ...
                             0.9 + 0.1 * massFrac];
                glowColor = [0.55 + 0.15 * massFrac, ...
                             0.25, ...
                             0.85 + 0.1 * massFrac];
                outerColor = [0.5 + 0.2 * massFrac, ...
                              0.2, ...
                              0.8 + 0.15 * massFrac];
                coreAlpha = 0.9;
                glowAlpha = 0.25 + 0.15 * massFrac;
                outerAlpha = 0.06 + 0.08 * massFrac - 0.02 * breathPhase;
            end

            obj.FingerCoreH.XData = fpx;
            obj.FingerCoreH.YData = fpy;
            obj.FingerCoreH.SizeData = coreSize;
            obj.FingerCoreH.CData = coreColor;
            obj.FingerCoreH.MarkerFaceAlpha = coreAlpha;
            obj.FingerCoreH.Visible = "on";

            obj.FingerGlowH.XData = fpx;
            obj.FingerGlowH.YData = fpy;
            obj.FingerGlowH.SizeData = glowSize;
            obj.FingerGlowH.CData = glowColor;
            obj.FingerGlowH.MarkerFaceAlpha = glowAlpha;
            obj.FingerGlowH.Visible = "on";

            obj.FingerOuterH.XData = fpx;
            obj.FingerOuterH.YData = fpy;
            obj.FingerOuterH.SizeData = outerSize;
            obj.FingerOuterH.CData = outerColor;
            obj.FingerOuterH.MarkerFaceAlpha = outerAlpha;
            obj.FingerOuterH.Visible = "on";
        end

        function renderTrailPatch(~, patchH, tx, ty, col, maxDist)
            %renderTrailPatch  Render a fading alpha trail on a patch object.
            validMask = ~isnan(tx);
            nTValid = sum(validMask);
            if nTValid < 3
                set(patchH, "XData", NaN, "YData", NaN, ...
                    "CData", NaN(1, 1, 3), "FaceVertexAlphaData", 0);
                return;
            end
            txv = tx(validMask);
            tyv = ty(validMask);
            % Trim to fixed arc length from newest end
            cumD = [0; cumsum(sqrt(diff(txv).^2 + diff(tyv).^2))];
            totalD = cumD(end);
            if totalD > maxDist
                cutoff = totalD - maxDist;
                startIdx = find(cumD >= cutoff, 1, "first");
                txv = txv(startIdx:end);
                tyv = tyv(startIdx:end);
            end
            nShow = numel(txv);
            if nShow < 3
                set(patchH, "XData", NaN, "YData", NaN, ...
                    "CData", NaN(1, 1, 3), "FaceVertexAlphaData", 0);
                return;
            end
            % Makima interpolation to smooth polygonal orbits
            tt = (1:nShow)';
            nFine = max(nShow * 3, 30);
            ttFine = linspace(1, nShow, nFine)';
            txv = interp1(tt, txv, ttFine, "makima");
            tyv = interp1(tt, tyv, ttFine, "makima");
            nShow = nFine;
            cdata = repmat(reshape(col, 1, 1, 3), nShow, 1, 1);
            alphaVals = linspace(0, 0.4, nShow)';
            txv(end + 1) = NaN; tyv(end + 1) = NaN; %#ok<AGROW>
            cdata(end + 1, 1, :) = NaN; %#ok<AGROW>
            alphaVals(end + 1) = NaN; %#ok<AGROW>
            set(patchH, "XData", txv, "YData", tyv, ...
                "CData", cdata, "FaceVertexAlphaData", alphaVals);
        end
    end
end
