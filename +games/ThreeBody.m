classdef ThreeBody < GameBase
    %ThreeBody  Gravitational three-body simulation with trails.
    %   Velocity Verlet N-body integration with three equal-mass bodies.
    %   Three sub-modes: figure-8 (Chenciner-Montgomery), Lagrange
    %   (equilateral triangle), and freeplay (random ICs).
    %   Finger acts as a gravitational attractor in all sub-modes.
    %
    %   Controls:
    %     M — cycle sub-mode (figure8 / lagrange / freeplay)
    %     0 — reset to current sub-mode initial conditions
    %
    %   Standalone: games.ThreeBody().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Three-Body"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Body positions, velocities, masses (sim-space)
        PosX            (3,1) double
        PosY            (3,1) double
        VelX            (3,1) double
        VelY            (3,1) double
        BodyMass        (3,1) double

        % Trail circular buffer (sim-space)
        TrailX          (3,:) double
        TrailY          (3,:) double
        TrailIdx        (1,1) double = 0
        TrailLen        (1,1) double = 400

        % Integration parameters
        SubMode         (1,1) string = "figure8"
        Dt              (1,1) double = 0.0005
        SubSteps        (1,1) double = 20
        GravConst       (1,1) double = 1.0

        % Display mapping (sim -> display)
        SimScale        (1,1) double = 1
        CenterX         (1,1) double = 0
        CenterY         (1,1) double = 0

        % Session tracking
        SessionStartTic uint64
        FrameCount      (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        CoreH                           % scatter array (3x1) — bright body dots
        GlowH                          % scatter array (3x1) — soft glow behind bodies
        TrailH                          % line array (3x1) — orbital trails
        CoMH                            % line — center-of-mass dot
        CoMLineH                        % line array (3x1) — lines from bodies to CoM
        BgImageH                        % image — dark background overlay
        HudTextH                        % text — bottom-left HUD
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize three-body simulation.
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

            obj.FrameCount = 0;
            obj.SessionStartTic = tic;
            obj.TrailIdx = 0;

            dx = displayRange.X;
            dy = displayRange.Y;

            % Black background image — covers camera feed
            obj.BgImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_threebody");
            uistack(obj.BgImageH, "bottom");
            uistack(obj.BgImageH, "up");

            % Apply initial conditions for the default sub-mode
            obj.applySubMode();

            % Body colors: cyan, green, magenta
            bodyColors = [obj.ColorCyan; obj.ColorGreen; obj.ColorMagenta];

            % Compute initial display positions for graphics creation
            dspX = obj.PosX * obj.SimScale + obj.CenterX;
            dspY = obj.PosY * obj.SimScale + obj.CenterY;

            % Initialize handle arrays as empty graphics arrays
            trailArr = gobjects(3, 1);
            glowArr = gobjects(3, 1);
            coreArr = gobjects(3, 1);

            % Create graphics per body (trail behind glow behind core)
            for b = 1:3
                col = bodyColors(b, :);

                trailArr(b) = line(ax, dspX(b), dspY(b), ...
                    "Color", [col, 0.5], "LineWidth", 1.5, ...
                    "Tag", "GT_threebody");

                glowArr(b) = scatter(ax, dspX(b), dspY(b), 600, col, ...
                    "filled", "MarkerFaceAlpha", 0.15, ...
                    "Tag", "GT_threebody");

                coreArr(b) = scatter(ax, dspX(b), dspY(b), 200, col, ...
                    "filled", "MarkerFaceAlpha", 1.0, ...
                    "Tag", "GT_threebody");
            end
            obj.TrailH = trailArr;
            obj.GlowH = glowArr;
            obj.CoreH = coreArr;

            % Center of mass + connecting lines
            comX = sum(obj.BodyMass .* obj.PosX) / sum(obj.BodyMass);
            comY = sum(obj.BodyMass .* obj.PosY) / sum(obj.BodyMass);
            comDispX = comX * obj.SimScale + obj.CenterX;
            comDispY = comY * obj.SimScale + obj.CenterY;

            % Thin lines from each body to CoM (behind the CoM dot)
            comLines = gobjects(3, 1);
            for b = 1:3
                comLines(b) = line(ax, ...
                    [dspX(b), comDispX], [dspY(b), comDispY], ...
                    "Color", [obj.ColorGold, 0.5], "LineWidth", 0.5, ...
                    "Tag", "GT_threebody");
            end
            obj.CoMLineH = comLines;

            obj.CoMH = line(ax, comDispX, comDispY, ...
                "Marker", ".", "MarkerSize", 10, ...
                "Color", obj.ColorGold, "LineStyle", "none", ...
                "Tag", "GT_threebody");

            % HUD text — bottom-left
            obj.HudTextH = text(ax, dx(1) + 5, dy(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_threebody");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame Velocity Verlet integration + rendering.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            obj.FrameCount = obj.FrameCount + 1;

            G = obj.GravConst;
            dt = obj.Dt;
            ds = obj.DtScale;
            nSub = max(1, round(obj.SubSteps * ds));
            nSub = min(nSub, obj.SubSteps * 4);  % safety cap
            softening = 0.01;
            tLen = obj.TrailLen;

            px = obj.PosX;
            py = obj.PosY;
            vx = obj.VelX;
            vy = obj.VelY;
            m = obj.BodyMass;

            % Finger sim-coords (finger gravity in ALL sub-modes)
            hasFinger = ~any(isnan(pos));
            if hasFinger
                fSimX = (pos(1) - obj.CenterX) / obj.SimScale;
                fSimY = (pos(2) - obj.CenterY) / obj.SimScale;
                % Stronger for stable orbits (need more force to perturb),
                % weaker for freeplay (bodies already loosely bound)
                if obj.SubMode == "freeplay"
                    fMass = 0.3;
                else
                    fMass = 1.5;
                end
            end

            % --- Velocity Verlet sub-stepping ---
            for s = 1:nSub %#ok<FXUP>
                % Compute accelerations at current positions
                accX = zeros(3, 1);
                accY = zeros(3, 1);
                % Pairwise interactions: (1,2), (1,3), (2,3)
                for i = 1:2
                    for j = (i+1):3
                        ddx = px(j) - px(i);
                        ddy = py(j) - py(i);
                        r2 = ddx^2 + ddy^2 + softening;
                        invR3 = G / (r2 * sqrt(r2));
                        accX(i) = accX(i) + m(j) * invR3 * ddx;
                        accY(i) = accY(i) + m(j) * invR3 * ddy;
                        accX(j) = accX(j) - m(i) * invR3 * ddx;
                        accY(j) = accY(j) - m(i) * invR3 * ddy;
                    end
                end
                % Finger gravity (all modes)
                if hasFinger
                    for b = 1:3
                        ddx = fSimX - px(b);
                        ddy = fSimY - py(b);
                        r2 = ddx^2 + ddy^2 + softening;
                        invR3 = G * fMass / (r2 * sqrt(r2));
                        accX(b) = accX(b) + invR3 * ddx;
                        accY(b) = accY(b) + invR3 * ddy;
                    end
                end

                % Half-step velocity
                vx = vx + accX * (dt * 0.5);
                vy = vy + accY * (dt * 0.5);

                % Full-step position
                px = px + vx * dt;
                py = py + vy * dt;

                % Recompute accelerations at new positions
                accX2 = zeros(3, 1);
                accY2 = zeros(3, 1);
                for i = 1:2
                    for j = (i+1):3
                        ddx = px(j) - px(i);
                        ddy = py(j) - py(i);
                        r2 = ddx^2 + ddy^2 + softening;
                        invR3 = G / (r2 * sqrt(r2));
                        accX2(i) = accX2(i) + m(j) * invR3 * ddx;
                        accX2(j) = accX2(j) - m(i) * invR3 * ddx;
                        accY2(i) = accY2(i) + m(j) * invR3 * ddy;
                        accY2(j) = accY2(j) - m(i) * invR3 * ddy;
                    end
                end
                if hasFinger
                    for b = 1:3
                        ddx = fSimX - px(b);
                        ddy = fSimY - py(b);
                        r2 = ddx^2 + ddy^2 + softening;
                        invR3 = G * fMass / (r2 * sqrt(r2));
                        accX2(b) = accX2(b) + invR3 * ddx;
                        accY2(b) = accY2(b) + invR3 * ddy;
                    end
                end

                % Second half-step velocity
                vx = vx + accX2 * (dt * 0.5);
                vy = vy + accY2 * (dt * 0.5);
            end

            obj.PosX = px;
            obj.PosY = py;
            obj.VelX = vx;
            obj.VelY = vy;

            % --- Fixed scale, no zoom-out ---
            % Scale is set once in applySubMode to fit the initial config.
            % Bodies that fly apart just leave the screen (realistic).
            % If ALL 3 are offscreen, auto-reset the sub-mode.
            obj.CenterX = mean(dx);
            obj.CenterY = mean(dy);

            % Check if all body dots are offscreen (display coords)
            bodyDispX = px * obj.SimScale + obj.CenterX;
            bodyDispY = py * obj.SimScale + obj.CenterY;
            offscreen = (bodyDispX < dx(1) | bodyDispX > dx(2) | ...
                         bodyDispY < dy(1) | bodyDispY > dy(2));
            if all(offscreen)
                obj.applySubMode();    % reset positions
                obj.TrailX(:) = NaN;
                obj.TrailY(:) = NaN;
                obj.TrailIdx = 0;
            end

            % --- Trail update ---
            obj.TrailIdx = mod(obj.TrailIdx, tLen) + 1;
            tidx = obj.TrailIdx;

            % Ensure trail buffers are allocated
            if isempty(obj.TrailX) || size(obj.TrailX, 2) ~= tLen
                obj.TrailX = NaN(3, tLen);
                obj.TrailY = NaN(3, tLen);
            end

            % Store current positions in trail (sim coordinates)
            obj.TrailX(:, tidx) = px;
            obj.TrailY(:, tidx) = py;

            % --- Display mapping: sim -> display ---
            simScale = obj.SimScale;
            cx = obj.CenterX;
            cy = obj.CenterY;

            dispPosX = px * simScale + cx;
            dispPosY = py * simScale + cy;

            % --- Update body graphics ---
            hasCore = numel(obj.CoreH) >= 3;
            hasGlow = numel(obj.GlowH) >= 3;
            hasTrail = numel(obj.TrailH) >= 3;
            for b = 1:3
                if hasCore && isvalid(obj.CoreH(b))
                    obj.CoreH(b).XData = dispPosX(b);
                    obj.CoreH(b).YData = dispPosY(b);
                end
                if hasGlow && isvalid(obj.GlowH(b))
                    obj.GlowH(b).XData = dispPosX(b);
                    obj.GlowH(b).YData = dispPosY(b);
                end

                % Trail rendering (oldest -> newest in display coords)
                trailOrder = mod(tidx:tidx + tLen - 1, tLen) + 1;
                tx = obj.TrailX(b, trailOrder) * simScale + cx;
                ty = obj.TrailY(b, trailOrder) * simScale + cy;
                validT = ~isnan(tx);
                if sum(validT) > 1 && hasTrail && isvalid(obj.TrailH(b))
                    obj.TrailH(b).XData = tx(validT);
                    obj.TrailH(b).YData = ty(validT);
                end
            end

            % --- Center of mass ---
            totalMass = sum(m);
            comX = sum(m .* px) / totalMass;
            comY = sum(m .* py) / totalMass;
            comDispX = comX * simScale + cx;
            comDispY = comY * simScale + cy;
            if ~isempty(obj.CoMH) && isvalid(obj.CoMH)
                obj.CoMH.XData = comDispX;
                obj.CoMH.YData = comDispY;
            end
            % Lines from bodies to CoM
            if numel(obj.CoMLineH) >= 3
                for b = 1:3
                    if isvalid(obj.CoMLineH(b))
                        obj.CoMLineH(b).XData = [dispPosX(b), comDispX];
                        obj.CoMLineH(b).YData = [dispPosY(b), comDispY];
                    end
                end
            end

            % --- HUD update (every 30 frames to reduce text rendering cost) ---
            if mod(obj.FrameCount, 30) == 0
                if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                    obj.HudTextH.String = obj.buildHudString();
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all three-body graphics and reset state.

            % Delete stored handle arrays
            for b = 1:3
                if numel(obj.CoreH) >= b && ~isempty(obj.CoreH(b)) && isvalid(obj.CoreH(b))
                    delete(obj.CoreH(b));
                end
                if numel(obj.GlowH) >= b && ~isempty(obj.GlowH(b)) && isvalid(obj.GlowH(b))
                    delete(obj.GlowH(b));
                end
                if numel(obj.TrailH) >= b && ~isempty(obj.TrailH(b)) && isvalid(obj.TrailH(b))
                    delete(obj.TrailH(b));
                end
            end

            % Delete singleton handles
            singles = {obj.CoMH, obj.BgImageH, obj.HudTextH};
            for k = 1:numel(singles)
                h = singles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end

            % Delete CoM lines
            if ~isempty(obj.CoMLineH)
                for b = 1:numel(obj.CoMLineH)
                    if isvalid(obj.CoMLineH(b))
                        delete(obj.CoMLineH(b));
                    end
                end
            end

            % Orphan guard — delete any tagged objects that survived
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_threebody");

            % Reset handles (use [] not gobjects — placeholders pass isvalid)
            obj.CoreH = [];
            obj.GlowH = [];
            obj.TrailH = [];
            obj.CoMH = [];
            obj.CoMLineH = [];
            obj.BgImageH = [];
            obj.HudTextH = [];

            % Reset state
            obj.TrailX = [];
            obj.TrailY = [];
            obj.TrailIdx = 0;
            obj.FrameCount = 0;
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle mode-specific key events.
            %   M — cycle sub-mode (figure8 / lagrange / freeplay)
            %   0 — reset to current sub-mode initial conditions
            handled = true;
            switch key
                case "m"
                    modes = ["figure8", "lagrange", "freeplay"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();
                case "0"
                    obj.applySubMode();
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return three-body-specific results.
            r.Title = "THREE-BODY";
            elapsed = toc(obj.SessionStartTic);
            r.Lines = {
                sprintf("Mode: %s  |  Time: %.0fs", obj.SubMode, elapsed)
            };
        end

    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function applySubMode(obj)
            %applySubMode  Set initial conditions for the current sub-mode.

            switch obj.SubMode
                case "figure8"
                    % Cris Moore figure-8 solution (Chenciner & Montgomery 2000)
                    % Exact ICs — the user's finger is the perturbation
                    obj.PosX = [0.97000436; -0.97000436; 0];
                    obj.PosY = [-0.24308753; 0.24308753; 0];
                    obj.VelX = [0.46620369; 0.46620369; -0.93240737];
                    obj.VelY = [0.43236573; 0.43236573; -0.86473146];
                    obj.BodyMass = [1; 1; 1];

                case "lagrange"
                    % Equilateral triangle — Lagrange solution
                    % Exact ICs — the user's finger is the perturbation
                    orbitR = 1.0;
                    angles = [0; 2*pi/3; 4*pi/3];
                    obj.PosX = orbitR * cos(angles);
                    obj.PosY = orbitR * sin(angles);
                    obj.BodyMass = [1; 1; 1];

                    % Tangential velocity for circular orbit
                    vMag = sqrt(obj.GravConst * 1.0 / (orbitR * sqrt(3)));
                    obj.VelX = vMag * (-sin(angles));
                    obj.VelY = vMag * cos(angles);

                case "freeplay"
                    % Random positions near center, small random velocities
                    obj.PosX = (rand(3, 1) - 0.5) * 0.6;
                    obj.PosY = (rand(3, 1) - 0.5) * 0.6;
                    obj.VelX = (rand(3, 1) - 0.5) * 0.3;
                    obj.VelY = (rand(3, 1) - 0.5) * 0.3;
                    obj.BodyMass = [1; 1; 1];

                    % Zero-out center-of-mass velocity (prevent drift)
                    totalM = sum(obj.BodyMass);
                    comVx = sum(obj.BodyMass .* obj.VelX) / totalM;
                    comVy = sum(obj.BodyMass .* obj.VelY) / totalM;
                    obj.VelX = obj.VelX - comVx;
                    obj.VelY = obj.VelY - comVy;
            end

            % Initialize scale to fit initial configuration in 80% of display
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);
            maxExtent = max([abs(obj.PosX); abs(obj.PosY)]);
            if maxExtent > 0
                obj.SimScale = min(areaW, areaH) * 0.4 / maxExtent;
            else
                obj.SimScale = min(areaW, areaH) * 0.3;
            end
            obj.CenterX = mean(dx);
            obj.CenterY = mean(dy);

            % Reset trail buffers
            obj.TrailX = NaN(3, obj.TrailLen);
            obj.TrailY = NaN(3, obj.TrailLen);
            obj.TrailIdx = 0;

            % Clear trail line data to prevent stale trails from old sub-mode
            for b = 1:3
                if numel(obj.TrailH) >= b && isgraphics(obj.TrailH(b))
                    obj.TrailH(b).XData = NaN;
                    obj.TrailH(b).YData = NaN;
                end
            end

            % Update HUD
            if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                obj.HudTextH.String = obj.buildHudString();
            end
        end

        function s = buildHudString(obj)
            %buildHudString  Build HUD string for three-body mode.
            elapsed = toc(obj.SessionStartTic);

            % Total energy: kinetic + gravitational potential
            px = obj.PosX; py = obj.PosY;
            vx = obj.VelX; vy = obj.VelY;
            m = obj.BodyMass;
            G = obj.GravConst;

            KE = 0.5 * sum(m .* (vx.^2 + vy.^2));
            PE = 0;
            for i = 1:2
                for j = (i+1):3
                    rDist = sqrt((px(i) - px(j))^2 + (py(i) - py(j))^2 + 0.01);
                    PE = PE - G * m(i) * m(j) / rDist;
                end
            end
            totalEnergy = KE + PE;

            s = upper(obj.SubMode) + " [M]" + ...
                "  |  E = " + sprintf("%.3f", totalEnergy) + ...
                "  |  t = " + sprintf("%.1fs", elapsed);
        end
    end
end
