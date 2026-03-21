classdef TargetPractice < GameBase
    %TargetPractice  Target practice — accuracy and speed game.
    %   Random targets appear on screen. Hit them before they time out.
    %   Targets shrink and timeout decreases as combo grows.
    %   Also used for pointing accuracy training in the webcam app.
    %
    %   Standalone: games.TargetPractice().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   TODO: Target timeout uses wall-clock time (toc), not DtScale. If RefFPS
    %         is changed to slow/speed the game, timeout duration stays the same.
    %         Consider scaling timeout by RefFPS ratio for full consistency.
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Target Practice"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Target
        TargetPos       (1,2) double = [NaN, NaN]
        TargetRadius    (1,1) double = 30
        TargetSpawnTic  uint64
        TargetTimeout   (1,1) double = 4.0
        TargetIndex     (1,1) double = 0
        PulsePhase      (1,1) double = 0

        % Path tracking
        PathSinceSpawn  (1,1) double = 0
        PrevPos         (1,2) double = [NaN, NaN]

        % Display scale factor (1.0 at ~180px GestureTrainer height)
        Sc              (1,1) double = 1

        % Stats
        TargetsHit      (1,1) double = 0
        TargetsMissed   (1,1) double = 0
        TargetHistory   struct = struct("pos", {}, "hitTime", {}, ...
                                        "hitDist", {}, "pathLen", {}, ...
                                        "directDist", {}, "hit", {})
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        TargetGlow
        TargetRingOuter
        TargetRingInner
        TargetDot
        TrailLine
        TimeBarBg
        TimeBarFg
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize state.
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

            obj.TargetPos = [NaN, NaN];
            obj.TargetIndex = 0;
            obj.TargetsHit = 0;
            obj.TargetsMissed = 0;
            obj.PathSinceSpawn = 0;
            obj.PrevPos = [NaN, NaN];
            obj.PulsePhase = 0;
            obj.TargetHistory = struct("pos", {}, "hitTime", {}, ...
                "hitDist", {}, "pathLen", {}, "directDist", {}, "hit", {});

            dx = displayRange.X;
            dy = displayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);
            obj.Sc = min(areaW, areaH) / 180;

            % --- Target rings (scatter for proper transparency) ---
            ps = obj.getPixelScale();
            obj.TargetGlow = scatter(ax, NaN, NaN, 1, ...
                obj.ColorCyan, "filled", "MarkerFaceAlpha", 0.15, ...
                "Visible", "off", "Tag", "GT_targetpractice");
            obj.TargetRingOuter = scatter(ax, NaN, NaN, 1, ...
                obj.ColorCyan, "filled", "MarkerFaceAlpha", 0.4, ...
                "Visible", "off", "Tag", "GT_targetpractice");
            obj.TargetRingInner = scatter(ax, NaN, NaN, 1, ...
                obj.ColorWhite, "filled", "MarkerFaceAlpha", 0.3, ...
                "Visible", "off", "Tag", "GT_targetpractice");
            obj.TargetDot = line(ax, NaN, NaN, ...
                "Color", [obj.ColorWhite, 1], "Marker", ".", ...
                "MarkerSize", 4.3 * ps, "LineStyle", "none", ...
                "Visible", "off", "Tag", "GT_targetpractice");

            % --- Trail line (ghost path to target) ---
            obj.TrailLine = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.12], "LineWidth", 1, ...
                "LineStyle", ":", "Visible", "off", "Tag", "GT_targetpractice");

            % --- Time bar ---
            barY = dy(2) - 8;
            barH = 4;
            obj.TimeBarBg = patch(ax, ...
                [dx(1) dx(2) dx(2) dx(1)], ...
                [barY barY barY+barH barY+barH], ...
                [0.3 0.3 0.3], "FaceAlpha", 0.3, "EdgeColor", "none", ...
                "Visible", "off", "Tag", "GT_targetpractice");
            obj.TimeBarFg = patch(ax, ...
                [dx(1) dx(2) dx(2) dx(1)], ...
                [barY barY barY+barH barY+barH], ...
                obj.ColorCyan, "FaceAlpha", 0.7, "EdgeColor", "none", ...
                "Visible", "off", "Tag", "GT_targetpractice");

            % Show time bar and spawn first target
            obj.showTimeBar();
            obj.spawnTarget();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame target practice game logic.

            % Accumulate path length
            if ~any(isnan(pos)) && ~any(isnan(obj.PrevPos))
                obj.PathSinceSpawn = obj.PathSinceSpawn ...
                    + norm(pos - obj.PrevPos);
            end
            obj.PrevPos = pos;

            % Check hit (swept segment: PrevPos -> pos vs target circle)
            if ~any(isnan(pos)) && ~any(isnan(obj.TargetPos))
                dist = obj.segmentPointDist(obj.PrevPos, pos, obj.TargetPos);
                if dist <= obj.TargetRadius
                    obj.onTargetHit(dist);
                    return;
                end
            end

            % Check timeout
            elapsed = toc(obj.TargetSpawnTic);
            if elapsed > obj.TargetTimeout
                obj.onTargetMiss();
                return;
            end

            % Animate target
            obj.PulsePhase = obj.PulsePhase + 0.12 * obj.DtScale;
            obj.animateTarget(elapsed, pos);

            % Update time bar
            obj.updateTimeBar(elapsed / obj.TargetTimeout);
        end

        function onCleanup(obj)
            %onCleanup  Delete all graphics.
            handles = {obj.TargetGlow, obj.TargetRingOuter, ...
                obj.TargetRingInner, obj.TargetDot, obj.TrailLine, ...
                obj.TimeBarBg, obj.TimeBarFg};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.TargetGlow = [];
            obj.TargetRingOuter = [];
            obj.TargetRingInner = [];
            obj.TargetDot = [];
            obj.TrailLine = [];
            obj.TimeBarBg = [];
            obj.TimeBarFg = [];

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_targetpractice");
        end

        function handled = onKeyPress(~, key)
            %onKeyPress  Block arrow keys (mouse-only game).
            handled = any(key == ["uparrow", "downarrow", "leftarrow", "rightarrow"]);
        end

        function r = getResults(obj)
            %getResults  Return target practice results.
            r.Title = "TARGET PRACTICE";
            nHit = obj.TargetsHit;
            nTotal = nHit + obj.TargetsMissed;
            accuracy = 0;
            if nTotal > 0; accuracy = nHit / nTotal * 100; end
            avgTime = NaN;
            hitEntries = obj.TargetHistory([obj.TargetHistory.hit]);
            if ~isempty(hitEntries)
                avgTime = mean([hitEntries.hitTime]);
            end
            r.Lines = {
                sprintf("Targets: %d/%d (%.0f%%)  |  Avg: %.2fs", ...
                    nHit, nTotal, accuracy, avgTime)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function spawnTarget(obj)
            %spawnTarget  Place a new target at a random reachable position.
            margin = round(35 * obj.Sc);
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            xMin = dx(1) + margin;
            xMax = dx(2) - margin;
            yMin = dy(1) + margin;
            yMax = dy(2) - margin;

            % Scale distances to display area
            areaSpan = min(xMax - xMin, yMax - yMin);
            minFingerDist = max(30, areaSpan * 0.35);
            minTargetDist = max(20, areaSpan * 0.2);

            fingerPos = obj.PrevPos;
            bestPos = [NaN, NaN];
            bestScore = -inf;

            for attempt = 1:50
                x = xMin + rand * (xMax - xMin);
                y = yMin + rand * (yMax - yMin);
                candidate = [x, y];

                if ~any(isnan(fingerPos))
                    dFinger = norm(candidate - fingerPos);
                else
                    dFinger = inf;
                end
                if ~any(isnan(obj.TargetPos))
                    dPrev = norm(candidate - obj.TargetPos);
                else
                    dPrev = inf;
                end

                if dFinger >= minFingerDist && dPrev >= minTargetDist
                    bestPos = candidate;
                    break;
                end

                score = dFinger + dPrev;
                if score > bestScore
                    bestScore = score;
                    bestPos = candidate;
                end
            end
            if any(isnan(bestPos))
                bestPos = [(xMin + xMax) / 2, (yMin + yMax) / 2];
            end

            obj.TargetPos = bestPos;
            obj.TargetSpawnTic = tic;
            obj.TargetIndex = obj.TargetIndex + 1;
            obj.PathSinceSpawn = 0;
            obj.PulsePhase = 0;

            % Difficulty scaling based on combo
            baseRadius = round(30 * obj.Sc);
            minRadius = max(2, round(3 * obj.Sc));
            obj.TargetRadius = max(minRadius, baseRadius - obj.Combo * 0.5);
            baseTimeout = 4.0;
            minTimeout = 0.1;
            obj.TargetTimeout = max(minTimeout, baseTimeout - obj.Combo * 0.06);

            obj.showTarget();
        end

        function onTargetHit(obj, dist)
            %onTargetHit  Process a successful target hit.
            hitTime = toc(obj.TargetSpawnTic);

            % Path efficiency
            if obj.TargetIndex >= 2 && ~isempty(obj.TargetHistory)
                prevTarget = obj.TargetHistory(end).pos;
                idealDist = norm(obj.TargetPos - prevTarget);
            else
                idealDist = obj.PathSinceSpawn;
            end
            if idealDist > 0
                pathRatio = obj.PathSinceSpawn / idealDist; %#ok<NASGU>
            end

            % Score — raw multiplier (no floor) matches original Mode 1
            obj.incrementCombo();
            comboMult = obj.Combo * 0.1;
            totalPoints = round(100 * comboMult);
            obj.addScore(totalPoints);
            obj.TargetsHit = obj.TargetsHit + 1;

            % Record history
            entry.pos = obj.TargetPos;
            entry.hitTime = hitTime;
            entry.hitDist = dist;
            entry.pathLen = obj.PathSinceSpawn;
            entry.directDist = idealDist;
            entry.hit = true;
            obj.TargetHistory(end + 1) = entry;

            % Visual feedback (radius matches current target size)
            obj.spawnHitEffect(obj.TargetPos, obj.ColorGreen, totalPoints, obj.TargetRadius);

            % Next target
            obj.spawnTarget();
        end

        function onTargetMiss(obj)
            %onTargetMiss  Handle target timeout.
            obj.resetCombo();
            obj.TargetsMissed = obj.TargetsMissed + 1;

            % Record miss
            entry.pos = obj.TargetPos;
            entry.hitTime = obj.TargetTimeout;
            entry.hitDist = NaN;
            entry.pathLen = obj.PathSinceSpawn;
            entry.directDist = NaN;
            entry.hit = false;
            obj.TargetHistory(end + 1) = entry;

            % Visual feedback (radius matches current target size)
            obj.spawnHitEffect(obj.TargetPos, obj.ColorRed, 0, obj.TargetRadius);

            % Next target
            obj.spawnTarget();
        end

        function showTarget(obj)
            %showTarget  Make target visible at current TargetPos.
            if any(isnan(obj.TargetPos)); return; end
            r = obj.TargetRadius;
            cx = obj.TargetPos(1);
            cy = obj.TargetPos(2);
            ps = obj.getPixelScale();

            outerDiam = r * 2.5 * ps;
            innerDiam = r * 0.5 * 2.5 * ps;
            glowDiam = r * 3.5 * ps;

            if ~isempty(obj.TargetGlow) && isvalid(obj.TargetGlow)
                set(obj.TargetGlow, "XData", cx, "YData", cy, ...
                    "SizeData", pi * (glowDiam/2)^2, "Visible", "on");
            end
            if ~isempty(obj.TargetRingOuter) && isvalid(obj.TargetRingOuter)
                set(obj.TargetRingOuter, "XData", cx, "YData", cy, ...
                    "SizeData", pi * (outerDiam/2)^2, "Visible", "on");
            end
            if ~isempty(obj.TargetRingInner) && isvalid(obj.TargetRingInner)
                set(obj.TargetRingInner, "XData", cx, "YData", cy, ...
                    "SizeData", pi * (innerDiam/2)^2, "Visible", "on");
            end
            if ~isempty(obj.TargetDot) && isvalid(obj.TargetDot)
                set(obj.TargetDot, "XData", cx, "YData", cy, "Visible", "on");
            end
        end

        function hideTarget(obj)
            %hideTarget  Hide all target graphics.
            handles = [obj.TargetGlow, obj.TargetRingOuter, ...
                obj.TargetRingInner, obj.TargetDot, obj.TrailLine];
            for k = 1:numel(handles)
                if ~isempty(handles(k)) && isvalid(handles(k))
                    handles(k).Visible = "off";
                end
            end
        end

        function animateTarget(obj, elapsed, fingerPos)
            %animateTarget  Per-frame target animation (breathing + color).
            if any(isnan(obj.TargetPos)); return; end
            r = obj.TargetRadius;
            cx = obj.TargetPos(1);
            cy = obj.TargetPos(2);
            ps = obj.getPixelScale();

            % Breathing
            breathe = 1 + 0.12 * sin(obj.PulsePhase);
            rOuter = r * breathe;
            rInner = r * 0.5 * breathe;

            outerDiam = rOuter * 2.5 * ps;
            innerDiam = rInner * 2.5 * ps;
            glowDiam = rOuter * 3.5 * ps;

            if ~isempty(obj.TargetRingOuter) && isvalid(obj.TargetRingOuter)
                obj.TargetRingOuter.SizeData = pi * (outerDiam/2)^2;
            end
            if ~isempty(obj.TargetGlow) && isvalid(obj.TargetGlow)
                obj.TargetGlow.SizeData = pi * (glowDiam/2)^2;
            end
            if ~isempty(obj.TargetRingInner) && isvalid(obj.TargetRingInner)
                obj.TargetRingInner.SizeData = pi * (innerDiam/2)^2;
            end

            % Color shift: cyan -> red as timeout approaches
            urgency = min(1, elapsed / obj.TargetTimeout);
            if urgency < 0.6
                ringColor = obj.ColorCyan;
            else
                t = min(1, (urgency - 0.6) / 0.4);
                ringColor = obj.ColorCyan * (1 - t) + obj.ColorRed * t;
            end
            if ~isempty(obj.TargetRingOuter) && isvalid(obj.TargetRingOuter)
                obj.TargetRingOuter.CData = ringColor;
                obj.TargetRingOuter.MarkerFaceAlpha = 0.3 + 0.3 * sin(obj.PulsePhase);
            end
            if ~isempty(obj.TargetGlow) && isvalid(obj.TargetGlow)
                obj.TargetGlow.CData = ringColor;
                obj.TargetGlow.MarkerFaceAlpha = 0.1 + 0.08 * sin(obj.PulsePhase);
            end

            % Ghost trail from finger to target
            if ~any(isnan(fingerPos)) && ~isempty(obj.TrailLine) && isvalid(obj.TrailLine)
                obj.TrailLine.XData = [fingerPos(1), cx];
                obj.TrailLine.YData = [fingerPos(2), cy];
                trailAlpha = 0.08 + 0.06 * (1 - urgency);
                obj.TrailLine.Color = [ringColor, trailAlpha];
                obj.TrailLine.Visible = "on";
            end
        end

        function showTimeBar(obj)
            %showTimeBar  Show the timeout progress bar.
            if ~isempty(obj.TimeBarBg) && isvalid(obj.TimeBarBg)
                obj.TimeBarBg.Visible = "on";
            end
            if ~isempty(obj.TimeBarFg) && isvalid(obj.TimeBarFg)
                obj.TimeBarFg.Visible = "on";
            end
        end

        function updateTimeBar(obj, fraction)
            %updateTimeBar  Update time bar fill (0=full, 1=empty).
            if isempty(obj.TimeBarFg) || ~isvalid(obj.TimeBarFg); return; end
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            barY = dy(2) - 8;
            barH = 4;
            remaining = 1 - fraction;
            xEnd = dx(1) + remaining * (dx(2) - dx(1));
            obj.TimeBarFg.XData = [dx(1) xEnd xEnd dx(1)];
            obj.TimeBarFg.YData = [barY barY barY+barH barY+barH];

            % Color: cyan -> yellow -> red
            if fraction < 0.5
                barColor = obj.ColorCyan;
            elseif fraction < 0.8
                t = (fraction - 0.5) / 0.3;
                barColor = obj.ColorCyan * (1 - t) + obj.ColorGold * t;
            else
                t = (fraction - 0.8) / 0.2;
                barColor = obj.ColorGold * (1 - t) + obj.ColorRed * t;
            end
            obj.TimeBarFg.FaceColor = barColor;
        end
    end

    % =================================================================
    % STATIC UTILITIES
    % =================================================================
    methods (Static, Access = private)
        function d = segmentPointDist(a, b, p)
            %segmentPointDist  Minimum distance from point P to segment A-B.
            %   Handles degenerate case (A==B) and clamps projection to [0,1].
            ab = b - a;
            ap = p - a;
            lenSq = dot(ab, ab);
            if lenSq < 1e-12
                d = norm(ap);
                return;
            end
            t = max(0, min(1, dot(ap, ab) / lenSq));
            closest = a + t * ab;
            d = norm(p - closest);
        end
    end
end
