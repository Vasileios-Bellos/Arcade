classdef NewtonsCradle < GameBase
    %NewtonsCradle  Newton's cradle with 5 pendulums and chrome ball physics.
    %   RK4 integration (8 substeps, dt=0.004), elastic collision via velocity
    %   swap + multi-pass hard position constraint. Chrome balls with specular
    %   highlight, V-shaped strings, bronze frame. Per-ball alpha-fade trails
    %   with EdgeAlpha='interp' + FaceVertexAlphaData, direct Nx1x3 RGB CData.
    %   Finger push interaction: velocity transfer on contact projected onto
    %   pendulum tangent.
    %
    %   Controls:
    %     M     — cycle sub-mode: classic / double / triple / mirror / chaos / still
    %     1-6   — jump to sub-mode directly
    %     N     — toggle frame/strings/base visibility
    %     0     — reset to current sub-mode initial conditions
    %
    %   Standalone: games.NewtonsCradle().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Newton's Cradle"
    end

    % =================================================================
    % PHYSICS STATE
    % =================================================================
    properties (Access = private)
        BallCount       (1,1) double = 5
        Theta           (:,1) double            % angular position per ball
        Omega           (:,1) double            % angular velocity per ball
        ArmLength       (1,1) double = 1.0      % string length (display units)
        BallRadius      (1,1) double = 1.0      % ball radius (display units)
        Gravity         (1,1) double = 9.81     % scaled gravity
        TimeStep        (1,1) double = 0.004    % RK4 dt
        SubSteps        (1,1) double = 8        % RK4 sub-steps per frame
        Damping         (1,1) double = 0.9985   % per-substep air resistance
        SubMode         (1,1) string = "classic"
        BarX            (1,1) double = 0        % frame bar center X
        BarY            (1,1) double = 0        % frame bar Y
        PivotX          (:,1) double            % per-ball pivot X positions
        StringOffset    (1,1) double = 1.0      % V-string lateral offset
        ShowFrame       (1,1) logical = true    % frame/strings visibility
        PrevFingerX     (1,1) double = NaN
        PrevFingerY     (1,1) double = NaN
    end

    % =================================================================
    % TRAIL BUFFERS
    % =================================================================
    properties (Access = private)
        TrailX          (:,:) double            % (TrailLen x N)
        TrailY          (:,:) double
        TrailWriteIdx   (1,1) double = 0
        TrailCount      (1,1) double = 0
        TrailLen        (1,1) double = 15
        Hues            (:,1) double            % per-ball HSV hue
    end

    % =================================================================
    % STATISTICS
    % =================================================================
    properties (Access = private)
        FrameCount      (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BgImageH                                % semi-transparent black background
        TrailPatchH                             % gobjects(N,1) — per-ball trail patches
        FrameGlowH                              % line — frame glow (wide, dim)
        FrameLineH                              % line — frame solid
        BaseLineH                               % line — base platform
        StringLeftH                             % line — left V-strings
        StringRightH                            % line — right V-strings
        BallPatchH                              % gobjects(N,1) — chrome ball patches
        HighlightPatchH                         % gobjects(N,1) — specular highlights
        HudTextH                                % text — mode/controls HUD
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create Newton's cradle with chrome balls and frame.
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
            areaH = diff(dy);

            numBalls = obj.BallCount;
            obj.FrameCount = 0;
            obj.PrevFingerX = NaN;
            obj.PrevFingerY = NaN;

            % --- Geometry (all in display pixel coordinates) ---
            ballR = areaH * 0.05;
            stringLen = areaH * 0.42;
            obj.ArmLength = stringLen;
            % Scale gravity so pendulum period ~ 1.5 sim-seconds regardless of L
            obj.Gravity = stringLen * (2 * pi / 1.5)^2;
            obj.TimeStep = 0.004;
            obj.SubSteps = 8;
            obj.Damping = 0.9985;
            obj.StringOffset = ballR * 0.6;
            obj.BallRadius = ballR;

            % Pivot spacing = exactly 2*ballR (patch circles in data units)
            spacing = 2 * ballR;
            totalWidth = (numBalls - 1) * spacing;

            % Bar: centered, upper portion of display
            obj.BarX = mean(dx);
            obj.BarY = dy(1) + areaH * 0.18;
            barYPos = obj.BarY;

            % Pivot X for each ball
            obj.PivotX = obj.BarX + linspace(-totalWidth / 2, totalWidth / 2, numBalls)';

            % Initial state
            obj.Theta = zeros(numBalls, 1);
            obj.Omega = zeros(numBalls, 1);
            obj.SubMode = "classic";
            obj.applySubMode();

            % --- Black background ---
            obj.BgImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_newtonscradle");
            uistack(obj.BgImageH, "bottom");
            uistack(obj.BgImageH, "up");

            % --- Per-ball trails (direct RGB, no colormap dependency) ---
            obj.TrailLen = 15;
            obj.TrailX = NaN(obj.TrailLen, numBalls);
            obj.TrailY = NaN(obj.TrailLen, numBalls);
            obj.TrailWriteIdx = 0;
            obj.TrailCount = 0;
            obj.Hues = linspace(0, 1 - 1 / numBalls, numBalls)';

            trailArr = gobjects(numBalls, 1);
            for k = 1:numBalls
                trailArr(k) = patch(ax, "XData", NaN, "YData", NaN, ...
                    "CData", zeros(1, 1, 3), ...
                    "EdgeColor", "interp", "EdgeAlpha", "interp", ...
                    "FaceVertexAlphaData", 0, "AlphaDataMapping", "none", ...
                    "Marker", "none", "LineStyle", "-", "LineWidth", 2.5, ...
                    "Tag", "GT_newtonscradle");
            end
            obj.TrailPatchH = trailArr;

            % --- Frame geometry ---
            barHalfW = totalWidth / 2 + spacing * 1.8;
            baseYPos = barYPos + stringLen + ballR * 3;
            baseHalfW = barHalfW + areaH * 0.04;
            frameCol = [0.55 0.48 0.38];  % warm bronze

            % Frame path: top bar + left leg + right leg (NaN-separated)
            fX = [obj.BarX - barHalfW, obj.BarX + barHalfW, NaN, ...
                  obj.BarX - barHalfW, obj.BarX - baseHalfW, NaN, ...
                  obj.BarX + barHalfW, obj.BarX + baseHalfW];
            fY = [barYPos, barYPos, NaN, ...
                  barYPos, baseYPos, NaN, ...
                  barYPos, baseYPos];

            % Frame glow (wide, dim)
            obj.FrameGlowH = line(ax, fX, fY, ...
                "Color", [frameCol, 0.10], "LineWidth", 10, ...
                "Tag", "GT_newtonscradle");

            % Frame solid
            obj.FrameLineH = line(ax, fX, fY, ...
                "Color", [frameCol, 0.65], "LineWidth", 3.5, ...
                "Tag", "GT_newtonscradle");

            % Base platform (thicker)
            obj.BaseLineH = line(ax, ...
                [obj.BarX - baseHalfW, obj.BarX + baseHalfW], ...
                [baseYPos, baseYPos], ...
                "Color", [frameCol * 0.8, 0.8], "LineWidth", 5, ...
                "Tag", "GT_newtonscradle");

            % --- Strings (V-shape per ball, NaN-separated) ---
            sOff = obj.StringOffset;
            strLX = NaN(3 * numBalls, 1); strLY = NaN(3 * numBalls, 1);
            strRX = NaN(3 * numBalls, 1); strRY = NaN(3 * numBalls, 1);
            for k = 1:numBalls
                bx = obj.PivotX(k) + stringLen * sin(obj.Theta(k));
                by = barYPos + stringLen * cos(obj.Theta(k));
                seg = 3 * (k - 1);
                strLX(seg + 1) = obj.PivotX(k) - sOff;
                strLY(seg + 1) = barYPos;
                strLX(seg + 2) = bx;
                strLY(seg + 2) = by;
                strRX(seg + 1) = obj.PivotX(k) + sOff;
                strRY(seg + 1) = barYPos;
                strRX(seg + 2) = bx;
                strRY(seg + 2) = by;
            end
            strCol = [0.6 0.6 0.55, 0.45];
            obj.StringLeftH = line(ax, strLX, strLY, "Color", strCol, ...
                "LineWidth", 1, "Tag", "GT_newtonscradle");
            obj.StringRightH = line(ax, strRX, strRY, "Color", strCol, ...
                "LineWidth", 1, "Tag", "GT_newtonscradle");

            % --- Ball positions ---
            bobX = obj.PivotX + stringLen * sin(obj.Theta);
            bobY = barYPos + stringLen * cos(obj.Theta);

            % Circle template (data units)
            nCirc = 64;
            circAng = linspace(0, 2 * pi, nCirc + 1)';
            circUX = cos(circAng);
            circUY = sin(circAng);

            % Chrome color
            chromeCol = [0.82 0.84 0.88];

            % Ball cores — filled patch circles
            ballArr = gobjects(numBalls, 1);
            for k = 1:numBalls
                ballArr(k) = patch(ax, ...
                    bobX(k) + ballR * circUX, bobY(k) + ballR * circUY, ...
                    chromeCol, "EdgeColor", "none", ...
                    "FaceAlpha", 1.0, "Tag", "GT_newtonscradle");
            end
            obj.BallPatchH = ballArr;

            % Highlight dots (upper-left offset for chrome specular)
            hlR = ballR * 0.3;
            hlOff = ballR * 0.25;
            highArr = gobjects(numBalls, 1);
            for k = 1:numBalls
                highArr(k) = patch(ax, ...
                    bobX(k) - hlOff + hlR * circUX, ...
                    bobY(k) - hlOff + hlR * circUY, ...
                    [1 1 1], "EdgeColor", "none", ...
                    "FaceAlpha", 0.5, "Tag", "GT_newtonscradle");
            end
            obj.HighlightPatchH = highArr;

            % --- HUD ---
            obj.HudTextH = text(ax, dx(1) + 5, dy(2) - 5, "", ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_newtonscradle");
            obj.refreshHud();

            % Z-order: trails above frame/strings, below balls
            for k = 1:numBalls
                uistack(obj.TrailPatchH(k), "top");
            end
            for k = 1:numBalls
                uistack(obj.BallPatchH(k), "top");
                uistack(obj.HighlightPatchH(k), "top");
            end
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame physics + rendering for Newton's cradle.
            numBalls = obj.BallCount;
            if isempty(obj.Theta) || numel(obj.Theta) ~= numBalls; return; end

            obj.FrameCount = obj.FrameCount + 1;
            dt = obj.TimeStep;
            grav = obj.Gravity;
            armLen = obj.ArmLength;
            ballR = obj.BallRadius;
            barYPos = obj.BarY;
            theta = obj.Theta;
            omega = obj.Omega;
            dampFactor = obj.Damping;
            pivX = obj.PivotX;

            % --- Finger push interaction ---
            hasFinger = ~isempty(pos) && all(~isnan(pos));
            if hasFinger
                bobX = pivX + armLen * sin(theta);
                bobY = barYPos + armLen * cos(theta);

                % Finger velocity from previous frame
                fvx = 0; fvy = 0;
                if ~isnan(obj.PrevFingerX)
                    fvx = pos(1) - obj.PrevFingerX;
                    fvy = pos(2) - obj.PrevFingerY;
                end
                obj.PrevFingerX = pos(1);
                obj.PrevFingerY = pos(2);

                % Normalize finger velocity so force feels the same at any
                % display size.  The multiplier 4.0 was tuned at ~240 data-
                % unit width (GestureTrainer).  Scale velocity by 240/areaW
                % so larger displays don't produce proportionally stronger
                % pushes.
                areaW = diff(obj.DisplayRange.X);
                refWidth = 240;  % reference display width the gain was tuned for
                velScale = refWidth / areaW;
                fvx = fvx * velScale;
                fvy = fvy * velScale;

                fingerSpeed = sqrt(fvx^2 + fvy^2);
                if fingerSpeed > 0.3
                    for k = 1:numBalls
                        ddx = pos(1) - bobX(k);
                        ddy = pos(2) - bobY(k);
                        distToBall = sqrt(ddx^2 + ddy^2);
                        if distToBall < ballR * 1.5
                            % Project finger velocity onto pendulum tangent
                            vTan = fvx * cos(theta(k)) - fvy * sin(theta(k));
                            omega(k) = omega(k) + (vTan / armLen) * 4.0;
                        end
                    end
                    % Clamp omega to prevent tunneling
                    omega = max(-10, min(10, omega));
                end
            else
                obj.PrevFingerX = NaN;
                obj.PrevFingerY = NaN;
            end

            % --- Physics: RK4 integration + collision resolution ---
            gL = grav / armLen;
            ds = obj.DtScale;
            nSubScaled = max(1, round(obj.SubSteps * ds));
            nSubScaled = min(nSubScaled, obj.SubSteps * 4);  % safety cap
            for ss = 1:nSubScaled
                % RK4 for each ball (simple pendulum: theta'' = -(g/L)*sin(theta))
                for k = 1:numBalls
                    th0 = theta(k); om0 = omega(k);
                    k1t = om0;           k1o = -gL * sin(th0);
                    th1 = th0 + 0.5*dt*k1t; om1 = om0 + 0.5*dt*k1o;
                    k2t = om1;           k2o = -gL * sin(th1);
                    th2 = th0 + 0.5*dt*k2t; om2 = om0 + 0.5*dt*k2o;
                    k3t = om2;           k3o = -gL * sin(th2);
                    th3 = th0 + dt*k3t;  om3 = om0 + dt*k3o;
                    k4t = om3;           k4o = -gL * sin(th3);

                    theta(k) = th0 + dt / 6 * (k1t + 2*k2t + 2*k3t + k4t);
                    omega(k) = om0 + dt / 6 * (k1o + 2*k2o + 2*k3o + k4o);
                end

                % Air resistance damping
                omega = omega * dampFactor;

                % Collision resolution — multiple passes for correct wave propagation
                % Constraint: theta(i) <= theta(i+1) for adjacent balls
                % When violated AND approaching: swap velocities (equal mass elastic)
                for pass = 1:numBalls * 2
                    anySwap = false;
                    for i = 1:numBalls - 1
                        if theta(i) > theta(i + 1) && omega(i) > omega(i + 1)
                            tmpOm = omega(i);
                            omega(i) = omega(i + 1);
                            omega(i + 1) = tmpOm;
                            % Separate overlapping balls
                            overlap = theta(i) - theta(i + 1);
                            theta(i) = theta(i) - overlap * 0.5;
                            theta(i + 1) = theta(i + 1) + overlap * 0.5;
                            anySwap = true;
                        end
                    end
                    if ~anySwap; break; end
                end

                % Hard position constraint — multiple passes, no overlaps
                for cp = 1:numBalls
                    anyFix = false;
                    for i = 1:numBalls - 1
                        if theta(i) > theta(i + 1)
                            avg = (theta(i) + theta(i + 1)) * 0.5;
                            theta(i) = avg;
                            theta(i + 1) = avg;
                            anyFix = true;
                        end
                    end
                    if ~anyFix; break; end
                end
            end

            % --- Rest threshold: kill residual jitter ---
            if max(abs(omega)) < 0.002 && max(abs(theta)) < 0.001
                omega(:) = 0;
                theta(:) = 0;
            end

            obj.Theta = theta;
            obj.Omega = omega;

            % --- Compute ball positions ---
            bobX = pivX + armLen * sin(theta);
            bobY = barYPos + armLen * cos(theta);

            % --- Update trails (direct RGB, per-vertex alpha fade) ---
            obj.TrailWriteIdx = mod(obj.TrailWriteIdx, obj.TrailLen) + 1;
            obj.TrailX(obj.TrailWriteIdx, :) = bobX';
            obj.TrailY(obj.TrailWriteIdx, :) = bobY';
            obj.TrailCount = min(obj.TrailCount + 1, obj.TrailLen);

            tIdx = obj.TrailWriteIdx;
            tLen = obj.TrailLen;
            tCount = obj.TrailCount;

            % Ordered range: oldest to newest
            if tCount < tLen
                orderRange = (1:tIdx)';
            else
                orderRange = [tIdx + 1:tLen, 1:tIdx]';
            end

            for k = 1:numBalls
                if numel(obj.TrailPatchH) < k || ~isvalid(obj.TrailPatchH(k)); continue; end
                tx = obj.TrailX(orderRange, k);
                ty = obj.TrailY(orderRange, k);
                nPts = numel(tx);

                if nPts < 5
                    set(obj.TrailPatchH(k), "XData", NaN, ...
                        "YData", NaN, "CData", NaN(1, 1, 3), ...
                        "FaceVertexAlphaData", 0);
                    continue;
                end

                % Constant ball color, alpha fades from 0 (tail) to 1 (head)
                [rr, gg, bb] = GameBase.hsvToRgb(obj.Hues(k));
                ballCol = [rr, gg, bb];
                cdata = repmat(reshape(ballCol, 1, 1, 3), nPts, 1, 1);
                alphaVals = linspace(0, 1, nPts)';
                % NaN terminator to prevent patch closure
                tx(end + 1) = NaN; %#ok<AGROW>
                ty(end + 1) = NaN; %#ok<AGROW>
                cdata = cat(1, cdata, NaN(1, 1, 3));
                alphaVals(end + 1) = NaN; %#ok<AGROW>
                set(obj.TrailPatchH(k), "XData", tx, "YData", ty, ...
                    "CData", cdata, "FaceVertexAlphaData", alphaVals);
            end

            % --- Update V-strings ---
            sOff = obj.StringOffset;
            strLX = NaN(3 * numBalls, 1); strLY = NaN(3 * numBalls, 1);
            strRX = NaN(3 * numBalls, 1); strRY = NaN(3 * numBalls, 1);
            for k = 1:numBalls
                seg = 3 * (k - 1);
                strLX(seg + 1) = pivX(k) - sOff;
                strLY(seg + 1) = barYPos;
                strLX(seg + 2) = bobX(k);
                strLY(seg + 2) = bobY(k);
                strRX(seg + 1) = pivX(k) + sOff;
                strRY(seg + 1) = barYPos;
                strRX(seg + 2) = bobX(k);
                strRY(seg + 2) = bobY(k);
            end
            if ~isempty(obj.StringLeftH) && isvalid(obj.StringLeftH)
                obj.StringLeftH.XData = strLX;
                obj.StringLeftH.YData = strLY;
            end
            if ~isempty(obj.StringRightH) && isvalid(obj.StringRightH)
                obj.StringRightH.XData = strRX;
                obj.StringRightH.YData = strRY;
            end

            % --- Update balls (patch circles in data units) ---
            nCirc = 64;
            ang = linspace(0, 2 * pi, nCirc + 1)';
            cUX = ballR * cos(ang);
            cUY = ballR * sin(ang);
            hlR = ballR * 0.3;
            hUX = hlR * cos(ang);
            hUY = hlR * sin(ang);
            hlOff = ballR * 0.25;
            for k = 1:numBalls
                if numel(obj.BallPatchH) >= k && isvalid(obj.BallPatchH(k))
                    obj.BallPatchH(k).XData = bobX(k) + cUX;
                    obj.BallPatchH(k).YData = bobY(k) + cUY;
                end
                if numel(obj.HighlightPatchH) >= k && isvalid(obj.HighlightPatchH(k))
                    obj.HighlightPatchH(k).XData = bobX(k) - hlOff + hUX;
                    obj.HighlightPatchH(k).YData = bobY(k) - hlOff + hUY;
                end
            end

            % --- Energy scoring ---
            totalKE = 0.5 * armLen^2 * sum(omega.^2);
            if totalKE > 0.5
                obj.addScore(floor(totalKE * 0.1));
                if mod(obj.FrameCount, 30) == 0
                    obj.incrementCombo();
                end
            else
                if mod(obj.FrameCount, 60) == 0 && obj.Combo > 0
                    obj.Combo = max(0, obj.Combo - 1);
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all Newton's cradle graphics.
            % Single handles
            singles = {obj.StringLeftH, obj.StringRightH, ...
                       obj.FrameLineH, obj.FrameGlowH, obj.BaseLineH, ...
                       obj.BgImageH, obj.HudTextH};
            for k = 1:numel(singles)
                h = singles{k};
                if ~isempty(h) && all(isvalid(h)); delete(h); end
            end
            % Handle arrays (balls, highlights, trails)
            arrays = {obj.BallPatchH, obj.HighlightPatchH, obj.TrailPatchH};
            for a = 1:numel(arrays)
                arr = arrays{a};
                if ~isempty(arr)
                    for k = 1:numel(arr)
                        if isvalid(arr(k)); delete(arr(k)); end
                    end
                end
            end

            obj.BallPatchH = [];
            obj.HighlightPatchH = [];
            obj.TrailPatchH = [];
            obj.StringLeftH = [];
            obj.StringRightH = [];
            obj.FrameLineH = [];
            obj.FrameGlowH = [];
            obj.BaseLineH = [];
            obj.BgImageH = [];
            obj.HudTextH = [];
            obj.Theta = [];
            obj.Omega = [];
            obj.Hues = [];
            obj.TrailX = [];
            obj.TrailY = [];
            obj.TrailWriteIdx = 0;
            obj.TrailCount = 0;
            obj.FrameCount = 0;
            obj.PrevFingerX = NaN;
            obj.PrevFingerY = NaN;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_newtonscradle");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["classic", "double", "triple", "mirror", "chaos", "still"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.applySubMode();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle mode-specific key events.
            handled = true;
            switch key
                case "m"
                    % Cycle sub-mode
                    modes = ["classic", "double", "triple", "mirror", "chaos", "still"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();

                case "n"
                    % Toggle frame/strings/base visibility
                    obj.ShowFrame = ~obj.ShowFrame;
                    vis = "on";
                    if ~obj.ShowFrame; vis = "off"; end
                    if ~isempty(obj.FrameLineH) && isvalid(obj.FrameLineH)
                        obj.FrameLineH.Visible = vis;
                    end
                    if ~isempty(obj.FrameGlowH) && isvalid(obj.FrameGlowH)
                        obj.FrameGlowH.Visible = vis;
                    end
                    if ~isempty(obj.BaseLineH) && isvalid(obj.BaseLineH)
                        obj.BaseLineH.Visible = vis;
                    end
                    if ~isempty(obj.StringLeftH) && isvalid(obj.StringLeftH)
                        obj.StringLeftH.Visible = vis;
                    end
                    if ~isempty(obj.StringRightH) && isvalid(obj.StringRightH)
                        obj.StringRightH.Visible = vis;
                    end
                    obj.refreshHud();

                case "0"
                    % Reset to current sub-mode initial conditions
                    obj.applySubMode();

                case {"1", "2", "3", "4", "5", "6"}
                    % Jump to sub-mode directly
                    modes = ["classic", "double", "triple", "mirror", "chaos", "still"];
                    idx = double(char(key)) - 48;
                    obj.SubMode = modes(idx);
                    obj.applySubMode();

                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return Newton's cradle results.
            r.Title = "NEWTON'S CRADLE";
            r.Lines = {
                sprintf("N=%d  |  Mode: %s", obj.BallCount, obj.SubMode)
            };
        end

        function s = getHudText(~)
            %getHudText  Return mode-specific HUD string.
            s = "";
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function s = buildHudString(obj)
            %buildHudString  Return mode-specific HUD string.
            bLabel = "HIDE FRAME";
            if ~obj.ShowFrame; bLabel = "SHOW FRAME"; end
            s = upper(obj.SubMode) + ...
                " [1-6/M]  |  " + bLabel + " [N]  |  RESET [0]";
        end

        function applySubMode(obj)
            %applySubMode  Set initial conditions based on current sub-mode.
            numBalls = obj.BallCount;
            obj.Theta = zeros(numBalls, 1);
            obj.Omega = zeros(numBalls, 1);
            switch obj.SubMode
                case "still"
                    % All balls at rest — push with finger
                case "classic"
                    % Pull 1 ball from the left
                    obj.Theta(1) = -1.0;
                case "double"
                    % Pull 2 balls from the left
                    obj.Theta(1) = -1.0;
                    obj.Theta(2) = -1.0;
                case "triple"
                    % Pull 3 balls from the left
                    nPull = min(3, numBalls);
                    obj.Theta(1:nPull) = -1.0;
                case "mirror"
                    % 1 ball from each side
                    obj.Theta(1) = -1.0;
                    obj.Theta(numBalls) = 1.0;
                case "chaos"
                    % Asymmetric — left/right at different heights
                    mid = ceil(numBalls / 2);
                    obj.Theta(1:mid-1) = -1.4 - (0:mid-2)' * 0.08;
                    obj.Theta(2) = -0.55;
                    obj.Theta(mid) = 0;
                    obj.Theta(mid+1:numBalls) = 0.9 + (0:numBalls-mid-1)' * 0.1;
            end
            obj.PrevFingerX = NaN;
            obj.PrevFingerY = NaN;
            % Clear trails on reset
            if ~isempty(obj.TrailX)
                obj.TrailX(:) = NaN;
                obj.TrailY(:) = NaN;
                obj.TrailWriteIdx = 0;
                obj.TrailCount = 0;
            end
            obj.refreshHud();
        end

        function refreshHud(obj)
            %refreshHud  Update HUD text display.
            if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                obj.HudTextH.String = obj.buildHudString();
            end
        end
    end
end
