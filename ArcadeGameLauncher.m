classdef (Sealed) ArcadeGameLauncher < handle
    %ArcadeGameLauncher  Standalone arcade-style game launcher with mouse input.
    %   Neon-styled arcade experience: animated game selector with scroll support,
    %   3-2-1 countdown, HUD with score roll-up and combo display, pause/reset/
    %   results screens.  Hosts the same GameBase games used by GestureMouse's
    %   GameHost, but driven by mouse input — no webcam required.
    %
    %   Usage:
    %       ArcadeGameLauncher.launch()
    %
    %   Menu Controls:
    %       Up/Down arrows or mouse hover to navigate
    %       Enter or Space to play, number keys for quick select
    %       ESC to quit
    %
    %   In-Game Controls:
    %       P = pause/resume, R or 0 = restart, ESC = end (results)
    %
    %   See also GameBase, GameHost, GameMenu, GestureMouse

    % =================================================================
    % CORE STATE
    % =================================================================
    properties (SetAccess = private)
        Fig                                     % figure handle
        Ax                                      % axes handle
        RenderTimer                             % timer for frame loop
        MousePos        (1,2) double = [NaN, NaN]
        KeyboardMode    (1,1) logical = false   % true while arrow keys drive cursor
        ArrowHeld       (1,4) logical = false   % [up, down, left, right]

        ActiveGame                              % current GameBase subclass (or [])
        ActiveGameName  string = ""
        State           (1,1) string = "menu"   % menu|countdown|active|paused|results

        % Game registry: key -> struct(ctor, name, key)
        Registry        dictionary
        RegistryOrder   string                  % keys in insertion order

        % Shared menu component
        Menu                                    % GameMenu handle
    end

    % =================================================================
    % HUD HANDLES (axes-based, during gameplay)
    % =================================================================
    properties (SetAccess = private)
        ScoreTextH                              % text — top-left score
        ComboTextH                              % text — combo display
        StatusTextH                             % text — center (countdown/pause/results)
        HudTextH                                % text — bottom HUD from game
    end

    % =================================================================
    % DISPLAY
    % =================================================================
    properties (SetAccess = private)
        DisplayRange    struct = struct("X", [0 640], "Y", [0 480])
    end

    % =================================================================
    % FPS MEASUREMENT (for frame-rate-independent game speeds)
    % =================================================================
    properties (SetAccess = private)
        FpsLastTic      uint64                  % tic of previous frame
        DtBuffer        (1,30) double = NaN     % ring buffer of frame dts (30 frames)
        DtBufIdx        (1,1) double = 0        % current write index
        DtScale         (1,1) double = 1        % avgDt / RefDt — clamped [0.1, 3.0]
        RefPixelSize    (1,2) double = [0, 0]   % axes pixel size at launch (for font scaling)
    end

    % =================================================================
    % SCORING STATE
    % =================================================================
    properties (SetAccess = private)
        Score           (1,1) double = 0
        ScoreDisplayed  (1,1) double = 0
        ScoreRollSpeed  (1,1) double = 3
        Combo           (1,1) double = 0
        MaxCombo        (1,1) double = 0

        % Combo fade
        ComboShowTic
        ComboFadeTic
        ComboFadeColor  (1,3) double = [0.2, 1, 0.4]
        LastScoreChangeTic
        PrevSyncedScore (1,1) double = 0
    end

    % =================================================================
    % COUNTDOWN STATE
    % =================================================================
    properties (SetAccess = private)
        CountdownValue  (1,1) double = 3
        CountdownFrames (1,1) double = 25
        PendingGameKey  string = ""
    end

    % =================================================================
    % SESSION
    % =================================================================
    properties (SetAccess = private)
        SessionStartTic
    end

    % =================================================================
    % COLOR CONSTANTS
    % =================================================================
    properties (Constant, Access = private)
        BgColor     (1,3) double = [0.015, 0.015, 0.03]
        ColorCyan   (1,3) double = [0, 0.92, 1]
        ColorGreen  (1,3) double = [0.2, 1, 0.4]
        ColorGold   (1,3) double = [1, 0.85, 0.2]
        ColorWhite  (1,3) double = [0.95, 0.95, 0.97]
    end

    % =================================================================
    % STATIC ENTRY POINT
    % =================================================================
    methods (Static)
        function launch()
            %launch  Open the arcade game launcher.
            %   ArcadeGameLauncher.launch()
            launcher = ArcadeGameLauncher();
            launcher.run();
        end
    end

    % =================================================================
    % CONSTRUCTOR & LIFECYCLE
    % =================================================================
    methods (Access = private)

        function obj = ArcadeGameLauncher()
            %ArcadeGameLauncher  Private constructor (use launch()).
        end

        function run(obj)
            %run  Create figure, registry, menu, HUD, and start game loop.
            obj.FpsLastTic = tic;
            obj.buildRegistry();
            obj.createFigure();
            obj.createHUD();

            % Create shared menu component
            obj.Menu = GameMenu(obj.Ax, obj.DisplayRange, ...
                obj.Registry, obj.RegistryOrder, ...
                "SelectionMode", "click", ...
                "SelectionFcn", @(k) obj.onMenuSelect(k), ...
                "TagPrefix", "GT_arc");

            obj.enterMenu();
            obj.Fig.SizeChangedFcn = @(~, ~) obj.onFigResize();
            obj.startTimer();
        end

        function close(obj)
            %close  Shut down arcade: stop timer, clean up game, delete figure.
            if ~isempty(obj.RenderTimer) && isvalid(obj.RenderTimer)
                stop(obj.RenderTimer);
                delete(obj.RenderTimer);
            end
            obj.RenderTimer = [];

            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                try
                    obj.ActiveGame.onCleanup();
                    obj.ActiveGame.cleanupHitEffects();
                catch
                end
                obj.ActiveGame = [];
            end

            if ~isempty(obj.Menu)
                obj.Menu.cleanup();
                obj.Menu = [];
            end

            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                delete(obj.Fig);
            end
            obj.Fig = [];
        end
    end

    % =================================================================
    % PRIVATE — Figure & Timer
    % =================================================================
    methods (Access = private)

        function createFigure(obj)
            %createFigure  Create fullscreen figure with aspect-correct axes.
            obj.Fig = figure("Color", obj.BgColor, ...
                "MenuBar", "none", "ToolBar", "none", "NumberTitle", "off", ...
                "WindowState", "maximized", ...
                "Name", "Arcade", ...
                "CloseRequestFcn", @(~, ~) obj.close(), ...
                "WindowButtonMotionFcn", @(~, ~) obj.onMouseMove(), ...
                "WindowButtonDownFcn", @(~, ~) obj.onMouseDown(), ...
                "WindowButtonUpFcn", @(~, ~) obj.onMouseUp(), ...
                "WindowScrollWheelFcn", @(~, e) obj.onScrollWheel(e), ...
                "KeyPressFcn", @(~, e) obj.onKeyPress(e), ...
                "KeyReleaseFcn", @(~, e) obj.onKeyRelease(e));

            drawnow;  % force layout so Position reflects maximized size
            obj.computeDisplayRange();

            obj.Ax = axes(obj.Fig, "Units", "normalized", ...
                "Position", [0 0 1 1]);
            obj.Ax.Color = obj.BgColor;
            obj.Ax.XLim = obj.DisplayRange.X;
            obj.Ax.YLim = obj.DisplayRange.Y;
            obj.Ax.YDir = "reverse";
            obj.Ax.Visible = "off";
            obj.Ax.XTick = [];
            obj.Ax.YTick = [];
            obj.Ax.Toolbar = [];
            obj.Ax.Interactions = [];
            enableDefaultInteractivity(obj.Ax);
            obj.Fig.Pointer = "arrow";
            hold(obj.Ax, "on");

            % Capture reference pixel size for font scaling
            axPx = getpixelposition(obj.Ax);
            obj.RefPixelSize = axPx(3:4);
        end

        function computeDisplayRange(obj)
            %computeDisplayRange  Set display range to match figure aspect ratio.
            figPos = obj.Fig.Position;
            figAR = figPos(3) / max(figPos(4), 1);
            rangeY = 480;
            rangeX = rangeY * figAR;
            obj.DisplayRange = struct("X", [0 rangeX], "Y", [0 rangeY]);
        end

        function startTimer(obj)
            %startTimer  Start the render timer (50 Hz).
            obj.RenderTimer = timer("ExecutionMode", "fixedSpacing", ...
                "Period", 0.02, "TimerFcn", @(~, ~) obj.onFrame(), ...
                "ErrorFcn", @(~, e) fprintf(2, "[Arcade] %s\n", e.Data.message));
            start(obj.RenderTimer);
        end

        function onMouseMove(obj)
            %onMouseMove  Update mouse position; handle scroll thumb drag.
            if isempty(obj.Ax) || ~isvalid(obj.Ax); return; end
            if obj.KeyboardMode; return; end  % ignore mouse while arrows active
            cp = get(obj.Ax, "CurrentPoint");
            obj.MousePos = cp(1, 1:2);

            if ~isempty(obj.Menu) && obj.Menu.ScrollDragging && obj.State == "menu"
                obj.Menu.updateScrollDrag(obj.MousePos(2));
            end
        end

        function onMouseDown(obj)
            %onMouseDown  Click on game item or start scroll thumb drag.
            if obj.State ~= "menu"; return; end
            if any(isnan(obj.MousePos)); return; end
            if isempty(obj.Menu); return; end

            % Check scroll thumb drag
            if obj.Menu.hitTestScrollThumb(obj.MousePos)
                obj.Menu.beginScrollDrag(obj.MousePos(2));
                return;
            end

            % Check item click
            hitIdx = obj.Menu.hitTestItem(obj.MousePos);
            if hitIdx > 0
                nGames = numel(obj.RegistryOrder);
                if hitIdx <= nGames
                    obj.PendingGameKey = obj.RegistryOrder(hitIdx);
                    obj.enterCountdown();
                end
            end
        end

        function onMouseUp(obj)
            %onMouseUp  End scroll thumb drag.
            if ~isempty(obj.Menu)
                obj.Menu.endScrollDrag();
            end
        end

        function onScrollWheel(obj, evnt)
            %onScrollWheel  Scroll game list or forward to active game.
            delta = round(evnt.VerticalScrollCount);
            if obj.State == "menu"
                if ~isempty(obj.Menu)
                    obj.Menu.scrollByDelta(delta);
                end
            elseif obj.State == "active"
                if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                    obj.ActiveGame.onScroll(-delta);
                end
            end
        end

        function onMenuSelect(obj, key)
            %onMenuSelect  Callback from GameMenu when a game is selected.
            obj.PendingGameKey = key;
            obj.enterCountdown();
        end

        function onFigResize(obj)
            %onFigResize  Handle figure resize — letterbox during gameplay.
            if isempty(obj.Fig) || ~isvalid(obj.Fig); return; end
            if isempty(obj.Ax) || ~isvalid(obj.Ax); return; end

            % During gameplay: freeze coordinate system, maintain aspect ratio
            if obj.State ~= "menu"
                % PlotBoxAspectRatio locks the axes box shape — MATLAB
                % auto-letterboxes within the Position rectangle.
                gameAR = diff(obj.DisplayRange.X) / diff(obj.DisplayRange.Y);
                pbaspect(obj.Ax, [gameAR 1 1]);
                % Manual letterbox fallback (kept in case pbaspect has issues):
                % GameBase.letterboxAxes(obj.Fig, obj.Ax, gameAR);
                % Scale HUD fonts
                if obj.RefPixelSize(1) > 0
                    axPx = getpixelposition(obj.Ax);
                    pixelScale = min(axPx(3) / obj.RefPixelSize(1), axPx(4) / obj.RefPixelSize(2));
                    GameBase.scaleScreenSpaceObjects(obj.Ax, pixelScale);
                    if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                        obj.ActiveGame.FontScale = pixelScale;
                    end
                end
                return;
            end

            % Menu state: adapt coordinate system to new window size
            obj.computeDisplayRange();
            obj.Ax.XLim = obj.DisplayRange.X;
            obj.Ax.YLim = obj.DisplayRange.Y;

            % Stop timer during rebuild to prevent re-entrant onFrame
            restartTimer = false;
            if ~isempty(obj.RenderTimer) && isvalid(obj.RenderTimer) ...
                    && strcmp(obj.RenderTimer.Running, "on")
                stop(obj.RenderTimer);
                restartTimer = true;
            end

            % Rebuild menu
            if ~isempty(obj.Menu)
                obj.Menu.resize(obj.DisplayRange);
            end

            % Rebuild HUD
            handles = {obj.ScoreTextH, obj.ComboTextH, ...
                obj.StatusTextH, obj.HudTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.createHUD();
            obj.hideGameplayHUD();

            drawnow;

            if restartTimer
                start(obj.RenderTimer);
            end
        end
    end

    % =================================================================
    % PRIVATE — Frame Loop
    % =================================================================
    methods (Access = private)

        function onFrame(obj)
            %onFrame  Main frame callback — dispatches to state handler.
            if isempty(obj.Fig) || ~isvalid(obj.Fig); return; end
            if isempty(obj.Ax) || ~isvalid(obj.Ax); return; end

            % Measure frame dt (EMA on dt, not FPS) and compute speed scale
            rawDt = toc(obj.FpsLastTic);
            obj.FpsLastTic = tic;
            [obj.DtScale, obj.DtBuffer, obj.DtBufIdx] = GameBase.computeDtScale(rawDt, obj.DtBuffer, obj.DtBufIdx);

            try
                switch obj.State
                    case "menu"
                        if ~isempty(obj.Menu)
                            obj.Menu.update(obj.MousePos);
                        end
                    case "countdown"
                        obj.updateCountdown();
                    case "active"
                        obj.updateActive();
                    case "paused"
                        % Static
                    case "results"
                        % Static
                end

                obj.updateComboFade();

                if obj.ScoreDisplayed < obj.Score
                    gap = obj.Score - obj.ScoreDisplayed;
                    obj.ScoreDisplayed = min(obj.ScoreDisplayed ...
                        + max(obj.ScoreRollSpeed, gap * 0.3), obj.Score);
                    obj.updateScoreText();
                end

                drawnow;
            catch me
                % Suppress stale-handle errors during state transitions
                if ~contains(me.message, "Invalid or deleted")
                    fprintf(2, "[Arcade] %s\n", me.message);
                end
            end
        end

        function updateActive(obj)
            %updateActive  Per-frame update during active gameplay.
            if isempty(obj.ActiveGame) || ~isvalid(obj.ActiveGame); return; end

            % Arrow key cursor movement (when keyboard mode active)
            if any(obj.ArrowHeld)
                spd = min(diff(obj.DisplayRange.X), diff(obj.DisplayRange.Y)) * 0.04 * obj.DtScale;
                if obj.ArrowHeld(1); obj.MousePos(2) = obj.MousePos(2) - spd; end  % up
                if obj.ArrowHeld(2); obj.MousePos(2) = obj.MousePos(2) + spd; end  % down
                if obj.ArrowHeld(3); obj.MousePos(1) = obj.MousePos(1) - spd; end  % left
                if obj.ArrowHeld(4); obj.MousePos(1) = obj.MousePos(1) + spd; end  % right
                % Clamp to display range
                obj.MousePos(1) = max(obj.DisplayRange.X(1), min(obj.DisplayRange.X(2), obj.MousePos(1)));
                obj.MousePos(2) = max(obj.DisplayRange.Y(1), min(obj.DisplayRange.Y(2), obj.MousePos(2)));
            end

            obj.ActiveGame.DtScale = obj.DtScale;
            obj.ActiveGame.onUpdate(obj.MousePos);
            obj.ActiveGame.updateHitEffects();

            % Game signalled completion (e.g., Pong win condition)
            if ~obj.ActiveGame.IsRunning
                obj.enterResults();
                return;
            end

            prevScore = obj.Score;
            prevCombo = obj.Combo;
            obj.Score = obj.ActiveGame.Score;
            obj.Combo = obj.ActiveGame.Combo;
            obj.MaxCombo = max(obj.MaxCombo, obj.ActiveGame.MaxCombo);

            % Track when score last changed (for combo auto-fade)
            if obj.Score ~= prevScore
                obj.LastScoreChangeTic = tic;
                obj.PrevSyncedScore = obj.Score;
            end

            % Update combo display — only on change
            if obj.ActiveGame.ShowHostCombo
                scoringRecently = ~isempty(obj.LastScoreChangeTic) ...
                    && toc(obj.LastScoreChangeTic) < 2.0;
                if obj.Combo >= 2 && scoringRecently
                    if obj.Combo ~= prevCombo
                        obj.showCombo();
                    end
                elseif obj.Combo == 0 && prevCombo > 0
                    obj.ComboFadeTic = tic;
                    obj.ComboFadeColor = obj.ColorGreen * 0.9;
                    obj.ComboShowTic = [];
                end
            end

            hudStr = obj.ActiveGame.getHudText();
            if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                if strlength(hudStr) > 0
                    obj.HudTextH.String = hudStr;
                    obj.HudTextH.Visible = "on";
                else
                    obj.HudTextH.Visible = "off";
                end
            end
        end
    end

    % =================================================================
    % PRIVATE — Key Handling
    % =================================================================
    methods (Access = private)

        function onKeyPress(obj, evnt)
            %onKeyPress  Route key events based on current state.
            key = string(evnt.Key);

            % Ignore modifier-only presses (shift/alt/control alone)
            if any(key == ["shift", "alt", "control"]); return; end

            if ~isempty(evnt.Modifier)
                mods = string(evnt.Modifier);
                if any(mods == "shift")
                    if ~(strlength(key) == 1 && key >= "1" && key <= "9")
                        shiftMap = dictionary( ...
                            ["!", "@", """", "#", "£", "$", "%", "^", "&", "*"], ...
                            ["1", "2",  "2",  "3", "3",  "4", "5",  "6", "7", "8"]);
                        ch = string(evnt.Character);
                        if shiftMap.isKey(ch)
                            key = shiftMap(ch);
                        end
                    end
                    key = "shift+" + key;
                elseif any(mods == "alt")
                    key = "alt+" + key;
                end
            end

            % Fallback: if modified key not in registry, try plain key
            plainKey = string(evnt.Key);
            if ~obj.Registry.isKey(key) && obj.Registry.isKey(plainKey)
                key = plainKey;
            end

            switch obj.State
                case "menu"
                    if obj.Registry.isKey(key)
                        obj.PendingGameKey = key;
                        obj.enterCountdown();
                    elseif key == "uparrow"
                        obj.Menu.moveSelection(-1);
                    elseif key == "downarrow"
                        obj.Menu.moveSelection(1);
                    elseif key == "return" || key == "space"
                        obj.Menu.confirmSelection();
                    elseif key == "escape"
                        obj.close();
                    end

                case "countdown"
                    if key == "escape"
                        obj.enterMenu();
                    end

                case "active"
                    if key == "p"
                        obj.enterPaused();
                    elseif key == "r"
                        obj.restartGame();
                    elseif key == "escape"
                        obj.enterResults();
                    else
                        handled = false;
                        if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                            handled = obj.ActiveGame.onKeyPress(key);
                        end
                        % Arrow keys for cursor movement (if game didn't handle them)
                        if ~handled
                            obj.handleArrowPress(key);
                        end
                    end

                case "paused"
                    if key == "p"
                        obj.enterActive();
                    elseif key == "r"
                        obj.restartGame();
                    elseif key == "escape"
                        obj.enterResults();
                    end

                case "results"
                    if key == "r" || key == "return" || key == "space"
                        obj.playAgain();
                    else
                        obj.enterMenu();
                    end
            end
        end
    end

    % =================================================================
    % PRIVATE — State Machine
    % =================================================================
    methods (Access = private)

        function enterMenu(obj)
            %enterMenu  Return to menu screen.
            obj.State = "menu";
            obj.ArrowHeld(:) = false;
            obj.KeyboardMode = false;

            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                try
                    obj.ActiveGame.onCleanup();
                    obj.ActiveGame.cleanupHitEffects();
                catch
                end
                obj.ActiveGame = [];
            end
            obj.cleanupOrphans();

            if ~isempty(obj.Menu)
                obj.Menu.show();
            end
            obj.hideGameplayHUD();
        end

        function enterCountdown(obj)
            %enterCountdown  Start 3-2-1 countdown before game.
            obj.State = "countdown";
            obj.CountdownValue = 3;
            obj.CountdownFrames = 25;

            obj.Score = 0;
            obj.ScoreDisplayed = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;
            obj.SessionStartTic = tic;
            obj.LastScoreChangeTic = [];
            obj.PrevSyncedScore = 0;
            obj.ComboShowTic = [];
            obj.ComboFadeTic = [];

            if ~isempty(obj.Menu)
                obj.Menu.hide();
            end

            if ~isempty(obj.ScoreTextH) && isvalid(obj.ScoreTextH)
                obj.ScoreTextH.String = "Score: 0";
                obj.ScoreTextH.Visible = "on";
            end
            if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                obj.ComboTextH.Visible = "off";
            end
            if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                obj.HudTextH.Visible = "off";
            end
        end

        function updateCountdown(obj)
            %updateCountdown  Animate 3-2-1-GO countdown.
            obj.CountdownFrames = obj.CountdownFrames - 1;
            totalPerNum = 25;
            progress = 1 - obj.CountdownFrames / totalPerNum;
            scale = 1 + 0.3 * sin(progress * pi);
            fadeAlpha = 1 - max(0, progress - 0.7) / 0.3;

            if ~isempty(obj.StatusTextH) && isvalid(obj.StatusTextH)
                cx = mean(obj.DisplayRange.X);
                cy = mean(obj.DisplayRange.Y);
                obj.StatusTextH.Position = [cx, cy, 0];
                if obj.CountdownValue > 0
                    obj.StatusTextH.String = string(obj.CountdownValue);
                else
                    obj.StatusTextH.String = "GO!";
                end
                obj.StatusTextH.FontSize = round(60 * scale);
                obj.StatusTextH.Color = [obj.ColorCyan, max(fadeAlpha, 0)];
                obj.StatusTextH.Visible = "on";
            end

            if obj.CountdownFrames <= 0
                if obj.CountdownValue > 0
                    obj.CountdownValue = obj.CountdownValue - 1;
                    if obj.CountdownValue > 0
                        obj.CountdownFrames = totalPerNum;
                    else
                        obj.CountdownFrames = 12;
                    end
                else
                    obj.launchGame();
                end
            end
        end

        function enterActive(obj)
            %enterActive  Resume from pause.
            obj.State = "active";
            if ~isempty(obj.StatusTextH) && isvalid(obj.StatusTextH)
                obj.StatusTextH.Visible = "off";
            end
            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                obj.ActiveGame.onResume();
            end
        end

        function enterPaused(obj)
            %enterPaused  Pause the game.
            obj.State = "paused";
            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                obj.ActiveGame.onPause();
            end
            if ~isempty(obj.StatusTextH) && isvalid(obj.StatusTextH)
                cx = mean(obj.DisplayRange.X);
                cy = mean(obj.DisplayRange.Y);
                obj.StatusTextH.Position = [cx, cy, 0];
                obj.StatusTextH.String = "PAUSED";
                obj.StatusTextH.FontSize = 32;
                obj.StatusTextH.Color = obj.ColorGold * 0.9;
                obj.StatusTextH.Visible = "on";
            end
        end

        function enterResults(obj)
            %enterResults  Show results screen.
            obj.State = "results";
            obj.ComboFadeTic = [];   % stop combo fade from hiding results text
            obj.ComboShowTic = [];

            results = struct("Title", "GAME OVER", "Lines", {{}});
            gameId = "";
            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                gameId = ScoreManager.classToId(class(obj.ActiveGame));
                try
                    results = obj.ActiveGame.getResults();
                catch
                end
                try
                    obj.ActiveGame.onCleanup();
                    obj.ActiveGame.cleanupHitEffects();
                catch
                end
                obj.ActiveGame = [];
            end
            obj.cleanupOrphans();

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cx = mean(dx);
            cy = mean(dy);

            if ~isempty(obj.StatusTextH) && isvalid(obj.StatusTextH)
                obj.StatusTextH.Position = [cx, cy - diff(dy) * 0.08, 0];
                titleStr = "GAME OVER";
                if isfield(results, "Title") && strlength(results.Title) > 0
                    titleStr = results.Title;
                end
                obj.StatusTextH.String = titleStr;
                obj.StatusTextH.FontSize = 32;
                obj.StatusTextH.Color = obj.ColorGold;
                obj.StatusTextH.Visible = "on";
            end

            if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                obj.ComboTextH.Position = [cx, cy + diff(dy) * 0.02, 0];
                obj.ComboTextH.HorizontalAlignment = "center";
                detailLines = {};
                if isfield(results, "Lines") && ~isempty(results.Lines)
                    detailLines = cellstr(results.Lines);
                end
                elapsed = toc(obj.SessionStartTic);
                detailLines{end + 1} = sprintf( ...
                    "Score: %d  |  Max Combo: %d  |  Time: %.0fs", ...
                    obj.Score, obj.MaxCombo, elapsed);
                % High score tracking
                if strlength(gameId) > 0
                    [isNewHigh, ~] = ScoreManager.submit( ...
                        gameId, obj.Score, obj.MaxCombo, elapsed);
                    if isNewHigh
                        detailLines{end + 1} = sprintf( ...
                            "★  NEW HIGH SCORE: %d  ★", obj.Score);
                    else
                        hsRec = ScoreManager.get(gameId);
                        if hsRec.highScore > obj.Score
                            detailLines{end + 1} = sprintf( ...
                                "High Score: %d", hsRec.highScore);
                        end
                    end
                end
                detailLines{end + 1} = "";
                detailLines{end + 1} = "[R] PLAY AGAIN   |   [ESC] MENU";
                obj.ComboTextH.String = strjoin(string(detailLines), newline);
                obj.ComboTextH.FontSize = 14;
                obj.ComboTextH.Color = obj.ColorWhite * 0.85;
                obj.ComboTextH.Visible = "on";
            end

            if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                obj.HudTextH.Visible = "off";
            end
        end

        function launchGame(obj)
            %launchGame  Instantiate and start the pending game.
            obj.State = "active";
            if ~isempty(obj.StatusTextH) && isvalid(obj.StatusTextH)
                obj.StatusTextH.Visible = "off";
            end

            key = obj.PendingGameKey;
            if ~obj.Registry.isKey(key); return; end
            entry = obj.Registry(key);
            obj.ActiveGameName = entry.name;

            game = entry.ctor();
            game.onInit(obj.Ax, obj.DisplayRange, struct());
            game.beginGame();
            obj.ActiveGame = game;
            obj.SessionStartTic = tic;
        end

        function restartGame(obj)
            %restartGame  Restart the current game (clean up + countdown).
            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                try
                    obj.ActiveGame.onCleanup();
                    obj.ActiveGame.cleanupHitEffects();
                catch
                end
                obj.ActiveGame = [];
            end
            obj.cleanupOrphans();
            obj.enterCountdown();
        end

        function playAgain(obj)
            %playAgain  Replay the same game from the results screen.
            if strlength(obj.PendingGameKey) > 0
                obj.cleanupOrphans();
                obj.enterCountdown();
            else
                obj.enterMenu();
            end
        end

        function launchSelected(obj)
            %launchSelected  Launch whatever game is currently highlighted.
            if isempty(obj.Menu); return; end
            obj.Menu.confirmSelection();
        end
    end

    % =================================================================
    % PRIVATE — HUD Management
    % =================================================================
    methods (Access = private)

        function createHUD(obj)
            %createHUD  Create persistent HUD text objects on axes.
            ax = obj.Ax;
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cx = mean(dx);
            cy = mean(dy);

            obj.ScoreTextH = text(ax, dx(1) + 4, dy(1) + 2, "Score: 0", ...
                "Color", obj.ColorGreen * 0.9, "FontSize", 14, ...
                "FontWeight", "bold", "HorizontalAlignment", "left", ...
                "VerticalAlignment", "top", "Visible", "off", ...
                "Tag", "GT_arcScore");

            obj.ComboTextH = text(ax, cx, dy(1) + 34, "", ...
                "Color", obj.ColorGold * 0.8, "FontSize", 13, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "top", "Visible", "off", ...
                "Tag", "GT_arcCombo");

            obj.StatusTextH = text(ax, cx, cy, "", ...
                "Color", obj.ColorCyan * 0.95, "FontSize", 28, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_arcStatus");

            obj.HudTextH = text(ax, cx, dy(2) - 8, "", ...
                "Color", obj.ColorWhite * 0.7, "FontSize", 11, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", "Visible", "off", ...
                "Tag", "GT_arcHud");
        end

        function scaleFonts(obj, pixelScale)
            %scaleFonts  Scale HUD font sizes by pixel scale factor.
            baseSizes = [14, 13, 28, 11];  % Score, Combo, Status, Hud
            handles = {obj.ScoreTextH, obj.ComboTextH, obj.StatusTextH, obj.HudTextH};
            for k = 1:4
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    h.FontSize = max(6, round(baseSizes(k) * pixelScale));
                end
            end
        end

        function handleArrowPress(obj, key)
            %handleArrowPress  Set arrow held flags for cursor movement.
            switch key
                case "uparrow";    obj.ArrowHeld(1) = true; obj.KeyboardMode = true;
                case "downarrow";  obj.ArrowHeld(2) = true; obj.KeyboardMode = true;
                case "leftarrow";  obj.ArrowHeld(3) = true; obj.KeyboardMode = true;
                case "rightarrow"; obj.ArrowHeld(4) = true; obj.KeyboardMode = true;
            end
        end

        function onKeyRelease(obj, evnt)
            %onKeyRelease  Clear arrow held flags on key release.
            switch string(evnt.Key)
                case "uparrow";    obj.ArrowHeld(1) = false;
                case "downarrow";  obj.ArrowHeld(2) = false;
                case "leftarrow";  obj.ArrowHeld(3) = false;
                case "rightarrow"; obj.ArrowHeld(4) = false;
            end
            if ~any(obj.ArrowHeld)
                obj.KeyboardMode = false;
            end
        end

        function hideGameplayHUD(obj)
            %hideGameplayHUD  Hide score/combo/status/hud text.
            handles = {obj.ScoreTextH, obj.ComboTextH, ...
                obj.StatusTextH, obj.HudTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    h.Visible = "off";
                end
            end
        end

        function updateScoreText(obj)
            %updateScoreText  Update score display with roll-up value.
            if ~isempty(obj.ScoreTextH) && isvalid(obj.ScoreTextH)
                obj.ScoreTextH.String = sprintf("Score: %d", ...
                    round(obj.ScoreDisplayed));
            end
        end

        function showCombo(obj)
            %showCombo  Show combo text.
            if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH); return; end
            obj.ComboFadeTic = [];
            obj.ComboTextH.String = sprintf("%dx Combo", obj.Combo);
            obj.ComboTextH.Color = obj.ColorGreen * 0.9;
            obj.ComboTextH.FontSize = 13;
            cx = mean(obj.DisplayRange.X);
            obj.ComboTextH.Position = [cx, obj.DisplayRange.Y(1) + 34, 0];
            obj.ComboTextH.HorizontalAlignment = "center";
            obj.ComboTextH.Visible = "on";
            obj.ComboShowTic = tic;
        end

        function updateComboFade(obj)
            %updateComboFade  Animate combo text fade-out.
            if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH)
                obj.ComboFadeTic = [];
                obj.ComboShowTic = [];
                return;
            end

            if ~isempty(obj.ComboShowTic) && isempty(obj.ComboFadeTic)
                if toc(obj.ComboShowTic) >= 1.0
                    obj.ComboFadeTic = tic;
                    obj.ComboFadeColor = obj.ColorGreen * 0.9;
                    obj.ComboShowTic = [];
                end
            end

            if isempty(obj.ComboFadeTic); return; end
            elapsed = toc(obj.ComboFadeTic);
            fadeDur = 0.6;
            if elapsed >= fadeDur
                obj.ComboTextH.Visible = "off";
                obj.ComboFadeTic = [];
            else
                comboAlpha = max(0, 1 - elapsed / fadeDur);
                obj.ComboTextH.Color = [obj.ComboFadeColor, comboAlpha];
            end
        end

        function cleanupOrphans(obj)
            %cleanupOrphans  Delete game graphics, preserving arcade HUD + menu.
            if isempty(obj.Ax) || ~isvalid(obj.Ax); return; end
            orphans = findall(obj.Ax, "-regexp", "Tag", "^GT_(?!arc)");
            if ~isempty(orphans)
                delete(orphans);
            end
        end
    end

    % =================================================================
    % PRIVATE — Game Registry
    % =================================================================
    methods (Access = private)

        function buildRegistry(obj)
            %buildRegistry  Register all available games with key bindings.
            obj.Registry = dictionary;
            obj.RegistryOrder = strings(0);

            % === Number keys (1-9) ===
            obj.registerGame("1", @games.Pointing, "Pointing");
            obj.registerGame("2", @games.Tracing, "Tracing");
            obj.registerGame("3", @games.Catching, "Catching");
            obj.registerGame("4", @games.FlickBall, "Flick Ball");
            obj.registerGame("5", @games.Pong, "Pong");
            obj.registerGame("6", @games.Juggling, "Juggling");
            obj.registerGame("7", @games.GlyphTrace, "Glyph Trace");
            obj.registerGame("8", @games.Keyboard, "Keyboard");
            obj.registerGame("9", @games.Breakout, "Breakout");

            % === Shift + number keys ===
            obj.registerGame("shift+1", @games.FlappyBird, "Flappy Bird");
            obj.registerGame("shift+2", @games.FruitNinja, "Fruit Ninja");
            obj.registerGame("shift+3", @games.SpaceInvaders, "Space Invaders");
            obj.registerGame("shift+4", @games.Snake, "Snake");
            obj.registerGame("shift+5", @games.Asteroids, "Asteroids");
            obj.registerGame("shift+6", @games.OrbitalDefense, "Orbital Defense");
            obj.registerGame("shift+7", @games.GravityWell, "Gravity Well");
            obj.registerGame("shift+8", @games.ShieldGuardian, "Shield Guardian");
            obj.registerGame("shift+9", @games.FpsRailShooter, "FPS Rail Shooter");

            % === Alt + number keys ===
            obj.registerGame("alt+1", @games.MoleculeGrid, "Molecule Grid");
            obj.registerGame("alt+2", @games.FluidSim, "Fluid Sim");
            obj.registerGame("alt+3", @games.Dobryakov, "Dobryakov");
            obj.registerGame("alt+4", @games.RippleTank, "Ripple Tank");
            obj.registerGame("alt+5", @games.ReactionDiffusion, "Reaction-Diffusion");
            obj.registerGame("alt+6", @games.WindTunnel, "Wind Tunnel");
            obj.registerGame("alt+7", @games.Elements, "Elements");
            obj.registerGame("alt+8", @games.StringHarmonics, "String Harmonics");
            obj.registerGame("alt+9", @games.ThreeBody, "Three-Body");
            obj.registerGame("alt+0", @games.Voronoi, "Voronoi");

            % === Special keys ===
            obj.registerGame("0", @games.GameOfLife, "Game of Life");
            obj.registerGame("shift+0", @games.Lissajous, "Lissajous");
            obj.registerGame("alt+p", @games.Piano, "Piano");
            obj.registerGame("alt+c", @games.CrystalGrowth, "Crystal Growth");

            % === Numpad keys ===
            obj.registerGame("numpad1", @games.Cloth, "Cloth");
            obj.registerGame("numpad2", @games.Boids, "Boids");
            obj.registerGame("numpad3", @games.DoublePendulum, "Double Pendulum");
            obj.registerGame("numpad4", @games.Smoke, "Smoke");
            obj.registerGame("numpad5", @games.Fire, "Fire");
            obj.registerGame("numpad6", @games.NewtonsCradle, "Newton's Cradle");
            obj.registerGame("numpad7", @games.EmField, "EM Field");
            obj.registerGame("numpad8", @games.Planets, "Planets");
            obj.registerGame("numpad9", @games.Lorenz, "Lorenz");
            obj.registerGame("numpad0", @games.FourierEpicycle, "Fourier Epicycle");
            obj.registerGame("shift+numpad1", @games.Ecosystem, "Ecosystem");
            obj.registerGame("shift+end", @games.Ecosystem, "Ecosystem");  % Windows: Shift+Numpad1 = End
        end

        function registerGame(obj, key, ctor, name)
            %registerGame  Add a game to the registry.
            entry.ctor = ctor;
            entry.name = name;
            entry.key = key;
            obj.Registry(key) = entry;
            obj.RegistryOrder(end + 1) = key;
        end
    end

    % =================================================================
    % DESTRUCTOR
    % =================================================================
    methods
        function delete(obj)
            %delete  Clean up on object destruction.
            obj.close();
        end
    end
end
