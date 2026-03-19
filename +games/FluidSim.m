classdef FluidSim < GameBase
    %FluidSim  Stam stable-fluids interactive dye simulation.
    %   FFT Poisson pressure projection, semi-Lagrangian advection,
    %   vorticity confinement, RGB dye with cycling hue injection.
    %   Ghost cells (2 per side) hide boundary dead zones.
    %
    %   TODO: Test GPU acceleration (gpuArray) at high grid levels (8-10).
    %   GPU crossover measured at ~640x568 on RTX 3070 Ti. At level 10
    %   (160x120 grid), FFT + advection may benefit. Code reference in
    %   GestureMouse_current.m backup. Also applies to Dobryakov, Smoke, Fire.
    %
    %   Controls:
    %       M               — cycle sub-mode (flow/velocity/vorticity/curl/pressure)
    %       N               — cycle injection mode (dye/fire/rainbow/colormap)
    %       Up / Down       — grid resolution (10 levels)
    %       Left / Right    — splat radius
    %       Shift+Left/Right — cycle colormap (when injection = colormap)
    %
    %   Standalone: games.FluidSim().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also games.FluidUtils, GameBase, GameHost

    properties (Constant)
        Name = "Fluid Sim"
    end

    % =================================================================
    % GRID LEVEL TABLES (Constant)
    % =================================================================
    properties (Access = private, Constant)
        GridSizes   = [16, 24, 32, 48, 64, 80, 96, 112, 128, 160]
        SplatRadiiTable = [4.5, 4.0, 3.5, 3.0, 2.5, 2.2, 2.0, 1.8, 1.5, 1.2]
        GhostCells  (1,1) double = 2
    end

    % =================================================================
    % SIMULATION PARAMETERS
    % =================================================================
    properties (Access = private)
        GridLevel       (1,1) double = 7
        GridW           (1,1) double = 64
        GridH           (1,1) double = 64
        SplatRadius     (1,1) double = 2.0
        ForceStrength   (1,1) double = 150
        VortEps         (1,1) double = 1.5      % vorticity confinement strength
        DyeRate         (1,1) double = 6.0
        DyeDecay        (1,1) double = 0.003
        Dt              (1,1) double = 0.1       % simulation time step
    end

    % =================================================================
    % SIMULATION STATE
    % =================================================================
    properties (Access = private)
        U               (:,:) double             % horizontal velocity field
        V               (:,:) double             % vertical velocity field
        DyeR            (:,:) double             % red dye channel
        DyeG            (:,:) double             % green dye channel
        DyeB            (:,:) double             % blue dye channel
        Eigvals         (:,:) double             % precomputed FFT Poisson eigenvalues
        MeshX           (:,:) double             % meshgrid X (precomputed)
        MeshY           (:,:) double             % meshgrid Y (precomputed)
        PressureField   (:,:) double             % pressure field for display
        PrevFingerX     (1,1) double = NaN
        PrevFingerY     (1,1) double = NaN
        FrameCount      (1,1) double = 0
        SubMode         (1,1) string = "flow"    % flow|velocity|vorticity|curl|pressure
        InjMode         (1,1) string = "dye"     % dye|fire|rainbow|colormap
        ColormapIdx     (1,1) double = 1
        ColormapRGB     (256,3) double = zeros(256, 3)
        TotalDyeInjected (1,1) double = 0
        PeakVorticity   (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ImageH                                    % image object
        ModeTextH                                 % text -- sub-mode label
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create fluid grid, precompute FFT eigenvalues, create image.
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

            obj.buildGrid();
            obj.createGraphics();
        end

        function onUpdate(obj, pos)
            %onUpdate  Full per-frame fluid simulation + rendering.
            if isempty(obj.U); return; end

            ghost = obj.GhostCells;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;
            dt = obj.Dt;
            u = obj.U;
            v = obj.V;
            dyeR = obj.DyeR;
            dyeG = obj.DyeG;
            dyeB = obj.DyeB;
            gX = obj.MeshX;
            gY = obj.MeshY;

            obj.FrameCount = obj.FrameCount + 1;

            % --- Map finger to grid coordinates ---
            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;
            fingerGridX = NaN;
            fingerGridY = NaN;
            fingerVelX = 0;
            fingerVelY = 0;
            hasFinger = ~isempty(pos) && all(~isnan(pos));

            if hasFinger
                fingerGridX = ghost + 1 + (pos(1) - dxRange(1)) ...
                    / (dxRange(2) - dxRange(1)) * (obj.GridW - 1);
                fingerGridY = ghost + 1 + (pos(2) - dyRange(1)) ...
                    / (dyRange(2) - dyRange(1)) * (obj.GridH - 1);
                fingerGridX = max(ghost + 1, min(Nx - ghost, fingerGridX));
                fingerGridY = max(ghost + 1, min(Ny - ghost, fingerGridY));

                if ~isnan(obj.PrevFingerX)
                    fingerVelX = fingerGridX - obj.PrevFingerX;
                    fingerVelY = fingerGridY - obj.PrevFingerY;
                end
                obj.PrevFingerX = fingerGridX;
                obj.PrevFingerY = fingerGridY;
            end

            % === STEP 1: Add forces (Gaussian splat) ===
            fingerSpeed = sqrt(fingerVelX^2 + fingerVelY^2);
            if hasFinger && fingerSpeed > 0.1
                distSqX = (gX - fingerGridX).^2;
                distSqY = (gY - fingerGridY).^2;
                gauss = exp(-(distSqX + distSqY) / (2 * obj.SplatRadius^2));

                % Velocity injection
                u = u + dt * obj.ForceStrength * fingerVelX * gauss;
                v = v + dt * obj.ForceStrength * fingerVelY * gauss;

                % Dye injection
                frameIdx = obj.FrameCount;
                dyeAmount = min(fingerSpeed, 8) * obj.DyeRate * gauss;
                dyeColorMean = 0;
                switch obj.InjMode
                    case "fire"
                        dyeR = dyeR + dyeAmount * 1.0;
                        dyeG = dyeG + dyeAmount * 0.45;
                        dyeB = dyeB + dyeAmount * 0.05;
                        dyeColorMean = 0.5;
                    case "rainbow"
                        param = 1 - abs(mod(frameIdx * 0.04 * 0.7, 2) - 1);
                        rainbowH = [0, 30, 60, 120, 240, 275, 300] / 360;
                        hueF = interp1(linspace(0, 1, 7), rainbowH, param);
                        [cr, cg, cb] = GameBase.hsvToRgb(hueF);
                        dyeR = dyeR + dyeAmount * cr;
                        dyeG = dyeG + dyeAmount * cg;
                        dyeB = dyeB + dyeAmount * cb;
                        dyeColorMean = (cr + cg + cb) / 3;
                    case "colormap"
                        cmRaw = mod(floor(frameIdx * 20), 510);
                        cmI = (cmRaw < 256) * cmRaw ...
                            + (cmRaw >= 256) * (510 - cmRaw) + 1;
                        cmap = obj.ColormapRGB;
                        cr = cmap(cmI, 1);
                        cg = cmap(cmI, 2);
                        cb = cmap(cmI, 3);
                        dyeR = dyeR + dyeAmount * cr;
                        dyeG = dyeG + dyeAmount * cg;
                        dyeB = dyeB + dyeAmount * cb;
                        dyeColorMean = (cr + cg + cb) / 3;
                    otherwise  % "dye"
                        dyeColor = [sin(frameIdx * 0.07) * 0.5 + 0.5, ...
                                    sin(frameIdx * 0.07 + 2.1) * 0.5 + 0.5, ...
                                    sin(frameIdx * 0.07 + 4.2) * 0.5 + 0.5];
                        dyeR = dyeR + dyeAmount * dyeColor(1);
                        dyeG = dyeG + dyeAmount * dyeColor(2);
                        dyeB = dyeB + dyeAmount * dyeColor(3);
                        dyeColorMean = mean(dyeColor);
                end

                obj.TotalDyeInjected = obj.TotalDyeInjected ...
                    + sum(dyeAmount(:)) * dyeColorMean;
            end

            % === STEP 2: Vorticity confinement (non-wrapping differences) ===
            vorticityEps = obj.VortEps;
            omega = [];
            if vorticityEps > 0
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
            end

            % === STEP 3: Advect velocity (semi-Lagrangian) ===
            u = games.FluidUtils.fldAdvect(u, u, v, dt, gX, gY, Ny, Nx);
            v = games.FluidUtils.fldAdvect(v, u, v, dt, gX, gY, Ny, Nx);

            % === STEP 4: Project (FFT Poisson pressure solve) ===
            [u, v] = games.FluidUtils.fldProject(u, v, obj.Eigvals, Nx, Ny);

            % Store pressure for display (non-wrapping divergence)
            dudxP = zeros(Ny, Nx); dvdyP = zeros(Ny, Nx);
            dudxP(:, 2:end) = u(:, 2:end) - u(:, 1:end-1);
            dvdyP(2:end, :) = v(2:end, :) - v(1:end-1, :);
            divField = dudxP + dvdyP;
            pHat = fft2(divField) ./ obj.Eigvals;
            pHat(1, 1) = 0;
            obj.PressureField = real(ifft2(pHat));

            % === STEP 5: Free-slip boundary + velocity damping ===
            u(:, 1) = 0; u(:, end) = 0;
            v(1, :) = 0; v(end, :) = 0;
            dsF = obj.DtScale;
            u = u * 0.998^dsF;
            v = v * 0.998^dsF;

            % === STEP 6: Advect dye ===
            dyeR = games.FluidUtils.fldAdvect(dyeR, u, v, dt, gX, gY, Ny, Nx);
            dyeG = games.FluidUtils.fldAdvect(dyeG, u, v, dt, gX, gY, Ny, Nx);
            dyeB = games.FluidUtils.fldAdvect(dyeB, u, v, dt, gX, gY, Ny, Nx);

            % Dye decay (frame-rate scaled)
            decayFactor = (1 - obj.DyeDecay)^dsF;
            dyeR = dyeR * decayFactor;
            dyeG = dyeG * decayFactor;
            dyeB = dyeB * decayFactor;

            % Clamp dye to [0, 1]
            dyeR = max(0, min(1, dyeR));
            dyeG = max(0, min(1, dyeG));
            dyeB = max(0, min(1, dyeB));

            % Store updated fields
            obj.U = u;
            obj.V = v;
            obj.DyeR = dyeR;
            obj.DyeG = dyeG;
            obj.DyeB = dyeB;

            % === STEP 7: Render ===
            obj.renderFluid(u, v, dyeR, dyeG, dyeB, Ny, Nx, ghost);

            % === SCORING ===
            obj.updateScoring(u, v, dyeR, dyeG, dyeB, ...
                omega, Ny, Nx, hasFinger, fingerSpeed);
        end

        function onCleanup(obj)
            %onCleanup  Delete all fluid simulation graphics and reset state.
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
            obj.Eigvals = [];
            obj.MeshX = [];
            obj.MeshY = [];
            obj.PrevFingerX = NaN;
            obj.PrevFingerY = NaN;
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_fluidsim");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["flow", "velocity", "vorticity", "curl", "pressure"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.updateModeLabel();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle mode-specific key events.
            handled = true;
            switch key
                case "m"
                    modes = ["flow", "velocity", "vorticity", "curl", "pressure"];
                    modeIdx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(modeIdx, numel(modes)) + 1);
                    obj.updateModeLabel();

                case "n"
                    injModes = ["dye", "fire", "rainbow", "colormap"];
                    modeIdx = find(injModes == obj.InjMode, 1);
                    obj.InjMode = injModes(mod(modeIdx, numel(injModes)) + 1);
                    if obj.InjMode == "colormap"
                        obj.loadColormap();
                    end
                    % Clear dye on injection mode change
                    ghost = obj.GhostCells;
                    Ny = obj.GridH + 2 * ghost;
                    Nx = obj.GridW + 2 * ghost;
                    obj.DyeR = zeros(Ny, Nx);
                    obj.DyeG = zeros(Ny, Nx);
                    obj.DyeB = zeros(Ny, Nx);
                    obj.updateModeLabel();

                case {"uparrow", "downarrow"}
                    obj.changeGridLevel(key);

                case {"leftarrow", "rightarrow"}
                    obj.changeSplatScale(key);

                case {"shift+leftarrow", "shift+rightarrow"}
                    if obj.InjMode == "colormap"
                        names = GameBase.lbmColormapNames();
                        nMaps = numel(names);
                        if key == "shift+rightarrow"
                            obj.ColormapIdx = mod(obj.ColormapIdx, nMaps) + 1;
                        else
                            obj.ColormapIdx = mod(obj.ColormapIdx - 2, nMaps) + 1;
                        end
                        obj.loadColormap();
                        obj.updateModeLabel();
                    else
                        handled = false;
                    end

                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return fluid-sim-specific results.
            r.Title = "FLUID SIM";
            elapsed = toc(obj.StartTic);
            r.Lines = {
                sprintf("Dye Injected: %.0f  |  Peak Vorticity: %.1f  |  Score: %d  |  Time: %.0fs", ...
                    obj.TotalDyeInjected, obj.PeakVorticity, obj.Score, elapsed)
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
            if obj.InjMode == "colormap"
                names = GameBase.lbmColormapNames();
                cmIdx = max(1, min(numel(names), obj.ColormapIdx));
                injLabel = upper(names(cmIdx)) ...
                    + " [S" + char(8592) + char(8594) + "]";
            else
                injLabel = upper(obj.InjMode);
            end
            s = upper(obj.SubMode) + " [M]  |  " + injLabel ...
                + " [N]  |  Grid " + obj.GridLevel ...
                + "/10 [" + char(8593) + char(8595) ...
                + "]  |  Vol " + sprintf("%.1f", obj.SplatRadius) ...
                + " [" + char(8592) + char(8594) + "]";
        end

        function buildGrid(obj)
            %buildGrid  Allocate fluid fields and precompute FFT eigenvalues.
            lvl = obj.GridLevel;
            obj.GridW = obj.GridSizes(lvl);
            obj.GridH = obj.GridSizes(lvl);
            obj.SplatRadius = obj.SplatRadiiTable(lvl);

            ghost = obj.GhostCells;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;

            obj.U = zeros(Ny, Nx);
            obj.V = zeros(Ny, Nx);
            obj.DyeR = zeros(Ny, Nx);
            obj.DyeG = zeros(Ny, Nx);
            obj.DyeB = zeros(Ny, Nx);

            [obj.MeshX, obj.MeshY] = meshgrid(1:Nx, 1:Ny);

            % Precompute FFT Poisson eigenvalues (discrete Laplacian spectrum)
            [ii, jj] = meshgrid(0:Nx-1, 0:Ny-1);
            eigvals = -4 + 2 * cos(2 * pi * ii / Nx) ...
                        + 2 * cos(2 * pi * jj / Ny);
            eigvals(1, 1) = 1;  % avoid division by zero (DC component)
            obj.Eigvals = eigvals;

            obj.TotalDyeInjected = 0;
            obj.PeakVorticity = 0;
            obj.FrameCount = 0;
            obj.PrevFingerX = NaN;
            obj.PrevFingerY = NaN;
            obj.PressureField = zeros(Ny, Nx);
            obj.SubMode = "flow";
        end

        function createGraphics(obj)
            %createGraphics  Create image overlay and HUD text.
            ax = obj.Ax;
            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;

            visNy = obj.GridH;
            visNx = obj.GridW;
            blackFrame = zeros(visNy, visNx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", blackFrame, ...
                "AlphaData", zeros(visNy, visNx), ...
                "AlphaDataMapping", "none", ...
                "Interpolation", "bilinear", ...
                "Tag", "GT_fluidsim");
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");

            obj.ModeTextH = text(ax, dxRange(1) + 5, dyRange(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_fluidsim");
        end

        function renderFluid(obj, u, v, dyeR, dyeG, dyeB, Ny, Nx, ghost)
            %renderFluid  Compute display RGB from fields and update image CData.
            if isempty(obj.ImageH) || ~isvalid(obj.ImageH); return; end

            switch obj.SubMode
                case "flow"
                    if obj.InjMode == "fire"
                        density = min(1, max(dyeR, max(dyeG, dyeB)) * 3.0);
                        displayR = min(1, density * 2.5);
                        displayG = min(1, max(0, (density - 0.25) * 1.8));
                        displayB = min(1, max(0, (density - 0.6) * 2.0));
                        bloom = imgaussfilt(density, 1.5) * 0.3;
                        displayR = min(1, displayR + bloom);
                        displayG = min(1, displayG + bloom * 0.4);
                        displayB = min(1, displayB + bloom * 0.1);
                    else
                        displayR = min(1, dyeR * 3.0);
                        displayG = min(1, dyeG * 3.0);
                        displayB = min(1, dyeB * 3.0);
                        glowR = imgaussfilt(displayR, 1.5);
                        glowG = imgaussfilt(displayG, 1.5);
                        glowB = imgaussfilt(displayB, 1.5);
                        displayR = min(1, displayR * 0.7 + glowR * 0.4);
                        displayG = min(1, displayG * 0.7 + glowG * 0.4);
                        displayB = min(1, displayB * 0.7 + glowB * 0.4);
                    end

                case "pressure"
                    pressureF = obj.PressureField;
                    normP = max(-1, min(1, pressureF / 5.0));
                    intensityP = abs(normP);
                    displayR = intensityP .* (normP < 0) * 0.9 ...
                        + min(1, dyeR * 2.5) * 0.4;
                    displayG = intensityP * 0.15 ...
                        + min(1, dyeG * 2.5) * 0.4;
                    displayB = intensityP .* (normP > 0) * 0.9 ...
                        + intensityP .* (normP < 0) * 0.4 ...
                        + min(1, dyeB * 2.5) * 0.4;
                    displayR = min(1, displayR + imgaussfilt(displayR, 2.0) * 0.3);
                    displayG = min(1, displayG + imgaussfilt(displayG, 2.0) * 0.3);
                    displayB = min(1, displayB + imgaussfilt(displayB, 2.0) * 0.3);

                case "velocity"
                    speedField = sqrt(u.^2 + v.^2);
                    normS = min(1, speedField / 15.0);
                    displayR = min(1, normS * 2.0);
                    displayG = min(1, normS * 1.5) ...
                        .* (1 - max(0, normS - 0.6) * 2.5);
                    displayB = max(0, 1 - normS * 2.0);
                    displayR = min(1, displayR + imgaussfilt(displayR, 1.5) * 0.3);
                    displayG = min(1, displayG + imgaussfilt(displayG, 1.5) * 0.3);
                    displayB = min(1, displayB + imgaussfilt(displayB, 1.5) * 0.3);

                case "vorticity"
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
                    dvdx2 = zeros(Ny, Nx); dudy2 = zeros(Ny, Nx);
                    dvdx2(:, 2:end-1) = (v(:, 3:end) - v(:, 1:end-2)) * 0.5;
                    dudy2(2:end-1, :) = (u(3:end, :) - u(1:end-2, :)) * 0.5;
                    curlMag = abs(dvdx2 - dudy2);
                    normC = min(1, curlMag / 8.0);
                    phaseC = obj.FrameCount * 0.02;
                    dR = dyeR .* (0.6 + 0.4 * sin(normC * 6 + phaseC));
                    dG = dyeG .* (0.6 + 0.4 * sin(normC * 6 + phaseC + 2.1));
                    dB = dyeB .* (0.6 + 0.4 * sin(normC * 6 + phaseC + 4.2));
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

            rgbFrame = cat(3, visR, visG, visB);
            obj.ImageH.CData = uint8(rgbFrame * 255);
            alphaFrame = min(0.92, max(visR, max(visG, visB)) * 1.8);
            obj.ImageH.AlphaData = alphaFrame;
        end

        function updateScoring(obj, u, v, dyeR, dyeG, dyeB, ...
                omega, Ny, Nx, hasFinger, fingerSpeed)
            %updateScoring  Accumulate score from KE, vorticity, and dye coverage.

            % Kinetic energy accumulation
            totalKE = sum(u(:).^2 + v(:).^2) * 0.5;
            if totalKE > 5
                energyScore = min(50, totalKE * 0.5);
                obj.addScore(round(energyScore * obj.comboMultiplier()));
            end

            % Vortex bonus
            if obj.VortEps > 0 && ~isempty(omega)
                peakVort = max(abs(omega(:)));
                if peakVort > 10
                    obj.addScore(round(peakVort * 0.2 * obj.comboMultiplier()));
                end
            end

            % Dye coverage bonus
            dyeIntensity = dyeR + dyeG + dyeB;
            coveredCells = nnz(dyeIntensity(:) > 0.1);
            if coveredCells > Nx * Ny * 0.2
                obj.addScore(round(coveredCells * 0.02));
            end

            % Combo: sustained finger movement increments, decays on stillness
            if hasFinger && fingerSpeed > 0.5
                if obj.Combo == 0
                    obj.Combo = 1;
                end
                if mod(obj.FrameCount, 30) == 0
                    obj.incrementCombo();
                end
            else
                if mod(obj.FrameCount, 60) == 0 && obj.Combo > 0
                    obj.Combo = max(0, obj.Combo - 1);
                end
            end
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Change fluid grid resolution (up/down arrows).
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

            % Delete old graphics
            if ~isempty(obj.ImageH) && isvalid(obj.ImageH)
                delete(obj.ImageH);
            end
            obj.ImageH = [];

            % Rebuild grid and graphics (keeps ModeTextH)
            obj.buildGrid();

            % Restore modes
            obj.SubMode = savedMode;
            obj.InjMode = savedInj;
            obj.ColormapIdx = savedCmIdx;
            obj.ColormapRGB = savedCmRGB;

            % Recreate image
            ax = obj.Ax;
            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;
            visNy = obj.GridH;
            visNx = obj.GridW;
            blackFrame = zeros(visNy, visNx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", blackFrame, ...
                "AlphaData", zeros(visNy, visNx), ...
                "AlphaDataMapping", "none", ...
                "Interpolation", "bilinear", ...
                "Tag", "GT_fluidsim");
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");

            obj.updateModeLabel();
        end

        function changeSplatScale(obj, key)
            %changeSplatScale  Change splat/feature scale (left/right arrows).
            splatStep = 0.3;
            if key == "rightarrow"
                obj.SplatRadius = min(6, obj.SplatRadius + splatStep);
            else
                obj.SplatRadius = max(1, obj.SplatRadius - splatStep);
            end
            obj.updateModeLabel();
        end

        function loadColormap(obj)
            %loadColormap  Cache the selected colormap as 256x3 RGB.
            names = GameBase.lbmColormapNames();
            cmIdx = max(1, min(numel(names), obj.ColormapIdx));
            cmName = names(cmIdx);
            try
                cmap = feval(cmName, 256);
            catch
                cmap = jet(256);
            end
            obj.ColormapRGB = cmap;
        end

        function updateModeLabel(obj)
            %updateModeLabel  Refresh the bottom-left HUD text.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

    end
end
