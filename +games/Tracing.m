classdef Tracing < GameBase
    %Tracing  Path-tracing accuracy game.
    %   A corridor appears on screen via sweep preview animation. Reach the
    %   start beacon, then trace along the path within the corridor. Paths
    %   increase in difficulty (tighter corridors, complex shapes).
    %
    %   Path types by tier:
    %     T1 = [curve, sCurve]
    %     T2 = [wave, oscillate, arc]
    %     T3 = [loop, figure8, spiral]
    %     T4 = [longSpiral]
    %
    %   Standalone: games.Tracing().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost, games.PathUtils

    properties (Constant)
        Name = "Tracing"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        Sc                  (1,1) double = 1           % display scale factor

        % Phase machine
        TracingPhase        (1,1) string = "preview"  % preview|approach|tracing|scored|gap

        % Current path
        CurrentPath         struct = struct()
        CorridorWidth       (1,1) double = 20
        PathIndex           (1,1) double = 0
        PathSpawnTic        uint64
        PathTimeLimit       (1,1) double = 12

        % Preview animation
        PreviewFrames       (1,1) double = 0
        PreviewTotalFrames  (1,1) double = 30

        % Scored phase animation
        ScoredFrames        (1,1) double = 0
        ScoredFlashColor    (1,3) double = [1, 1, 1]
        ScoredIsSuccess     (1,1) logical = false
        ScoredTracedVerts   (:,2) double = zeros(0,2)
        ScoredBgVerts       (:,2) double = zeros(0,2)
        ScoredTracedGlowXY  = {}
        ScoredBgGlowXY      = {}
        ScoredCentroid      (1,2) double = [0, 0]

        % Gap phase
        GapFrames           (1,1) double = 0

        % Progress tracking (forward-only)
        TracingProgressIdx  (1,1) double = 0

        % Session stats
        PathsCompleted      (1,1) double = 0
        PathsFailed         (1,1) double = 0

        % Per-path accumulators
        TracingDeviationSum (1,1) double = 0
        TracingDeviationMax (1,1) double = 0
        TracingFrameCount   (1,1) double = 0
        TracingOnPathCount  (1,1) double = 0
        TracingActualDist   (1,1) double = 0
        TracingPrevFingerPos (1,2) double = [NaN, NaN]

        % Per-frame deviation buffer (for jitter calculation)
        TracingDevBuf       (1,:) double
        TracingDevBufIdx    (1,1) double = 0

        % Target beacon state (for approach phase)
        TargetPos           (1,2) double = [NaN, NaN]
        TargetRadius        (1,1) double = 30
        TargetTimeout       (1,1) double = 4.0
        PulsePhase          (1,1) double = 0

        % Per-path history
        PathHistory         struct = struct("type", {}, "difficulty", {}, ...
                                            "completion", {}, "avgDeviation", {}, ...
                                            "maxDeviation", {}, "jitter", {}, ...
                                            "elapsed", {}, "timeLimit", {}, ...
                                            "corridorWidth", {}, "score", {}, ...
                                            "deviationRatio", {}, "actualPathLen", {}, ...
                                            "idealPathLen", {}, "pathEfficiency", {})
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        % Corridor bands
        PathBandBg              % patch — filled corridor (full path, dim cyan)
        PathBandBgGlow          % line  — glow outline around bg corridor
        PathBandTraced          % patch — filled corridor (traced section, bright green)
        PathBandTracedGlow      % line  — glow outline around traced corridor

        % Preview sweep
        PathPreviewDot          % line — sweep dot
        PathPreviewGlow         % line — glow behind sweep dot

        % Approach / tracing helpers
        DirectionArrow          % quiver — direction indicator at path start
        DeviationWhisker        % line  — finger-to-path line
        ZoneCircle              % line  — corridor circle around finger

        % Target beacon (reused for approach and progress target)
        TargetGlow              % line — glow ring
        TargetRingOuter         % line — outer ring
        TargetRingInner         % line — inner ring
        TargetDot               % line — center dot
        TrailLine               % line — ghost trail to target

        % Time bar
        TimeBarBg               % patch — bar background
        TimeBarFg               % patch — bar foreground
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

            % Reset state
            obj.PathIndex = 0;
            obj.PathsCompleted = 0;
            obj.PathsFailed = 0;
            obj.TracingPhase = "preview";
            obj.PulsePhase = 0;
            obj.TargetPos = [NaN, NaN];
            obj.PathHistory = struct("type", {}, "difficulty", {}, ...
                "completion", {}, "avgDeviation", {}, ...
                "maxDeviation", {}, "jitter", {}, ...
                "elapsed", {}, "timeLimit", {}, ...
                "corridorWidth", {}, "score", {}, ...
                "deviationRatio", {}, "actualPathLen", {}, ...
                "idealPathLen", {}, "pathEfficiency", {});

            dxR = displayRange.X;
            dyR = displayRange.Y;
            obj.Sc = min(diff(dxR), diff(dyR)) / 180;

            % --- Target beacon rings ---
            obj.TargetGlow = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.15], "LineWidth", 12, ...
                "LineStyle", "-", "Visible", "off", "Tag", "GT_tracing");
            obj.TargetRingOuter = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.6], "LineWidth", 2.5, ...
                "LineStyle", "-", "Visible", "off", "Tag", "GT_tracing");
            obj.TargetRingInner = line(ax, NaN, NaN, ...
                "Color", [obj.ColorWhite, 0.9], "LineWidth", 1.5, ...
                "LineStyle", "-", "Visible", "off", "Tag", "GT_tracing");
            obj.TargetDot = line(ax, NaN, NaN, ...
                "Color", [obj.ColorWhite, 1], "Marker", ".", ...
                "MarkerSize", 8, "LineStyle", "none", ...
                "Visible", "off", "Tag", "GT_tracing");

            % --- Ghost trail to target ---
            obj.TrailLine = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.12], "LineWidth", 1, ...
                "LineStyle", ":", "Visible", "off", "Tag", "GT_tracing");

            % --- Time bar ---
            barY = dyR(2) - 8;
            barH = 4;
            obj.TimeBarBg = patch(ax, ...
                [dxR(1) dxR(2) dxR(2) dxR(1)], ...
                [barY barY barY+barH barY+barH], ...
                [0.3 0.3 0.3], "FaceAlpha", 0.3, "EdgeColor", "none", ...
                "Visible", "off", "Tag", "GT_tracing");
            obj.TimeBarFg = patch(ax, ...
                [dxR(1) dxR(2) dxR(2) dxR(1)], ...
                [barY barY barY+barH barY+barH], ...
                obj.ColorCyan, "FaceAlpha", 0.7, "EdgeColor", "none", ...
                "Visible", "off", "Tag", "GT_tracing");

            % --- Corridor patches (bg and traced) ---
            obj.PathBandBg = patch(ax, NaN, NaN, obj.ColorCyan, ...
                "FaceAlpha", 0.25, "EdgeColor", "none", ...
                "Visible", "off", "Tag", "GT_tracing");
            obj.PathBandBgGlow = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.7], "LineWidth", 3, ...
                "LineStyle", "-", "Visible", "off", "Tag", "GT_tracing");
            obj.PathBandTraced = patch(ax, NaN, NaN, [0.15, 1, 0.35], ...
                "FaceAlpha", 0.85, "EdgeColor", "none", ...
                "Visible", "off", "Tag", "GT_tracing");
            obj.PathBandTracedGlow = line(ax, NaN, NaN, ...
                "Color", [obj.ColorGreen, 0.7], "LineWidth", 3, ...
                "LineStyle", "-", "Visible", "off", "Tag", "GT_tracing");

            % --- Preview sweep dot and glow ---
            obj.PathPreviewGlow = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.3], "Marker", ".", ...
                "MarkerSize", 24, "LineStyle", "none", ...
                "Visible", "off", "Tag", "GT_tracing");
            obj.PathPreviewDot = line(ax, NaN, NaN, ...
                "Color", [obj.ColorWhite, 1], "Marker", ".", ...
                "MarkerSize", 12, "LineStyle", "none", ...
                "Visible", "off", "Tag", "GT_tracing");

            % --- Deviation whisker (finger to nearest path point) ---
            obj.DeviationWhisker = line(ax, NaN, NaN, ...
                "Color", [obj.ColorGreen, 0.3], "LineWidth", 1, ...
                "LineStyle", "-", "Visible", "off", "Tag", "GT_tracing");

            % --- Zone circle (corridor visualization around finger) ---
            obj.ZoneCircle = line(ax, NaN, NaN, ...
                "Color", [obj.ColorGreen, 0.12], "LineWidth", 1, ...
                "LineStyle", "-", "Visible", "off", "Tag", "GT_tracing");

            % Spawn first path
            obj.spawnNextPath();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame tracing game logic.
            switch obj.TracingPhase
                case "preview"
                    obj.updatePreview();
                case "approach"
                    obj.updateApproach(pos);
                case "tracing"
                    obj.updateTracing(pos);
                case "scored"
                    obj.updateScored();
                case "gap"
                    obj.updateGap();
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all graphics.
            handles = {obj.PathBandBg, obj.PathBandBgGlow, ...
                obj.PathBandTraced, obj.PathBandTracedGlow, ...
                obj.PathPreviewDot, obj.PathPreviewGlow, ...
                obj.DeviationWhisker, obj.ZoneCircle, ...
                obj.TargetGlow, obj.TargetRingOuter, ...
                obj.TargetRingInner, obj.TargetDot, obj.TrailLine, ...
                obj.TimeBarBg, obj.TimeBarFg};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            % Delete quiver arrow separately
            if ~isempty(obj.DirectionArrow) && isvalid(obj.DirectionArrow)
                delete(obj.DirectionArrow);
            end
            obj.PathBandBg = [];
            obj.PathBandBgGlow = [];
            obj.PathBandTraced = [];
            obj.PathBandTracedGlow = [];
            obj.PathPreviewDot = [];
            obj.PathPreviewGlow = [];
            obj.DeviationWhisker = [];
            obj.ZoneCircle = [];
            obj.TargetGlow = [];
            obj.TargetRingOuter = [];
            obj.TargetRingInner = [];
            obj.TargetDot = [];
            obj.TrailLine = [];
            obj.TimeBarBg = [];
            obj.TimeBarFg = [];
            obj.DirectionArrow = [];

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_tracing");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for tracing.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return tracing-specific results.
            r.Title = "TRACING";
            nTotal = obj.PathsCompleted + obj.PathsFailed;
            avgDev = NaN;
            if ~isempty(obj.PathHistory)
                avgDev = mean([obj.PathHistory.avgDeviation], "omitnan");
            end
            r.Lines = {
                sprintf("Paths: %d/%d  |  Avg Dev: %.1fpx  |  Max Combo: %d", ...
                    obj.PathsCompleted, nTotal, avgDev, obj.MaxCombo)
            };
        end
    end

    % =================================================================
    % PRIVATE — PATH LIFECYCLE
    % =================================================================
    methods (Access = private)

        function spawnNextPath(obj)
            %spawnNextPath  Generate and display the next tracing path.
            obj.PathIndex = obj.PathIndex + 1;

            % Difficulty tier based on path number
            if obj.PathIndex <= 2
                tier = 1;
            elseif obj.PathIndex <= 4
                tier = 2;
            elseif obj.PathIndex <= 7
                tier = 3;
            elseif obj.PathIndex <= 9
                tier = 4;
            else
                tier = randi(4);
            end

            % Corridor width shrinks with tier and combo (scaled to display)
            baseWidths = [16, 14, 11, 8];
            obj.CorridorWidth = max(4 * obj.Sc, (baseWidths(min(tier, 4)) - obj.Combo * 0.2) * obj.Sc);

            % Time limit per tier
            timeLimits = [15, 13, 11, 10];
            obj.PathTimeLimit = timeLimits(min(tier, 4));

            % Generate path
            obj.CurrentPath = games.PathUtils.generatePath(tier, ...
                obj.DisplayRange.X, obj.DisplayRange.Y, obj.CorridorWidth);

            obj.enterPreview();
        end

        function enterPreview(obj)
            %enterPreview  Sweep-reveal the path with a progressive patch draw.
            obj.TracingPhase = "preview";
            obj.PreviewTotalFrames = 30;  % ~0.6s sweep
            obj.PreviewFrames = obj.PreviewTotalFrames;

            pathData = obj.CurrentPath;

            % Start with empty background glow
            if ~isempty(obj.PathBandBgGlow) && isvalid(obj.PathBandBgGlow)
                set(obj.PathBandBgGlow, "XData", NaN, "YData", NaN, ...
                    "Color", [obj.ColorCyan, 0.7], "Visible", "on");
            end

            % Recreate bg band as Faces/Vertices patch for sweep animation
            ax = obj.Ax;
            if ~isempty(obj.PathBandBg) && isvalid(obj.PathBandBg)
                delete(obj.PathBandBg);
            end
            obj.PathBandBg = patch(ax, "Faces", 1, ...
                "Vertices", [0 0], ...
                "FaceColor", obj.ColorCyan, "FaceAlpha", 0.35, ...
                "EdgeColor", "none", "Visible", "on", "Tag", "GT_tracing");
            uistack(obj.PathBandBg, "bottom");
            uistack(obj.PathBandBg, "up");  % above image

            % Traced glow + patch hidden during preview
            if ~isempty(obj.PathBandTracedGlow) && isvalid(obj.PathBandTracedGlow)
                set(obj.PathBandTracedGlow, "XData", NaN, "YData", NaN, ...
                    "Visible", "off");
            end
            if ~isempty(obj.PathBandTraced) && isvalid(obj.PathBandTraced)
                set(obj.PathBandTraced, "XData", NaN, "YData", NaN, ...
                    "Visible", "off");
            end

            % Show sweep dot at start
            if ~isempty(obj.PathPreviewGlow) && isvalid(obj.PathPreviewGlow)
                set(obj.PathPreviewGlow, "XData", pathData.X(1), "YData", pathData.Y(1), ...
                    "Color", [obj.ColorCyan, 0.3], "LineStyle", "none", ...
                    "Marker", ".", "MarkerSize", 24, "Visible", "on");
            end
            if ~isempty(obj.PathPreviewDot) && isvalid(obj.PathPreviewDot)
                set(obj.PathPreviewDot, "XData", pathData.X(1), "YData", pathData.Y(1), ...
                    "Color", [obj.ColorWhite, 1], "LineStyle", "none", ...
                    "Marker", ".", "MarkerSize", 12, "Visible", "on");
            end
        end

        function updatePreview(obj)
            %updatePreview  Progressive sweep — extend corridor patch each frame.
            obj.PreviewFrames = obj.PreviewFrames - 1;
            tProgress = 1 - obj.PreviewFrames / obj.PreviewTotalFrames;  % 0->1
            pathData = obj.CurrentPath;
            nPts = numel(pathData.X);
            halfW = obj.CorridorWidth / 2;

            % Sweep index — ease-out cubic for smooth deceleration
            eased = 1 - (1 - tProgress)^3;
            sweepIdx = max(2, round(eased * nPts));

            % Closed paths: snap when near closure in final 1% of sweep
            fullPathClosed = hypot(pathData.X(end) - pathData.X(1), ...
                pathData.Y(end) - pathData.Y(1)) < halfW * 2;
            if fullPathClosed && sweepIdx > round(0.99 * nPts)
                gapDist = hypot(pathData.X(sweepIdx) - pathData.X(1), ...
                    pathData.Y(sweepIdx) - pathData.Y(1));
                if gapDist < obj.CorridorWidth * 1.5
                    sweepIdx = nPts;
                end
            end

            try
                % Polybuffer throughout — avoids transition artifacts
                ps = games.PathUtils.buildBandPolyshape( ...
                    pathData.X(1:sweepIdx), pathData.Y(1:sweepIdx), halfW);
                triObj = triangulation(ps);
                if ~isempty(obj.PathBandBg) && isvalid(obj.PathBandBg)
                    set(obj.PathBandBg, "Faces", triObj.ConnectivityList, ...
                        "Vertices", triObj.Points);
                end
                [bx, by] = boundary(ps);
                [bx, by] = games.PathUtils.filterGlowBoundary( ...
                    bx, by, obj.CorridorWidth);
                if ~isempty(obj.PathBandBgGlow) && isvalid(obj.PathBandBgGlow)
                    set(obj.PathBandBgGlow, "XData", bx, "YData", by);
                end
            catch
                % Polyshape failed — skip this frame's update
            end

            % Move sweep dot to current front
            if ~isempty(obj.PathPreviewDot) && isvalid(obj.PathPreviewDot)
                set(obj.PathPreviewDot, "XData", pathData.X(sweepIdx), ...
                    "YData", pathData.Y(sweepIdx));
            end
            if ~isempty(obj.PathPreviewGlow) && isvalid(obj.PathPreviewGlow)
                set(obj.PathPreviewGlow, "XData", pathData.X(sweepIdx), ...
                    "YData", pathData.Y(sweepIdx));
            end

            % Preview complete — hide dots, enter approach
            if obj.PreviewFrames <= 0
                if ~isempty(obj.PathPreviewDot) && isvalid(obj.PathPreviewDot)
                    obj.PathPreviewDot.Visible = "off";
                end
                if ~isempty(obj.PathPreviewGlow) && isvalid(obj.PathPreviewGlow)
                    obj.PathPreviewGlow.Visible = "off";
                end
                obj.enterApproach();
            end
        end

        function enterApproach(obj)
            %enterApproach  Show start beacon — user must reach path start.
            obj.TracingPhase = "approach";
            pathData = obj.CurrentPath;

            % Timer starts now (after shape is fully drawn)
            obj.PathSpawnTic = tic;
            obj.showTimeBar();

            % Position start beacon at path start (cyan color for approach)
            obj.TargetPos = [pathData.X(1), pathData.Y(1)];
            obj.TargetRadius = obj.CorridorWidth;
            obj.TargetTimeout = obj.PathTimeLimit;
            obj.PulsePhase = 0;
            if ~isempty(obj.TargetRingOuter) && isvalid(obj.TargetRingOuter)
                obj.TargetRingOuter.Color = [obj.ColorCyan, 0.6];
            end
            if ~isempty(obj.TargetGlow) && isvalid(obj.TargetGlow)
                obj.TargetGlow.Color = [obj.ColorCyan, 0.15];
            end
            obj.showTarget();

            % Show trail line to guide finger to start
            if ~isempty(obj.TrailLine) && isvalid(obj.TrailLine)
                obj.TrailLine.Visible = "on";
            end

            % Direction arrow at path start pointing along first segment
            lookAhead = min(15, numel(pathData.X) - 1);
            qdx = pathData.X(1 + lookAhead) - pathData.X(1);
            qdy = pathData.Y(1 + lookAhead) - pathData.Y(1);
            if ~isempty(obj.DirectionArrow) && isvalid(obj.DirectionArrow)
                delete(obj.DirectionArrow);
            end
            obj.DirectionArrow = quiver(obj.Ax, pathData.X(1), pathData.Y(1), ...
                qdx, qdy, 0, ...
                "Color", obj.ColorGreen, "LineWidth", 2.5, ...
                "MaxHeadSize", 2, "Visible", "on", "Tag", "GT_tracing");

            % Hide preview handles
            if ~isempty(obj.PathPreviewGlow) && isvalid(obj.PathPreviewGlow)
                obj.PathPreviewGlow.Visible = "off";
            end
            if ~isempty(obj.PathPreviewDot) && isvalid(obj.PathPreviewDot)
                obj.PathPreviewDot.Visible = "off";
            end
        end

        function updateApproach(obj, fingerPos)
            %updateApproach  Animate start beacon and check finger proximity.
            elapsed = toc(obj.PathSpawnTic);
            obj.updateTimeBar(elapsed / obj.PathTimeLimit);

            % Breathing animation on start beacon
            obj.PulsePhase = obj.PulsePhase + 0.15;
            obj.animateTarget(elapsed, fingerPos);

            % Check timeout — skipped path
            if elapsed > obj.PathTimeLimit
                obj.hideTarget();
                obj.onPathTimeout();
                return
            end

            if any(isnan(fingerPos)); return; end

            % Check if finger reached start point (within corridor width)
            pathData = obj.CurrentPath;
            distToStart = hypot(fingerPos(1) - pathData.X(1), ...
                fingerPos(2) - pathData.Y(1));
            if distToStart <= obj.CorridorWidth
                obj.hideTarget();
                obj.enterTracing();
            end
        end

        function enterTracing(obj)
            %enterTracing  Begin active tracing — reset accumulators.
            obj.TracingPhase = "tracing";
            obj.TracingProgressIdx = 1;

            % Hide preview handles
            if ~isempty(obj.PathPreviewGlow) && isvalid(obj.PathPreviewGlow)
                obj.PathPreviewGlow.Visible = "off";
            end
            if ~isempty(obj.PathPreviewDot) && isvalid(obj.PathPreviewDot)
                obj.PathPreviewDot.Visible = "off";
            end

            obj.TracingDeviationSum = 0;
            obj.TracingDeviationMax = 0;
            obj.TracingFrameCount = 0;
            obj.TracingOnPathCount = 0;
            obj.TracingActualDist = 0;
            obj.TracingPrevFingerPos = [NaN, NaN];
            obj.TracingDevBufIdx = 0;
            obj.TracingDevBuf = zeros(1, 5000);

            % Show zone circle and whisker
            if ~isempty(obj.ZoneCircle) && isvalid(obj.ZoneCircle)
                obj.ZoneCircle.Visible = "on";
            end
            if ~isempty(obj.DeviationWhisker) && isvalid(obj.DeviationWhisker)
                obj.DeviationWhisker.Visible = "on";
            end

            % Recreate traced band as Faces/Vertices patch
            ax = obj.Ax;
            if ~isempty(obj.PathBandTraced) && isvalid(obj.PathBandTraced)
                delete(obj.PathBandTraced);
            end
            obj.PathBandTraced = patch(ax, "Faces", 1, "Vertices", [0 0], ...
                "FaceColor", [0.15, 1, 0.35], "FaceAlpha", 0.85, ...
                "EdgeColor", "none", "Visible", "on", "Tag", "GT_tracing");
            uistack(obj.PathBandTraced, "bottom");
            uistack(obj.PathBandTraced, "up", 2);  % above image + bg band

            % Show traced glow (start empty)
            if ~isempty(obj.PathBandTracedGlow) && isvalid(obj.PathBandTracedGlow)
                set(obj.PathBandTracedGlow, "XData", NaN, "YData", NaN, ...
                    "Color", [obj.ColorGreen, 0.7], "Visible", "on");
            end

            % Show progress target at path start (green)
            pathData = obj.CurrentPath;
            obj.TargetPos = [pathData.X(1), pathData.Y(1)];
            obj.TargetRadius = obj.CorridorWidth;
            obj.PulsePhase = 0;
            if ~isempty(obj.TargetRingOuter) && isvalid(obj.TargetRingOuter)
                obj.TargetRingOuter.Color = [obj.ColorGreen, 0.6];
            end
            if ~isempty(obj.TargetGlow) && isvalid(obj.TargetGlow)
                obj.TargetGlow.Color = [obj.ColorGreen, 0.15];
            end
            obj.showTarget();
        end

        function updateTracing(obj, fingerPos)
            %updateTracing  Core per-frame tracing logic (directional, forward-only).
            if any(isnan(fingerPos))
                elapsed = toc(obj.PathSpawnTic);
                obj.updateTimeBar(elapsed / obj.PathTimeLimit);
                if elapsed > obj.PathTimeLimit
                    obj.onPathComplete();
                end
                return
            end

            pathData = obj.CurrentPath;
            nPts = numel(pathData.X);
            halfCorridor = obj.CorridorWidth / 2;
            progIdx = obj.TracingProgressIdx;

            % 1a. Full path check — never lose while inside corridor
            allDists = hypot(pathData.X - fingerPos(1), ...
                             pathData.Y - fingerPos(2));
            deviation = min(allDists);

            % 1b. Local search for progress advancement (GestureTrainer original)
            searchStart = max(1, progIdx - 5);
            searchEnd = min(nPts, progIdx + 80);
            searchRange = searchStart:searchEnd;
            localDists = hypot(pathData.X(searchRange) - fingerPos(1), ...
                               pathData.Y(searchRange) - fingerPos(2));
            [~, localMinIdx] = min(localDists);
            nearestIdx = searchRange(localMinIdx);

            % 2. Check corridor (15% tolerance)
            insideCorridor = deviation <= halfCorridor * 1.15;
            hasStarted = progIdx > 1;
            if ~insideCorridor
                if hasStarted
                    obj.hideTarget();
                    obj.onPathComplete();
                    return
                else
                    elapsed = toc(obj.PathSpawnTic);
                    obj.updateTimeBar(elapsed / obj.PathTimeLimit);
                    if elapsed > obj.PathTimeLimit
                        obj.onPathComplete();
                    end
                    return
                end
            end

            % 3. Advance progress toward nearest point (rate-limited, forward only)
            if nearestIdx > progIdx
                obj.TracingProgressIdx = min(nearestIdx, progIdx + 30);
            end

            % 3b. Move progress target to frontier
            frontIdx = obj.TracingProgressIdx;
            obj.TargetPos = [pathData.X(frontIdx), pathData.Y(frontIdx)];
            obj.PulsePhase = obj.PulsePhase + 0.12;
            theta = linspace(0, 2*pi, 48);
            ringR = obj.TargetRadius * (1 + 0.08 * sin(obj.PulsePhase));
            tcx = pathData.X(frontIdx);
            tcy = pathData.Y(frontIdx);
            if ~isempty(obj.TargetRingOuter) && isvalid(obj.TargetRingOuter)
                set(obj.TargetRingOuter, "XData", tcx + ringR * cos(theta), ...
                    "YData", tcy + ringR * sin(theta));
            end
            if ~isempty(obj.TargetGlow) && isvalid(obj.TargetGlow)
                set(obj.TargetGlow, "XData", tcx + ringR * cos(theta), ...
                    "YData", tcy + ringR * sin(theta));
            end
            if ~isempty(obj.TargetRingInner) && isvalid(obj.TargetRingInner)
                set(obj.TargetRingInner, "XData", tcx + ringR * 0.5 * cos(theta), ...
                    "YData", tcy + ringR * 0.5 * sin(theta));
            end
            if ~isempty(obj.TargetDot) && isvalid(obj.TargetDot)
                set(obj.TargetDot, "XData", tcx, "YData", tcy);
            end

            % 4. Accumulate stats
            obj.TracingFrameCount = obj.TracingFrameCount + 1;
            obj.TracingDeviationSum = obj.TracingDeviationSum + deviation;
            obj.TracingDeviationMax = max(obj.TracingDeviationMax, deviation);
            obj.TracingOnPathCount = obj.TracingOnPathCount + 1;

            % Accumulate finger travel distance
            if ~any(isnan(obj.TracingPrevFingerPos))
                obj.TracingActualDist = obj.TracingActualDist + ...
                    norm(fingerPos - obj.TracingPrevFingerPos);
            end
            obj.TracingPrevFingerPos = fingerPos;

            % 5. Store deviation for jitter calculation
            obj.TracingDevBufIdx = obj.TracingDevBufIdx + 1;
            if obj.TracingDevBufIdx <= numel(obj.TracingDevBuf)
                obj.TracingDevBuf(obj.TracingDevBufIdx) = deviation;
            end

            % 6. Update visuals
            progress = obj.TracingProgressIdx / nPts;
            obj.updateTracingVisuals(fingerPos, nearestIdx, deviation, progress);

            % 6b. Move arrow with progress target
            if ~isempty(obj.DirectionArrow) && isvalid(obj.DirectionArrow)
                lookAhead = min(nPts, frontIdx + 15);
                if lookAhead > frontIdx
                    adx = pathData.X(lookAhead) - pathData.X(frontIdx);
                    ady = pathData.Y(lookAhead) - pathData.Y(frontIdx);
                else
                    adx = 0; ady = 0;
                end
                set(obj.DirectionArrow, "XData", tcx, "YData", tcy, ...
                    "UData", adx, "VData", ady);
            end

            % 7. Update time bar
            elapsed = toc(obj.PathSpawnTic);
            obj.updateTimeBar(elapsed / obj.PathTimeLimit);

            % 8. Check completion (100% — full path traversal)
            if obj.TracingProgressIdx >= nPts
                obj.onPathComplete();
                return
            end

            % 9. Check timeout
            if elapsed > obj.PathTimeLimit
                obj.onPathComplete();
            end
        end

        function updateTracingVisuals(obj, fingerPos, nearestIdx, deviation, progress)
            %updateTracingVisuals  Per-frame visual updates with filled patch bands.
            pathData = obj.CurrentPath;
            halfCorridor = obj.CorridorWidth / 2;

            % Determine color based on how centered the finger is
            if deviation < halfCorridor * 0.3
                zoneColor = obj.ColorGreen;
            elseif deviation < halfCorridor * 0.6
                zoneColor = obj.ColorCyan;
            else
                zoneColor = obj.ColorGold;
            end

            % --- Traced band: from path start to current progress only ---
            progIdx = obj.TracingProgressIdx;
            segEnd = min(progIdx, numel(pathData.X));
            if segEnd >= 2
                try
                    tps = games.PathUtils.buildBandPolyshape( ...
                        pathData.X(1:segEnd), pathData.Y(1:segEnd), halfCorridor);
                    tT = triangulation(tps);
                    if ~isempty(obj.PathBandTraced) && isvalid(obj.PathBandTraced)
                        set(obj.PathBandTraced, "Faces", tT.ConnectivityList, ...
                            "Vertices", tT.Points, ...
                            "FaceAlpha", 0.75 + 0.15 * progress);
                    end
                    [tbx, tby] = boundary(tps);
                    [tbx, tby] = games.PathUtils.filterGlowBoundary( ...
                        tbx, tby, obj.CorridorWidth);
                    if ~isempty(obj.PathBandTracedGlow) && isvalid(obj.PathBandTracedGlow)
                        set(obj.PathBandTracedGlow, ...
                            "XData", tbx, "YData", tby);
                    end
                catch
                    % Skip update on polyshape failure
                end
            end

            % --- Deviation whisker ---
            if ~isempty(obj.DeviationWhisker) && isvalid(obj.DeviationWhisker)
                if deviation > 3
                    whiskerAlpha = min(0.35, deviation / halfCorridor * 0.3);
                    set(obj.DeviationWhisker, ...
                        "XData", [fingerPos(1), pathData.X(nearestIdx)], ...
                        "YData", [fingerPos(2), pathData.Y(nearestIdx)], ...
                        "Color", [zoneColor, whiskerAlpha], "Visible", "on");
                else
                    obj.DeviationWhisker.Visible = "off";
                end
            end

            % --- Zone circle around finger ---
            if ~isempty(obj.ZoneCircle) && isvalid(obj.ZoneCircle)
                theta = linspace(0, 2*pi, 32);
                set(obj.ZoneCircle, ...
                    "XData", fingerPos(1) + halfCorridor * cos(theta), ...
                    "YData", fingerPos(2) + halfCorridor * sin(theta), ...
                    "Color", [zoneColor, 0.10]);
            end
        end

        function onPathComplete(obj)
            %onPathComplete  Score the completed path.
            pathData = obj.CurrentPath;
            elapsed = toc(obj.PathSpawnTic);
            progress = obj.TracingProgressIdx / numel(pathData.X);
            halfCorridor = obj.CorridorWidth / 2;

            % Compute metrics
            avgDev = 0;
            if obj.TracingOnPathCount > 0
                avgDev = obj.TracingDeviationSum / obj.TracingOnPathCount;
            end
            maxDev = obj.TracingDeviationMax;

            % Jitter: std of deviation derivative
            jitter = 0;
            if obj.TracingDevBufIdx > 2
                devSignal = obj.TracingDevBuf(1:obj.TracingDevBufIdx);
                devDeriv = diff(devSignal);
                jitter = std(devDeriv, "omitnan");
            end

            % Path efficiency
            idealLen = pathData.TotalLen * progress;
            pathEff = 1;
            if obj.TracingActualDist > 0 && idealLen > 0
                pathEff = idealLen / obj.TracingActualDist;
            end

            deviationRatio = avgDev / max(halfCorridor, 1);

            % Scoring: complete = baseScore x comboMult, incomplete = 0
            isComplete = progress >= 1.0;
            if isComplete
                obj.incrementCombo();
                obj.PathsCompleted = obj.PathsCompleted + 1;

                tierScores = [100, 150, 200, 300];
                baseScore = tierScores(min(pathData.Difficulty, 4));
                comboMult = obj.Combo * 0.1;
                totalPoints = round(baseScore * comboMult);
            else
                obj.resetCombo();
                obj.PathsFailed = obj.PathsFailed + 1;
                totalPoints = 0;
            end
            obj.addScore(totalPoints);

            % Record path history
            entry.type = pathData.Type;
            entry.difficulty = pathData.Difficulty;
            entry.completion = progress;
            entry.avgDeviation = avgDev;
            entry.maxDeviation = maxDev;
            entry.jitter = jitter;
            entry.elapsed = elapsed;
            entry.timeLimit = obj.PathTimeLimit;
            entry.corridorWidth = obj.CorridorWidth;
            entry.score = totalPoints;
            entry.deviationRatio = deviationRatio;
            entry.actualPathLen = obj.TracingActualDist;
            entry.idealPathLen = idealLen;
            entry.pathEfficiency = pathEff;
            obj.PathHistory(end + 1) = entry;

            obj.enterScored(totalPoints, progress);
        end

        function onPathTimeout(obj)
            %onPathTimeout  Handle approach timeout — path skipped.
            obj.resetCombo();
            obj.PathsFailed = obj.PathsFailed + 1;

            % Record as failed path
            pathData = obj.CurrentPath;
            entry.type = pathData.Type;
            entry.difficulty = pathData.Difficulty;
            entry.completion = 0;
            entry.avgDeviation = NaN;
            entry.maxDeviation = NaN;
            entry.jitter = NaN;
            entry.elapsed = obj.PathTimeLimit;
            entry.timeLimit = obj.PathTimeLimit;
            entry.corridorWidth = obj.CorridorWidth;
            entry.score = 0;
            entry.deviationRatio = NaN;
            entry.actualPathLen = 0;
            entry.idealPathLen = pathData.TotalLen;
            entry.pathEfficiency = 0;
            obj.PathHistory(end + 1) = entry;

            obj.enterScored(0, 0);
        end

        function enterScored(obj, points, completion)
            %enterScored  Show score animation for tracing.
            obj.TracingPhase = "scored";
            obj.ScoredFrames = 18;  % ~0.4s fast display
            obj.hideTimeBar();

            % Hide tracing-only visuals
            if ~isempty(obj.ZoneCircle) && isvalid(obj.ZoneCircle)
                obj.ZoneCircle.Visible = "off";
            end
            if ~isempty(obj.DeviationWhisker) && isvalid(obj.DeviationWhisker)
                obj.DeviationWhisker.Visible = "off";
            end

            pathData = obj.CurrentPath;
            isSuccess = completion >= 1.0;
            obj.ScoredIsSuccess = isSuccess;

            % Hide arrow immediately (quiver doesn't support alpha fade)
            if ~isempty(obj.DirectionArrow) && isvalid(obj.DirectionArrow)
                delete(obj.DirectionArrow);
                obj.DirectionArrow = [];
            end

            obj.hideTarget();
            frontIdx = max(1, obj.TracingProgressIdx);
            effectPt = [pathData.X(frontIdx), pathData.Y(frontIdx)];
            if isSuccess
                obj.spawnHitEffect(effectPt, obj.ColorGreen, points);
            else
                obj.spawnHitEffect(effectPt, obj.ColorRed, 0);
            end

            % Snap traced band to full path on completion (satisfying finish)
            if isSuccess
                halfCorridor = obj.CorridorWidth / 2;
                try
                    fps = games.PathUtils.buildBandPolyshape( ...
                        pathData.X, pathData.Y, halfCorridor);
                    fT = triangulation(fps);
                    if ~isempty(obj.PathBandTraced) && isvalid(obj.PathBandTraced)
                        set(obj.PathBandTraced, "Faces", fT.ConnectivityList, ...
                            "Vertices", fT.Points);
                    end
                    [fbx, fby] = boundary(fps);
                    [fbx, fby] = games.PathUtils.filterGlowBoundary( ...
                        fbx, fby, obj.CorridorWidth);
                    if ~isempty(obj.PathBandTracedGlow) && isvalid(obj.PathBandTracedGlow)
                        set(obj.PathBandTracedGlow, "XData", fbx, "YData", fby);
                    end
                catch
                    % Keep current traced band on failure
                end
            end

            % Set flash color based on success
            if isSuccess
                flashColor = obj.ColorGreen;
            else
                flashColor = [1, 1, 1];
            end
            obj.ScoredFlashColor = flashColor;
            if ~isempty(obj.PathBandTracedGlow) && isvalid(obj.PathBandTracedGlow)
                obj.PathBandTracedGlow.Color = [flashColor, 0.85];
            end
            if ~isempty(obj.PathBandTraced) && isvalid(obj.PathBandTraced)
                obj.PathBandTraced.FaceColor = flashColor;
                obj.PathBandTraced.FaceAlpha = 1;
            end
            % On success, also flash the bg band green
            if isSuccess
                if ~isempty(obj.PathBandBg) && isvalid(obj.PathBandBg)
                    obj.PathBandBg.FaceColor = flashColor;
                    obj.PathBandBg.FaceAlpha = 0.6;
                end
                if ~isempty(obj.PathBandBgGlow) && isvalid(obj.PathBandBgGlow)
                    obj.PathBandBgGlow.Color = [flashColor, 0.7];
                end
            end

            % Store original vertices and glow outlines for expansion
            if isSuccess
                obj.ScoredCentroid = [mean(pathData.X), mean(pathData.Y)];
                if ~isempty(obj.PathBandTraced) && isvalid(obj.PathBandTraced)
                    obj.ScoredTracedVerts = obj.PathBandTraced.Vertices;
                end
                if ~isempty(obj.PathBandBg) && isvalid(obj.PathBandBg)
                    obj.ScoredBgVerts = obj.PathBandBg.Vertices;
                end
                if ~isempty(obj.PathBandTracedGlow) && isvalid(obj.PathBandTracedGlow)
                    obj.ScoredTracedGlowXY = { ...
                        obj.PathBandTracedGlow.XData, obj.PathBandTracedGlow.YData};
                end
                if ~isempty(obj.PathBandBgGlow) && isvalid(obj.PathBandBgGlow)
                    obj.ScoredBgGlowXY = { ...
                        obj.PathBandBgGlow.XData, obj.PathBandBgGlow.YData};
                end
            end
        end

        function updateScored(obj)
            %updateScored  Animate score display phase.
            obj.ScoredFrames = obj.ScoredFrames - 1;
            tProgress = 1 - obj.ScoredFrames / 18;

            % Fade all band layers + glows (quadratic for fast drop-off)
            fade = min(1, max(0, 1 - tProgress))^2;
            fc = obj.ScoredFlashColor;
            if obj.ScoredIsSuccess
                glowAlpha = 0.85 * fade;
                bandAlpha = fade;
                bgAlpha = 0.6 * fade;
                bgGlowAlpha = 0.7 * fade;
            else
                glowAlpha = 0.7 * fade;
                bandAlpha = fade;
                bgAlpha = 0.35 * fade;
                bgGlowAlpha = 0.5 * fade;
                fc = [1, 1, 1];
            end
            if ~isempty(obj.PathBandTracedGlow) && isvalid(obj.PathBandTracedGlow)
                obj.PathBandTracedGlow.Color = [fc, min(1, max(0, glowAlpha))];
            end
            if ~isempty(obj.PathBandTraced) && isvalid(obj.PathBandTraced)
                obj.PathBandTraced.FaceColor = fc;
                obj.PathBandTraced.FaceAlpha = min(1, max(0, bandAlpha));
            end
            if ~isempty(obj.PathBandBgGlow) && isvalid(obj.PathBandBgGlow)
                obj.PathBandBgGlow.Color = [fc, min(1, max(0, bgGlowAlpha))];
            end
            if ~isempty(obj.PathBandBg) && isvalid(obj.PathBandBg)
                obj.PathBandBg.FaceColor = fc;
                obj.PathBandBg.FaceAlpha = min(1, max(0, bgAlpha));
            end

            % Success: expand shape outward from centroid as it fades
            if obj.ScoredIsSuccess
                scaleFactor = 1 + tProgress * 0.4;  % expand up to 40%
                scx = obj.ScoredCentroid(1);
                scy = obj.ScoredCentroid(2);

                % Expand traced band vertices
                if ~isempty(obj.PathBandTraced) && isvalid(obj.PathBandTraced) ...
                        && ~isempty(obj.ScoredTracedVerts)
                    expanded = [scx; scy]' + (obj.ScoredTracedVerts - [scx, scy]) * scaleFactor;
                    obj.PathBandTraced.Vertices = expanded;
                end

                % Expand bg band vertices
                if ~isempty(obj.PathBandBg) && isvalid(obj.PathBandBg) ...
                        && ~isempty(obj.ScoredBgVerts)
                    expanded = [scx; scy]' + (obj.ScoredBgVerts - [scx, scy]) * scaleFactor;
                    obj.PathBandBg.Vertices = expanded;
                end

                % Expand traced glow outline
                if ~isempty(obj.PathBandTracedGlow) && isvalid(obj.PathBandTracedGlow) ...
                        && numel(obj.ScoredTracedGlowXY) == 2
                    ox = obj.ScoredTracedGlowXY{1};
                    oy = obj.ScoredTracedGlowXY{2};
                    set(obj.PathBandTracedGlow, ...
                        "XData", scx + (ox - scx) * scaleFactor, ...
                        "YData", scy + (oy - scy) * scaleFactor);
                end

                % Expand bg glow outline
                if ~isempty(obj.PathBandBgGlow) && isvalid(obj.PathBandBgGlow) ...
                        && numel(obj.ScoredBgGlowXY) == 2
                    ox = obj.ScoredBgGlowXY{1};
                    oy = obj.ScoredBgGlowXY{2};
                    set(obj.PathBandBgGlow, ...
                        "XData", scx + (ox - scx) * scaleFactor, ...
                        "YData", scy + (oy - scy) * scaleFactor);
                end
            end

            if obj.ScoredFrames <= 0
                obj.enterGap();
            end
        end

        function enterGap(obj)
            %enterGap  Clear previous path and immediately start next.
            obj.hideTracingGraphics();
            obj.spawnNextPath();
        end

        function updateGap(obj)
            %updateGap  Count down gap frames then spawn next path.
            obj.GapFrames = obj.GapFrames - 1;
            if obj.GapFrames <= 0
                obj.spawnNextPath();
            end
        end
    end

    % =================================================================
    % PRIVATE — GRAPHICS HELPERS
    % =================================================================
    methods (Access = private)

        function hideTracingGraphics(obj)
            %hideTracingGraphics  Hide all tracing overlay handles.
            handles = {obj.PathBandBgGlow, ...
                       obj.PathBandTracedGlow, obj.PathBandTraced, ...
                       obj.PathPreviewDot, obj.PathPreviewGlow, ...
                       obj.DeviationWhisker, obj.ZoneCircle};
            % Delete quiver arrow if present
            if ~isempty(obj.DirectionArrow) && isvalid(obj.DirectionArrow)
                delete(obj.DirectionArrow);
                obj.DirectionArrow = [];
            end
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    h.Visible = "off";
                end
            end

            % Delete the Faces/Vertices bg patch (a fresh one is created
            % in enterPreview for the next sweep animation)
            if ~isempty(obj.PathBandBg) && isvalid(obj.PathBandBg)
                delete(obj.PathBandBg);
                obj.PathBandBg = [];
            end
        end

        function showTarget(obj)
            %showTarget  Make target visible at current TargetPos.
            if any(isnan(obj.TargetPos)); return; end
            theta = linspace(0, 2*pi, 48);
            ringR = obj.TargetRadius;
            tcx = obj.TargetPos(1);
            tcy = obj.TargetPos(2);

            xOuter = tcx + ringR * cos(theta);
            yOuter = tcy + ringR * sin(theta);
            xInner = tcx + ringR * 0.5 * cos(theta);
            yInner = tcy + ringR * 0.5 * sin(theta);

            if ~isempty(obj.TargetGlow) && isvalid(obj.TargetGlow)
                set(obj.TargetGlow, "XData", xOuter, "YData", yOuter, "Visible", "on");
            end
            if ~isempty(obj.TargetRingOuter) && isvalid(obj.TargetRingOuter)
                set(obj.TargetRingOuter, "XData", xOuter, "YData", yOuter, "Visible", "on");
            end
            if ~isempty(obj.TargetRingInner) && isvalid(obj.TargetRingInner)
                set(obj.TargetRingInner, "XData", xInner, "YData", yInner, "Visible", "on");
            end
            if ~isempty(obj.TargetDot) && isvalid(obj.TargetDot)
                set(obj.TargetDot, "XData", tcx, "YData", tcy, "Visible", "on");
            end
        end

        function hideTarget(obj)
            %hideTarget  Hide all target graphics.
            handles = {obj.TargetGlow, obj.TargetRingOuter, ...
                       obj.TargetRingInner, obj.TargetDot, obj.TrailLine};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    h.Visible = "off";
                end
            end
        end

        function animateTarget(obj, elapsed, fingerPos)
            %animateTarget  Per-frame target animation (breathing + color).
            if any(isnan(obj.TargetPos)); return; end
            theta = linspace(0, 2*pi, 48);
            ringR = obj.TargetRadius;
            tcx = obj.TargetPos(1);
            tcy = obj.TargetPos(2);

            % Breathing: radius oscillates +/-12%
            breathe = 1 + 0.12 * sin(obj.PulsePhase);
            rOuter = ringR * breathe;
            rInner = ringR * 0.5 * breathe;

            xOuter = tcx + rOuter * cos(theta);
            yOuter = tcy + rOuter * sin(theta);
            xInner = tcx + rInner * cos(theta);
            yInner = tcy + rInner * sin(theta);

            if ~isempty(obj.TargetRingOuter) && isvalid(obj.TargetRingOuter)
                set(obj.TargetRingOuter, "XData", xOuter, "YData", yOuter);
            end
            if ~isempty(obj.TargetGlow) && isvalid(obj.TargetGlow)
                set(obj.TargetGlow, "XData", xOuter, "YData", yOuter);
            end
            if ~isempty(obj.TargetRingInner) && isvalid(obj.TargetRingInner)
                set(obj.TargetRingInner, "XData", xInner, "YData", yInner);
            end

            % Color shift: cyan -> red as timeout approaches
            urgency = min(1, elapsed / obj.TargetTimeout);
            if urgency < 0.6
                ringColor = obj.ColorCyan;
            else
                blendT = min(1, (urgency - 0.6) / 0.4);
                ringColor = obj.ColorCyan * (1 - blendT) + obj.ColorRed * blendT;
            end
            if ~isempty(obj.TargetRingOuter) && isvalid(obj.TargetRingOuter)
                obj.TargetRingOuter.Color = [ringColor, 0.7 + 0.3 * sin(obj.PulsePhase)];
            end
            if ~isempty(obj.TargetGlow) && isvalid(obj.TargetGlow)
                obj.TargetGlow.Color = [ringColor, 0.1 + 0.08 * sin(obj.PulsePhase)];
            end

            % Ghost trail from finger to target
            if ~any(isnan(fingerPos)) && ~isempty(obj.TrailLine) && isvalid(obj.TrailLine)
                obj.TrailLine.XData = [fingerPos(1), tcx];
                obj.TrailLine.YData = [fingerPos(2), tcy];
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

        function hideTimeBar(obj)
            %hideTimeBar  Hide the timeout progress bar.
            if ~isempty(obj.TimeBarBg) && isvalid(obj.TimeBarBg)
                obj.TimeBarBg.Visible = "off";
            end
            if ~isempty(obj.TimeBarFg) && isvalid(obj.TimeBarFg)
                obj.TimeBarFg.Visible = "off";
            end
        end

        function updateTimeBar(obj, fraction)
            %updateTimeBar  Update time bar fill (0=full, 1=empty).
            if isempty(obj.TimeBarFg) || ~isvalid(obj.TimeBarFg); return; end
            dxR = obj.DisplayRange.X;
            dyR = obj.DisplayRange.Y;
            barY = dyR(2) - 8;
            barH = 4;
            remaining = 1 - fraction;
            xEnd = dxR(1) + remaining * (dxR(2) - dxR(1));
            obj.TimeBarFg.XData = [dxR(1) xEnd xEnd dxR(1)];
            obj.TimeBarFg.YData = [barY barY barY+barH barY+barH];

            % Color: cyan -> yellow -> red
            if fraction < 0.5
                barColor = obj.ColorCyan;
            elseif fraction < 0.8
                blendT = (fraction - 0.5) / 0.3;
                barColor = obj.ColorCyan * (1 - blendT) + obj.ColorGold * blendT;
            else
                blendT = (fraction - 0.8) / 0.2;
                barColor = obj.ColorGold * (1 - blendT) + obj.ColorRed * blendT;
            end
            obj.TimeBarFg.FaceColor = barColor;
        end
    end
end
