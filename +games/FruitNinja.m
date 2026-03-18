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
    % PRE-COMPUTED CONSTANTS
    % =================================================================
    properties (Access = private)
        ThetaCircle24   (1,24) double       % linspace(0, 2*pi, 24), computed once
    end

    % =================================================================
    % FRUIT POOL (8 slots)
    % =================================================================
    properties (Access = private)
        FruitPoolPatch  cell                % {1x8} patch handles (body)
        FruitPoolGlow   cell                % {1x8} patch handles (glow)
        FruitX          (1,8) double = NaN  % x position per slot
        FruitY          (1,8) double = NaN  % y position per slot
        FruitVx         (1,8) double = 0    % x velocity per slot
        FruitVy         (1,8) double = 0    % y velocity per slot
        FruitRadius     (1,8) double = 0    % radius per slot
        FruitColor      cell                % {1x8} [r,g,b] per slot
        FruitSlashing   (1,8) logical = false  % finger inside?
        FruitEntryAngle (1,8) double = NaN  % entry angle per slot
        FruitActive     (1,8) logical = false  % is slot in use?
    end

    % =================================================================
    % HALF POOL (16 slots — 2 per fruit max)
    % =================================================================
    properties (Access = private)
        HalfPoolPatch   cell                % {1x16} patch handles
        HalfVerts       cell                % {1x16} Nx2 vertex arrays
        HalfVx          (1,16) double = 0
        HalfVy          (1,16) double = 0
        HalfSpin        (1,16) double = 0
        HalfAlpha       (1,16) double = 0
        HalfFrames      (1,16) double = 0
        HalfColor       cell                % {1x16} [r,g,b]
        HalfActive      (1,16) logical = false
    end

    % =================================================================
    % SLASH EFFECT POOL (6 slots)
    % =================================================================
    properties (Access = private)
        SlashPoolCore   cell                % {1x6} line handles (core)
        SlashPoolGlow   cell                % {1x6} line handles (glow)
        SlashFrames     (1,6) double = 0
        SlashFadeFrames (1,6) double = 0
        SlashIdxStart   (1,6) double = 0
        SlashIdxEnd     (1,6) double = 0
        SlashActive     (1,6) logical = false
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        Gravity         (1,1) double = 0.12
        SpawnTimer      (1,1) double = 0
        SlashThreshold  (1,1) double = 1.5

        % Stats
        StartTicLocal   uint64
        FruitsSliced    (1,1) double = 0
        FruitsDropped   (1,1) double = 0
        SliceHistory    struct = struct("centrality", {}, "speed", {}, ...
                                        "angle", {}, "position", {}, "time", {})

        % Display scale factor (1.0 at ~180px reference)
        Sc              (1,1) double = 1

        % Trace buffer (own shifting buffer or host-provided)
        GetSmoothedTrace    function_handle = function_handle.empty
        TraceBufferX    (:,1) double
        TraceBufferY    (:,1) double
        TraceBufferIdx  (1,1) double = 0
        TraceBufferMax  (1,1) double = 200
        SmoothedX       (:,1) double        % cached smoothed trace
        SmoothedY       (:,1) double
        PrevPos         (1,2) double = [NaN, NaN]
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, caps)
            %onInit  Create graphics pools and initialize state.
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
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);

            % Display scale factor (1.0 at ~180px reference)
            obj.Sc = min(areaW, areaH) / 180;

            obj.Gravity = max(0.06, areaH * 0.001);
            obj.SpawnTimer = 0;
            obj.StartTicLocal = tic;
            obj.FruitsSliced = 0;
            obj.FruitsDropped = 0;
            obj.SliceHistory = struct("centrality", {}, "speed", {}, ...
                "angle", {}, "position", {}, "time", {});
            obj.PrevPos = [NaN, NaN];

            % Pre-compute theta for fruit circles
            obj.ThetaCircle24 = linspace(0, 2*pi, 24);

            % Trace source: prefer host-provided smoothed trace
            if isfield(caps, "getSmoothedTrace")
                obj.GetSmoothedTrace = caps.getSmoothedTrace;
            else
                obj.GetSmoothedTrace = function_handle.empty;
            end

            % Own trace buffer (shifting array, same pattern as FourierEpicycle)
            obj.TraceBufferX = NaN(obj.TraceBufferMax, 1);
            obj.TraceBufferY = NaN(obj.TraceBufferMax, 1);
            obj.TraceBufferIdx = 0;
            obj.SmoothedX = zeros(0, 1);
            obj.SmoothedY = zeros(0, 1);

            % --- Pre-allocate Fruit Pool (8 slots) ---
            obj.FruitPoolPatch = cell(1, 8);
            obj.FruitPoolGlow = cell(1, 8);
            obj.FruitColor = cell(1, 8);
            obj.FruitX(:) = NaN;
            obj.FruitY(:) = NaN;
            obj.FruitVx(:) = 0;
            obj.FruitVy(:) = 0;
            obj.FruitRadius(:) = 0;
            obj.FruitSlashing(:) = false;
            obj.FruitEntryAngle(:) = NaN;
            obj.FruitActive(:) = false;
            nanXY = NaN(1, 24);
            for kk = 1:8
                obj.FruitPoolGlow{kk} = patch(ax, "XData", nanXY, "YData", nanXY, ...
                    "FaceColor", [1 1 1], "FaceAlpha", 0.15, ...
                    "EdgeColor", "none", "Visible", "off", "Tag", "GT_fruitninja");
                obj.FruitPoolPatch{kk} = patch(ax, "XData", nanXY, "YData", nanXY, ...
                    "FaceColor", [1 1 1], "FaceAlpha", 0.5, ...
                    "EdgeColor", [1 1 1], "LineWidth", 1.5, "Visible", "off", "Tag", "GT_fruitninja");
                obj.FruitColor{kk} = [1 1 1];
            end

            % --- Pre-allocate Half Pool (16 slots) ---
            obj.HalfPoolPatch = cell(1, 16);
            obj.HalfVerts = cell(1, 16);
            obj.HalfColor = cell(1, 16);
            obj.HalfVx(:) = 0;
            obj.HalfVy(:) = 0;
            obj.HalfSpin(:) = 0;
            obj.HalfAlpha(:) = 0;
            obj.HalfFrames(:) = 0;
            obj.HalfActive(:) = false;
            nanHalf = NaN(1, 20);
            for kk = 1:16
                obj.HalfPoolPatch{kk} = patch(ax, "XData", nanHalf, "YData", nanHalf, ...
                    "FaceColor", [1 1 1], "FaceAlpha", 0.5, ...
                    "EdgeColor", [1 1 1], "LineWidth", 1.5, "Visible", "off", "Tag", "GT_fruitninja");
                obj.HalfVerts{kk} = zeros(20, 2);
                obj.HalfColor{kk} = [1 1 1];
            end

            % --- Pre-allocate Slash Effect Pool (6 slots) ---
            obj.SlashPoolCore = cell(1, 6);
            obj.SlashPoolGlow = cell(1, 6);
            obj.SlashFrames(:) = 0;
            obj.SlashFadeFrames(:) = 0;
            obj.SlashIdxStart(:) = 0;
            obj.SlashIdxEnd(:) = 0;
            obj.SlashActive(:) = false;
            for kk = 1:6
                obj.SlashPoolGlow{kk} = line(ax, NaN, NaN, ...
                    "Color", [obj.ColorCyan, 0.5], ...
                    "LineWidth", 6, "Visible", "off", "Tag", "GT_fruitninja");
                obj.SlashPoolCore{kk} = line(ax, NaN, NaN, ...
                    "Color", [obj.ColorWhite, 0.9], ...
                    "LineWidth", 2.5, "Visible", "off", "Tag", "GT_fruitninja");
            end
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
            slashThresh = max(1.5, min(areaW, areaH) * 0.004);

            % --- Spawn fruits ---
            obj.SpawnTimer = obj.SpawnTimer + 1;
            spawnInterval = max(15, 45 - obj.FruitsSliced * 0.3);
            if obj.SpawnTimer >= spawnInterval
                obj.SpawnTimer = 0;
                obj.spawnFruit();
            end

            theta = obj.ThetaCircle24;

            % --- Update active fruits (gravity + movement) ---
            for kk = 1:8
                if ~obj.FruitActive(kk); continue; end

                fx = obj.FruitX(kk) + obj.FruitVx(kk);
                fy = obj.FruitY(kk) + obj.FruitVy(kk);
                fvy = obj.FruitVy(kk) + obj.Gravity;
                fvx = obj.FruitVx(kk);
                fRadius = obj.FruitRadius(kk);

                % Wall collision -- bounce off top, left, right (not bottom)
                if fx - fRadius < dx(1)
                    fx = dx(1) + fRadius;
                    fvx = abs(fvx) * 0.8;
                elseif fx + fRadius > dx(2)
                    fx = dx(2) - fRadius;
                    fvx = -abs(fvx) * 0.8;
                end
                if fy - fRadius < dy(1)
                    fy = dy(1) + fRadius;
                    fvy = abs(fvy) * 0.8;
                end

                obj.FruitX(kk) = fx;
                obj.FruitY(kk) = fy;
                obj.FruitVx(kk) = fvx;
                obj.FruitVy(kk) = fvy;

                % Update graphics
                circX = fx + fRadius * cos(theta);
                circY = fy + fRadius * sin(theta);
                pH = obj.FruitPoolPatch{kk};
                if ~isempty(pH) && isvalid(pH)
                    pH.XData = circX;
                    pH.YData = circY;
                end
                gH = obj.FruitPoolGlow{kk};
                if ~isempty(gH) && isvalid(gH)
                    gH.XData = circX;
                    gH.YData = circY;
                end

                % Slash detection: enter/exit through fruit
                if ~any(isnan(pos))
                    distToFruit = norm(pos(:) - [fx; fy]);
                    if obj.FruitSlashing(kk)
                        % Finger was inside -- check if it exited
                        if distToFruit > fRadius + 3
                            obj.sliceFruit(kk, pos, slashSpeed, traceX, traceY, nTrace);
                            continue;  % fruit deactivated, move on
                        end
                    else
                        % Check if finger entered fruit with some movement
                        if distToFruit < fRadius + 3 && slashSpeed > slashThresh
                            obj.FruitSlashing(kk) = true;
                            obj.FruitEntryAngle(kk) = atan2(pos(2) - fy, pos(1) - fx);
                        end
                    end
                end

                % Check if fruit fell off screen
                if fy > dy(2) + fRadius * 2
                    obj.FruitsDropped = obj.FruitsDropped + 1;
                    obj.resetCombo();
                    obj.deactivateFruit(kk);
                end
            end

            % --- Update split halves animation ---
            for kk = 1:16
                if ~obj.HalfActive(kk); continue; end

                obj.HalfFrames(kk) = obj.HalfFrames(kk) + 1;
                obj.HalfVx(kk) = obj.HalfVx(kk) * 0.97;
                obj.HalfVy(kk) = obj.HalfVy(kk) + obj.Gravity;
                obj.HalfAlpha(kk) = max(0, obj.HalfAlpha(kk) - 0.04);

                verts = obj.HalfVerts{kk};

                % Move vertices
                verts(:,1) = verts(:,1) + obj.HalfVx(kk);
                verts(:,2) = verts(:,2) + obj.HalfVy(kk);

                % Rotate
                centX = mean(verts(:,1));
                centY = mean(verts(:,2));
                ca = cos(obj.HalfSpin(kk)); sa = sin(obj.HalfSpin(kk));
                relX = verts(:,1) - centX;
                relY = verts(:,2) - centY;
                verts(:,1) = centX + relX * ca - relY * sa;
                verts(:,2) = centY + relX * sa + relY * ca;

                obj.HalfVerts{kk} = verts;

                hpH = obj.HalfPoolPatch{kk};
                if ~isempty(hpH) && isvalid(hpH)
                    hpH.XData = verts(:,1);
                    hpH.YData = verts(:,2);
                    hpH.FaceAlpha = obj.HalfAlpha(kk) * 0.6;
                    hpH.EdgeAlpha = obj.HalfAlpha(kk);
                end

                if obj.HalfAlpha(kk) <= 0 || obj.HalfFrames(kk) > 30
                    obj.deactivateHalf(kk);
                end
            end

            % --- Animate slash effects (re-read from trace with age offset) ---
            for kk = 1:6
                if ~obj.SlashActive(kk); continue; end

                obj.SlashFrames(kk) = obj.SlashFrames(kk) + 1;

                if obj.SlashFrames(kk) > obj.SlashFadeFrames(kk)
                    obj.deactivateSlash(kk);
                    continue;
                end

                % Re-read from live trace — buffer shifts 1/frame when full,
                % so subtract age to track the same physical points.
                % During growing phase (buffer not full), no shift occurs.
                if obj.TraceBufferIdx >= obj.TraceBufferMax
                    age = obj.SlashFrames(kk) - 1;
                else
                    age = 0;
                end
                trN = numel(traceX);
                i1 = max(1, obj.SlashIdxStart(kk) - age);
                i2 = min(trN, obj.SlashIdxEnd(kk) - age);
                if i1 < i2
                    sx = traceX(i1:i2);
                    sy = traceY(i1:i2);
                else
                    sx = NaN; sy = NaN;
                end
                fadeProgress = obj.SlashFrames(kk) / obj.SlashFadeFrames(kk);
                alphaVal = 1 - fadeProgress^0.5;

                coreH = obj.SlashPoolCore{kk};
                if ~isempty(coreH) && isvalid(coreH)
                    coreH.XData = sx;
                    coreH.YData = sy;
                    coreH.Color(4) = alphaVal * 0.9;
                end
                glowH = obj.SlashPoolGlow{kk};
                if ~isempty(glowH) && isvalid(glowH)
                    glowH.XData = sx;
                    glowH.YData = sy;
                    glowH.Color(4) = alphaVal * 0.5;
                end
            end

            obj.PrevPos = pos;
        end

        function onCleanup(obj)
            %onCleanup  Delete all pool graphics and reset state.

            % Delete fruit pool
            for kk = 1:8
                if ~isempty(obj.FruitPoolPatch) && numel(obj.FruitPoolPatch) >= kk
                    h = obj.FruitPoolPatch{kk};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
                if ~isempty(obj.FruitPoolGlow) && numel(obj.FruitPoolGlow) >= kk
                    h = obj.FruitPoolGlow{kk};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.FruitPoolPatch = {};
            obj.FruitPoolGlow = {};
            obj.FruitActive(:) = false;

            % Delete half pool
            for kk = 1:16
                if ~isempty(obj.HalfPoolPatch) && numel(obj.HalfPoolPatch) >= kk
                    h = obj.HalfPoolPatch{kk};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.HalfPoolPatch = {};
            obj.HalfActive(:) = false;

            % Delete slash pool
            for kk = 1:6
                if ~isempty(obj.SlashPoolCore) && numel(obj.SlashPoolCore) >= kk
                    h = obj.SlashPoolCore{kk};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
                if ~isempty(obj.SlashPoolGlow) && numel(obj.SlashPoolGlow) >= kk
                    h = obj.SlashPoolGlow{kk};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.SlashPoolCore = {};
            obj.SlashPoolGlow = {};
            obj.SlashActive(:) = false;

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
            %   Uses host-provided trace if available, otherwise own
            %   shifting buffer (same pattern as FourierEpicycle).
            if ~isempty(obj.GetSmoothedTrace)
                [tx, ty] = obj.GetSmoothedTrace();
            else
                % Update own shifting trace buffer
                if ~any(isnan(pos))
                    obj.TraceBufferIdx = min(obj.TraceBufferIdx + 1, obj.TraceBufferMax);
                    if obj.TraceBufferIdx == obj.TraceBufferMax
                        % Buffer full — shift left by 1
                        obj.TraceBufferX(1:end-1) = obj.TraceBufferX(2:end);
                        obj.TraceBufferY(1:end-1) = obj.TraceBufferY(2:end);
                    end
                    obj.TraceBufferX(obj.TraceBufferIdx) = pos(1);
                    obj.TraceBufferY(obj.TraceBufferIdx) = pos(2);
                end

                nValid = obj.TraceBufferIdx;
                if nValid < 1
                    tx = zeros(0, 1); ty = zeros(0, 1);
                    return;
                end
                tx = obj.TraceBufferX(1:nValid);
                ty = obj.TraceBufferY(1:nValid);

                % Smooth once, cache result
                if numel(tx) >= 5
                    tx = smoothdata(tx, "gaussian", 9);
                    ty = smoothdata(ty, "gaussian", 9);
                end
                obj.SmoothedX = tx;
                obj.SmoothedY = ty;
            end
        end

        function spawnFruit(obj)
            %spawnFruit  Activate an inactive fruit pool slot.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            % Find first inactive slot
            slot = find(~obj.FruitActive, 1);
            if isempty(slot); return; end  % pool full

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

            theta = obj.ThetaCircle24;
            circX = xPos + fruitRadius * cos(theta);
            circY = yPos + fruitRadius * sin(theta);

            % Populate slot data
            obj.FruitX(slot) = xPos;
            obj.FruitY(slot) = yPos;
            obj.FruitVx(slot) = velX;
            obj.FruitVy(slot) = velY;
            obj.FruitRadius(slot) = fruitRadius;
            obj.FruitColor{slot} = clr;
            obj.FruitSlashing(slot) = false;
            obj.FruitEntryAngle(slot) = NaN;
            obj.FruitActive(slot) = true;

            % Activate pool graphics
            gH = obj.FruitPoolGlow{slot};
            if ~isempty(gH) && isvalid(gH)
                gH.XData = circX;
                gH.YData = circY;
                gH.FaceColor = clr;
                gH.Visible = "on";
            end
            pH = obj.FruitPoolPatch{slot};
            if ~isempty(pH) && isvalid(pH)
                pH.XData = circX;
                pH.YData = circY;
                pH.FaceColor = clr;
                pH.EdgeColor = clr;
                pH.Visible = "on";
            end
        end

        function deactivateFruit(obj, slot)
            %deactivateFruit  Hide fruit and mark slot inactive.
            obj.FruitActive(slot) = false;
            pH = obj.FruitPoolPatch{slot};
            if ~isempty(pH) && isvalid(pH)
                pH.Visible = "off";
            end
            gH = obj.FruitPoolGlow{slot};
            if ~isempty(gH) && isvalid(gH)
                gH.Visible = "off";
            end
        end

        function deactivateHalf(obj, slot)
            %deactivateHalf  Hide half-patch and mark slot inactive.
            obj.HalfActive(slot) = false;
            hpH = obj.HalfPoolPatch{slot};
            if ~isempty(hpH) && isvalid(hpH)
                hpH.Visible = "off";
            end
        end

        function deactivateSlash(obj, slot)
            %deactivateSlash  Hide slash effect and mark slot inactive.
            obj.SlashActive(slot) = false;
            cH = obj.SlashPoolCore{slot};
            if ~isempty(cH) && isvalid(cH)
                cH.Visible = "off";
                cH.XData = NaN;
                cH.YData = NaN;
            end
            gH = obj.SlashPoolGlow{slot};
            if ~isempty(gH) && isvalid(gH)
                gH.Visible = "off";
                gH.XData = NaN;
                gH.YData = NaN;
            end
        end

        function sliceFruit(obj, fruitSlot, exitPos, slashSpeed, traceX, traceY, nTrace)
            %sliceFruit  Slice fruit into two halves with slash animation.
            %   Uses entry/exit angles for accurate cut geometry.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            fx = obj.FruitX(fruitSlot);
            fy = obj.FruitY(fruitSlot);
            fRadius = obj.FruitRadius(fruitSlot);
            fColor = obj.FruitColor{fruitSlot};
            fvx = obj.FruitVx(fruitSlot);
            fvy = obj.FruitVy(fruitSlot);

            obj.FruitsSliced = obj.FruitsSliced + 1;
            obj.incrementCombo();

            % Entry/exit angles relative to current fruit center
            a1 = obj.FruitEntryAngle(fruitSlot);
            a2 = atan2(exitPos(2) - fy, exitPos(1) - fx);

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
                "position", [fx, fy], "time", toc(obj.StartTicLocal));

            % Cut direction from entry to exit on circle boundary
            entryOnCircle = [fx + fRadius * cos(a1), fy + fRadius * sin(a1)];
            exitOnCircle  = [fx + fRadius * cos(a2), fy + fRadius * sin(a2)];
            slashDir = [exitOnCircle(1) - entryOnCircle(1); ...
                        exitOnCircle(2) - entryOnCircle(2)];
            if norm(slashDir) > 0
                slashDir = slashDir / norm(slashDir);
            else
                slashDir = [1; 0];
            end
            splitNorm = [-slashDir(2); slashDir(1)];

            % Build two half-pieces: arc from a1->a2 and arc from a2->a1+2pi
            for side = [1, -1]
                if side == 1
                    arcSpan = mod(a2 - a1, 2*pi);
                    arcTheta = linspace(a1, a1 + arcSpan, 20);
                else
                    arcSpan = mod(a1 - a2, 2*pi);
                    arcTheta = linspace(a2, a2 + arcSpan, 20);
                end
                hx = fx + fRadius * cos(arcTheta);
                hy = fy + fRadius * sin(arcTheta);

                % Find inactive half slot
                halfSlot = find(~obj.HalfActive, 1);
                if isempty(halfSlot); continue; end  % pool full, skip

                splitVx = fvx + splitNorm(1) * side * 1.5 * obj.Sc;
                splitVy = fvy + splitNorm(2) * side * 1.5 * obj.Sc - 0.5 * obj.Sc;

                obj.HalfVerts{halfSlot} = [hx(:), hy(:)];
                obj.HalfColor{halfSlot} = fColor;
                obj.HalfVx(halfSlot) = splitVx;
                obj.HalfVy(halfSlot) = splitVy;
                obj.HalfSpin(halfSlot) = side * 0.06;
                obj.HalfAlpha(halfSlot) = 1.0;
                obj.HalfFrames(halfSlot) = 0;
                obj.HalfActive(halfSlot) = true;

                hpH = obj.HalfPoolPatch{halfSlot};
                if ~isempty(hpH) && isvalid(hpH)
                    hpH.XData = hx(:);
                    hpH.YData = hy(:);
                    hpH.FaceColor = fColor;
                    hpH.EdgeColor = fColor;
                    hpH.FaceAlpha = 0.5;
                    hpH.EdgeAlpha = 1.0;
                    hpH.Visible = "on";
                end
            end

            % Slash animation — find entry/exit in RECENT trace only
            % (searching full buffer matches old positions, creating huge spans)
            searchLen = min(40, nTrace);
            searchStart = nTrace - searchLen + 1;
            recentX = traceX(searchStart:end);
            recentY = traceY(searchStart:end);
            entryOnCircle = [fx + fRadius * cos(a1), ...
                             fy + fRadius * sin(a1)];
            entryDists = (recentX - entryOnCircle(1)).^2 + ...
                         (recentY - entryOnCircle(2)).^2;
            [~, entryLocal] = min(entryDists);
            exitDists = (recentX - exitPos(1)).^2 + ...
                        (recentY - exitPos(2)).^2;
            [~, exitLocal] = min(exitDists);
            entryIdx = searchStart + entryLocal - 1;
            exitIdx = searchStart + exitLocal - 1;
            padVal = 4;
            idxStart = max(1, min(entryIdx, exitIdx) - padVal);
            idxEnd = min(nTrace, max(entryIdx, exitIdx) + padVal);
            sx = traceX(idxStart:idxEnd);
            sy = traceY(idxStart:idxEnd);

            % Find inactive slash slot
            slashSlot = find(~obj.SlashActive, 1);
            if ~isempty(slashSlot)
                fadeFrames = 12;
                obj.SlashFrames(slashSlot) = 0;
                obj.SlashFadeFrames(slashSlot) = fadeFrames;
                obj.SlashIdxStart(slashSlot) = idxStart;
                obj.SlashIdxEnd(slashSlot) = idxEnd;
                obj.SlashActive(slashSlot) = true;

                glowH = obj.SlashPoolGlow{slashSlot};
                if ~isempty(glowH) && isvalid(glowH)
                    glowH.XData = sx;
                    glowH.YData = sy;
                    glowH.Color = [obj.ColorCyan, 0.5];
                    glowH.Visible = "on";
                end
                coreH = obj.SlashPoolCore{slashSlot};
                if ~isempty(coreH) && isvalid(coreH)
                    coreH.XData = sx;
                    coreH.YData = sy;
                    coreH.Color = [obj.ColorWhite, 0.9];
                    coreH.Visible = "on";
                end
            end

            % Spawn burst effect at fruit center
            obj.spawnHitEffect([fx, fy], fColor, points, fRadius);

            % Deactivate original fruit (hide, not delete)
            obj.deactivateFruit(fruitSlot);
        end
    end
end
