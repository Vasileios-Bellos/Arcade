classdef (Sealed) ArcadeGameLauncher < handle
    %ArcadeGameLauncher  Standalone arcade-style game launcher with mouse input.
    %   Full-featured arcade experience: game menu, 3-2-1 countdown, HUD with
    %   score roll-up and combo display, pause/reset/results screens. Hosts the
    %   same GameBase games used by GestureMouse's GameHost, but driven by mouse
    %   input in a standalone figure — no webcam or GestureMouse required.
    %
    %   Usage:
    %       ArcadeGameLauncher.launch()     % opens arcade
    %
    %   Controls:
    %       Menu:   Game keys to select, Escape to quit
    %       Active: P = pause, R/0 = restart, Escape = end (results)
    %       Paused: P = resume, R/0 = restart, Escape = end (results)
    %       Results: Any key = back to menu
    %
    %   See also GameBase, GameHost, GestureMouse

    % =================================================================
    % CORE STATE
    % =================================================================
    properties (SetAccess = private)
        Fig                                     % figure handle
        Ax                                      % axes handle
        RenderTimer                             % timer for frame loop
        MousePos        (1,2) double = [320, 240]

        ActiveGame                              % current GameBase subclass (or [])
        ActiveGameName  string = ""
        State           (1,1) string = "menu"   % menu|countdown|active|paused|results

        % Game registry: key -> struct(ctor, name, key)
        Registry        dictionary

        % Display
        DisplayRange    struct = struct("X", [0 640], "Y", [0 480])
    end

    % =================================================================
    % HUD HANDLES
    % =================================================================
    properties (SetAccess = private)
        TitleTextH                              % text — arcade title
        MenuTextH                               % text — game list
        ScoreTextH                              % text — top-left score
        ComboTextH                              % text — combo display
        StatusTextH                             % text — center (countdown/pause/results)
        HudTextH                                % text — bottom HUD from game
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
    % SESSION STATE
    % =================================================================
    properties (SetAccess = private)
        SessionStartTic
    end

    % =================================================================
    % COLOR CONSTANTS
    % =================================================================
    properties (Constant, Access = private)
        ColorCyan   (1,3) double = [0, 0.92, 1]
        ColorGreen  (1,3) double = [0.2, 1, 0.4]
        ColorGold   (1,3) double = [1, 0.85, 0.2]
        ColorRed    (1,3) double = [1, 0.3, 0.2]
        ColorWhite  (1,3) double = [1, 1, 1]
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
            %run  Create figure, registry, HUD, and start game loop.
            obj.createFigure();
            obj.buildRegistry();
            obj.createHUD();
            obj.enterMenu();
            obj.startTimer();
        end

        function close(obj)
            %close  Shut down arcade: stop timer, clean up game, delete figure.
            % Stop timer
            if ~isempty(obj.RenderTimer) && isvalid(obj.RenderTimer)
                stop(obj.RenderTimer);
                delete(obj.RenderTimer);
            end
            obj.RenderTimer = [];

            % Clean up active game
            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                try
                    obj.ActiveGame.onCleanup();
                    obj.ActiveGame.cleanupHitEffects();
                catch
                end
                obj.ActiveGame = [];
            end

            % Delete figure
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
            %createFigure  Create fullscreen figure with axes.
            obj.Fig = figure("Color", "k", "WindowState", "maximized", ...
                "MenuBar", "none", "ToolBar", "none", ...
                "Name", "Arcade Game Launcher", "NumberTitle", "off");

            obj.Ax = axes(obj.Fig, "Position", [0 0 1 1], "Color", "k", ...
                "XLim", obj.DisplayRange.X, "YLim", obj.DisplayRange.Y, ...
                "YDir", "reverse", "Visible", "off", "XTick", [], "YTick", []);
            hold(obj.Ax, "on");

            % Mouse tracking
            obj.Fig.WindowButtonMotionFcn = @(~, ~) obj.onMouseMove();

            % Key handling
            obj.Fig.KeyPressFcn = @(~, e) obj.onKeyPress(e);

            % Close handler
            obj.Fig.CloseRequestFcn = @(~, ~) obj.close();
        end

        function startTimer(obj)
            %startTimer  Start the physics/render timer (50 Hz).
            obj.RenderTimer = timer("ExecutionMode", "fixedSpacing", ...
                "Period", 0.02, "TimerFcn", @(~, ~) obj.onFrame(), ...
                "ErrorFcn", @(~, e) fprintf(2, "[Arcade] %s\n", e.Data.message));
            start(obj.RenderTimer);
        end

        function onMouseMove(obj)
            %onMouseMove  Update mouse position from axes CurrentPoint.
            if isempty(obj.Ax) || ~isvalid(obj.Ax); return; end
            cp = get(obj.Ax, "CurrentPoint");
            obj.MousePos = cp(1, 1:2);
        end
    end

    % =================================================================
    % PRIVATE — Frame Loop
    % =================================================================
    methods (Access = private)

        function onFrame(obj)
            %onFrame  Main frame callback — dispatches to state handler.
            if isempty(obj.Fig) || ~isvalid(obj.Fig); return; end

            switch obj.State
                case "menu"
                    % Static menu — nothing to update
                case "countdown"
                    obj.updateCountdown();
                case "active"
                    obj.updateActive();
                case "paused"
                    % Static pause — nothing to update
                case "results"
                    % Static results — nothing to update
            end

            % Combo fade animation
            obj.updateComboFade();

            % Score roll-up
            if obj.ScoreDisplayed < obj.Score
                gap = obj.Score - obj.ScoreDisplayed;
                obj.ScoreDisplayed = min(obj.ScoreDisplayed ...
                    + max(obj.ScoreRollSpeed, gap * 0.3), obj.Score);
                obj.updateScoreText();
            end

            drawnow;
        end

        function updateActive(obj)
            %updateActive  Per-frame update during active gameplay.
            if isempty(obj.ActiveGame) || ~isvalid(obj.ActiveGame)
                return;
            end

            obj.ActiveGame.onUpdate(obj.MousePos);
            obj.ActiveGame.updateHitEffects();

            % Sync score/combo from game
            obj.Score = obj.ActiveGame.Score;
            obj.Combo = obj.ActiveGame.Combo;
            obj.MaxCombo = max(obj.MaxCombo, obj.ActiveGame.MaxCombo);

            % Update combo display
            if obj.Combo >= 2
                obj.showCombo();
            elseif obj.Combo == 0 && ~isempty(obj.ComboShowTic)
                obj.ComboFadeTic = tic;
                obj.ComboFadeColor = obj.ColorGreen * 0.9;
                obj.ComboShowTic = [];
            end

            % Update HUD text from game
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

            % Build modifier+key string (matches GameHost/GestureMouse pattern)
            if ~isempty(evnt.Modifier)
                mods = string(evnt.Modifier);
                if any(mods == "shift")
                    key = "shift+" + key;
                elseif any(mods == "alt")
                    key = "alt+" + key;
                end
            end

            switch obj.State
                case "menu"
                    if obj.Registry.isKey(key)
                        obj.PendingGameKey = key;
                        obj.enterCountdown();
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
                    elseif key == "r" || key == "0"
                        obj.restartGame();
                    elseif key == "escape"
                        obj.enterResults();
                    else
                        % Forward to game
                        if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                            obj.ActiveGame.onKeyPress(key);
                        end
                    end

                case "paused"
                    if key == "p"
                        obj.enterActive();
                    elseif key == "r" || key == "0"
                        obj.restartGame();
                    elseif key == "escape"
                        obj.enterResults();
                    end

                case "results"
                    obj.enterMenu();
            end
        end
    end

    % =================================================================
    % PRIVATE — State Machine
    % =================================================================
    methods (Access = private)

        function enterMenu(obj)
            %enterMenu  Show game selection menu.
            obj.State = "menu";

            % Clean up any active game
            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                try
                    obj.ActiveGame.onCleanup();
                    obj.ActiveGame.cleanupHitEffects();
                catch
                end
                obj.ActiveGame = [];
            end

            % Orphan cleanup (preserve HUD)
            obj.cleanupOrphans();

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cx = mean(dx);
            cy = mean(dy);

            % Title
            if ~isempty(obj.TitleTextH) && isvalid(obj.TitleTextH)
                obj.TitleTextH.Position = [cx, cy - diff(dy) * 0.15, 0];
                obj.TitleTextH.String = "ARCADE";
                obj.TitleTextH.Visible = "on";
            end

            % Game list
            if ~isempty(obj.MenuTextH) && isvalid(obj.MenuTextH)
                obj.MenuTextH.Position = [cx, cy + diff(dy) * 0.02, 0];
                obj.MenuTextH.String = obj.buildMenuText();
                obj.MenuTextH.Visible = "on";
            end

            % Hide gameplay HUD
            obj.hideGameplayHUD();
        end

        function enterCountdown(obj)
            %enterCountdown  Start 3-2-1 countdown before game.
            obj.State = "countdown";
            obj.CountdownValue = 3;
            obj.CountdownFrames = 25;

            % Reset session
            obj.Score = 0;
            obj.ScoreDisplayed = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;
            obj.SessionStartTic = tic;
            obj.ComboShowTic = [];
            obj.ComboFadeTic = [];

            % Hide menu
            if ~isempty(obj.TitleTextH) && isvalid(obj.TitleTextH)
                obj.TitleTextH.Visible = "off";
            end
            if ~isempty(obj.MenuTextH) && isvalid(obj.MenuTextH)
                obj.MenuTextH.Visible = "off";
            end

            % Show score
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
            alpha = 1 - max(0, progress - 0.7) / 0.3;

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
                obj.StatusTextH.Color = [obj.ColorCyan, max(alpha, 0)];
                obj.StatusTextH.Visible = "on";
            end

            if obj.CountdownFrames <= 0
                if obj.CountdownValue > 0
                    obj.CountdownValue = obj.CountdownValue - 1;
                    if obj.CountdownValue > 0
                        obj.CountdownFrames = totalPerNum;
                    else
                        obj.CountdownFrames = 12;  % "GO!" duration
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

            % Get results before cleanup
            results = struct("Title", "GAME OVER", "Lines", {{}});
            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
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

            % Orphan cleanup
            obj.cleanupOrphans();

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cx = mean(dx);
            cy = mean(dy);

            % Title
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

            % Details
            if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                obj.ComboTextH.Position = [cx, cy + diff(dy) * 0.02, 0];
                obj.ComboTextH.HorizontalAlignment = "center";
                detailLines = {};
                if isfield(results, "Lines")
                    detailLines = results.Lines;
                end
                elapsed = toc(obj.SessionStartTic);
                detailLines{end + 1} = sprintf( ...
                    "Score: %d  |  Max Combo: %d  |  Time: %.0fs", ...
                    obj.Score, obj.MaxCombo, elapsed);
                detailLines{end + 1} = "";
                detailLines{end + 1} = "Press any key to continue";
                obj.ComboTextH.String = strjoin(detailLines, newline);
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
            ctor = entry.ctor;
            obj.ActiveGameName = entry.name;

            % Instantiate game (no caps — standalone, no GestureMouse)
            game = ctor();
            game.onInit(obj.Ax, obj.DisplayRange, struct());
            game.StartTic = tic;
            game.IsRunning = true;
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
    end

    % =================================================================
    % PRIVATE — HUD Management
    % =================================================================
    methods (Access = private)

        function createHUD(obj)
            %createHUD  Create persistent HUD text objects.
            ax = obj.Ax;
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cx = mean(dx);

            % Arcade title (menu only)
            obj.TitleTextH = text(ax, cx, mean(dy), "ARCADE", ...
                "Color", obj.ColorCyan * 0.95, "FontSize", 42, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_arcTitle");

            % Menu text (game list)
            obj.MenuTextH = text(ax, cx, mean(dy), "", ...
                "Color", obj.ColorWhite * 0.7, "FontSize", 14, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "top", "Visible", "off", ...
                "Tag", "GT_arcMenu");

            % Score text (top left)
            obj.ScoreTextH = text(ax, dx(1) + 4, dy(1) + 2, "Score: 0", ...
                "Color", obj.ColorGreen * 0.9, "FontSize", 14, ...
                "FontWeight", "bold", "HorizontalAlignment", "left", ...
                "VerticalAlignment", "top", "Visible", "off", ...
                "Tag", "GT_arcScore");

            % Combo text (below score / center for results)
            obj.ComboTextH = text(ax, cx, dy(1) + 34, "", ...
                "Color", obj.ColorGold * 0.8, "FontSize", 13, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "top", "Visible", "off", ...
                "Tag", "GT_arcCombo");

            % Status text (center — countdown/pause/results)
            obj.StatusTextH = text(ax, cx, mean(dy), "", ...
                "Color", obj.ColorCyan * 0.95, "FontSize", 28, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_arcStatus");

            % HUD text (bottom center — game-specific)
            obj.HudTextH = text(ax, cx, dy(2) - 8, "", ...
                "Color", obj.ColorWhite * 0.7, "FontSize", 11, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", "Visible", "off", ...
                "Tag", "GT_arcHud");
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
            if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH)
                return;
            end
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
            else
                alpha = max(0, 1 - elapsed / fadeDur);
                obj.ComboTextH.Color = [obj.ComboFadeColor, alpha];
            end
        end

        function cleanupOrphans(obj)
            %cleanupOrphans  Delete game graphics, preserving HUD.
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

            % === Games registered here as they are extracted ===
            obj.registerGame("1", @games.Pointing, "Pointing");
        end

        function registerGame(obj, key, ctor, name)
            %registerGame  Add a game to the registry.
            entry.ctor = ctor;
            entry.name = name;
            entry.key = key;
            obj.Registry(key) = entry;
        end

        function lines = buildMenuText(obj)
            %buildMenuText  Build multi-line menu from registry.
            if obj.Registry.numEntries == 0
                lines = "No games available";
                return;
            end
            keys = obj.Registry.keys;
            parts = strings(1, numel(keys));
            for k = 1:numel(keys)
                entry = obj.Registry(keys(k));
                parts(k) = upper(entry.key) + "  —  " + entry.name;
            end
            lines = strjoin(parts, newline) + newline + newline ...
                + "ESC  —  Quit";
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
