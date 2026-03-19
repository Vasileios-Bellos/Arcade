classdef GlyphTracing < GameBase
    %GlyphTracing  Letter/number tracing game with fill coverage and recognition.
    %   Font-rendered letter shapes are displayed as cyan polyshapes. The
    %   player traces the letter with their finger (or mouse). A polybuffer
    %   around the finger path is intersected with the letter polyshape to
    %   grow a green fill. Completion requires BOTH ~90% fill coverage AND
    %   character recognition match (when hosted with GestureMouse caps).
    %
    %   Standalone: games.GlyphTracing().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost, GestureMouse

    properties (Constant)
        Name = "Glyph Tracing"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Character sequence and progress
        Sequence        (1,:) char                          % characters to trace (A-Z, 0-9)
        SeqIndex        (1,1) double = 0                    % current index into Sequence
        CurrentChar     (1,1) char = 'A'                    % character being traced

        % Letter geometry
        PathX           (1,:) double                        % NaN-separated contour X
        PathY           (1,:) double                        % NaN-separated contour Y
        LetterPs                                            % letter polyshape (intersection + area)
        LetterArea      (1,1) double = 0                    % area of letter polyshape
        FilledPs                                            % accumulated fill polyshape (grows)
        RecentX         (1,:) double                        % recent finger positions X (flushed)
        RecentY         (1,:) double                        % recent finger positions Y
        FillWidth       (1,1) double = 8                    % polybuffer width (px)
        FillUpdateCD    (1,1) double = 0                    % frame counter for periodic updates
        Coverage        (1,1) double = 0                    % current fill coverage %

        % Recognition
        Recognized      (1,1) logical = false               % recognition matched target
        TimeLimit       (1,1) double = 12                   % seconds per letter
        SpawnTic        uint64                              % tic at letter spawn
        ModeStartTic    uint64                              % tic at mode start

        % Completion tracking
        LettersCompleted (1,1) double = 0
        LettersFailed   (1,1) double = 0
        LetterHistory   struct = struct("char", {}, "elapsed", {}, "completed", {})

        % Phase machine
        Phase           (1,1) string = "active"             % active|scored|gap
        ScoredFrames    (1,1) double = 0
        GapFrames       (1,1) double = 0

        % Scored phase animation
        ScoredCentroid  (1,2) double = [0, 0]
        ScoredBgVerts   (:,2) double = zeros(0, 2)
        ScoredFillVerts (:,2) double = zeros(0, 2)
        ScoredGlowXY    = {}
        ScoredIsSuccess (1,1) logical = false

        % Combo decay
        LastComboTic    uint64

        % Host capabilities
        GlyphCache      struct = struct()                   % glyph cache (from host or built locally)
        RecognitionCB   function_handle = function_handle.empty  % saved host callback
        ResetRecogFcn   function_handle = function_handle.empty  % host resetRecognitionState()
        TextDetectFcn   function_handle = function_handle.empty  % enable/disable text detection
        SavedRecogMode  (1,1) string = "mixed"              % saved RecognitionMode
        HasHostRecog    (1,1) logical = false                % host provides recognition
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BandBgH                     % patch  -- filled glyph background (cyan)
        BandBgGlowH                 % line   -- contour outline glow (cyan)
        TracedFillH                 % patch  -- green fill (grows with finger)
        ProgressTextH               % text   -- progress indicator (N/36)
        TimeBarBg                   % patch  -- time bar background
        TimeBarFg                   % patch  -- time bar foreground
        ComboTextH                  % text   -- combo display
        ComboFadeTic    uint64
        ComboFadeColor  (1,3) double = [0.2, 1, 0.4]
        ComboShowTic    uint64
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
            obj.ShowHostCombo = false;

            % --- Obtain glyph cache from host or build locally ---
            if isfield(caps, "glyphCache") && ~isempty(caps.glyphCache)
                obj.GlyphCache = caps.glyphCache;
            elseif exist("GestureMouse", "class")
                obj.GlyphCache = GestureMouse.buildGlyphCache();
            else
                obj.GlyphCache = struct();
            end

            % --- Hook into host recognition if available ---
            obj.HasHostRecog = false;
            if isfield(caps, "setRecognitionCallback") ...
                    && isfield(caps, "resetRecognitionState") ...
                    && isfield(caps, "setTextDetection")
                obj.HasHostRecog = true;
                obj.RecognitionCB = caps.setRecognitionCallback;
                obj.ResetRecogFcn = caps.resetRecognitionState;
                obj.TextDetectFcn = caps.setTextDetection;

                % Enable text detection + set callback
                obj.TextDetectFcn(true);
                if isfield(caps, "getRecognitionMode")
                    obj.SavedRecogMode = caps.getRecognitionMode();
                end
                if isfield(caps, "setRecognitionMode")
                    caps.setRecognitionMode("mixed");
                end
                obj.RecognitionCB(@(ch) obj.onCharRecognized(ch));
            end

            % --- State ---
            obj.Sequence = [char('A':'Z'), char('0':'9')];
            obj.SeqIndex = 0;
            obj.LettersCompleted = 0;
            obj.LettersFailed = 0;
            obj.LetterHistory = struct("char", {}, "elapsed", {}, "completed", {});
            obj.ModeStartTic = tic;
            obj.Phase = "active";
            obj.Recognized = false;
            obj.Coverage = 0;
            obj.FilledPs = polyshape();
            obj.RecentX = [];
            obj.RecentY = [];
            obj.FillUpdateCD = 0;
            obj.LastComboTic = [];
            obj.ComboFadeTic = [];
            obj.ComboShowTic = [];

            dx = displayRange.X;
            dy = displayRange.Y;

            % --- Graphics (created once, updated per-letter) ---
            obj.BandBgH = [];
            obj.TracedFillH = [];
            obj.BandBgGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.4], "LineWidth", 2, ...
                "Tag", "GT_glyphtracing");
            obj.ProgressTextH = text(ax, 0, 0, "", ...
                "Color", obj.ColorWhite * 0.7, "FontSize", 12, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "top", "Visible", "off", ...
                "Tag", "GT_glyphtracing");

            % --- Time bar ---
            barW = (dx(2) - dx(1)) * 0.6;
            barH = 5;
            barX = mean(dx) - barW / 2;
            barY = dy(2) - 12;
            obj.TimeBarBg = patch(ax, ...
                [barX, barX + barW, barX + barW, barX], ...
                [barY, barY, barY + barH, barY + barH], ...
                [0.3 0.3 0.3], "FaceAlpha", 0.3, "EdgeColor", "none", ...
                "Visible", "off", "Tag", "GT_glyphtracing");
            obj.TimeBarFg = patch(ax, ...
                [barX, barX + barW, barX + barW, barX], ...
                [barY, barY, barY + barH, barY + barH], ...
                obj.ColorCyan, "FaceAlpha", 0.7, "EdgeColor", "none", ...
                "Visible", "off", "Tag", "GT_glyphtracing");

            % Combo text (pre-allocated, hidden until needed)
            obj.ComboTextH = text(ax, 0, 0, "", ...
                "Color", obj.ColorGold * 0.8, "FontSize", 13, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "top", "Visible", "off", "Tag", "GT_glyphtracing");

            obj.showTimeBar();
            obj.spawnNextLetter();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame glyph tracing logic.
            switch obj.Phase
                case "active"
                    obj.updateActive(pos);
                case "scored"
                    obj.updateScored();
                case "gap"
                    obj.updateGap();
            end

            % Combo fade animation
            obj.updateComboFade();
        end

        function onCleanup(obj)
            %onCleanup  Delete all graphics, restore host state.
            handles = {obj.BandBgH, obj.BandBgGlowH, obj.TracedFillH, ...
                obj.ProgressTextH, obj.TimeBarBg, obj.TimeBarFg, ...
                obj.ComboTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.BandBgH = [];
            obj.BandBgGlowH = [];
            obj.TracedFillH = [];
            obj.ProgressTextH = [];
            obj.TimeBarBg = [];
            obj.TimeBarFg = [];
            obj.ComboTextH = [];

            % Restore host recognition state
            if obj.HasHostRecog
                try
                    obj.RecognitionCB(function_handle.empty);
                    obj.TextDetectFcn(false);
                catch
                end
            end

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_glyphtracing");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for glyph trace.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return glyph trace results.
            r.Title = "GLYPH TRACE";
            nTotal = obj.LettersCompleted + obj.LettersFailed;
            accuracy = 0;
            if nTotal > 0
                accuracy = obj.LettersCompleted / nTotal * 100;
            end
            r.Lines = {
                sprintf("Characters: %d/%d (%.0f%%)", ...
                    obj.LettersCompleted, numel(obj.Sequence), accuracy)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        % ----- Phase updates -----------------------------------------

        function updateActive(obj, fingerPos)
            %updateActive  Per-frame active tracing with proximity fill.
            elapsed = toc(obj.SpawnTic);
            timeLeft = obj.TimeLimit - elapsed;

            if timeLeft > 0
                obj.updateTimeBarFraction(timeLeft / obj.TimeLimit);
            end

            % Timeout check
            if timeLeft <= 0
                if obj.Coverage >= 90 && obj.Recognized
                    obj.onSuccess(elapsed);
                else
                    obj.onFail(elapsed);
                end
                return;
            end

            % Accumulate finger positions
            if ~any(isnan(fingerPos))
                obj.RecentX(end + 1) = fingerPos(1);
                obj.RecentY(end + 1) = fingerPos(2);
            end

            % Every 3 frames: polybuffer recent path, union with fill
            obj.FillUpdateCD = obj.FillUpdateCD + obj.DtScale;
            if obj.FillUpdateCD >= 7 && numel(obj.RecentX) >= 2
                obj.FillUpdateCD = 0;
                obj.updateProximityFill();
            end

            % Combo text auto-hide after 1s
            if ~isempty(obj.LastComboTic)
                comboAge = toc(obj.LastComboTic);
                if comboAge > 1.0
                    obj.LastComboTic = [];
                    if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                        obj.ComboFadeTic = tic;
                        obj.ComboFadeColor = obj.ColorGreen * 0.9;
                    end
                end
            end

            % Check completion: both conditions met
            if obj.Coverage >= 90 && obj.Recognized
                obj.onSuccess(elapsed);
            end

            % In standalone mode (no host recognition), auto-recognize
            % when coverage reaches 95% so the game is still completable.
            if ~obj.HasHostRecog && obj.Coverage >= 95
                obj.Recognized = true;
                if obj.Coverage >= 90
                    obj.onSuccess(elapsed);
                end
            end
        end

        function updateScored(obj)
            %updateScored  Animate scored phase (fade + expand).
            obj.ScoredFrames = obj.ScoredFrames - obj.DtScale;
            t = 1 - obj.ScoredFrames / 48;  % 0 -> 1

            % Fade all elements (quadratic for fast drop-off)
            fade = max(0, 1 - t)^2;
            if obj.ScoredIsSuccess
                fc = obj.ColorGreen;
                glowAlpha = 0.7 * fade;
                fillAlpha = 0.7 * fade;
                bgAlpha = 0.2 * fade;
            else
                fc = [1, 1, 1];  % white flash on fail
                glowAlpha = 0.5 * fade;
                fillAlpha = 0.5 * fade;
                bgAlpha = 0.15 * fade;
            end

            if ~isempty(obj.BandBgGlowH) && isvalid(obj.BandBgGlowH)
                obj.BandBgGlowH.Color = [fc, glowAlpha];
            end
            if ~isempty(obj.TracedFillH) && isvalid(obj.TracedFillH)
                obj.TracedFillH.FaceColor = fc;
                obj.TracedFillH.FaceAlpha = fillAlpha;
            end
            if ~isempty(obj.BandBgH) && isvalid(obj.BandBgH)
                obj.BandBgH.FaceColor = fc;
                obj.BandBgH.FaceAlpha = bgAlpha;
            end

            % Success: expand shape outward from centroid
            if obj.ScoredIsSuccess
                scaleFactor = 1 + t * 0.4;  % expand up to 40%
                cx = obj.ScoredCentroid(1);
                cy = obj.ScoredCentroid(2);

                if ~isempty(obj.BandBgH) && isvalid(obj.BandBgH) ...
                        && ~isempty(obj.ScoredBgVerts)
                    expanded = [cx; cy]' + (obj.ScoredBgVerts - [cx, cy]) * scaleFactor;
                    obj.BandBgH.Vertices = expanded;
                end
                if ~isempty(obj.TracedFillH) && isvalid(obj.TracedFillH) ...
                        && ~isempty(obj.ScoredFillVerts)
                    expanded = [cx; cy]' + (obj.ScoredFillVerts - [cx, cy]) * scaleFactor;
                    obj.TracedFillH.Vertices = expanded;
                end
                if ~isempty(obj.BandBgGlowH) && isvalid(obj.BandBgGlowH) ...
                        && numel(obj.ScoredGlowXY) == 2
                    ox = obj.ScoredGlowXY{1};
                    oy = obj.ScoredGlowXY{2};
                    set(obj.BandBgGlowH, ...
                        "XData", cx + (ox - cx) * scaleFactor, ...
                        "YData", cy + (oy - cy) * scaleFactor);
                end
            end

            if obj.ScoredFrames <= 0
                obj.Phase = "gap";
                obj.GapFrames = 36;
            end
        end

        function updateGap(obj)
            %updateGap  Wait between letters.
            obj.GapFrames = obj.GapFrames - obj.DtScale;
            if obj.GapFrames <= 0
                obj.spawnNextLetter();
            end
        end

        % ----- Letter spawning ---------------------------------------

        function spawnNextLetter(obj)
            %spawnNextLetter  Display next letter as filled cyan shape.
            obj.SeqIndex = obj.SeqIndex + 1;
            if obj.SeqIndex > numel(obj.Sequence)
                obj.IsRunning = false;
                return;
            end

            ch = obj.Sequence(obj.SeqIndex);
            obj.CurrentChar = ch;
            chStr = upper(string(ch));
            if chStr >= "0" && chStr <= "9"
                glyphKey = "D" + chStr;
            else
                glyphKey = chStr;
            end
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            ax = obj.Ax;

            % Get glyph contour from cache
            if isfield(obj.GlyphCache, glyphKey)
                glyphData = obj.GlyphCache.(glyphKey);
                fullX = glyphData.x(:)';
                fullY = glyphData.y(:)';
            else
                theta = linspace(0, 2 * pi, 50);
                fullX = 0.5 + 0.4 * cos(theta);
                fullY = 0.5 + 0.4 * sin(theta);
            end

            % Scale to ~60% of display area, centered
            mx = mean(fullX, "omitnan");
            my = mean(fullY, "omitnan");
            fullX = fullX - mx;
            fullY = fullY - my;
            rangeX = max(fullX, [], "omitnan") - min(fullX, [], "omitnan");
            rangeY = max(fullY, [], "omitnan") - min(fullY, [], "omitnan");
            scaleFactor = min(diff(dx) * 0.60 / max(rangeX, 0.01), ...
                              diff(dy) * 0.60 / max(rangeY, 0.01));
            fullX = fullX * scaleFactor + mean(dx);
            fullY = fullY * scaleFactor + mean(dy);

            % Build polyshape and store
            obj.PathX = fullX;
            obj.PathY = fullY;
            if exist("GestureMouse", "class")
                obj.LetterPs = GestureMouse.buildPolyFromNaN(fullX, fullY);
            else
                obj.LetterPs = polyshape();
            end
            obj.LetterArea = area(obj.LetterPs);

            % Compute fill width from stroke width: 2*area/perimeter
            letterPerim = perimeter(obj.LetterPs);
            if letterPerim > 0
                obj.FillWidth = min(30, max(10, 2.0 * obj.LetterArea / letterPerim));
            else
                obj.FillWidth = 15;
            end

            obj.FilledPs = polyshape();
            obj.RecentX = [];
            obj.RecentY = [];
            obj.FillUpdateCD = 0;
            obj.Coverage = 0;
            obj.Recognized = false;
            obj.SpawnTic = tic;
            obj.Phase = "active";

            % Timer shortens with combo (12s base, -0.5s per combo, min 5s)
            obj.TimeLimit = max(5, 12 - obj.Combo * 0.5);

            % --- Cyan background: filled letter ---
            if ~isempty(obj.BandBgH) && isvalid(obj.BandBgH)
                delete(obj.BandBgH);
            end
            bgT = triangulation(obj.LetterPs);
            obj.BandBgH = patch(ax, "Faces", bgT.ConnectivityList, ...
                "Vertices", bgT.Points, "FaceColor", obj.ColorCyan, ...
                "FaceAlpha", 0.20, "EdgeColor", "none", "Tag", "GT_glyphtracing");
            uistack(obj.BandBgH, "bottom");
            uistack(obj.BandBgH, "up");

            % --- Green fill (empty, grows via polybuffer) ---
            if ~isempty(obj.TracedFillH) && isvalid(obj.TracedFillH)
                delete(obj.TracedFillH);
            end
            obj.TracedFillH = patch(ax, "Faces", 1, "Vertices", [0 0], ...
                "FaceColor", obj.ColorGreen, "FaceAlpha", 0.65, ...
                "EdgeColor", "none", "Visible", "off", "Tag", "GT_glyphtracing");
            uistack(obj.TracedFillH, "bottom");
            uistack(obj.TracedFillH, "up", 2);

            % --- Cyan outline glow ---
            if ~isempty(obj.BandBgGlowH) && isvalid(obj.BandBgGlowH)
                set(obj.BandBgGlowH, "XData", fullX, "YData", fullY, ...
                    "Color", [obj.ColorCyan, 0.4], "Visible", "on");
            end

            % --- Progress indicator ---
            if ~isempty(obj.ProgressTextH) && isvalid(obj.ProgressTextH)
                obj.ProgressTextH.String = sprintf("%d / %d", ...
                    obj.SeqIndex, numel(obj.Sequence));
                obj.ProgressTextH.Position = [dx(2) - 30, dy(1) + 25, 0];
                obj.ProgressTextH.Visible = "on";
            end

            % Clear host recognition state for fresh detection
            if obj.HasHostRecog && ~isempty(obj.ResetRecogFcn)
                try
                    obj.ResetRecogFcn();
                catch
                end
            end

            obj.showTimeBar();
        end

        % ----- Proximity fill ----------------------------------------

        function updateProximityFill(obj)
            %updateProximityFill  Polybuffer finger path, intersect with letter.
            w = warning("off", "MATLAB:polyshape:repairedBySimplify");
            try
                pathPts = [obj.RecentX(:), obj.RecentY(:)];
                newBuf = polybuffer(pathPts, "lines", obj.FillWidth);

                if newBuf.NumRegions > 0
                    clipped = intersect(newBuf, obj.LetterPs);
                    if clipped.NumRegions > 0
                        obj.FilledPs = union(obj.FilledPs, clipped);
                    end
                end
            catch
                % Skip on polybuffer/intersect failure
            end
            warning(w);

            % Clear recent buffer (keep last point for continuity)
            if numel(obj.RecentX) > 1
                obj.RecentX = obj.RecentX(end);
                obj.RecentY = obj.RecentY(end);
            end

            % Update coverage
            if obj.LetterArea > 0
                obj.Coverage = area(obj.FilledPs) / obj.LetterArea * 100;
            end

            % Render fill as Faces/Vertices
            if obj.FilledPs.NumRegions > 0
                try
                    triObj = triangulation(obj.FilledPs);
                    set(obj.TracedFillH, "Faces", triObj.ConnectivityList, ...
                        "Vertices", triObj.Points, "Visible", "on");
                catch
                    % Skip on triangulation failure
                end
            end
        end

        % ----- Success / Fail ----------------------------------------

        function onSuccess(obj, elapsed)
            %onSuccess  Handle successful letter trace.
            obj.LettersCompleted = obj.LettersCompleted + 1;
            obj.incrementCombo();

            letterPoints = round(100 * max(1, obj.Combo * 0.5));
            obj.addScore(letterPoints);

            obj.LetterHistory(end + 1) = struct("char", obj.CurrentChar, ...
                "elapsed", elapsed, "completed", true);

            % Flash full letter green
            if ~isempty(obj.TracedFillH) && isvalid(obj.TracedFillH) ...
                    && ~isempty(obj.LetterPs) && obj.LetterPs.NumRegions > 0
                try
                    triObj = triangulation(obj.LetterPs);
                    set(obj.TracedFillH, "Faces", triObj.ConnectivityList, ...
                        "Vertices", triObj.Points, "FaceAlpha", 0.7, ...
                        "Visible", "on");
                catch
                end
            end

            % Store vertices for expansion animation
            obj.ScoredCentroid = [mean(obj.PathX, "omitnan"), ...
                mean(obj.PathY, "omitnan")];
            obj.ScoredIsSuccess = true;
            if ~isempty(obj.BandBgH) && isvalid(obj.BandBgH)
                obj.ScoredBgVerts = obj.BandBgH.Vertices;
            end
            if ~isempty(obj.TracedFillH) && isvalid(obj.TracedFillH)
                obj.ScoredFillVerts = obj.TracedFillH.Vertices;
            end
            if ~isempty(obj.BandBgGlowH) && isvalid(obj.BandBgGlowH)
                obj.ScoredGlowXY = { ...
                    obj.BandBgGlowH.XData, obj.BandBgGlowH.YData};
            end

            % Flash bg green
            if ~isempty(obj.BandBgH) && isvalid(obj.BandBgH)
                obj.BandBgH.FaceColor = obj.ColorGreen;
                obj.BandBgH.FaceAlpha = 0.5;
            end
            if ~isempty(obj.BandBgGlowH) && isvalid(obj.BandBgGlowH)
                obj.BandBgGlowH.Color = [obj.ColorGreen, 0.7];
            end

            cx = obj.ScoredCentroid(1);
            cy = obj.ScoredCentroid(2);
            obj.spawnHitEffect([cx, cy], obj.ColorGreen, letterPoints, 25);
            if obj.Combo >= 2
                obj.showCombo([cx, cy - 30]);
                obj.LastComboTic = tic;
            end

            obj.hideTimeBar();
            obj.Phase = "scored";
            obj.ScoredFrames = 48;
        end

        function onFail(obj, elapsed)
            %onFail  Handle failed letter trace (timeout).
            obj.LettersFailed = obj.LettersFailed + 1;
            obj.resetCombo();

            obj.LetterHistory(end + 1) = struct("char", obj.CurrentChar, ...
                "elapsed", elapsed, "completed", false);

            % Store vertices for fade animation
            obj.ScoredCentroid = [mean(obj.PathX, "omitnan"), ...
                mean(obj.PathY, "omitnan")];
            obj.ScoredIsSuccess = false;
            if ~isempty(obj.BandBgH) && isvalid(obj.BandBgH)
                obj.ScoredBgVerts = obj.BandBgH.Vertices;
            end
            if ~isempty(obj.TracedFillH) && isvalid(obj.TracedFillH)
                obj.ScoredFillVerts = obj.TracedFillH.Vertices;
            end
            if ~isempty(obj.BandBgGlowH) && isvalid(obj.BandBgGlowH)
                obj.ScoredGlowXY = { ...
                    obj.BandBgGlowH.XData, obj.BandBgGlowH.YData};
            end

            cx = obj.ScoredCentroid(1);
            cy = obj.ScoredCentroid(2);
            obj.spawnHitEffect([cx, cy], obj.ColorRed, 0, 25);

            % Stay on same letter -- decrement so spawnNextLetter re-loads it
            obj.SeqIndex = obj.SeqIndex - 1;
            obj.hideTimeBar();
            obj.Phase = "scored";
            obj.ScoredFrames = 48;
        end

        % ----- Recognition callback -----------------------------------

        function onCharRecognized(obj, ch)
            %onCharRecognized  Callback from host recognition.
            if obj.Phase ~= "active"; return; end

            % Normalize confusables: O/0 and I/1 treated as same
            target = upper(string(obj.CurrentChar));
            recognized = upper(ch);
            if (target == "O" && recognized == "0") ...
                    || (target == "0" && recognized == "O")
                recognized = target;
            end
            if (target == "I" && recognized == "1") ...
                    || (target == "1" && recognized == "I")
                recognized = target;
            end

            if recognized == target
                obj.Recognized = true;
            else
                % Wrong letter: reset fill and recognition state
                obj.FilledPs = polyshape();
                obj.Coverage = 0;
                obj.RecentX = [];
                obj.RecentY = [];
                if ~isempty(obj.TracedFillH) && isvalid(obj.TracedFillH)
                    obj.TracedFillH.Visible = "off";
                end
                if obj.HasHostRecog && ~isempty(obj.ResetRecogFcn)
                    try
                        obj.ResetRecogFcn();
                    catch
                    end
                end
            end
        end

        % ----- Time bar -----------------------------------------------

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

        function updateTimeBarFraction(obj, frac)
            %updateTimeBarFraction  Set time bar fill (1=full, 0=empty).
            frac = max(0, min(1, frac));
            if isempty(obj.TimeBarFg) || ~isvalid(obj.TimeBarFg); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            barW = (dx(2) - dx(1)) * 0.6;
            barH = 5;
            barX = mean(dx) - barW / 2;
            barY = dy(2) - 12;
            fillW = barW * frac;
            obj.TimeBarFg.XData = [barX, barX + fillW, barX + fillW, barX];
            obj.TimeBarFg.YData = [barY, barY, barY + barH, barY + barH];

            % Color gradient: cyan (full) -> yellow -> red (empty)
            if frac > 0.5
                barColor = obj.ColorCyan;
            elseif frac > 0.2
                t = (frac - 0.2) / 0.3;
                barColor = obj.ColorGold * (1 - t) + obj.ColorCyan * t;
            else
                t = frac / 0.2;
                barColor = obj.ColorRed * (1 - t) + obj.ColorGold * t;
            end
            obj.TimeBarFg.FaceColor = barColor;
            obj.TimeBarFg.Visible = "on";

            if ~isempty(obj.TimeBarBg) && isvalid(obj.TimeBarBg)
                obj.TimeBarBg.Visible = "on";
            end
        end

        % ----- Combo display -------------------------------------------

        function showCombo(obj, hitPos)
            %showCombo  Show combo text briefly at hit location.
            if obj.Combo >= 2
                obj.ComboFadeTic = [];
                if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH); return; end
                obj.ComboTextH.String = sprintf("%dx Combo", obj.Combo);
                obj.ComboTextH.Color = obj.ColorGreen * 0.9;
                if ~any(isnan(hitPos))
                    obj.ComboTextH.Position = [hitPos(1), hitPos(2) + 12, 0];
                end
                obj.ComboTextH.Visible = "on";
                obj.ComboShowTic = tic;
            else
                if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                    obj.ComboFadeTic = tic;
                    obj.ComboFadeColor = obj.ColorGreen * 0.9;
                end
            end
        end

        function updateComboFade(obj)
            %updateComboFade  Animate combo text fade-out, delete when done.
            if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH)
                obj.ComboFadeTic = [];
                obj.ComboShowTic = [];
                return;
            end

            % Auto-trigger fade after 1s display
            if ~isempty(obj.ComboShowTic) && isempty(obj.ComboFadeTic)
                if toc(obj.ComboShowTic) >= 1.0
                    obj.ComboFadeTic = tic;
                    obj.ComboFadeColor = obj.ColorGreen * 0.9;
                    obj.ComboShowTic = [];
                end
            end

            % Animate fade-out
            if isempty(obj.ComboFadeTic); return; end
            elapsed = toc(obj.ComboFadeTic);
            fadeDur = 0.6;
            if elapsed >= fadeDur
                obj.ComboTextH.Visible = "off";
                obj.ComboFadeTic = [];
                return;
            end
            fadeAlpha = max(0, 1 - elapsed / fadeDur);
            obj.ComboTextH.Color = [obj.ComboFadeColor, fadeAlpha];
        end
    end
end
