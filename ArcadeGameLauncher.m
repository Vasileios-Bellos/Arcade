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
    %   See also GameBase, GameHost, GestureMouse

    % =================================================================
    % CORE STATE
    % =================================================================
    properties (SetAccess = private)
        Fig                                     % figure handle
        Ax                                      % axes handle
        RenderTimer                             % timer for frame loop
        MousePos        (1,2) double = [NaN, NaN]

        ActiveGame                              % current GameBase subclass (or [])
        ActiveGameName  string = ""
        State           (1,1) string = "menu"   % menu|countdown|active|paused|results

        % Game registry: key -> struct(ctor, name, key)
        Registry        dictionary
        RegistryOrder   string                  % keys in insertion order
    end

    % =================================================================
    % MENU GRAPHICS — all axes-based, no UI widgets
    % =================================================================
    properties (SetAccess = private)
        % Title
        TitleGlowH                              % text — glow shadow (right offset)
        TitleMainH                              % text — bright neon title

        % Subtitle + accents
        SubtitleTextH                           % text — "SELECT GAME" spaced
        DecoLineGlowH                          % line — accent glow (wide, faint)
        DecoLineCoreH                           % line — accent core (thin, bright)
        FooterTextH                             % text — instructions at bottom

        % Starfield
        StarfieldH                              % scatter — subtle background dots

        % Game list item slots (MaxVisibleItems graphics sets)
        MenuItemBg                              % cell of patch — pill backgrounds
        MenuItemGlow                            % cell of patch — outer glow
        MenuItemKeyBg                           % cell of patch — key badge pill
        MenuItemKeyText                         % cell of text — key labels
        MenuItemNameText                        % cell of text — game names
        NumSlots        (1,1) double = 0        % actual number of created slots

        % Selection + scroll
        SelectedIdx     (1,1) double = 1        % absolute game index (1-based)
        ScrollOffset    (1,1) double = 0        % first visible game index (0-based)
        ScrollTrackH                            % line — scroll track (right side)
        ScrollThumbH                            % patch — scroll thumb

        % Scroll drag state
        ScrollDragging  (1,1) logical = false   % true while dragging thumb
        ScrollDragStartY (1,1) double = 0       % mouse Y at drag start
        ScrollDragStartOffset (1,1) double = 0  % ScrollOffset at drag start
    end

    % =================================================================
    % DISPLAY
    % =================================================================
    properties (SetAccess = private)
        DisplayRange    struct = struct("X", [0 640], "Y", [0 480])
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
    % SCORING STATE
    % =================================================================
    properties (SetAccess = private)
        Score           (1,1) double = 0
        ScoreDisplayed  (1,1) double = 0
        ScoreRollSpeed  (1,1) double = 3
        Combo           (1,1) double = 0
        MaxCombo        (1,1) double = 0

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
    % MENU LAYOUT CONSTANTS
    % =================================================================
    properties (Constant, Access = private)
        ItemWidth       = 180
        ItemHeight      = 40
        ItemGap         = 10
        ItemCornerR     = 20          % half height = full pill shape
        KeyBadgeSz      = 28          % circle diameter
        MaxVisibleItems = 6
        ItemListTopFrac = 0.30        % fraction of display range for list top
    end

    % =================================================================
    % COLOR CONSTANTS
    % =================================================================
    properties (Constant, Access = private)
        BgColor     (1,3) double = [0.015, 0.015, 0.03]
        ColorCyan   (1,3) double = [0, 0.92, 1]
        ColorTeal   (1,3) double = [0.08, 0.55, 0.70]
        ColorGreen  (1,3) double = [0.2, 1, 0.4]
        ColorGold   (1,3) double = [1, 0.85, 0.2]
        ColorRed    (1,3) double = [1, 0.3, 0.2]
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
            obj.buildRegistry();
            obj.createFigure();
            obj.createHUD();
            obj.createMenu();
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

            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                obj.Fig.CloseRequestFcn = "closereq";
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
                "KeyPressFcn", @(~, e) obj.onKeyPress(e));

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
            hold(obj.Ax, "on");
        end

        function computeDisplayRange(obj)
            %computeDisplayRange  Set display range to match figure aspect ratio.
            %   Keeps Y fixed at 480, scales X proportionally so 1 data unit
            %   is the same physical size in both axes (circles stay circular).
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
            cp = get(obj.Ax, "CurrentPoint");
            obj.MousePos = cp(1, 1:2);

            if obj.ScrollDragging && obj.State == "menu"
                obj.handleScrollDrag();
            end
        end

        function onMouseDown(obj)
            %onMouseDown  Click on game item or start scroll thumb drag.
            if obj.State ~= "menu"; return; end
            if any(isnan(obj.MousePos)); return; end
            nGames = numel(obj.RegistryOrder);
            if nGames == 0; return; end

            % Check scroll thumb hit first
            if nGames > obj.MaxVisibleItems && obj.hitTestScrollThumb()
                obj.ScrollDragging = true;
                obj.ScrollDragStartY = obj.MousePos(2);
                obj.ScrollDragStartOffset = obj.ScrollOffset;
                return;
            end

            mx = obj.MousePos(1);
            my = obj.MousePos(2);
            dy = obj.DisplayRange.Y;
            cx = mean(obj.DisplayRange.X);
            rangeH = diff(dy);

            listTop = dy(1) + rangeH * obj.ItemListTopFrac;
            iW = obj.ItemWidth;
            iH = obj.ItemHeight;
            iGap = obj.ItemGap;

            for slot = 1:obj.NumSlots
                gameIdx = obj.ScrollOffset + slot;
                if gameIdx > nGames; break; end
                yTop = listTop + (slot - 1) * (iH + iGap);
                yBot = yTop + iH;
                xLeft = cx - iW / 2;
                xRight = cx + iW / 2;
                if mx >= xLeft && mx <= xRight && my >= yTop && my <= yBot
                    obj.SelectedIdx = gameIdx;
                    obj.PendingGameKey = obj.RegistryOrder(gameIdx);
                    obj.enterCountdown();
                    return;
                end
            end
        end

        function onMouseUp(obj)
            %onMouseUp  End scroll thumb drag.
            obj.ScrollDragging = false;
        end

        function onScrollWheel(obj, evnt)
            %onScrollWheel  Scroll game list with mouse wheel.
            if obj.State ~= "menu"; return; end
            nGames = numel(obj.RegistryOrder);
            maxVis = obj.MaxVisibleItems;
            if nGames <= maxVis; return; end

            delta = round(evnt.VerticalScrollCount);
            obj.ScrollOffset = max(0, min(obj.ScrollOffset + delta, ...
                nGames - maxVis));

            % Keep selection in visible window
            if obj.SelectedIdx <= obj.ScrollOffset
                obj.SelectedIdx = obj.ScrollOffset + 1;
            elseif obj.SelectedIdx > obj.ScrollOffset + maxVis
                obj.SelectedIdx = obj.ScrollOffset + maxVis;
            end

            obj.updateSlotContent();
            obj.updateSlotHighlight();
            obj.updateScrollThumb();
        end

        function hit = hitTestScrollThumb(obj)
            %hitTestScrollThumb  Check if mouse is over the scroll thumb.
            hit = false;
            if isempty(obj.ScrollThumbH) || ~isvalid(obj.ScrollThumbH); return; end
            if obj.ScrollThumbH.Visible == "off"; return; end

            mx = obj.MousePos(1);
            my = obj.MousePos(2);
            tx = obj.ScrollThumbH.XData;
            ty = obj.ScrollThumbH.YData;

            if mx >= min(tx) - 5 && mx <= max(tx) + 5 ...
                    && my >= min(ty) && my <= max(ty)
                hit = true;
            end
        end

        function handleScrollDrag(obj)
            %handleScrollDrag  Update scroll offset from thumb drag motion.
            nGames = numel(obj.RegistryOrder);
            maxVis = obj.MaxVisibleItems;
            maxOff = nGames - maxVis;
            if maxOff <= 0; return; end

            % Compute track geometry
            dy = obj.DisplayRange.Y;
            rangeH = diff(dy);
            listTop = dy(1) + rangeH * obj.ItemListTopFrac;
            iH = obj.ItemHeight;
            iGap = obj.ItemGap;
            trackTop = listTop + 4;
            trackBot = listTop + obj.NumSlots * (iH + iGap) - iGap - 4;
            trackH = trackBot - trackTop;
            thumbH = max(15, trackH * maxVis / nGames);
            scrollableH = trackH - thumbH;
            if scrollableH <= 0; return; end

            % Map mouse delta to scroll offset
            deltaY = obj.MousePos(2) - obj.ScrollDragStartY;
            deltaFrac = deltaY / scrollableH;
            newOffset = round(obj.ScrollDragStartOffset + deltaFrac * maxOff);
            newOffset = max(0, min(newOffset, maxOff));

            if newOffset ~= obj.ScrollOffset
                obj.ScrollOffset = newOffset;

                % Keep selection in visible window
                if obj.SelectedIdx <= obj.ScrollOffset
                    obj.SelectedIdx = obj.ScrollOffset + 1;
                elseif obj.SelectedIdx > obj.ScrollOffset + maxVis
                    obj.SelectedIdx = obj.ScrollOffset + maxVis;
                end

                obj.updateSlotContent();
                obj.updateSlotHighlight();
                obj.updateScrollThumb();
            end
        end

        function onFigResize(obj)
            %onFigResize  Recompute display range and rebuild menu on resize.
            if isempty(obj.Fig) || ~isvalid(obj.Fig); return; end
            if isempty(obj.Ax) || ~isvalid(obj.Ax); return; end

            obj.computeDisplayRange();
            obj.Ax.XLim = obj.DisplayRange.X;
            obj.Ax.YLim = obj.DisplayRange.Y;

            % Only rebuild menu graphics when in menu state
            if obj.State ~= "menu"; return; end

            % Stop timer during rebuild to prevent re-entrant onFrame
            if ~isempty(obj.RenderTimer) && isvalid(obj.RenderTimer) ...
                    && strcmp(obj.RenderTimer.Running, "on")
                stop(obj.RenderTimer);
                restartTimer = true;
            else
                restartTimer = false;
            end

            % Delete and recreate all arcade menu graphics
            arcObjs = findall(obj.Ax, "-regexp", "Tag", "^GT_arc");
            if ~isempty(arcObjs); delete(arcObjs); end

            obj.createHUD();
            obj.createMenu();
            obj.setMenuVisible("on");
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

            switch obj.State
                case "menu"
                    obj.updateMenuAnim();
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
        end

        function updateMenuAnim(obj)
            %updateMenuAnim  Animate selected glow pulse + title shimmer.
            if isempty(obj.SessionStartTic); return; end
            t = toc(obj.SessionStartTic);

            % Mouse hover detection
            obj.updateMouseHover();

            % Selected item glow pulse
            slotIdx = obj.SelectedIdx - obj.ScrollOffset;
            if slotIdx >= 1 && slotIdx <= obj.NumSlots
                g = obj.MenuItemGlow{slotIdx};
                if ~isempty(g) && isvalid(g)
                    pulse = 0.10 + 0.06 * sin(t * 3.5);
                    g.FaceAlpha = pulse;
                end
            end

            % Title hue shimmer
            if ~isempty(obj.TitleMainH) && isvalid(obj.TitleMainH)
                hue = 0.52 + 0.015 * sin(t * 0.7);
                rgb = ArcadeGameLauncher.hsvToRgb(hue, 0.92, 1.0);
                obj.TitleMainH.Color = rgb;
            end
        end

        function updateMouseHover(obj)
            %updateMouseHover  Highlight item under mouse cursor.
            if any(isnan(obj.MousePos)); return; end
            nGames = numel(obj.RegistryOrder);
            if nGames == 0; return; end

            mx = obj.MousePos(1);
            my = obj.MousePos(2);
            dy = obj.DisplayRange.Y;
            cx = mean(obj.DisplayRange.X);
            rangeH = diff(dy);

            listTop = dy(1) + rangeH * obj.ItemListTopFrac;
            iW = obj.ItemWidth;
            iH = obj.ItemHeight;
            iGap = obj.ItemGap;

            for slot = 1:obj.NumSlots
                gameIdx = obj.ScrollOffset + slot;
                if gameIdx > nGames; break; end
                yTop = listTop + (slot - 1) * (iH + iGap);
                yBot = yTop + iH;
                xLeft = cx - iW / 2;
                xRight = cx + iW / 2;
                if mx >= xLeft && mx <= xRight && my >= yTop && my <= yBot
                    if obj.SelectedIdx ~= gameIdx
                        obj.SelectedIdx = gameIdx;
                        obj.updateSlotHighlight();
                    end
                    return;
                end
            end
        end

        function updateActive(obj)
            %updateActive  Per-frame update during active gameplay.
            if isempty(obj.ActiveGame) || ~isvalid(obj.ActiveGame); return; end

            obj.ActiveGame.onUpdate(obj.MousePos);
            obj.ActiveGame.updateHitEffects();

            % Game signalled completion (e.g., Pong win condition)
            if ~obj.ActiveGame.IsRunning
                obj.enterResults();
                return;
            end

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
                    elseif key == "uparrow"
                        obj.moveSelection(-1);
                    elseif key == "downarrow"
                        obj.moveSelection(1);
                    elseif key == "return" || key == "space"
                        obj.launchSelected();
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

        function moveSelection(obj, delta)
            %moveSelection  Move selection up/down with wrapping and scroll.
            nGames = numel(obj.RegistryOrder);
            if nGames == 0; return; end
            obj.SelectedIdx = mod(obj.SelectedIdx - 1 + delta, nGames) + 1;

            % Scroll to keep selection visible
            maxVis = obj.MaxVisibleItems;
            if obj.SelectedIdx <= obj.ScrollOffset
                obj.ScrollOffset = obj.SelectedIdx - 1;
            elseif obj.SelectedIdx > obj.ScrollOffset + maxVis
                obj.ScrollOffset = obj.SelectedIdx - maxVis;
            end
            obj.ScrollOffset = max(0, min(obj.ScrollOffset, nGames - maxVis));

            obj.updateSlotContent();
            obj.updateSlotHighlight();
            obj.updateScrollThumb();
        end

        function launchSelected(obj)
            %launchSelected  Launch the currently highlighted game.
            nGames = numel(obj.RegistryOrder);
            if nGames == 0; return; end
            idx = max(1, min(obj.SelectedIdx, nGames));
            obj.PendingGameKey = obj.RegistryOrder(idx);
            obj.enterCountdown();
        end
    end

    % =================================================================
    % PRIVATE — State Machine
    % =================================================================
    methods (Access = private)

        function enterMenu(obj)
            %enterMenu  Show game selection menu.
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
            obj.setMenuVisible("on");
            obj.hideGameplayHUD();
            obj.SessionStartTic = tic;
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

            obj.setMenuVisible("off");

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
                if isfield(results, "Lines") && ~isempty(results.Lines)
                    detailLines = cellstr(results.Lines);
                end
                elapsed = toc(obj.SessionStartTic);
                detailLines{end + 1} = sprintf( ...
                    "Score: %d  |  Max Combo: %d  |  Time: %.0fs", ...
                    obj.Score, obj.MaxCombo, elapsed);
                detailLines{end + 1} = "";
                detailLines{end + 1} = "Press any key to continue";
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
    end

    % =================================================================
    % PRIVATE — Menu Rendering (pure axes graphics)
    % =================================================================
    methods (Access = private)

        function createMenu(obj)
            %createMenu  Build neon-styled menu with starfield, title, game list.
            ax = obj.Ax;
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cx = mean(dx);
            rangeH = diff(dy);

            % --- Starfield background ---
            rng("shuffle");
            nStars = 60;
            starX = rand(nStars, 1) * diff(dx) + dx(1);
            starY = rand(nStars, 1) * diff(dy) + dy(1);
            starSz = 0.8 + rand(nStars, 1) * 3.5;
            starC = repmat([0.45 0.50 0.65], nStars, 1) ...
                + (rand(nStars, 3) - 0.5) * 0.15;
            starC = max(0, min(starC, 1));
            obj.StarfieldH = scatter(ax, starX, starY, starSz, starC, ...
                "filled", "MarkerFaceAlpha", 0.18, "Tag", "GT_arcStars");

            % --- Title with neon glow (shadow to the RIGHT only) ---
            titleY = dy(1) + rangeH * 0.14;
            titleStr = "A  R  C  A  D  E";

            % Drop shadow — shifted right and down
            obj.TitleGlowH = text(ax, cx + 6, titleY + 4, titleStr, ...
                "Color", [obj.ColorCyan * 0.35, 0.55], ...
                "FontSize", 50, "FontWeight", "bold", ...
                "FontName", "Consolas", ...
                "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", ...
                "Tag", "GT_arcTitleGlow");

            % Main bright title
            obj.TitleMainH = text(ax, cx, titleY, titleStr, ...
                "Color", obj.ColorCyan, ...
                "FontSize", 50, "FontWeight", "bold", ...
                "FontName", "Consolas", ...
                "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", ...
                "Tag", "GT_arcTitleMain");

            % --- Subtitle (spaced letters, no shadow) ---
            subY = titleY + rangeH * 0.07;
            obj.SubtitleTextH = text(ax, cx, subY, ...
                "S E L E C T   G A M E", ...
                "Color", [0.12 0.50 0.62], "FontSize", 15, ...
                "FontWeight", "bold", "FontName", "Consolas", ...
                "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", ...
                "Tag", "GT_arcSubtitle");

            % --- Accent line (glow + core) ---
            lineY = subY + rangeH * 0.035;
            lineHW = 100;
            obj.DecoLineGlowH = line(ax, ...
                [cx - lineHW, cx + lineHW], [lineY, lineY], ...
                "Color", [obj.ColorCyan * 0.25, 0.22], "LineWidth", 5, ...
                "Tag", "GT_arcLineGlow");
            obj.DecoLineCoreH = line(ax, ...
                [cx - lineHW, cx + lineHW], [lineY, lineY], ...
                "Color", [obj.ColorCyan * 0.55, 0.50], "LineWidth", 1.2, ...
                "Tag", "GT_arcLineCore");

            % --- Game list (slot-based for scroll support) ---
            nGames = numel(obj.RegistryOrder);
            nSlots = min(nGames, obj.MaxVisibleItems);
            obj.NumSlots = nSlots;

            obj.MenuItemBg = cell(1, nSlots);
            obj.MenuItemGlow = cell(1, nSlots);
            obj.MenuItemKeyBg = cell(1, nSlots);
            obj.MenuItemKeyText = cell(1, nSlots);
            obj.MenuItemNameText = cell(1, nSlots);

            listTop = dy(1) + rangeH * obj.ItemListTopFrac;
            iW = obj.ItemWidth;
            iH = obj.ItemHeight;
            iGap = obj.ItemGap;
            cornerR = obj.ItemCornerR;
            kbSz = obj.KeyBadgeSz;
            kbR = kbSz / 2;

            for slot = 1:nSlots
                yTop = listTop + (slot - 1) * (iH + iGap);
                yCtr = yTop + iH / 2;
                xLeft = cx - iW / 2;

                % Outer glow (larger, faint — only visible when selected)
                [gx, gy] = ArcadeGameLauncher.roundedRectVerts( ...
                    cx, yCtr, iW + 18, iH + 12, cornerR + 5);
                obj.MenuItemGlow{slot} = patch(ax, ...
                    "XData", gx, "YData", gy, ...
                    "FaceColor", obj.ColorCyan * 0.35, "FaceAlpha", 0, ...
                    "EdgeColor", "none", "Tag", "GT_arcGlow");

                % Pill background
                [bx, by] = ArcadeGameLauncher.roundedRectVerts( ...
                    cx, yCtr, iW, iH, cornerR);
                obj.MenuItemBg{slot} = patch(ax, ...
                    "XData", bx, "YData", by, ...
                    "FaceColor", [0.045 0.048 0.065], "FaceAlpha", 0.92, ...
                    "EdgeColor", [0.09 0.10 0.13], "LineWidth", 1.2, ...
                    "Tag", "GT_arcBg");

                % Key badge (circle inside the item)
                kbCx = xLeft + 8 + kbSz / 2;
                [kx, ky] = ArcadeGameLauncher.roundedRectVerts( ...
                    kbCx, yCtr, kbSz, kbSz, kbR);
                obj.MenuItemKeyBg{slot} = patch(ax, ...
                    "XData", kx, "YData", ky, ...
                    "FaceColor", obj.ColorTeal * 0.30, "FaceAlpha", 0.75, ...
                    "EdgeColor", "none", "Tag", "GT_arcKeyBg");

                % Key text
                obj.MenuItemKeyText{slot} = text(ax, kbCx, yCtr, "", ...
                    "Color", obj.ColorCyan * 0.75, "FontSize", 13, ...
                    "FontWeight", "bold", "FontName", "Consolas", ...
                    "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "middle", ...
                    "Tag", "GT_arcKeyTxt");

                % Game name
                obj.MenuItemNameText{slot} = text(ax, ...
                    xLeft + 8 + kbSz + 12, yCtr, "", ...
                    "Color", [0.45 0.47 0.54], "FontSize", 15, ...
                    "FontWeight", "bold", ...
                    "HorizontalAlignment", "left", ...
                    "VerticalAlignment", "middle", ...
                    "Tag", "GT_arcName");
            end

            % --- Scroll indicator (hidden until needed) ---
            trackX = cx + iW / 2 + 14;
            trackTop = listTop + 4;
            trackBot = listTop + nSlots * (iH + iGap) - iGap - 4;
            obj.ScrollTrackH = line(ax, [trackX, trackX], ...
                [trackTop, trackBot], ...
                "Color", [0.10 0.10 0.14], "LineWidth", 2.5, ...
                "Visible", "off", "Tag", "GT_arcScrollTrack");

            [tx, ty] = ArcadeGameLauncher.roundedRectVerts( ...
                trackX, (trackTop + trackBot) / 2, 5, 30, 2.5);
            obj.ScrollThumbH = patch(ax, "XData", tx, "YData", ty, ...
                "FaceColor", obj.ColorCyan * 0.4, "FaceAlpha", 0.6, ...
                "EdgeColor", "none", "Visible", "off", ...
                "Tag", "GT_arcScrollThumb");

            % --- Footer ---
            footY = dy(2) - rangeH * 0.04;
            footStr = sprintf( ...
                "%s%s Navigate   %s   Enter: Play   %s   1-9: Quick Select   %s   ESC: Quit", ...
                char(8593), char(8595), char(183), char(183), char(183));
            obj.FooterTextH = text(ax, cx, footY, footStr, ...
                "Color", [0.22 0.24 0.32], "FontSize", 10.5, ...
                "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", ...
                "Tag", "GT_arcFooter");

            % --- Initialize ---
            obj.SelectedIdx = 1;
            obj.ScrollOffset = 0;
            obj.updateSlotContent();
            obj.updateSlotHighlight();
            obj.updateScrollThumb();
        end

        function updateSlotContent(obj)
            %updateSlotContent  Fill slot graphics with game data from scroll window.
            nGames = numel(obj.RegistryOrder);
            for slot = 1:obj.NumSlots
                gameIdx = obj.ScrollOffset + slot;
                if gameIdx >= 1 && gameIdx <= nGames
                    entry = obj.Registry(obj.RegistryOrder(gameIdx));
                    if ~isempty(obj.MenuItemKeyText{slot}) ...
                            && isvalid(obj.MenuItemKeyText{slot})
                        obj.MenuItemKeyText{slot}.String = upper(entry.key);
                    end
                    if ~isempty(obj.MenuItemNameText{slot}) ...
                            && isvalid(obj.MenuItemNameText{slot})
                        obj.MenuItemNameText{slot}.String = entry.name;
                    end
                    obj.setSlotVisible(slot, "on");
                else
                    obj.setSlotVisible(slot, "off");
                end
            end
        end

        function updateSlotHighlight(obj)
            %updateSlotHighlight  Apply selected/unselected style to each slot.
            nGames = numel(obj.RegistryOrder);
            for slot = 1:obj.NumSlots
                gameIdx = obj.ScrollOffset + slot;
                isSel = (gameIdx == obj.SelectedIdx) && gameIdx <= nGames;

                bg = obj.MenuItemBg{slot};
                glow = obj.MenuItemGlow{slot};
                keyBg = obj.MenuItemKeyBg{slot};
                keyTxt = obj.MenuItemKeyText{slot};
                nameTxt = obj.MenuItemNameText{slot};

                if isSel
                    if ~isempty(bg) && isvalid(bg)
                        bg.FaceColor = [0.03 0.14 0.20];
                        bg.EdgeColor = obj.ColorCyan * 0.40;
                        bg.LineWidth = 1.8;
                    end
                    if ~isempty(glow) && isvalid(glow)
                        glow.FaceAlpha = 0.10;
                    end
                    if ~isempty(keyBg) && isvalid(keyBg)
                        keyBg.FaceColor = obj.ColorTeal * 0.50;
                    end
                    if ~isempty(keyTxt) && isvalid(keyTxt)
                        keyTxt.Color = obj.ColorCyan;
                        keyTxt.FontSize = 14;
                    end
                    if ~isempty(nameTxt) && isvalid(nameTxt)
                        nameTxt.Color = obj.ColorWhite;
                    end
                else
                    if ~isempty(bg) && isvalid(bg)
                        bg.FaceColor = [0.045 0.048 0.065];
                        bg.EdgeColor = [0.09 0.10 0.13];
                        bg.LineWidth = 1.2;
                    end
                    if ~isempty(glow) && isvalid(glow)
                        glow.FaceAlpha = 0.0;
                    end
                    if ~isempty(keyBg) && isvalid(keyBg)
                        keyBg.FaceColor = obj.ColorTeal * 0.25;
                    end
                    if ~isempty(keyTxt) && isvalid(keyTxt)
                        keyTxt.Color = obj.ColorCyan * 0.50;
                        keyTxt.FontSize = 13;
                    end
                    if ~isempty(nameTxt) && isvalid(nameTxt)
                        nameTxt.Color = [0.40 0.42 0.50];
                    end
                end
            end
        end

        function updateScrollThumb(obj)
            %updateScrollThumb  Show/hide scroll bar and position thumb.
            nGames = numel(obj.RegistryOrder);
            needsScroll = nGames > obj.MaxVisibleItems;

            visStr = "off";
            if needsScroll; visStr = "on"; end
            if ~isempty(obj.ScrollTrackH) && isvalid(obj.ScrollTrackH)
                obj.ScrollTrackH.Visible = visStr;
            end
            if ~isempty(obj.ScrollThumbH) && isvalid(obj.ScrollThumbH)
                obj.ScrollThumbH.Visible = visStr;
                if needsScroll
                    % Compute thumb position
                    dy = obj.DisplayRange.Y;
                    rangeH = diff(dy);
                    listTop = dy(1) + rangeH * obj.ItemListTopFrac;
                    iH = obj.ItemHeight;
                    iGap = obj.ItemGap;
                    trackTop = listTop + 4;
                    trackBot = listTop + obj.NumSlots * (iH + iGap) - iGap - 4;
                    trackH = trackBot - trackTop;

                    thumbH = max(15, trackH * obj.MaxVisibleItems / nGames);
                    maxOff = nGames - obj.MaxVisibleItems;
                    frac = obj.ScrollOffset / max(1, maxOff);
                    thumbCY = trackTop + thumbH / 2 ...
                        + frac * (trackH - thumbH);

                    trackX = mean(obj.DisplayRange.X) + obj.ItemWidth / 2 + 14;
                    [tx, ty] = ArcadeGameLauncher.roundedRectVerts( ...
                        trackX, thumbCY, 5, thumbH, 2.5);
                    obj.ScrollThumbH.XData = tx;
                    obj.ScrollThumbH.YData = ty;
                end
            end
        end

        function setSlotVisible(obj, slot, vis)
            %setSlotVisible  Show/hide all graphics in a single slot.
            handles = {obj.MenuItemBg{slot}, obj.MenuItemGlow{slot}, ...
                obj.MenuItemKeyBg{slot}, obj.MenuItemKeyText{slot}, ...
                obj.MenuItemNameText{slot}};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    h.Visible = vis;
                end
            end
        end

        function setMenuVisible(obj, vis)
            %setMenuVisible  Show or hide all menu graphics.
            singles = {obj.TitleGlowH, obj.TitleMainH, ...
                obj.SubtitleTextH, obj.DecoLineGlowH, obj.DecoLineCoreH, ...
                obj.FooterTextH, obj.StarfieldH, ...
                obj.ScrollTrackH, obj.ScrollThumbH};
            for k = 1:numel(singles)
                h = singles{k};
                if ~isempty(h) && isvalid(h)
                    h.Visible = vis;
                end
            end

            lists = {obj.MenuItemBg, obj.MenuItemGlow, obj.MenuItemKeyBg, ...
                obj.MenuItemKeyText, obj.MenuItemNameText};
            for j = 1:numel(lists)
                arr = lists{j};
                if isempty(arr); continue; end
                for k = 1:numel(arr)
                    if ~isempty(arr{k}) && isvalid(arr{k})
                        arr{k}.Visible = vis;
                    end
                end
            end
        end
    end

    % =================================================================
    % PRIVATE — HUD Management (axes text objects during gameplay)
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
    % STATIC — Graphics Utilities
    % =================================================================
    methods (Static, Access = private)

        function [px, py] = roundedRectVerts(cx, cy, w, h, r)
            %roundedRectVerts  Rounded rectangle (pill) patch vertices.
            %   [px, py] = roundedRectVerts(cx, cy, w, h, r)
            %   cx, cy = center, w = width, h = height, r = corner radius.
            %   Coordinate system assumes YDir = "reverse" (y increases downward).
            hw = w / 2;
            hh = h / 2;
            r = min(r, min(hw, hh));
            n = 16;

            % Corner arc centers: TR, BR, BL, TL
            corners = [ cx+hw-r, cy-hh+r; ...
                        cx+hw-r, cy+hh-r; ...
                        cx-hw+r, cy+hh-r; ...
                        cx-hw+r, cy-hh+r ];

            % Arc start angles (clockwise on screen = increasing angle)
            arcStart = [-pi/2; 0; pi/2; pi];

            px = zeros(4 * n, 1);
            py = zeros(4 * n, 1);
            for k = 1:4
                t = linspace(arcStart(k), arcStart(k) + pi/2, n)';
                idx = (k - 1) * n + (1:n);
                px(idx) = corners(k, 1) + r * cos(t);
                py(idx) = corners(k, 2) + r * sin(t);
            end
        end

        function rgb = hsvToRgb(h, s, v)
            %hsvToRgb  Convert HSV to RGB (scalar inputs).
            c = v * s;
            hp = mod(h * 6, 6);
            x = c * (1 - abs(mod(hp, 2) - 1));
            m = v - c;
            if hp < 1
                rgb = [c, x, 0];
            elseif hp < 2
                rgb = [x, c, 0];
            elseif hp < 3
                rgb = [0, c, x];
            elseif hp < 4
                rgb = [0, x, c];
            elseif hp < 5
                rgb = [x, 0, c];
            else
                rgb = [c, 0, x];
            end
            rgb = rgb + m;
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
