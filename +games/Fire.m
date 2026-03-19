classdef Fire < GameBase
    %Fire  Stam stable-fluids fire simulation with combustion system.
    %   Fuel + heat above ignition threshold triggers combustion, generating
    %   more heat. Fire colormap rendering with two-pass bloom. Ember
    %   particles spawn from hot regions. Ghost cells (2 per side) hide
    %   boundary dead zones.
    %
    %   Controls:
    %       M               — cycle sub-mode (torch/campfire/wildfire/wall)
    %       1-4             — direct sub-mode select
    %       Up / Down       — grid resolution (10 levels)
    %       0               — reset simulation
    %
    %   Standalone: games.Fire().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also games.FluidUtils, GameBase, GameHost

    properties (Constant)
        Name = "Fire"
    end

    % =================================================================
    % GRID LEVEL TABLE (Constant)
    % =================================================================
    properties (Access = private, Constant)
        GridSizes   = [20, 30, 40, 60, 80, 100, 112, 128, 144, 176]
        GhostCells  (1,1) double = 2
    end

    % =================================================================
    % SIMULATION PARAMETERS
    % =================================================================
    properties (Access = private)
        GridLevel       (1,1) double = 5
        GridW           (1,1) double = 80
        GridH           (1,1) double = 60
        SubMode         (1,1) string = "torch"
        Buoyancy        (1,1) double = 1.0
        Cooling         (1,1) double = 0.02
        Combustion      (1,1) double = 0.5
        MaxEmbers       (1,1) double = 50
    end

    % =================================================================
    % SIMULATION STATE
    % =================================================================
    properties (Access = private)
        Ux              (:,:) double        % horizontal velocity field
        Uy              (:,:) double        % vertical velocity field
        Temp            (:,:) double        % temperature field
        Fuel            (:,:) double        % fuel density field
        Eigvals         (:,:) double        % precomputed FFT Poisson eigenvalues
        MeshX           (:,:) double        % meshgrid X (precomputed)
        MeshY           (:,:) double        % meshgrid Y (precomputed)
        EmberX          (:,1) double        % ember X positions
        EmberY          (:,1) double        % ember Y positions
        EmberVx         (:,1) double        % ember X velocities
        EmberVy         (:,1) double        % ember Y velocities
        EmberLife       (:,1) double        % ember remaining life [0,1]
        PrevFinger      (1,2) double = [NaN NaN]
        ExplosionDone   (1,1) logical = false
        FrameCount      (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BgImageH                            % dark background overlay
        ImageH                              % fire image overlay
        EmberH                              % ember core scatter
        EmberGlowH                          % ember glow scatter
        ModeTextH                           % sub-mode HUD label
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create fire fluid grid, fuel field, ember particles, and image overlay.
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
            %onUpdate  Per-frame fire simulation: combustion, fluid, embers, rendering.
            if isempty(obj.Ux); return; end

            ghost = obj.GhostCells;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;
            dt = 1.0;
            u = obj.Ux;
            v = obj.Uy;
            temp = obj.Temp;
            fuel = obj.Fuel;
            gX = obj.MeshX;
            gY = obj.MeshY;

            obj.FrameCount = obj.FrameCount + 1;

            % --- Map finger to interior grid coordinates ---
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

                if all(~isnan(obj.PrevFinger))
                    fingerVelX = fingerGridX - obj.PrevFinger(1);
                    fingerVelY = fingerGridY - obj.PrevFinger(2);
                end
                obj.PrevFinger = [fingerGridX, fingerGridY];
            end

            % === STEP 1: Combustion — fuel + heat above ignition -> more heat ===
            ignitionThreshold = 0.3;
            burning = (fuel > 0.01) & (temp > ignitionThreshold);
            combustionRate = obj.Combustion * dt;
            burnAmount = min(fuel, combustionRate) .* burning;
            fuel = fuel - burnAmount;
            temp = temp + burnAmount * 3.0;

            % === STEP 2: Finger interaction — add fuel at finger position ===
            fingerSpeed = sqrt(fingerVelX^2 + fingerVelY^2);
            if hasFinger
                if obj.SubMode == "torch"
                    % Sparkler: intense point source at finger only
                    sparkR = max(1.5, obj.GridW * 0.025);
                    gauss = exp(-((gX - fingerGridX).^2 + (gY - fingerGridY).^2) ...
                        / (2 * sparkR^2));
                    fuel = fuel + 1.2 * gauss;
                    temp = temp + 1.8 * gauss;
                    % Radial spark ejection: small random velocity bursts outward
                    nSpk = 3 + round(fingerSpeed * 2);
                    for si = 1:nSpk
                        ang = rand * 2 * pi;
                        spd = 1.5 + rand * 3.0;
                        spkR = sparkR * (0.5 + rand * 1.5);
                        spkGauss = exp(-((gX - fingerGridX - cos(ang) * spkR).^2 ...
                            + (gY - fingerGridY - sin(ang) * spkR).^2) / (2 * 1.2^2));
                        fuel = fuel + 0.15 * spkGauss;
                        temp = temp + 0.3 * spkGauss;
                        u = u + spd * cos(ang) * spkGauss;
                        v = v + spd * sin(ang) * spkGauss;
                    end
                    % Movement drags sparks along
                    if fingerSpeed > 0.1
                        u = u + dt * 3.0 * fingerVelX * gauss;
                        v = v + dt * 3.0 * fingerVelY * gauss;
                    end
                elseif obj.SubMode == "wildfire"
                    % Wildfire: finger is the spark — strong ignition
                    ignR = max(3, obj.GridW * 0.07);
                    gauss = exp(-((gX - fingerGridX).^2 + (gY - fingerGridY).^2) ...
                        / (2 * ignR^2));
                    temp = temp + 3.0 * gauss;
                    if fingerSpeed > 0.1
                        u = u + dt * 4.0 * fingerVelX * gauss;
                        v = v + dt * 4.0 * fingerVelY * gauss;
                    end
                else
                    % Campfire / wall: moderate interaction
                    fuelR = max(2, obj.GridW * 0.05);
                    gauss = exp(-((gX - fingerGridX).^2 + (gY - fingerGridY).^2) ...
                        / (2 * fuelR^2));
                    fuel = fuel + 0.4 * gauss;
                    temp = temp + 0.5 * gauss;
                    if fingerSpeed > 0.1
                        u = u + dt * 5.0 * fingerVelX * gauss;
                        v = v + dt * 5.0 * fingerVelY * gauss;
                    end
                end
            end

            % === STEP 2c: Wildfire spread — fire front creeps into unburned fuel ===
            if obj.SubMode == "wildfire"
                hotMask = double(temp > 0.1);
                kernel = fspecial("gaussian", 7, 2.0);
                kernel(4, 4) = 0;  % don't self-reinforce
                spreadHeat = conv2(hotMask, kernel, "same");
                hasFuelMask = fuel > 0.02;
                temp = temp + spreadHeat .* hasFuelMask * 0.5;
            end

            % === STEP 3: Buoyancy — upward force from heat ===
            v = v - obj.Buoyancy * temp;

            % === STEP 4: Vorticity confinement ===
            vortEps = 2.0;
            dvdx = zeros(Ny, Nx); dudy = zeros(Ny, Nx);
            dvdx(:, 2:end-1) = (v(:, 3:end) - v(:, 1:end-2)) * 0.5;
            dudy(2:end-1, :) = (u(3:end, :) - u(1:end-2, :)) * 0.5;
            omega = dvdx - dudy;
            absW = abs(omega);
            dWdx = zeros(Ny, Nx); dWdy = zeros(Ny, Nx);
            dWdx(:, 2:end-1) = (absW(:, 3:end) - absW(:, 1:end-2)) * 0.5;
            dWdy(2:end-1, :) = (absW(3:end, :) - absW(1:end-2, :)) * 0.5;
            gradLen = sqrt(dWdx.^2 + dWdy.^2) + 1e-10;
            u = u + dt * vortEps * (dWdy ./ gradLen) .* omega;
            v = v + dt * vortEps * (-dWdx ./ gradLen) .* omega;

            % === STEP 5: Advect velocity ===
            u = games.FluidUtils.fldAdvect(u, u, v, dt, gX, gY, Ny, Nx);
            v = games.FluidUtils.fldAdvect(v, u, v, dt, gX, gY, Ny, Nx);

            % === STEP 6: Pressure projection ===
            [u, v] = games.FluidUtils.fldProject(u, v, obj.Eigvals, Nx, Ny);

            % === STEP 7: Boundary conditions + smooth boundary layer ===
            u(:, 1) = 0; u(:, end) = 0;
            v(1, :) = 0; v(end, :) = 0;
            bnd = 3;
            for bi = 1:bnd
                fac = bi / (bnd + 1);
                u(:, bi) = u(:, bi) * fac;
                u(:, end - bi + 1) = u(:, end - bi + 1) * fac;
                v(bi, :) = v(bi, :) * fac;
                v(end - bi + 1, :) = v(end - bi + 1, :) * fac;
            end
            dsF = obj.DtScale;
            u = u * 0.995^dsF;
            v = v * 0.995^dsF;
            % Kill heat and fuel at all boundaries
            temp(1:ghost, :) = 0; temp(end-ghost+1:end, :) = 0;
            temp(:, 1:ghost) = 0; temp(:, end-ghost+1:end) = 0;
            fuel(1:ghost, :) = 0; fuel(end-ghost+1:end, :) = 0;
            fuel(:, 1:ghost) = 0; fuel(:, end-ghost+1:end) = 0;

            % === STEP 7b: Re-inject fuel AFTER cleanup ===
            if obj.FrameCount > 3 && obj.SubMode == "campfire"
                [fuel, temp] = obj.replenishFuel(fuel, temp);
            end
            % Wall: dramatic burst every ~5s, nothing between
            if obj.SubMode == "wall" && mod(obj.FrameCount, 150) < 30
                burstY = Ny;
                fuelR2 = max(3, obj.GridH * 0.15);
                rowDist = exp(-(gY - burstY).^2 / (2 * fuelR2^2));
                fuel = fuel + rowDist * 1.5;
                temp = temp + rowDist * 2.5;
                v = v - rowDist * 1.5;
            end

            % === STEP 8: Advect temperature and fuel ===
            temp = games.FluidUtils.fldAdvect(temp, u, v, dt, gX, gY, Ny, Nx);
            fuel = games.FluidUtils.fldAdvect(fuel, u, v, dt, gX, gY, Ny, Nx);

            % === STEP 9: Cooling (frame-rate scaled) ===
            temp = max(0, temp * (1 - obj.Cooling)^dsF);
            fuel = max(0, fuel);

            % Store fields
            obj.Ux = u;
            obj.Uy = v;
            obj.Temp = temp;
            obj.Fuel = fuel;

            % === STEP 10: Update ember particles ===
            obj.updateEmbers(u, v, temp, ghost, Nx, Ny);

            % === STEP 11: Render fire ===
            obj.renderFire(ghost);

            % === SCORING ===
            totalHeat = sum(temp(:));
            totalKE = sum(u(:).^2 + v(:).^2) * 0.5;
            if totalHeat > Nx * Ny * 0.02
                obj.addScore(round(min(40, totalHeat * 0.2) ...
                    * max(1, obj.Combo * 0.1)));
            end
            if totalKE > 5
                obj.addScore(round(min(20, totalKE * 0.2) ...
                    * max(1, obj.Combo * 0.1)));
            end
            if hasFinger && fingerSpeed > 0.3
                if obj.Combo == 0; obj.Combo = 1; end
                if mod(obj.FrameCount, 25) == 0
                    obj.incrementCombo();
                end
            else
                if mod(obj.FrameCount, 50) == 0 && obj.Combo > 0
                    obj.Combo = max(0, obj.Combo - 1);
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete fire sim graphics and reset state.
            handles = {obj.BgImageH, obj.ImageH, obj.EmberGlowH, ...
                obj.EmberH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.BgImageH = [];
            obj.ImageH = [];
            obj.EmberGlowH = [];
            obj.EmberH = [];
            obj.ModeTextH = [];
            obj.Ux = [];
            obj.Uy = [];
            obj.Temp = [];
            obj.Fuel = [];
            obj.Eigvals = [];
            obj.MeshX = [];
            obj.MeshY = [];
            obj.EmberX = [];
            obj.EmberY = [];
            obj.EmberVx = [];
            obj.EmberVy = [];
            obj.EmberLife = [];
            obj.PrevFinger = [NaN NaN];
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_fire");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["torch", "campfire", "wildfire", "wall"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.applySubMode();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle fire-specific key events.
            handled = true;
            switch key
                case "m"
                    % Cycle sub-mode
                    modes = ["torch", "campfire", "wildfire", "wall"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();

                case {"1", "2", "3", "4"}
                    % Direct sub-mode select
                    modes = ["torch", "campfire", "wildfire", "wall"];
                    n = double(key) - 48;
                    obj.SubMode = modes(n);
                    obj.applySubMode();

                case {"uparrow", "downarrow"}
                    obj.changeGridLevel(key);

                case "0"
                    % Reset simulation with current sub-mode
                    obj.applySubMode();

                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return fire-specific results.
            r.Title = "FIRE";
            r.Lines = {
                sprintf("Grid: %dx%d  |  Mode: %s", obj.GridW, obj.GridH, obj.SubMode)
            };
        end

        function s = getHudText(~)
            %getHudText  Return fire HUD string.
            s = "";
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function s = buildHudString(obj)
            %buildHudString  Return fire HUD string.
            s = "FIRE: " + upper(obj.SubMode) + " [1-4/M]  |  Grid " ...
                + obj.GridLevel + "/10 [" + char(8593) + char(8595) + "]";
        end

        function buildGrid(obj)
            %buildGrid  Allocate fluid fields, precompute eigenvalues and meshgrid.
            lvl = max(1, min(10, obj.GridLevel));
            obj.GridW = obj.GridSizes(lvl);
            obj.GridH = round(obj.GridW * 0.75);

            ghost = obj.GhostCells;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;

            % Initialize fields
            obj.Ux = zeros(Ny, Nx);
            obj.Uy = zeros(Ny, Nx);
            obj.Temp = zeros(Ny, Nx);
            obj.Fuel = zeros(Ny, Nx);

            % Precompute meshgrid and eigenvalues
            [obj.MeshX, obj.MeshY] = meshgrid(1:Nx, 1:Ny);

            [ii, jj] = meshgrid(0:Nx-1, 0:Ny-1);
            eigvals = -4 + 2 * cos(2 * pi * ii / Nx) + 2 * cos(2 * pi * jj / Ny);
            eigvals(1, 1) = 1;
            obj.Eigvals = eigvals;

            % State
            obj.FrameCount = 0;
            obj.PrevFinger = [NaN NaN];
            obj.SubMode = "torch";
            obj.Buoyancy = 0.3;
            obj.Cooling = 0.08;
            obj.Combustion = 0.8;
            obj.MaxEmbers = 120;
            obj.ExplosionDone = false;

            % Place initial fuel
            obj.placeFuel();

            % Initialize ember particles (preallocated)
            nEmb = obj.MaxEmbers;
            obj.EmberX = NaN(nEmb, 1);
            obj.EmberY = NaN(nEmb, 1);
            obj.EmberVx = zeros(nEmb, 1);
            obj.EmberVy = zeros(nEmb, 1);
            obj.EmberLife = zeros(nEmb, 1);
        end

        function createGraphics(obj)
            %createGraphics  Create image overlays, ember scatter, and HUD label.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;

            % Dark background — semi-transparent to let camera show through
            obj.BgImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.4, ...
                "AlphaDataMapping", "none", "Tag", "GT_fire_bg");
            uistack(obj.BgImageH, "bottom");
            uistack(obj.BgImageH, "up");

            % Fire image overlay — visible interior only
            visNy = obj.GridH;
            visNx = obj.GridW;
            blackFrame = zeros(visNy, visNx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", blackFrame, "AlphaData", zeros(visNy, visNx), ...
                "AlphaDataMapping", "none", "Interpolation", "bilinear", ...
                "Tag", "GT_fire");

            % Ember glow scatter (larger, translucent halos)
            obj.EmberGlowH = scatter(ax, NaN, NaN, 60, [1 0.6 0.1], ...
                "filled", "MarkerFaceAlpha", 0.2, "Tag", "GT_fire");

            % Ember core scatter (smaller, bright)
            obj.EmberH = scatter(ax, NaN, NaN, 15, [1 0.7 0.2], ...
                "filled", "MarkerFaceAlpha", 0.9, "Tag", "GT_fire");

            % Sub-mode HUD label
            obj.ModeTextH = text(ax, dxRange(1) + 5, dyRange(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_fire");
        end

        function renderFire(obj, ghost)
            %renderFire  Compute fire colormap + bloom and update image CData.
            if isempty(obj.ImageH) || ~isvalid(obj.ImageH); return; end

            visTemp = obj.Temp(ghost+1:end-ghost, ghost+1:end-ghost);
            visFuel = obj.Fuel(ghost+1:end-ghost, ghost+1:end-ghost);

            % Fire colormap: black -> deep red -> orange -> yellow -> white
            t = min(1, visTemp * 2.0);
            t2 = t .* t;  % quadratic ramp for deeper darks

            displayR = min(1, t2 * 1.5 + t * 0.8);
            displayG = min(1, max(0, t - 0.25) .* 2.0);
            displayB = min(1, max(0, t - 0.6) .* 3.0);

            % Fuel glow: subtle hint where fuel exists but hasn't ignited
            fuelGlow = min(1, visFuel * 0.08);
            displayR = max(displayR, fuelGlow * 0.15);
            displayG = max(displayG, fuelGlow * 0.02);

            % Two-pass bloom for fire glow
            peakI = max(displayR(:));
            if peakI > 0.05
                g1R = imgaussfilt(displayR, 1.5);
                g1G = imgaussfilt(displayG, 1.5);
                g1B = imgaussfilt(displayB, 1.5);
                g2R = imgaussfilt(displayR, 3.5);
                g2G = imgaussfilt(displayG, 3.5);
                g2B = imgaussfilt(displayB, 3.5);
                displayR = min(1, displayR * 0.5 + g1R * 0.3 + g2R * 0.25);
                displayG = min(1, displayG * 0.5 + g1G * 0.3 + g2G * 0.25);
                displayB = min(1, displayB * 0.5 + g1B * 0.3 + g2B * 0.25);
            end

            rgb = cat(3, displayR, displayG, displayB);
            obj.ImageH.CData = uint8(rgb * 255);
            alphaMap = min(0.95, max(displayR, max(displayG, displayB)) * 2.0);
            obj.ImageH.AlphaData = alphaMap;
        end

        function placeFuel(obj)
            %placeFuel  Place initial fuel based on current sub-mode.
            ghost = obj.GhostCells;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;
            gX = obj.MeshX;
            gY = obj.MeshY;
            midX = (ghost + 1 + Nx - ghost) / 2;
            botY = Ny;  % ghost cell below visible area
            fuel = zeros(Ny, Nx);
            temp = obj.Temp;

            switch obj.SubMode
                case "campfire"
                    fuelR = max(3, obj.GridW * 0.08);
                    gauss = exp(-((gX - midX).^2 + (gY - botY).^2) / (2 * fuelR^2));
                    fuel = gauss * 2.0;
                    temp = temp + gauss * 1.0;

                case "wall"
                    fuelR = max(3, obj.GridH * 0.15);
                    rowDist = exp(-(gY - botY).^2 / (2 * fuelR^2));
                    fuel = rowDist * 2.0;
                    temp = temp + rowDist * 1.0;

                case "torch"
                    % No initial fuel — finger is the only source

                case "wildfire"
                    fuel = 2.0 * ones(Ny, Nx);
            end

            obj.Fuel = fuel;
            obj.Temp = temp;
        end

        function [fuel, temp] = replenishFuel(obj, fuel, temp)
            %replenishFuel  Continuously inject fuel+heat at campfire source.
            ghost = obj.GhostCells;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;
            gX = obj.MeshX;
            gY = obj.MeshY;
            midX = (ghost + 1 + Nx - ghost) / 2;
            botY = Ny;

            switch obj.SubMode
                case "campfire"
                    fuelR = max(3, obj.GridW * 0.08);
                    gauss = exp(-((gX - midX).^2 + (gY - botY).^2) / (2 * fuelR^2));
                    fuel = fuel + gauss * 0.3;
                    temp = temp + gauss * 0.5;
            end
        end

        function updateEmbers(obj, u, v, temp, ghost, Nx, Ny)
            %updateEmbers  Spawn, move, and age ember particles from hot regions.
            emberLife = obj.EmberLife;
            ex = obj.EmberX;
            ey = obj.EmberY;
            evx = obj.EmberVx;
            evy = obj.EmberVy;

            % Age existing embers
            alive = emberLife > 0;
            emberLife(alive) = emberLife(alive) - 0.02;
            dead = emberLife <= 0;
            emberLife(dead) = 0;

            % Move alive embers: follow velocity field + random jitter + rise
            aliveIdx = find(alive & ~dead);
            for k = 1:numel(aliveIdx)
                i = aliveIdx(k);
                gx = round(max(1, min(Nx, ex(i))));
                gy = round(max(1, min(Ny, ey(i))));
                evx(i) = evx(i) * 0.95 + u(gy, gx) * 0.3 + (rand - 0.5) * 0.8;
                evy(i) = evy(i) * 0.95 + v(gy, gx) * 0.3 - 0.5 + (rand - 0.5) * 0.4;
                ex(i) = ex(i) + evx(i);
                ey(i) = ey(i) + evy(i);
                if ex(i) < 1 || ex(i) > Nx || ey(i) < 1 || ey(i) > Ny
                    emberLife(i) = 0;
                end
            end

            % Spawn new embers from hot regions
            deadSlots = find(emberLife <= 0);
            if ~isempty(deadSlots) && obj.FrameCount > 5
                interior = temp(ghost+1:end-ghost, ghost+1:end-ghost);
                hotMask = interior > 0.8;
                nHot = nnz(hotMask);
                if nHot > 0
                    isSparkler = obj.SubMode == "torch";
                    maxPerFrame = 2 + 4 * isSparkler;
                    nSpawn = min(maxPerFrame, min(numel(deadSlots), nHot));
                    [hotRows, hotCols] = find(hotMask);
                    pick = randperm(nHot, nSpawn);
                    for s = 1:nSpawn
                        slot = deadSlots(s);
                        ex(slot) = ghost + hotCols(pick(s));
                        ey(slot) = ghost + hotRows(pick(s));
                        if isSparkler
                            ang = rand * 2 * pi;
                            spd = 1.5 + rand * 3.0;
                            evx(slot) = spd * cos(ang);
                            evy(slot) = spd * sin(ang);
                            emberLife(slot) = 0.3 + rand * 0.4;
                        else
                            evx(slot) = (rand - 0.5) * 1.5;
                            evy(slot) = -1.0 - rand * 1.5;
                            emberLife(slot) = 0.6 + rand * 0.4;
                        end
                    end
                end
            end

            obj.EmberX = ex;
            obj.EmberY = ey;
            obj.EmberVx = evx;
            obj.EmberVy = evy;
            obj.EmberLife = emberLife;
        end

        function applySubMode(obj)
            %applySubMode  Apply sub-mode parameters, reset fields, update HUD.
            switch obj.SubMode
                case "campfire"
                    obj.Buoyancy = 1.0;
                    obj.Cooling = 0.02;
                    obj.Combustion = 0.5;
                    obj.MaxEmbers = 50;
                case "wall"
                    obj.Buoyancy = 0.05;
                    obj.Cooling = 0.025;
                    obj.Combustion = 0.5;
                    obj.MaxEmbers = 50;
                case "torch"
                    obj.Buoyancy = 0.3;
                    obj.Cooling = 0.08;
                    obj.Combustion = 0.8;
                    obj.MaxEmbers = 120;
                case "wildfire"
                    obj.Buoyancy = 0.03;
                    obj.Cooling = 0.001;
                    obj.Combustion = 0.03;
                    obj.MaxEmbers = 50;
            end

            % Reset fields for fresh start
            ghost = obj.GhostCells;
            Ny = obj.GridH + 2 * ghost;
            Nx = obj.GridW + 2 * ghost;
            obj.Ux = zeros(Ny, Nx);
            obj.Uy = zeros(Ny, Nx);
            obj.Temp = zeros(Ny, Nx);
            obj.Fuel = zeros(Ny, Nx);
            obj.FrameCount = 0;
            obj.placeFuel();

            % Reset embers
            nEmb = obj.MaxEmbers;
            obj.EmberX = NaN(nEmb, 1);
            obj.EmberY = NaN(nEmb, 1);
            obj.EmberVx = zeros(nEmb, 1);
            obj.EmberVy = zeros(nEmb, 1);
            obj.EmberLife = zeros(nEmb, 1);
            if ~isempty(obj.EmberH) && isvalid(obj.EmberH)
                set(obj.EmberH, "XData", NaN, "YData", NaN);
            end
            if ~isempty(obj.EmberGlowH) && isvalid(obj.EmberGlowH)
                set(obj.EmberGlowH, "XData", NaN, "YData", NaN);
            end
            % Clear fire image
            if ~isempty(obj.ImageH) && isvalid(obj.ImageH)
                obj.ImageH.CData = zeros(obj.GridH, obj.GridW, 3, "uint8");
                obj.ImageH.AlphaData = zeros(obj.GridH, obj.GridW);
            end

            % Update HUD label
            obj.updateModeLabel();
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Change fire grid resolution with up/down arrows.
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

        function updateModeLabel(obj)
            %updateModeLabel  Refresh the bottom-left HUD text.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end
    end
end
