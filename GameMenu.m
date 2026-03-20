classdef (Sealed) GameMenu < handle
    %GameMenu  Shared neon-styled game selection menu for arcade and finger hosts.
    %   Renders a scrollable game list with animated title, starfield, and slot-based
    %   item highlighting. Supports two selection modes:
    %     "click" — external confirmSelection() call triggers selection (mouse)
    %     "dwell" — hovering over an item for DwellDuration auto-triggers (finger)
    %
    %   Usage:
    %       menu = GameMenu(ax, displayRange, registry, registryOrder, ...
    %           "SelectionMode", "dwell", "SelectionFcn", @(k) disp(k));
    %       menu.update(pos);       % call every frame with [x, y]
    %       menu.show(); menu.hide();
    %       menu.cleanup();
    %
    %   See also ArcadeGameLauncher, GameHost

    % =================================================================
    % CONFIGURATION (set in constructor)
    % =================================================================
    properties (SetAccess = private)
        Ax                                          % axes handle
        DisplayRange    struct                      % struct with .X=[min max], .Y=[min max]
        Registry        dictionary                  % key -> struct(ctor, name, key)
        RegistryOrder   string                      % keys in display order
        SelectionMode   (1,1) string = "click"      % "click" | "dwell"
        SelectionFcn    = []                        % callback: f(key) on selection
        DwellDuration   (1,1) double = 3.0          % seconds for dwell selection
        TagPrefix       (1,1) string = "GT_menu"    % graphics tag prefix
        MenuTitle       (1,1) string = "A  R  C  A  D  E"
        MenuSubtitle    (1,1) string = "S E L E C T   G A M E"
        RefPixelSize    (1,2) double = [0, 0]           % axes pixel size at creation (for font scaling)
    end

    % =================================================================
    % MENU GRAPHICS HANDLES
    % =================================================================
    properties (SetAccess = private)
        TitleGlowH                                  % text — glow shadow
        TitleMainH                                  % text — bright neon title
        SubtitleTextH                               % text — "SELECT GAME"
        DecoLineGlowH                              % line — accent glow
        DecoLineCoreH                               % line — accent core
        FooterTextH                                 % text — instructions
        StarfieldH                                  % scatter — background dots
    end

    % =================================================================
    % GAME LIST SLOT HANDLES
    % =================================================================
    properties (SetAccess = private)
        MenuItemBg                                  % cell of patch — pill backgrounds
        MenuItemGlow                                % cell of patch — outer glow
        MenuItemKeyBg                               % cell of patch — key badge pill
        MenuItemKeyText                             % cell of text — key labels
        MenuItemNameText                            % cell of text — game names
        MenuItemScoreText                           % cell of text — high scores
        NumSlots        (1,1) double = 0            % created slot count
    end

    % =================================================================
    % SELECTION & SCROLL STATE
    % =================================================================
    properties (SetAccess = private)
        SelectedIdx     (1,1) double = 1            % absolute game index (1-based)
        ScrollOffset    (1,1) double = 0            % first visible game index (0-based)
        ScrollTrackH                                % line — scroll track
        ScrollThumbH                                % patch — scroll thumb

        % Scroll drag
        ScrollDragging  (1,1) logical = false
        ScrollDragStartY (1,1) double = 0
        ScrollDragStartOffset (1,1) double = 0
    end

    % =================================================================
    % DWELL STATE
    % =================================================================
    properties (SetAccess = private)
        DwellIdx        (1,1) double = 0            % game index being dwelled on
        DwellStartTic   = []                        % tic when dwell began
    end

    % =================================================================
    % ANIMATION STATE
    % =================================================================
    properties (SetAccess = private)
        AnimStartTic    = []                        % tic for title shimmer / glow pulse

        % Twinkling stars
        TwinkleH                                    % line handles for pulsing stars
        TwinklePhase    (1,:) double                % phase offsets (radians)
        TwinkleSpeed    (1,:) double                % pulse speeds (rad/s)
        TwinkleBaseSize (1,:) double                % base MarkerSize per star

        % Shooting star comets (2 pre-allocated)
        CometH                                      % (1,2) line handles for comet trails
        CometHeadH                                  % (1,2) line handles for comet head dots
        CometActive     (1,2) logical = false       % whether each comet is active
        CometPos        (2,2) double = zeros(2,2)   % [x; y] head position per comet
        CometVel        (2,2) double = zeros(2,2)   % [vx; vy] per comet
        CometProgress   (1,2) double = zeros(1,2)   % 0-1 progress through flight
        CometDuration   (1,2) double = [2.0, 2.0]   % seconds per comet flight
        CometNextSpawn  (1,1) double = 3            % seconds until next spawn attempt
        CometLastSpawnT (1,1) double = 0            % elapsed time of last spawn
    end

    % =================================================================
    % LAYOUT (scaled to display range in constructor)
    % =================================================================
    properties (SetAccess = private)
        ItemWidth       = 200
        ItemHeight      = 46
        ItemGap         = 10
        ItemCornerR     = 20
        KeyBadgeSz      = 28
        MaxVisibleItems = 6
        ItemListTopFrac = 0.30
        TitleFontSize   = 24
        SubtitleFontSize = 12
        NameFontSize    = 15
        KeyFontSize     = 13
        ScoreFontSize   = 12
        FooterFontSize  = 10.5
        LayoutScale     = 1.0
    end

    % =================================================================
    % COLOR CONSTANTS
    % =================================================================
    properties (Constant)
        ColorCyan   (1,3) double = [0, 0.92, 1]
        ColorTeal   (1,3) double = [0.08, 0.55, 0.70]
        ColorGreen  (1,3) double = [0.2, 1, 0.4]
        ColorGold   (1,3) double = [1, 0.85, 0.2]
        ColorRed    (1,3) double = [1, 0.3, 0.2]
        ColorWhite  (1,3) double = [0.95, 0.95, 0.97]
    end

    % =================================================================
    % CONSTRUCTOR & DESTRUCTOR
    % =================================================================
    methods
        function obj = GameMenu(ax, displayRange, registry, registryOrder, opts)
            %GameMenu  Create the menu on the given axes.
            arguments
                ax
                displayRange struct
                registry dictionary
                registryOrder string
                opts.SelectionMode (1,1) string = "click"
                opts.SelectionFcn = []
                opts.DwellDuration (1,1) double = 3.0
                opts.TagPrefix (1,1) string = "GT_menu"
                opts.Title (1,1) string = "A  R  C  A  D  E"
                opts.Subtitle (1,1) string = "S E L E C T   G A M E"
            end
            obj.Ax = ax;
            obj.DisplayRange = displayRange;
            obj.Registry = registry;
            obj.RegistryOrder = registryOrder;
            obj.SelectionMode = opts.SelectionMode;
            obj.SelectionFcn = opts.SelectionFcn;
            obj.DwellDuration = opts.DwellDuration;
            obj.TagPrefix = opts.TagPrefix;
            obj.MenuTitle = opts.Title;
            obj.MenuSubtitle = opts.Subtitle;
            obj.AnimStartTic = tic;

            % Scale layout to display range (designed for 640 wide)
            refWidth = 640;
            actualWidth = diff(displayRange.X);
            s = actualWidth / refWidth;
            obj.LayoutScale = s;
            obj.ItemWidth = round(200 * s);
            obj.ItemHeight = round(46 * s);
            obj.ItemGap = round(10 * s);
            obj.ItemCornerR = round(20 * s);
            obj.KeyBadgeSz = round(28 * s);
            obj.MaxVisibleItems = min(6, max(3, floor(diff(displayRange.Y) * 0.6 / (obj.ItemHeight + obj.ItemGap))));
            % Font sizes: scale up for small display ranges (e.g. GestureMouse
            % ROI ~200 DU) so text fills the scaled pills proportionally.
            % No scaling for equal-or-larger ranges (ArcadeGameLauncher ~850 DU).
            % Font sizes: scale by min(pixel width, pixel height) ratio
            % relative to reference (captured at init or from 1920x1080).
            axPx = getpixelposition(obj.Ax);
            if isempty(obj.RefPixelSize) || all(obj.RefPixelSize == 0)
                obj.RefPixelSize = axPx(3:4);
            end
            pxScale = min(axPx(3) / obj.RefPixelSize(1), axPx(4) / obj.RefPixelSize(2));
            obj.TitleFontSize = max(14, round(36 * pxScale));
            obj.SubtitleFontSize = max(6, round(12 * pxScale));
            obj.NameFontSize = max(7, round(15 * pxScale));
            obj.KeyFontSize = max(6, round(13 * pxScale));
            obj.ScoreFontSize = max(6, round(12 * pxScale));
            obj.FooterFontSize = max(5, round(10.5 * pxScale));

            obj.createGraphics();
        end

        function delete(obj)
            %delete  Destructor.
            obj.cleanup();
        end
    end

    % =================================================================
    % PUBLIC API
    % =================================================================
    methods

        function update(obj, pos)
            %update  Per-frame call: hover detection, dwell timer, animations.
            %   pos = [x, y] in data coordinates.
            if isempty(obj.Ax) || ~isvalid(obj.Ax); return; end

            if ~any(isnan(pos))
                % Finger-based scroll drag (dwell mode)
                if obj.ScrollDragging
                    obj.updateScrollDrag(pos(2));
                    if ~obj.hitTestScrollArea(pos)
                        obj.endScrollDrag();
                    end
                elseif obj.SelectionMode == "dwell" && obj.hitTestScrollThumb(pos)
                    obj.beginScrollDrag(pos(2));
                else
                    % Hover detection (only when not dragging scroll)
                    obj.updateHover(pos);
                end
            else
                if obj.ScrollDragging
                    obj.endScrollDrag();
                end
            end

            % Dwell logic
            if obj.SelectionMode == "dwell"
                obj.updateDwell();
            end

            % Animations (title shimmer, glow pulse, twinkle, comets)
            obj.updateAnimations();
        end

        function confirmSelection(obj)
            %confirmSelection  Trigger selection of the currently highlighted item.
            %   Used in click mode by external caller (e.g., mouse click).
            nGames = numel(obj.RegistryOrder);
            if nGames == 0; return; end
            idx = max(1, min(obj.SelectedIdx, nGames));
            key = obj.RegistryOrder(idx);
            obj.fireSelection(key);
        end

        function show(obj)
            %show  Make all menu graphics visible and refresh scores.
            obj.updateSlotContent();
            obj.setAllVisible("on");
            obj.AnimStartTic = tic;
            obj.resetDwell();
        end

        function hide(obj)
            %hide  Make all menu graphics invisible.
            obj.setAllVisible("off");
            obj.resetDwell();
        end

        function resize(obj, newDisplayRange)
            %resize  Rebuild menu graphics for a new display range.
            obj.DisplayRange = newDisplayRange;

            % Recompute layout dimensions for new range
            refWidth = 640;
            actualWidth = diff(newDisplayRange.X);
            s = actualWidth / refWidth;
            obj.LayoutScale = s;
            obj.ItemWidth = round(200 * s);
            obj.ItemHeight = round(46 * s);
            obj.ItemGap = round(10 * s);
            obj.ItemCornerR = round(20 * s);
            obj.KeyBadgeSz = round(28 * s);
            obj.MaxVisibleItems = min(6, max(3, floor(diff(newDisplayRange.Y) * 0.6 / (obj.ItemHeight + obj.ItemGap))));
            % Font sizes: scale by min(pixel width, pixel height) ratio
            % relative to reference — same formula as constructor
            axPx = getpixelposition(obj.Ax);
            if obj.RefPixelSize(1) > 0 && obj.RefPixelSize(2) > 0
                pxScale = min(axPx(3) / obj.RefPixelSize(1), axPx(4) / obj.RefPixelSize(2));
            else
                pxScale = 1.0;
            end
            obj.TitleFontSize = max(14, round(36 * pxScale));
            obj.SubtitleFontSize = max(6, round(12 * pxScale));
            obj.NameFontSize = max(7, round(15 * pxScale));
            obj.KeyFontSize = max(6, round(13 * pxScale));
            obj.ScoreFontSize = max(6, round(12 * pxScale));
            obj.FooterFontSize = max(5, round(10.5 * pxScale));

            obj.deleteGraphics();
            obj.createGraphics();
        end

        function key = getSelectedKey(obj)
            %getSelectedKey  Return registry key of the currently selected item.
            nGames = numel(obj.RegistryOrder);
            if nGames == 0
                key = "";
                return;
            end
            idx = max(1, min(obj.SelectedIdx, nGames));
            key = obj.RegistryOrder(idx);
        end

        function moveSelection(obj, delta)
            %moveSelection  Move selection up/down with wrapping and scroll.
            nGames = numel(obj.RegistryOrder);
            if nGames == 0; return; end
            obj.SelectedIdx = mod(obj.SelectedIdx - 1 + delta, nGames) + 1;

            maxVis = obj.MaxVisibleItems;
            if obj.SelectedIdx <= obj.ScrollOffset
                obj.ScrollOffset = obj.SelectedIdx - 1;
            elseif obj.SelectedIdx > obj.ScrollOffset + maxVis
                obj.ScrollOffset = obj.SelectedIdx - maxVis;
            end
            obj.ScrollOffset = max(0, min(obj.ScrollOffset, nGames - maxVis));

            obj.updateSlotContent();
            obj.updateSlotHighlight();
            obj.updateScrollThumbPos();
            obj.resetDwell();
        end

        function scrollByDelta(obj, delta)
            %scrollByDelta  Scroll the game list by delta items (wheel support).
            nGames = numel(obj.RegistryOrder);
            maxVis = obj.MaxVisibleItems;
            if nGames <= maxVis; return; end

            obj.ScrollOffset = max(0, min(obj.ScrollOffset + delta, ...
                nGames - maxVis));

            if obj.SelectedIdx <= obj.ScrollOffset
                obj.SelectedIdx = obj.ScrollOffset + 1;
            elseif obj.SelectedIdx > obj.ScrollOffset + maxVis
                obj.SelectedIdx = obj.ScrollOffset + maxVis;
            end

            obj.updateSlotContent();
            obj.updateSlotHighlight();
            obj.updateScrollThumbPos();
        end

        function idx = hitTestItem(obj, pos)
            %hitTestItem  Return game index under position, or 0 if none.
            idx = 0;
            nGames = numel(obj.RegistryOrder);
            if nGames == 0; return; end

            mx = pos(1);
            my = pos(2);
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
                    idx = gameIdx;
                    return;
                end
            end
        end

        function hit = hitTestScrollThumb(obj, pos)
            %hitTestScrollThumb  Check if position is over the scroll thumb.
            hit = false;
            if isempty(obj.ScrollThumbH) || ~isvalid(obj.ScrollThumbH); return; end
            if obj.ScrollThumbH.Visible == "off"; return; end

            mx = pos(1);
            my = pos(2);
            tx = obj.ScrollThumbH.XData;
            ty = obj.ScrollThumbH.YData;

            if mx >= min(tx) - 5 && mx <= max(tx) + 5 ...
                    && my >= min(ty) && my <= max(ty)
                hit = true;
            end
        end

        function beginScrollDrag(obj, mouseY)
            %beginScrollDrag  Start dragging the scroll thumb.
            obj.ScrollDragging = true;
            obj.ScrollDragStartY = mouseY;
            obj.ScrollDragStartOffset = obj.ScrollOffset;
        end

        function updateScrollDrag(obj, mouseY)
            %updateScrollDrag  Update scroll offset during drag.
            if ~obj.ScrollDragging; return; end

            nGames = numel(obj.RegistryOrder);
            maxVis = obj.MaxVisibleItems;
            maxOff = nGames - maxVis;
            if maxOff <= 0; return; end

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

            deltaY = mouseY - obj.ScrollDragStartY;
            deltaFrac = deltaY / scrollableH;
            newOffset = round(obj.ScrollDragStartOffset + deltaFrac * maxOff);
            newOffset = max(0, min(newOffset, maxOff));

            if newOffset ~= obj.ScrollOffset
                obj.ScrollOffset = newOffset;

                if obj.SelectedIdx <= obj.ScrollOffset
                    obj.SelectedIdx = obj.ScrollOffset + 1;
                elseif obj.SelectedIdx > obj.ScrollOffset + maxVis
                    obj.SelectedIdx = obj.ScrollOffset + maxVis;
                end

                obj.updateSlotContent();
                obj.updateSlotHighlight();
                obj.updateScrollThumbPos();
            end
        end

        function endScrollDrag(obj)
            %endScrollDrag  End scroll thumb drag.
            obj.ScrollDragging = false;
        end

        function hit = hitTestScrollArea(obj, pos)
            %hitTestScrollArea  Check if position is near the scroll track.
            hit = false;
            if isempty(obj.ScrollTrackH) || ~isvalid(obj.ScrollTrackH); return; end
            if obj.ScrollTrackH.Visible == "off"; return; end
            tx = obj.ScrollTrackH.XData;
            ty = obj.ScrollTrackH.YData;
            margin = 20 * obj.LayoutScale;
            if pos(1) >= min(tx) - margin && pos(1) <= max(tx) + margin ...
                    && pos(2) >= min(ty) - margin && pos(2) <= max(ty) + margin
                hit = true;
            end
        end

        function cleanup(obj)
            %cleanup  Delete all owned graphics.
            obj.deleteGraphics();
        end
    end

    % =================================================================
    % PRIVATE — Graphics Creation
    % =================================================================
    methods (Access = private)

        function createGraphics(obj)
            %createGraphics  Build all menu graphics on the axes.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cx = mean(dx);
            rangeW = diff(dx);
            rangeH = diff(dy);
            tag = obj.TagPrefix;

            % --- Starfield ---
            % Starfield as a single line with dot markers (scales via scaleScreenSpaceObjects)
            nStars = max(20, round(90 * obj.LayoutScale));
            sx = dx(1) + rand(nStars, 1) * rangeW;
            sy = dy(1) + rand(nStars, 1) * rangeH;
            obj.StarfieldH = line(ax, sx, sy, ...
                "LineStyle", "none", "Marker", ".", ...
                "MarkerSize", 3, "Color", [0.35 0.40 0.55 0.4], ...
                "Tag", tag + "Star");
            uistack(obj.StarfieldH, "bottom");

            % --- Title (large) ---
            s = obj.LayoutScale;
            titleY = dy(1) + rangeH * 0.09;
            titleStr = obj.MenuTitle;
            glowOffY = max(1, round(2.5 * s));
            glowOffX = max(1, round(3 * s));
            obj.TitleGlowH = text(ax, cx + glowOffX, titleY + glowOffY, titleStr, ...
                "Color", [0.00 0.35 0.50], "FontSize", obj.TitleFontSize, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Tag", tag + "TGlow");
            obj.TitleMainH = text(ax, cx, titleY, titleStr, ...
                "Color", obj.ColorCyan, "FontSize", obj.TitleFontSize, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Tag", tag + "TMain");

            % --- Subtitle (between title and game list) ---
            subY = titleY + rangeH * 0.10;
            obj.SubtitleTextH = text(ax, cx, subY, obj.MenuSubtitle, ...
                "Color", [0.25 0.28 0.38], "FontSize", obj.SubtitleFontSize, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Tag", tag + "Sub");

            % --- Decorative line ---
            lineY = subY + rangeH * 0.035;
            lineHW = rangeW * 0.13;
            obj.DecoLineGlowH = line(ax, [cx - lineHW, cx + lineHW], ...
                [lineY, lineY], "Color", [obj.ColorCyan, 0.10], ...
                "LineWidth", 6, "Tag", tag + "DGlow");
            obj.DecoLineCoreH = line(ax, [cx - lineHW, cx + lineHW], ...
                [lineY, lineY], "Color", [obj.ColorCyan, 0.25], ...
                "LineWidth", 1.2, "Tag", tag + "DCore");

            % --- Game list slots ---
            listTop = dy(1) + rangeH * obj.ItemListTopFrac;
            iW = obj.ItemWidth;
            iH = obj.ItemHeight;
            iGap = obj.ItemGap;
            iR = obj.ItemCornerR;
            badgeSz = obj.KeyBadgeSz;

            nGames = numel(obj.RegistryOrder);
            nSlots = min(obj.MaxVisibleItems, max(nGames, 1));
            obj.NumSlots = nSlots;

            obj.MenuItemBg = cell(1, nSlots);
            obj.MenuItemGlow = cell(1, nSlots);
            obj.MenuItemKeyBg = cell(1, nSlots);
            obj.MenuItemKeyText = cell(1, nSlots);
            obj.MenuItemNameText = cell(1, nSlots);
            obj.MenuItemScoreText = cell(1, nSlots);

            for slot = 1:nSlots
                yMid = listTop + (slot - 1) * (iH + iGap) + iH / 2;

                % Glow (outer, behind bg)
                [gx, gy] = GameMenu.roundedRectVerts(cx, yMid, iW + 8, iH + 6, iR + 3);
                obj.MenuItemGlow{slot} = patch(ax, "XData", gx, "YData", gy, ...
                    "FaceColor", obj.ColorCyan * 0.35, "FaceAlpha", 0, ...
                    "EdgeColor", "none", "Tag", tag + "Glow");

                % Background pill
                [bx, by] = GameMenu.roundedRectVerts(cx, yMid, iW, iH, iR);
                obj.MenuItemBg{slot} = patch(ax, "XData", bx, "YData", by, ...
                    "FaceColor", [0.045 0.048 0.065], ...
                    "EdgeColor", [0.09 0.10 0.13], "LineWidth", 1.2, ...
                    "Tag", tag + "Bg");

                % Key badge pill
                badgeX = cx - iW / 2 + round(22 * s);
                [kx, ky] = GameMenu.roundedRectVerts(badgeX, yMid, badgeSz, badgeSz, badgeSz / 2);
                obj.MenuItemKeyBg{slot} = patch(ax, "XData", kx, "YData", ky, ...
                    "FaceColor", obj.ColorTeal * 0.25, ...
                    "EdgeColor", "none", "Tag", tag + "KBg");

                % Key text
                obj.MenuItemKeyText{slot} = text(ax, badgeX, yMid, "", ...
                    "Color", obj.ColorCyan * 0.50, "FontSize", obj.KeyFontSize, ...
                    "FontWeight", "bold", ...
                    "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "middle", ...
                    "Tag", tag + "KTxt");

                % Game name text (centered in pill)
                obj.MenuItemNameText{slot} = text(ax, cx, yMid, "", ...
                    "Color", [0.45 0.47 0.54], "FontSize", obj.NameFontSize, ...
                    "FontWeight", "bold", ...
                    "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "middle", ...
                    "Tag", tag + "Name");

                % High score text (right-aligned)
                scoreX = cx + iW / 2 - round(4 * s);
                obj.MenuItemScoreText{slot} = text(ax, scoreX, yMid, "", ...
                    "Color", [0.35 0.30 0.15], "FontSize", obj.ScoreFontSize, ...
                    "FontWeight", "bold", ...
                    "HorizontalAlignment", "right", ...
                    "VerticalAlignment", "middle", ...
                    "Tag", tag + "Score");
            end

            % --- Scroll indicator ---
            trackX = cx + iW / 2 + round(14 * s);
            trackTop = listTop + 4;
            trackBot = listTop + nSlots * (iH + iGap) - iGap - 4;
            obj.ScrollTrackH = line(ax, [trackX, trackX], ...
                [trackTop, trackBot], ...
                "Color", [0.10 0.10 0.14], "LineWidth", 2.5, ...
                "Visible", "off", "Tag", tag + "STrack");

            [tx, ty] = GameMenu.roundedRectVerts( ...
                trackX, (trackTop + trackBot) / 2, 5, 30, 2.5);
            obj.ScrollThumbH = patch(ax, "XData", tx, "YData", ty, ...
                "FaceColor", obj.ColorCyan * 0.4, "FaceAlpha", 1.0, ...
                "EdgeColor", "none", "Visible", "off", ...
                "Tag", tag + "SThumb");

            % --- Footer (positioned relative to last menu item, not bottom) ---
            footY = listTop + nSlots * (iH + iGap) + iGap;
            if obj.SelectionMode == "dwell"
                footStr = "Hover to select  |  G: Exit";
            else
                footStr = sprintf( ...
                    "%s%s Navigate   %s   Click/Enter: Play   %s   ESC: Quit", ...
                    char(8593), char(8595), char(183), char(183));
            end
            obj.FooterTextH = text(ax, cx, footY, footStr, ...
                "Color", [0.22 0.24 0.32], "FontSize", obj.FooterFontSize, ...
                "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", ...
                "Tag", tag + "Footer");

            % --- Twinkling stars (8 special pulsing stars) ---
            nTwinkle = 20;
            obj.TwinkleH = gobjects(1, nTwinkle);
            obj.TwinklePhase = rand(1, nTwinkle) * 2 * pi;
            obj.TwinkleSpeed = 1.5 + rand(1, nTwinkle) * 2.5;
            obj.TwinkleBaseSize = 4 + rand(1, nTwinkle) * 3;
            for k = 1:nTwinkle
                tx = dx(1) + rand() * rangeW;
                ty = dy(1) + rand() * rangeH;
                obj.TwinkleH(k) = line(ax, tx, ty, ...
                    "LineStyle", "none", "Marker", ".", ...
                    "MarkerSize", obj.TwinkleBaseSize(k), ...
                    "Color", [0.12 0.18 0.27], ...
                    "Tag", tag + "Twinkle");
                uistack(obj.TwinkleH(k), "bottom");
            end

            % --- Shooting star comets (2 pre-allocated, initially hidden) ---
            nComets = 2;
            nTrailPts = 15;
            obj.CometH = gobjects(1, nComets);
            obj.CometHeadH = gobjects(1, nComets);
            nanTrail = nan(1, nTrailPts);
            for k = 1:nComets
                obj.CometH(k) = line(ax, nanTrail, nanTrail, ...
                    "LineStyle", "-", "LineWidth", 1.5, ...
                    "Color", [0.35 0.43 0.50], ...
                    "Visible", "off", "Tag", tag + "Comet");
                obj.CometHeadH(k) = line(ax, 0, 0, ...
                    "LineStyle", "none", "Marker", ".", ...
                    "MarkerSize", 5, "Color", [0.70 0.85 1.0], ...
                    "Visible", "off", "Tag", tag + "CometHd");
                uistack(obj.CometH(k), "bottom");
                uistack(obj.CometHeadH(k), "bottom");
            end
            obj.CometActive = [false, false];
            obj.CometNextSpawn = 1 + rand() * 1.5;
            obj.CometLastSpawnT = 0;

            % --- Initialize ---
            obj.SelectedIdx = 1;
            obj.ScrollOffset = 0;
            obj.updateSlotContent();
            obj.updateSlotHighlight();
            obj.updateScrollThumbPos();
        end

        function deleteGraphics(obj)
            %deleteGraphics  Delete all owned graphics objects.
            if isempty(obj.Ax) || ~isvalid(obj.Ax); return; end
            objs = findall(obj.Ax, "-regexp", "Tag", "^" + obj.TagPrefix);
            if ~isempty(objs)
                delete(objs);
            end
            obj.TitleGlowH = [];
            obj.TitleMainH = [];
            obj.SubtitleTextH = [];
            obj.DecoLineGlowH = [];
            obj.DecoLineCoreH = [];
            obj.FooterTextH = [];
            obj.StarfieldH = [];
            obj.MenuItemBg = {};
            obj.MenuItemGlow = {};
            obj.MenuItemKeyBg = {};
            obj.MenuItemKeyText = {};
            obj.MenuItemNameText = {};
            obj.MenuItemScoreText = {};
            obj.ScrollTrackH = [];
            obj.ScrollThumbH = [];
            obj.TwinkleH = [];
            obj.CometH = [];
            obj.CometHeadH = [];
            obj.CometActive = [false, false];
            obj.NumSlots = 0;
        end
    end

    % =================================================================
    % PRIVATE — Slot Management
    % =================================================================
    methods (Access = private)

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
                    % High score display
                    if ~isempty(obj.MenuItemScoreText{slot}) ...
                            && isvalid(obj.MenuItemScoreText{slot})
                        gId = ScoreManager.classToId(func2str(entry.ctor));
                        hsRec = ScoreManager.get(gId);
                        if hsRec.highScore > 0
                            obj.MenuItemScoreText{slot}.String = ...
                                sprintf("★ %d", hsRec.highScore);
                        else
                            obj.MenuItemScoreText{slot}.String = "";
                        end
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
                scoreTxt = obj.MenuItemScoreText{slot};

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
                    end
                    if ~isempty(nameTxt) && isvalid(nameTxt)
                        nameTxt.Color = obj.ColorWhite;
                    end
                    if ~isempty(scoreTxt) && isvalid(scoreTxt)
                        scoreTxt.Color = obj.ColorGold * 0.85;
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
                    end
                    if ~isempty(nameTxt) && isvalid(nameTxt)
                        nameTxt.Color = [0.40 0.42 0.50];
                    end
                    if ~isempty(scoreTxt) && isvalid(scoreTxt)
                        scoreTxt.Color = [0.35 0.30 0.15];
                    end
                end
            end
        end

        function updateScrollThumbPos(obj)
            %updateScrollThumbPos  Show/hide scroll bar and position thumb.
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

                    trackX = mean(obj.DisplayRange.X) + obj.ItemWidth / 2 + round(14 * obj.LayoutScale);
                    [tx, ty] = GameMenu.roundedRectVerts( ...
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
                obj.MenuItemNameText{slot}, obj.MenuItemScoreText{slot}};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    h.Visible = vis;
                end
            end
        end

        function setAllVisible(obj, vis)
            %setAllVisible  Show or hide all menu graphics.
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

            % Twinkle stars
            if ~isempty(obj.TwinkleH)
                for k = 1:numel(obj.TwinkleH)
                    if isvalid(obj.TwinkleH(k))
                        obj.TwinkleH(k).Visible = vis;
                    end
                end
            end

            % Comets: only hide — show is controlled by spawn logic
            if vis == "off"
                for k = 1:numel(obj.CometH)
                    if ~isempty(obj.CometH) && isvalid(obj.CometH(k))
                        obj.CometH(k).Visible = "off";
                    end
                    if ~isempty(obj.CometHeadH) && isvalid(obj.CometHeadH(k))
                        obj.CometHeadH(k).Visible = "off";
                    end
                end
                obj.CometActive = [false, false];
            end

            lists = {obj.MenuItemBg, obj.MenuItemGlow, obj.MenuItemKeyBg, ...
                obj.MenuItemKeyText, obj.MenuItemNameText, ...
                obj.MenuItemScoreText};
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
    % PRIVATE — Hover & Dwell
    % =================================================================
    methods (Access = private)

        function updateHover(obj, pos)
            %updateHover  Highlight item under cursor/finger position.
            nGames = numel(obj.RegistryOrder);
            if nGames == 0; return; end

            hitIdx = obj.hitTestItem(pos);
            if hitIdx > 0 && hitIdx ~= obj.SelectedIdx
                obj.SelectedIdx = hitIdx;
                obj.updateSlotHighlight();

                % Reset dwell when selection changes
                if obj.SelectionMode == "dwell"
                    obj.DwellIdx = hitIdx;
                    obj.DwellStartTic = tic;
                end
            elseif hitIdx == 0 && obj.SelectionMode == "dwell"
                % Cursor left all items
                obj.resetDwell();
            elseif hitIdx > 0 && hitIdx == obj.SelectedIdx ...
                    && obj.SelectionMode == "dwell" && obj.DwellIdx ~= hitIdx
                % Re-entered same item after leaving
                obj.DwellIdx = hitIdx;
                obj.DwellStartTic = tic;
            end
        end

        function updateDwell(obj)
            %updateDwell  Update dwell timer and visual feedback.
            if obj.DwellIdx == 0 || isempty(obj.DwellStartTic); return; end

            elapsed = toc(obj.DwellStartTic);
            progress = min(1.0, elapsed / obj.DwellDuration);

            % Visual feedback: ramp glow from cyan to green
            slotIdx = obj.DwellIdx - obj.ScrollOffset;
            if slotIdx >= 1 && slotIdx <= obj.NumSlots
                glow = obj.MenuItemGlow{slotIdx};
                bg = obj.MenuItemBg{slotIdx};
                keyBg = obj.MenuItemKeyBg{slotIdx};
                nameTxt = obj.MenuItemNameText{slotIdx};
                scoreTxt = obj.MenuItemScoreText{slotIdx};

                % Lerp colors: cyan → green
                glowClr = (1 - progress) * obj.ColorCyan * 0.35 ...
                    + progress * obj.ColorGreen * 0.50;
                bgEdge = (1 - progress) * obj.ColorCyan * 0.40 ...
                    + progress * obj.ColorGreen * 0.60;
                keyClr = (1 - progress) * obj.ColorTeal * 0.50 ...
                    + progress * obj.ColorGreen * 0.40;
                nameClr = (1 - progress) * obj.ColorWhite ...
                    + progress * obj.ColorGreen;
                glowAlpha = 0.10 + 0.20 * progress;

                if ~isempty(glow) && isvalid(glow)
                    glow.FaceColor = glowClr;
                    glow.FaceAlpha = glowAlpha;
                end
                if ~isempty(bg) && isvalid(bg)
                    bg.EdgeColor = bgEdge;
                end
                if ~isempty(keyBg) && isvalid(keyBg)
                    keyBg.FaceColor = keyClr;
                end
                if ~isempty(nameTxt) && isvalid(nameTxt)
                    nameTxt.Color = nameClr;
                end
                if ~isempty(scoreTxt) && isvalid(scoreTxt)
                    scoreClr = (1 - progress) * obj.ColorGold * 0.85 ...
                        + progress * obj.ColorGreen * 0.80;
                    scoreTxt.Color = scoreClr;
                end
            end

            % Fire selection when dwell completes
            if progress >= 1.0
                nGames = numel(obj.RegistryOrder);
                if obj.DwellIdx >= 1 && obj.DwellIdx <= nGames
                    key = obj.RegistryOrder(obj.DwellIdx);
                    obj.resetDwell();
                    obj.fireSelection(key);
                end
            end
        end

        function resetDwell(obj)
            %resetDwell  Clear dwell state and restore slot colors.
            obj.DwellIdx = 0;
            obj.DwellStartTic = [];
            obj.updateSlotHighlight();
        end
    end

    % =================================================================
    % PRIVATE — Animations
    % =================================================================
    methods (Access = private)

        function updateAnimations(obj)
            %updateAnimations  Title shimmer, glow pulse, twinkling stars, comets.
            if isempty(obj.AnimStartTic); return; end
            t = toc(obj.AnimStartTic);

            % Selected glow pulse (skip in dwell mode — dwell ramp overrides)
            if obj.SelectionMode ~= "dwell" || obj.DwellIdx == 0
                slotIdx = obj.SelectedIdx - obj.ScrollOffset;
                if slotIdx >= 1 && slotIdx <= obj.NumSlots
                    g = obj.MenuItemGlow{slotIdx};
                    if ~isempty(g) && isvalid(g)
                        pulse = 0.10 + 0.06 * sin(t * 3.5);
                        g.FaceAlpha = pulse;
                    end
                end
            end

            % Title hue shimmer
            if ~isempty(obj.TitleMainH) && isvalid(obj.TitleMainH)
                hue = 0.52 + 0.015 * sin(t * 0.7);
                rgb = GameMenu.hsvToRgb(hue, 0.92, 1.0);
                obj.TitleMainH.Color = rgb;
            end

            % --- Twinkling stars ---
            if ~isempty(obj.TwinkleH)
                baseColor = [0.4, 0.6, 0.9];
                for k = 1:numel(obj.TwinkleH)
                    if ~isvalid(obj.TwinkleH(k)); continue; end
                    if obj.TwinkleH(k).Visible == "off"; continue; end
                    pulse = 0.5 + 0.5 * sin(t * obj.TwinkleSpeed(k) + obj.TwinklePhase(k));
                    brightness = 0.2 + 0.8 * pulse;
                    obj.TwinkleH(k).Color = baseColor * brightness;
                    obj.TwinkleH(k).MarkerSize = obj.TwinkleBaseSize(k) * (0.85 + 0.15 * pulse);
                end
            end

            % --- Shooting star comets ---
            obj.updateComets(t);
        end

        function updateComets(obj, t)
            %updateComets  Spawn, advance, and render shooting star comets.
            if isempty(obj.CometH); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            rangeW = diff(dx);
            rangeH = diff(dy);
            nTrailPts = 15;

            % --- Spawn logic ---
            if t - obj.CometLastSpawnT >= obj.CometNextSpawn
                % Find an inactive comet slot
                slotK = 0;
                for k = 1:2
                    if ~obj.CometActive(k)
                        slotK = k;
                        break;
                    end
                end
                if slotK > 0
                    obj.spawnComet(slotK, dx, dy, rangeW, rangeH);
                end
                obj.CometLastSpawnT = t;
                obj.CometNextSpawn = 1.5 + rand() * 2;
            end

            % --- Update active comets ---
            for k = 1:2
                if ~obj.CometActive(k); continue; end
                if ~isvalid(obj.CometH(k)); continue; end

                % Advance progress
                dt = 1.0 / 50;  % approximate frame dt at 50 Hz
                obj.CometProgress(k) = obj.CometProgress(k) + dt / obj.CometDuration(k);

                if obj.CometProgress(k) >= 1.0
                    % Deactivate
                    obj.CometActive(k) = false;
                    obj.CometH(k).Visible = "off";
                    obj.CometHeadH(k).Visible = "off";
                    continue;
                end

                % Current head position
                headX = obj.CometPos(1, k) + obj.CometVel(1, k) * obj.CometProgress(k) * obj.CometDuration(k);
                headY = obj.CometPos(2, k) + obj.CometVel(2, k) * obj.CometProgress(k) * obj.CometDuration(k);

                % Trail: points from head backwards along velocity
                trailLen = 0.12 * max(rangeW, rangeH);
                velNorm = sqrt(obj.CometVel(1, k)^2 + obj.CometVel(2, k)^2);
                if velNorm < 1e-6; continue; end
                dirX = obj.CometVel(1, k) / velNorm;
                dirY = obj.CometVel(2, k) / velNorm;

                fracs = linspace(0, 1, nTrailPts);
                trailX = headX - fracs * trailLen * dirX;
                trailY = headY - fracs * trailLen * dirY;

                obj.CometH(k).XData = trailX;
                obj.CometH(k).YData = trailY;
                obj.CometH(k).Visible = "on";

                % Fade: gradual in (first 15%) and gradual out (last 60%)
                p = obj.CometProgress(k);
                if p < 0.15
                    fade = p / 0.15;           % 0→1 over first 15%
                elseif p > 0.4
                    fade = 1.0 - (p - 0.4) / 0.6;  % 1→0 over last 60%
                else
                    fade = 1.0;
                end
                fade = max(0, fade);
                obj.CometH(k).Color = [0.35 0.43 0.50] * (0.2 + 0.8 * fade);

                % Head dot
                obj.CometHeadH(k).XData = headX;
                obj.CometHeadH(k).YData = headY;
                obj.CometHeadH(k).Visible = "on";
                obj.CometHeadH(k).Color = [0.70 0.85 1.0] * (0.3 + 0.7 * fade);
            end
        end

        function spawnComet(obj, k, dx, dy, rangeW, rangeH)
            %spawnComet  Initialize comet k from upper region, streaking diagonally down.
            % Start in upper 20% of screen, random X
            startX = dx(1) + (0.1 + rand() * 0.8) * rangeW;
            startY = dy(1) + rand() * rangeH * 0.2;

            % Direction: steep diagonal downward (55-75 deg from horizontal)
            % Randomly left or right
            angle = (55 + rand() * 20) * pi / 180;
            if rand() > 0.5
                angle = pi - angle;  % streak left instead of right
            end
            speed = (0.6 + rand() * 0.4) * max(rangeW, rangeH);
            vx = speed * cos(angle);
            vy = speed * sin(angle);

            obj.CometPos(:, k) = [startX; startY];
            obj.CometVel(:, k) = [vx; vy];
            obj.CometProgress(k) = 0;
            obj.CometDuration(k) = 1.0 + rand() * 0.8;  % 1.0-1.8 seconds
            obj.CometActive(k) = true;
        end
    end

    % =================================================================
    % PRIVATE — Utility
    % =================================================================
    methods (Access = private)

        function fireSelection(obj, key)
            %fireSelection  Invoke the selection callback.
            if ~isempty(obj.SelectionFcn)
                obj.SelectionFcn(key);
            end
        end
    end

    % =================================================================
    % STATIC — Graphics Utilities
    % =================================================================
    methods (Static, Access = private)

        function [px, py] = roundedRectVerts(cx, cy, w, h, r)
            %roundedRectVerts  Rounded rectangle (pill) patch vertices.
            hw = w / 2;
            hh = h / 2;
            r = min(r, min(hw, hh));
            n = 16;

            corners = [ cx+hw-r, cy-hh+r; ...
                        cx+hw-r, cy+hh-r; ...
                        cx-hw+r, cy+hh-r; ...
                        cx-hw+r, cy-hh+r ];

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
end
