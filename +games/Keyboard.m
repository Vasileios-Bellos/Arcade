classdef Keyboard < GameBase
    %Keyboard  On-screen QWERTY keyboard with dwell-based key press.
    %   Finger hovers over a key; after a dwell threshold the key fires.
    %   ISO L-shaped Enter key, Shift/Caps/Ctrl/Alt toggles, typed text
    %   display.  Scoring: 10 pts per typeable key press.
    %
    %   Standalone: games.Keyboard().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Keyboard"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        Keys            struct = struct("label", {}, "x", {}, "y", {}, ...
                                        "w", {}, "h", {})
        HoverIdx        (1,1) double = 0
        DwellFrames     (1,1) double = 0
        DwellThreshold  (1,1) double = 12
        TypedText       (1,1) string = ""
        LastPressIdx    (1,1) double = 0
        ShiftActive     (1,1) logical = false
        CapsActive      (1,1) logical = false
        CtrlActive      (1,1) logical = false
        AltActive       (1,1) logical = false
        TotalPresses    (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        KeyPatches      = {}    % cell array of patch handles
        KeyTexts        = {}    % cell array of text handles
        KeyGlows        = {}    % cell array of glow patch handles
        TypedTextH              % text handle for typed text display
        BgPatchH                % patch handle for keyboard background
        CursorH                 % reserved for cursor blink (unused)
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create QWERTY keyboard graphics and initialize state.
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

            obj.buildKeyboard(ax, displayRange);
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame keyboard interaction (dwell detection).
            if any(isnan(pos)); return; end

            hoveredKey = obj.findHoveredKey(pos);

            % Update hover state
            if hoveredKey ~= obj.HoverIdx
                if obj.HoverIdx > 0 && obj.HoverIdx <= numel(obj.KeyPatches)
                    obj.resetKeyVisual(obj.HoverIdx);
                end
                obj.HoverIdx = hoveredKey;
                obj.DwellFrames = 0;
                obj.LastPressIdx = 0;
            end

            if hoveredKey > 0
                obj.DwellFrames = obj.DwellFrames + 1;

                % Hover highlight — progressive fill
                if hoveredKey <= numel(obj.KeyPatches) ...
                        && ~isempty(obj.KeyPatches{hoveredKey})
                    p = obj.KeyPatches{hoveredKey};
                    if isvalid(p)
                        progress = min(1, obj.DwellFrames / obj.DwellThreshold);
                        p.FaceAlpha = 0.06 + progress * 0.2;
                        p.EdgeColor = obj.ColorCyan * (0.5 + progress * 0.5);
                    end
                end

                % Trigger press at dwell threshold
                if obj.DwellFrames >= obj.DwellThreshold
                    obj.pressKey(hoveredKey);
                    obj.DwellFrames = 0;
                end
            end

            % Update typed text display
            if ~isempty(obj.TypedTextH) && isvalid(obj.TypedTextH)
                displayText = obj.TypedText;
                if strlength(displayText) > 30
                    displayText = extractAfter(displayText, ...
                        strlength(displayText) - 30);
                end
                obj.TypedTextH.String = displayText;
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all keyboard graphics.
            for k = 1:numel(obj.KeyPatches)
                if ~isempty(obj.KeyPatches{k}) && isvalid(obj.KeyPatches{k})
                    delete(obj.KeyPatches{k});
                end
            end
            for k = 1:numel(obj.KeyTexts)
                if ~isempty(obj.KeyTexts{k}) && isvalid(obj.KeyTexts{k})
                    delete(obj.KeyTexts{k});
                end
            end
            for k = 1:numel(obj.KeyGlows)
                if ~isempty(obj.KeyGlows{k}) && isvalid(obj.KeyGlows{k})
                    delete(obj.KeyGlows{k});
                end
            end
            obj.KeyPatches = {};
            obj.KeyTexts = {};
            obj.KeyGlows = {};

            handles = {obj.TypedTextH, obj.BgPatchH, obj.CursorH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.TypedTextH = [];
            obj.BgPatchH = [];
            obj.CursorH = [];

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_keyboard");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No physical key bindings (all interaction is dwell).
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return keyboard-specific results.
            r.Title = "KEYBOARD";
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            else
                elapsed = 0;
            end
            r.Lines = {
                sprintf("Keys: %d  |  Time: %.0fs  |  Text: %s", ...
                    obj.TotalPresses, elapsed, obj.TypedText)
            };
        end
    end

    % =================================================================
    % PRIVATE — KEYBOARD LAYOUT & RENDERING
    % =================================================================
    methods (Access = private)

        function buildKeyboard(obj, ax, displayRange)
            %buildKeyboard  Create QWERTY keyboard with ISO layout.
            %   Accurate key widths (all rows = 15u). 5 rows:
            %   Number row (Esc-Backspace), Q-row, Home row, Z-row, Modifiers.
            dx = displayRange.X;
            dy = displayRange.Y;
            displayW = dx(2) - dx(1);
            displayH = dy(2) - dy(1);

            % Keyboard occupies bottom ~50% of display
            kbTop = dy(1) + displayH * 0.48;
            kbBot = dy(2) - 3;
            kbH = kbBot - kbTop;
            keyGap = 2;
            rowGap = 2;
            nRows = 5;
            rowH = (kbH - (nRows - 1) * rowGap) / nRows;
            kbMargin = displayW * 0.02;
            kbLeft = dx(1) + kbMargin;
            kbRight = dx(2) - kbMargin;
            kbW = kbRight - kbLeft;
            oneU = kbW / 15.0;

            % --- ISO-style row definitions: {labels, widths_in_u} ---
            r1L = ["Esc","1","2","3","4","5","6","7","8","9","0","-","=","Back"];
            r1W = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2];
            r2L = ["Tab","Q","W","E","R","T","Y","U","I","O","P","[","]"];
            r2W = [1.5, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1];
            r3L = ["Caps","A","S","D","F","G","H","J","K","L",";","'","#","Enter"];
            r3W = [1.75, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.25];
            r4L = ["LShift","Z","X","C","V","B","N","M",",",".","/","RShift"];
            r4W = [2.25, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2.75];
            r5L = ["LCtrl","Win","LAlt","Space","RAlt","Fn","Menu","RCtrl"];
            r5W = [1.25, 1.25, 1.25, 6.25, 1.25, 1.25, 1.25, 1.25];

            allLabels = {r1L, r2L, r3L, r4L, r5L};
            allWidths = {r1W, r2W, r3W, r4W, r5W};

            % Build key struct array
            obj.Keys = struct("label", {}, "x", {}, "y", {}, "w", {}, "h", {});
            obj.KeyPatches = {};
            obj.KeyTexts = {};
            obj.KeyGlows = {};
            obj.TypedText = "";
            obj.HoverIdx = 0;
            obj.DwellFrames = 0;
            obj.LastPressIdx = 0;
            obj.TotalPresses = 0;
            obj.ShiftActive = false;
            obj.CapsActive = false;
            obj.CtrlActive = false;
            obj.AltActive = false;

            keyIdx = 0;
            for r = 1:nRows
                labels = allLabels{r};
                widths = allWidths{r};
                rowY = kbTop + (r - 1) * (rowH + rowGap);
                cumU = 0;
                for c = 1:numel(labels)
                    keyIdx = keyIdx + 1;
                    kx = kbLeft + cumU * oneU;
                    kw = widths(c) * oneU - keyGap;
                    obj.Keys(keyIdx) = struct("label", labels(c), ...
                        "x", kx, "y", rowY, "w", kw, "h", rowH);
                    cumU = cumU + widths(c);
                end
            end

            % --- Create graphics for each key ---
            nKeys = numel(obj.Keys);
            obj.KeyPatches = cell(1, nKeys);
            obj.KeyTexts = cell(1, nKeys);
            obj.KeyGlows = cell(1, nKeys);

            fontSize = max(9, min(14, floor(rowH * 0.48)));
            modFontSize = max(7, fontSize - 2);

            for k = 1:nKeys
                ky = obj.Keys(k);
                xv = [ky.x, ky.x + ky.w, ky.x + ky.w, ky.x];
                yv = [ky.y, ky.y, ky.y + ky.h, ky.y + ky.h];

                % Key glow (behind)
                obj.KeyGlows{k} = patch(ax, xv, yv, obj.ColorCyan, ...
                    "FaceAlpha", 0, "EdgeColor", obj.ColorCyan * 0.15, ...
                    "LineWidth", 4, "Tag", "GT_keyboard");

                % Key face
                obj.KeyPatches{k} = patch(ax, xv, yv, obj.ColorCyan, ...
                    "FaceAlpha", 0.06, "EdgeColor", obj.ColorCyan, ...
                    "LineWidth", 1.5, "Tag", "GT_keyboard");

                % Display label
                lbl = obj.keyDisplayLabel(ky.label);
                fs = fontSize;
                if strlength(lbl) > 1
                    fs = modFontSize;
                end
                obj.KeyTexts{k} = text(ax, ky.x + ky.w / 2, ...
                    ky.y + ky.h / 2, lbl, ...
                    "Color", [0.85, 0.85, 0.85], "FontSize", fs, ...
                    "FontWeight", "bold", ...
                    "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "middle", ...
                    "Interpreter", "none", "Tag", "GT_keyboard");
            end

            % --- ISO L-shaped Enter key ---
            obj.reshapeEnterKey(kbTop, rowH, rowGap, oneU, keyGap);

            % --- Typed text display (above keyboard) ---
            obj.TypedTextH = text(ax, mean(dx), kbTop - 12, "", ...
                "Color", obj.ColorCyan * 0.9, "FontSize", 18, ...
                "FontWeight", "bold", ...
                "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", ...
                "Interpreter", "none", "Tag", "GT_keyboard");

            % --- Background panel ---
            obj.BgPatchH = patch(ax, ...
                [kbLeft - 5, kbRight + 5, kbRight + 5, kbLeft - 5], ...
                [kbTop - 20, kbTop - 20, kbBot + 5, kbBot + 5], ...
                [0.1, 0.1, 0.12], "FaceAlpha", 0.3, ...
                "EdgeColor", obj.ColorCyan * 0.2, ...
                "LineWidth", 1, "Tag", "GT_keyboard");
            uistack(obj.BgPatchH, "bottom");

            % Show lowercase labels by default
            obj.updateShiftLabels();
        end

        function reshapeEnterKey(obj, kbTop, rowH, rowGap, oneU, keyGap)
            %reshapeEnterKey  Replace rectangular Enter with ISO L-shape.
            enterIdx = 0;
            for k = 1:numel(obj.Keys)
                if obj.Keys(k).label == "Enter"
                    enterIdx = k;
                    break;
                end
            end
            if enterIdx == 0; return; end

            ek = obj.Keys(enterIdx);
            row2Y = kbTop + 1 * (rowH + rowGap);
            row3Y = kbTop + 2 * (rowH + rowGap);

            upperW = 1.5 * oneU - keyGap;   % row 2 protrusion (wider)
            lowerW = ek.w;                   % 1.25u - gap (row 3, narrower)
            xRight = ek.x + lowerW;
            xUpperLeft = xRight - upperW;
            stepY = row2Y + rowH;

            % 6-point L polygon (clockwise from protrusion top-left)
            lx = [xUpperLeft, xRight, xRight, ek.x, ek.x, xUpperLeft];
            ly = [row2Y, row2Y, row3Y + rowH, row3Y + rowH, stepY, stepY];

            % Bounding box for hit detection
            obj.Keys(enterIdx).y = row2Y;
            obj.Keys(enterIdx).h = 2 * rowH + rowGap;

            % Replace rectangular patches with L-shape
            if ~isempty(obj.KeyGlows{enterIdx}) ...
                    && isvalid(obj.KeyGlows{enterIdx})
                set(obj.KeyGlows{enterIdx}, "XData", lx, "YData", ly);
            end
            if ~isempty(obj.KeyPatches{enterIdx}) ...
                    && isvalid(obj.KeyPatches{enterIdx})
                set(obj.KeyPatches{enterIdx}, "XData", lx, "YData", ly);
            end

            % Centroid of L for text label
            upperArea = upperW * (stepY - row2Y);
            lowerArea = lowerW * (row3Y + rowH - stepY);
            totalArea = upperArea + lowerArea;
            centX = ((xUpperLeft + xRight) / 2 * upperArea + ...
                     (ek.x + xRight) / 2 * lowerArea) / totalArea;
            centY = ((row2Y + stepY) / 2 * upperArea + ...
                     (stepY + row3Y + rowH) / 2 * lowerArea) / totalArea;
            if ~isempty(obj.KeyTexts{enterIdx}) ...
                    && isvalid(obj.KeyTexts{enterIdx})
                obj.KeyTexts{enterIdx}.Position = [centX, centY, 0];
            end
        end

        % ----- Hit detection -----

        function idx = findHoveredKey(obj, fingerPos)
            %findHoveredKey  Return index of key under finger, 0 if none.
            idx = 0;
            for k = 1:numel(obj.Keys)
                ky = obj.Keys(k);
                inBox = fingerPos(1) >= ky.x ...
                    && fingerPos(1) <= ky.x + ky.w ...
                    && fingerPos(2) >= ky.y ...
                    && fingerPos(2) <= ky.y + ky.h;
                if inBox
                    % L-shaped Enter: reject top-left corner outside polygon
                    if ky.label == "Enter" ...
                            && ~isempty(obj.KeyPatches{k}) ...
                            && isvalid(obj.KeyPatches{k})
                        px = obj.KeyPatches{k}.XData;
                        py = obj.KeyPatches{k}.YData;
                        if ~inpolygon(fingerPos(1), fingerPos(2), px, py)
                            continue;
                        end
                    end
                    idx = k;
                    return;
                end
            end
        end

        % ----- Key press logic -----

        function pressKey(obj, keyIdx)
            %pressKey  Handle a key press via dwell detection.
            keyLabel = obj.Keys(keyIdx).label;

            % --- Toggle modifiers ---
            shiftKeys = ["LShift", "RShift"];
            ctrlKeys = ["LCtrl", "RCtrl"];
            altKeys = ["LAlt", "RAlt"];

            if ismember(keyLabel, shiftKeys)
                obj.ShiftActive = ~obj.ShiftActive;
                obj.updateModifierVisual(shiftKeys, obj.ShiftActive);
                obj.updateShiftLabels();
                obj.flashKey(keyIdx);
                return;
            end
            if keyLabel == "Caps"
                obj.CapsActive = ~obj.CapsActive;
                obj.updateModifierVisual("Caps", obj.CapsActive);
                obj.updateShiftLabels();
                obj.flashKey(keyIdx);
                return;
            end
            if ismember(keyLabel, ctrlKeys)
                obj.CtrlActive = ~obj.CtrlActive;
                obj.updateModifierVisual(ctrlKeys, obj.CtrlActive);
                obj.flashKey(keyIdx);
                return;
            end
            if ismember(keyLabel, altKeys)
                obj.AltActive = ~obj.AltActive;
                obj.updateModifierVisual(altKeys, obj.AltActive);
                obj.flashKey(keyIdx);
                return;
            end

            % Non-typeable keys — just flash
            if ismember(keyLabel, ["Tab", "Win", "Fn", "Menu", "Esc"])
                obj.flashKey(keyIdx);
                return;
            end

            % --- Typeable keys ---
            obj.TotalPresses = obj.TotalPresses + 1;
            if keyLabel == "Back"
                if strlength(obj.TypedText) > 0
                    obj.TypedText = extractBefore(obj.TypedText, ...
                        strlength(obj.TypedText));
                end
            elseif keyLabel == "Space"
                obj.TypedText = obj.TypedText + " ";
            elseif keyLabel == "Enter"
                obj.TypedText = obj.TypedText + " ";
            else
                ch = string(keyLabel);
                isUpper = xor(obj.ShiftActive, obj.CapsActive);
                if strlength(ch) == 1 && ch >= "A" && ch <= "Z"
                    if ~isUpper
                        ch = lower(ch);
                    end
                elseif obj.ShiftActive
                    ch = games.Keyboard.shiftedChar(ch);
                end
                obj.TypedText = obj.TypedText + ch;
            end
            obj.addScore(10);
            obj.flashKey(keyIdx);
        end

        % ----- Visual feedback -----

        function flashKey(obj, keyIdx)
            %flashKey  Green flash on key press, plus hit-effect burst.
            if keyIdx <= numel(obj.KeyPatches) ...
                    && ~isempty(obj.KeyPatches{keyIdx})
                p = obj.KeyPatches{keyIdx};
                if isvalid(p)
                    p.FaceColor = obj.ColorGreen;
                    p.FaceAlpha = 0.4;
                end
            end
            ky = obj.Keys(keyIdx);
            obj.spawnHitEffect([ky.x + ky.w / 2, ky.y + ky.h / 2], ...
                obj.ColorGreen, 10, 10);
        end

        function updateModifierVisual(obj, labels, isActive)
            %updateModifierVisual  Highlight or unhighlight modifier keys.
            for k = 1:numel(obj.Keys)
                if ismember(obj.Keys(k).label, labels)
                    if k <= numel(obj.KeyPatches) ...
                            && ~isempty(obj.KeyPatches{k})
                        p = obj.KeyPatches{k};
                        if isvalid(p)
                            if isActive
                                p.FaceColor = obj.ColorGold;
                                p.FaceAlpha = 0.25;
                                p.EdgeColor = obj.ColorGold;
                            else
                                p.FaceColor = obj.ColorCyan;
                                p.FaceAlpha = 0.06;
                                p.EdgeColor = obj.ColorCyan;
                            end
                        end
                    end
                end
            end
        end

        function resetKeyVisual(obj, keyIdx)
            %resetKeyVisual  Reset key to default state (preserves modifier highlight).
            if keyIdx <= 0 || keyIdx > numel(obj.KeyPatches); return; end
            if isempty(obj.KeyPatches{keyIdx}); return; end
            p = obj.KeyPatches{keyIdx};
            if ~isvalid(p); return; end

            keyLabel = obj.Keys(keyIdx).label;
            shiftOn = obj.ShiftActive ...
                && ismember(keyLabel, ["LShift", "RShift"]);
            capsOn = obj.CapsActive && keyLabel == "Caps";
            ctrlOn = obj.CtrlActive ...
                && ismember(keyLabel, ["LCtrl", "RCtrl"]);
            altOn = obj.AltActive ...
                && ismember(keyLabel, ["LAlt", "RAlt"]);

            if shiftOn || capsOn || ctrlOn || altOn
                p.FaceColor = obj.ColorGold;
                p.FaceAlpha = 0.25;
                p.EdgeColor = obj.ColorGold;
            else
                p.FaceColor = obj.ColorCyan;
                p.FaceAlpha = 0.06;
                p.EdgeColor = obj.ColorCyan;
            end
        end

        function updateShiftLabels(obj)
            %updateShiftLabels  Refresh key text labels for Shift/Caps state.
            for k = 1:numel(obj.Keys)
                keyLabel = obj.Keys(k).label;
                if strlength(keyLabel) > 1; continue; end
                if k > numel(obj.KeyTexts); continue; end
                t = obj.KeyTexts{k};
                if isempty(t) || ~isvalid(t); continue; end

                if keyLabel >= "A" && keyLabel <= "Z"
                    isUpper = xor(obj.ShiftActive, obj.CapsActive);
                    if isUpper
                        t.String = char(keyLabel);
                    else
                        t.String = lower(char(keyLabel));
                    end
                else
                    if obj.ShiftActive
                        t.String = char(games.Keyboard.shiftedChar(keyLabel));
                    else
                        t.String = char(keyLabel);
                    end
                end
            end
        end
    end

    % =================================================================
    % STATIC UTILITIES
    % =================================================================
    methods (Static, Access = private)
        function ch = shiftedChar(keyLabel)
            %shiftedChar  Map key label to its shifted symbol.
            persistent sMap
            if isempty(sMap)
                sMap = dictionary( ...
                    ["1","2","3","4","5","6","7","8","9","0","-","=", ...
                     "[","]",";","'","#",",",".","/","\"], ...
                    ["!","@","#","$","%","^","&","*","(",")", "_","+", ...
                     "{","}",":","~","~","<",">","?","|"]);
            end
            if sMap.isKey(keyLabel)
                ch = sMap(keyLabel);
            else
                ch = keyLabel;
            end
        end

        function lbl = keyDisplayLabel(internalLabel)
            %keyDisplayLabel  Map internal key label to display string.
            switch internalLabel
                case "Back";    lbl = "<-";
                case "LShift";  lbl = "Shift";
                case "RShift";  lbl = "Shift";
                case "LCtrl";   lbl = "Ctrl";
                case "RCtrl";   lbl = "Ctrl";
                case "LAlt";    lbl = "Alt";
                case "RAlt";    lbl = "Alt";
                case "Space";   lbl = "";
                otherwise;      lbl = char(internalLabel);
            end
        end
    end
end
