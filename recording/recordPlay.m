function recordPlay(gameName, outputDir, maxRecordFrames)
%recordPlay  Play a game with real input while recording.
%   Launch any game in standalone mode. Play with mouse and keyboard.
%   Press Esc or close the figure to stop. GIF + MP4 auto-saved with
%   timestamp to the output directory.
%
%   recordPlay("Pong")                    % record until Esc
%   recordPlay("Tetris", "assets")        % record until Esc, save to assets/
%   recordPlay("Snake", "assets", 600)    % record exactly 600 frames (~10s)

arguments
    gameName         string
    outputDir        string = "assets"
    maxRecordFrames  double = 0    % 0 = unlimited (record until Esc/close)
end

if ~isfolder(outputDir); mkdir(outputDir); end

fprintf("=== RECORDING: %s ===\n", gameName);
fprintf("  Play normally. Press Esc to stop and save.\n\n");

% --- Create game (replicates GameBase.play() setup) ---
ctor = str2func("games." + gameName);
game = ctor();

fig = figure("Color", "k", "WindowState", "maximized", ...
    "MenuBar", "none", "ToolBar", "none", ...
    "Name", "REC: " + gameName, "NumberTitle", "off");
drawnow; pause(0.3);

figPos = fig.Position;
figAR = figPos(3) / max(figPos(4), 1);
rangeY = 480;
rangeX = rangeY * figAR;

ax = axes(fig, "Position", [0 0 1 1], "Color", "k", ...
    "XLim", [0 rangeX], "YLim", [0 rangeY], "YDir", "reverse", ...
    "Visible", "off", "XTick", [], "YTick", []);
hold(ax, "on");
range = struct("X", [0 rangeX], "Y", [0 rangeY]);

game.init(ax, range);
game.beginGame();

% --- Recording state ---
if maxRecordFrames > 0
    maxFrames = maxRecordFrames;
else
    maxFrames = 60 * 120; % 2 min buffer at 60fps
end
framesBuf = cell(1, maxFrames);
capturedCount = 0;
saving = false;
mousePos = [rangeX/2, rangeY/2];
arrowHeld = false(1, 4);
kbMode = false;
frameTic = tic;
recStartTic = tic; % for measuring actual FPS

% --- Callbacks ---
fig.WindowButtonMotionFcn = @(~,~) onMouseMove();
fig.WindowButtonDownFcn = @(~,~) game.onMouseDown();
fig.WindowScrollWheelFcn = @(~,e) game.onScroll(-round(e.VerticalScrollCount));
fig.KeyPressFcn = @(~,e) onKey(e);
fig.KeyReleaseFcn = @(~,e) onKeyRelease(e);
fig.CloseRequestFcn = @(~,~) stopAndSave();

gameAR = diff(range.X) / diff(range.Y);
prevAxPx = getpixelposition(ax);
prevAxPx = prevAxPx(3:4);
fig.SizeChangedFcn = @(~,~) onResize();

% --- Timer ---
tmr = timer("ExecutionMode", "fixedSpacing", "Period", 0.016, ...
    "TimerFcn", @(~,~) tick(), "ErrorFcn", @(~,~) []);
