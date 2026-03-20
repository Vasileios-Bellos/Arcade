classdef StrangeAttractors < GameBase
    %StrangeAttractors  Strange attractor visualization with RK4 integration.
    %   40 tracers (default, 10-70 via Up/Down) in 4 strange attractors:
    %   Lorenz, Rossler, Thomas, Aizawa. Per-attractor 3D-to-2D projection
    %   with rotating viewpoint. Ribbon trail patches with movmean smoothing.
    %   Multi-batch trail sampling scales with speed for uniform spatial
    %   resolution.
    %
    %   Controls:
    %     M           — cycle attractor (lorenz/rossler/thomas/aizawa)
    %     N           — toggle finger parameter control ON/OFF
    %     Up/Down     — tracer count (10-70, step 10)
    %     Left/Right  — speed [0.25, 0.5, 1, 2, 3]x
    %     0           — reset particles to current attractor ICs
    %
    %   Standalone: games.StrangeAttractors().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Strange Attractors"
    end

    % =================================================================
    % SIMULATION STATE
    % =================================================================
    properties (Access = private)
        State           (3,:) double
        TracerCount     (1,1) double = 40
        Dt              (1,1) double = 0.005
        SubSteps        (1,1) double = 5
        TrailX          (:,:) double
        TrailY          (:,:) double
        TrailIdx        (1,1) double = 0
        TrailCount      (1,1) double = 0
        TrailLen        (1,1) double = 70
        SubMode         (1,1) string = "lorenz"
        ViewAngle       (1,1) double = 0
        Params          struct
        FrameCount      (1,1) double = 0
        Hues            (:,1) double
        ProjBounds      (1,4) double = [-25 25 0 55]
        FingerParam     (1,1) double = NaN
        FingerParamY    (1,1) double = NaN
        SpeedMult       (1,1) double = 1.0
        FingerControl   (1,1) logical = true
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        TrailH
        GlowH
        ParticleH
        BgImageH
        HudTextH
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create strange attractor graphics and seed particles.
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

            dxRange = displayRange.X;
            dyRange = displayRange.Y;
            N = obj.TracerCount;

            % State left empty — applySubMode populates it.
            obj.State = zeros(3, 0);

            obj.Hues = linspace(0, 1 - 1/N, N)';

            obj.TrailX = NaN(obj.TrailLen, N);
            obj.TrailY = NaN(obj.TrailLen, N);
            obj.TrailIdx = 0;
            obj.TrailCount = 0;

            obj.ViewAngle = 0;
            obj.FrameCount = 0;
            obj.FingerParam = NaN;
            obj.FingerParamY = NaN;
            obj.SpeedMult = 1.0;
            obj.FingerControl = true;

            % Dark background — covers camera feed (alpha 0.92)
            obj.BgImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_strangeattractors");
            try
                uistack(obj.BgImageH, "bottom");
                uistack(obj.BgImageH, "up");
            catch
                % uistack can fail during rapid reinit — non-critical
            end

            % Trail ribbon patch per particle (filled quads, no edges)
            trailArr = gobjects(N, 1);
            for k = 1:N
                trailArr(k) = patch(ax, ...
                    "Vertices", [NaN NaN], "Faces", 1, ...
                    "FaceVertexCData", [0 0 0], ...
                    "FaceVertexAlphaData", 0, ...
                    "FaceColor", "interp", "FaceAlpha", "interp", ...
                    "EdgeColor", "none", ...
                    "AlphaDataMapping", "none", ...
                    "Tag", "GT_strangeattractors");
            end
            obj.TrailH = trailArr;
            obj.GlowH = [];

            % Particle scatter
            cdata = zeros(N, 3);
            for k = 1:N
                [cdata(k, 1), cdata(k, 2), cdata(k, 3)] = ...
                    GameBase.hsvToRgb(obj.Hues(k));
            end
            obj.ParticleH = scatter(ax, NaN(N, 1), NaN(N, 1), 35, ...
                cdata, "filled", "MarkerFaceAlpha", 0.9, ...
                "Tag", "GT_strangeattractors");

            % HUD text
            obj.HudTextH = text(ax, dxRange(1) + 5, dyRange(2) - 5, ...
                "", ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_strangeattractors");

            % Seed the default attractor
            obj.SubMode = "lorenz";
            obj.applySubMode();
        end

        function onUpdate(obj, pos)
            %onUpdate  RK4 integration + 3D projection + rendering.
            if isempty(obj.State); return; end

            N = size(obj.State, 2);
            dt = obj.Dt;
            state = obj.State;
            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;

            obj.FrameCount = obj.FrameCount + 1;

            % Finger position maps to attractor parameters (when control ON)
            if obj.FingerControl && ~isempty(pos) && all(~isnan(pos))
                tX = (pos(1) - dxRange(1)) / (dxRange(2) - dxRange(1));
                tX = max(0, min(1, tX));
                obj.FingerParam = 10 + tX * 40;

                % Y: top of screen = high value (1), bottom = low (0)
                tY = 1 - (pos(2) - dyRange(1)) / (dyRange(2) - dyRange(1));
                tY = max(0, min(1, tY));
                obj.FingerParamY = tY;
            else
                obj.FingerParam = NaN;
                obj.FingerParamY = NaN;
            end

            % Update HUD every 3rd frame
            if mod(obj.FrameCount, 3) == 0 ...
                    && ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                obj.HudTextH.String = obj.buildHudString();
            end

            % RK4 integration — 4 batches per frame at 1x speed, each
            % batch stores a trail point for smooth spatial resolution.
            ds = obj.DtScale;
            nBatches = max(1, round(obj.SpeedMult * 1.6667 * ds));
            nBatches = min(nBatches, round(obj.SpeedMult * 1.6667) * 4);  % safety cap
            baseSub = obj.SubSteps;
            angleStep = 0.002 / nBatches;
            expandA = 0.05;
            shrinkA = 0.015;
            boundsMargin = 3;

            dispX = zeros(1, N);
            dispY = zeros(1, N);

            for iBatch = 1:nBatches
                for iSub = 1:baseSub
                    k1 = obj.computeDerivatives(state);
                    k2 = obj.computeDerivatives(state + 0.5 * dt * k1);
                    k3 = obj.computeDerivatives(state + 0.5 * dt * k2);
                    k4 = obj.computeDerivatives(state + dt * k3);
                    state = state + (dt / 6) * (k1 + 2*k2 + 2*k3 + k4);
                end

                % Guard diverged / escaped particles — reset to IC
                bad = any(~isfinite(state), 1);
                switch obj.SubMode
                    case "lorenz"
                        bad = bad | any(abs(state) > 100, 1);
                    case "rossler"
                        bad = bad | any(abs(state) > 80, 1);
                    case "thomas"
                        bad = bad | any(abs(state) > 10, 1);
                    case "aizawa"
                        bad = bad | abs(state(1,:)) > 3 ...
                            | abs(state(2,:)) > 3 ...
                            | state(3,:) < -2 | state(3,:) > 4;
                end
                if any(bad)
                    state = obj.respawnBadParticles(state, bad);
                end
                obj.State = state;

                % 3D to 2D projection — per-attractor best view
                ca = cos(obj.ViewAngle);
                sa = sin(obj.ViewAngle);
                obj.ViewAngle = obj.ViewAngle + angleStep;
                xr = state(1, :) * ca - state(2, :) * sa;
                yr = state(1, :) * sa + state(2, :) * ca;
                switch obj.SubMode
                    case "lorenz"
                        projX = xr;
                        projY = state(3, :);
                    case "rossler"
                        elev = 0.25;
                        projX = xr;
                        projY = yr * cos(elev) + state(3, :) * sin(elev);
                    case "thomas"
                        elev = 0.3;
                        projX = xr;
                        projY = yr * cos(elev) + state(3, :) * sin(elev);
                    case "aizawa"
                        projX = xr;
                        projY = state(3, :);
                    otherwise
                        projX = xr;
                        projY = state(3, :);
                end

                % Smoothly expand/contract projection bounds
                pxMin = min(projX); pxMax = max(projX);
                pyMin = min(projY); pyMax = max(projY);
                if pxMin - boundsMargin < obj.ProjBounds(1)
                    obj.ProjBounds(1) = obj.ProjBounds(1) * (1 - expandA) ...
                        + (pxMin - boundsMargin) * expandA;
                elseif pxMin - boundsMargin > obj.ProjBounds(1)
                    obj.ProjBounds(1) = obj.ProjBounds(1) * (1 - shrinkA) ...
                        + (pxMin - boundsMargin) * shrinkA;
                end
                if pxMax + boundsMargin > obj.ProjBounds(2)
                    obj.ProjBounds(2) = obj.ProjBounds(2) * (1 - expandA) ...
                        + (pxMax + boundsMargin) * expandA;
                elseif pxMax + boundsMargin < obj.ProjBounds(2)
                    obj.ProjBounds(2) = obj.ProjBounds(2) * (1 - shrinkA) ...
                        + (pxMax + boundsMargin) * shrinkA;
                end
                if pyMin - boundsMargin < obj.ProjBounds(3)
                    obj.ProjBounds(3) = obj.ProjBounds(3) * (1 - expandA) ...
                        + (pyMin - boundsMargin) * expandA;
                elseif pyMin - boundsMargin > obj.ProjBounds(3)
                    obj.ProjBounds(3) = obj.ProjBounds(3) * (1 - shrinkA) ...
                        + (pyMin - boundsMargin) * shrinkA;
                end
                if pyMax + boundsMargin > obj.ProjBounds(4)
                    obj.ProjBounds(4) = obj.ProjBounds(4) * (1 - expandA) ...
                        + (pyMax + boundsMargin) * expandA;
                elseif pyMax + boundsMargin < obj.ProjBounds(4)
                    obj.ProjBounds(4) = obj.ProjBounds(4) * (1 - shrinkA) ...
                        + (pyMax + boundsMargin) * shrinkA;
                end

                bnd = obj.ProjBounds;
                bndW = max(bnd(2) - bnd(1), 1e-6);
                bndH = max(bnd(4) - bnd(3), 1e-6);
                dxSpan = dxRange(2) - dxRange(1);
                dySpan = dyRange(2) - dyRange(1);
                dispX = dxRange(1) + (projX - bnd(1)) / bndW * dxSpan;
                dispY = dyRange(2) - (projY - bnd(3)) / bndH * dySpan;

                % Aizawa: stretch Y to compensate for widescreen squish
                if obj.SubMode == "aizawa"
                    arFix = dxSpan / dySpan * 1.2;
                    midY = (dyRange(1) + dyRange(2)) / 2;
                    dispY = midY + (dispY - midY) * arFix;
                end

                % Store trail point after each batch
                obj.TrailIdx = mod(obj.TrailIdx, obj.TrailLen) + 1;
                obj.TrailX(obj.TrailIdx, :) = dispX;
                obj.TrailY(obj.TrailIdx, :) = dispY;
                obj.TrailCount = min(obj.TrailCount + 1, obj.TrailLen);
            end

            % Render trails — filled ribbon quads with FaceAlpha="interp"
            obj.renderTrails(N);

            % Update scatter (rebuild CData if N changed)
            if ~isempty(obj.ParticleH) && isvalid(obj.ParticleH)
                if numel(obj.ParticleH.XData) ~= N
                    cdata = zeros(N, 3);
                    for k = 1:N
                        [cdata(k,1), cdata(k,2), cdata(k,3)] = ...
                            GameBase.hsvToRgb(obj.Hues(k));
                    end
                    set(obj.ParticleH, "XData", dispX(:), ...
                        "YData", dispY(:), "CData", cdata);
                else
                    set(obj.ParticleH, "XData", dispX(:), ...
                        "YData", dispY(:));
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all strange attractor graphics.
            if ~isempty(obj.TrailH)
                for k = 1:numel(obj.TrailH)
                    if isvalid(obj.TrailH(k)); delete(obj.TrailH(k)); end
                end
            end
            if ~isempty(obj.GlowH)
                for k = 1:numel(obj.GlowH)
                    if isvalid(obj.GlowH(k)); delete(obj.GlowH(k)); end
                end
            end
            simpleH = {obj.ParticleH, obj.BgImageH, obj.HudTextH};
            for k = 1:numel(simpleH)
                h = simpleH{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_strangeattractors");

            obj.TrailH = [];
            obj.GlowH = [];
            obj.ParticleH = [];
            obj.BgImageH = [];
            obj.HudTextH = [];
            obj.State = zeros(3, 0);
            obj.TrailX = [];
            obj.TrailY = [];
            obj.Hues = [];
            obj.ViewAngle = 0;
            obj.FrameCount = 0;
            obj.TrailCount = 0;
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles attractors.
            modes = ["lorenz", "rossler", "thomas", "aizawa"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.State = zeros(3, 0);  % guard race condition
            obj.SubMode = modes(newIdx);
            obj.applySubMode();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle StrangeAttractors-specific key events.
            handled = true;
            switch key
                case "m"
                    % Cycle attractor
                    modes = ["lorenz", "rossler", "thomas", "aizawa"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.State = zeros(3, 0);  % guard race condition
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();

                case "n"
                    % Toggle finger parameter control
                    obj.FingerControl = ~obj.FingerControl;
                    if ~obj.FingerControl
                        obj.FingerParam = NaN;
                        obj.FingerParamY = NaN;
                    end
                    if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                        obj.HudTextH.String = obj.buildHudString();
                    end

                case "uparrow"
                    obj.TracerCount = min(70, obj.TracerCount + 10);
                    obj.reinitWithPreservedState();

                case "downarrow"
                    obj.TracerCount = max(10, obj.TracerCount - 10);
                    obj.reinitWithPreservedState();

                case "leftarrow"
                    levels = [0.25, 0.5, 1, 2, 3];
                    [~, idx] = min(abs(levels - obj.SpeedMult));
                    idx = max(1, idx - 1);
                    obj.SpeedMult = levels(idx);
                    if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                        obj.HudTextH.String = obj.buildHudString();
                    end

                case "rightarrow"
                    levels = [0.25, 0.5, 1, 2, 3];
                    [~, idx] = min(abs(levels - obj.SpeedMult));
                    idx = min(numel(levels), idx + 1);
                    obj.SpeedMult = levels(idx);
                    if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                        obj.HudTextH.String = obj.buildHudString();
                    end

                case "0"
                    % Reset particles to current sub-mode ICs
                    obj.State = zeros(3, 0);
                    obj.applySubMode();

                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return StrangeAttractors-specific results.
            r.Title = "STRANGE ATTRACTORS";
            r.Lines = {
                sprintf("Mode: %s  |  Particles: %d", obj.SubMode, obj.TracerCount)
            };
        end

    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function applySubMode(obj)
            %applySubMode  Set attractor parameters and re-seed particles.
            obj.FingerParam = NaN;
            obj.FingerParamY = NaN;
            N = size(obj.State, 2);
            if N == 0; N = obj.TracerCount; end
            switch obj.SubMode
                case "lorenz"
                    obj.Params = struct("sigma", 10, "rho", 28, "beta", 8/3);
                    obj.Dt = 0.005;
                    obj.SubSteps = 5;
                    % Spread particles across BOTH wings of the attractor
                    eq = sqrt(8/3 * 27);  % ~8.49
                    halfN = ceil(N / 2);
                    obj.State = zeros(3, N);
                    obj.State(1, 1:halfN) = -eq + randn(1, halfN) * 2;
                    obj.State(2, 1:halfN) = -eq + randn(1, halfN) * 2;
                    obj.State(3, 1:halfN) = 27 + randn(1, halfN) * 3;
                    obj.State(1, halfN+1:N) = eq + randn(1, N - halfN) * 2;
                    obj.State(2, halfN+1:N) = eq + randn(1, N - halfN) * 2;
                    obj.State(3, halfN+1:N) = 27 + randn(1, N - halfN) * 3;
                    obj.ProjBounds = [-25 25 0 55];
                case "rossler"
                    obj.Params = struct("a", 0.2, "b", 0.2, "c", 5.7);
                    obj.Dt = 0.005;
                    obj.SubSteps = 8;
                    obj.State = [randn(1, N) * 2; ...
                                 randn(1, N) * 2; ...
                                 randn(1, N) * 0.3];
                    obj.ProjBounds = [-15 15 -15 15];
                case "thomas"
                    obj.Params = struct("b", 0.19);
                    obj.Dt = 0.03;
                    obj.SubSteps = 8;
                    obj.State = [randn(1, N) * 1.5 + 1; ...
                                 randn(1, N) * 1.5 - 1; ...
                                 randn(1, N) * 1.5 + 1];
                    obj.ProjBounds = [-5 5 -5 5];
                case "aizawa"
                    obj.Params = struct("a", 0.95, "b", 0.7, "c", 0.6, ...
                                        "d", 3.5, "e", 0.25, "f", 0.1);
                    obj.Dt = 0.01;
                    obj.SubSteps = 6;
                    obj.State = [-0.78 + randn(1, N) * 0.05; ...
                                 -0.63 + randn(1, N) * 0.05; ...
                                 -0.18 + randn(1, N) * 0.03];
                    obj.ProjBounds = [-2 2 -1.5 2.5];
            end
            obj.TrailX = NaN(obj.TrailLen, N);
            obj.TrailY = NaN(obj.TrailLen, N);
            obj.TrailIdx = 0;
            obj.TrailCount = 0;
            obj.FrameCount = 0;
            if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                obj.HudTextH.String = obj.buildHudString();
            end
        end

        function reinitWithPreservedState(obj)
            %reinitWithPreservedState  Reinit graphics preserving mode settings.
            subMode = obj.SubMode;
            spdMul = obj.SpeedMult;
            fCtrl = obj.FingerControl;
            obj.onCleanup();
            obj.onInit(obj.Ax, obj.DisplayRange, struct());
            obj.SubMode = subMode;
            obj.SpeedMult = spdMul;
            obj.FingerControl = fCtrl;
            obj.applySubMode();
        end

        function dstate = computeDerivatives(obj, state)
            %computeDerivatives  ODE derivatives for all particles (vectorized).
            x = state(1, :);
            y = state(2, :);
            z = state(3, :);
            p = obj.Params;

            if obj.SubMode == "lorenz"
                % X -> rho (10-50), Y -> sigma (5-20)
                rho = p.rho;
                sigma = p.sigma;
                if ~isnan(obj.FingerParam)
                    rho = obj.FingerParam;
                end
                if ~isnan(obj.FingerParamY)
                    sigma = 5 + obj.FingerParamY * 15;
                end
                dstate = [sigma * (y - x); ...
                          x .* (rho - z) - y; ...
                          x .* y - p.beta * z];
            elseif obj.SubMode == "rossler"
                % X -> c (3-15), Y -> a (0.1-0.4)
                aVal = p.a; bVal = p.b; cVal = p.c;
                if ~isnan(obj.FingerParam)
                    cVal = obj.FingerParam * 0.3;
                end
                if ~isnan(obj.FingerParamY)
                    aVal = 0.1 + obj.FingerParamY * 0.3;
                end
                dstate = [-y - z; ...
                          x + aVal * y; ...
                          bVal + z .* (x - cVal)];
            elseif obj.SubMode == "thomas"
                % X -> b (0.10-0.30), no Y param (cyclic symmetry)
                bVal = p.b;
                if ~isnan(obj.FingerParam)
                    tFrac = (obj.FingerParam - 10) / 40;  % 0..1
                    bVal = 0.10 + tFrac * 0.20;
                end
                dstate = [sin(y) - bVal * x; ...
                          sin(z) - bVal * y; ...
                          sin(x) - bVal * z];
            elseif obj.SubMode == "aizawa"
                % X -> a (0.85-1.10), Y -> epsilon (0.1-0.5)
                aVal = p.a; bVal = p.b; cVal = p.c;
                dVal = p.d; eVal = p.e; fVal = p.f;
                if ~isnan(obj.FingerParam)
                    tFrac = (obj.FingerParam - 10) / 40;
                    aVal = 0.85 + tFrac * 0.25;
                end
                if ~isnan(obj.FingerParamY)
                    eVal = 0.1 + obj.FingerParamY * 0.4;
                end
                r2 = x.^2 + y.^2;
                dstate = [(z - bVal) .* x - dVal * y; ...
                          dVal * x + (z - bVal) .* y; ...
                          cVal + aVal * z - z.^3 / 3 ...
                              - r2 .* (1 + eVal * z) + fVal * z .* x.^3];
            else
                dstate = zeros(size(state));
            end
        end

        function state = respawnBadParticles(obj, state, bad)
            %respawnBadParticles  Reset diverged particles to attractor ICs.
            nBad = sum(bad);
            switch obj.SubMode
                case "lorenz"
                    eq = sqrt(8/3 * 27);
                    state(:, bad) = [eq + randn(1, nBad) * 2; ...
                                     eq + randn(1, nBad) * 2; ...
                                     27 + randn(1, nBad) * 3];
                case "rossler"
                    state(:, bad) = [randn(1, nBad) * 2; ...
                                     randn(1, nBad) * 2; ...
                                     randn(1, nBad) * 0.3];
                case "thomas"
                    state(:, bad) = [randn(1, nBad) * 1.5 + 1; ...
                                     randn(1, nBad) * 1.5 - 1; ...
                                     randn(1, nBad) * 1.5 + 1];
                case "aizawa"
                    state(:, bad) = [-0.78 + randn(1, nBad) * 0.05; ...
                                     -0.63 + randn(1, nBad) * 0.05; ...
                                     -0.18 + randn(1, nBad) * 0.03];
            end
        end

        function renderTrails(obj, N)
            %renderTrails  Render ribbon trail quads with per-vertex alpha.
            tLen = obj.TrailLen;
            tIdx = obj.TrailIdx;
            trailOrd = mod((tIdx:tIdx + tLen - 1), tLen) + 1;
            ribbonHW = 0.2;  % ribbon half-width in data units

            for k = 1:N
                if numel(obj.TrailH) < k || ~isvalid(obj.TrailH(k))
                    continue;
                end
                tx = obj.TrailX(trailOrd, k);
                ty = obj.TrailY(trailOrd, k);
                validMask = ~isnan(tx);
                nValid = sum(validMask);
                if nValid < 3
                    set(obj.TrailH(k), ...
                        "Vertices", [NaN NaN], "Faces", 1, ...
                        "FaceVertexCData", [0 0 0], ...
                        "FaceVertexAlphaData", 0);
                    continue;
                end
                txv = tx(validMask);
                tyv = ty(validMask);
                nPts = numel(txv);

                % Light moving-average smoothing (window 5) to soften
                % sharp corners. Keep last 3 points raw so trail head
                % stays exactly superimposed on the tracer dot.
                if nPts >= 8
                    nSmooth = nPts - 3;
                    txv(1:nSmooth) = movmean(txv(1:nSmooth), 5);
                    tyv(1:nSmooth) = movmean(tyv(1:nSmooth), 5);
                end

                % Smooth normals: average adjacent segment normals to
                % prevent ribbon twist/kink at sharp direction changes
                ddx = diff(txv);
                ddy = diff(tyv);
                segLen = sqrt(ddx.^2 + ddy.^2);
                segLen(segLen < 1e-10) = 1e-10;
                snx = -ddy ./ segLen;
                sny = ddx ./ segLen;
                % Average consecutive normals at interior vertices
                nx = zeros(nPts, 1);
                ny = zeros(nPts, 1);
                nx(1) = snx(1);  ny(1) = sny(1);
                nx(end) = snx(end);  ny(end) = sny(end);
                for j = 2:nPts-1
                    mx = snx(j-1) + snx(j);
                    my = sny(j-1) + sny(j);
                    mLen = sqrt(mx^2 + my^2);
                    if mLen < 1e-10
                        nx(j) = snx(j);  ny(j) = sny(j);
                    else
                        nx(j) = mx / mLen;  ny(j) = my / mLen;
                    end
                end

                % Left and right ribbon boundaries
                lx = txv + nx * ribbonHW;
                ly = tyv + ny * ribbonHW;
                rx = txv - nx * ribbonHW;
                ry = tyv - ny * ribbonHW;

                % Vertices: [left; right] (2*nPts x 2)
                verts = [lx, ly; rx, ry];

                % Faces: quads [leftI, leftI+1, rightI+1, rightI]
                ii = (1:nPts - 1)';
                faces = [ii, ii + 1, ii + 1 + nPts, ii + nPts];

                % Per-vertex alpha: 0 at tail, 0.5 at head (same L and R)
                alphaPerPt = linspace(0, 0.5, nPts)';
                alphaVerts = [alphaPerPt; alphaPerPt];

                % Per-vertex color (constant hue)
                [rr, gg, bb] = GameBase.hsvToRgb(obj.Hues(k));
                cdataVerts = repmat([rr, gg, bb], 2 * nPts, 1);

                set(obj.TrailH(k), "Vertices", verts, "Faces", faces, ...
                    "FaceVertexCData", cdataVerts, ...
                    "FaceVertexAlphaData", alphaVerts);
            end
        end

        function s = buildHudString(obj)
            %buildHudString  Build HUD label string for current state.
            ctrlStr = "ON";
            if ~obj.FingerControl; ctrlStr = "OFF"; end
            if mod(obj.SpeedMult, 1) == 0
                spdStr = sprintf("%dx", obj.SpeedMult);
            else
                spdStr = sprintf("%.1fx", obj.SpeedMult);
            end
            s = upper(obj.SubMode) + " [M]  |  CONTROL " + ...
                ctrlStr + " [N]  |  Tracers = " + ...
                obj.TracerCount + " [" + char(8593) + char(8595) + ...
                "]  |  Speed = " + spdStr + " [" + ...
                char(8592) + char(8594) + ...
                "]  |  " + obj.buildParamString() + ...
                "  |  0 = Reset";
        end

        function s = buildParamString(obj)
            %buildParamString  Current attractor parameter names and values.
            switch obj.SubMode
                case "lorenz"
                    if ~isnan(obj.FingerParam)
                        rhoVal = obj.FingerParam;
                    else
                        rhoVal = obj.Params.rho;
                    end
                    if ~isnan(obj.FingerParamY)
                        sigVal = 5 + obj.FingerParamY * 15;
                    else
                        sigVal = obj.Params.sigma;
                    end
                    s = sprintf("%s=%.1f  %s=%.1f", ...
                        char(961), rhoVal, char(963), sigVal);
                case "rossler"
                    if ~isnan(obj.FingerParam)
                        cVal = obj.FingerParam * 0.3;
                    else
                        cVal = obj.Params.c;
                    end
                    if ~isnan(obj.FingerParamY)
                        aVal = 0.1 + obj.FingerParamY * 0.3;
                    else
                        aVal = obj.Params.a;
                    end
                    s = sprintf("c=%.2f  a=%.2f", cVal, aVal);
                case "thomas"
                    if ~isnan(obj.FingerParam)
                        tFrac = (obj.FingerParam - 10) / 40;
                        bVal = 0.10 + tFrac * 0.20;
                    else
                        bVal = obj.Params.b;
                    end
                    s = sprintf("b=%.3f", bVal);
                case "aizawa"
                    if ~isnan(obj.FingerParam)
                        tFrac = (obj.FingerParam - 10) / 40;
                        aVal = 0.85 + tFrac * 0.25;
                    else
                        aVal = obj.Params.a;
                    end
                    if ~isnan(obj.FingerParamY)
                        eVal = 0.1 + obj.FingerParamY * 0.4;
                    else
                        eVal = obj.Params.e;
                    end
                    s = sprintf("a=%.2f  %s=%.2f", ...
                        aVal, char(949), eVal);
                otherwise
                    s = "";
            end
            s = string(s);
        end
    end
end
