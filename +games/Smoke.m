classdef Smoke < GameBase
    %Smoke  Stam stable-fluids smoke simulation with buoyancy and vorticity.
    %   Blue-grey rendering with cycling hue tint and two-pass bloom.
    %   Density and temperature fields advected separately; temperature
    %   drives buoyancy. Finger injects velocity, density, and heat.
    %
    %   Controls:
    %       M / 1-4         — sub-mode (chimney/incense/explosion/wind)
    %       Up / Down        — grid resolution (10 levels)
    %       0                — reset simulation
    %
    %   Standalone: games.Smoke().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also games.FluidUtils, GameBase, GameHost

    properties (Constant)
        Name = "Smoke"
    end

    % =================================================================
    % GRID LEVEL TABLE (Constant)
    % =================================================================
    properties (Access = private, Constant)
        GridSizes = [20, 30, 40, 60, 80, 100, 112, 128, 144, 176]
        GhostCells (1,1) double = 2
    end

    % =================================================================
    % SIMULATION PARAMETERS
    % =================================================================
    properties (Access = private)
        GridLevel       (1,1) double = 5
        GridW           (1,1) double = 80
        GridH           (1,1) double = 60
        SubMode         (1,1) string = "chimney"
        Buoyancy        (1,1) double = 0.5
        Dissipation     (1,1) double = 0.03
        VortEps         (1,1) double = 1.5
    end

    % =================================================================
    % SIMULATION STATE
    % =================================================================
    properties (Access = private)
        Ux              (:,:) double
        Uy              (:,:) double
        Density         (:,:) double
        Temp            (:,:) double
        Eigvals         (:,:) double
        MeshX           (:,:) double
        MeshY           (:,:) double
        PrevFinger      (1,2) double = [NaN NaN]
        SplatHue        (1,1) double = 0
        FrameCount      (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BgImageH                        % dark background overlay
        ImageH                          % smoke rendering image
        ModeTextH                       % HUD text label
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create fluid grid, eigenvalues, and image overlay.
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
            %onUpdate  Per-frame Stam smoke solver with buoyancy and rendering.
            if isempty(obj.Ux); return; end

            ghost = obj.GhostCells;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;
            dt = 1.0;
            u = obj.Ux;
            v = obj.Uy;
            dens = obj.Density;
            tmp = obj.Temp;
            gX = obj.MeshX;
            gY = obj.MeshY;

            obj.FrameCount = obj.FrameCount + 1;

            % --- Map finger to interior grid coords ---
            dxR = obj.DisplayRange.X;
            dyR = obj.DisplayRange.Y;
            fingerGridX = NaN;
            fingerGridY = NaN;
            fingerVelX = 0;
            fingerVelY = 0;
            hasFinger = ~isempty(pos) && all(~isnan(pos));

            if hasFinger
                fingerGridX = ghost + 1 ...
                    + (pos(1) - dxR(1)) / (dxR(2) - dxR(1)) * (obj.GridW - 1);
                fingerGridY = ghost + 1 ...
                    + (pos(2) - dyR(1)) / (dyR(2) - dyR(1)) * (obj.GridH - 1);
                fingerGridX = max(ghost + 1, min(Nx - ghost, fingerGridX));
                fingerGridY = max(ghost + 1, min(Ny - ghost, fingerGridY));

                if all(~isnan(obj.PrevFinger))
                    fingerVelX = fingerGridX - obj.PrevFinger(1);
                    fingerVelY = fingerGridY - obj.PrevFinger(2);
                end
                obj.PrevFinger = [fingerGridX, fingerGridY];
            end

            % === STEP 1: Source injection (sub-mode dependent) ===
            midX = (ghost + 1 + Nx - ghost) / 2;
            botY = Ny - ghost - 1;
            splatR = max(2, obj.GridW * 0.04);

            switch obj.SubMode
                case "chimney"
                    gauss = exp(-((gX - midX).^2 + (gY - botY).^2) ...
                        / (2 * splatR^2));
                    dens = dens + 0.4 * gauss;
                    tmp = tmp + 0.8 * gauss;
                    v = v - 0.3 * gauss;

                case "incense"
                    thinR = max(1.5, splatR * 0.5);
                    gauss = exp(-((gX - midX).^2 + (gY - botY).^2) ...
                        / (2 * thinR^2));
                    dens = dens + 0.3 * gauss;
                    tmp = tmp + 0.6 * gauss;

                case "explosion"
                    if obj.FrameCount <= 3
                        ctrX = midX;
                        ctrY = (ghost + 1 + Ny - ghost) / 2;
                        burstR = max(3, obj.GridW * 0.08);
                        gauss = exp(-((gX - ctrX).^2 + (gY - ctrY).^2) ...
                            / (2 * burstR^2));
                        dens = dens + 3.0 * gauss;
                        tmp = tmp + 5.0 * gauss;
                        rx = gX - ctrX;
                        ry = gY - ctrY;
                        radDist = sqrt(rx.^2 + ry.^2) + 1e-6;
                        radialStr = 8.0 * gauss;
                        u = u + radialStr .* (rx ./ radDist);
                        v = v + radialStr .* (ry ./ radDist);
                    end

                case "wind"
                    leftX = ghost + 2;
                    colGauss = exp(-(gX - leftX).^2 / (2 * splatR^2));
                    midY = (ghost + 1 + Ny - ghost) / 2;
                    spreadY = obj.GridH * 0.3;
                    rowGauss = exp(-(gY - midY).^2 / (2 * spreadY^2));
                    srcMask = colGauss .* rowGauss;
                    dens = dens + 0.5 * srcMask;
                    tmp = tmp + 0.4 * srcMask;
                    u = u + 1.5 * srcMask;
            end

            % === STEP 2: Finger velocity injection ===
            fingerSpeed = sqrt(fingerVelX^2 + fingerVelY^2);
            if hasFinger && fingerSpeed > 0.1
                gauss = exp(-((gX - fingerGridX).^2 + (gY - fingerGridY).^2) ...
                    / (2 * (splatR * 1.5)^2));
                u = u + dt * 8.0 * fingerVelX * gauss;
                v = v + dt * 8.0 * fingerVelY * gauss;
                dens = dens + 0.2 * gauss;
                tmp = tmp + 0.3 * gauss;
            end

            % === STEP 3: Buoyancy ===
            v = v - obj.Buoyancy * tmp;

            % === STEP 4: Vorticity confinement ===
            if obj.VortEps > 0
                dvdx = zeros(Ny, Nx);
                dudy = zeros(Ny, Nx);
                dvdx(:, 2:end-1) = (v(:, 3:end) - v(:, 1:end-2)) * 0.5;
                dudy(2:end-1, :) = (u(3:end, :) - u(1:end-2, :)) * 0.5;
                omega = dvdx - dudy;
                absW = abs(omega);
                dWdx = zeros(Ny, Nx);
                dWdy = zeros(Ny, Nx);
                dWdx(:, 2:end-1) = (absW(:, 3:end) - absW(:, 1:end-2)) * 0.5;
                dWdy(2:end-1, :) = (absW(3:end, :) - absW(1:end-2, :)) * 0.5;
                vortLen = sqrt(dWdx.^2 + dWdy.^2) + 1e-10;
                u = u + dt * obj.VortEps * (dWdy ./ vortLen) .* omega;
                v = v + dt * obj.VortEps * (-dWdx ./ vortLen) .* omega;
            end

            % === STEP 5: Advect velocity (semi-Lagrangian) ===
            u = games.FluidUtils.fldAdvect(u, u, v, dt, gX, gY, Ny, Nx);
            v = games.FluidUtils.fldAdvect(v, u, v, dt, gX, gY, Ny, Nx);

            % === STEP 6: Pressure projection (FFT Poisson) ===
            [u, v] = games.FluidUtils.fldProject(u, v, obj.Eigvals, Nx, Ny);

            % === STEP 7: Free-slip boundary + velocity damping ===
            u(:, 1) = 0; u(:, end) = 0;
            v(1, :) = 0; v(end, :) = 0;
            bndLayers = 3;
            for bi = 1:bndLayers
                fac = bi / (bndLayers + 1);
                u(:, bi) = u(:, bi) * fac;
                u(:, end - bi + 1) = u(:, end - bi + 1) * fac;
                v(bi, :) = v(bi, :) * fac;
                v(end - bi + 1, :) = v(end - bi + 1, :) * fac;
            end
            dsF = obj.DtScale;
            u = u * 0.998^dsF;
            v = v * 0.998^dsF;

            % === STEP 8: Advect density and temperature ===
            dens = games.FluidUtils.fldAdvect(dens, u, v, dt, gX, gY, Ny, Nx);
            tmp = games.FluidUtils.fldAdvect(tmp, u, v, dt, gX, gY, Ny, Nx);

            % === STEP 9: Dissipation and cooling (frame-rate scaled) ===
            dens = max(0, dens * (1 - obj.Dissipation)^dsF);
            tmp = max(0, tmp * (1 - obj.Dissipation * 1.5)^dsF);

            % Store fields
            obj.Ux = u;
            obj.Uy = v;
            obj.Density = dens;
            obj.Temp = tmp;

            % === STEP 10: Render ===
            obj.SplatHue = mod(obj.SplatHue + 0.003, 1.0);
            obj.renderSmoke(ghost);

            % === SCORING ===
            totalDens = sum(dens(:));
            totalKE = sum(u(:).^2 + v(:).^2) * 0.5;
            if totalKE > 3
                obj.addScore(round(min(30, totalKE * 0.3) ...
                    * max(1, obj.Combo * 0.1)));
            end
            if totalDens > Nx * Ny * 0.05
                obj.addScore(round(totalDens * 0.01));
            end
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

        function onCleanup(obj)
            %onCleanup  Delete smoke graphics and reset state.
            handles = {obj.BgImageH, obj.ImageH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.BgImageH = [];
            obj.ImageH = [];
            obj.ModeTextH = [];
            obj.Ux = [];
            obj.Uy = [];
            obj.Density = [];
            obj.Temp = [];
            obj.Eigvals = [];
            obj.MeshX = [];
            obj.MeshY = [];
            obj.PrevFinger = [NaN NaN];
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_smoke");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["chimney", "incense", "explosion", "wind"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.applySubMode();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle smoke-specific key events.
            handled = true;
            switch key
                case "m"
                    modes = ["chimney", "incense", "explosion", "wind"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();

                case {"1", "2", "3", "4"}
                    modes = ["chimney", "incense", "explosion", "wind"];
                    modeIdx = double(key) - 48;
                    obj.SubMode = modes(modeIdx);
                    obj.applySubMode();

                case {"uparrow", "downarrow"}
                    obj.changeGridLevel(key);

                case "0"
                    savedMode = obj.SubMode;
                    obj.onCleanup();
                    obj.buildGrid();
                    obj.createGraphics();
                    obj.SubMode = savedMode;
                    obj.applySubMode();

                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return smoke-specific results.
            r.Title = "SMOKE";
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            r.Lines = {
                sprintf("Grid: %dx%d  |  Mode: %s  |  Time: %.0fs", ...
                    obj.GridW, obj.GridH, obj.SubMode, elapsed)
            };
        end

        function s = getHudText(~)
            %getHudText  Return HUD string for bottom of screen.
            s = "";
        end
    end

    % =================================================================
    % PRIVATE HELPERS
    % =================================================================
    methods (Access = private)

        function s = buildHudString(obj)
            %buildHudString  Return HUD string for bottom of screen.
            s = "SMOKE: " + upper(obj.SubMode) ...
                + " [1-4/M]  |  Grid " + obj.GridLevel + "/10 [" ...
                + char(8593) + char(8595) + "]";
        end

        function buildGrid(obj)
            %buildGrid  Allocate fluid fields, meshgrid, and FFT eigenvalues.
            ghost = obj.GhostCells;
            lvl = max(1, min(10, obj.GridLevel));
            obj.GridW = obj.GridSizes(lvl);
            obj.GridH = round(obj.GridW * 0.75);

            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;

            obj.Ux = zeros(Ny, Nx);
            obj.Uy = zeros(Ny, Nx);
            obj.Density = zeros(Ny, Nx);
            obj.Temp = zeros(Ny, Nx);

            [obj.MeshX, obj.MeshY] = meshgrid(1:Nx, 1:Ny);

            % FFT Poisson eigenvalues (discrete Laplacian spectrum)
            [ii, jj] = meshgrid(0:Nx-1, 0:Ny-1);
            eigvals = -4 + 2 * cos(2 * pi * ii / Nx) + 2 * cos(2 * pi * jj / Ny);
            eigvals(1, 1) = 1;
            obj.Eigvals = eigvals;

            obj.FrameCount = 0;
            obj.PrevFinger = [NaN NaN];
            obj.SplatHue = 0;
            obj.SubMode = "chimney";
        end

        function createGraphics(obj)
            %createGraphics  Create dark background overlay and smoke image.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dxR = obj.DisplayRange.X;
            dyR = obj.DisplayRange.Y;

            % Dark background — covers camera feed (alpha 0.92)
            obj.BgImageH = image(ax, "XData", dxR, "YData", dyR, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_smoke_bg");
            uistack(obj.BgImageH, "bottom");
            uistack(obj.BgImageH, "up");

            % Smoke image overlay — visible interior only (no ghost cells)
            visNy = obj.GridH;
            visNx = obj.GridW;
            blackFrame = zeros(visNy, visNx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dxR, "YData", dyR, ...
                "CData", blackFrame, "AlphaData", zeros(visNy, visNx), ...
                "AlphaDataMapping", "none", "Interpolation", "bilinear", ...
                "Tag", "GT_smoke");

            % HUD label
            obj.ModeTextH = text(ax, dxR(1) + 5, dyR(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_smoke");
        end

        function renderSmoke(obj, ghost)
            %renderSmoke  Blue-grey + cycling hue tint + two-pass bloom rendering.
            if isempty(obj.ImageH) || ~isvalid(obj.ImageH); return; end

            visDens = obj.Density(ghost+1:end-ghost, ghost+1:end-ghost);
            visTmp = obj.Temp(ghost+1:end-ghost, ghost+1:end-ghost);

            % Intensity from density, warmth from temperature
            intensity = min(1, visDens * 2.5);
            warmth = min(1, visTmp * 1.5);

            % Base color: cool blue-grey with subtle cycling hue tint
            [hR, hG, hB] = GameBase.hsvToRgb(obj.SplatHue);
            hueTint = 0.25;
            baseR = 0.55 * (1 - hueTint) + hR * hueTint;
            baseG = 0.58 * (1 - hueTint) + hG * hueTint;
            baseB = 0.72 * (1 - hueTint) + hB * hueTint;

            dispR = intensity .* (baseR + (1 - baseR) * warmth);
            dispG = intensity .* (baseG + (1 - baseG) * warmth);
            dispB = intensity .* (baseB + (1 - baseB) * warmth);

            % Two-pass bloom for soft neon glow
            peakI = max(intensity(:));
            if peakI > 0.05
                g1R = imgaussfilt(dispR, 1.5);
                g1G = imgaussfilt(dispG, 1.5);
                g1B = imgaussfilt(dispB, 1.5);
                g2R = imgaussfilt(dispR, 4.0);
                g2G = imgaussfilt(dispG, 4.0);
                g2B = imgaussfilt(dispB, 4.0);
                dispR = min(1, dispR * 0.6 + g1R * 0.25 + g2R * 0.2);
                dispG = min(1, dispG * 0.6 + g1G * 0.25 + g2G * 0.2);
                dispB = min(1, dispB * 0.6 + g1B * 0.25 + g2B * 0.2);
            end

            rgb = cat(3, dispR, dispG, dispB);
            obj.ImageH.CData = uint8(rgb * 255);
            smokeAlpha = min(0.92, intensity * 1.8);
            obj.ImageH.AlphaData = smokeAlpha;
        end

        function applySubMode(obj)
            %applySubMode  Set physics parameters for current sub-mode and update HUD.
            switch obj.SubMode
                case "chimney"
                    obj.Buoyancy = 0.5;
                    obj.Dissipation = 0.035;
                    obj.VortEps = 1.5;
                case "incense"
                    obj.Buoyancy = 0.2;
                    obj.Dissipation = 0.025;
                    obj.VortEps = 3.0;
                case "explosion"
                    obj.Buoyancy = 0.3;
                    obj.Dissipation = 0.04;
                    obj.VortEps = 2.0;
                    % Reset fields for fresh burst
                    ghost = obj.GhostCells;
                    Ny = obj.GridH + 2 * ghost;
                    Nx = obj.GridW + 2 * ghost;
                    obj.Ux = zeros(Ny, Nx);
                    obj.Uy = zeros(Ny, Nx);
                    obj.Density = zeros(Ny, Nx);
                    obj.Temp = zeros(Ny, Nx);
                    obj.FrameCount = 0;
                case "wind"
                    obj.Buoyancy = 0.15;
                    obj.Dissipation = 0.03;
                    obj.VortEps = 1.0;
            end

            % Update HUD label
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Adjust grid resolution with up/down arrows.
            oldLevel = obj.GridLevel;
            if key == "uparrow"
                obj.GridLevel = min(10, oldLevel + 1);
            else
                obj.GridLevel = max(1, oldLevel - 1);
            end
            if obj.GridLevel == oldLevel; return; end

            savedMode = obj.SubMode;
            obj.onCleanup();
            obj.buildGrid();
            obj.createGraphics();
            obj.SubMode = savedMode;
            obj.applySubMode();
        end
    end
end
