classdef RippleTank < GameBase
    %RippleTank  2D wave equation PDE with Blinn-Phong liquid surface rendering.
    %   Finger acts as an oscillating point source. Three sub-modes: ripple
    %   (continuous), raindrop (periodic impulse), interference (two sources).
    %   Wave physics: viscous damping + uniform energy drain + Neumann boundaries.
    %   Rendering: Blinn-Phong specular + half-Lambert diffuse + bloom.
    %
    %   Standalone: games.RippleTank().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Ripple Tank"
    end

    % =================================================================
    % SIMULATION STATE
    % =================================================================
    properties (Access = private)
        U               (:,:) double            % current height field
        UPrev           (:,:) double            % previous height field
        GridW           (1,1) double = 80       % visible grid width
        GridH           (1,1) double = 60       % visible grid height
        Damping         (1,1) double = 0.996    % wave energy dissipation
        WaveSpeed       (1,1) double = 0.45     % c (Courant number)
        Omega           (1,1) double = 0.5      % source oscillation frequency
        Amplitude       (1,1) double = 5.0      % source injection amplitude
        Phase           (1,1) double = 0        % oscillation phase accumulator
        Viscosity       (1,1) double = 0.15     % viscous damping (high-freq faster)
        Gx              (:,:) double            % cached meshgrid X
        Gy              (:,:) double            % cached meshgrid Y
        SubMode         (1,1) string = "ripple" % ripple|raindrop|interference
        FixedSrcX       (1,1) double = NaN      % secondary source position X
        FixedSrcY       (1,1) double = NaN      % secondary source position Y
        GridLevel       (1,1) double = 10       % 1-10
        PeakAmp         (1,1) double = 0        % peak amplitude seen
        FrameCount      (1,1) double = 0        % total frames rendered
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ImageH                                  % image object for surface
        ModeTextH                               % text -- bottom-left HUD label
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create ripple tank grid and image overlay.
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

            % Grid size from level (10 levels)
            sizes = [30 40 50 60 70 80 100 120 140 160];
            level = max(1, min(10, obj.GridLevel));
            baseW = sizes(level);
            aspect = diff(dxRange) / diff(dyRange);
            obj.GridW = baseW;
            obj.GridH = max(20, round(baseW / aspect));
            Nx = obj.GridW;
            Ny = obj.GridH;

            % Initialize height fields and cached meshgrid
            obj.U = zeros(Ny, Nx);
            obj.UPrev = zeros(Ny, Nx);
            obj.Gx = repmat(1:Nx, Ny, 1);
            obj.Gy = repmat((1:Ny)', 1, Nx);
            obj.Phase = 0;
            obj.PeakAmp = 0;
            obj.FrameCount = 0;
            obj.SubMode = "ripple";

            % Fixed source for interference mode (center-left)
            obj.FixedSrcX = round(Nx * 0.3);
            obj.FixedSrcY = round(Ny * 0.5);

            % Create image overlay
            blackFrame = zeros(Ny, Nx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", blackFrame, "AlphaData", zeros(Ny, Nx), ...
                "AlphaDataMapping", "none", "Interpolation", "bilinear", ...
                "Tag", "GT_rippletank");
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");

            % Bottom-left HUD text
            obj.ModeTextH = text(ax, dxRange(1) + 5, dyRange(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_rippletank");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame wave equation with viscous damping + Blinn-Phong.
            %   Physics: d^2u/dt^2 = c^2 * laplacian(u) + nu * laplacian(du/dt)
            %   Viscous term damps high-frequency waves faster (physically correct).
            %   Rendering: Blinn-Phong surface normal shading with Fresnel alpha.
            if isempty(obj.U); return; end

            Ny = obj.GridH;
            Nx = obj.GridW;
            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;
            uField = obj.U;
            uPrevField = obj.UPrev;
            c2 = obj.WaveSpeed^2;
            nu = obj.Viscosity;
            gx = obj.Gx;
            gy = obj.Gy;

            % --- Inject source at finger position ---
            dsR = obj.DtScale;
            obj.Phase = obj.Phase + obj.Omega * dsR;
            if ~any(isnan(pos))
                fx = (pos(1) - dxRange(1)) / diff(dxRange) * Nx;
                fy = (pos(2) - dyRange(1)) / diff(dyRange) * Ny;
                fx = max(2, min(Nx - 1, fx));
                fy = max(2, min(Ny - 1, fy));
                splat = exp(-((gx - fx).^2 + (gy - fy).^2) / (2 * 2.5^2));

                amp = obj.Amplitude;
                switch obj.SubMode
                    case "ripple"
                        % Continuous oscillating point source
                        uField = uField + sin(obj.Phase) * amp * splat;
                    case "raindrop"
                        % Periodic impulse drops near finger with random offset
                        if mod(obj.FrameCount, 6) == 0
                            offx = (rand - 0.5) * 8;
                            offy = (rand - 0.5) * 8;
                            dropSplat = exp(-((gx - fx - offx).^2 + ...
                                (gy - fy - offy).^2) / (2 * 1.8^2));
                            uField = uField - amp * 1.3 * dropSplat;
                        end
                    case "interference"
                        uField = uField + sin(obj.Phase) * amp * splat;
                end
            end

            % Fixed source for interference mode
            if obj.SubMode == "interference"
                srcX = obj.FixedSrcX;
                srcY = obj.FixedSrcY;
                splat2 = exp(-((gx - srcX).^2 + (gy - srcY).^2) / (2 * 2.5^2));
                uField = uField + sin(obj.Phase) * obj.Amplitude * splat2;
            end

            % --- Wave equation with viscous damping ---
            % d^2u/dt^2 = c^2 * laplacian(u) + nu * laplacian(du/dt)
            % Viscous term: nu * laplacian(velocity) damps high-frequency waves
            % faster because Laplacian amplifies short wavelengths

            % 5-point Laplacian of height field
            lap = zeros(Ny, Nx);
            lap(2:end-1, 2:end-1) = uField(2:end-1, 3:end) + uField(2:end-1, 1:end-2) + ...
                uField(3:end, 2:end-1) + uField(1:end-2, 2:end-1) - 4 * uField(2:end-1, 2:end-1);

            % Laplacian of velocity (u - uPrev) for viscous dissipation
            vel = uField - uPrevField;
            lapVel = zeros(Ny, Nx);
            lapVel(2:end-1, 2:end-1) = vel(2:end-1, 3:end) + vel(2:end-1, 1:end-2) + ...
                vel(3:end, 2:end-1) + vel(1:end-2, 2:end-1) - 4 * vel(2:end-1, 2:end-1);

            uNew = 2 * uField - uPrevField + c2 * lap + nu * lapVel;

            % Uniform damping for background energy drain (frame-rate scaled)
            uNew = uNew * 0.998^dsR;

            % Reflective (Neumann) boundaries: du/dn = 0 at walls
            uNew(1, :) = uNew(2, :);
            uNew(end, :) = uNew(end-1, :);
            uNew(:, 1) = uNew(:, 2);
            uNew(:, end) = uNew(:, end-1);

            obj.UPrev = uField;
            obj.U = uNew;
            obj.PeakAmp = max(obj.PeakAmp, max(abs(uNew(:))));
            obj.FrameCount = obj.FrameCount + 1;

            % --- Blinn-Phong surface shading (liquid glass caustics) ---
            % Surface normals from height gradient
            dhdx = zeros(Ny, Nx);
            dhdy = zeros(Ny, Nx);
            dhdx(:, 2:end-1) = (uNew(:, 3:end) - uNew(:, 1:end-2)) * 0.5;
            dhdy(2:end-1, :) = (uNew(3:end, :) - uNew(1:end-2, :)) * 0.5;

            % Normal vector: (-dhdx, -dhdy, 1) normalized
            nzComp = 1 ./ sqrt(dhdx.^2 + dhdy.^2 + 1);
            nxComp = -dhdx .* nzComp;
            nyComp = -dhdy .* nzComp;

            % Light direction (upper-left, tilted toward viewer)
            Lx = 0.3; Ly = -0.5; Lz = 0.8;
            Ln = sqrt(Lx^2 + Ly^2 + Lz^2);
            Lx = Lx / Ln; Ly = Ly / Ln; Lz = Lz / Ln;

            % Diffuse (half-Lambert - no hard shadow terminator)
            NdotL = nxComp * Lx + nyComp * Ly + nzComp * Lz;
            diffuseVal = (NdotL * 0.5 + 0.5).^2;

            % Blinn-Phong specular: half-vector H = normalize(L + V)
            % Viewer directly above: V = (0, 0, 1)
            Hx = Lx; Hy = Ly; Hz = Lz + 1;
            Hn = sqrt(Hx^2 + Hy^2 + Hz^2);
            Hx = Hx / Hn; Hy = Hy / Hn; Hz = Hz / Hn;
            NdotH = max(0, nxComp * Hx + nyComp * Hy + nzComp * Hz);
            specularVal = NdotH.^20;  % shiny water (material shininess ~20)

            % Water coloring: Blinn-Phong shading + gentle signed height tint
            heightTint = max(-1, min(1, uNew * 2));  % smooth signed, no kink
            displayR = 0.01 + diffuseVal * 0.05 + specularVal * 0.85 + heightTint * 0.02;
            displayG = 0.04 + diffuseVal * 0.30 + specularVal * 0.90 + heightTint * 0.06;
            displayB = 0.15 + diffuseVal * 0.70 + specularVal * 1.00 + heightTint * 0.08;

            % Bloom on specular highlights
            if Nx >= 30
                bloomVal = imgaussfilt(specularVal, 1.5);
                displayR = displayR + bloomVal * 0.3;
                displayG = displayG + bloomVal * 0.4;
                displayB = displayB + bloomVal * 0.5;
            end

            displayR = min(1, displayR);
            displayG = min(1, displayG);
            displayB = min(1, displayB);

            % Constant alpha overlay
            alphaMap = 0.7 * ones(Ny, Nx);

            frameRGB = uint8(cat(3, displayR, displayG, displayB) * 255);
            if ~isempty(obj.ImageH) && isvalid(obj.ImageH)
                obj.ImageH.CData = frameRGB;
                obj.ImageH.AlphaData = alphaMap;
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete ripple tank graphics and state.
            handles = {obj.ImageH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.ImageH = [];
            obj.ModeTextH = [];
            obj.U = [];
            obj.UPrev = [];
            obj.Gx = [];
            obj.Gy = [];
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_rippletank");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["ripple", "raindrop", "interference"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.updateHud();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle ripple tank keys.
            %   M = cycle sub-mode, Up/Down = grid level, Left/Right = omega.
            handled = true;
            switch key
                case "m"
                    modes = ["ripple", "raindrop", "interference"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                case {"uparrow", "downarrow"}
                    obj.changeGridLevel(key);
                case {"leftarrow", "rightarrow"}
                    stepVal = 0.1;
                    if key == "rightarrow"
                        obj.Omega = min(2.0, obj.Omega + stepVal);
                    else
                        obj.Omega = max(0.1, obj.Omega - stepVal);
                    end
                case "0"
                    % Reset simulation state
                    obj.resetGrid();
                otherwise
                    handled = false;
            end
            if handled
                obj.updateHud();
            end
        end

        function r = getResults(obj)
            %getResults  Return ripple tank results.
            r.Title = "RIPPLE TANK";
            r.Lines = {
                sprintf("Peak Amplitude: %.2f", obj.PeakAmp)
            };
        end

        function s = getHudText(~)
            %getHudText  HUD managed by ModeTextH; return empty for host.
            s = "";
        end
    end

    % =================================================================
    % PRIVATE HELPERS
    % =================================================================
    methods (Access = private)
        function s = buildHudString(obj)
            %buildHudString  Build HUD string with sub-mode, grid level, frequency.
            s = upper(obj.SubMode) + " [M]  |  Grid " + obj.GridLevel + ...
                "/10 [" + char(8593) + char(8595) + "]" + ...
                "  |  Freq " + sprintf("%.1f", obj.Omega) + ...
                " [" + char(8592) + char(8594) + "]";
        end

        function updateHud(obj)
            %updateHud  Refresh the bottom-left HUD text.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Adjust grid resolution and reinitialize.
            if key == "uparrow"
                obj.GridLevel = min(10, obj.GridLevel + 1);
            else
                obj.GridLevel = max(1, obj.GridLevel - 1);
            end
            savedMode = obj.SubMode;
            savedOmega = obj.Omega;
            savedAmp = obj.Amplitude;

            % Delete current image
            if ~isempty(obj.ImageH) && isvalid(obj.ImageH)
                delete(obj.ImageH);
            end
            obj.ImageH = [];

            % Reinitialize grid at new resolution
            obj.rebuildGrid();

            obj.SubMode = savedMode;
            obj.Omega = savedOmega;
            obj.Amplitude = savedAmp;
        end

        function resetGrid(obj)
            %resetGrid  Zero out the wave fields without changing resolution.
            Ny = obj.GridH;
            Nx = obj.GridW;
            obj.U = zeros(Ny, Nx);
            obj.UPrev = zeros(Ny, Nx);
            obj.Phase = 0;
            obj.PeakAmp = 0;
            obj.FrameCount = 0;
        end

        function rebuildGrid(obj)
            %rebuildGrid  Recreate grid arrays and image at current GridLevel.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;

            sizes = [30 40 50 60 70 80 100 120 140 160];
            level = max(1, min(10, obj.GridLevel));
            baseW = sizes(level);
            aspect = diff(dxRange) / diff(dyRange);
            obj.GridW = baseW;
            obj.GridH = max(20, round(baseW / aspect));
            Nx = obj.GridW;
            Ny = obj.GridH;

            obj.U = zeros(Ny, Nx);
            obj.UPrev = zeros(Ny, Nx);
            obj.Gx = repmat(1:Nx, Ny, 1);
            obj.Gy = repmat((1:Ny)', 1, Nx);
            obj.Phase = 0;
            obj.PeakAmp = 0;
            obj.FrameCount = 0;

            obj.FixedSrcX = round(Nx * 0.3);
            obj.FixedSrcY = round(Ny * 0.5);

            blackFrame = zeros(Ny, Nx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", blackFrame, "AlphaData", zeros(Ny, Nx), ...
                "AlphaDataMapping", "none", "Interpolation", "bilinear", ...
                "Tag", "GT_rippletank");
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");
        end
    end
end
