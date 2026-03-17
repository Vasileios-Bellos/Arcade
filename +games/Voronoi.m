classdef Voronoi < GameBase
    %Voronoi  Voronoi tessellation with animated seeds and Lloyd relaxation.
    %   40 seeds move with finger repel/attract interaction. Nearest-neighbor
    %   cell coloring, Delaunay triangulation overlay, Lloyd relaxation mode.
    %
    %   Standalone: games.Voronoi().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Voronoi"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        SeedX           (:,1) double
        SeedY           (:,1) double
        VelX            (:,1) double
        VelY            (:,1) double
        SeedCount       (1,1) double = 40
        SeedColors      (:,3) double
        SubMode         (1,1) string = "voronoi"
        ImgW            (1,1) double = 120
        ImgH            (1,1) double = 90
        FrameCount      (1,1) double = 0
        Damping         (1,1) double = 0.995
        SpeedCap        (1,1) double = 3.0
        RepelRadius     (1,1) double = 80
        LloydAlpha      (1,1) double = 0.08
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ImageH
        EdgeH
        EdgeGlowH
        DelH
        SeedH
        SeedGlowH
        ModeTextH
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create Voronoi tessellation visualization.
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
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);
            nSeeds = obj.SeedCount;

            % Reset state
            obj.FrameCount = 0;
            obj.SubMode = "voronoi";

            % Place seeds randomly in display area
            obj.SeedX = dx(1) + rand(nSeeds, 1) * areaW;
            obj.SeedY = dy(1) + rand(nSeeds, 1) * areaH;

            % Random initial velocities (small)
            obj.VelX = (rand(nSeeds, 1) - 0.5) * 1.0;
            obj.VelY = (rand(nSeeds, 1) - 0.5) * 1.0;

            % Assign rainbow hues
            hues = linspace(0, 1 - 1 / nSeeds, nSeeds)';
            obj.SeedColors = zeros(nSeeds, 3);
            for k = 1:nSeeds
                [rr, gg, bb] = GameBase.hsvToRgb(hues(k));
                obj.SeedColors(k, :) = [rr, gg, bb];
            end

            % Dark background image — covers camera feed
            bgImg = image(ax, "XData", dx, "YData", dy, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_voronoi");
            uistack(bgImg, "bottom");
            uistack(bgImg, "up");

            % Cell coloring image overlay (nearest-neighbor, semi-transparent)
            imgW = obj.ImgW;
            imgH = obj.ImgH;
            blackFrame = zeros(imgH, imgW, 3, "uint8");
            obj.ImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", blackFrame, "AlphaData", ones(imgH, imgW) * 0.55, ...
                "AlphaDataMapping", "none", "Interpolation", "bilinear", ...
                "Tag", "GT_voronoi");

            % Voronoi edge glow (wider, behind) + core edge (brighter, thinner)
            obj.EdgeGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.2], "LineWidth", 3.0, "Tag", "GT_voronoi");
            obj.EdgeH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.8], "LineWidth", 1.2, "Tag", "GT_voronoi");

            % Delaunay edge line (starts invisible)
            obj.DelH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorGold, 0.5], "LineWidth", 0.8, ...
                "Visible", "off", "Tag", "GT_voronoi");

            % Seed scatter: large glow aura + core dot (neon style)
            obj.SeedGlowH = scatter(ax, obj.SeedX, obj.SeedY, 200, ...
                obj.SeedColors, "filled", "MarkerFaceAlpha", 0.15, "Tag", "GT_voronoi");
            obj.SeedH = scatter(ax, obj.SeedX, obj.SeedY, 35, ...
                obj.SeedColors, "filled", "MarkerFaceAlpha", 1.0, "Tag", "GT_voronoi");

            % Sub-mode text (bottom-left)
            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, ...
                "VORONOI [M]", ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_voronoi");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame Voronoi tessellation update.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);
            nSeeds = obj.SeedCount;

            obj.FrameCount = obj.FrameCount + 1;

            sx = obj.SeedX;
            sy = obj.SeedY;
            vx = obj.VelX;
            vy = obj.VelY;

            % --- Finger interaction: repel close, attract at medium range ---
            if ~any(isnan(pos))
                ddx = sx - pos(1);
                ddy = sy - pos(2);
                dist = sqrt(ddx.^2 + ddy.^2);
                safeDist = max(dist, 1);
                repelR = obj.RepelRadius;
                attractR = repelR * 3;
                % Repulsion (close range)
                inRepel = dist < repelR & dist > 0;
                if any(inRepel)
                    strength = 3.0 * (1 - dist(inRepel) / repelR).^2;
                    vx(inRepel) = vx(inRepel) + strength .* ddx(inRepel) ./ safeDist(inRepel);
                    vy(inRepel) = vy(inRepel) + strength .* ddy(inRepel) ./ safeDist(inRepel);
                end
                % Attraction (medium range — creates orbit/gather effect)
                inAttract = dist >= repelR & dist < attractR & dist > 0;
                if any(inAttract)
                    pullStr = 0.8 * (1 - dist(inAttract) / attractR);
                    vx(inAttract) = vx(inAttract) - pullStr .* ddx(inAttract) ./ safeDist(inAttract);
                    vy(inAttract) = vy(inAttract) - pullStr .* ddy(inAttract) ./ safeDist(inAttract);
                end
            end

            % --- Lloyd relaxation in "lloyd" mode ---
            if obj.SubMode == "lloyd"
                try
                    DT = delaunayTriangulation(sx, sy);
                    [V, R] = voronoiDiagram(DT);
                    for k = 1:nSeeds
                        region = R{k};
                        if any(region == 1); continue; end  % unbounded region
                        verts = V(region, :);
                        if any(isinf(verts(:))); continue; end
                        % Area centroid via shoelace formula
                        vx2 = verts(:, 1); vy2 = verts(:, 2);
                        vx2n = circshift(vx2, -1); vy2n = circshift(vy2, -1);
                        crossProd = vx2 .* vy2n - vx2n .* vy2;
                        A6 = 3 * sum(crossProd);
                        if abs(A6) < 1e-12
                            centX = mean(vx2); centY = mean(vy2);
                        else
                            centX = sum((vx2 + vx2n) .* crossProd) / A6;
                            centY = sum((vy2 + vy2n) .* crossProd) / A6;
                        end
                        vx(k) = vx(k) + obj.LloydAlpha * (centX - sx(k));
                        vy(k) = vy(k) + obj.LloydAlpha * (centY - sy(k));
                    end
                catch
                    % Degenerate triangulation — skip Lloyd this frame
                end
            end

            % --- Move seeds: integrate velocity, apply damping ---
            vx = vx * obj.Damping;
            vy = vy * obj.Damping;

            % Speed cap
            spd = sqrt(vx.^2 + vy.^2);
            tooFast = spd > obj.SpeedCap;
            if any(tooFast)
                scaleFactor = obj.SpeedCap ./ spd(tooFast);
                vx(tooFast) = vx(tooFast) .* scaleFactor;
                vy(tooFast) = vy(tooFast) .* scaleFactor;
            end

            sx = sx + vx;
            sy = sy + vy;

            % Wrap around edges
            sx = dx(1) + mod(sx - dx(1), areaW);
            sy = dy(1) + mod(sy - dy(1), areaH);

            obj.SeedX = sx;
            obj.SeedY = sy;
            obj.VelX = vx;
            obj.VelY = vy;

            % --- Compute nearest-neighbor cell coloring (vectorized) ---
            imgW = obj.ImgW;
            imgH = obj.ImgH;

            % Pixel grid coordinates
            px = linspace(dx(1), dx(2), imgW);  % 1 x imgW
            py = linspace(dy(1), dy(2), imgH);  % 1 x imgH

            % Build distance matrix: for each pixel (r,c), find nearest seed
            pxGrid = repmat(px, imgH, 1);       % imgH x imgW
            pyGrid = repmat(py', 1, imgW);       % imgH x imgW
            pxFlat = pxGrid(:);                   % (imgH*imgW) x 1
            pyFlat = pyGrid(:);                   % (imgH*imgW) x 1

            % Distance squared: (imgH*imgW) x nSeeds
            dSq = (pxFlat - sx').^2 + (pyFlat - sy').^2;

            % Argmin along seed dimension
            [~, nearest] = min(dSq, [], 2);       % (imgH*imgW) x 1

            % Assign colors
            cellColors = obj.SeedColors(nearest, :);  % (imgH*imgW) x 3
            rgbImg = reshape(cellColors, [imgH, imgW, 3]);

            % Neon boost: brighten and add slight bloom
            rgbImg = min(1, rgbImg * 1.3);

            % Update image CData
            if ~isempty(obj.ImageH) && isvalid(obj.ImageH)
                obj.ImageH.CData = uint8(rgbImg * 255);
                % Adjust cell transparency per sub-mode
                if obj.SubMode == "delaunay"
                    obj.ImageH.AlphaData = ones(imgH, imgW) * 0.2;
                else
                    obj.ImageH.AlphaData = ones(imgH, imgW) * 0.55;
                end
            end

            % --- Compute Delaunay + Voronoi edges ---
            try
                DT = delaunayTriangulation(sx, sy);

                % Voronoi edges
                if obj.SubMode ~= "delaunay"
                    [V, R] = voronoiDiagram(DT);
                    edgeX = [];
                    edgeY = [];
                    for k = 1:nSeeds
                        region = R{k};
                        if any(region == 1); continue; end
                        verts = V(region, :);
                        if any(isinf(verts(:))); continue; end
                        % Close the polygon
                        verts = [verts; verts(1, :)]; %#ok<AGROW>
                        edgeX = [edgeX, verts(:, 1)', NaN]; %#ok<AGROW>
                        edgeY = [edgeY, verts(:, 2)', NaN]; %#ok<AGROW>
                    end
                    if ~isempty(obj.EdgeGlowH) && isvalid(obj.EdgeGlowH)
                        obj.EdgeGlowH.XData = edgeX;
                        obj.EdgeGlowH.YData = edgeY;
                        obj.EdgeGlowH.Visible = "on";
                    end
                    if ~isempty(obj.EdgeH) && isvalid(obj.EdgeH)
                        obj.EdgeH.XData = edgeX;
                        obj.EdgeH.YData = edgeY;
                        obj.EdgeH.Visible = "on";
                    end
                else
                    if ~isempty(obj.EdgeGlowH) && isvalid(obj.EdgeGlowH)
                        obj.EdgeGlowH.Visible = "off";
                    end
                    if ~isempty(obj.EdgeH) && isvalid(obj.EdgeH)
                        obj.EdgeH.Visible = "off";
                    end
                end

                % Delaunay edges (only in delaunay/dual modes)
                if obj.SubMode == "delaunay" || obj.SubMode == "dual"
                    edgeList = DT.edges;
                    delX = NaN(1, size(edgeList, 1) * 3);
                    delY = NaN(1, size(edgeList, 1) * 3);
                    delX(1:3:end) = sx(edgeList(:, 1));
                    delX(2:3:end) = sx(edgeList(:, 2));
                    delY(1:3:end) = sy(edgeList(:, 1));
                    delY(2:3:end) = sy(edgeList(:, 2));
                    if ~isempty(obj.DelH) && isvalid(obj.DelH)
                        obj.DelH.XData = delX;
                        obj.DelH.YData = delY;
                        obj.DelH.Visible = "on";
                    end
                else
                    if ~isempty(obj.DelH) && isvalid(obj.DelH)
                        obj.DelH.Visible = "off";
                    end
                end
            catch
                % Degenerate triangulation — skip edge rendering this frame
            end

            % --- Update seed scatter positions ---
            if ~isempty(obj.SeedH) && isvalid(obj.SeedH)
                obj.SeedH.XData = sx;
                obj.SeedH.YData = sy;
            end
            if ~isempty(obj.SeedGlowH) && isvalid(obj.SeedGlowH)
                obj.SeedGlowH.XData = sx;
                obj.SeedGlowH.YData = sy;
            end

            % --- Scoring: reward seed spread uniformity ---
            obj.addScore(1);
            if mod(obj.FrameCount, 60) == 0
                obj.incrementCombo();
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all Voronoi graphics and reset state.
            handles = {obj.ImageH, obj.EdgeH, obj.EdgeGlowH, ...
                       obj.DelH, obj.SeedH, obj.SeedGlowH, ...
                       obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_voronoi");
            obj.ImageH = [];
            obj.EdgeH = [];
            obj.EdgeGlowH = [];
            obj.DelH = [];
            obj.SeedH = [];
            obj.SeedGlowH = [];
            obj.ModeTextH = [];
            obj.SeedX = [];
            obj.SeedY = [];
            obj.VelX = [];
            obj.VelY = [];
            obj.SeedColors = [];
            obj.FrameCount = 0;
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle Voronoi keys.
            handled = true;
            switch key
                case "m"
                    modes = ["voronoi", "delaunay", "dual", "lloyd"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();
                case "0"
                    % Reset seeds
                    dx = obj.DisplayRange.X;
                    dy = obj.DisplayRange.Y;
                    areaW = dx(2) - dx(1);
                    areaH = dy(2) - dy(1);
                    nSeeds = obj.SeedCount;
                    obj.SeedX = dx(1) + rand(nSeeds, 1) * areaW;
                    obj.SeedY = dy(1) + rand(nSeeds, 1) * areaH;
                    obj.VelX = (rand(nSeeds, 1) - 0.5) * 1.0;
                    obj.VelY = (rand(nSeeds, 1) - 0.5) * 1.0;
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return Voronoi results.
            r.Title = "VORONOI";
            elapsed = 0;
            if ~isempty(obj.StartTic); elapsed = toc(obj.StartTic); end
            r.Lines = {
                sprintf("Seeds: %d  |  Mode: %s  |  Time: %.0fs", ...
                    obj.SeedCount, obj.SubMode, elapsed)
            };
        end

        function s = getHudText(obj)
            %getHudText  Return HUD string.
            s = upper(obj.SubMode) + " [M]";
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function applySubMode(obj)
            %applySubMode  Apply Voronoi sub-mode settings and update label.
            switch obj.SubMode
                case "voronoi"
                    if ~isempty(obj.EdgeGlowH) && isvalid(obj.EdgeGlowH)
                        obj.EdgeGlowH.Visible = "on";
                        obj.EdgeGlowH.Color = [obj.ColorCyan, 0.2];
                    end
                    if ~isempty(obj.EdgeH) && isvalid(obj.EdgeH)
                        obj.EdgeH.Visible = "on";
                        obj.EdgeH.Color = [obj.ColorCyan, 0.8];
                    end
                    if ~isempty(obj.DelH) && isvalid(obj.DelH)
                        obj.DelH.Visible = "off";
                    end
                case "delaunay"
                    if ~isempty(obj.EdgeGlowH) && isvalid(obj.EdgeGlowH)
                        obj.EdgeGlowH.Visible = "off";
                    end
                    if ~isempty(obj.EdgeH) && isvalid(obj.EdgeH)
                        obj.EdgeH.Visible = "off";
                    end
                    if ~isempty(obj.DelH) && isvalid(obj.DelH)
                        obj.DelH.Visible = "on";
                        obj.DelH.Color = [obj.ColorGold, 0.6];
                    end
                case "dual"
                    if ~isempty(obj.EdgeGlowH) && isvalid(obj.EdgeGlowH)
                        obj.EdgeGlowH.Visible = "on";
                        obj.EdgeGlowH.Color = [obj.ColorCyan, 0.15];
                    end
                    if ~isempty(obj.EdgeH) && isvalid(obj.EdgeH)
                        obj.EdgeH.Visible = "on";
                        obj.EdgeH.Color = [obj.ColorCyan, 0.5];
                    end
                    if ~isempty(obj.DelH) && isvalid(obj.DelH)
                        obj.DelH.Visible = "on";
                        obj.DelH.Color = [obj.ColorGold, 0.5];
                    end
                case "lloyd"
                    if ~isempty(obj.EdgeGlowH) && isvalid(obj.EdgeGlowH)
                        obj.EdgeGlowH.Visible = "on";
                        obj.EdgeGlowH.Color = [obj.ColorGreen, 0.15];
                    end
                    if ~isempty(obj.EdgeH) && isvalid(obj.EdgeH)
                        obj.EdgeH.Visible = "on";
                        obj.EdgeH.Color = [obj.ColorGreen, 0.7];
                    end
                    if ~isempty(obj.DelH) && isvalid(obj.DelH)
                        obj.DelH.Visible = "off";
                    end
            end
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = upper(obj.SubMode) + " [M]";
            end
        end
    end
end
