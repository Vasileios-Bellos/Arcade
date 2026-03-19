classdef Lissajous < GameBase
    %Lissajous  N x N parametric Lissajous table with per-cell rainbow trails.
    %   Each cell (i,j) traces sin(j*t) vs cos(i*t). Header markers orbit
    %   reference circles. Sub-modes: table, single, morph, spiral.
    %
    %   Standalone: games.Lissajous().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Lissajous"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        T               (1,1) double = 0
        N               (1,1) double = 5
        TrailX          double = []
        TrailY          double = []
        TrailIdx        (1,1) double = 0
        TrailLen        (1,1) double = 200
        PhaseX          (1,1) double = 0
        PhaseY          (1,1) double = 0
        SubMode         (1,1) string = "table"
        Hues            double = []
        FrameCount      (1,1) double = 0
        MorphA          (1,1) double = 1
        MorphB          (1,1) double = 1
        MorphRate       (1,1) double = 0.003
        SpiralC         (1,1) double = 3
        SpiralRot       (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        TrailH
        DotH
        GlowH
        GridH
        HeaderH
        MarkerTopH
        MarkerLeftH
        ModeTextH
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create NxN Lissajous table visualization.
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
            nGrid = obj.N;

            % Reset state
            obj.T = 0;
            obj.FrameCount = 0;
            obj.TrailIdx = 0;
            obj.SubMode = "table";
            obj.MorphA = 1;
            obj.MorphB = 1;
            obj.SpiralRot = 0;
            obj.PhaseX = 0;
            obj.PhaseY = 0;

            % Pre-allocate trail buffers: trailLen x (N*N)
            nCells = nGrid * nGrid;
            obj.TrailX = NaN(obj.TrailLen, nCells);
            obj.TrailY = NaN(obj.TrailLen, nCells);

            % Assign rainbow hues to each cell
            obj.Hues = linspace(0, 1 - 1 / nCells, nCells)';

            % Dark background image — covers camera feed
            bgH = image(ax, "XData", dx, "YData", dy, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_lissajous");
            uistack(bgH, "bottom");
            uistack(bgH, "up");

            % Grid dimensions: (N+1) columns and (N+1) rows
            % Row 0 / Col 0 = headers; rows/cols 1-N = cells
            cellW = areaW / (nGrid + 1);
            cellH = areaH / (nGrid + 1);

            % Grid lines — subtle neon grid
            gridXData = [];
            gridYData = [];
            for k = 0:nGrid+1
                xLine = dx(1) + k * cellW;
                gridXData = [gridXData, xLine, xLine, NaN]; %#ok<AGROW>
                gridYData = [gridYData, dy(1), dy(2), NaN]; %#ok<AGROW>
            end
            for k = 0:nGrid+1
                yLine = dy(1) + k * cellH;
                gridXData = [gridXData, dx(1), dx(2), NaN]; %#ok<AGROW>
                gridYData = [gridYData, yLine, yLine, NaN]; %#ok<AGROW>
            end
            obj.GridH = line(ax, gridXData, gridYData, ...
                "Color", [0.15, 0.25, 0.4, 0.35], "LineWidth", 0.5, "Tag", "GT_lissajous");

            % Header circles — reference orbits in header row (top) and column (left)
            headerHandles = gobjects(1, 2 * nGrid);
            for k = 1:nGrid
                % Top header circle at column k
                cx = dx(1) + (k + 0.5) * cellW;
                cy = dy(1) + 0.5 * cellH;
                radius = min(cellW, cellH) * 0.35;
                theta = linspace(0, 2 * pi, 60);
                headerHandles(k) = line(ax, cx + radius * cos(theta), cy + radius * sin(theta), ...
                    "Color", [0.2, 0.4, 0.6, 0.45], "LineWidth", 0.8, "Tag", "GT_lissajous");
                % Left header circle at row k
                cx2 = dx(1) + 0.5 * cellW;
                cy2 = dy(1) + (k + 0.5) * cellH;
                headerHandles(nGrid + k) = line(ax, cx2 + radius * cos(theta), cy2 + radius * sin(theta), ...
                    "Color", [0.2, 0.4, 0.6, 0.45], "LineWidth", 0.8, "Tag", "GT_lissajous");
            end
            obj.HeaderH = headerHandles;

            % Header marker dots: bright core markers
            topMarkerX = NaN(1, nGrid);
            topMarkerY = NaN(1, nGrid);
            leftMarkerX = NaN(1, nGrid);
            leftMarkerY = NaN(1, nGrid);
            obj.MarkerTopH = scatter(ax, topMarkerX, topMarkerY, 60, ...
                obj.ColorCyan, "filled", "MarkerFaceAlpha", 1.0, "Tag", "GT_lissajous");
            obj.MarkerLeftH = scatter(ax, leftMarkerX, leftMarkerY, 60, ...
                obj.ColorCyan, "filled", "MarkerFaceAlpha", 1.0, "Tag", "GT_lissajous");

            % Trail lines — one per cell for RGBA color support, wider for neon glow
            trailHandles = gobjects(1, nCells);
            for k = 1:nCells
                [rr, gg, bb] = GameBase.hsvToRgb(obj.Hues(k));
                trailHandles(k) = line(ax, NaN, NaN, ...
                    "Color", [rr, gg, bb, 0.55], "LineWidth", 1.8, "Tag", "GT_lissajous");
            end
            obj.TrailH = trailHandles;

            % Current dots: glow aura layer (behind) + opaque core layer
            dotX = NaN(1, nCells);
            dotY = NaN(1, nCells);
            dotColors = zeros(nCells, 3);
            for k = 1:nCells
                [rr, gg, bb] = GameBase.hsvToRgb(obj.Hues(k));
                dotColors(k, :) = [rr, gg, bb];
            end
            obj.GlowH = scatter(ax, dotX, dotY, 100, dotColors, "filled", ...
                "MarkerFaceAlpha", 0.18, "Tag", "GT_lissajous");
            obj.DotH = scatter(ax, dotX, dotY, 30, dotColors, "filled", ...
                "MarkerFaceAlpha", 1.0, "Tag", "GT_lissajous");

            % Sub-mode text (bottom-left)
            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, ...
                "TABLE [M]", ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_lissajous");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame Lissajous table animation.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);
            nGrid = obj.N;
            nCells = nGrid * nGrid;

            obj.FrameCount = obj.FrameCount + 1;

            % Increment time parameter (frame-rate scaled)
            obj.T = obj.T + 0.02 * obj.DtScale;
            tNow = obj.T;

            % Finger interaction: X/Y position control phase offsets
            if ~any(isnan(pos))
                relX = (pos(1) - dx(1)) / areaW;  % 0..1
                relY = (pos(2) - dy(1)) / areaH;  % 0..1
                % Phase drift proportional to finger offset from center
                dsL = obj.DtScale;
                obj.PhaseX = obj.PhaseX + (relX - 0.5) * 0.02 * dsL;
                obj.PhaseY = obj.PhaseY + (relY - 0.5) * 0.02 * dsL;
                % In morph/spiral, finger also controls morph/rotation speed
                if obj.SubMode == "morph"
                    obj.MorphRate = 0.002 + relX * 0.008;
                elseif obj.SubMode == "spiral"
                    obj.SpiralC = 0.5 + relY * 2.0;
                end
            end

            % Grid geometry
            cellW = areaW / (nGrid + 1);
            cellH = areaH / (nGrid + 1);
            halfCellW = cellW * 0.4;
            halfCellH = cellH * 0.4;

            % Compute positions for all cells and header markers
            dotX = zeros(1, nCells);
            dotY = zeros(1, nCells);

            % Sub-mode specific frequency computation (frame-rate scaled)
            dsL2 = obj.DtScale;
            switch obj.SubMode
                case "morph"
                    % Smoothly interpolate frequency ratios
                    obj.MorphA = obj.MorphA + obj.MorphRate * dsL2;
                    obj.MorphB = obj.MorphB + obj.MorphRate * 0.7 * dsL2;
                    if obj.MorphA > 8; obj.MorphA = 1; end
                    if obj.MorphB > 8; obj.MorphB = 1; end
                case "spiral"
                    obj.SpiralRot = obj.SpiralRot + 0.01 * dsL2;
            end

            topMX = zeros(1, nGrid);
            topMY = zeros(1, nGrid);
            leftMX = zeros(1, nGrid);
            leftMY = zeros(1, nGrid);

            for k = 1:nGrid
                % Top header marker: x = sin(k * t + phaseX)
                cx = dx(1) + (k + 0.5) * cellW;
                cy = dy(1) + 0.5 * cellH;
                radius = min(cellW, cellH) * 0.35;
                topMX(k) = cx + radius * sin(k * tNow + obj.PhaseX);
                topMY(k) = cy + radius * cos(k * tNow + obj.PhaseX);

                % Left header marker: y = cos(k * t + phaseY)
                cx2 = dx(1) + 0.5 * cellW;
                cy2 = dy(1) + (k + 0.5) * cellH;
                leftMX(k) = cx2 + radius * sin(k * tNow + obj.PhaseY);
                leftMY(k) = cy2 + radius * cos(k * tNow + obj.PhaseY);
            end

            % Update header marker scatter positions
            if ~isempty(obj.MarkerTopH) && isvalid(obj.MarkerTopH)
                obj.MarkerTopH.XData = topMX;
                obj.MarkerTopH.YData = topMY;
            end
            if ~isempty(obj.MarkerLeftH) && isvalid(obj.MarkerLeftH)
                obj.MarkerLeftH.XData = leftMX;
                obj.MarkerLeftH.YData = leftMY;
            end

            % Compute Lissajous positions per cell
            for i = 1:nGrid
                for j = 1:nGrid
                    cellIdx = (i - 1) * nGrid + j;
                    cellCx = dx(1) + (j + 0.5) * cellW;
                    cellCy = dy(1) + (i + 0.5) * cellH;

                    switch obj.SubMode
                        case "single"
                            % Single large Lissajous — finger controls freq
                            if ~any(isnan(pos))
                                freqX = round((pos(1) - dx(1)) / areaW * 7) + 1;
                                freqY = round((pos(2) - dy(1)) / areaH * 7) + 1;
                            else
                                freqX = 3; freqY = 2;
                            end
                            % All cells use same position, mapped to full display
                            lx = sin(freqX * tNow + obj.PhaseX);
                            ly = cos(freqY * tNow + obj.PhaseY);
                            dotX(cellIdx) = mean(dx) + lx * areaW * 0.42;
                            dotY(cellIdx) = mean(dy) + ly * areaH * 0.42;
                        case "morph"
                            % Smoothly morphing frequencies
                            fj = j + (obj.MorphA - floor(obj.MorphA)) * ...
                                 (mod(j, nGrid) + 1 - j);
                            fi = i + (obj.MorphB - floor(obj.MorphB)) * ...
                                 (mod(i, nGrid) + 1 - i);
                            lx = sin(fj * tNow + obj.PhaseX);
                            ly = cos(fi * tNow + obj.PhaseY);
                            dotX(cellIdx) = cellCx + lx * halfCellW;
                            dotY(cellIdx) = cellCy + ly * halfCellH;
                        case "spiral"
                            % Spirograph: rotating phase offset
                            phaseOff = obj.SpiralRot * obj.SpiralC;
                            lx = sin(j * tNow + obj.PhaseX + phaseOff * j);
                            ly = cos(i * tNow + obj.PhaseY + phaseOff * i);
                            dotX(cellIdx) = cellCx + lx * halfCellW;
                            dotY(cellIdx) = cellCy + ly * halfCellH;
                        otherwise  % "table"
                            lx = sin(j * tNow + obj.PhaseX);
                            ly = cos(i * tNow + obj.PhaseY);
                            dotX(cellIdx) = cellCx + lx * halfCellW;
                            dotY(cellIdx) = cellCy + ly * halfCellH;
                    end
                end
            end

            % Update circular trail buffer
            trailLen = obj.TrailLen;
            obj.TrailIdx = mod(obj.TrailIdx, trailLen) + 1;
            obj.TrailX(obj.TrailIdx, :) = dotX;
            obj.TrailY(obj.TrailIdx, :) = dotY;

            % Update trail line graphics (oldest -> newest extraction)
            trIdx = mod(obj.TrailIdx:obj.TrailIdx + trailLen - 1, trailLen) + 1;
            for k = 1:nCells
                if k <= numel(obj.TrailH) && isvalid(obj.TrailH(k))
                    tx = obj.TrailX(trIdx, k);
                    ty = obj.TrailY(trIdx, k);
                    validMask = ~isnan(tx);
                    if sum(validMask) > 1
                        obj.TrailH(k).XData = tx(validMask);
                        obj.TrailH(k).YData = ty(validMask);
                    end
                end
            end

            % Update glow aura + dot core scatter
            if ~isempty(obj.GlowH) && isvalid(obj.GlowH)
                obj.GlowH.XData = dotX;
                obj.GlowH.YData = dotY;
            end
            if ~isempty(obj.DotH) && isvalid(obj.DotH)
                obj.DotH.XData = dotX;
                obj.DotH.YData = dotY;
            end

            % Scoring: frame count + pattern complexity via phase diversity
            obj.addScore(1);
            if mod(obj.FrameCount, 60) == 0
                obj.incrementCombo();
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all Lissajous graphics and reset state.
            % Delete individual handles
            handles = {obj.DotH, obj.GlowH, obj.GridH, ...
                       obj.MarkerTopH, obj.MarkerLeftH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            % Delete trail line array
            if ~isempty(obj.TrailH)
                for k = 1:numel(obj.TrailH)
                    if isvalid(obj.TrailH(k)); delete(obj.TrailH(k)); end
                end
            end
            % Delete header circle array
            if ~isempty(obj.HeaderH)
                for k = 1:numel(obj.HeaderH)
                    if isvalid(obj.HeaderH(k)); delete(obj.HeaderH(k)); end
                end
            end
            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_lissajous");
            % Reset handles
            obj.TrailH = [];
            obj.HeaderH = [];
            obj.DotH = [];
            obj.GlowH = [];
            obj.GridH = [];
            obj.MarkerTopH = [];
            obj.MarkerLeftH = [];
            obj.ModeTextH = [];
            obj.TrailX = [];
            obj.TrailY = [];
            obj.TrailIdx = 0;
            obj.FrameCount = 0;
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["table", "single", "morph", "spiral"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.applySubMode();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle Lissajous keys.
            handled = true;
            switch key
                case "m"
                    modes = ["table", "single", "morph", "spiral"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();
                case "0"
                    % Reset: revert to table mode
                    obj.SubMode = "table";
                    obj.applySubMode();
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return Lissajous results.
            r.Title = "LISSAJOUS";
            r.Lines = {
                sprintf("Frames: %d", obj.FrameCount)
            };
        end

    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function applySubMode(obj)
            %applySubMode  Apply sub-mode settings and update label.
            switch obj.SubMode
                case "table"
                    obj.showTableElements();
                    obj.TrailX(:) = NaN;
                    obj.TrailY(:) = NaN;
                    obj.TrailIdx = 0;
                case "single"
                    obj.hideTableElements();
                    obj.TrailX(:) = NaN;
                    obj.TrailY(:) = NaN;
                    obj.TrailIdx = 0;
                case "morph"
                    obj.showTableElements();
                    obj.MorphA = 1;
                    obj.MorphB = 1;
                    obj.TrailX(:) = NaN;
                    obj.TrailY(:) = NaN;
                    obj.TrailIdx = 0;
                case "spiral"
                    obj.showTableElements();
                    obj.SpiralRot = 0;
                    obj.TrailX(:) = NaN;
                    obj.TrailY(:) = NaN;
                    obj.TrailIdx = 0;
            end
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = upper(obj.SubMode) + " [M]";
            end
        end

        function hideTableElements(obj)
            %hideTableElements  Hide grid, header circles, and header markers.
            if ~isempty(obj.GridH) && isvalid(obj.GridH)
                obj.GridH.Visible = "off";
            end
            if ~isempty(obj.HeaderH)
                for k = 1:numel(obj.HeaderH)
                    if isvalid(obj.HeaderH(k))
                        obj.HeaderH(k).Visible = "off";
                    end
                end
            end
            if ~isempty(obj.MarkerTopH) && isvalid(obj.MarkerTopH)
                obj.MarkerTopH.Visible = "off";
            end
            if ~isempty(obj.MarkerLeftH) && isvalid(obj.MarkerLeftH)
                obj.MarkerLeftH.Visible = "off";
            end
        end

        function showTableElements(obj)
            %showTableElements  Show grid, header circles, and header markers.
            if ~isempty(obj.GridH) && isvalid(obj.GridH)
                obj.GridH.Visible = "on";
            end
            if ~isempty(obj.HeaderH)
                for k = 1:numel(obj.HeaderH)
                    if isvalid(obj.HeaderH(k))
                        obj.HeaderH(k).Visible = "on";
                    end
                end
            end
            if ~isempty(obj.MarkerTopH) && isvalid(obj.MarkerTopH)
                obj.MarkerTopH.Visible = "on";
            end
            if ~isempty(obj.MarkerLeftH) && isvalid(obj.MarkerLeftH)
                obj.MarkerLeftH.Visible = "on";
            end
        end
    end
end
