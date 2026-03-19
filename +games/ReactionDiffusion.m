classdef ReactionDiffusion < GameBase
    %ReactionDiffusion  Gray-Scott reaction-diffusion Turing pattern simulator.
    %   Simulates the Gray-Scott model with 5 F/k parameter presets
    %   (spots, stripes, coral, spirals, mitosis) and 5 color schemes
    %   (neon, heatmap, ocean, organic, monochrome). Finger injects catalyst.
    %
    %   Controls:
    %       M       — cycle F/k preset (spots/stripes/coral/spirals/mitosis)
    %       N       — cycle color scheme (neon/heatmap/ocean/organic/monochrome)
    %       Up/Down — change grid resolution (10 levels)
    %       0       — reset simulation
    %
    %   Standalone: games.ReactionDiffusion().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Reaction-Diffusion"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Concentration fields
        U               (:,:) double          % substrate concentration
        V               (:,:) double          % catalyst concentration

        % Gray-Scott parameters
        DiffusionU      (1,1) double = 0.16   % substrate diffusion rate
        DiffusionV      (1,1) double = 0.08   % catalyst diffusion rate
        FeedRate        (1,1) double = 0.035   % feed rate
        KillRate        (1,1) double = 0.065   % kill rate

        % Grid dimensions
        GridW           (1,1) double = 80      % visible grid width
        GridH           (1,1) double = 60      % visible grid height
        GridLevel       (1,1) double = 5       % 1-10

        % Sub-mode / color scheme
        SubMode         (1,1) string = "spots"
        ColorScheme     (1,1) string = "neon"

        % Stats
        FrameCount      (1,1) double = 0
        PeakV           (1,1) double = 0       % peak catalyst concentration
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ImageH                                 % image object
        ModeTextH                              % text label
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create reaction-diffusion grid and image overlay.
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

            obj.SubMode = "spots";
            obj.ColorScheme = "neon";
            obj.FrameCount = 0;
            obj.PeakV = 0;

            obj.initGrid();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame Gray-Scott simulation + neon rendering.
            if isempty(obj.U); return; end

            Ny = obj.GridH;
            Nx = obj.GridW;
            dxR = obj.DisplayRange.X;
            dyR = obj.DisplayRange.Y;
            uField = obj.U;
            vField = obj.V;
            Du = obj.DiffusionU;
            Dv = obj.DiffusionV;
            feedF = obj.FeedRate;
            killK = obj.KillRate;
            dt = 1.0;

            % Inject catalyst at finger position
            if ~any(isnan(pos))
                fx = (pos(1) - dxR(1)) / diff(dxR) * Nx;
                fy = (pos(2) - dyR(1)) / diff(dyR) * Ny;
                fx = max(2, min(Nx - 1, fx));
                fy = max(2, min(Ny - 1, fy));
                [gx, gy] = meshgrid(1:Nx, 1:Ny);
                splat = exp(-((gx - fx).^2 + (gy - fy).^2) / (2 * 2.0^2));
                vField = min(1, vField + splat * 0.15);
            end

            % Sub-steps per frame for stability (frame-rate scaled)
            baseNSub = 2;
            ds = obj.DtScale;
            nSubScaled = max(1, round(baseNSub * ds));
            nSubScaled = min(nSubScaled, baseNSub * 4);  % safety cap
            for substep = 1:nSubScaled
                % Laplacian via circshift (periodic boundaries)
                lapU = uField([2:end 1], :) + uField([end 1:end-1], :) + ...
                       uField(:, [2:end 1]) + uField(:, [end 1:end-1]) - 4 * uField;
                lapV = vField([2:end 1], :) + vField([end 1:end-1], :) + ...
                       vField(:, [2:end 1]) + vField(:, [end 1:end-1]) - 4 * vField;

                % Gray-Scott reaction
                uvv = uField .* vField .* vField;
                uField = uField + (Du * lapU - uvv + feedF * (1 - uField)) * dt;
                vField = vField + (Dv * lapV + uvv - (feedF + killK) * vField) * dt;

                % Clamp
                uField = max(0, min(1, uField));
                vField = max(0, min(1, vField));
            end

            obj.U = uField;
            obj.V = vField;
            obj.PeakV = max(obj.PeakV, max(vField(:)));
            obj.FrameCount = obj.FrameCount + 1;

            % --- Color scheme rendering ---
            normV = min(1, vField * 4);
            edgeV = normV .* (1 - normV) * 4;  % transition zone

            switch obj.ColorScheme
                case "neon"
                    % Magenta core, cyan-green edge glow, deep blue void
                    dispR = normV.^0.5 * 0.85;
                    dispG = edgeV * 0.8;
                    dispB = normV.^0.3 * 1.0;
                case "heatmap"
                    % Black -> red -> yellow -> white (thermal)
                    dispR = min(1, normV * 3);
                    dispG = min(1, max(0, normV * 3 - 1));
                    dispB = min(1, max(0, normV * 3 - 2));
                case "ocean"
                    % Deep blue void -> turquoise transition -> warm coral
                    dispR = normV.^1.5 * 0.9 + edgeV * 0.1;
                    dispG = normV * 0.3 + edgeV * 0.6;
                    dispB = 0.15 + (1 - normV) * 0.3 + edgeV * 0.4;
                case "organic"
                    % Cream background, brown/tan spots (animal print)
                    dispR = 0.85 - normV * 0.65;
                    dispG = 0.80 - normV * 0.60;
                    dispB = 0.65 - normV * 0.55;
                case "monochrome"
                    % Single blue hue, luminance variation
                    lum = normV.^0.7;
                    dispR = lum * 0.15;
                    dispG = lum * 0.4;
                    dispB = lum * 0.95;
            end

            % Bloom
            if Nx >= 30
                bloomR = imgaussfilt(dispR, 2.0);
                bloomG = imgaussfilt(dispG, 2.0);
                bloomB = imgaussfilt(dispB, 2.0);
                dispR = dispR + bloomR * 0.3;
                dispG = dispG + bloomG * 0.4;
                dispB = dispB + bloomB * 0.3;
            end

            dispR = min(1, dispR);
            dispG = min(1, dispG);
            dispB = min(1, dispB);

            % Alpha from pattern intensity
            alphaMap = min(0.9, max(dispR, max(dispG, dispB)));

            frameImg = uint8(cat(3, dispR, dispG, dispB) * 255);
            if ~isempty(obj.ImageH) && isvalid(obj.ImageH)
                obj.ImageH.CData = frameImg;
                obj.ImageH.AlphaData = alphaMap;
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all graphics and release fields.
            handles = {obj.ImageH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.ImageH = [];
            obj.ModeTextH = [];
            obj.U = [];
            obj.V = [];
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_reactiondiffusion");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["spots", "stripes", "coral", "spirals", "mitosis"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.applyParams();
            obj.updateModeLabel();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle reaction-diffusion mode keys.
            handled = true;
            if key == "m"
                % Cycle F/k preset
                modes = ["spots", "stripes", "coral", "spirals", "mitosis"];
                idx = find(modes == obj.SubMode, 1);
                obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                obj.applyParams();
                obj.updateModeLabel();
            elseif key == "n"
                % Cycle color scheme
                schemes = ["neon", "heatmap", "ocean", "organic", "monochrome"];
                idx = find(schemes == obj.ColorScheme, 1);
                obj.ColorScheme = schemes(mod(idx, numel(schemes)) + 1);
                obj.updateModeLabel();
            elseif key == "uparrow"
                obj.changeGridLevel("uparrow");
            elseif key == "downarrow"
                obj.changeGridLevel("downarrow");
            elseif key == "0"
                % Reset simulation, preserve sub-mode and color scheme
                savedMode = obj.SubMode;
                savedScheme = obj.ColorScheme;
                obj.onCleanup();
                obj.SubMode = savedMode;
                obj.ColorScheme = savedScheme;
                obj.PeakV = 0;
                obj.FrameCount = 0;
                obj.initGrid();
            else
                handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return reaction-diffusion results.
            r.Title = "REACTION-DIFFUSION";
            r.Lines = {
                sprintf("Peak Catalyst: %.2f", obj.PeakV)
            };
        end

        function s = getHudText(~)
            %getHudText  Return mode-specific HUD text.
            s = "";
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function s = buildHudString(obj)
            %buildHudString  Return mode-specific HUD text.
            s = upper(obj.SubMode) + " [M]  |  " + ...
                upper(obj.ColorScheme) + " [N]  |  Grid " + ...
                obj.GridLevel + "/10 [" + char(8593) + char(8595) + "]";
        end

        function initGrid(obj)
            %initGrid  Initialize concentration fields, image, and label.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dxR = obj.DisplayRange.X;
            dyR = obj.DisplayRange.Y;

            % Grid size from level
            sizes = [30 40 50 60 70 80 100 120 140 160];
            level = max(1, min(10, obj.GridLevel));
            baseW = sizes(level);
            aspect = diff(dxR) / diff(dyR);
            obj.GridW = baseW;
            obj.GridH = max(20, round(baseW / aspect));
            Nx = obj.GridW;
            Ny = obj.GridH;

            % Initialize: u = 1 everywhere, v = 0 (no catalyst)
            obj.U = ones(Ny, Nx);
            obj.V = zeros(Ny, Nx);

            % Seed a small patch of catalyst at center to bootstrap
            cy = round(Ny / 2);
            cx = round(Nx / 2);
            seedR = max(2, round(min(Nx, Ny) * 0.06));
            for i = max(1, cy - seedR):min(Ny, cy + seedR)
                for j = max(1, cx - seedR):min(Nx, cx + seedR)
                    if (i - cy)^2 + (j - cx)^2 <= seedR^2
                        obj.U(i, j) = 0.5 + rand * 0.1;
                        obj.V(i, j) = 0.25 + rand * 0.1;
                    end
                end
            end

            obj.FrameCount = 0;
            obj.PeakV = 0;
            obj.applyParams();

            % Create image overlay
            blackFrame = zeros(Ny, Nx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dxR, "YData", dyR, ...
                "CData", blackFrame, "AlphaData", zeros(Ny, Nx), ...
                "AlphaDataMapping", "none", "Interpolation", "bilinear", ...
                "Tag", "GT_reactiondiffusion");
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");

            % Mode text label
            obj.ModeTextH = text(ax, dxR(1) + 5, dyR(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", ...
                "Tag", "GT_reactiondiffusion");
        end

        function applyParams(obj)
            %applyParams  Set F, k parameters based on current sub-mode.
            switch obj.SubMode
                case "spots"
                    obj.FeedRate = 0.035; obj.KillRate = 0.065;
                case "stripes"
                    obj.FeedRate = 0.04;  obj.KillRate = 0.06;
                case "coral"
                    obj.FeedRate = 0.02;  obj.KillRate = 0.055;
                case "spirals"
                    obj.FeedRate = 0.014; obj.KillRate = 0.045;
                case "mitosis"
                    obj.FeedRate = 0.028; obj.KillRate = 0.062;
            end
        end

        function updateModeLabel(obj)
            %updateModeLabel  Refresh the on-screen HUD label.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Change grid resolution, reinitialize fields.
            if key == "uparrow"
                obj.GridLevel = min(10, obj.GridLevel + 1);
            else
                obj.GridLevel = max(1, obj.GridLevel - 1);
            end
            savedMode = obj.SubMode;
            savedScheme = obj.ColorScheme;
            obj.onCleanup();
            obj.SubMode = savedMode;
            obj.ColorScheme = savedScheme;
            obj.initGrid();
        end
    end
end
