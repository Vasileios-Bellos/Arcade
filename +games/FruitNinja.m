classdef FruitNinja < GameBase
    %FruitNinja  Slash fruits launched upward before they fall off screen.
    %   Fruits spawn from below with upward velocity and arc under gravity.
    %   Move finger through a fruit (entry then exit) to slice it. Closer
    %   cuts to center score higher. Dropped fruits reset combo.
    %
    %   Standalone: games.FruitNinja().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Fruit Ninja"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Fruit physics
        Fruits          struct = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                                        "radius", {}, "color", {}, "patchH", {}, "glowH", {}, ...
                                        "slashing", {}, "entryAngle", {})
        Halves          struct = struct("verts", {}, "color", {}, "patchH", {}, ...
                                        "vx", {}, "vy", {}, "spin", {}, "alpha", {}, "frames", {})
        Gravity         (1,1) double = 0.12
        SpawnTimer      (1,1) double = 0
        SlashThreshold  (1,1) double = 1.5

        % Slash effects — animated slash lines shown on fruit cut
        SlashEffects    struct = struct("coreH", {}, "glowH", {}, ...
                                        "frames", {}, "fadeFrames", {}, "idxStart", {}, "idxEnd", {})

        % Stats
        StartTicLocal   uint64
        FruitsSliced    (1,1) double = 0
        FruitsDropped   (1,1) double = 0
        SliceHistory    struct = struct("centrality", {}, "speed", {}, ...
                                        "angle", {}, "position", {}, "time", {})

        % Trace buffer (own or host-provided)
        GetSmoothedTrace    function_handle = function_handle.empty
        TraceBufferX    (1,:) double = []
        TraceBufferY    (1,:) double = []
        TraceBufferIdx  (1,1) double = 0
        TraceBufferLen  (1,1) double = 200
        PrevPos         (1,2) double = [NaN, NaN]
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, caps)
            %onInit  Create graphics and initialize state.
            arguments
                obj
                ax
                displayRange struct
                caps struct = struct()
            end
            obj.Ax = ax;
            obj.DisplayRange = displayRange;
            obj.Score = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;

            dx = displayRange.X;
            dy = displayRange.Y;
            areaH = dy(2) - dy(1);

            obj.Gravity = max(0.06, areaH * 0.001);
            obj.Fruits = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "radius", {}, "color", {}, "patchH", {}, "glowH", {}, ...
                "slashing", {}, "entryAngle", {});
            obj.Halves = struct("verts", {}, "color", {}, "patchH", {}, ...
                "vx", {}, "vy", {}, "spin", {}, "alpha", {}, "frames", {});
            obj.SlashEffects = struct("coreH", {}, "glowH", {}, ...
                "frames", {}, "fadeFrames", {}, "idxStart", {}, "idxEnd", {});
            obj.SpawnTimer = 0;
            obj.StartTicLocal = tic;
            obj.FruitsSliced = 0;
            obj.FruitsDropped = 0;
            obj.SliceHistory = struct("centrality", {}, "speed", {}, ...
                "angle", {}, "position", {}, "time", {});
            obj.PrevPos = [NaN, NaN];

            % Trace source: prefer host-provided smoothed trace
            if isfield(caps, "getSmoothedTrace")
                obj.GetSmoothedTrace = caps.getSmoothedTrace;
            else
                obj.GetSmoothedTrace = function_handle.empty;
            end

            % Own trace buffer (used when no host trace is available)
            obj.TraceBufferX = NaN(1, obj.TraceBufferLen);
            obj.TraceBufferY = NaN(1, obj.TraceBufferLen);
            obj.TraceBufferIdx = 0;
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame fruit ninja game logic.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);

            % --- Obtain smoothed trace ---
            [traceX, traceY] = obj.getTrace(pos);
            nTrace = numel(traceX);

            % Compute current finger speed (average over last 3 trace points)
            slashSpeed = 0;
            if nTrace >= 3
                speeds = sqrt(diff(traceX).^2 + diff(traceY).^2);
                slashSpeed = mean(speeds(max(1, end-2):end));
            end
            slashThresh = max(1.5, min(areaW, areaH) * 0.008);

            % --- Spawn fruits ---
            obj.SpawnTimer = obj.SpawnTimer + 1;
            spawnInterval = max(15, 45 - obj.FruitsSliced * 0.3);
            if obj.SpawnTimer >= spawnInterval
                obj.SpawnTimer = 0;
                obj.spawnFruit();
            end

            % --- Update fruits (gravity + movement) ---
            kk = 1;
            while kk <= numel(obj.Fruits)
                f = obj.Fruits(kk);
                f.x = f.x + f.vx;
                f.y = f.y + f.vy;
                f.vy = f.vy + obj.Gravity;

                % Wall collision -- bounce off top, left, right (not bottom)
                if f.x - f.radius < dx(1)
                    f.x = dx(1) + f.radius;
                    f.vx = abs(f.vx) * 0.8;
                elseif f.x + f.radius > dx(2)
                    f.x = dx(2) - f.radius;
                    f.vx = -abs(f.vx) * 0.8;
                end
                if f.y - f.radius < dy(1)
                    f.y = dy(1) + f.radius;
                    f.vy = abs(f.vy) * 0.8;
                end
                obj.Fruits(kk) = f;

                % Update graphics
                theta = linspace(0, 2*pi, 24);
                circX = f.x + f.radius * cos(theta);
                circY = f.y + f.radius * sin(theta);
                if ~isempty(f.patchH) && isvalid(f.patchH)
                    f.patchH.XData = circX;
                    f.patchH.YData = circY;
                end
                if ~isempty(f.glowH) && isvalid(f.glowH)
                    f.glowH.XData = circX;
                    f.glowH.YData = circY;
                end

                % Slash detection: enter/exit through fruit
                if ~any(isnan(pos))
                    distToFruit = norm(pos(:) - [f.x; f.y]);
                    if f.slashing
                        % Finger was inside -- check if it exited
                        if distToFruit > f.radius + 3
                            obj.sliceFruit(kk, pos, slashSpeed, traceX, traceY, nTrace);
                            continue;  % fruit removed, don't increment kk
                        end
                    else
                        % Check if finger entered fruit with some movement
                        if distToFruit < f.radius + 3 && slashSpeed > slashThresh
                            f.slashing = true;
                            f.entryAngle = atan2(pos(2) - f.y, pos(1) - f.x);
                            obj.Fruits(kk) = f;
                        end
                    end
                end

                % Check if fruit fell off screen
                if f.y > dy(2) + f.radius * 2
                    obj.FruitsDropped = obj.FruitsDropped + 1;
                    obj.resetCombo();
                    if ~isempty(f.patchH) && isvalid(f.patchH); delete(f.patchH); end
                    if ~isempty(f.glowH) && isvalid(f.glowH); delete(f.glowH); end
                    obj.Fruits(kk) = [];
                    continue;
                end
                kk = kk + 1;
            end

            % --- Update split halves animation ---
            kk = 1;
            while kk <= numel(obj.Halves)
                hf = obj.Halves(kk);
                hf.frames = hf.frames + 1;
                hf.vx = hf.vx * 0.97;
                hf.vy = hf.vy + obj.Gravity;
                hf.alpha = max(0, hf.alpha - 0.04);

                % Move vertices
                hf.verts(:,1) = hf.verts(:,1) + hf.vx;
                hf.verts(:,2) = hf.verts(:,2) + hf.vy;

                % Rotate
                centX = mean(hf.verts(:,1));
                centY = mean(hf.verts(:,2));
                ca = cos(hf.spin); sa = sin(hf.spin);
                relX = hf.verts(:,1) - centX;
                relY = hf.verts(:,2) - centY;
                hf.verts(:,1) = centX + relX * ca - relY * sa;
                hf.verts(:,2) = centY + relX * sa + relY * ca;

                if ~isempty(hf.patchH) && isvalid(hf.patchH)
                    hf.patchH.XData = hf.verts(:,1);
                    hf.patchH.YData = hf.verts(:,2);
                    hf.patchH.FaceAlpha = hf.alpha * 0.6;
                    hf.patchH.EdgeAlpha = hf.alpha;
                end
                obj.Halves(kk) = hf;

                if hf.alpha <= 0 || hf.frames > 30
                    if ~isempty(hf.patchH) && isvalid(hf.patchH); delete(hf.patchH); end
                    obj.Halves(kk) = [];
                    continue;
                end
                kk = kk + 1;
            end

            % --- Animate slash effects (capture -> fade) ---
            kk = 1;
            while kk <= numel(obj.SlashEffects)
                se = obj.SlashEffects(kk);
                se.frames = se.frames + 1;

                if se.frames > se.fadeFrames
                    if ~isempty(se.coreH) && isvalid(se.coreH); delete(se.coreH); end
                    if ~isempty(se.glowH) && isvalid(se.glowH); delete(se.glowH); end
                    obj.SlashEffects(kk) = [];
                    continue;
                else
                    % Update coordinates from current trace every frame.
                    % Buffer shifts by 1 each frame, so adjust indices to
                    % track the same physical points.
                    age = se.frames - 1;
                    trN = numel(traceX);
                    i1 = max(1, se.idxStart - age);
                    i2 = min(trN, se.idxEnd - age);
                    if i1 < i2
                        sx = traceX(i1:i2);
                        sy = traceY(i1:i2);
                    else
                        sx = NaN; sy = NaN;
                    end
                    fadeProgress = se.frames / se.fadeFrames;
                    alphaVal = 1 - fadeProgress^0.5;
                    if ~isempty(se.coreH) && isvalid(se.coreH)
                        se.coreH.XData = sx;
                        se.coreH.YData = sy;
                        se.coreH.Color(4) = alphaVal * 0.9;
                    end
                    if ~isempty(se.glowH) && isvalid(se.glowH)
                        se.glowH.XData = sx;
                        se.glowH.YData = sy;
                        se.glowH.Color(4) = alphaVal * 0.5;
                    end
                end
                obj.SlashEffects(kk) = se;
                kk = kk + 1;
            end

            obj.PrevPos = pos;
        end

        function onCleanup(obj)
            %onCleanup  Delete all fruit ninja graphics.
            for kk = 1:numel(obj.Fruits)
                if ~isempty(obj.Fruits(kk).patchH) && isvalid(obj.Fruits(kk).patchH)
                    delete(obj.Fruits(kk).patchH);
                end
                if ~isempty(obj.Fruits(kk).glowH) && isvalid(obj.Fruits(kk).glowH)
                    delete(obj.Fruits(kk).glowH);
                end
            end
            obj.Fruits = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "radius", {}, "color", {}, "patchH", {}, "glowH", {}, ...
                "slashing", {}, "entryAngle", {});

            for kk = 1:numel(obj.Halves)
                if ~isempty(obj.Halves(kk).patchH) && isvalid(obj.Halves(kk).patchH)
                    delete(obj.Halves(kk).patchH);
                end
            end
            obj.Halves = struct("verts", {}, "color", {}, "patchH", {}, ...
                "vx", {}, "vy", {}, "spin", {}, "alpha", {}, "frames", {});

            for kk = 1:numel(obj.SlashEffects)
                if ~isempty(obj.SlashEffects(kk).coreH) && isvalid(obj.SlashEffects(kk).coreH)
                    delete(obj.SlashEffects(kk).coreH);
                end
                if ~isempty(obj.SlashEffects(kk).glowH) && isvalid(obj.SlashEffects(kk).glowH)
                    delete(obj.SlashEffects(kk).glowH);
                end
            end
            obj.SlashEffects = struct("coreH", {}, "glowH", {}, ...
                "frames", {}, "fadeFrames", {}, "idxStart", {}, "idxEnd", {});

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_fruitninja");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for fruit ninja.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return fruit ninja results.
            r.Title = "FRUIT NINJA";
            elapsed = toc(obj.StartTicLocal);
            avgCent = 0;
            if ~isempty(obj.SliceHistory)
                avgCent = mean([obj.SliceHistory.centrality]);
            end
            r.Lines = {
                sprintf("Sliced: %d  |  Dropped: %d  |  Score: %d  |  Accuracy: %.0f%%  |  Time: %.0fs  |  Max Combo: %d", ...
                    obj.FruitsSliced, obj.FruitsDropped, obj.Score, avgCent * 100, elapsed, obj.MaxCombo)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function [tx, ty] = getTrace(obj, pos)
            %getTrace  Return smoothed trace coordinates.
            %   Uses host-provided trace if available, otherwise own buffer.
            if ~isempty(obj.GetSmoothedTrace)
                [tx, ty] = obj.GetSmoothedTrace();
            else
                % Update own trace buffer
                if ~any(isnan(pos))
                    idx = mod(obj.TraceBufferIdx, obj.TraceBufferLen) + 1;
                    obj.TraceBufferX(idx) = pos(1);
                    obj.TraceBufferY(idx) = pos(2);
                    obj.TraceBufferIdx = obj.TraceBufferIdx + 1;
                end
                % Extract valid (non-NaN) entries in order
                nFilled = min(obj.TraceBufferIdx, obj.TraceBufferLen);
                if nFilled == 0
                    tx = []; ty = [];
                    return;
                end
                if obj.TraceBufferIdx <= obj.TraceBufferLen
                    tx = obj.TraceBufferX(1:nFilled);
                    ty = obj.TraceBufferY(1:nFilled);
                else
                    startIdx = mod(obj.TraceBufferIdx, obj.TraceBufferLen) + 1;
                    order = [startIdx:obj.TraceBufferLen, 1:startIdx-1];
                    tx = obj.TraceBufferX(order);
                    ty = obj.TraceBufferY(order);
                end
                % Apply Gaussian smoothing for consistency with host trace
                if numel(tx) >= 5
                    tx = smoothdata(tx, "gaussian", 9);
                    ty = smoothdata(ty, "gaussian", 9);
                end
            end
        end

        function spawnFruit(obj)
            %spawnFruit  Launch a fruit upward from the bottom.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);

            fruitColors = {obj.ColorRed, obj.ColorGreen, obj.ColorGold, ...
                           obj.ColorMagenta, [1, 0.6, 0.15]};
            clr = fruitColors{randi(numel(fruitColors))};
            fruitRadius = max(5, round(min(areaW, areaH) * (0.03 + rand * 0.025)));

            % Launch from bottom with upward velocity
            xPos = dx(1) + areaW * (0.15 + rand * 0.7);
            yPos = dy(2) + fruitRadius;
            velX = (rand - 0.5) * areaW * 0.012;
            velY = -(areaH * (0.022 + rand * 0.025));

            theta = linspace(0, 2*pi, 24);
            circX = xPos + fruitRadius * cos(theta);
            circY = yPos + fruitRadius * sin(theta);

            glowH = patch(ax, "XData", circX, "YData", circY, ...
                "FaceColor", clr, "FaceAlpha", 0.15, ...
                "EdgeColor", "none", "Tag", "GT_fruitninja");
            patchH = patch(ax, "XData", circX, "YData", circY, ...
                "FaceColor", clr, "FaceAlpha", 0.5, ...
                "EdgeColor", clr, "LineWidth", 1.5, "Tag", "GT_fruitninja");

            obj.Fruits(end + 1) = struct("x", xPos, "y", yPos, ...
                "vx", velX, "vy", velY, ...
                "radius", fruitRadius, "color", clr, ...
                "patchH", patchH, "glowH", glowH, ...
                "slashing", false, "entryAngle", NaN);
        end

        function sliceFruit(obj, fruitIdx, exitPos, slashSpeed, traceX, traceY, nTrace)
            %sliceFruit  Slice fruit into two halves with slash animation.
            %   Uses entry/exit angles for accurate cut geometry.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            f = obj.Fruits(fruitIdx);
            obj.FruitsSliced = obj.FruitsSliced + 1;
            obj.incrementCombo();

            % Entry/exit angles relative to current fruit center
            a1 = f.entryAngle;
            a2 = atan2(exitPos(2) - f.y, exitPos(1) - f.x);

            % Centrality: how close the chord passes through center.
            % Smaller arc => chord further from center => lower centrality.
            smallerArc = min(mod(a2 - a1, 2*pi), mod(a1 - a2, 2*pi));
            centrality = 1 - cos(smallerArc / 2);

            % Scoring: base x centrality bonus x combo
            comboMult = obj.comboMultiplier();
            centralityBonus = 0.5 + centrality;  % 0.5 (edge) to 1.5 (center)
            points = round(100 * centralityBonus * comboMult);
            obj.addScore(points);

            % Store slice diagnostics
            slashAngle = atan2(sin(a2 - a1), cos(a2 - a1));
            obj.SliceHistory(end + 1) = struct("centrality", centrality, ...
                "speed", slashSpeed, "angle", rad2deg(slashAngle), ...
                "position", [f.x, f.y], "time", toc(obj.StartTicLocal));

            % Cut direction from entry to exit on circle boundary
            entryOnCircle = [f.x + f.radius * cos(a1), f.y + f.radius * sin(a1)];
            exitOnCircle  = [f.x + f.radius * cos(a2), f.y + f.radius * sin(a2)];
            slashDir = [exitOnCircle(1) - entryOnCircle(1); ...
                        exitOnCircle(2) - entryOnCircle(2)];
            if norm(slashDir) > 0
                slashDir = slashDir / norm(slashDir);
            else
                slashDir = [1; 0];
            end
            splitNorm = [-slashDir(2); slashDir(1)];

            % Build two pieces: arc from a1->a2 and arc from a2->a1+2pi
            for side = [1, -1]
                if side == 1
                    arcSpan = mod(a2 - a1, 2*pi);
                    arcTheta = linspace(a1, a1 + arcSpan, 20);
                else
                    arcSpan = mod(a1 - a2, 2*pi);
                    arcTheta = linspace(a2, a2 + arcSpan, 20);
                end
                hx = f.x + f.radius * cos(arcTheta);
                hy = f.y + f.radius * sin(arcTheta);

                halfPatch = patch(ax, "XData", hx, "YData", hy, ...
                    "FaceColor", f.color, "FaceAlpha", 0.5, ...
                    "EdgeColor", f.color, "LineWidth", 1.5, "Tag", "GT_fruitninja");

                splitVx = f.vx + splitNorm(1) * side * 1.5;
                splitVy = f.vy + splitNorm(2) * side * 1.5 - 0.5;

                obj.Halves(end + 1) = struct("verts", [hx(:), hy(:)], ...
                    "color", f.color, "patchH", halfPatch, ...
                    "vx", splitVx, "vy", splitVy, ...
                    "spin", side * 0.06, "alpha", 1.0, "frames", 0);
            end

            % Slash animation -- store trace INDEX range, update coordinates
            % from the live trace every frame so it stays superimposed.
            entryOnCircle = [f.x + f.radius * cos(a1), ...
                             f.y + f.radius * sin(a1)];
            entryDists = (traceX - entryOnCircle(1)).^2 + ...
                         (traceY - entryOnCircle(2)).^2;
            [~, entryIdx] = min(entryDists);
            exitDists = (traceX - exitPos(1)).^2 + ...
                        (traceY - exitPos(2)).^2;
            [~, exitIdx] = min(exitDists);
            padVal = 4;
            idxStart = max(1, min(entryIdx, exitIdx) - padVal);
            idxEnd = min(nTrace, max(entryIdx, exitIdx) + padVal);
            sx = traceX(idxStart:idxEnd);
            sy = traceY(idxStart:idxEnd);

            fadeFrames = 12;
            glowLine = line(ax, sx, sy, ...
                "Color", [obj.ColorCyan, 0.5], ...
                "LineWidth", 6, "Tag", "GT_fruitninja");
            coreLine = line(ax, sx, sy, ...
                "Color", [obj.ColorWhite, 0.9], ...
                "LineWidth", 2.5, "Tag", "GT_fruitninja");
            obj.SlashEffects(end + 1) = struct("coreH", coreLine, ...
                "glowH", glowLine, "frames", 0, "fadeFrames", fadeFrames, ...
                "idxStart", idxStart, "idxEnd", idxEnd);

            % Spawn burst effect at fruit center
            obj.spawnHitEffect([f.x, f.y], f.color, points, f.radius);

            % Delete original fruit
            if ~isempty(f.patchH) && isvalid(f.patchH); delete(f.patchH); end
            if ~isempty(f.glowH) && isvalid(f.glowH); delete(f.glowH); end
            obj.Fruits(fruitIdx) = [];
        end
    end
end
