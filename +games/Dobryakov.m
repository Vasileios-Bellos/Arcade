classdef Dobryakov < GameBase
    %Dobryakov  Enhanced Stam stable-fluids sim with bloom and multi-splat.
    %   Dobryakov-style fluid visualization with heavy two-pass bloom,
    %   multi-color dye injection, vorticity confinement, and 5 render
    %   sub-modes (flow, velocity, vorticity, curl, pressure).
    %
    %   Standalone: games.Dobryakov().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost, games.FluidUtils

    properties (Constant)
        Name = "Dobryakov"
    end

    % =================================================================
    % GRID & PHYSICS PARAMETERS
    % =================================================================
    properties (Access = private)
        GridLevel       (1,1) double = 7      % resolution level 1-10
        GridW           (1,1) double = 80
        GridH           (1,1) double = 80
        SplatRadius     (1,1) double = 2.0    % splat radius (grid cells)
        ForceStrength   (1,1) double = 200    % force multiplier
        VortEps         (1,1) double = 2.5    % vorticity confinement strength
        DyeRate         (1,1) double = 8.0    % dye injection rate
        DyeDecay        (1,1) double = 0.002  % per-frame dye decay
        Dt              (1,1) double = 0.1    % time step
    end

    % =================================================================
    % FLUID STATE
    % =================================================================
    properties (Access = private)
        U               (:,:) double          % horizontal velocity
        V               (:,:) double          % vertical velocity
        DyeR            (:,:) double          % red dye channel
        DyeG            (:,:) double          % green dye channel
        DyeB            (:,:) double          % blue dye channel
        Pressure        (:,:) double          % pressure field (for display)
        Eigvals         (:,:) double          % FFT Poisson eigenvalues
        MeshX           (:,:) double          % meshgrid X
        MeshY           (:,:) double          % meshgrid Y
    end

    % =================================================================
    % FINGER / TRACKING STATE
    % =================================================================
    properties (Access = private)
        PrevFingerX     (1,1) double = NaN
        PrevFingerY     (1,1) double = NaN
        SplatHue        (1,1) double = 0      % cycling hue for splats
        FrameCount      (1,1) double = 0
    end

    % =================================================================
    % SUB-MODE & INJECTION
    % =================================================================
    properties (Access = private)
        SubMode         (1,1) string = "flow"   % flow|velocity|vorticity|curl|pressure
        InjMode         (1,1) string = "dye"    % dye|fire|rainbow|colormap
        ColormapIdx     (1,1) double = 1        % index into lbmColormapNames
        ColormapRGB     (256,3) double = zeros(256, 3)  % cached colormap
    end

    % =================================================================
    % STATISTICS
    % =================================================================
    properties (Access = private)
        TotalDyeInjected (1,1) double = 0
        PeakVorticity    (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ImageH                                % image object for fluid rendering
        ModeTextH                             % text label for HUD
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create fluid grid, image overlay, and HUD label.
            arguments
                obj
                ax
                displayRange    struct
                ~
            end
            obj.Ax = ax;
            obj.DisplayRange = displayRange;
            obj.Score = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;

            dxRange = displayRange.X;
            dyRange = displayRange.Y;

            % Apply grid level -> visible resolution + splat radius
            gridSizes = [20, 30, 40, 60, 80, 100, 112, 128, 144, 176];
            splatRadii = [5.0, 4.5, 4.0, 3.5, 3.0, 2.5, 2.2, 2.0, 1.8, 1.5];
            lvl = obj.GridLevel;
            obj.GridW = gridSizes(lvl);
            obj.GridH = gridSizes(lvl);
            obj.SplatRadius = splatRadii(lvl);

            % Add ghost cells (2 per side)
            ghost = 2;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;

            % Initialize fields (full grid including ghost)
            obj.U = zeros(Ny, Nx);
            obj.V = zeros(Ny, Nx);
            obj.DyeR = zeros(Ny, Nx);
            obj.DyeG = zeros(Ny, Nx);
            obj.DyeB = zeros(Ny, Nx);
            obj.Pressure = zeros(Ny, Nx);

            % Precompute meshgrid
            [obj.MeshX, obj.MeshY] = meshgrid(1:Nx, 1:Ny);

            % FFT Poisson eigenvalues
            [ii, jj] = meshgrid(0:Nx-1, 0:Ny-1);
            ev = -4 + 2 * cos(2 * pi * ii / Nx) + 2 * cos(2 * pi * jj / Ny);
            ev(1, 1) = 1;
            obj.Eigvals = ev;

            % State
            obj.TotalDyeInjected = 0;
            obj.PeakVorticity = 0;
            obj.FrameCount = 0;
            obj.PrevFingerX = NaN;
            obj.PrevFingerY = NaN;
            obj.SplatHue = 0;
            obj.SubMode = "flow";

            % Image shows only visible interior (no ghost cells)
            visNy = obj.GridH;
            visNx = obj.GridW;
            blackFrame = zeros(visNy, visNx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", blackFrame, "AlphaData", zeros(visNy, visNx), ...
                "AlphaDataMapping", "none", "Interpolation", "bilinear", ...
                "Tag", "GT_dobryakov");
            % Just above camera feed, below all UI overlays
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");

            % HUD label
            obj.ModeTextH = text(ax, dxRange(1) + 5, dyRange(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_dobryakov");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame fluid physics, dye injection, and rendering.
            if isempty(obj.U); return; end

            ghost = 2;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;
            dt = obj.Dt;
            u = obj.U;
            v = obj.V;
            dyeR = obj.DyeR;
            dyeG = obj.DyeG;
            dyeB = obj.DyeB;
            X = obj.MeshX;
            Y = obj.MeshY;
            splatR = obj.SplatRadius;

            obj.FrameCount = obj.FrameCount + 1;
            fc = obj.FrameCount;

            % --- Map finger to interior grid ---
            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;
            fingerGridX = NaN;
            fingerGridY = NaN;
            fingerVelX = 0;
            fingerVelY = 0;
            hasFinger = ~isempty(pos) && all(~isnan(pos));

            if hasFinger
                fingerGridX = ghost + 1 + (pos(1) - dxRange(1)) ...
                    / diff(dxRange) * (obj.GridW - 1);
                fingerGridY = ghost + 1 + (pos(2) - dyRange(1)) ...
                    / diff(dyRange) * (obj.GridH - 1);
                fingerGridX = max(ghost + 1, min(Nx - ghost, fingerGridX));
                fingerGridY = max(ghost + 1, min(Ny - ghost, fingerGridY));

                if ~isnan(obj.PrevFingerX)
                    fingerVelX = fingerGridX - obj.PrevFingerX;
                    fingerVelY = fingerGridY - obj.PrevFingerY;
                end
                obj.PrevFingerX = fingerGridX;
                obj.PrevFingerY = fingerGridY;
            end

            % === STEP 1a: Finger multi-color splat ===
            fingerSpeed = sqrt(fingerVelX^2 + fingerVelY^2);
            if hasFinger && fingerSpeed > 0.1
                gauss = exp(-((X - fingerGridX).^2 + (Y - fingerGridY).^2) ...
                    / (2 * splatR^2));

                % Velocity injection
                u = u + dt * obj.ForceStrength * fingerVelX * gauss;
                v = v + dt * obj.ForceStrength * fingerVelY * gauss;

                % Multi-color dye: center + 2 perpendicular offset splats
                obj.SplatHue = obj.SplatHue + 0.012;
                hue = obj.SplatHue;
                splatAmt = min(fingerSpeed, 10) * obj.DyeRate;
                perpX = -fingerVelY / (fingerSpeed + 0.01);
                perpY = fingerVelX / (fingerSpeed + 0.01);

                for s = 1:3
                    offX = [0, perpX * 2.5, -perpX * 2.5];
                    offY = [0, perpY * 2.5, -perpY * 2.5];
                    gx = fingerGridX + offX(s);
                    gy = fingerGridY + offY(s);
                    if gx < 1 || gx > Nx || gy < 1 || gy > Ny; continue; end

                    g = exp(-((X - gx).^2 + (Y - gy).^2) / (2 * splatR^2));
                    [cr, cg, cb] = obj.computeSplatColor(hue, s, fc);
                    amt = splatAmt * g * (1 - 0.25 * (s > 1));
                    dyeR = dyeR + amt * cr;
                    dyeG = dyeG + amt * cg;
                    dyeB = dyeB + amt * cb;
                end
                obj.TotalDyeInjected = obj.TotalDyeInjected + splatAmt * 3;
            end

            % === STEP 2: Strong vorticity confinement (non-wrapping) ===
            vorticityEps = obj.VortEps;
            dvdx = zeros(Ny, Nx); dudy = zeros(Ny, Nx);
            dvdx(:, 2:end-1) = (v(:, 3:end) - v(:, 1:end-2)) * 0.5;
            dudy(2:end-1, :) = (u(3:end, :) - u(1:end-2, :)) * 0.5;
            omega = dvdx - dudy;
            absW = abs(omega);
            dWdx = zeros(Ny, Nx); dWdy = zeros(Ny, Nx);
            dWdx(:, 2:end-1) = (absW(:, 3:end) - absW(:, 1:end-2)) * 0.5;
            dWdy(2:end-1, :) = (absW(3:end, :) - absW(1:end-2, :)) * 0.5;
            lenW = sqrt(dWdx.^2 + dWdy.^2) + 1e-10;
            u = u + dt * vorticityEps * (dWdy ./ lenW) .* omega;
            v = v + dt * vorticityEps * (-dWdx ./ lenW) .* omega;
            peakW = max(abs(omega(:)));
            obj.PeakVorticity = max(obj.PeakVorticity, peakW);

            % === STEP 3: Advect velocity ===
            u = games.FluidUtils.fldAdvect(u, u, v, dt, X, Y, Ny, Nx);
            v = games.FluidUtils.fldAdvect(v, u, v, dt, X, Y, Ny, Nx);

            % === STEP 4: Project ===
            [u, v] = games.FluidUtils.fldProject(u, v, obj.Eigvals, Nx, Ny);

            % Store pressure for display (non-wrapping divergence)
            dudxP = zeros(Ny, Nx); dvdyP = zeros(Ny, Nx);
            dudxP(:, 2:end) = u(:, 2:end) - u(:, 1:end-1);
            dvdyP(2:end, :) = v(2:end, :) - v(1:end-1, :);
            divField = dudxP + dvdyP;
            pHat = fft2(divField) ./ obj.Eigvals;
            pHat(1, 1) = 0;
            obj.Pressure = real(ifft2(pHat));

            % === STEP 5: Free-slip boundary + velocity damping ===
            u(:, 1) = 0; u(:, end) = 0;
            v(1, :) = 0; v(end, :) = 0;
            dsF = obj.DtScale;
            u = u * 0.998^dsF;
            v = v * 0.998^dsF;

            % === STEP 6: Advect dye ===
            dyeR = games.FluidUtils.fldAdvect(dyeR, u, v, dt, X, Y, Ny, Nx);
            dyeG = games.FluidUtils.fldAdvect(dyeG, u, v, dt, X, Y, Ny, Nx);
            dyeB = games.FluidUtils.fldAdvect(dyeB, u, v, dt, X, Y, Ny, Nx);

            % Slower decay for richer color buildup (frame-rate scaled)
            decayFactor = (1 - obj.DyeDecay)^dsF;
            dyeR = max(0, min(1, dyeR * decayFactor));
            dyeG = max(0, min(1, dyeG * decayFactor));
            dyeB = max(0, min(1, dyeB * decayFactor));

            % Store
            obj.U = u;
            obj.V = v;
            obj.DyeR = dyeR;
            obj.DyeG = dyeG;
            obj.DyeB = dyeB;

            % === STEP 7: Render ===
            obj.renderFluid(u, v, dyeR, dyeG, dyeB, fc, Ny, Nx, ghost);

            % === SCORING ===
            totalKE = sum(u(:).^2 + v(:).^2) * 0.5;
            if totalKE > 5
                obj.Score = obj.Score + round(min(50, totalKE * 0.5) ...
                    * max(1, obj.Combo * 0.1));
            end
            if peakW > 10
                obj.Score = obj.Score + round(peakW * 0.2 ...
                    * max(1, obj.Combo * 0.1));
            end
            coveredCells = nnz((dyeR + dyeG + dyeB) > 0.1);
            if coveredCells > Nx * Ny * 0.2
                obj.Score = obj.Score + round(coveredCells * 0.02);
            end
            if hasFinger && fingerSpeed > 0.5
                if obj.Combo == 0; obj.Combo = 1; end
                if mod(fc, 30) == 0
                    obj.incrementCombo();
                end
            else
                if mod(fc, 60) == 0 && obj.Combo > 0
                    obj.Combo = max(0, obj.Combo - 1);
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all graphics and release state.
            handles = {obj.ImageH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.ImageH = [];
            obj.ModeTextH = [];
            obj.U = [];
            obj.V = [];
            obj.DyeR = [];
            obj.DyeG = [];
            obj.DyeB = [];
            obj.Pressure = [];
            obj.Eigvals = [];
            obj.MeshX = [];
            obj.MeshY = [];
            obj.PrevFingerX = NaN;
            obj.PrevFingerY = NaN;
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_dobryakov");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["flow", "velocity", "vorticity", "curl", "pressure"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.updateHudLabel();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle Dobryakov-specific keys.
            handled = true;
            switch key
                case "m"
                    % Cycle sub-mode: flow -> velocity -> vorticity -> curl -> pressure
                    modes = ["flow", "velocity", "vorticity", "curl", "pressure"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.updateHudLabel();

                case "n"
                    % Cycle injection mode: dye -> fire -> rainbow -> colormap
                    injModes = ["dye", "fire", "rainbow", "colormap"];
                    idx = find(injModes == obj.InjMode, 1);
                    obj.InjMode = injModes(mod(idx, numel(injModes)) + 1);
                    if obj.InjMode == "colormap"
                        obj.loadColormap();
                    end
                    % Clear dye on injection mode change
                    ghost = 2;
                    Ny = obj.GridH + 2 * ghost;
                    Nx = obj.GridW + 2 * ghost;
                    obj.DyeR = zeros(Ny, Nx);
                    obj.DyeG = zeros(Ny, Nx);
                    obj.DyeB = zeros(Ny, Nx);
                    obj.updateHudLabel();

                case {"uparrow", "downarrow"}
                    obj.changeGridLevel(key);

                case {"leftarrow", "rightarrow"}
                    obj.changeSplatScale(key);

                case {"shift+leftarrow", "shift+rightarrow"}
                    if obj.InjMode == "colormap"
                        names = GameBase.lbmColormapNames();
                        n = numel(names);
                        if key == "shift+rightarrow"
                            obj.ColormapIdx = mod(obj.ColormapIdx, n) + 1;
                        else
                            obj.ColormapIdx = mod(obj.ColormapIdx - 2, n) + 1;
                        end
                        obj.loadColormap();
                        obj.updateHudLabel();
                    else
                        handled = false;
                    end

                case "0"
                    % Reset fluid state (keep grid level)
                    savedMode = obj.SubMode;
                    savedInj = obj.InjMode;
                    obj.onCleanup();
                    obj.onInit(obj.Ax, obj.DisplayRange, struct());
                    obj.SubMode = savedMode;
                    obj.InjMode = savedInj;
                    obj.updateHudLabel();

                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return Dobryakov-specific results.
            r.Title = "DOBRYAKOV FLUID";
            elapsed = toc(obj.StartTic);
            r.Lines = {
                sprintf("Dye Injected: %.0f  |  Peak Vorticity: %.1f  |  Score: %d  |  Time: %.0fs", ...
                    obj.TotalDyeInjected, obj.PeakVorticity, obj.Score, elapsed)
            };
        end

    end

    % =================================================================
    % PRIVATE HELPERS
    % =================================================================
    methods (Access = private)

        function [cr, cg, cb] = computeSplatColor(obj, hue, splatIdx, fc)
            %computeSplatColor  Compute RGB for a single splat based on injection mode.
            switch obj.InjMode
                case "fire"
                    cr = 1.0; cg = 0.45; cb = 0.05;
                case "rainbow"
                    param = 1 - abs(mod(fc * 0.04 * 0.7, 2) - 1);
                    rainbowH = [0, 30, 60, 120, 240, 275, 300] / 360;
                    hueS = interp1(linspace(0, 1, 7), rainbowH, param);
                    hueS = mod(hueS + (splatIdx - 1) * 1/7, 1);
                    [cr, cg, cb] = GameBase.hsvToRgb(hueS);
                case "colormap"
                    cmRaw = mod(floor(fc * 20) + (splatIdx - 1) * 30, 510);
                    cmI = (cmRaw < 256) * cmRaw + (cmRaw >= 256) * (510 - cmRaw) + 1;
                    cmap = obj.ColormapRGB;
                    cr = cmap(cmI, 1);
                    cg = cmap(cmI, 2);
                    cb = cmap(cmI, 3);
                otherwise  % "dye"
                    [cr, cg, cb] = GameBase.hsvToRgb( ...
                        mod(hue + (splatIdx - 1) * 0.33, 1));
            end
        end

        function renderFluid(obj, u, v, dyeR, dyeG, dyeB, fc, Ny, Nx, ghost)
            %renderFluid  Compute display RGB from fluid state and update image.
            if isempty(obj.ImageH) || ~isvalid(obj.ImageH); return; end

            switch obj.SubMode
                case "flow"
                    if obj.InjMode == "fire"
                        % Fire colormap: black -> red -> orange -> yellow
                        density = min(1, max(dyeR, max(dyeG, dyeB)) * 4.5);
                        displayR = min(1, density * 2.5);
                        displayG = min(1, max(0, (density - 0.25) * 1.8));
                        displayB = min(1, max(0, (density - 0.6) * 2.0));
                        bloom = imgaussfilt(density, 2.0) * 0.3;
                        displayR = min(1, displayR + bloom);
                        displayG = min(1, displayG + bloom * 0.4);
                        displayB = min(1, displayB + bloom * 0.1);
                    else
                        % Heavy two-pass bloom (Dobryakov signature)
                        dR = min(1, dyeR * 4.5);
                        dG = min(1, dyeG * 4.5);
                        dB = min(1, dyeB * 4.5);
                        g1R = imgaussfilt(dR, 1.5);
                        g1G = imgaussfilt(dG, 1.5);
                        g1B = imgaussfilt(dB, 1.5);
                        g2R = imgaussfilt(dR, 4.0);
                        g2G = imgaussfilt(dG, 4.0);
                        g2B = imgaussfilt(dB, 4.0);
                        displayR = min(1, dR * 0.45 + g1R * 0.35 + g2R * 0.3);
                        displayG = min(1, dG * 0.45 + g1G * 0.35 + g2G * 0.3);
                        displayB = min(1, dB * 0.45 + g1B * 0.35 + g2B * 0.3);
                    end

                case "pressure"
                    % Pressure: cyan/magenta diverging + dye overlay
                    p = obj.Pressure;
                    normP = max(-1, min(1, p / 5.0));
                    intensity = abs(normP);
                    displayR = intensity .* (normP < 0) * 0.9 + ...
                               min(1, dyeR * 2.5) * 0.4;
                    displayG = intensity * 0.15 + ...
                               min(1, dyeG * 2.5) * 0.4;
                    displayB = intensity .* (normP > 0) * 0.9 + ...
                               intensity .* (normP < 0) * 0.4 + ...
                               min(1, dyeB * 2.5) * 0.4;
                    displayR = min(1, displayR + imgaussfilt(displayR, 2.0) * 0.3);
                    displayG = min(1, displayG + imgaussfilt(displayG, 2.0) * 0.3);
                    displayB = min(1, displayB + imgaussfilt(displayB, 2.0) * 0.3);

                case "velocity"
                    % Speed magnitude: cyan -> gold -> red (fixed scale)
                    spd = sqrt(u.^2 + v.^2);
                    normS = min(1, spd / 15.0);
                    displayR = min(1, normS * 2.0);
                    displayG = min(1, normS * 1.5) .* (1 - max(0, normS - 0.6) * 2.5);
                    displayB = max(0, 1 - normS * 2.0);
                    displayR = min(1, displayR + imgaussfilt(displayR, 1.5) * 0.3);
                    displayG = min(1, displayG + imgaussfilt(displayG, 1.5) * 0.3);
                    displayB = min(1, displayB + imgaussfilt(displayB, 1.5) * 0.3);

                case "vorticity"
                    % Dye smoke colored red/blue by curl sign
                    dvdx2 = zeros(Ny, Nx); dudy2 = zeros(Ny, Nx);
                    dvdx2(:, 2:end-1) = (v(:, 3:end) - v(:, 1:end-2)) * 0.5;
                    dudy2(2:end-1, :) = (u(3:end, :) - u(1:end-2, :)) * 0.5;
                    omegaFull = dvdx2 - dudy2;
                    normW = max(-1, min(1, omegaFull / 5.0));
                    dyeI = min(1, (dyeR + dyeG + dyeB) * 3.0);
                    displayR = dyeI .* max(0, -normW);
                    displayG = zeros(Ny, Nx);
                    displayB = dyeI .* max(0, normW);
                    displayR = min(1, displayR + imgaussfilt(displayR, 1.5) * 0.4);
                    displayG = min(1, displayG + imgaussfilt(displayG, 1.5) * 0.4);
                    displayB = min(1, displayB + imgaussfilt(displayB, 1.5) * 0.4);

                case "curl"
                    % Curl-based sine modulation of dye (organic veining)
                    dvdx2 = zeros(Ny, Nx); dudy2 = zeros(Ny, Nx);
                    dvdx2(:, 2:end-1) = (v(:, 3:end) - v(:, 1:end-2)) * 0.5;
                    dudy2(2:end-1, :) = (u(3:end, :) - u(1:end-2, :)) * 0.5;
                    curlMag = abs(dvdx2 - dudy2);
                    normC = min(1, curlMag / 8.0);
                    phase = fc * 0.02;
                    dR = dyeR .* (0.6 + 0.4 * sin(normC * 6 + phase));
                    dG = dyeG .* (0.6 + 0.4 * sin(normC * 6 + phase + 2.1));
                    dB = dyeB .* (0.6 + 0.4 * sin(normC * 6 + phase + 4.2));
                    vein = min(1, normC * 2.0);
                    dR = min(1, dR * 3.5 + vein * 0.15);
                    dG = min(1, dG * 3.5 + vein * 0.08);
                    dB = min(1, dB * 3.5 + vein * 0.2);
                    displayR = min(1, dR + imgaussfilt(dR, 2.0) * 0.3);
                    displayG = min(1, dG + imgaussfilt(dG, 2.0) * 0.3);
                    displayB = min(1, dB + imgaussfilt(dB, 2.0) * 0.3);
            end

            % Extract visible interior (skip ghost cells)
            g = ghost;
            visR = displayR(g+1:end-g, g+1:end-g);
            visG = displayG(g+1:end-g, g+1:end-g);
            visB = displayB(g+1:end-g, g+1:end-g);

            % Compose CData + AlphaData (transparent where no dye)
            rgbData = cat(3, visR, visG, visB);
            obj.ImageH.CData = uint8(rgbData * 255);
            alphaData = min(0.92, max(visR, max(visG, visB)) * 1.8);
            obj.ImageH.AlphaData = alphaData;
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Change grid resolution (up/down arrow).
            oldLevel = obj.GridLevel;
            if key == "uparrow"
                obj.GridLevel = min(10, oldLevel + 1);
            else
                obj.GridLevel = max(1, oldLevel - 1);
            end
            if obj.GridLevel == oldLevel; return; end
            savedMode = obj.SubMode;
            savedInj = obj.InjMode;
            savedCmIdx = obj.ColormapIdx;
            savedCmRGB = obj.ColormapRGB;
            obj.onCleanup();
            obj.onInit(obj.Ax, obj.DisplayRange, struct());
            obj.SubMode = savedMode;
            obj.InjMode = savedInj;
            obj.ColormapIdx = savedCmIdx;
            obj.ColormapRGB = savedCmRGB;
            obj.updateHudLabel();
        end

        function changeSplatScale(obj, key)
            %changeSplatScale  Change splat/feature scale (left/right arrow).
            step = 0.3;
            if key == "rightarrow"
                obj.SplatRadius = min(8, obj.SplatRadius + step);
            else
                obj.SplatRadius = max(1, obj.SplatRadius - step);
            end
            obj.updateHudLabel();
        end

        function loadColormap(obj)
            %loadColormap  Cache colormap RGB from current ColormapIdx.
            names = GameBase.lbmColormapNames();
            idx = max(1, min(numel(names), obj.ColormapIdx));
            cmName = names(idx);
            try
                obj.ColormapRGB = feval(cmName, 256);
            catch
                obj.ColormapRGB = jet(256);
            end
        end

        function updateHudLabel(obj)
            %updateHudLabel  Refresh the mode text display.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

        function s = buildHudString(obj)
            %buildHudString  Compose the HUD label from current state.
            if obj.InjMode == "colormap"
                names = GameBase.lbmColormapNames();
                cmIdx = max(1, min(numel(names), obj.ColormapIdx));
                injLabel = upper(names(cmIdx)) + " [S" + char(8592) + char(8594) + "]";
            else
                injLabel = upper(obj.InjMode);
            end
            s = upper(obj.SubMode) + ...
                " [M]  |  " + injLabel + " [N]  |  Grid " + ...
                obj.GridLevel + "/10 [" + char(8593) + char(8595) + ...
                "]  |  Vol " + sprintf("%.1f", obj.SplatRadius) + ...
                " [" + char(8592) + char(8594) + "]";
        end
    end
end
