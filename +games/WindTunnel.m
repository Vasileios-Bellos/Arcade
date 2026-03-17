classdef WindTunnel < GameBase
    %WindTunnel  LBM D2Q9 lattice Boltzmann wind tunnel simulation.
    %   Simulates 2D incompressible fluid flow around obstacles using the
    %   Bhatnagar-Gross-Krook (BGK) collision operator on a D2Q9 lattice.
    %   Zou-He inlet boundary, free-slip walls, partial bounce-back
    %   obstacles with SDF-based solid fraction for smooth boundaries.
    %
    %   Features:
    %     - 2 obstacle shapes: cylinder, NACA 0012 airfoil (B key)
    %     - 6 visualization sub-modes: dye, velocity, vorticity, curl,
    %       streamlines, paint (M key)
    %     - 5 dye injection modes: dye, smoke, rainbow, colormap (N key)
    %     - 17 MATLAB colormaps via Shift+Left/Right
    %     - 10 grid resolution levels (Up/Down)
    %     - Adjustable inlet velocity (Left/Right)
    %     - Adjustable dye volume (Shift+Up/Down)
    %     - Render-grid upscaling (min 300 rows) for anti-aliased obstacles
    %
    %   Standalone: games.WindTunnel().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost, games.FluidUtils

    properties (Constant)
        Name = "Wind Tunnel"
    end

    % =================================================================
    % SIMULATION STATE
    % =================================================================
    properties (Access = private)
        % LBM fields
        F               (:,:,:) double      % distribution functions (Ny, Nx, 9)
        Rho             (:,:) double        % density field
        Ux              (:,:) double        % x-velocity field
        Uy              (:,:) double        % y-velocity field

        % Obstacle
        ObstMask        (:,:) logical       % obstacle cells (shrunk for physics)
        ObstFullMask    (:,:) logical       % unshrunk obstacle (for quiver masking)
        ObstNs          (:,:) double        % solid fraction for partial bounce-back
        BounceIdx1      (:,1) double        % precomputed bounce-back src
        BounceIdx2      (:,1) double        % precomputed bounce-back dst
        ObstShape       (1,1) string = "cylinder"  % B key: cylinder|airfoil
        CylX            (1,1) double = 0    % cylinder center X (grid)
        CylY            (1,1) double = 0    % cylinder center Y (grid)
        CylR            (1,1) double = 0    % cylinder radius (grid)
        ObstBlend       (:,:) double        % anti-aliased obstacle blend on render grid
        ObstCharLen     (1,1) double = 0    % characteristic length for Re
        ObstOutlineX    (:,1) double        % outline polygon X (display coords)
        ObstOutlineY    (:,1) double        % outline polygon Y (display coords)

        % Grid
        GridW           (1,1) double = 120
        GridH           (1,1) double = 90
        GridLevel       (1,1) double = 6    % 1-10
        RenderNx        (1,1) double = 0    % render grid width (>= physics)
        RenderNy        (1,1) double = 0    % render grid height

        % Meshgrid cache
        Gx              (:,:) double        % meshgrid X for advection
        Gy              (:,:) double        % meshgrid Y for advection

        % Physics params
        UIn             (1,1) double = 0.09 % inlet velocity (lattice units)
        UInLevel        (1,1) double = 7    % 1-10
        Tau             (1,1) double = 0.56 % relaxation time
        SubSteps        (1,1) double = 8    % physics steps per render frame

        % Visualization
        SubMode         (1,1) string = "dye"    % dye|velocity|vorticity|curl|streamlines|paint
        InjMode         (1,1) string = "dye"    % N key: dye|smoke|rainbow|colormap
        ColormapIdx     (1,1) double = 1        % index into lbmColormapNames
        ColormapRGB     (256,3) double = zeros(256, 3)  % cached 256x3 colormap

        % Passive dye advection
        DyeR            (:,:) double        % red dye channel
        DyeG            (:,:) double        % green dye channel
        DyeB            (:,:) double        % blue dye channel
        DyeDecay        (1,1) double = 0.004    % dye decay per substep
        DyeVolume       (1,1) double = 1.0      % injection strength (0.2-3.0)

        % Quiver arrows
        QuiverSkip      (1,1) double = 5    % subsampling step

        % Stats
        FrameCount      (1,1) double = 0
        PeakSpeed       (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ImageH                              % image overlay
        ObstLineH                           % line -- obstacle boundary glow
        QuiverH                             % quiver -- velocity field arrows
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create LBM wind tunnel simulation and graphics.
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

            % Grid size from level (4:3 aspect ratio)
            % Ny always multiple of 6 so cylinder radius is exact integer
            baseSizes = [40 30; 48 36; 56 42; 80 60; 96 72; ...
                         120 90; 144 108; 176 132; 200 150; 240 180];
            level = max(1, min(10, obj.GridLevel));
            obj.GridW = baseSizes(level, 1);
            obj.GridH = baseSizes(level, 2);
            Nx = obj.GridW;
            Ny = obj.GridH;

            % Scale substeps proportional to grid width so the physical
            % time per frame is constant regardless of resolution.
            NxRef = 120;
            nSubBase = 12;
            obj.SubSteps = max(4, round(nSubBase * Nx / NxRef));

            % D2Q9 lattice velocities and weights
            latCx = [0, 1, 0, -1, 0, 1, -1, -1, 1];
            wts   = [4/9, 1/9, 1/9, 1/9, 1/9, 1/36, 1/36, 1/36, 1/36];

            % Initialize f to equilibrium with uniform inlet velocity
            uInVal = obj.UIn;
            usq = uInVal^2;
            obj.F = zeros(Ny, Nx, 9);
            for i = 1:9
                cu = latCx(i) * uInVal;
                obj.F(:,:,i) = wts(i) * (1 + 3*cu + 4.5*cu^2 - 1.5*usq);
            end

            obj.Rho = ones(Ny, Nx);
            obj.Ux = uInVal * ones(Ny, Nx);
            obj.Uy = zeros(Ny, Nx);

            % Asymmetric perturbation to trigger vortex shedding quickly
            obj.Uy = 0.003 * randn(Ny, Nx);

            [gx, gy] = meshgrid(1:Nx, 1:Ny);

            % Render grid: minimum 300 rows for smooth obstacle
            obj.RenderNy = max(Ny, 300);
            obj.RenderNx = round(obj.RenderNy * Nx / Ny);
            rNx = obj.RenderNx;
            rNy = obj.RenderNy;

            % Build obstacle mask, blend, and outline
            obj.buildObstacle(gx, gy, dxRange, dyRange);

            % Smooth velocity damping inside obstacles
            fluidFrac = 1 - obj.ObstNs;
            obj.Ux = obj.Ux .* fluidFrac;
            obj.Uy = obj.Uy .* fluidFrac;

            % Initialize passive dye fields (RGB)
            obj.DyeR = zeros(Ny, Nx);
            obj.DyeG = zeros(Ny, Nx);
            obj.DyeB = zeros(Ny, Nx);
            obj.Gx = gx;
            obj.Gy = gy;

            % State
            obj.FrameCount = 0;
            obj.PeakSpeed = 0;

            % --- Graphics ---
            % Main image overlay (render grid resolution for smooth cylinder)
            obj.ImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", zeros(rNy, rNx, 3, "uint8"), ...
                "AlphaData", zeros(rNy, rNx), ...
                "Interpolation", "bilinear", "Tag", "GT_windtunnel");

            % Obstacle glow outline
            obj.ObstLineH = line(ax, ...
                obj.ObstOutlineX, obj.ObstOutlineY, ...
                "Color", [0.4, 0.8, 1.0, 0.5], "LineWidth", 2.5, ...
                "Tag", "GT_windtunnel");

            % Quiver arrows (for streamlines mode)
            skipVal = max(4, round(Nx / 25));
            obj.QuiverSkip = skipVal;
            qx = 1:skipVal:Nx;
            qy = 1:skipVal:Ny;
            [QX, QY] = meshgrid(qx, qy);
            dispQX = dxRange(1) + (QX - 1) / max(1, Nx - 1) * diff(dxRange);
            dispQY = dyRange(1) + (QY - 1) / max(1, Ny - 1) * diff(dyRange);
            obj.QuiverH = quiver(ax, dispQX, dispQY, ...
                zeros(size(QX)), zeros(size(QY)), 0.8, ...
                "Color", [0, 0.9, 1, 0.7], "LineWidth", 1.2, ...
                "MaxHeadSize", 0.5, "Visible", "off", "Tag", "GT_windtunnel");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame LBM wind tunnel with dye advection.
            if isempty(obj.F); return; end

            Ny = obj.GridH;
            Nx = obj.GridW;
            fDist = obj.F;
            tauVal = obj.Tau;
            uInVal = obj.UIn;
            invTau = 1 / tauVal;

            % D2Q9 lattice constants
            latCx = [0, 1, 0, -1, 0, 1, -1, -1, 1];
            latCy = [0, 0, 1, 0, -1, 1, 1, -1, -1];
            wts   = [4/9, 1/9, 1/9, 1/9, 1/9, 1/36, 1/36, 1/36, 1/36];
            cxR = reshape(latCx, 1, 1, 9);
            cyR = reshape(latCy, 1, 1, 9);
            wR  = reshape(wts, 1, 1, 9);
            obstMaskLocal = obj.ObstMask;

            % --- Finger interaction ---
            fingerGx = NaN; fingerGy = NaN;
            if ~any(isnan(pos))
                dxR = obj.DisplayRange.X;
                dyR = obj.DisplayRange.Y;
                fingerGx = 1 + (pos(1) - dxR(1)) / diff(dxR) * (Nx - 1);
                fingerGy = 1 + (pos(2) - dyR(1)) / diff(dyR) * (Ny - 1);
            end

            if obj.SubMode == "paint" && ~isnan(fingerGx)
                % Paint obstacles
                paintR = max(2, round(Ny / 15));
                fxi = round(fingerGx); fyi = round(fingerGy);
                if fingerGx > 3 && fingerGx < Nx - 2 && ...
                        fingerGy > 2 && fingerGy < Ny - 1
                    changed = false;
                    rMin = max(2, fyi - paintR);
                    rMax = min(Ny - 1, fyi + paintR);
                    cMin = max(3, fxi - paintR);
                    cMax = min(Nx - 1, fxi + paintR);
                    pr2 = paintR^2;
                    for r = rMin:rMax
                        for c = cMin:cMax
                            if (c - fingerGx)^2 + (r - fingerGy)^2 <= pr2 ...
                                    && ~obstMaskLocal(r, c)
                                obstMaskLocal(r, c) = true;
                                changed = true;
                            end
                        end
                    end
                    if changed
                        obj.ObstMask = obstMaskLocal;
                        obj.updateBounceIndices();
                    end
                end
            end

            % --- LBM sub-steps ---
            for stepIdx = 1:obj.SubSteps
                % 1. Macroscopic quantities
                rho = sum(fDist, 3);
                rho = max(rho, 0.5);
                ux = sum(fDist .* cxR, 3) ./ rho;
                uy = sum(fDist .* cyR, 3) ./ rho;
                fluidFrac = 1 - obj.ObstNs;
                ux = ux .* fluidFrac;
                uy = uy .* fluidFrac;

                % Finger force injection (non-paint modes): velocity splat
                if obj.SubMode ~= "paint" && ~isnan(fingerGx)
                    splatR = max(3, round(Ny / 10));
                    splatStr = 0.005;
                    distSq = (obj.Gx - fingerGx).^2 + ...
                             (obj.Gy - fingerGy).^2;
                    gauss = exp(-distSq / (2 * splatR^2));
                    gauss(obstMaskLocal) = 0;
                    ux = ux + splatStr * uInVal * 3 * gauss;
                    uy = uy + splatStr * 0.5 * gauss;
                end

                % Safety clamp: keep Ma < 0.25
                maxU = 0.144;
                speedSq = ux.^2 + uy.^2;
                tooFast = speedSq > maxU^2;
                if any(tooFast(:))
                    sc = maxU ./ sqrt(speedSq(tooFast));
                    ux(tooFast) = ux(tooFast) .* sc;
                    uy(tooFast) = uy(tooFast) .* sc;
                end

                % 2. Equilibrium distribution
                cu = ux .* cxR + uy .* cyR;
                usq = ux.^2 + uy.^2;
                feq = wR .* rho .* (1 + 3*cu + 4.5*cu.^2 - 1.5*usq);

                % 3. BGK collision
                fDist = fDist - invTau * (fDist - feq);

                % 4. Save post-collision for partial bounce-back
                fPost = fDist;

                % 5. Save wall distributions before streaming
                topOut5 = fDist(1, :, 5);
                topOut8 = fDist(1, :, 8);
                topOut9 = fDist(1, :, 9);
                botOut3 = fDist(Ny, :, 3);
                botOut6 = fDist(Ny, :, 6);
                botOut7 = fDist(Ny, :, 7);

                % 6. Streaming
                fNew = zeros(Ny, Nx, 9);
                fNew(:,:,1)               = fDist(:,:,1);
                fNew(:, 2:end, 2)         = fDist(:, 1:end-1, 2);
                fNew(2:end, :, 3)         = fDist(1:end-1, :, 3);
                fNew(:, 1:end-1, 4)       = fDist(:, 2:end, 4);
                fNew(1:end-1, :, 5)       = fDist(2:end, :, 5);
                fNew(2:end, 2:end, 6)     = fDist(1:end-1, 1:end-1, 6);
                fNew(2:end, 1:end-1, 7)   = fDist(1:end-1, 2:end, 7);
                fNew(1:end-1, 1:end-1, 8) = fDist(2:end, 2:end, 8);
                fNew(1:end-1, 2:end, 9)   = fDist(2:end, 1:end-1, 9);
                fDist = fNew;

                % 7. Partial bounce-back (grayscale method)
                ns = obj.ObstNs;
                opp = [1, 4, 5, 2, 3, 8, 9, 6, 7];
                for qi = 1:9
                    fDist(:,:,qi) = (1 - ns) .* fDist(:,:,qi) + ...
                        ns .* fPost(:,:,opp(qi));
                end

                % 8. Free-slip walls
                fDist(1, :, 3)  = topOut5;
                fDist(1, :, 6)  = topOut9;
                fDist(1, :, 7)  = topOut8;
                fDist(Ny, :, 5) = botOut3;
                fDist(Ny, :, 9) = botOut6;
                fDist(Ny, :, 8) = botOut7;

                % 9. Zou-He inlet
                f1c = fDist(:, 1, 1);
                f3c = fDist(:, 1, 3);
                f5c = fDist(:, 1, 5);
                f4c = fDist(:, 1, 4);
                f7c = fDist(:, 1, 7);
                f8c = fDist(:, 1, 8);
                rhoIn = (f1c + f3c + f5c + 2*(f4c + f7c + f8c)) / (1 - uInVal);
                fDist(:, 1, 2) = f4c + (2/3) * rhoIn * uInVal;
                fDist(:, 1, 6) = f8c + 0.5*(f5c - f3c) + (1/6) * rhoIn * uInVal;
                fDist(:, 1, 9) = f7c + 0.5*(f3c - f5c) + (1/6) * rhoIn * uInVal;

                % 10. Zero-gradient outflow
                fDist(:, Nx, [4 7 8]) = fDist(:, Nx-1, [4 7 8]);
            end

            obj.F = fDist;

            % --- Final macroscopic quantities ---
            rho = sum(fDist, 3);
            rho = max(rho, 0.5);
            ux = sum(fDist .* cxR, 3) ./ rho;
            uy = sum(fDist .* cyR, 3) ./ rho;
            fluidFrac = 1 - obj.ObstNs;
            ux = ux .* fluidFrac;
            uy = uy .* fluidFrac;
            obj.Rho = rho;
            obj.Ux = ux;
            obj.Uy = uy;

            speedField = sqrt(ux.^2 + uy.^2);
            obj.PeakSpeed = max(obj.PeakSpeed, max(speedField(:)));
            obj.FrameCount = obj.FrameCount + 1;

            % --- Dye advection (semi-Lagrangian using LBM velocity) ---
            gx = obj.Gx; gy = obj.Gy;
            nSub = obj.SubSteps;
            Xb = max(1, min(Nx, gx - nSub * ux));
            Yb = max(1, min(Ny, gy - nSub * uy));

            dyeR = games.FluidUtils.fastBilerp(obj.DyeR, Xb, Yb, Ny, Nx);
            dyeG = games.FluidUtils.fastBilerp(obj.DyeG, Xb, Yb, Ny, Nx);
            dyeB = games.FluidUtils.fastBilerp(obj.DyeB, Xb, Yb, Ny, Nx);

            % Finger injection
            tFrame = obj.FrameCount * 0.04;
            vol = obj.DyeVolume;
            if obj.SubMode ~= "paint" && ~isnan(fingerGx)
                dSqF = (gx - fingerGx).^2 + (gy - fingerGy).^2;
                fR = max(2, round(Ny / 12));
                gaussF = exp(-dSqF / (2 * fR^2)) * 0.15 * vol;
                switch obj.InjMode
                    case "smoke"
                        dyeR = dyeR + gaussF * 0.50;
                        dyeG = dyeG + gaussF * 0.50;
                        dyeB = dyeB + gaussF * 0.50;
                    case "rainbow"
                        param = 1 - abs(mod(tFrame * 0.7, 2) - 1);
                        rainbowHues = [0, 30, 60, 120, 240, 275, 300] / 360;
                        hueF = interp1(linspace(0, 1, 7), rainbowHues, param);
                        [rF, gF, bF] = GameBase.hsvToRgb(hueF);
                        dyeR = dyeR + gaussF * rF;
                        dyeG = dyeG + gaussF * gF;
                        dyeB = dyeB + gaussF * bF;
                    case "colormap"
                        cmRaw = mod(floor(tFrame * 40), 510);
                        cmIdx = (cmRaw < 256) * cmRaw + ...
                            (cmRaw >= 256) * (510 - cmRaw) + 1;
                        cmap = obj.ColormapRGB;
                        rF = cmap(cmIdx, 1);
                        gF = cmap(cmIdx, 2);
                        bF = cmap(cmIdx, 3);
                        dyeR = dyeR + gaussF * rF;
                        dyeG = dyeG + gaussF * gF;
                        dyeB = dyeB + gaussF * bF;
                    otherwise  % "dye"
                        hueF = mod(tFrame * 0.5, 1);
                        [rF, gF, bF] = GameBase.hsvToRgb(hueF);
                        dyeR = dyeR + gaussF * rF;
                        dyeG = dyeG + gaussF * gF;
                        dyeB = dyeB + gaussF * bF;
                end
            end

            % Decay and clamp
            if obj.InjMode == "smoke"
                decayMult = 1 - obj.DyeDecay * 2.0;
            else
                decayMult = 1 - obj.DyeDecay;
            end
            dyeR = min(1.0, dyeR * decayMult);
            dyeG = min(1.0, dyeG * decayMult);
            dyeB = min(1.0, dyeB * decayMult);
            % Zero dye inside obstacle
            dyeR(obstMaskLocal) = 0;
            dyeG(obstMaskLocal) = 0;
            dyeB(obstMaskLocal) = 0;

            % Inlet: zero dye at left boundary (clean inflow)
            dyeR(:, 1) = 0; dyeG(:, 1) = 0; dyeB(:, 1) = 0;

            obj.DyeR = dyeR;
            obj.DyeG = dyeG;
            obj.DyeB = dyeB;

            % --- Visualization ---
            % Compute vorticity (central differences + one-sided at edges)
            curlField = zeros(Ny, Nx);
            curlField(:, 2:end-1) = (uy(:, 3:end) - uy(:, 1:end-2)) * 0.5;
            curlField(:, 1) = uy(:, 2) - uy(:, 1);
            curlField(:, end) = uy(:, end) - uy(:, end-1);
            duxdy = zeros(Ny, Nx);
            duxdy(2:end-1, :) = (ux(3:end, :) - ux(1:end-2, :)) * 0.5;
            duxdy(1, :) = ux(2, :) - ux(1, :);
            duxdy(end, :) = ux(end, :) - ux(end-1, :);
            curlField = curlField - duxdy;

            switch obj.SubMode
                case "dye"
                    if obj.InjMode == "smoke"
                        R = min(0.7, dyeR * 1.4);
                        G = min(0.7, dyeG * 1.4);
                        B = min(0.7, dyeB * 1.4);
                    else
                        R = min(1, dyeR * 1.4);
                        G = min(1, dyeG * 1.4);
                        B = min(1, dyeB * 1.4);
                        bright = max(cat(3, R, G, B), [], 3);
                        bloom = bright.^2 * 0.4;
                        R = min(1, R + bloom);
                        G = min(1, G + bloom);
                        B = min(1, B + bloom);
                    end

                case "velocity"
                    normS = min(1, speedField / (uInVal * 2.5));
                    R = min(1, normS * 2.0);
                    G = min(1, normS * 1.5) .* (1 - max(0, normS - 0.6) * 2.5);
                    B = max(0, 1 - normS * 2.0);
                    R = min(1, R + imgaussfilt(R, 1.5) * 0.3);
                    G = min(1, G + imgaussfilt(G, 1.5) * 0.3);
                    B = min(1, B + imgaussfilt(B, 1.5) * 0.3);

                case "vorticity"
                    maxCurl = uInVal * 0.15;
                    sc = max(-1, min(1, curlField / maxCurl));
                    mag = abs(sc).^0.6;
                    R = max(0, sc) .* mag * 1.0;
                    G = max(0, -sc) .* mag * 0.9;
                    B = mag * 0.9;
                    bloom = mag.^2 * 0.3;
                    R = min(1, R + bloom * 0.5);
                    G = min(1, G + bloom * 0.3);
                    B = min(1, B + bloom * 0.4);
                    R = min(1, R + dyeR * 0.25);
                    G = min(1, G + dyeG * 0.25);
                    B = min(1, B + dyeB * 0.25);

                case "curl"
                    maxCurl = uInVal * 0.12;
                    sc = curlField / maxCurl;
                    absSc = min(1, abs(sc).^0.5);
                    wave = sin(sc * 5);
                    R = max(0, sc) .* absSc * 0.8 + absSc * 0.15;
                    G = absSc * 0.3 .* (0.5 + 0.5 * wave);
                    B = max(0, -sc) .* absSc * 0.9 + absSc * 0.2;
                    R = min(1, R + dyeR * 0.6);
                    G = min(1, G + dyeG * 0.6);
                    B = min(1, B + dyeB * 0.6);
                    bright = max(cat(3, R, G, B), [], 3);
                    bloom = bright.^2 * 0.4;
                    R = min(1, R + bloom * 0.5);
                    G = min(1, G + bloom * 0.4);
                    B = min(1, B + bloom * 0.5);

                case "streamlines"
                    maxSpeed = uInVal * 1.5;
                    s = min(1, speedField / maxSpeed);
                    R = s * 0.3;
                    G = s * 0.4;
                    B = 0.08 + s * 0.25;
                    R = min(1, R + dyeR * 0.8);
                    G = min(1, G + dyeG * 0.8);
                    B = min(1, B + dyeB * 0.8);
                    bright = max(cat(3, R, G, B), [], 3);
                    bloom = bright.^2 * 0.3;
                    R = min(1, R + bloom * 0.5);
                    G = min(1, G + bloom * 0.4);
                    B = min(1, B + bloom * 0.5);

                case "paint"
                    maxSpeed = uInVal * 1.5;
                    s = min(1, speedField / maxSpeed);
                    R = s * 0.4;
                    G = s * 0.6;
                    B = 0.1 + s * 0.3;
                    R(obstMaskLocal) = 0.7;
                    G(obstMaskLocal) = 0.7;
                    B(obstMaskLocal) = 0.7;
            end

            % Upscale to render grid and apply anti-aliased obstacle
            rNx = obj.RenderNx;
            rNy = obj.RenderNy;
            if rNy > Ny
                R = imresize(R, [rNy rNx], "bilinear");
                G = imresize(G, [rNy rNx], "bilinear");
                B = imresize(B, [rNy rNx], "bilinear");
            end
            if obj.SubMode ~= "paint"
                cb = obj.ObstBlend;
                R = R .* (1 - cb) + 0.15 * cb;
                G = G .* (1 - cb) + 0.30 * cb;
                B = B .* (1 - cb) + 0.40 * cb;
            end

            img = uint8(cat(3, R, G, B) * 255);
            if obj.SubMode == "dye"
                if obj.InjMode == "smoke"
                    smkDen = max(dyeR, max(dyeG, dyeB));
                    alphaField = min(1, smkDen.^0.6);
                    if rNy > Ny
                        alphaField = imresize(alphaField, [rNy rNx], "bilinear");
                    end
                else
                    alphaField = max(R, max(G, B));
                end
                alphaField = max(alphaField, obj.ObstBlend);
            else
                alphaField = ones(size(R));
            end
            if ~isempty(obj.ImageH) && isvalid(obj.ImageH)
                obj.ImageH.CData = img;
                obj.ImageH.AlphaData = alphaField;
            end

            % --- Update quiver arrows (streamlines mode) ---
            if ~isempty(obj.QuiverH) && isvalid(obj.QuiverH)
                if obj.SubMode == "streamlines"
                    skipVal = obj.QuiverSkip;
                    qux = ux; quy = uy;
                    fm = obj.ObstFullMask;
                    qux(fm) = 0; quy(fm) = 0;
                    obj.QuiverH.UData = qux(1:skipVal:end, 1:skipVal:end);
                    obj.QuiverH.VData = quy(1:skipVal:end, 1:skipVal:end);
                    obj.QuiverH.Visible = "on";
                else
                    obj.QuiverH.Visible = "off";
                end
            end

            % --- Obstacle glow visibility ---
            if ~isempty(obj.ObstLineH) && isvalid(obj.ObstLineH)
                if obj.SubMode == "paint"
                    obj.ObstLineH.Visible = "off";
                else
                    obj.ObstLineH.Visible = "on";
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all wind tunnel graphics and reset state.
            handles = {obj.ImageH, obj.ObstLineH, obj.QuiverH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.ImageH = [];
            obj.ObstLineH = [];
            obj.QuiverH = [];
            obj.F = [];
            obj.Rho = [];
            obj.Ux = [];
            obj.Uy = [];
            obj.ObstMask = [];
            obj.ObstFullMask = [];
            obj.ObstBlend = [];
            obj.RenderNx = 0;
            obj.RenderNy = 0;
            obj.BounceIdx1 = [];
            obj.BounceIdx2 = [];
            obj.DyeR = [];
            obj.DyeG = [];
            obj.DyeB = [];
            obj.Gx = [];
            obj.Gy = [];
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_windtunnel");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle wind tunnel key events.
            %   M = cycle sub-mode, N = injection mode, B = obstacle shape,
            %   Up/Down = grid level, Left/Right = velocity,
            %   Shift+Up/Down = dye volume, Shift+Left/Right = colormap,
            %   0 = reset simulation.
            handled = true;
            switch key
                case "m"
                    modes = ["dye", "velocity", "vorticity", "curl", ...
                        "streamlines", "paint"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                case "n"
                    injModes = ["dye", "smoke", "rainbow", "colormap"];
                    idx = find(injModes == obj.InjMode, 1);
                    obj.InjMode = injModes(mod(idx, numel(injModes)) + 1);
                    if obj.InjMode == "colormap"
                        obj.loadColormap();
                    end
                    Ny = obj.GridH; Nx = obj.GridW;
                    obj.DyeR = zeros(Ny, Nx);
                    obj.DyeG = zeros(Ny, Nx);
                    obj.DyeB = zeros(Ny, Nx);
                case "b"
                    obj.toggleObstShape();
                case {"uparrow", "downarrow"}
                    obj.changeGridLevel(key);
                case {"leftarrow", "rightarrow"}
                    obj.changeVelocity(key);
                case {"shift+uparrow", "shift+downarrow"}
                    if key == "shift+uparrow"
                        obj.DyeVolume = min(3.0, obj.DyeVolume + 0.2);
                    else
                        obj.DyeVolume = max(0.2, obj.DyeVolume - 0.2);
                    end
                case {"shift+leftarrow", "shift+rightarrow"}
                    if obj.InjMode == "colormap"
                        names = GameBase.lbmColormapNames();
                        nNames = numel(names);
                        if key == "shift+rightarrow"
                            obj.ColormapIdx = mod(obj.ColormapIdx, nNames) + 1;
                        else
                            obj.ColormapIdx = mod(obj.ColormapIdx - 2, nNames) + 1;
                        end
                        obj.loadColormap();
                    else
                        handled = false;
                    end
                case "0"
                    obj.resetSimulation();
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return wind tunnel results.
            r.Title = "WIND TUNNEL";
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            nu = (obj.Tau - 0.5) / 3;
            charLen = max(1, obj.ObstCharLen);
            Re = obj.UIn * charLen / max(nu, 1e-6);
            r.Lines = {
                sprintf("Re%s%.0f  |  Grid: %dx%d  |  Peak Speed: %.3f  |  Time: %.0fs", ...
                    char(8776), Re, obj.GridW, obj.GridH, obj.PeakSpeed, elapsed)
            };
        end

        function s = getHudText(obj)
            %getHudText  Return HUD string with sub-mode, injection, obstacle, etc.
            nu = (obj.Tau - 0.5) / 3;
            charLen = max(1, obj.ObstCharLen);
            uInVal = obj.UIn;
            Re = uInVal * charLen / max(nu, 1e-6);
            if obj.InjMode == "colormap"
                names = GameBase.lbmColormapNames();
                cmIdx = max(1, min(numel(names), obj.ColormapIdx));
                injLabel = upper(names(cmIdx)) + " [S" + ...
                    char(8592) + char(8594) + "]";
            else
                injLabel = upper(obj.InjMode);
            end
            if obj.ObstShape == "cylinder"
                shapeLabel = "CYL";
            else
                shapeLabel = "AIRFOIL";
            end
            s = sprintf( ...
                "%s [M]  |  %s [N]  |  %s [B]  |  Vol %.1f [S%s%s]  |  Grid %d/%d [%s%s]  |  U %.3f [%s%s]  |  Re%s%.0f", ...
                upper(obj.SubMode), injLabel, shapeLabel, obj.DyeVolume, ...
                char(8593), char(8595), ...
                obj.GridLevel, 10, char(8593), char(8595), ...
                uInVal, char(8592), char(8594), char(8776), Re);
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function updateBounceIndices(obj)
            %updateBounceIndices  Precompute linear index pairs for bounce-back.
            Ny = obj.GridH;
            Nx = obj.GridW;
            NyNx = Ny * Nx;
            obstIdx = find(obj.ObstFullMask);
            nO = numel(obstIdx);
            if nO == 0
                obj.BounceIdx1 = [];
                obj.BounceIdx2 = [];
                return;
            end
            pairs = [2 4; 3 5; 6 8; 7 9];
            idx1 = zeros(nO * 4, 1);
            idx2 = zeros(nO * 4, 1);
            for k = 1:4
                rng = (k-1)*nO + (1:nO);
                idx1(rng) = obstIdx + (pairs(k,1) - 1) * NyNx;
                idx2(rng) = obstIdx + (pairs(k,2) - 1) * NyNx;
            end
            obj.BounceIdx1 = idx1;
            obj.BounceIdx2 = idx2;
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Resize LBM grid resolution.
            oldLevel = obj.GridLevel;
            if key == "uparrow"
                obj.GridLevel = min(10, obj.GridLevel + 1);
            else
                obj.GridLevel = max(1, obj.GridLevel - 1);
            end
            if obj.GridLevel ~= oldLevel
                savedSubMode = obj.SubMode;
                savedInjMode = obj.InjMode;
                savedObstShape = obj.ObstShape;
                savedVol = obj.DyeVolume;
                savedUInLevel = obj.UInLevel;
                savedUIn = obj.UIn;
                savedCmIdx = obj.ColormapIdx;
                savedCmRGB = obj.ColormapRGB;

                obj.onCleanup();

                obj.SubMode = savedSubMode;
                obj.InjMode = savedInjMode;
                obj.ObstShape = savedObstShape;
                obj.DyeVolume = savedVol;
                obj.UInLevel = savedUInLevel;
                obj.UIn = savedUIn;
                obj.ColormapIdx = savedCmIdx;
                obj.ColormapRGB = savedCmRGB;

                obj.onInit(obj.Ax, obj.DisplayRange, struct());
            end
        end

        function changeVelocity(obj, key)
            %changeVelocity  Change inlet velocity (left/right arrow).
            if key == "rightarrow"
                obj.UInLevel = min(10, obj.UInLevel + 1);
            else
                obj.UInLevel = max(1, obj.UInLevel - 1);
            end
            % Level 1-10 maps to velocity 0.03-0.12 (Ma < 0.21)
            obj.UIn = 0.03 + (obj.UInLevel - 1) * 0.01;
        end

        function loadColormap(obj)
            %loadColormap  Cache the current colormap's 256x3 RGB matrix.
            names = GameBase.lbmColormapNames();
            idx = max(1, min(numel(names), obj.ColormapIdx));
            cmName = names(idx);
            try
                obj.ColormapRGB = feval(cmName, 256);
            catch
                obj.ColormapRGB = jet(256);
            end
        end

        function toggleObstShape(obj)
            %toggleObstShape  Switch between cylinder and airfoil (B key).
            if obj.ObstShape == "cylinder"
                obj.ObstShape = "airfoil";
            else
                obj.ObstShape = "cylinder";
            end
            Ny = obj.GridH; Nx = obj.GridW;
            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;
            [gx, gy] = meshgrid(1:Nx, 1:Ny);
            obj.buildObstacle(gx, gy, dxRange, dyRange);
            % Update outline graphics
            if ~isempty(obj.ObstLineH) && isvalid(obj.ObstLineH)
                obj.ObstLineH.XData = obj.ObstOutlineX;
                obj.ObstLineH.YData = obj.ObstOutlineY;
            end
            % Smooth velocity damping inside new obstacle, clear dye
            fluidFrac = 1 - obj.ObstNs;
            obj.Ux = obj.Ux .* fluidFrac;
            obj.Uy = obj.Uy .* fluidFrac;
            obj.DyeR = zeros(Ny, Nx);
            obj.DyeG = zeros(Ny, Nx);
            obj.DyeB = zeros(Ny, Nx);
        end

        function resetSimulation(obj)
            %resetSimulation  Reset simulation to initial state at current settings.
            savedSubMode = obj.SubMode;
            savedInjMode = obj.InjMode;
            savedObstShape = obj.ObstShape;
            savedVol = obj.DyeVolume;
            savedUInLevel = obj.UInLevel;
            savedUIn = obj.UIn;
            savedCmIdx = obj.ColormapIdx;
            savedCmRGB = obj.ColormapRGB;

            obj.onCleanup();

            obj.SubMode = savedSubMode;
            obj.InjMode = savedInjMode;
            obj.ObstShape = savedObstShape;
            obj.DyeVolume = savedVol;
            obj.UInLevel = savedUInLevel;
            obj.UIn = savedUIn;
            obj.ColormapIdx = savedCmIdx;
            obj.ColormapRGB = savedCmRGB;

            obj.onInit(obj.Ax, obj.DisplayRange, struct());
        end

        function buildObstacle(obj, gx, gy, dxRange, dyRange)
            %buildObstacle  Create obstacle mask, render blend, and outline.
            Ny = obj.GridH;
            Nx = obj.GridW;
            rNx = obj.RenderNx;
            rNy = obj.RenderNy;
            [rgx, rgy] = meshgrid( ...
                linspace(1, Nx, rNx), linspace(1, Ny, rNy));

            centerX = round(0.35 * Nx);
            centerY = round(0.5 * Ny) + 0.5;
            % Snap center to nearest quiver row/col for symmetric streamlines
            qSkip = max(4, round(Nx / 25));
            qRows = 1:qSkip:Ny;
            qCols = 1:qSkip:Nx;
            [~, nr] = min(abs(qRows - centerY));
            [~, nc] = min(abs(qCols - centerX));
            centerY = qRows(nr);
            centerX = qCols(nc);
            obj.CylX = centerX;
            obj.CylY = centerY;

            % Shrink physics boundary inward so staircase edges stay
            % hidden inside the displayed outline (0.5 cell inset)
            physShrink = 0.5;

            switch obj.ObstShape
                case "cylinder"
                    R = max(3, round(Ny / 6));
                    obj.CylR = R;
                    obj.ObstCharLen = R * 2;
                    % Smooth SDF on physics grid
                    distField = sqrt((gx - centerX).^2 + (gy - centerY).^2);
                    sdfField = R - distField;
                    transWidth = 1.5;
                    cylNs = max(0, min(1, sdfField / transWidth + 0.5));
                    obj.ObstFullMask = cylNs > 0;
                    sdfPhys = sdfField - physShrink;
                    obj.ObstMask = sdfPhys >= 0;
                    % Render blend uses FULL radius (no shrink)
                    rDist = sqrt((rgx - centerX).^2 + (rgy - centerY).^2);
                    obj.ObstBlend = max(0, min(1, R + 0.5 - rDist));
                    % Outline in display coords (full radius)
                    nTh = 64;
                    theta = linspace(0, 2*pi, nTh)';
                    oX = centerX + R * cos(theta);
                    oY = centerY + R * sin(theta);

                case "airfoil"
                    % Clark Y airfoil -- UIUC data, pchip-upsampled
                    chord = max(8, round(Ny / 2.5));
                    obj.ObstCharLen = chord;
                    aoa = -12 * pi / 180;
                    % Clark Y upper surface (20 key UIUC points)
                    xUd = [0 .001 .004 .012 .02 .04 .06 .10 ...
                           .16 .22 .30 .36 .42 .50 .60 .70 ...
                           .80 .90 .96 1.0]';
                    yUd = [0 .00373 .00892 .01786 .02537 .03913 ...
                           .04876 .06300 .07757 .08614 .09068 ...
                           .09163 .09057 .08588 .07576 .06143 ...
                           .04388 .02350 .01002 .00060]';
                    % Clark Y lower surface (20 key points)
                    xLd = [0 .001 .004 .012 .02 .04 .06 .10 ...
                           .16 .22 .30 .40 .50 .60 .70 .80 ...
                           .86 .92 .96 1.0]';
                    yLd = [0 -.00594 -.01051 -.01697 -.02027 ...
                           -.02452 -.02713 -.02938 -.03025 -.02914 ...
                           -.02631 -.02330 -.01920 -.01510 -.01100 ...
                           -.00700 -.00460 -.00260 -.00120 -.00060]';
                    % Scale Y 2x for thicker profile
                    yUd = yUd * 2.0;
                    yLd = yLd * 2.0;
                    % Upsample with pchip + cosine spacing (300 pts)
                    nPts = 300;
                    betaAngle = linspace(0, pi, nPts)';
                    xq = 0.5 * (1 - cos(betaAngle));
                    yUq = pchip(xUd, yUd, xq);
                    yLq = pchip(xLd, yLd, xq);
                    % Closed polygon (upper LE->TE, lower TE->LE, close)
                    xPoly = [xq; flipud(xq(2:end)); xq(1)];
                    yPoly = [yUq; flipud(yLq(2:end)); yUq(1)];
                    % Flip upside down (camber on bottom in display)
                    yPoly = -yPoly;
                    % Rotate by AoA
                    cosA = cos(aoa); sinA = sin(aoa);
                    xR = xPoly * cosA + yPoly * sinA;
                    yR = -xPoly * sinA + yPoly * cosA;
                    % Scale and position
                    xR = xR * chord + centerX - chord * 0.3;
                    yR = yR * chord;
                    yMid = (max(yR) + min(yR)) / 2;
                    yR = yR - yMid + centerY;
                    % Analytical SDF: min distance to polygon boundary
                    px = xR(:); py = yR(:);
                    gxf = gx(:)'; gyf = gy(:)';
                    dSq = (gxf - px).^2 + (gyf - py).^2;
                    minDist = sqrt(min(dSq, [], 1));
                    sdfPhys = reshape(minDist, Ny, Nx);
                    rawInside = inpolygon(gx, gy, xR, yR);
                    obj.ObstFullMask = rawInside;
                    sdfPhys(~rawInside) = -sdfPhys(~rawInside);
                    sdfPhys = sdfPhys - physShrink;
                    obj.ObstMask = sdfPhys >= 0;
                    % Render blend uses FULL polygon (no shrink)
                    rInside = inpolygon(rgx, rgy, xR, yR);
                    rDistIn = bwdist(~rInside);
                    rDistOut = bwdist(rInside);
                    rSdf = double(rDistIn) - double(rDistOut);
                    blendField = max(0, min(1, rSdf + 0.5));
                    obj.ObstBlend = imgaussfilt(blendField, 0.6);
                    % Outline (full polygon)
                    oX = xR;
                    oY = yR;
            end

            % Keep boundaries clear
            obj.ObstMask(1, :) = false;
            obj.ObstMask(Ny, :) = false;
            obj.ObstMask(:, 1) = false;
            obj.ObstMask(:, Nx) = false;

            % Partial bounce-back: smooth solid fraction
            if obj.ObstShape == "cylinder"
                nsField = cylNs;
            else
                halfBand = 1.0;
                nsField = zeros(Ny, Nx);
                nsField(sdfPhys >= halfBand) = 1.0;
                insideBand = sdfPhys > 0 & sdfPhys < halfBand;
                nsField(insideBand) = sdfPhys(insideBand) / halfBand;
            end
            % Clear boundaries (must remain fluid)
            nsField(1, :) = 0; nsField(Ny, :) = 0;
            nsField(:, 1) = 0; nsField(:, Nx) = 0;
            obj.ObstNs = nsField;

            obj.updateBounceIndices();

            % Convert outline to display coords
            obj.ObstOutlineX = dxRange(1) + (oX - 1) / max(1, Nx - 1) * diff(dxRange);
            obj.ObstOutlineY = dyRange(1) + (oY - 1) / max(1, Ny - 1) * diff(dyRange);
        end
    end
end