start(tmr);

    function onMouseMove()
        if kbMode; return; end
        cp = get(ax, "CurrentPoint");
        mousePos = cp(1, 1:2);
    end

    function onResize()
        if ~isvalid(fig) || ~isvalid(ax); return; end
        engine.GameBase.letterboxAxes(fig, ax, gameAR);
        axPx = getpixelposition(ax);
        newPs = min(axPx(3)/854, axPx(4)/480);
        oldPs = min(prevAxPx(1)/854, prevAxPx(2)/480);
        if oldPs > 0
            engine.GameBase.scaleScreenSpaceObjects(ax, newPs/oldPs);
        end
        prevAxPx = axPx(3:4);
        game.FontScale = newPs;
    end

    function tick()
        if saving; return; end
        if ~game.IsRunning
            stopAndSave();
            return;
        end
        try
            rawDt = min(toc(frameTic), 0.1);
            frameTic = tic;
            game.DtScale = rawDt * game.RefFPS;

            if any(arrowHeld)
                spd = min(rangeX, rangeY) * 0.04 * game.DtScale;
                if arrowHeld(1); mousePos(2) = mousePos(2) - spd; end
                if arrowHeld(2); mousePos(2) = mousePos(2) + spd; end
                if arrowHeld(3); mousePos(1) = mousePos(1) - spd; end
                if arrowHeld(4); mousePos(1) = mousePos(1) + spd; end
                mousePos(1) = max(0, min(rangeX, mousePos(1)));
                mousePos(2) = max(0, min(rangeY, mousePos(2)));
            end

            game.onUpdate(mousePos);
            game.updateHitEffects();
            drawnow;

            % Capture every frame
            if capturedCount < maxFrames
                capturedCount = capturedCount + 1;
                framesBuf{capturedCount} = getframe(fig);
                if maxRecordFrames > 0 && capturedCount >= maxFrames
                    stopAndSave();
                    return;
                end
            end
        catch me
            fprintf(2, "[recordPlay] %s\n", me.message);
        end
    end

    function onKey(e)
        key = string(e.Key);
        if key == "escape"
            stopAndSave();
            return;
        end
        handled = game.onKeyPress(key);
        if ~handled
            switch key
                case "uparrow";    arrowHeld(1) = true; kbMode = true;
                case "downarrow";  arrowHeld(2) = true; kbMode = true;
                case "leftarrow";  arrowHeld(3) = true; kbMode = true;
                case "rightarrow"; arrowHeld(4) = true; kbMode = true;
            end
        end
    end

    function onKeyRelease(e)
        switch string(e.Key)
            case "uparrow";    arrowHeld(1) = false;
            case "downarrow";  arrowHeld(2) = false;
            case "leftarrow";  arrowHeld(3) = false;
            case "rightarrow"; arrowHeld(4) = false;
        end
        if ~any(arrowHeld); kbMode = false; end
    end

    function stopAndSave()
        if saving; return; end
        saving = true;

        % Measure actual achieved FPS
        totalElapsed = toc(recStartTic);
        actualFps = capturedCount / max(totalElapsed, 0.1);

        if isvalid(tmr); stop(tmr); delete(tmr); end
        try game.onCleanup(); game.cleanupHitEffects(); catch; end
        if isvalid(fig); delete(fig); end

        if capturedCount == 0
            fprintf("No frames captured.\n");
            return;
        end

        framesBuf = framesBuf(1:capturedCount);

        fprintf("Captured %d frames over %.1f s (%.0f fps)\n", ...
            capturedCount, totalElapsed, actualFps);
        reply = input("Save recording? [y/n]: ", "s");
        if ~strcmpi(reply, "y")
            fprintf("Recording discarded.\n");
            return;
        end

        ts = datestr(now, "yyyymmdd_HHMMss"); %#ok<TNOW1,DATST>
        baseName = lower(gameName) + "_" + ts;
        fprintf("Saving as %s...\n", baseName);

        % --- MP4 (actual FPS so playback matches real time) ---
        mp4File = fullfile(outputDir, baseName + ".mp4");
        vw = VideoWriter(mp4File, "MPEG-4");
        vw.FrameRate = round(actualFps);
        vw.Quality = 95;
        open(vw);
        for i = 1:capturedCount
            writeVideo(vw, framesBuf{i}.cdata);
        end
        close(vw);
        fprintf("  MP4: %s (%.0f fps)\n", mp4File, actualFps);

        % --- GIF (same FPS as MP4) ---
        gifFile = fullfile(outputDir, baseName + ".gif");
        gifFps = round(actualFps);
        gifDelay = 1 / gifFps;
        skip = 1;
        % Build a global colormap from sampled frames for consistency
        sampleIdx = round(linspace(1, capturedCount, min(20, capturedCount)));
        samplePixels = [];
        for si = 1:numel(sampleIdx)
            img = framesBuf{sampleIdx(si)}.cdata;
            samplePixels = [samplePixels; reshape(img, [], 3)]; %#ok<AGROW>
        end
        sampleImg = reshape(samplePixels, [], 1, 3);
[~, globalMap] = rgb2ind(uint8(sampleImg), 256, "nodither");
        for gi = 1:skip:capturedCount
            img = framesBuf{gi}.cdata;
            imind = rgb2ind(img, globalMap, "dither");
            if gi == 1
                imwrite(imind, globalMap, gifFile, "gif", "LoopCount", inf, "DelayTime", gifDelay);
            else
                imwrite(imind, globalMap, gifFile, "gif", "WriteMode", "append", "DelayTime", gifDelay);
            end
        end
        fprintf("  GIF: %s (%.0f fps, %d x %d)\n", gifFile, gifFps, size(framesBuf{1}.cdata, 2), size(framesBuf{1}.cdata, 1));
        fprintf("=== SAVED ===\n");
    end
end
