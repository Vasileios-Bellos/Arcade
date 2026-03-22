classdef Snake < engine.GameBase
    %Snake  Classic snake game on a discrete integer grid with neon colormap.
    %   The snake moves one cell per step on a grid of integer [col, row]
    %   positions. Eating food grows the body and increases speed. Self-
    %   collision ends the game. Wrap-around at screen edges.
    %
    %   Standalone: games.Snake().play()
    %   Hosted:     Arcade hosts via init/onUpdate/onCleanup
    %
    %   See also engine.GameBase, Arcade

    properties (Constant)
        Name = "Snake"
    end

    % =================================================================
    % CONFIGURATION
    % =================================================================
    properties
        Colormap = "default"    % "default", colormap name ("hsv"), or Nx3 matrix
    end

    methods
        function set.Colormap(obj, val)
            if isstring(val) || ischar(val)
                obj.Colormap = string(val);
            elseif isnumeric(val) && size(val, 2) == 3
                obj.Colormap = val;
            else
                error("games:Snake:BadColormap", ...
                    "Colormap must be a colormap name or Nx3 matrix.");
            end
        end
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        Body            (:,2) double                % [col, row] integer indices, head = row 1
        Direction       (1,2) double = [1, 0]       % [dcol, drow] — one of [1,0],[-1,0],[0,1],[0,-1]
        QueuedDir       (1,2) double = [0, 0]       % buffered next direction (prevents missed turns)
        FoodPos         (1,2) double = [NaN, NaN]   % [col, row] integer position
        StepAccum       (1,1) double = 0            % DtScale accumulator for step timing
        StepInterval    (1,1) double = 4            % DtScale units between steps (decreases with length)
        ColormapRGB     (:,3) double                % 256-row neon colormap for body gradient
        KeyboardMode    (1,1) logical = false       % true while arrow keys drive direction
        PrevPos         (1,2) double = [NaN, NaN]   % previous mouse/finger position
        GameOver        (1,1) logical = false
        LastFoodTic                         % tic of last food eaten
        ComboTimeout    (1,1) double = 2.4  % seconds before combo resets (1.5x host fade)

        % Grid geometry
        GridCols        (1,1) double = 25
        GridRows        (1,1) double = 19
        CellW           (1,1) double = 1
        CellH           (1,1) double = 1

        % Grid lines handle
        GridLinesH      = []                        % line handle for grid overlay

        % Pre-computed marker sizes (data units, set once in onInit)
        HeadMarkerSz    (1,1) double = 1            % MarkerSize for head segment
        TailMarkerSz    (1,1) double = 0.5          % MarkerSize for tail segment
        FoodMarkerSz    (1,1) double = 1            % SizeData for food scatter
        FoodGlowSz      (1,1) double = 4            % SizeData for food glow scatter
        HeadGlowSz      (1,1) double = 2            % SizeData for head glow scatter
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        FoodPatchH                      % scatter — food core
        FoodGlowH                       % scatter — food glow
        BodyPatchH      = {}            % cell array of line handles for body segments
        BodyPoolSize    (1,1) double = 100  % pre-allocated body segment pool
        HeadPatchH                      % scatter — head glow overlay
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create snake game graphics and initialize state.
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
            obj.GameOver = false;

            dx = displayRange.X;
            dy = displayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);

            % Compute grid dimensions — target ~25 columns, aspect-aware
            obj.GridCols = max(10, round(25 * areaW / max(areaW, areaH)));
            obj.GridRows = max(8, round(25 * areaH / max(areaW, areaH)));
            obj.CellW = areaW / obj.GridCols;
            obj.CellH = areaH / obj.GridRows;

            % Step timing
            obj.StepAccum = 0;
            obj.StepInterval = 4;
            obj.QueuedDir = [0, 0];

            % Start with 5-segment snake at grid center, moving right
            cx = round(obj.GridCols / 2);
            cy = round(obj.GridRows / 2);
            obj.Body = zeros(5, 2);
            for i = 1:5
                obj.Body(i, :) = [cx - (i - 1), cy];   % head at cx, tail extends left
            end
            obj.Direction = [1, 0];
            obj.PrevPos = [NaN, NaN];
            obj.KeyboardMode = false;

            obj.ColormapRGB = obj.buildColormap();

            % Draw subtle grid lines
            obj.drawGridLines(ax, dx, dy);

            % Marker sizes stored as fractions of cell (converted to points each step)
            cellData = min(obj.CellW, obj.CellH);
            obj.HeadMarkerSz = 0.92;   % fraction of cell
            obj.TailMarkerSz = 0.50;

            % Scatter SizeData is in points^2. Convert data-unit radius to
            % points using axes pixel extent and DPI. We compute the
            % conversion factor once and store the final SizeData values.
            pixPos = getpixelposition(ax);
            axPxW = pixPos(3);
            pxPerDataX = axPxW / areaW;
            dpiVal = get(0, "ScreenPixelsPerInch");
            ptPerPx = 72 / dpiVal;

            foodRadiusPts = (cellData * 0.45) * pxPerDataX * ptPerPx;
            obj.FoodMarkerSz = foodRadiusPts^2 * pi;
            obj.FoodGlowSz = (foodRadiusPts * 2.2)^2 * pi;

            headRadiusPts = (cellData * 0.55) * pxPerDataX * ptPerPx;
            obj.HeadGlowSz = headRadiusPts^2 * pi;

            % Convert cell fractions to initial point sizes
            initCellPts = cellData * pxPerDataX * ptPerPx;
            initHeadPts = initCellPts * obj.HeadMarkerSz;
            initTailPts = initCellPts * obj.TailMarkerSz;
            initFoodPts = initCellPts * 0.45;

            % Pre-allocate body segment pool
            nPool = obj.BodyPoolSize;
            nInit = size(obj.Body, 1);
            obj.BodyPatchH = cell(1, nPool);
            for i = 1:nPool
                if i <= nInit
                    t = (i - 1) / max(1, nInit - 1);
                    mSize = initHeadPts * (1 - t) + initTailPts * t;
                    cmapIdx = max(1, round((1 - t) * (size(obj.ColormapRGB, 1) - 1)) + 1);
                    clr = obj.ColormapRGB(cmapIdx, :);
                    xy = obj.gridToData(obj.Body(i, :));
                    obj.BodyPatchH{i} = line(ax, xy(1), xy(2), ...
                        "Marker", "o", "MarkerSize", mSize, ...
                        "MarkerFaceColor", clr, "MarkerEdgeColor", clr * 0.5, ...
                        "LineStyle", "none", "Tag", "GT_snake");
                else
                    obj.BodyPatchH{i} = line(ax, NaN, NaN, ...
                        "Marker", "o", "MarkerSize", initTailPts, ...
                        "MarkerFaceColor", [1 1 1], "MarkerEdgeColor", [0.7 0.7 0.7], ...
                        "LineStyle", "none", "Visible", "off", "Tag", "GT_snake");
                end
            end

            % Head marker (bright glow overlay on top of body)
            headXY = obj.gridToData(obj.Body(1, :));
            obj.HeadPatchH = scatter(ax, headXY(1), headXY(2), ...
                (initCellPts * 0.55)^2 * pi, obj.ColormapRGB(end, :), "filled", ...
                "MarkerFaceAlpha", 0.55, "Tag", "GT_snake");

            % Pre-allocate food graphics (red core + glow)
            obj.FoodGlowH = scatter(ax, NaN, NaN, ...
                (initFoodPts * 2.2)^2 * pi, obj.ColorRed, "filled", "MarkerFaceAlpha", 0.18, ...
                "Tag", "GT_snake");
            obj.FoodPatchH = scatter(ax, NaN, NaN, ...
                initFoodPts^2 * pi, obj.ColorRed, "filled", "Tag", "GT_snake");

            % Place first food
            obj.spawnFood();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame snake movement, collision, and rendering.
            if obj.GameOver; return; end
            if isempty(obj.Body); return; end

            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            cellData = min(obj.CellW, obj.CellH);

            % ----------------------------------------------------------
            % Direction from finger/mouse MOVEMENT (delta-based)
            % ----------------------------------------------------------
            if obj.KeyboardMode && ~any(isnan(pos)) && ~any(isnan(obj.PrevPos))
                % Exit keyboard mode if mouse moves more than one cell
                if norm(pos - obj.PrevPos) > cellData
                    obj.KeyboardMode = false;
                end
            end

            if ~obj.KeyboardMode && ~any(isnan(pos)) && ~any(isnan(obj.PrevPos))
                delta = pos - obj.PrevPos;
                if norm(delta) > cellData * 0.25
                    if abs(delta(1)) > abs(delta(2))
                        newDir = [sign(delta(1)), 0];
                    else
                        newDir = [0, sign(delta(2))];
                    end
                    % Buffer the direction — applied at next step
                    if any(newDir ~= 0)
                        obj.QueuedDir = newDir;
                    end
                end
            end
            obj.PrevPos = pos;

            % ----------------------------------------------------------
            % Step timing — accumulate DtScale, step when threshold met
            % ----------------------------------------------------------
            ds = obj.DtScale;
            obj.StepAccum = obj.StepAccum + ds;
            if obj.StepAccum < obj.StepInterval
                return;
            end
            obj.StepAccum = obj.StepAccum - obj.StepInterval;

            % Apply queued direction (prevents 180-degree reversal)
            if any(obj.QueuedDir ~= 0)
                if ~isequal(obj.QueuedDir + obj.Direction, [0, 0])
                    obj.Direction = obj.QueuedDir;
                end
                obj.QueuedDir = [0, 0];
            end

            % Move: new head = current head + direction (integer step)
            headCell = obj.Body(1, :);
            newHead = headCell + obj.Direction;

            % Wrap-around on grid edges
            newHead(1) = mod(newHead(1) - 1, obj.GridCols) + 1;
            newHead(2) = mod(newHead(2) - 1, obj.GridRows) + 1;

            % Self collision — integer comparison (skip first 3 neck segments)
            nBody = size(obj.Body, 1);
            if nBody > 3
                bodyCheck = obj.Body(4:end, :);
                if any(bodyCheck(:,1) == newHead(1) & bodyCheck(:,2) == newHead(2))
                    obj.GameOver = true;
                    obj.IsRunning = false;
                    return;
                end
            end

            % Check food collision (exact integer match)
            ate = false;
            if ~any(isnan(obj.FoodPos)) && isequal(newHead, obj.FoodPos)
                ate = true;
                obj.incrementCombo();
                obj.LastFoodTic = tic;
                totalPoints = round(100 * obj.comboMultiplier());
                obj.addScore(totalPoints);
                foodXY = obj.gridToData(obj.FoodPos);
                obj.spawnBounceEffect(foodXY, [0, -1], totalPoints, 5);
                obj.spawnFood();
                % Speed up: reduce step interval as snake grows
                bodyLen = nBody + 1;
                obj.StepInterval = max(1.5, 4 - (bodyLen - 5) * 0.05);
            end

            % Advance body
            if ate
                obj.Body = [newHead; obj.Body];
            else
                obj.Body = [newHead; obj.Body(1:end-1, :)];
            end

            % Update graphics
            obj.updateBodyGraphics();
        end

        function onCleanup(obj)
            %onCleanup  Delete all snake graphics.
            handles = {obj.HeadPatchH, obj.FoodPatchH, obj.FoodGlowH, obj.GridLinesH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.HeadPatchH = [];
            obj.FoodPatchH = [];
            obj.FoodGlowH = [];
            obj.GridLinesH = [];
            for k = 1:numel(obj.BodyPatchH)
                if ~isempty(obj.BodyPatchH{k}) && isvalid(obj.BodyPatchH{k})
                    delete(obj.BodyPatchH{k});
                end
            end
            obj.BodyPatchH = {};
            obj.Body = zeros(0, 2);

            % Orphan guard
            engine.GameBase.deleteTaggedGraphics(obj.Ax, "^GT_snake");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Arrow keys control snake direction.
            %   Direction is buffered and applied at the next step to avoid
            %   skipping frames or reversing into yourself.
            handled = true;
            switch key
                case "uparrow"
                    obj.QueuedDir = [0, -1];
                    obj.KeyboardMode = true;
                case "downarrow"
                    obj.QueuedDir = [0, 1];
                    obj.KeyboardMode = true;
                case "leftarrow"
                    obj.QueuedDir = [-1, 0];
                    obj.KeyboardMode = true;
                case "rightarrow"
                    obj.QueuedDir = [1, 0];
                    obj.KeyboardMode = true;
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return snake-specific results.
            r.Title = "SNAKE";
            bodyLen = size(obj.Body, 1);
            r.Lines = {
                sprintf("Length: %d", bodyLen)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function xy = gridToData(obj, gridPos)
            %gridToData  Convert [col, row] integer grid position to data coordinates.
            %   Returns [x, y] at the center of the grid cell.
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            xy = [dx(1) + (gridPos(1) - 0.5) * obj.CellW, ...
                  dy(1) + (gridPos(2) - 0.5) * obj.CellH];
        end

        function drawGridLines(obj, ax, dx, dy)
            %drawGridLines  Draw subtle grid overlay.
            nC = obj.GridCols;
            nR = obj.GridRows;
            cw = obj.CellW;
            ch = obj.CellH;

            % Build NaN-separated line arrays for all grid lines in one handle
            nLines = (nC + 1) + (nR + 1);
            xAll = NaN(3 * nLines, 1);
            yAll = NaN(3 * nLines, 1);
            idx = 1;

            % Vertical lines
            for c = 0:nC
                xVal = dx(1) + c * cw;
                xAll(idx)   = xVal; yAll(idx)   = dy(1);
                xAll(idx+1) = xVal; yAll(idx+1) = dy(2);
                idx = idx + 3;
            end

            % Horizontal lines
            for r = 0:nR
                yVal = dy(1) + r * ch;
                xAll(idx)   = dx(1); yAll(idx)   = yVal;
                xAll(idx+1) = dx(2); yAll(idx+1) = yVal;
                idx = idx + 3;
            end

            obj.GridLinesH = line(ax, xAll, yAll, ...
                "Color", [0.15 0.15 0.15], "LineWidth", 0.5, ...
                "Tag", "GT_snake");
            uistack(obj.GridLinesH, "bottom");
        end

        function spawnFood(obj)
            %spawnFood  Place food at a random empty grid cell.
            nC = obj.GridCols;
            nR = obj.GridRows;

            % Try random positions up to 200 times
            foodCell = [NaN, NaN];
            for attempt = 1:200
                candidate = [randi(nC), randi(nR)];
                if isempty(obj.Body) || ~any(obj.Body(:,1) == candidate(1) & obj.Body(:,2) == candidate(2))
                    foodCell = candidate;
                    break;
                end
            end

            % Fallback: scan for first empty cell if grid is nearly full
            if any(isnan(foodCell))
                for c = 1:nC
                    for r = 1:nR
                        if ~any(obj.Body(:,1) == c & obj.Body(:,2) == r)
                            foodCell = [c, r];
                            break;
                        end
                    end
                    if ~any(isnan(foodCell)); break; end
                end
            end

            obj.FoodPos = foodCell;

            % Reposition pre-allocated food graphics
            foodXY = obj.gridToData(foodCell);
            if ~isempty(obj.FoodGlowH) && isvalid(obj.FoodGlowH)
                obj.FoodGlowH.XData = foodXY(1);
                obj.FoodGlowH.YData = foodXY(2);
            end
            if ~isempty(obj.FoodPatchH) && isvalid(obj.FoodPatchH)
                obj.FoodPatchH.XData = foodXY(1);
                obj.FoodPatchH.YData = foodXY(2);
            end
        end

        function updateBodyGraphics(obj)
            %updateBodyGraphics  Update body segment positions, sizes, and colors.
            nBody = size(obj.Body, 1);
            cmapSize = size(obj.ColormapRGB, 1);
            nPool = numel(obj.BodyPatchH);

            % Convert cell-fraction sizes to points using current axes pixel extent
            ax = obj.Ax;
            cellData = min(obj.CellW, obj.CellH);
            pixPos = getpixelposition(ax);
            areaW = diff(obj.DisplayRange.X);
            pxPerData = pixPos(3) / areaW;
            dpiVal = get(0, "ScreenPixelsPerInch");
            ptPerPx = 72 / dpiVal;
            cellPts = cellData * pxPerData * ptPerPx;
            headSz = cellPts * obj.HeadMarkerSz;
            tailSz = cellPts * obj.TailMarkerSz;

            % Activate/update segments up to nBody, hide the rest
            for i = 1:nPool
                h = obj.BodyPatchH{i};
                if isempty(h) || ~isvalid(h); continue; end
                if i <= nBody
                    xy = obj.gridToData(obj.Body(i, :));
                    h.XData = xy(1);
                    h.YData = xy(2);
                    t = (i - 1) / max(1, nBody - 1);
                    h.MarkerSize = headSz * (1 - t) + tailSz * t;
                    cmapIdx = max(1, round((1 - t) * (cmapSize - 1)) + 1);
                    clr = obj.ColormapRGB(cmapIdx, :);
                    h.MarkerFaceColor = clr;
                    h.MarkerEdgeColor = clr * 0.5;
                    h.Visible = "on";
                else
                    h.Visible = "off";
                end
            end

            % Extend pool if snake exceeds pre-allocated capacity
            if nBody > nPool
                ax = obj.Ax;
                if ~isempty(ax) && isvalid(ax)
                    for i = (nPool + 1):nBody
                        xy = obj.gridToData(obj.Body(i, :));
                        obj.BodyPatchH{i} = line(ax, xy(1), xy(2), ...
                            "Marker", "o", "MarkerSize", tailSz, ...
                            "MarkerFaceColor", [1 1 1], "MarkerEdgeColor", [0.7 0.7 0.7], ...
                            "LineStyle", "none", "Tag", "GT_snake");
                    end
                end
            end

            % Update head glow position and color
            if ~isempty(obj.HeadPatchH) && isvalid(obj.HeadPatchH)
                headXY = obj.gridToData(obj.Body(1, :));
                obj.HeadPatchH.XData = headXY(1);
                obj.HeadPatchH.YData = headXY(2);
                obj.HeadPatchH.CData = obj.ColormapRGB(end, :);
                headGlowPts = cellPts * 0.55;
                obj.HeadPatchH.SizeData = headGlowPts^2 * pi;
            end

            % Update food scatter sizes to match current pixel scale
            foodPts = cellPts * 0.45;
            if ~isempty(obj.FoodPatchH) && isvalid(obj.FoodPatchH)
                obj.FoodPatchH.SizeData = foodPts^2 * pi;
            end
            if ~isempty(obj.FoodGlowH) && isvalid(obj.FoodGlowH)
                obj.FoodGlowH.SizeData = (foodPts * 2.2)^2 * pi;
            end
        end

        function cmap = buildColormap(obj)
            %buildColormap  Generate 256-row colormap from Colormap property.
            nRows = 256;
            val = obj.Colormap;
            if isnumeric(val) && size(val, 2) == 3
                nIn = size(val, 1);
                if nIn == 1
                    cmap = repmat(val, nRows, 1);
                elseif nIn == nRows
                    cmap = val;
                else
                    idx = linspace(1, nIn, nRows)';
                    cmap = interp1(1:nIn, val, idx);
                end
            elseif val == "default" || val == "custom"
                tt = linspace(0, 1, nRows)';
                cmap = obj.ColorCyan .* (1 - tt * 0.6) + obj.ColorGreen .* (tt * 0.6);
            else
                try
                    cmap = feval(val, nRows);
                catch
                    warning("games:Snake:BadColormap", ...
                        "Colormap '%s' not found, using default.", val);
                    tt = linspace(0, 1, nRows)';
                    cmap = obj.ColorCyan .* (1 - tt * 0.6) + obj.ColorGreen .* (tt * 0.6);
                end
            end
        end
    end
end
