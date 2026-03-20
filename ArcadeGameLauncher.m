classdef ArcadeGameLauncher < handle
    %ArcadeGameLauncher  Standalone arcade-style game launcher with mouse input.
    %   Neon-styled arcade experience: animated game selector with scroll support,
    %   3-2-1 countdown, HUD with score roll-up and combo display, pause/reset/
    %   results screens.  Hosts the same GameBase games used by GestureMouse's
    %   GameHost, but driven by mouse input — no webcam required.
    %
    %   Usage:
    %       ArcadeGameLauncher()
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
    % PUBLIC CONFIGURATION
    % =================================================================
    properties
        ShowFPS         (1,1) logical = true    % show FPS counter during gameplay
    end

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

        % Shared menu component
        Menu                                    % GameMenu handle
    end

    properties (SetAccess = protected)
        % Game registry: key -> struct(ctor, name, key)
        Registry        dictionary
        RegistryOrder   string                  % keys in insertion order
    end

    % =================================================================
    % HUD HANDLES (axes-based, during gameplay)
    % =================================================================
    properties (SetAccess = private)
        ScoreTextH                              % text — top-left score
        ComboTextH                              % text — combo display
        StatusTextH                             % text — center (countdown/pause/results)
        HudTextH                                % text — bottom HUD from game
        FpsTextH                                % text — top-right FPS counter
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
        DtScale         (1,1) double = 1        % rawDt * RefFPS
        RawDt           (1,1) double = 0.040   % raw dt of current frame (seconds)
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
            %launch  Open the arcade game launcher (legacy entry point).
            %   ArcadeGameLauncher.launch()
            ArcadeGameLauncher();
        end
    end

    % =================================================================
    % CONSTRUCTOR & LIFECYCLE
    % =================================================================
    methods (Access = public)

        function obj = ArcadeGameLauncher()
            %ArcadeGameLauncher  Create and run the arcade game launcher.
            obj.run();
        end

        function run(obj)
            %run  Create figure, registry, menu, HUD, and start game loop.
            obj.FpsLastTic = tic;
            obj.buildRegistry();
            obj.createFigure();
            obj.createHUD();

            % Create shared menu component
            [menuTitle, menuSubtitle] = obj.getMenuTitles();
            obj.Menu = GameMenu(obj.Ax, obj.DisplayRange, ...
                obj.Registry, obj.RegistryOrder, ...
                "SelectionMode", "click", ...
                "SelectionFcn", @(k) obj.onMenuSelect(k), ...
                "TagPrefix", "GT_arc", ...
                "Title", menuTitle, ...
                "Subtitle", menuSubtitle);

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

            % RefPixelSize captured lazily on first onFigResize
            % (after maximize completes) — avoids pre-maximize capture.
        end

        function computeDisplayRange(obj)
            %computeDisplayRange  Fixed 16:9 display range (854x480).
            %   Same on all machines regardless of figure size or maximize timing.
            %   pbaspect handles letterboxing if the figure AR differs.
            obj.DisplayRange = struct("X", [0 854], "Y", [0 480]);
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
            cp = get(obj.Ax, "CurrentPoint");
            newPos = cp(1, 1:2);
            if obj.KeyboardMode
                % Exit keyboard mode if mouse moves enough
                if ~any(isnan(obj.MousePos)) && norm(newPos - obj.MousePos) > 15
                    obj.KeyboardMode = false;
                else
                    return;
                end
            end
            obj.MousePos = newPos;

            if ~isempty(obj.Menu) && obj.Menu.ScrollDragging && obj.State == "menu"
                obj.Menu.updateScrollDrag(obj.MousePos(2));
            end
        end

        function onMouseDown(obj)
            %onMouseDown  Click on game item, forward to active game, or start scroll thumb drag.

            % Forward click to active game during gameplay
            if obj.State == "active"
                if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                    obj.ActiveGame.onMouseDown();
                end
                return;
            end

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

            % Lazy capture: first resize = maximize complete
            if obj.RefPixelSize(1) == 0
                axPx = getpixelposition(obj.Ax);
                obj.RefPixelSize = axPx(3:4);
            end

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

            % Menu state: letterbox like games do (fixed display range)
            menuAR = diff(obj.DisplayRange.X) / diff(obj.DisplayRange.Y);
            pbaspect(obj.Ax, [menuAR 1 1]);

            % Scale non-menu screen-space objects (HUD text, markers)
            if obj.RefPixelSize(1) > 0
                axPx = getpixelposition(obj.Ax);
                pixelScale = min(axPx(3) / obj.RefPixelSize(1), axPx(4) / obj.RefPixelSize(2));
                GameBase.scaleScreenSpaceObjects(obj.Ax, pixelScale);
            end

            % Impose deterministic menu font sizes from current pixel size
            if ~isempty(obj.Menu)
                obj.Menu.scaleFonts();
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

            % Measure frame dt (cap at 50ms / 20 FPS floor)
            obj.RawDt = min(toc(obj.FpsLastTic), 0.1);
            obj.FpsLastTic = tic;
            % Update ring buffer for FPS display
            obj.DtBufIdx = mod(obj.DtBufIdx, numel(obj.DtBuffer)) + 1;
            obj.DtBuffer(obj.DtBufIdx) = obj.RawDt;
            obj.DtScale = 1;  % default for non-game states (countdown etc.)

            try
                switch obj.State
                    case "menu"
                        if ~isempty(obj.Menu)
                            if obj.KeyboardMode
                                obj.Menu.update([NaN NaN]);
                            else
                                obj.Menu.update(obj.MousePos);
                            end
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

                % FPS counter (from 30-frame ring buffer)
                if ~isempty(obj.FpsTextH) && isvalid(obj.FpsTextH)
                    showIt = obj.ShowFPS && (obj.State == "active" || obj.State == "paused");
                    if showIt
                        validDts = obj.DtBuffer(~isnan(obj.DtBuffer));
                        if ~isempty(validDts)
                            obj.FpsTextH.String = sprintf("%.0f fps", 1 / mean(validDts));
                        end
                        obj.FpsTextH.Visible = "on";
                    else
                        obj.FpsTextH.Visible = "off";
                    end
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

            obj.ActiveGame.DtScale = obj.RawDt * obj.ActiveGame.RefFPS;
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
            %onKeyPress  Route key events — exact GestureMouse pattern.
            %   1. Try modifier+key (shift+X, alt+X)
            %   2. If not handled, try plain key
            key = string(evnt.Key);

            % Ignore modifier-only presses
            if any(key == ["shift", "alt", "control"]); return; end

            % Try modifier+key first
            if ~isempty(evnt.Modifier)
                if any(strcmp(evnt.Modifier, "shift"))
                    if ~(strlength(key) == 1 && key >= "1" && key <= "9")
                        shiftMap = dictionary( ...
                            ["!", "@", """", "#", "£", "$", "%", "^", "&", "*"], ...
                            ["1", "2",  "2",  "3", "3",  "4", "5",  "6", "7", "8"]);
                        ch = string(evnt.Character);
                        if shiftMap.isKey(ch)
                            key = shiftMap(ch);
                        end
                    end
                    if obj.dispatchKey("shift+" + key); return; end
                elseif any(strcmp(evnt.Modifier, "alt"))
                    if obj.dispatchKey("alt+" + key); return; end
                end
            end

            % Fall back to plain key
            obj.dispatchKey(string(evnt.Key));
        end

        function handled = dispatchKey(obj, key)
            %dispatchKey  Route a key string to the state machine.
            %   Returns true if consumed. Called twice per keypress:
            %   first with modifier+key, then with plain key (fallback).
            handled = true;
            switch obj.State
                case "menu"
                    if key == "uparrow"
                        obj.KeyboardMode = true;
                        obj.Menu.moveSelection(-1);
                    elseif key == "downarrow"
                        obj.KeyboardMode = true;
                        obj.Menu.moveSelection(1);
                    elseif key == "return" || key == "space"
                        obj.Menu.confirmSelection();
                    elseif key == "escape"
                        obj.close();
                    else
                        handled = false;
                    end

                case "countdown"
                    if key == "escape"
                        obj.enterMenu();
                    else
                        handled = false;
                    end

                case "active"
                    if key == "p"
                        obj.enterPaused();
                    elseif key == "r"
                        obj.restartGame();
                    elseif key == "escape"
                        obj.enterResults();
                    else
                        gameHandled = false;
                        if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                            gameHandled = obj.ActiveGame.onKeyPress(key);
                        end
                        if ~gameHandled
                            obj.handleArrowPress(key);
                        end
                        handled = gameHandled;
                    end

                case "paused"
                    if key == "p"
                        obj.enterActive();
                    elseif key == "r"
                        obj.restartGame();
                    elseif key == "escape"
                        obj.enterResults();
                    else
                        handled = false;
                    end

                case "results"
                    if key == "r" || key == "return" || key == "space"
                        obj.playAgain();
                    elseif key == "escape"
                        obj.enterMenu();
                    else
                        handled = false;
                    end

                otherwise
                    handled = false;
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
                obj.Menu.scaleFonts();
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
                obj.StatusTextH.FontSize = max(14, round(30 * obj.getPixelScale() * scale));
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
                obj.StatusTextH.FontSize = max(14, round(16 * obj.getPixelScale()));
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
                obj.StatusTextH.FontSize = max(14, round(16 * obj.getPixelScale()));
                obj.StatusTextH.Color = obj.ColorGold;
                obj.StatusTextH.Visible = "on";
            end

            if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                obj.ComboTextH.Position = [cx, cy + diff(dy) * 0.02, 0];
                obj.ComboTextH.HorizontalAlignment = "center";
                detailLines = {};
                % Line 1: game-specific details
                if isfield(results, "Lines") && ~isempty(results.Lines)
                    detailLines = cellstr(results.Lines);
                end
                % Line 2: score / combo / time
                elapsed = toc(obj.SessionStartTic);
                detailLines{end + 1} = sprintf( ...
                    "Score: %d  |  Max Combo: %d  |  Time: %.0fs", ...
                    obj.Score, obj.MaxCombo, elapsed);
                % Line 3: high score
                if strlength(gameId) > 0
                    [isNewHigh, ~] = ScoreManager.submit( ...
                        gameId, obj.Score, obj.MaxCombo, elapsed);
                    if isNewHigh
                        detailLines{end + 1} = sprintf( ...
                            "★  NEW HIGH SCORE: %d  ★", obj.Score);
                    else
                        hsRec = ScoreManager.get(gameId);
                        detailLines{end + 1} = sprintf( ...
                            "High Score: %d", hsRec.highScore);
                    end
                end
                detailLines{end + 1} = "";
                detailLines{end + 1} = "[R] PLAY AGAIN   |   [ESC] MENU";
                obj.ComboTextH.String = strjoin(string(detailLines), newline);
                obj.ComboTextH.FontSize = max(8, round(7 * obj.getPixelScale()));
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

            % Bring HUD text to front (above game graphics)
            hudHandles = {obj.ScoreTextH, obj.ComboTextH, ...
                obj.StatusTextH, obj.HudTextH, obj.FpsTextH};
            for k = 1:numel(hudHandles)
                h = hudHandles{k};
                if ~isempty(h) && isvalid(h)
                    uistack(h, "top");
                end
            end
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

            obj.FpsTextH = text(ax, dx(2) - 4, dy(1) + 2, "", ...
                "Color", obj.ColorGreen * 0.9, "FontSize", 14, ...
                "FontWeight", "bold", ...
                "HorizontalAlignment", "right", ...
                "VerticalAlignment", "top", "Visible", "off", ...
                "Tag", "GT_arcFps");
        end

        function ps = getPixelScale(obj)
            %getPixelScale  Deterministic scale from current axes vs 854x480.
            if isempty(obj.Ax) || ~isvalid(obj.Ax)
                ps = 1.0;
                return;
            end
            axPx = getpixelposition(obj.Ax);
            ps = min(axPx(3) / 854, axPx(4) / 480);
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
            if ~any(obj.ArrowHeld) && obj.State ~= "menu"
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
            obj.ComboTextH.FontSize = max(8, round(7 * obj.getPixelScale()));
            cx = mean(obj.DisplayRange.X);
            obj.ComboTextH.Position = [cx, obj.DisplayRange.Y(1) + 2, 0];
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
    % PROTECTED — Game Registry (override in subclasses)
    % =================================================================
    methods (Access = protected)

        function [t, s] = getMenuTitles(~)
            %getMenuTitles  Return title and subtitle for the menu screen.
            t = "A  R  C  A  D  E";
            s = "S E L E C T   G A M E";
        end

        function buildRegistry(obj)
            %buildRegistry  Register all available games with key bindings.
            obj.Registry = dictionary;
            obj.RegistryOrder = strings(0);

            % === Classics first ===
            obj.registerGame("1", @games.Pong, "Pong");
            obj.registerGame("2", @games.Breakout, "Breakout");
            obj.registerGame("3", @games.Snake, "Snake");
            obj.registerGame("4", @games.Tetris, "Tetris");
            obj.registerGame("5", @games.Asteroids, "Asteroids");
            obj.registerGame("6", @games.SpaceInvaders, "Space Invaders");
            obj.registerGame("7", @games.FlappyBird, "Flappy Bird");
            obj.registerGame("8", @games.FruitNinja, "Fruit Ninja");
            % === Originals ===
            obj.registerGame("9", @games.TargetPractice, "Target Practice");
            obj.registerGame("10", @games.Fireflies, "Fireflies");
            obj.registerGame("11", @games.FlickIt, "Flick It");
            obj.registerGame("12", @games.Juggling, "Juggling");
            obj.registerGame("13", @games.OrbitalDefense, "Orbital Defense");
            obj.registerGame("14", @games.ShieldGuardian, "Shield Guardian");
            obj.registerGame("15", @games.RailShooter, "Rail Shooter");
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
