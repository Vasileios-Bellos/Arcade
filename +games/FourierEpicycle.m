classdef FourierEpicycle < GameBase
    %FourierEpicycle  Draw shapes and watch DFT epicycles reconstruct them.
    %   Draw a closed shape with finger/mouse, then the DFT decomposes it
    %   into rotating circles that animate the reconstruction. 8 parametric
    %   presets (circle, triangle, square, etc.), 36 letter shapes from
    %   GlyphCache. Up/Down adjusts circle count, Left/Right adjusts speed.
    %
    %   Standalone: games.FourierEpicycle().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost, GestureMouse

    properties (Constant)
        Name = "Fourier Epicycle"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        SubMode         (1,1) string = "draw"       % draw|presets|letters
        State           (1,1) string = "waiting"     % waiting|animating|completing
        FrameCount      (1,1) double = 0

        % Drawing capture
        DrawX           (:,1) double                 % raw drawn path X
        DrawY           (:,1) double                 % raw drawn path Y
        DrawIdx         (1,1) double = 0             % current count
        MaxDrawPts      (1,1) double = 2000          % max capture points

        % DFT
        Coeffs          (:,1) double                 % DFT coefficients (complex)
        Freqs           (:,1) double                 % sorted frequency indices
        NumCircles      (1,1) double = 20            % active circle count
        MaxCircles      (1,1) double = 250           % maximum circle count
        MinCircles      (1,1) double = 1             % minimum circle count
        CircleStep      (1,1) double = 10            % step for up/down

        % Animation
        AnimT           (1,1) double = 0             % animation parameter [0, 2*pi)
        AnimSpeed       (1,1) double = 0.06          % radians per frame (fallback)
        TipSpeed        (1,1) double = 4             % target tip distance per frame (px)
        PathPerimeter   (1,1) double = 0             % total path length
        PathN           (1,1) double = 0             % FFT sample count (for open-path end)

        % Trace buffer
        TraceX          (:,1) double                 % reconstructed trace X
        TraceY          (:,1) double                 % reconstructed trace Y
        TraceIdx        (1,1) double = 0
        TraceMaxPts     (1,1) double = 1200          % trace buffer size

        % Pause/draw detection
        WasDrawing      (1,1) logical = false
        CloseDist       (1,1) double = 20            % auto-close detection radius
        PauseFrames     (1,1) double = 0
        PauseThresh     (1,1) double = 10            % frames of stillness to trigger
        PauseDispThresh (1,1) double = 18            % total displacement threshold (raised from 10 for finger jitter ~2px/frame)
        HasMoved        (1,1) logical = false
        DrawFrames      (1,1) double = 0             % frames since drawing started

        % Bridge (end-to-start closure)
        BridgeX         (:,1) double
        BridgeY         (:,1) double
        BridgeIdx       (1,1) double = 0

        % Completion effect
        CompletingFrames    (1,1) double = 0
        CompletingMax       (1,1) double = 25
        CompleteCentroid    (1,2) double = [0, 0]
        CompleteTraceX      (:,1) double
        CompleteTraceY      (:,1) double
        CompleteOrigX       (:,1) double
        CompleteOrigY       (:,1) double
        CompleteDrawX       (:,1) double
        CompleteDrawY       (:,1) double
        CompleteLetterVerts (:,2) double = zeros(0, 2)

        % Letters sub-mode
        LetterTarget    (1,1) string = ""
        LetterIdx       (1,1) double = 1
        TargetPathX     (:,1) double
        TargetPathY     (:,1) double

        % Presets sub-mode
        PresetIdx       (1,1) double = 1
        PresetShapes    (:,1) string = ["circle"; "triangle"; "square"; ...
                                        "rhombus"; "heart"; "figure8"]

        % Match % display
        MatchTextH
        MatchShowTic
        MatchFadeTic

        % Own trace buffer for standalone / non-GestureMouse hosts
        OwnTraceX       (:,1) double
        OwnTraceY       (:,1) double
        OwnTraceIdx     (1,1) double = 0
        OwnTraceMax     (1,1) double = 500

        % Host capabilities (function handles, empty if standalone)
        GetSmoothedTrace    function_handle
        GlyphCacheData      struct
        HasHostRecog        (1,1) logical = false
        SetRecognitionCB    function_handle
        ResetRecogFcn       function_handle
        SetTextDetect       function_handle
        SetRecogMode        function_handle
        SavedRecogMode      (1,1) string = ""
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BgImageH
        CirclesH
        RadiiH
        RadiiGlowH
        TraceH
        TraceGlowH
        OrigPathH
        OrigGlowH
        DrawLineH
        DotH
        DotGlowH
        ModeTextH
        PromptH
        LetterPatchH
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, caps)
            %onInit  Create Fourier epicycle drawing mode graphics.
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

            % --- Host capabilities ---
            if isfield(caps, "getSmoothedTrace")
                obj.GetSmoothedTrace = caps.getSmoothedTrace;
            else
                obj.GetSmoothedTrace = function_handle.empty;
            end

            % Glyph cache for letter shapes
            if isfield(caps, "glyphCache") && ~isempty(caps.glyphCache)
                obj.GlyphCacheData = caps.glyphCache;
            else
                obj.GlyphCacheData = GestureMouse.buildGlyphCache();
            end

            % Recognition hooks
            obj.HasHostRecog = false;
            if isfield(caps, "setRecognitionCallback") ...
                    && isfield(caps, "resetRecognitionState") ...
                    && isfield(caps, "setTextDetection")
                obj.HasHostRecog = true;
                obj.SetRecognitionCB = caps.setRecognitionCallback;
                obj.ResetRecogFcn = caps.resetRecognitionState;
                obj.SetTextDetect = caps.setTextDetection;
                if isfield(caps, "setRecognitionMode")
                    obj.SetRecogMode = caps.setRecognitionMode;
                end
                if isfield(caps, "getRecognitionMode")
                    obj.SavedRecogMode = caps.getRecognitionMode();
                end
            end

            % --- State ---
            obj.State = "waiting";
            obj.FrameCount = 0;
            obj.DrawX = NaN(obj.MaxDrawPts, 1);
            obj.DrawY = NaN(obj.MaxDrawPts, 1);
            obj.DrawIdx = 0;
            obj.Coeffs = [];
            obj.Freqs = [];
            obj.AnimT = 0;
            obj.TraceX = NaN(obj.TraceMaxPts, 1);
            obj.TraceY = NaN(obj.TraceMaxPts, 1);
            obj.TraceIdx = 0;
            obj.WasDrawing = false;
            obj.HasMoved = false;
            obj.PauseFrames = 0;
            obj.DrawFrames = 0;

            % Own trace buffer (for standalone mode)
            obj.OwnTraceX = NaN(obj.OwnTraceMax, 1);
            obj.OwnTraceY = NaN(obj.OwnTraceMax, 1);
            obj.OwnTraceIdx = 0;

            % --- Graphics ---
            obj.OrigGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.2], "LineWidth", 10, ...
                "Tag", "GT_fourier");
            obj.OrigPathH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.5], "LineWidth", 4, ...
                "Tag", "GT_fourier");
            obj.DrawLineH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.8], "LineWidth", 4, ...
                "Tag", "GT_fourier");
            obj.CirclesH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.4], "LineWidth", 1.6, ...
                "Tag", "GT_fourier");
            obj.RadiiGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorGold, 0.18], "LineWidth", 4, ...
                "Tag", "GT_fourier");
            obj.RadiiH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorGold, 0.65], "LineWidth", 1.5, ...
                "Tag", "GT_fourier");
            obj.TraceGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorGreen, 0.25], "LineWidth", 10, ...
                "Tag", "GT_fourier");
            obj.TraceH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorGreen, 0.9], "LineWidth", 3.6, ...
                "Tag", "GT_fourier");
            obj.DotGlowH = scatter(ax, NaN, NaN, 400, obj.ColorMagenta, ...
                "filled", "MarkerFaceAlpha", 0.25, "Tag", "GT_fourier");
            obj.DotH = scatter(ax, NaN, NaN, 80, obj.ColorMagenta, ...
                "filled", "MarkerFaceAlpha", 1.0, "Tag", "GT_fourier");

            % Mode text (bottom-left)
            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_fourier");

            % Draw prompt (center)
            cx = mean(dx);
            cy = mean(dy);
            obj.PromptH = text(ax, cx, cy, "DRAW A SHAPE", ...
                "Color", [obj.ColorCyan, 0.5], "FontSize", 20, ...
                "HorizontalAlignment", "center", "FontWeight", "bold", ...
                "Tag", "GT_fourier");

            % If presets or letters sub-mode, auto-load shape
            if obj.SubMode ~= "draw"
                obj.loadSubModeShape();
            end
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame Fourier epicycle update.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            obj.FrameCount = obj.FrameCount + 1;
            hasFinger = ~any(isnan(pos));

            % Update own trace buffer (for standalone mode)
            if hasFinger
                obj.OwnTraceIdx = min(obj.OwnTraceIdx + 1, obj.OwnTraceMax);
                if obj.OwnTraceIdx == obj.OwnTraceMax
                    obj.OwnTraceX(1:end-1) = obj.OwnTraceX(2:end);
                    obj.OwnTraceY(1:end-1) = obj.OwnTraceY(2:end);
                end
                obj.OwnTraceX(obj.OwnTraceIdx) = pos(1);
                obj.OwnTraceY(obj.OwnTraceIdx) = pos(2);
            end

            switch obj.State
                case "waiting"
                    obj.updateWaiting(pos, hasFinger);
                case "animating"
                    obj.updateAnimation();
                case "completing"
                    obj.updateCompletion();
            end

            obj.updateHitEffects();
            obj.updateMatchFade();
        end

        function onCleanup(obj)
            %onCleanup  Delete all Fourier epicycle graphics.
            % Disable letter recognition if it was active
            if obj.HasHostRecog
                obj.SetTextDetect(false);
                obj.SetRecognitionCB(function_handle.empty);
                if obj.SavedRecogMode ~= "" && ~isempty(obj.SetRecogMode)
                    obj.SetRecogMode(obj.SavedRecogMode);
                end
            end
            obj.LetterTarget = "";

            handles = {obj.BgImageH, obj.CirclesH, obj.RadiiH, ...
                obj.RadiiGlowH, obj.TraceH, obj.TraceGlowH, ...
                obj.OrigPathH, obj.OrigGlowH, obj.DrawLineH, ...
                obj.DotH, obj.DotGlowH, obj.ModeTextH, ...
                obj.MatchTextH, obj.PromptH, obj.LetterPatchH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_fourier");

            obj.BgImageH = [];
            obj.CirclesH = [];
            obj.RadiiH = [];
            obj.RadiiGlowH = [];
            obj.TraceH = [];
            obj.TraceGlowH = [];
            obj.OrigPathH = [];
            obj.OrigGlowH = [];
            obj.DrawLineH = [];
            obj.DotH = [];
            obj.DotGlowH = [];
            obj.ModeTextH = [];
            obj.MatchTextH = [];
            obj.MatchShowTic = [];
            obj.MatchFadeTic = [];
            obj.PromptH = [];
            obj.LetterPatchH = [];
            obj.TargetPathX = [];
            obj.TargetPathY = [];
            obj.Coeffs = [];
            obj.Freqs = [];
            obj.DrawX = [];
            obj.DrawY = [];
            obj.DrawIdx = 0;
            obj.TraceIdx = 0;
            obj.FrameCount = 0;
            obj.BridgeX = [];
            obj.BridgeY = [];
            obj.BridgeIdx = 0;
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle mode-specific keys.
            handled = true;
            switch key
                case "m"
                    modes = ["draw", "presets", "letters"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();
                case "n"
                    obj.nextShape();
                case {"uparrow", "downarrow"}
                    obj.changeCircleCount(key);
                case {"leftarrow", "rightarrow"}
                    obj.changeSpeed(key);
                case "0"
                    obj.nextShape();
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return Fourier-specific results.
            r.Title = "FOURIER EPICYCLE";
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            r.Lines = {
                sprintf("%s  |  Score: %d  |  Max Combo: %d  |  Time: %.1fs", ...
                    upper(obj.SubMode), obj.Score, obj.MaxCombo, elapsed)
            };
        end

        function s = getHudText(obj)
            %getHudText  Return HUD string for display.
            s = obj.buildHudString();
        end
    end

    % =================================================================
    % PRIVATE — STATE MACHINE
    % =================================================================
    methods (Access = private)

        function updateWaiting(obj, ~, hasFinger)
            %updateWaiting  Handle drawing/waiting state.

            % Breathing prompt animation
            if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                alpha = 0.3 + 0.2 * sin(obj.FrameCount * 0.08);
                rgb = obj.PromptH.Color(1:3);
                obj.PromptH.Color = [rgb, alpha];
            end

            % Get trace data
            [traceX, traceY] = obj.getTrace();
            nTrace = numel(traceX);

            if hasFinger && nTrace >= 2
                % Total displacement over last PauseThresh points
                nCheck = min(obj.PauseThresh, nTrace);
                tail = nTrace - nCheck + 1 : nTrace;
                totalDisp = sum(sqrt( ...
                    diff(traceX(tail)).^2 + ...
                    diff(traceY(tail)).^2));

                if totalDisp < obj.PauseDispThresh
                    obj.PauseFrames = obj.PauseFrames + 1;
                else
                    obj.HasMoved = true;
                    obj.PauseFrames = 0;
                end

                % Show the trace tail as blue neon line
                if obj.HasMoved && ~isempty(obj.DrawLineH) ...
                        && isvalid(obj.DrawLineH)
                    obj.DrawFrames = obj.DrawFrames + 1;
                    nShow = min(obj.DrawFrames, nTrace);
                    if nShow >= 2
                        i1 = nTrace - nShow + 1;
                        obj.DrawLineH.XData = traceX(i1:nTrace);
                        obj.DrawLineH.YData = traceY(i1:nTrace);
                    end
                end

                % Pause detection (skip for letters — handled by recognition)
                if obj.HasMoved ...
                        && obj.PauseFrames >= obj.PauseThresh ...
                        && nTrace >= 10 ...
                        && obj.SubMode ~= "letters"
                    if obj.SubMode == "presets"
                        [shapeOk, matchPct] = obj.checkShapeMatch();
                        obj.showMatchPct(matchPct, ...
                            [traceX(end), traceY(end)]);
                        if ~shapeOk
                            % Shape mismatch — red flash, reset drawing
                            if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                                obj.PromptH.Color = [1, 0.2, 0.2, 0.8];
                            end
                            obj.HasMoved = false;
                            obj.DrawFrames = 0;
                            obj.PauseFrames = 0;
                            obj.resetCombo();
                            if ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                                obj.DrawLineH.XData = NaN;
                                obj.DrawLineH.YData = NaN;
                            end
                            return;
                        end
                    end
                    % Accept — snapshot and animate
                    nDrawn = min(obj.DrawFrames, nTrace);
                    nn = min(nDrawn, obj.MaxDrawPts);
                    obj.DrawX(1:nn) = traceX(nTrace - nn + 1 : nTrace);
                    obj.DrawY(1:nn) = traceY(nTrace - nn + 1 : nTrace);
                    obj.DrawIdx = nn;
                    if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                        obj.PromptH.Visible = "off";
                    end
                    % Score for presets
                    if obj.SubMode == "presets"
                        obj.incrementCombo();
                        pts = round(100 * obj.comboMultiplier());
                        obj.addScore(pts);
                        obj.spawnHitEffect( ...
                            [traceX(end), traceY(end)], ...
                            obj.ColorGreen, pts);
                    end
                    obj.startAnimation();
                    return;
                end
            else
                obj.PauseFrames = 0;
            end
        end

        function startAnimation(obj)
            %startAnimation  Compute DFT and begin epicycle animation.
            n = obj.DrawIdx;
            if n < 3
                obj.resetToWaiting();
                return;
            end

            % Close the path smoothly with a Hermite spline bridge
            pathX = obj.DrawX(1:n);
            pathY = obj.DrawY(1:n);
            nLetterPts = n;
            closeDist = sqrt((pathX(end) - pathX(1))^2 + ...
                (pathY(end) - pathY(1))^2);
            if closeDist > 0.5
                nTan = min(5, n - 1);
                m0x = pathX(end) - pathX(end - nTan);
                m0y = pathY(end) - pathY(end - nTan);
                m0Len = sqrt(m0x^2 + m0y^2);
                if m0Len > 0; m0x = m0x / m0Len; m0y = m0y / m0Len; end

                m1x = pathX(1 + nTan) - pathX(1);
                m1y = pathY(1 + nTan) - pathY(1);
                m1Len = sqrt(m1x^2 + m1y^2);
                if m1Len > 0; m1x = m1x / m1Len; m1y = m1y / m1Len; end

                m0x = m0x * closeDist * 0.5;
                m0y = m0y * closeDist * 0.5;
                m1x = m1x * closeDist * 0.5;
                m1y = m1y * closeDist * 0.5;

                nBridge = max(8, round(closeDist / 2));
                tB = linspace(0, 1, nBridge + 2)';
                tB = tB(2:end);
                h00 = 2*tB.^3 - 3*tB.^2 + 1;
                h10 = tB.^3 - 2*tB.^2 + tB;
                h01 = -2*tB.^3 + 3*tB.^2;
                h11 = tB.^3 - tB.^2;
                bridgeX = h00*pathX(end) + h10*m0x + h01*pathX(1) + h11*m1x;
                bridgeY = h00*pathY(end) + h10*m0y + h01*pathY(1) + h11*m1y;

                if obj.SubMode == "letters"
                    obj.BridgeX = [];
                    obj.BridgeY = [];
                    obj.BridgeIdx = 0;
                else
                    obj.BridgeX = bridgeX;
                    obj.BridgeY = bridgeY;
                    obj.BridgeIdx = 0;
                end

                pathX = [pathX; bridgeX];
                pathY = [pathY; bridgeY];
            else
                obj.BridgeX = [];
                obj.BridgeY = [];
                obj.BridgeIdx = 0;
            end
            nPts = numel(pathX);

            % Compute letter arc fraction before resampling
            preCumLen = [0; cumsum(sqrt(diff(pathX).^2 + diff(pathY).^2))];
            letterArcFrac = preCumLen(min(nLetterPts, numel(preCumLen))) / ...
                max(preCumLen(end), 1);

            % Resample to uniform spacing
            N = min(1024, max(128, nPts * 2));
            cumLen = preCumLen;
            [cumLen, uIdx] = unique(cumLen, "stable");
            pathX = pathX(uIdx);
            pathY = pathY(uIdx);
            totalLen = cumLen(end);
            if totalLen < 1
                obj.resetToWaiting();
                return;
            end
            uniformS = linspace(0, totalLen, N + 1)';
            uniformS = uniformS(1:N);
            pathX = interp1(cumLen, pathX, uniformS, "linear");
            pathY = interp1(cumLen, pathY, uniformS, "linear");

            % Smooth junction with circular padding
            smoothWin = max(5, round(N / 20));
            padLen = smoothWin;
            pxPad = [pathX(end - padLen + 1 : end); pathX; pathX(1:padLen)];
            pyPad = [pathY(end - padLen + 1 : end); pathY; pathY(1:padLen)];
            pxPad = smoothdata(pxPad, "gaussian", smoothWin);
            pyPad = smoothdata(pyPad, "gaussian", smoothWin);
            pathX = pxPad(padLen + 1 : end - padLen);
            pathY = pyPad(padLen + 1 : end - padLen);

            % Store path perimeter
            obj.PathPerimeter = sum(sqrt(diff([pathX; pathX(1)]).^2 + ...
                diff([pathY; pathY(1)]).^2));

            % Store N for animation end detection
            if obj.SubMode == "letters" && letterArcFrac < 0.99
                obj.PathN = round(N * letterArcFrac);
            else
                obj.PathN = N;
            end

            % Complex signal and DFT
            z = pathX + 1i * pathY;
            Z = fft(z) / N;

            % Frequency indices
            freqIdx = (0:N-1)';
            freqIdx(freqIdx > N/2) = freqIdx(freqIdx > N/2) - N;

            % Sort by magnitude (largest first)
            mags = abs(Z);
            [~, sortIdx] = sort(mags, "descend");
            obj.Coeffs = Z(sortIdx);
            obj.Freqs = freqIdx(sortIdx);

            % Cap circle count
            nRotAvail = sum(freqIdx ~= 0);
            obj.MaxCircles = nRotAvail;
            obj.NumCircles = min(obj.NumCircles, nRotAvail);

            % Reset animation state
            obj.AnimT = 0;
            obj.TraceX = NaN(obj.TraceMaxPts, 1);
            obj.TraceY = NaN(obj.TraceMaxPts, 1);
            obj.TraceIdx = 0;
            obj.State = "animating";

            % Update draw line and original path
            if obj.SubMode == "letters"
                nDisp = obj.PathN;
                dispX = pathX(1:nDisp);
                dispY = pathY(1:nDisp);
            else
                dispX = [pathX; pathX(1)];
                dispY = [pathY; pathY(1)];
            end
            if obj.SubMode == "draw"
                if ~isempty(obj.BridgeX)
                    rawX = obj.DrawX(1:obj.DrawIdx);
                    rawY = obj.DrawY(1:obj.DrawIdx);
                    if ~isempty(obj.OrigPathH) && isvalid(obj.OrigPathH)
                        obj.OrigPathH.XData = rawX;
                        obj.OrigPathH.YData = rawY;
                    end
                    if ~isempty(obj.OrigGlowH) && isvalid(obj.OrigGlowH)
                        obj.OrigGlowH.XData = rawX;
                        obj.OrigGlowH.YData = rawY;
                    end
                else
                    if ~isempty(obj.OrigPathH) && isvalid(obj.OrigPathH)
                        obj.OrigPathH.XData = dispX;
                        obj.OrigPathH.YData = dispY;
                    end
                    if ~isempty(obj.OrigGlowH) && isvalid(obj.OrigGlowH)
                        obj.OrigGlowH.XData = dispX;
                        obj.OrigGlowH.YData = dispY;
                    end
                end
            end
            if ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                if isempty(obj.BridgeX)
                    obj.DrawLineH.XData = dispX;
                    obj.DrawLineH.YData = dispY;
                else
                    obj.DrawLineH.XData = obj.DrawX(1:obj.DrawIdx);
                    obj.DrawLineH.YData = obj.DrawY(1:obj.DrawIdx);
                end
            end
            if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                obj.PromptH.Visible = "off";
            end

            obj.updateHud();
        end

        function updateAnimation(obj)
            %updateAnimation  Advance epicycle animation one frame.

            % Progressive bridge reveal
            nBr = numel(obj.BridgeX);
            if nBr > 0 && obj.BridgeIdx < nBr ...
                    && ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                oldIdx = obj.BridgeIdx;
                dist = 0;
                newIdx = oldIdx;
                while newIdx < nBr && dist < obj.TipSpeed
                    newIdx = newIdx + 1;
                    if newIdx > 1
                        dist = dist + sqrt( ...
                            (obj.BridgeX(newIdx) - obj.BridgeX(max(1, newIdx - 1)))^2 + ...
                            (obj.BridgeY(newIdx) - obj.BridgeY(max(1, newIdx - 1)))^2);
                    elseif oldIdx == 0
                        curX = obj.DrawLineH.XData(:);
                        curY = obj.DrawLineH.YData(:);
                        if ~isempty(curX) && ~isnan(curX(end))
                            dist = dist + sqrt( ...
                                (obj.BridgeX(1) - curX(end))^2 + ...
                                (obj.BridgeY(1) - curY(end))^2);
                        end
                    end
                end
                newIdx = max(newIdx, oldIdx + 1);
                curX = obj.DrawLineH.XData(:);
                curY = obj.DrawLineH.YData(:);
                appendX = obj.BridgeX(oldIdx + 1 : newIdx);
                appendY = obj.BridgeY(oldIdx + 1 : newIdx);
                obj.DrawLineH.XData = [curX; appendX];
                obj.DrawLineH.YData = [curY; appendY];
                if obj.SubMode ~= "presets"
                    if ~isempty(obj.OrigPathH) && isvalid(obj.OrigPathH)
                        obj.OrigPathH.XData = [obj.OrigPathH.XData(:); appendX];
                        obj.OrigPathH.YData = [obj.OrigPathH.YData(:); appendY];
                    end
                    if ~isempty(obj.OrigGlowH) && isvalid(obj.OrigGlowH)
                        obj.OrigGlowH.XData = [obj.OrigGlowH.XData(:); appendX];
                        obj.OrigGlowH.YData = [obj.OrigGlowH.YData(:); appendY];
                    end
                end
                obj.BridgeIdx = newIdx;
            end

            nCirc = min(obj.NumCircles, numel(obj.Coeffs));
            if nCirc < 1; return; end

            t = obj.AnimT;

            % Compute epicycle chain positions
            allCoeffs = obj.Coeffs;
            allFreqs = obj.Freqs;

            dcMask = (allFreqs == 0);
            dcVal = sum(allCoeffs(dcMask));
            rotCoeffs = allCoeffs(~dcMask);
            rotFreqs = allFreqs(~dcMask);
            nRot = min(nCirc, numel(rotCoeffs));

            centersX = zeros(nRot + 1, 1);
            centersY = zeros(nRot + 1, 1);

            epicyclePos = dcVal;
            centersX(1) = real(epicyclePos);
            centersY(1) = imag(epicyclePos);

            for k = 1:nRot
                epicyclePos = epicyclePos + rotCoeffs(k) * exp(1i * rotFreqs(k) * t);
                centersX(k + 1) = real(epicyclePos);
                centersY(k + 1) = imag(epicyclePos);
            end

            tipX = centersX(end);
            tipY = centersY(end);

            % Build circle geometry (NaN-separated)
            theta = linspace(0, 2*pi, 64)';
            circAllX = [];
            circAllY = [];
            radAllX = [];
            radAllY = [];

            for k = 1:nRot
                rad = abs(rotCoeffs(k));
                if rad < 0.3; continue; end
                cx = centersX(k);
                cy = centersY(k);
                circAllX = [circAllX; cx + rad * cos(theta); NaN]; %#ok<AGROW>
                circAllY = [circAllY; cy + rad * sin(theta); NaN]; %#ok<AGROW>
            end

            for k = 1:nRot
                radAllX = [radAllX; centersX(k); centersX(k + 1); NaN]; %#ok<AGROW>
                radAllY = [radAllY; centersY(k); centersY(k + 1); NaN]; %#ok<AGROW>
            end

            % Update circles and radii graphics
            if ~isempty(obj.CirclesH) && isvalid(obj.CirclesH)
                obj.CirclesH.XData = circAllX;
                obj.CirclesH.YData = circAllY;
            end
            if ~isempty(obj.RadiiH) && isvalid(obj.RadiiH)
                obj.RadiiH.XData = radAllX;
                obj.RadiiH.YData = radAllY;
            end
            if ~isempty(obj.RadiiGlowH) && isvalid(obj.RadiiGlowH)
                obj.RadiiGlowH.XData = radAllX;
                obj.RadiiGlowH.YData = radAllY;
            end

            % Update trace
            obj.TraceIdx = obj.TraceIdx + 1;
            if obj.TraceIdx > obj.TraceMaxPts
                obj.TraceIdx = obj.TraceMaxPts;
                obj.TraceX(1:end-1) = obj.TraceX(2:end);
                obj.TraceY(1:end-1) = obj.TraceY(2:end);
            end
            obj.TraceX(obj.TraceIdx) = tipX;
            obj.TraceY(obj.TraceIdx) = tipY;

            tIdx = obj.TraceIdx;
            trX = obj.TraceX(1:tIdx);
            trY = obj.TraceY(1:tIdx);
            hue = mod(t / (2*pi), 1);
            rgb = hsv2rgb([hue, 0.9, 1.0]);
            if ~isempty(obj.TraceH) && isvalid(obj.TraceH)
                obj.TraceH.XData = trX;
                obj.TraceH.YData = trY;
                obj.TraceH.Color = [rgb, 0.9];
            end
            if ~isempty(obj.TraceGlowH) && isvalid(obj.TraceGlowH)
                obj.TraceGlowH.XData = trX;
                obj.TraceGlowH.YData = trY;
                obj.TraceGlowH.Color = [rgb, 0.25];
            end

            % Update tip dot
            if ~isempty(obj.DotH) && isvalid(obj.DotH)
                obj.DotH.XData = tipX;
                obj.DotH.YData = tipY;
                obj.DotH.CData = hsv2rgb([hue, 1.0, 1.0]);
            end
            if ~isempty(obj.DotGlowH) && isvalid(obj.DotGlowH)
                obj.DotGlowH.XData = tipX;
                obj.DotGlowH.YData = tipY;
                obj.DotGlowH.CData = hsv2rgb([hue, 1.0, 1.0]);
            end

            % Advance time (distance-based)
            dzdt = 0;
            for k = 1:nRot
                dzdt = dzdt + 1i * rotFreqs(k) * rotCoeffs(k) ...
                    * exp(1i * rotFreqs(k) * t);
            end
            tipVel = abs(dzdt);
            if tipVel > 0.1
                dt = obj.TipSpeed / tipVel;
            else
                dt = obj.AnimSpeed;
            end
            dt = min(dt, obj.AnimSpeed * 5);
            obj.AnimT = obj.AnimT + dt;

            % Score: increment per frame based on circle count
            if mod(obj.FrameCount, 30) == 0
                obj.addScore(nRot);
                obj.incrementCombo();
            end

            % Check for full rotation completion
            if obj.SubMode == "letters" && obj.PathN > 1
                Ntotal = numel(obj.Coeffs);
                tEnd = 2 * pi * obj.PathN / Ntotal;
            else
                tEnd = 2 * pi;
            end
            if obj.AnimT >= tEnd
                if obj.SubMode ~= "letters"
                    pos0 = dcVal;
                    for k = 1:nRot
                        pos0 = pos0 + rotCoeffs(k);
                    end
                    obj.TraceIdx = min(obj.TraceIdx + 1, obj.TraceMaxPts);
                    obj.TraceX(obj.TraceIdx) = real(pos0);
                    obj.TraceY(obj.TraceIdx) = imag(pos0);
                end
                trX = obj.TraceX(1:obj.TraceIdx);
                trY = obj.TraceY(1:obj.TraceIdx);
                if ~isempty(obj.TraceH) && isvalid(obj.TraceH)
                    obj.TraceH.XData = trX;
                    obj.TraceH.YData = trY;
                end
                if ~isempty(obj.TraceGlowH) && isvalid(obj.TraceGlowH)
                    obj.TraceGlowH.XData = trX;
                    obj.TraceGlowH.YData = trY;
                end
                obj.enterCompletion();
            end
        end

        function enterCompletion(obj)
            %enterCompletion  Begin expand+fade effect after animation finishes.
            obj.State = "completing";
            obj.CompletingFrames = obj.CompletingMax;

            tIdx = obj.TraceIdx;
            if tIdx > 0
                obj.CompleteTraceX = obj.TraceX(1:tIdx);
                obj.CompleteTraceY = obj.TraceY(1:tIdx);
                obj.CompleteCentroid = [mean(obj.CompleteTraceX, "omitnan"), ...
                    mean(obj.CompleteTraceY, "omitnan")];
            else
                obj.CompleteCentroid = [mean(obj.DisplayRange.X), ...
                    mean(obj.DisplayRange.Y)];
            end

            if ~isempty(obj.OrigPathH) && isvalid(obj.OrigPathH)
                obj.CompleteOrigX = obj.OrigPathH.XData(:);
                obj.CompleteOrigY = obj.OrigPathH.YData(:);
            end
            if ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                obj.CompleteDrawX = obj.DrawLineH.XData(:);
                obj.CompleteDrawY = obj.DrawLineH.YData(:);
            end

            if ~isempty(obj.LetterPatchH) && isvalid(obj.LetterPatchH)
                obj.CompleteLetterVerts = obj.LetterPatchH.Vertices;
            else
                obj.CompleteLetterVerts = zeros(0, 2);
            end

            % Flash green on presets/letters
            if obj.SubMode == "presets" || obj.SubMode == "letters"
                fc = [0.2, 1.0, 0.3];
                if ~isempty(obj.OrigPathH) && isvalid(obj.OrigPathH)
                    obj.OrigPathH.Color = [fc, 0.7];
                end
                if ~isempty(obj.OrigGlowH) && isvalid(obj.OrigGlowH)
                    obj.OrigGlowH.Color = [fc, 0.3];
                end
                if ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                    obj.DrawLineH.Color = [fc, 0.8];
                end
                if ~isempty(obj.LetterPatchH) && isvalid(obj.LetterPatchH)
                    obj.LetterPatchH.FaceColor = fc;
                    obj.LetterPatchH.FaceAlpha = 0.5;
                end
            end

            % Hide epicycle machinery
            mechH = {obj.CirclesH, obj.RadiiH, obj.RadiiGlowH};
            for k = 1:numel(mechH)
                h = mechH{k};
                if ~isempty(h) && isvalid(h)
                    h.XData = NaN; h.YData = NaN;
                end
            end
            scatH = {obj.DotH, obj.DotGlowH};
            for k = 1:numel(scatH)
                h = scatH{k};
                if ~isempty(h) && isvalid(h)
                    h.XData = NaN; h.YData = NaN;
                end
            end
        end

        function updateCompletion(obj)
            %updateCompletion  Per-frame expand+fade effect.
            obj.CompletingFrames = obj.CompletingFrames - 1;
            t = 1 - obj.CompletingFrames / obj.CompletingMax;
            fade = max(0, 1 - t)^2;
            scaleFactor = 1 + t * 0.4;
            cx = obj.CompleteCentroid(1);
            cy = obj.CompleteCentroid(2);

            % Expand + fade trace
            if ~isempty(obj.CompleteTraceX)
                expX = cx + (obj.CompleteTraceX - cx) * scaleFactor;
                expY = cy + (obj.CompleteTraceY - cy) * scaleFactor;
                hue = mod(obj.AnimT / (2*pi), 1);
                rgb = hsv2rgb([hue, 0.9, 1.0]);
                if ~isempty(obj.TraceH) && isvalid(obj.TraceH)
                    obj.TraceH.XData = expX;
                    obj.TraceH.YData = expY;
                    obj.TraceH.Color = [rgb, 0.9 * fade];
                end
                if ~isempty(obj.TraceGlowH) && isvalid(obj.TraceGlowH)
                    obj.TraceGlowH.XData = expX;
                    obj.TraceGlowH.YData = expY;
                    obj.TraceGlowH.Color = [rgb, 0.25 * fade];
                end
            end

            % Expand + fade original path
            if ~isempty(obj.CompleteOrigX)
                expX = cx + (obj.CompleteOrigX - cx) * scaleFactor;
                expY = cy + (obj.CompleteOrigY - cy) * scaleFactor;
                if ~isempty(obj.OrigPathH) && isvalid(obj.OrigPathH)
                    pathRgb = obj.OrigPathH.Color(1:3);
                    obj.OrigPathH.XData = expX;
                    obj.OrigPathH.YData = expY;
                    obj.OrigPathH.Color = [pathRgb, 0.7 * fade];
                end
                if ~isempty(obj.OrigGlowH) && isvalid(obj.OrigGlowH)
                    glowRgb = obj.OrigGlowH.Color(1:3);
                    obj.OrigGlowH.XData = expX;
                    obj.OrigGlowH.YData = expY;
                    obj.OrigGlowH.Color = [glowRgb, 0.3 * fade];
                end
            end

            % Expand + fade draw line
            if ~isempty(obj.CompleteDrawX)
                expX = cx + (obj.CompleteDrawX - cx) * scaleFactor;
                expY = cy + (obj.CompleteDrawY - cy) * scaleFactor;
                if ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                    obj.DrawLineH.XData = expX;
                    obj.DrawLineH.YData = expY;
                    obj.DrawLineH.Color = [obj.ColorCyan, 0.8 * fade];
                end
            end

            % Expand + fade filled letter patch
            if ~isempty(obj.LetterPatchH) && isvalid(obj.LetterPatchH) ...
                    && ~isempty(obj.CompleteLetterVerts)
                expanded = [cx, cy] + (obj.CompleteLetterVerts - [cx, cy]) * scaleFactor;
                obj.LetterPatchH.Vertices = expanded;
                obj.LetterPatchH.FaceAlpha = 0.5 * fade;
                obj.LetterPatchH.EdgeAlpha = 0.4 * fade;
            end

            % Done — advance to next or reset
            if obj.CompletingFrames <= 0
                if obj.SubMode == "presets"
                    obj.PresetIdx = mod(obj.PresetIdx, numel(obj.PresetShapes)) + 1;
                    obj.resetAndLoad();
                elseif obj.SubMode == "letters"
                    obj.LetterIdx = mod(obj.LetterIdx, 36) + 1;
                    obj.resetAndLoad();
                else
                    obj.resetToWaiting();
                end
            end
        end
    end

    % =================================================================
    % PRIVATE — SUB-MODES & SHAPE MANAGEMENT
    % =================================================================
    methods (Access = private)

        function applySubMode(obj)
            %applySubMode  Switch sub-mode and update display.
            if obj.HasHostRecog
                obj.SetTextDetect(false);
                obj.SetRecognitionCB(function_handle.empty);
            end
            obj.LetterTarget = "";
            obj.resetCombo();

            obj.HasMoved = false;
            obj.PauseFrames = 0;
            obj.DrawFrames = 0;
            obj.State = "waiting";
            obj.DrawIdx = 0;
            obj.TraceIdx = 0;
            obj.AnimT = 0;
            obj.TraceX = NaN(obj.TraceMaxPts, 1);
            obj.TraceY = NaN(obj.TraceMaxPts, 1);
            obj.Coeffs = [];
            obj.Freqs = [];

            % Clear graphics
            lineHandles = {obj.CirclesH, obj.RadiiH, obj.RadiiGlowH, ...
                obj.TraceH, obj.TraceGlowH, obj.OrigPathH, ...
                obj.OrigGlowH, obj.DrawLineH};
            for k = 1:numel(lineHandles)
                h = lineHandles{k};
                if ~isempty(h) && isvalid(h)
                    h.XData = NaN; h.YData = NaN;
                end
            end
            if ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                obj.DrawLineH.Color = [obj.ColorCyan, 0.8];
            end
            if ~isempty(obj.LetterPatchH) && isvalid(obj.LetterPatchH)
                delete(obj.LetterPatchH);
                obj.LetterPatchH = [];
            end
            obj.TargetPathX = [];
            obj.TargetPathY = [];
            scatHandles = {obj.DotH, obj.DotGlowH};
            for k = 1:numel(scatHandles)
                h = scatHandles{k};
                if ~isempty(h) && isvalid(h)
                    h.XData = NaN; h.YData = NaN;
                end
            end

            % Update prompt
            if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                cx = mean(obj.DisplayRange.X);
                cy = mean(obj.DisplayRange.Y);
                if obj.SubMode == "draw"
                    obj.PromptH.String = "DRAW A SHAPE";
                    obj.PromptH.FontSize = 20;
                    obj.PromptH.Color = [obj.ColorCyan, 0.5];
                    obj.PromptH.Position = [cx, cy, 0];
                    obj.PromptH.HorizontalAlignment = "center";
                    obj.PromptH.Visible = "on";
                else
                    obj.PromptH.Visible = "off";
                end
            end

            obj.updateHud();

            if obj.SubMode ~= "draw"
                obj.loadSubModeShape();
            end
        end

        function loadSubModeShape(obj)
            %loadSubModeShape  Load a shape for presets/letters sub-mode.
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cx = mean(dx);
            cy = mean(dy);
            scaleW = diff(dx) * 0.45;
            scaleH = diff(dy) * 0.45;
            scaleFactor = min(scaleW, scaleH);

            % Delete old letter patch
            if ~isempty(obj.LetterPatchH) && isvalid(obj.LetterPatchH)
                delete(obj.LetterPatchH);
                obj.LetterPatchH = [];
            end

            if obj.SubMode == "presets"
                shapeName = obj.PresetShapes(obj.PresetIdx);
                pts = games.FourierEpicycle.generatePreset(shapeName, 256);
                pathX = pts(:,1) * scaleFactor + cx;
                pathY = pts(:,2) * scaleFactor + cy;

                obj.TargetPathX = pathX;
                obj.TargetPathY = pathY;

                if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                    obj.PromptH.String = upper(shapeName);
                    obj.PromptH.FontSize = 16;
                    obj.PromptH.Color = [obj.ColorGold, 0.5];
                    obj.PromptH.Visible = "on";
                end

                dispX = [pathX(:); pathX(1)];
                dispY = [pathY(:); pathY(1)];
                if ~isempty(obj.OrigGlowH) && isvalid(obj.OrigGlowH)
                    obj.OrigGlowH.XData = dispX;
                    obj.OrigGlowH.YData = dispY;
                    obj.OrigGlowH.Color = [obj.ColorGold, 0.15];
                end
                if ~isempty(obj.OrigPathH) && isvalid(obj.OrigPathH)
                    obj.OrigPathH.XData = dispX;
                    obj.OrigPathH.YData = dispY;
                    obj.OrigPathH.Color = [obj.ColorGold, 0.35];
                end

            elseif obj.SubMode == "letters"
                chars = ['A':'Z', '0':'9'];
                idx = mod(obj.LetterIdx - 1, numel(chars)) + 1;
                ch = string(chars(idx));
                glyphKey = GestureMouse.glyphKey(ch);
                axH = obj.Ax;

                if ~isempty(obj.GlyphCacheData) && isfield(obj.GlyphCacheData, glyphKey)
                    glyphData = obj.GlyphCacheData.(glyphKey);
                    fullX = glyphData.x(:)';
                    fullY = glyphData.y(:)';
                else
                    theta = linspace(0, 2*pi, 50);
                    fullX = 0.5 + 0.4 * cos(theta);
                    fullY = 0.5 + 0.4 * sin(theta);
                end

                mx = mean(fullX, "omitnan");
                my = mean(fullY, "omitnan");
                fullX = fullX - mx;
                fullY = fullY - my;
                rangeX = max(fullX, [], "omitnan") - min(fullX, [], "omitnan");
                rangeY = max(fullY, [], "omitnan") - min(fullY, [], "omitnan");
                sf = min(diff(dx) * 0.60 / max(rangeX, 0.01), ...
                    diff(dy) * 0.60 / max(rangeY, 0.01));
                fullX = fullX * sf + cx;
                fullY = fullY * sf + cy;

                letterPs = GestureMouse.buildPolyFromNaN(fullX, fullY);
                if area(letterPs) > 0
                    bgT = triangulation(letterPs);
                    obj.LetterPatchH = patch(axH, ...
                        "Faces", bgT.ConnectivityList, ...
                        "Vertices", bgT.Points, ...
                        "FaceColor", obj.ColorGold, "FaceAlpha", 0.12, ...
                        "EdgeColor", "none", "Tag", "GT_fourier");
                    uistack(obj.LetterPatchH, "bottom");
                    uistack(obj.LetterPatchH, "up");
                end

                if ~isempty(obj.OrigGlowH) && isvalid(obj.OrigGlowH)
                    obj.OrigGlowH.XData = fullX;
                    obj.OrigGlowH.YData = fullY;
                    obj.OrigGlowH.Color = [obj.ColorGold, 0.15];
                end
                if ~isempty(obj.OrigPathH) && isvalid(obj.OrigPathH)
                    obj.OrigPathH.XData = fullX;
                    obj.OrigPathH.YData = fullY;
                    obj.OrigPathH.Color = [obj.ColorGold, 0.35];
                end

                if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                    obj.PromptH.String = sprintf("%s  (%d/36)", ch, idx);
                    obj.PromptH.FontSize = 14;
                    obj.PromptH.Color = [obj.ColorGold, 0.4];
                    obj.PromptH.HorizontalAlignment = "right";
                    obj.PromptH.Visible = "on";
                    obj.PromptH.Position = [dx(2) - 5, dy(1) + 25, 0];
                end

                % Enable character recognition for letter matching
                obj.LetterTarget = upper(ch);
                if obj.HasHostRecog
                    obj.SetTextDetect(true);
                    if ~isempty(obj.SetRecogMode)
                        obj.SetRecogMode("mixed");
                    end
                    obj.SetRecognitionCB(@(c) obj.onLetterRecognized(c));
                    obj.ResetRecogFcn();
                end
            end
        end

        function nextShape(obj)
            %nextShape  Cycle to next preset/letter shape.
            if obj.SubMode == "presets"
                obj.PresetIdx = mod(obj.PresetIdx, numel(obj.PresetShapes)) + 1;
                obj.resetAndLoad();
            elseif obj.SubMode == "letters"
                obj.LetterIdx = mod(obj.LetterIdx, 36) + 1;
                obj.resetAndLoad();
            elseif obj.SubMode == "draw"
                obj.resetToWaiting();
            end
        end

        function resetToWaiting(obj)
            %resetToWaiting  Return to waiting state for a new drawing.
            obj.State = "waiting";
            obj.DrawIdx = 0;
            obj.TraceIdx = 0;
            obj.AnimT = 0;
            obj.WasDrawing = false;
            obj.HasMoved = false;
            obj.PauseFrames = 0;
            obj.DrawFrames = 0;
            obj.BridgeX = [];
            obj.BridgeY = [];
            obj.BridgeIdx = 0;
            obj.TraceX = NaN(obj.TraceMaxPts, 1);
            obj.TraceY = NaN(obj.TraceMaxPts, 1);
            obj.Coeffs = [];
            obj.Freqs = [];

            lineH = {obj.CirclesH, obj.RadiiH, obj.RadiiGlowH, ...
                obj.TraceH, obj.TraceGlowH, obj.OrigPathH, ...
                obj.OrigGlowH, obj.DrawLineH};
            for k = 1:numel(lineH)
                h = lineH{k};
                if ~isempty(h) && isvalid(h)
                    h.XData = NaN; h.YData = NaN;
                end
            end
            if ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                obj.DrawLineH.Color = [obj.ColorCyan, 0.8];
            end
            if ~isempty(obj.LetterPatchH) && isvalid(obj.LetterPatchH)
                delete(obj.LetterPatchH);
                obj.LetterPatchH = [];
            end
            scatH = {obj.DotH, obj.DotGlowH};
            for k = 1:numel(scatH)
                h = scatH{k};
                if ~isempty(h) && isvalid(h)
                    h.XData = NaN; h.YData = NaN;
                end
            end

            if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                cx = mean(obj.DisplayRange.X);
                cy = mean(obj.DisplayRange.Y);
                obj.PromptH.String = "DRAW A SHAPE";
                obj.PromptH.FontSize = 20;
                obj.PromptH.Color = [obj.ColorCyan, 0.5];
                obj.PromptH.HorizontalAlignment = "center";
                obj.PromptH.Position = [cx, cy, 0];
                obj.PromptH.Visible = "on";
            end
        end

        function resetAndLoad(obj)
            %resetAndLoad  Reset animation state and load new shape.
            obj.State = "waiting";
            obj.DrawIdx = 0;
            obj.TraceIdx = 0;
            obj.AnimT = 0;
            obj.HasMoved = false;
            obj.PauseFrames = 0;
            obj.DrawFrames = 0;
            obj.BridgeX = [];
            obj.BridgeY = [];
            obj.BridgeIdx = 0;
            obj.TraceX = NaN(obj.TraceMaxPts, 1);
            obj.TraceY = NaN(obj.TraceMaxPts, 1);
            obj.Coeffs = [];
            obj.Freqs = [];

            lineH = {obj.CirclesH, obj.RadiiH, obj.RadiiGlowH, ...
                obj.TraceH, obj.TraceGlowH, obj.OrigPathH, ...
                obj.OrigGlowH, obj.DrawLineH};
            for k = 1:numel(lineH)
                h = lineH{k};
                if ~isempty(h) && isvalid(h)
                    h.XData = NaN; h.YData = NaN;
                end
            end
            if ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                obj.DrawLineH.Color = [obj.ColorCyan, 0.8];
            end
            scatH = {obj.DotH, obj.DotGlowH};
            for k = 1:numel(scatH)
                h = scatH{k};
                if ~isempty(h) && isvalid(h)
                    h.XData = NaN; h.YData = NaN;
                end
            end
            obj.loadSubModeShape();
        end

        function changeCircleCount(obj, key)
            %changeCircleCount  Adjust number of circles via up/down arrows.
            old = obj.NumCircles;
            if key == "uparrow"
                obj.NumCircles = min(obj.MaxCircles, old + obj.CircleStep);
            else
                obj.NumCircles = max(obj.MinCircles, old - obj.CircleStep);
            end
            if obj.NumCircles ~= old
                obj.TraceIdx = 0;
                obj.TraceX = NaN(obj.TraceMaxPts, 1);
                obj.TraceY = NaN(obj.TraceMaxPts, 1);
                obj.AnimT = 0;
            end
            obj.updateHud();
        end

        function changeSpeed(obj, key)
            %changeSpeed  Adjust tip speed via left/right arrows.
            if key == "rightarrow"
                obj.TipSpeed = min(20, obj.TipSpeed * 1.3);
            else
                obj.TipSpeed = max(0.5, obj.TipSpeed / 1.3);
            end
            obj.updateHud();
        end
    end

    % =================================================================
    % PRIVATE — TRACE & RECOGNITION
    % =================================================================
    methods (Access = private)

        function [tx, ty] = getTrace(obj)
            %getTrace  Get smoothed trace from host or own buffer.
            if ~isempty(obj.GetSmoothedTrace)
                [tx, ty] = obj.GetSmoothedTrace();
            else
                nValid = obj.OwnTraceIdx;
                if nValid < 1
                    tx = zeros(0, 1);
                    ty = zeros(0, 1);
                else
                    tx = obj.OwnTraceX(1:nValid);
                    ty = obj.OwnTraceY(1:nValid);
                end
            end
        end

        function onLetterRecognized(obj, ch)
            %onLetterRecognized  Callback from host recognition system.
            if obj.State ~= "waiting"; return; end
            if ~obj.HasMoved; return; end

            target = obj.LetterTarget;
            recognized = upper(string(ch));

            % Normalize confusable pairs (O/0, I/1)
            if (target == "O" && recognized == "0") ...
                    || (target == "0" && recognized == "O")
                recognized = target;
            end
            if (target == "I" && recognized == "1") ...
                    || (target == "1" && recognized == "I")
                recognized = target;
            end

            if recognized == target
                [traceX, traceY] = obj.getTrace();
                nTrace = numel(traceX);
                if nTrace < 5; return; end

                nDrawn = min(obj.DrawFrames, nTrace);
                nn = min(nDrawn, obj.MaxDrawPts);
                if nn < 5; return; end

                obj.DrawX(1:nn) = traceX(nTrace - nn + 1 : nTrace);
                obj.DrawY(1:nn) = traceY(nTrace - nn + 1 : nTrace);
                obj.DrawIdx = nn;

                if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                    obj.PromptH.Visible = "off";
                end

                obj.incrementCombo();
                pts = round(100 * obj.comboMultiplier());
                obj.addScore(pts);
                obj.spawnHitEffect( ...
                    [traceX(end), traceY(end)], obj.ColorGreen, pts);

                if ~isempty(obj.TargetPathX)
                    [~, matchPct] = obj.checkShapeMatch();
                    obj.showMatchPct(matchPct, ...
                        [traceX(end), traceY(end) - 15]);
                end

                % Disable recognition during animation
                if obj.HasHostRecog
                    obj.SetTextDetect(false);
                    obj.SetRecognitionCB(function_handle.empty);
                end

                obj.startAnimation();
            else
                % Wrong letter — flash red, reset
                if ~isempty(obj.PromptH) && isvalid(obj.PromptH)
                    obj.PromptH.Color = [1, 0.2, 0.2, 0.8];
                end
                if obj.HasHostRecog
                    obj.ResetRecogFcn();
                end
                obj.HasMoved = false;
                obj.DrawFrames = 0;
                obj.PauseFrames = 0;
                if ~isempty(obj.DrawLineH) && isvalid(obj.DrawLineH)
                    obj.DrawLineH.XData = NaN;
                    obj.DrawLineH.YData = NaN;
                end
                obj.resetCombo();
            end
        end

        function [ok, pct] = checkShapeMatch(obj)
            %checkShapeMatch  Check if drawn trace matches stored target shape.
            [traceX, traceY] = obj.getTrace();
            nTrace = numel(traceX);
            nDrawn = min(obj.DrawFrames, nTrace);
            if nDrawn < 20; ok = false; pct = 0; return; end

            i1 = nTrace - nDrawn + 1;
            drawnX = traceX(i1:nTrace);
            drawnY = traceY(i1:nTrace);

            tgtX = obj.TargetPathX;
            tgtY = obj.TargetPathY;
            if isempty(tgtX); ok = false; pct = 0; return; end

            bbDiag = sqrt((max(tgtX) - min(tgtX))^2 + ...
                (max(tgtY) - min(tgtY))^2);
            maxDist = bbDiag * 0.15;

            fwdDists = sqrt(min((drawnX(:) - tgtX(:)').^2 + ...
                (drawnY(:) - tgtY(:)').^2, [], 2));
            fwdScore = mean(max(0, 1 - fwdDists / maxDist));

            revDists = sqrt(min((tgtX(:) - drawnX(:)').^2 + ...
                (tgtY(:) - drawnY(:)').^2, [], 2));
            revScore = mean(max(0, 1 - revDists / maxDist));

            pct = round(sqrt(fwdScore * revScore) * 100);
            ok = pct >= 70;
        end
    end

    % =================================================================
    % PRIVATE — HUD & MATCH DISPLAY
    % =================================================================
    methods (Access = private)

        function updateHud(obj)
            %updateHud  Update mode text.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

        function s = buildHudString(obj)
            %buildHudString  Build HUD string for Fourier mode.
            s = upper(obj.SubMode) + " [M]  |  Circles " + ...
                obj.NumCircles + " [" + char(8593) + char(8595) + ...
                "]  |  Speed " + sprintf("%.1f", obj.TipSpeed) + ...
                " [" + char(8592) + char(8594) + "]";
        end

        function showMatchPct(obj, pct, pos)
            %showMatchPct  Show match percentage as floating text.
            axH = obj.Ax;
            if isempty(obj.MatchTextH) || ~isvalid(obj.MatchTextH)
                obj.MatchTextH = text(axH, 0, 0, "", ...
                    "FontSize", 14, "FontWeight", "bold", ...
                    "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "bottom", "Tag", "GT_fourier");
            end
            if pct >= 70
                clr = obj.ColorGreen;
            elseif pct >= 50
                clr = obj.ColorGold;
            else
                clr = [1, 0.3, 0.2];
            end
            obj.MatchTextH.String = sprintf("%d%%", pct);
            obj.MatchTextH.Color = [clr, 1.0];
            obj.MatchTextH.Position = [pos(1), pos(2) - 10, 0];
            obj.MatchTextH.Visible = "on";
            obj.MatchShowTic = tic;
            obj.MatchFadeTic = [];
        end

        function updateMatchFade(obj)
            %updateMatchFade  Animate match % text fade-out.
            if isempty(obj.MatchTextH) || ~isvalid(obj.MatchTextH)
                return;
            end
            if obj.MatchTextH.Visible == "off"; return; end
            if ~isempty(obj.MatchShowTic) && isempty(obj.MatchFadeTic)
                if toc(obj.MatchShowTic) >= 1.0
                    obj.MatchFadeTic = tic;
                    obj.MatchShowTic = [];
                end
            end
            if isempty(obj.MatchFadeTic); return; end
            elapsed = toc(obj.MatchFadeTic);
            fadeDur = 0.6;
            if elapsed >= fadeDur
                obj.MatchTextH.Visible = "off";
                obj.MatchFadeTic = [];
            else
                alpha = max(0, 1 - elapsed / fadeDur);
                c = obj.MatchTextH.Color;
                obj.MatchTextH.Color = [c(1:3), alpha];
            end
        end
    end

    % =================================================================
    % STATIC — PRESET SHAPE GENERATION
    % =================================================================
    methods (Static, Access = private)

        function pts = generatePreset(shapeName, N)
            %generatePreset  Generate parametric shape with N points.
            %   Returns Nx2 matrix normalized to fit within [-0.5, 0.5].
            t = linspace(0, 2*pi, N + 1)';
            t = t(1:N);

            switch shapeName
                case "circle"
                    pts = [cos(t), sin(t)];
                case "triangle"
                    vx = cos([pi/2; pi/2 + 2*pi/3; pi/2 + 4*pi/3; pi/2]);
                    vy = sin([pi/2; pi/2 + 2*pi/3; pi/2 + 4*pi/3; pi/2]);
                    cumD = [0; cumsum(sqrt(diff(vx).^2 + diff(vy).^2))];
                    s = linspace(0, cumD(end), N + 1)';
                    s = s(1:N);
                    pts = [interp1(cumD, vx, s, "linear"), ...
                        interp1(cumD, vy, s, "linear")];
                case "square"
                    vx = [1; -1; -1; 1; 1];
                    vy = [1; 1; -1; -1; 1];
                    cumD = [0; cumsum(sqrt(diff(vx).^2 + diff(vy).^2))];
                    s = linspace(0, cumD(end), N + 1)';
                    s = s(1:N);
                    pts = [interp1(cumD, vx, s, "linear"), ...
                        interp1(cumD, vy, s, "linear")];
                case "rhombus"
                    vx = [0; -1; 0; 1; 0];
                    vy = [1.3; 0; -1.3; 0; 1.3];
                    cumD = [0; cumsum(sqrt(diff(vx).^2 + diff(vy).^2))];
                    s = linspace(0, cumD(end), N + 1)';
                    s = s(1:N);
                    pts = [interp1(cumD, vx, s, "linear"), ...
                        interp1(cumD, vy, s, "linear")];
                case "clover"
                    r = 1 + 0.5 * cos(4*(t + pi/4));
                    pts = [r .* cos(t), r .* sin(t)];
                case "heart"
                    pts = [16*sin(t).^3, ...
                        -(13*cos(t) - 5*cos(2*t) - 2*cos(3*t) - cos(4*t))];
                case "trefoil"
                    r = 1 + 0.4*cos(3*t);
                    pts = [r .* cos(t), r .* sin(t)];
                case "spiral"
                    half = round(N/2);
                    r2 = [linspace(0.1, 1, half)'; ...
                        linspace(1, 0.1, N - half)'];
                    angle2 = linspace(0, 6*pi, N)';
                    pts = [r2 .* cos(angle2), r2 .* sin(angle2)];
                case "figure8"
                    pts = [sin(t), sin(2*t)];
                otherwise
                    pts = [cos(t), sin(t)];
            end

            % Normalize to fit within [-0.5, 0.5]
            rangeX = max(pts(:,1)) - min(pts(:,1));
            rangeY = max(pts(:,2)) - min(pts(:,2));
            maxRange = max(rangeX, rangeY);
            if maxRange > 0
                pts = pts / maxRange * 0.95;
            end
            pts(:,1) = pts(:,1) - (max(pts(:,1)) + min(pts(:,1))) / 2;
            pts(:,2) = pts(:,2) - (max(pts(:,2)) + min(pts(:,2))) / 2;
        end
    end
end
