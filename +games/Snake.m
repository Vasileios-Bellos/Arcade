classdef Snake < GameBase
    %Snake  Finger-directed snake game with neon colormap gradient.
    %   The snake moves on a grid, directed by the finger position relative
    %   to the head. Eating food grows the body and increases speed. Self-
    %   collision ends the game. Wrap-around at screen edges.
    %
    %   Standalone: games.Snake().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

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
            % Live-update if snake is active
            if ~isempty(obj.ColormapRGB)
                obj.ColormapRGB = obj.buildColormap();
            end
        end
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        Body            (:,2) double                % [x, y] per segment, head = row 1
        Direction       (1,2) double = [1, 0]       % current movement direction
        Speed           (1,1) double = 1.5
        BaseSpeed       (1,1) double = 1.5
        CellSize        (1,1) double = 4
        FoodPos         (1,2) double = [NaN, NaN]
        MoveAccum       (1,1) double = 0            % sub-cell movement accumulator
        ColormapRGB     (:,3) double                % 256-row neon colormap for body gradient
        KeyboardMode    (1,1) logical = false     % true while arrow keys drive direction
        PrevPos         (1,2) double = [NaN, NaN]  % previous mouse position (for keyboard→mouse handoff)
        GameOver        (1,1) logical = false
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        FoodPatchH                      % scatter — food core
        FoodGlowH                       % scatter — food glow
        BodyPatchH      = {}            % cell array of line handles for body segments
        BodyPoolSize    (1,1) double = 60  % pre-allocated body segment pool
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

            obj.CellSize = max(6, round(min(areaW, areaH) * 0.06));
            obj.BaseSpeed = max(1.0, obj.CellSize * 0.35);
            obj.Speed = obj.BaseSpeed;
            obj.MoveAccum = 0;

            % Start with 5-segment snake at grid-aligned center
            cs = obj.CellSize;
            cx = dx(1) + round((mean(dx) - dx(1)) / cs) * cs;
            cy = dy(1) + round((mean(dy) - dy(1)) / cs) * cs;
            obj.Body = zeros(5, 2);
            for i = 1:5
                obj.Body(i, :) = [cx + (i - 1) * cs, cy];
            end
            obj.Direction = [-1, 0];  % moving left

            obj.ColormapRGB = obj.buildColormap();

            % Pre-allocate body segment pool (all hidden, activated as snake grows)
            nPool = obj.BodyPoolSize;
            nInit = size(obj.Body, 1);
            headSize = cs * 2.4;
            tailSize = cs * 0.9;
            obj.BodyPatchH = cell(1, nPool);
            for i = 1:nPool
                if i <= nInit
                    t = (i - 1) / max(1, nInit - 1);
                    mSize = headSize * (1 - t) + tailSize * t;
                    cmapIdx = max(1, round((1 - t) * (size(obj.ColormapRGB, 1) - 1)) + 1);
                    clr = obj.ColormapRGB(cmapIdx, :);
                    obj.BodyPatchH{i} = line(ax, obj.Body(i, 1), obj.Body(i, 2), ...
                        "Marker", "o", "MarkerSize", mSize, ...
                        "MarkerFaceColor", clr, "MarkerEdgeColor", clr * 0.7, ...
                        "LineStyle", "none", "Tag", "GT_snake");
                else
                    obj.BodyPatchH{i} = line(ax, NaN, NaN, ...
                        "Marker", "o", "MarkerSize", tailSize, ...
                        "MarkerFaceColor", [1 1 1], "MarkerEdgeColor", [0.7 0.7 0.7], ...
                        "LineStyle", "none", "Visible", "off", "Tag", "GT_snake");
                end
            end

            % Head marker (glow overlay)
            obj.HeadPatchH = scatter(ax, obj.Body(1, 1), obj.Body(1, 2), ...
                (cs * 2.4)^2, obj.ColormapRGB(end, :), "filled", ...
                "MarkerFaceAlpha", 0.8, "Tag", "GT_snake");

            % Pre-allocate food graphics (repositioned in spawnFood, never deleted)
            obj.FoodGlowH = scatter(ax, NaN, NaN, ...
                (cs * 6)^2, obj.ColorRed, "filled", "MarkerFaceAlpha", 0.2, ...
                "Tag", "GT_snake");
            obj.FoodPatchH = scatter(ax, NaN, NaN, ...
                (cs * 2.5)^2, obj.ColorRed, "filled", "Tag", "GT_snake");

            % Place first food
            obj.spawnFood();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame snake movement, collision, and rendering.
            if obj.GameOver; return; end
            if isempty(obj.Body); return; end

            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cs = obj.CellSize;
            headPos = obj.Body(1, :);

            % Determine direction from finger/mouse MOVEMENT direction.
            % In camera app, fingerPos - head works because finger is close.
            % With mouse, use movement direction (pos - prevPos) so the
            % snake turns based on which way you move, not where you are.
            % Skipped when arrow keys are active.
            if obj.KeyboardMode && ~any(isnan(pos)) && ~any(isnan(obj.PrevPos))
                if norm(pos - obj.PrevPos) > cs
                    obj.KeyboardMode = false;
                end
            end
            if ~obj.KeyboardMode && ~any(isnan(pos)) && ~any(isnan(obj.PrevPos))
                delta = pos - obj.PrevPos;
                if norm(delta) > cs * 0.3  % only respond to significant movement
                    if abs(delta(1)) > abs(delta(2))
                        newDir = [sign(delta(1)), 0];
                    else
                        newDir = [0, sign(delta(2))];
                    end
                    if ~isequal(newDir + obj.Direction, [0, 0]) && any(newDir ~= 0)
                        obj.Direction = newDir;
                    end
                end
            end
            obj.PrevPos = pos;

            ds = obj.DtScale;

            % Accumulate movement
            obj.MoveAccum = obj.MoveAccum + obj.Speed * ds;
            if obj.MoveAccum < cs
                obj.updateHitEffects();
                return;  % Not enough movement for a step
            end
            obj.MoveAccum = obj.MoveAccum - cs;

            % Move: new head position
            newHead = headPos + obj.Direction * cs;

            % Wall wrap-around
            if newHead(1) < dx(1); newHead(1) = dx(2); end
            if newHead(1) > dx(2); newHead(1) = dx(1); end
            if newHead(2) < dy(1); newHead(2) = dy(2); end
            if newHead(2) > dy(2); newHead(2) = dy(1); end

            % Self collision (skip 3 neck segments to prevent jitter deaths)
            for i = 4:size(obj.Body, 1)
                if norm(newHead - obj.Body(i, :)) < cs * 0.5
                    obj.GameOver = true;
                    obj.IsRunning = false;
                    obj.updateHitEffects();
                    return;
                end
            end

            % Check food collision
            ate = false;
            if ~any(isnan(obj.FoodPos)) && norm(newHead - obj.FoodPos) < cs * 0.5
                ate = true;
                obj.incrementCombo();
                totalPoints = round(100 * obj.comboMultiplier());
                obj.addScore(totalPoints);
                obj.spawnBounceEffect(obj.FoodPos, [0, -1], 0, 5);
                obj.spawnFood();
                % Speed up slightly
                obj.Speed = obj.BaseSpeed * (1 + 0.03 * size(obj.Body, 1));
            end

            % Move body
            if ate
                obj.Body = [newHead; obj.Body];
            else
                obj.Body = [newHead; obj.Body(1:end-1, :)];
            end

            % Update graphics — position-based taper, colormap stretched to length
            obj.updateBodyGraphics();

            obj.updateHitEffects();
        end

        function onCleanup(obj)
            %onCleanup  Delete all snake graphics.
            handles = {obj.HeadPatchH, obj.FoodPatchH, obj.FoodGlowH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.HeadPatchH = [];
            obj.FoodPatchH = [];
            obj.FoodGlowH = [];
            for k = 1:numel(obj.BodyPatchH)
                if ~isempty(obj.BodyPatchH{k}) && isvalid(obj.BodyPatchH{k})
                    delete(obj.BodyPatchH{k});
                end
            end
            obj.BodyPatchH = {};
            obj.Body = zeros(0, 2);

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_snake");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Arrow keys control snake direction.
            %   Once arrows are used, mouse direction is ignored until
            %   the mouse moves significantly (handled in onUpdate).
            handled = true;
            switch key
                case "uparrow"
                    if obj.Direction(2) ~= 1
                        obj.Direction = [0, -1];
                    end
                    obj.KeyboardMode = true;
                case "downarrow"
                    if obj.Direction(2) ~= -1
                        obj.Direction = [0, 1];
                    end
                    obj.KeyboardMode = true;
                case "leftarrow"
                    if obj.Direction(1) ~= 1
                        obj.Direction = [-1, 0];
                    end
                    obj.KeyboardMode = true;
                case "rightarrow"
                    if obj.Direction(1) ~= -1
                        obj.Direction = [1, 0];
                    end
                    obj.KeyboardMode = true;
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return snake-specific results.
            r.Title = "SNAKE";
            bodyLen = size(obj.Body, 1);
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            r.Lines = {
                sprintf("Length: %d  |  Score: %d  |  Time: %.0fs  |  Max Combo: %d", ...
                    bodyLen, obj.Score, elapsed, obj.MaxCombo)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function spawnFood(obj)
            %spawnFood  Place food at a random grid-aligned position.
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cs = obj.CellSize;
            margin = cs * 3;

            % Grid-aligned position, avoiding all snake segments
            foodXY = [NaN, NaN];
            for attempt = 1:100 %#ok<FXUP>
                rawX = dx(1) + margin + rand * (diff(dx) - 2 * margin);
                rawY = dy(1) + margin + rand * (diff(dy) - 2 * margin);
                candidate = [dx(1) + round((rawX - dx(1)) / cs) * cs, ...
                             dy(1) + round((rawY - dy(1)) / cs) * cs];
                if isempty(obj.Body) || all(vecnorm(obj.Body - candidate, 2, 2) >= cs * 0.5)
                    foodXY = candidate;
                    break;
                end
            end
            if any(isnan(foodXY))
                foodXY = [mean(dx), mean(dy)];
            end
            obj.FoodPos = foodXY;

            % Reposition pre-allocated food graphics (no delete/create)
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
            cs = obj.CellSize;
            pxScale = obj.FontScale;
            headSize = cs * (2.4 + 0.04 * max(0, nBody - 5)) * pxScale;
            tailSize = cs * 1.3 * pxScale;
            nPool = numel(obj.BodyPatchH);

            % Activate/update segments up to nBody, hide rest
            for i = 1:nPool
                if i > nPool; break; end
                h = obj.BodyPatchH{i};
                if isempty(h) || ~isvalid(h); continue; end
                if i <= nBody
                    h.XData = obj.Body(i, 1);
                    h.YData = obj.Body(i, 2);
                    t = (i - 1) / max(1, nBody - 1);
                    h.MarkerSize = headSize * (1 - t) + tailSize * t;
                    cmapIdx = max(1, round((1 - t) * (cmapSize - 1)) + 1);
                    clr = obj.ColormapRGB(cmapIdx, :);
                    h.MarkerFaceColor = clr;
                    h.MarkerEdgeColor = clr * 0.7;
                    h.Visible = "on";
                else
                    h.Visible = "off";
                end
            end

            % If snake exceeds pool (very long game), extend pool
            if nBody > nPool
                ax = obj.Ax;
                if ~isempty(ax) && isvalid(ax)
                    for i = (nPool + 1):nBody
                        obj.BodyPatchH{i} = line(ax, obj.Body(i, 1), obj.Body(i, 2), ...
                            "Marker", "o", "MarkerSize", tailSize, ...
                            "MarkerFaceColor", [1 1 1], "MarkerEdgeColor", [0.7 0.7 0.7], ...
                            "LineStyle", "none", "Tag", "GT_snake");
                    end
                end
            end

            if ~isempty(obj.HeadPatchH) && isvalid(obj.HeadPatchH)
                obj.HeadPatchH.XData = obj.Body(1, 1);
                obj.HeadPatchH.YData = obj.Body(1, 2);
                obj.HeadPatchH.CData = obj.ColormapRGB(end, :);
                obj.HeadPatchH.SizeData = headSize^2;
            end
        end

        function cmap = buildColormap(obj)
            %buildColormap  Generate 256-row colormap from Colormap property.
            nRows = 256;
            val = obj.Colormap;
            if isnumeric(val) && size(val, 2) == 3
                nIn = size(val, 1);
                if nIn == 1
                    % Single RGB — constant color for all segments
                    cmap = repmat(val, nRows, 1);
                elseif nIn == nRows
                    cmap = val;
                else
                    % Nx3 matrix — resample to 256 rows
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
