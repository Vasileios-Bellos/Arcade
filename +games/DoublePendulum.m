classdef DoublePendulum < GameBase
    %DoublePendulum  Lagrangian double pendulum chaos visualization.
    %   N double pendulums with RK4 integration (dt=0.002, 10 substeps/frame),
    %   per-pendulum rainbow trails (100-frame circular buffer), and finger
    %   interaction as generalized forces Q1/Q2 via 1/r^2 gravity.
    %
    %   Controls:
    %     M     — cycle sub-mode: chaos / energy / cascade / freefall
    %     N     — cycle finger mode: neutral / attract / repel
    %     B     — show/hide pendulum rods, pivot, and bob1
    %     Up/Dn — change pendulum count: 5 / 10 / 15 / 20
    %     0     — reset to current sub-mode initial conditions
    %
    %   Standalone: games.DoublePendulum().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Double Pendulum"
    end

    % =================================================================
    % PHYSICS STATE
    % =================================================================
    properties (Access = private)
        State           (4,:) double            % [theta1; omega1; theta2; omega2] x N
        PendulumCount   (1,1) double = 10       % number of pendulums
        ArmLength1      (1,1) double = 1.0      % L1 (normalized)
        ArmLength2      (1,1) double = 1.0      % L2 (normalized)
        Mass1           (1,1) double = 1.0      % bob1 mass
        Mass2           (1,1) double = 1.0      % bob2 mass
        Gravity         (1,1) double = 9.81     % gravitational acceleration
        TimeStep        (1,1) double = 0.002    % RK4 dt
        SubSteps        (1,1) double = 10       % RK4 sub-steps per frame
        SubMode         (1,1) string = "chaos"  % chaos | energy | cascade | freefall
        FingerMode      (1,1) string = "neutral" % neutral | attract | repel
        ShowRods        (1,1) logical = true     % visibility of rods/pivot/bob1
    end

    % =================================================================
    % DISPLAY GEOMETRY
    % =================================================================
    properties (Access = private)
        Scale           (1,1) double = 1        % pixels per unit arm length
        CenterX         (1,1) double = 0        % pivot X in display coords
        CenterY         (1,1) double = 0        % pivot Y in display coords
        Hues            (:,1) double             % per-pendulum hue [0,1]
    end

    % =================================================================
    % TRAIL BUFFERS
    % =================================================================
    properties (Access = private)
        TrailX          (:,:) double             % (TrailLen x N) circular buffer
        TrailY          (:,:) double
        TrailWriteIdx   (1,1) double = 0         % write index into trail buffer
        TrailLen        (1,1) double = 100        % trail buffer capacity
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
        BgImageH                                  % image — semi-transparent black background
        TrailGlowH                                % gobjects(N,1) — glow lines per pendulum
        TrailLineH                                % gobjects(N,1) — core trail lines
        RodLineH                                  % line — NaN-separated rods
        Bob1GlowH                                 % scatter — bob1 glow
        Bob1DotH                                  % scatter — bob1 marker
        Bob2GlowH                                 % scatter — bob2 glow
        Bob2DotH                                  % scatter — bob2 marker
        PivotGlowH                                % scatter — pivot glow
        PivotDotH                                 % scatter — pivot marker
        HudTextH                                  % text — mode/controls HUD
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize physics state.
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

            obj.Scale = areaH * 0.25;  % L1+L2=2 -> total arm = half screen height
            obj.CenterX = mean(dx);
            obj.CenterY = mean(dy);    % pivot at screen center

            nPend = obj.PendulumCount;
            obj.ArmLength1 = 1.0;
            obj.ArmLength2 = 1.0;
            obj.Mass1 = 1.0;
            obj.Mass2 = 1.0;
            obj.Gravity = 9.81;
            obj.TimeStep = 0.002;
            obj.SubSteps = 10;
            obj.SubMode = "chaos";
            obj.TrailLen = 100;

            obj.State = zeros(4, nPend);
            obj.applySubMode();

            obj.TrailX = NaN(obj.TrailLen, nPend);
            obj.TrailY = NaN(obj.TrailLen, nPend);
            obj.TrailWriteIdx = 0;

            obj.Hues = linspace(0, 1 - 1 / nPend, nPend)';
            obj.FrameCount = 0;

            % Semi-transparent black background
            obj.BgImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_doublependulum");
            uistack(obj.BgImageH, "bottom");
            uistack(obj.BgImageH, "up");

            % Trail lines (one per pendulum) — build locally then assign once
            trailGlowArr = gobjects(nPend, 1);
            trailArr = gobjects(nPend, 1);
            for k = 1:nPend
                [r, g, b] = GameBase.hsvToRgb(obj.Hues(k));
                trailGlowArr(k) = line(ax, NaN, NaN, ...
                    "Color", [r, g, b, 0.12], "LineWidth", 4, ...
                    "Tag", "GT_doublependulum");
                trailArr(k) = line(ax, NaN, NaN, ...
                    "Color", [r, g, b, 0.6], "LineWidth", 1.5, ...
                    "Tag", "GT_doublependulum");
            end
            obj.TrailGlowH = trailGlowArr;
            obj.TrailLineH = trailArr;

            % Rod lines (NaN-separated: pivot->bob1->bob2)
            obj.RodLineH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorWhite, 0.5], "LineWidth", 1.5, ...
                "Tag", "GT_doublependulum");

            % Bob1 glow (large, semi-transparent behind bob1)
            obj.Bob1GlowH = scatter(ax, NaN(nPend, 1), NaN(nPend, 1), ...
                200 * ones(nPend, 1), repmat(obj.ColorWhite, nPend, 1), "filled", ...
                "MarkerFaceAlpha", 0.12, "Tag", "GT_doublependulum");

            % Bob1 scatter (mid-joint, white)
            obj.Bob1DotH = scatter(ax, NaN(nPend, 1), NaN(nPend, 1), ...
                50 * ones(nPend, 1), repmat(obj.ColorWhite, nPend, 1), "filled", ...
                "MarkerFaceAlpha", 0.7, "Tag", "GT_doublependulum");

            % Bob2 scatter (tip, rainbow hues)
            bob2Col = zeros(nPend, 3);
            for k = 1:nPend
                [r, g, b] = GameBase.hsvToRgb(obj.Hues(k));
                bob2Col(k, :) = [r, g, b];
            end

            % Bob2 glow (large, semi-transparent behind bob2)
            obj.Bob2GlowH = scatter(ax, NaN(nPend, 1), NaN(nPend, 1), ...
                350 * ones(nPend, 1), bob2Col, "filled", ...
                "MarkerFaceAlpha", 0.15, "Tag", "GT_doublependulum");

            obj.Bob2DotH = scatter(ax, NaN(nPend, 1), NaN(nPend, 1), ...
                80 * ones(nPend, 1), bob2Col, "filled", ...
                "MarkerFaceAlpha", 0.9, "Tag", "GT_doublependulum");

            % Pivot glow (behind pivot marker)
            obj.PivotGlowH = scatter(ax, obj.CenterX, obj.CenterY, ...
                400, obj.ColorGold, "filled", "MarkerFaceAlpha", 0.15, ...
                "Tag", "GT_doublependulum");

            % Pivot marker
            obj.PivotDotH = scatter(ax, obj.CenterX, obj.CenterY, ...
                120, obj.ColorGold, "filled", "MarkerFaceAlpha", 0.8, ...
                "Tag", "GT_doublependulum");

            obj.FingerMode = "neutral";
            obj.HudTextH = text(ax, dx(1) + 5, dy(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_doublependulum");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame RK4 integration and rendering.
            nPend = size(obj.State, 2);
            if nPend == 0; return; end

            obj.FrameCount = obj.FrameCount + 1;
            L1 = obj.ArmLength1;
            L2 = obj.ArmLength2;
            m1 = obj.Mass1;
            m2 = obj.Mass2;
            grav = obj.Gravity;
            dt = obj.TimeStep;
            nSub = obj.SubSteps;
            sc = obj.Scale;
            cx = obj.CenterX;
            cy = obj.CenterY;

            % Compute finger force (always-on gravity-like attract/repel)
            hasFinger = ~isempty(pos) && all(~isnan(pos));
            fMode = obj.FingerMode;
            if hasFinger && fMode ~= "neutral"
                fSign = 1;
                if fMode == "repel"; fSign = -1; end
                fingerX = pos(1);
                fingerY = pos(2);
                % Scale finger force to display size (tuned for ~240px)
                dispSc = min(diff(obj.DisplayRange.X), diff(obj.DisplayRange.Y)) / 240;
                fingerG = 300 * dispSc^2;       % force strength
                softening2 = (20 * dispSc)^2;   % prevents blowup at zero distance
            end

            % RK4 integration with finger generalized forces
            curState = obj.State;
            for sub = 1:nSub %#ok<FXUP>
                if hasFinger && fMode ~= "neutral"
                    Q1 = zeros(1, nPend);
                    Q2 = zeros(1, nPend);
                    for k = 1:nPend
                        t1k = curState(1, k);
                        t2k = curState(3, k);
                        % Bob1 position
                        bx1 = cx + sc * L1 * sin(t1k);
                        by1 = cy + sc * L1 * cos(t1k);
                        % Bob2 position
                        bx2 = bx1 + sc * L2 * sin(t2k);
                        by2 = by1 + sc * L2 * cos(t2k);

                        % Force on bob1: 1/r^2 toward/away from finger
                        ddx1 = fingerX - bx1;
                        ddy1 = fingerY - by1;
                        dist2_1 = ddx1^2 + ddy1^2 + softening2;
                        fMag1 = fSign * fingerG / dist2_1;
                        Fx1 = fMag1 * ddx1 / sqrt(dist2_1);
                        Fy1 = fMag1 * ddy1 / sqrt(dist2_1);
                        Q1(k) = sc * L1 * (Fx1 * cos(t1k) - Fy1 * sin(t1k));

                        % Force on bob2: 1/r^2 toward/away from finger
                        ddx2 = fingerX - bx2;
                        ddy2 = fingerY - by2;
                        dist2_2 = ddx2^2 + ddy2^2 + softening2;
                        fMag2 = fSign * fingerG / dist2_2;
                        Fx2 = fMag2 * ddx2 / sqrt(dist2_2);
                        Fy2 = fMag2 * ddy2 / sqrt(dist2_2);
                        Q2(k) = sc * L2 * (Fx2 * cos(t2k) - Fy2 * sin(t2k));
                    end
                    k1 = games.DoublePendulum.computeDerivatives(curState, L1, L2, m1, m2, grav, Q1, Q2);
                    k2 = games.DoublePendulum.computeDerivatives(curState + 0.5 * dt * k1, L1, L2, m1, m2, grav, Q1, Q2);
                    k3 = games.DoublePendulum.computeDerivatives(curState + 0.5 * dt * k2, L1, L2, m1, m2, grav, Q1, Q2);
                    k4 = games.DoublePendulum.computeDerivatives(curState + dt * k3, L1, L2, m1, m2, grav, Q1, Q2);
                else
                    k1 = games.DoublePendulum.computeDerivatives(curState, L1, L2, m1, m2, grav);
                    k2 = games.DoublePendulum.computeDerivatives(curState + 0.5 * dt * k1, L1, L2, m1, m2, grav);
                    k3 = games.DoublePendulum.computeDerivatives(curState + 0.5 * dt * k2, L1, L2, m1, m2, grav);
                    k4 = games.DoublePendulum.computeDerivatives(curState + dt * k3, L1, L2, m1, m2, grav);
                end
                curState = curState + (dt / 6) * (k1 + 2 * k2 + 2 * k3 + k4);
            end

            % Clamp angular velocities to prevent fling-outs
            maxOmega = 30;
            curState(2, :) = max(-maxOmega, min(maxOmega, curState(2, :)));
            curState(4, :) = max(-maxOmega, min(maxOmega, curState(4, :)));
            obj.State = curState;

            % Cartesian positions
            theta1 = curState(1, :);
            theta2 = curState(3, :);
            x1 = cx + sc * L1 * sin(theta1);
            y1 = cy + sc * L1 * cos(theta1);
            x2 = x1 + sc * L2 * sin(theta2);
            y2 = y1 + sc * L2 * cos(theta2);

            % Trail buffers
            obj.TrailWriteIdx = mod(obj.TrailWriteIdx, obj.TrailLen) + 1;
            obj.TrailX(obj.TrailWriteIdx, :) = x2;
            obj.TrailY(obj.TrailWriteIdx, :) = y2;

            % Trail rendering
            tLen = obj.TrailLen;
            tIdx = obj.TrailWriteIdx;
            readOrder = mod((tIdx:tIdx + tLen - 1), tLen) + 1;
            for k = 1:nPend
                tx = obj.TrailX(readOrder, k);
                ty = obj.TrailY(readOrder, k);
                validMask = ~isnan(tx);
                if sum(validMask) > 1
                    if numel(obj.TrailGlowH) >= k && isvalid(obj.TrailGlowH(k))
                        obj.TrailGlowH(k).XData = tx(validMask);
                        obj.TrailGlowH(k).YData = ty(validMask);
                    end
                    if numel(obj.TrailLineH) >= k && isvalid(obj.TrailLineH(k))
                        obj.TrailLineH(k).XData = tx(validMask);
                        obj.TrailLineH(k).YData = ty(validMask);
                    end
                end
            end

            % Rod lines (NaN-separated)
            rodX = NaN(4 * nPend, 1);
            rodY = NaN(4 * nPend, 1);
            for k = 1:nPend
                base = (k - 1) * 4;
                rodX(base + 1) = cx;    rodX(base + 2) = x1(k); rodX(base + 3) = x2(k);
                rodY(base + 1) = cy;    rodY(base + 2) = y1(k); rodY(base + 3) = y2(k);
            end
            if ~isempty(obj.RodLineH) && isvalid(obj.RodLineH)
                obj.RodLineH.XData = rodX;
                obj.RodLineH.YData = rodY;
            end

            if ~isempty(obj.Bob1GlowH) && isvalid(obj.Bob1GlowH)
                obj.Bob1GlowH.XData = x1(:);
                obj.Bob1GlowH.YData = y1(:);
            end
            if ~isempty(obj.Bob1DotH) && isvalid(obj.Bob1DotH)
                obj.Bob1DotH.XData = x1(:);
                obj.Bob1DotH.YData = y1(:);
            end
            if ~isempty(obj.Bob2GlowH) && isvalid(obj.Bob2GlowH)
                obj.Bob2GlowH.XData = x2(:);
                obj.Bob2GlowH.YData = y2(:);
            end
            if ~isempty(obj.Bob2DotH) && isvalid(obj.Bob2DotH)
                obj.Bob2DotH.XData = x2(:);
                obj.Bob2DotH.YData = y2(:);
            end

            % Scoring: divergence among bob2 endpoints
            spreadX = max(x2) - min(x2);
            spreadY = max(y2) - min(y2);
            divergence = sqrt(spreadX^2 + spreadY^2);
            if divergence > sc * 0.5
                comboMult = max(1, obj.Combo * 0.1);
                obj.addScore(round(divergence * 0.2 * comboMult));
                obj.incrementCombo();
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all double pendulum graphics.
            singleHandles = {obj.RodLineH, obj.Bob1DotH, obj.Bob1GlowH, ...
                obj.Bob2DotH, obj.Bob2GlowH, ...
                obj.PivotDotH, obj.PivotGlowH, ...
                obj.BgImageH, obj.HudTextH};
            for k = 1:numel(singleHandles)
                h = singleHandles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end

            % Delete per-pendulum trail arrays
            if ~isempty(obj.TrailGlowH)
                for k = 1:numel(obj.TrailGlowH)
                    if isvalid(obj.TrailGlowH(k)); delete(obj.TrailGlowH(k)); end
                end
            end
            if ~isempty(obj.TrailLineH)
                for k = 1:numel(obj.TrailLineH)
                    if isvalid(obj.TrailLineH(k)); delete(obj.TrailLineH(k)); end
                end
            end

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_doublependulum");

            obj.RodLineH = [];
            obj.Bob1DotH = [];
            obj.Bob1GlowH = [];
            obj.Bob2DotH = [];
            obj.Bob2GlowH = [];
            obj.PivotDotH = [];
            obj.PivotGlowH = [];
            obj.TrailGlowH = [];
            obj.TrailLineH = [];
            obj.BgImageH = [];
            obj.HudTextH = [];
            obj.State = [];
            obj.TrailX = [];
            obj.TrailY = [];
            obj.Hues = [];
            obj.FrameCount = 0;
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle double-pendulum-specific keys.
            handled = true;
            switch key
                case "m"
                    % Cycle sub-mode
                    modes = ["chaos", "energy", "cascade", "freefall"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();

                case "n"
                    % Cycle finger interaction mode
                    fModes = ["neutral", "attract", "repel"];
                    idx = find(fModes == obj.FingerMode, 1);
                    obj.FingerMode = fModes(mod(idx, numel(fModes)) + 1);
                    obj.applySubMode();

                case "b"
                    % Toggle rod/pivot/bob1 visibility
                    obj.ShowRods = ~obj.ShowRods;
                    vis = "on";
                    if ~obj.ShowRods; vis = "off"; end
                    if ~isempty(obj.RodLineH) && isvalid(obj.RodLineH)
                        obj.RodLineH.Visible = vis;
                    end
                    if ~isempty(obj.PivotDotH) && isvalid(obj.PivotDotH)
                        obj.PivotDotH.Visible = vis;
                    end
                    if ~isempty(obj.PivotGlowH) && isvalid(obj.PivotGlowH)
                        obj.PivotGlowH.Visible = vis;
                    end
                    if ~isempty(obj.Bob1DotH) && isvalid(obj.Bob1DotH)
                        obj.Bob1DotH.Visible = vis;
                    end
                    if ~isempty(obj.Bob1GlowH) && isvalid(obj.Bob1GlowH)
                        obj.Bob1GlowH.Visible = vis;
                    end
                    obj.applySubMode();  % refresh HUD

                case {"uparrow", "downarrow"}
                    % Change pendulum count: 5/10/15/20
                    counts = [5, 10, 15, 20];
                    idx = find(counts == obj.PendulumCount, 1);
                    if isempty(idx); idx = 4; end
                    if key == "uparrow"
                        idx = min(idx + 1, numel(counts));
                    else
                        idx = max(idx - 1, 1);
                    end
                    obj.PendulumCount = counts(idx);

                    % Preserve user settings across reinit
                    prevSubMode = obj.SubMode;
                    prevFingerMode = obj.FingerMode;
                    prevShowRods = obj.ShowRods;

                    obj.onCleanup();
                    obj.onInit(obj.Ax, obj.DisplayRange, struct());

                    obj.SubMode = prevSubMode;
                    obj.FingerMode = prevFingerMode;
                    obj.ShowRods = prevShowRods;
                    if ~prevShowRods
                        if ~isempty(obj.RodLineH) && isvalid(obj.RodLineH)
                            obj.RodLineH.Visible = "off";
                        end
                        if ~isempty(obj.PivotDotH) && isvalid(obj.PivotDotH)
                            obj.PivotDotH.Visible = "off";
                        end
                        if ~isempty(obj.PivotGlowH) && isvalid(obj.PivotGlowH)
                            obj.PivotGlowH.Visible = "off";
                        end
                        if ~isempty(obj.Bob1DotH) && isvalid(obj.Bob1DotH)
                            obj.Bob1DotH.Visible = "off";
                        end
                        if ~isempty(obj.Bob1GlowH) && isvalid(obj.Bob1GlowH)
                            obj.Bob1GlowH.Visible = "off";
                        end
                    end
                    obj.applySubMode();

                case "0"
                    % Reset to current sub-mode initial conditions
                    obj.applySubMode();

                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return double-pendulum-specific results.
            r.Title = "DOUBLE PENDULUM";
            elapsed = toc(obj.StartTic);
            r.Lines = {
                sprintf("N=%d  |  Mode: %s  |  Time: %.0fs", ...
                    obj.PendulumCount, obj.SubMode, elapsed)
            };
        end

    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function applySubMode(obj)
            %applySubMode  Set initial conditions for current sub-mode.
            nPend = size(obj.State, 2);
            if nPend == 0; return; end

            switch obj.SubMode
                case "chaos"
                    baseAngle = pi * 0.75;
                    spreadVec = linspace(-0.02, 0.02, nPend);
                    obj.State(1, :) = baseAngle + spreadVec;
                    obj.State(2, :) = 0;
                    obj.State(3, :) = baseAngle + spreadVec * 0.5;
                    obj.State(4, :) = 0;
                case "cascade"
                    spreadVec = linspace(-0.15, 0.15, nPend);
                    baseAngle = pi * 0.7;
                    obj.State(1, :) = baseAngle + spreadVec;
                    obj.State(2, :) = 0;
                    obj.State(3, :) = baseAngle + spreadVec * 0.5;
                    obj.State(4, :) = 0;
                case "energy"
                    baseAngle = pi * 0.95;
                    spreadVec = linspace(-0.03, 0.03, nPend);
                    obj.State(1, :) = baseAngle + spreadVec;
                    obj.State(2, :) = 2.0;
                    obj.State(3, :) = baseAngle - spreadVec;
                    obj.State(4, :) = -1.5;
                case "freefall"
                    spreadVec = linspace(-0.08, 0.08, nPend);
                    obj.State(1, :) = pi + spreadVec;
                    obj.State(2, :) = 0;
                    obj.State(3, :) = pi + spreadVec * 0.5;
                    obj.State(4, :) = 0;
            end

            % Reset trail buffers
            obj.TrailX = NaN(obj.TrailLen, nPend);
            obj.TrailY = NaN(obj.TrailLen, nPend);
            obj.TrailWriteIdx = 0;

            % Update HUD text
            if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                obj.HudTextH.String = obj.buildHudString();
            end
        end

        function s = buildHudString(obj)
            %buildHudString  Compose the bottom-left HUD label.
            rodsLabel = "SHOW PENDULUM";
            if ~obj.ShowRods; rodsLabel = "HIDE PENDULUM"; end
            s = upper(obj.SubMode) + " [M]  |  " + ...
                upper(obj.FingerMode) + " [N]  |  " + ...
                rodsLabel + " [B]  |  N=" + ...
                obj.PendulumCount + " [" + char(8593) + char(8595) + "]";
        end
    end

    % =================================================================
    % STATIC METHODS — PHYSICS
    % =================================================================
    methods (Static, Access = private)

        function dState = computeDerivatives(state, L1, L2, m1, m2, gVal, Q1, Q2)
            %computeDerivatives  State derivatives for double pendulum (Lagrangian).
            %   state: 4 x N matrix [theta1; omega1; theta2; omega2]
            %   Q1, Q2: optional generalized forces (1 x N) on theta1, theta2
            %   Returns: 4 x N matrix of derivatives.

            t1 = state(1, :); w1 = state(2, :);
            t2 = state(3, :); w2 = state(4, :);
            deltaAngle = t1 - t2;
            totalMass = m1 + m2;

            cosDelta = cos(deltaAngle);
            sinDelta = sin(deltaAngle);

            den = totalMass * L1 - m2 * L1 * cosDelta.^2;
            den = max(abs(den), 1e-10) .* sign(den + 1e-20);

            a1 = (-m2 * L1 * w1.^2 .* sinDelta .* cosDelta ...
                + m2 * gVal * sin(t2) .* cosDelta ...
                - m2 * L2 * w2.^2 .* sinDelta ...
                - totalMass * gVal * sin(t1)) ./ den;

            den2 = L2 / L1 .* den;
            a2 = (m2 * L2 * w2.^2 .* sinDelta .* cosDelta ...
                + totalMass * (gVal * sin(t1) .* cosDelta ...
                    - L1 * w1.^2 .* sinDelta ...
                    - gVal * sin(t2))) ./ den2;

            % Add external generalized forces
            if nargin >= 8 && ~isempty(Q1)
                a1 = a1 + Q1 ./ (totalMass * L1);
                a2 = a2 + Q2 ./ (m2 * L2);
            end

            dState = [w1; a1; w2; a2];
        end
    end
end
