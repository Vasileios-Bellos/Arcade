classdef (Sealed) ArcadeGameLauncher < handle
    %ArcadeGameLauncher  Standalone arcade-style game launcher with mouse input.
    %   Full-featured arcade experience: visual game menu with hover selection,
    %   3-2-1 countdown, HUD with score roll-up and combo display, pause/reset/
    %   results screens. Hosts the same GameBase games used by GestureMouse's
    %   GameHost, but driven by mouse input — no webcam required.
    %
    %   Usage:
    %       ArcadeGameLauncher.launch()
    %
    %   Menu Controls:
    %       Click or number key to select a game
    %       ESC to quit
    %
    %   In-Game Controls:
    %       P = pause/resume, R or 0 = restart, ESC = end (results)
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
        RegistryOrder   string                  % keys in insertion order

        % Display
        DisplayRange    struct = struct("X", [0 640], "Y", [0 480])
    end

    % =================================================================
    % MENU BUTTON HANDLES
    % =================================================================
    properties (SetAccess = private)
        TitleTextH                              % text — arcade title
        FooterTextH                             % text — instructions
        MenuBtnPatches                          % patch array — button backgrounds
        MenuBtnTexts                            % text array — button labels
        MenuBtnKeys     string                  % key strings per button
        MenuBtnYTop     double                  % top Y of each button
        MenuBtnYBot     double                  % bottom Y of each button
        MenuBtnXLeft    (1,1) double = 0
        MenuBtnXRight   (1,1) double = 0
        HoveredBtn      (1,1) double = 0        % 0 = none
    end

    % =================================================================
    % HUD HANDLES
    % =================================================================
    properties (SetAccess = private)
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
            obj.createMenuButtons();
            obj.enterMenu();
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

            obj.Fig.WindowButtonMotionFcn = @(~, ~) obj.onMouseMove();
            obj.Fig.WindowButtonDownFcn = @(~, ~) obj.onMouseClick();
            obj.Fig.KeyPressFcn = @(~, e) obj.onKeyPress(e);
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

        function onMouseClick(obj)
            %onMouseClick  Handle mouse click (menu button selection).
            if obj.State ~= "menu"; return; end
            idx = obj.hitTestButtons(obj.MousePos);
            if idx > 0
                obj.PendingGameKey = obj.MenuBtnKeys(idx);
                obj.enterCountdown();
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

            switch obj.State
                case "menu"
                    obj.updateMenuHover();
                case "countdown"
                    obj.updateCountdown();
                case "active"
                    obj.updateActive();
                case "paused"
                    % Static — nothing
                case "results"
                    % Static — nothing
            end

            % Combo fade
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

            % Sync score/combo
            obj.Score = obj.ActiveGame.Score;
            obj.Combo = obj.ActiveGame.Combo;
            obj.MaxCombo = max(obj.MaxCombo, obj.ActiveGame.MaxCombo);

            if obj.Combo >= 2
                obj.showCombo();
            elseif obj.Combo == 0 && ~isempty(obj.ComboShowTic)
                obj.ComboFadeTic = tic;
                obj.ComboFadeColor = obj.ColorGreen * 0.9;
                obj.ComboShowTic = [];
            end

            % Game HUD text
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
            %enterMenu  Show game selection menu with visual buttons.
            obj.State = "menu";

            if ~isempty(obj.ActiveGame) && isvalid(obj.ActiveGame)
                try
                    obj.ActiveGame.onCleanup();
                    obj.ActiveGame.cleanupHitEffects();
                catch
                end
                obj.ActiveGame = [];
            end
            obj.cleanupOrphans();

            % Show menu elements
            if ~isempty(obj.TitleTextH) && isvalid(obj.TitleTextH)
                obj.TitleTextH.Visible = "on";
            end
            if ~isempty(obj.FooterTextH) && isvalid(obj.FooterTextH)
                obj.FooterTextH.Visible = "on";
            end
            obj.showMenuButtons();
            obj.hideGameplayHUD();
            obj.HoveredBtn = 0;
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
            obj.ComboShowTic = [];
            obj.ComboFadeTic = [];

            % Hide menu
            obj.hideMenuAll();

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
    end

    % =================================================================
    % PRIVATE — Menu Buttons
    % =================================================================
    methods (Access = private)

        function createMenuButtons(obj)
            %createMenuButtons  Build visual button rows from registry.
            ax = obj.Ax;
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cx = mean(dx);

            nGames = numel(obj.RegistryOrder);
            if nGames == 0; return; end

            btnW = min(300, diff(dx) * 0.5);
            btnH = 36;
            btnGap = 8;
            totalH = nGames * btnH + (nGames - 1) * btnGap;
            startY = mean(dy) - totalH * 0.3;

            obj.MenuBtnPatches = gobjects(nGames, 1);
            obj.MenuBtnTexts = gobjects(nGames, 1);
            obj.MenuBtnKeys = strings(nGames, 1);
            obj.MenuBtnYTop = zeros(nGames, 1);
            obj.MenuBtnYBot = zeros(nGames, 1);
            obj.MenuBtnXLeft = cx - btnW / 2;
            obj.MenuBtnXRight = cx + btnW / 2;

            for k = 1:nGames
                gameKey = obj.RegistryOrder(k);
                entry = obj.Registry(gameKey);
                yTop = startY + (k - 1) * (btnH + btnGap);
                yBot = yTop + btnH;

                xL = obj.MenuBtnXLeft;
                xR = obj.MenuBtnXRight;

                % Button background
                obj.MenuBtnPatches(k) = patch(ax, ...
                    [xL xR xR xL], [yTop yTop yBot yBot], ...
                    [0.12 0.12 0.15], "FaceAlpha", 0.8, ...
                    "EdgeColor", [0.25 0.25 0.3], "LineWidth", 1.5, ...
                    "Visible", "off", "Tag", "GT_arcBtn");

                % Button label: "[key]  Game Name"
                label = upper(entry.key) + "     " + entry.name;
                obj.MenuBtnTexts(k) = text(ax, ...
                    xL + 16, (yTop + yBot) / 2, label, ...
                    "Color", obj.ColorWhite * 0.65, "FontSize", 14, ...
                    "FontWeight", "bold", "HorizontalAlignment", "left", ...
                    "VerticalAlignment", "middle", "Visible", "off", ...
                    "Tag", "GT_arcBtn");

                obj.MenuBtnKeys(k) = gameKey;
                obj.MenuBtnYTop(k) = yTop;
                obj.MenuBtnYBot(k) = yBot;
            end
        end

        function showMenuButtons(obj)
            %showMenuButtons  Make all menu buttons visible.
            for k = 1:numel(obj.MenuBtnPatches)
                if ~isempty(obj.MenuBtnPatches(k)) && isvalid(obj.MenuBtnPatches(k))
                    obj.MenuBtnPatches(k).Visible = "on";
                end
            end
            for k = 1:numel(obj.MenuBtnTexts)
                if ~isempty(obj.MenuBtnTexts(k)) && isvalid(obj.MenuBtnTexts(k))
                    obj.MenuBtnTexts(k).Visible = "on";
                end
            end
        end

        function hideMenuAll(obj)
            %hideMenuAll  Hide title, footer, and all menu buttons.
            if ~isempty(obj.TitleTextH) && isvalid(obj.TitleTextH)
                obj.TitleTextH.Visible = "off";
            end
            if ~isempty(obj.FooterTextH) && isvalid(obj.FooterTextH)
                obj.FooterTextH.Visible = "off";
            end
            for k = 1:numel(obj.MenuBtnPatches)
                if ~isempty(obj.MenuBtnPatches(k)) && isvalid(obj.MenuBtnPatches(k))
                    obj.MenuBtnPatches(k).Visible = "off";
                end
            end
            for k = 1:numel(obj.MenuBtnTexts)
                if ~isempty(obj.MenuBtnTexts(k)) && isvalid(obj.MenuBtnTexts(k))
                    obj.MenuBtnTexts(k).Visible = "off";
                end
            end
        end

        function updateMenuHover(obj)
            %updateMenuHover  Highlight button under mouse cursor.
            newHover = obj.hitTestButtons(obj.MousePos);

            if newHover == obj.HoveredBtn; return; end

            % Un-hover previous
            if obj.HoveredBtn > 0 && obj.HoveredBtn <= numel(obj.MenuBtnPatches)
                k = obj.HoveredBtn;
                if isvalid(obj.MenuBtnPatches(k))
                    obj.MenuBtnPatches(k).FaceColor = [0.12 0.12 0.15];
                    obj.MenuBtnPatches(k).EdgeColor = [0.25 0.25 0.3];
                end
                if isvalid(obj.MenuBtnTexts(k))
                    obj.MenuBtnTexts(k).Color = obj.ColorWhite * 0.65;
                end
            end

            % Hover new
            if newHover > 0 && newHover <= numel(obj.MenuBtnPatches)
                k = newHover;
                if isvalid(obj.MenuBtnPatches(k))
                    obj.MenuBtnPatches(k).FaceColor = [0.18 0.22 0.28];
                    obj.MenuBtnPatches(k).EdgeColor = obj.ColorCyan * 0.5;
                end
                if isvalid(obj.MenuBtnTexts(k))
                    obj.MenuBtnTexts(k).Color = obj.ColorCyan;
                end
            end

            obj.HoveredBtn = newHover;
        end

        function idx = hitTestButtons(obj, pos)
            %hitTestButtons  Return index of button under pos, or 0.
            idx = 0;
            mx = pos(1); my = pos(2);
            if mx < obj.MenuBtnXLeft || mx > obj.MenuBtnXRight
                return;
            end
            for k = 1:numel(obj.MenuBtnYTop)
                if my >= obj.MenuBtnYTop(k) && my <= obj.MenuBtnYBot(k)
                    idx = k;
                    return;
                end
            end
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
            cy = mean(dy);

            % Arcade title
            obj.TitleTextH = text(ax, cx, cy - diff(dy) * 0.18, "ARCADE", ...
                "Color", obj.ColorCyan * 0.95, "FontSize", 42, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_arcTitle");

            % Footer instructions
            obj.FooterTextH = text(ax, cx, dy(2) - 20, ...
                "Click or press number to play  |  ESC: Quit", ...
                "Color", obj.ColorWhite * 0.4, "FontSize", 11, ...
                "FontWeight", "normal", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", "Visible", "off", ...
                "Tag", "GT_arcFooter");

            % Score text (top left)
            obj.ScoreTextH = text(ax, dx(1) + 4, dy(1) + 2, "Score: 0", ...
                "Color", obj.ColorGreen * 0.9, "FontSize", 14, ...
                "FontWeight", "bold", "HorizontalAlignment", "left", ...
                "VerticalAlignment", "top", "Visible", "off", ...
                "Tag", "GT_arcScore");

            % Combo text
            obj.ComboTextH = text(ax, cx, dy(1) + 34, "", ...
                "Color", obj.ColorGold * 0.8, "FontSize", 13, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "top", "Visible", "off", ...
                "Tag", "GT_arcCombo");

            % Status text (center)
            obj.StatusTextH = text(ax, cx, cy, "", ...
                "Color", obj.ColorCyan * 0.95, "FontSize", 28, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_arcStatus");

            % Game HUD text (bottom)
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
                alpha = max(0, 1 - elapsed / fadeDur);
                obj.ComboTextH.Color = [obj.ComboFadeColor, alpha];
            end
        end

        function cleanupOrphans(obj)
            %cleanupOrphans  Delete game graphics, preserving arcade HUD.
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

            % === Games registered here as they are extracted ===
            obj.registerGame("1", @games.Pointing, "Pointing");
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
