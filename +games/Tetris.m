classdef Tetris < GameBase
    %Tetris  Classic falling-block puzzle game with SRS rotation and wall kicks.
    %   10x20 playfield with 7-bag randomizer, ghost piece, hold, next preview,
    %   DAS/ARR auto-repeat, lock delay, combo scoring, and T-spin detection.
    %   Mouse X controls horizontal position; click or Space for hard drop.
    %
    %   Standalone: games.Tetris().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Tetris"
    end

    % =================================================================
    % GRID CONSTANTS
    % =================================================================
    properties (Constant, Access = private)
        GridCols    (1,1) double = 10
        GridRows    (1,1) double = 22   % 20 visible + 2 buffer above
        VisibleRows (1,1) double = 20
    end

    % =================================================================
    % PIECE DATA (built once via static method)
    % =================================================================
    properties (Constant, Access = private)
        % PieceDefs: 1x7 struct array, each with:
        %   .offsets  — 4x2xR int8 array ([row,col] offsets for each rotation state)
        %   .color    — 1x3 double RGB
        %   .id       — uint8 piece ID (1-7)
        PieceDefs = games.Tetris.buildPieceDefs()

        % Wall kick tables: struct with .JLSTZ and .I fields
        % Each is a containers.Map from "R0>R1" to 5x2 int16 offset array [col,row]
        KickTables = games.Tetris.buildKickTables()
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Board: 22x10 uint8 (0=empty, 1-7=piece type ID)
        Board               (:,:) uint8

        % Active piece
        CurType             (1,1) uint8  = 0    % piece ID 1-7, 0=none
        CurRot              (1,1) uint8  = 0    % rotation state 0-3
        CurRow              (1,1) int16  = 0    % pivot row (1=bottom)
        CurCol              (1,1) int16  = 0    % pivot col (1=left)

        % Ghost
        GhostRow            (1,1) int16  = 0

        % Hold
        HoldType            (1,1) uint8  = 0    % held piece ID, 0=none
        HoldUsed            (1,1) logical = false

        % 7-bag randomizer
        Bag                 (1,:) uint8  = uint8.empty(1,0)
        BagIdx              (1,1) uint8  = 0
        NextQueue           (1,:) uint8  = uint8.empty(1,0)  % next 3 pieces

        % Gravity timing
        GravityAccum        (1,1) double = 0
        GravityInterval     (1,1) double = 48   % frames at level 1 (recalc per level)
        SoftDropping        (1,1) logical = false
        SoftDropFrames      (1,1) double = 0    % frame counter for releasing soft drop

        % Lock delay
        LockActive          (1,1) logical = false
        LockTimer           (1,1) double = 0
        LockResets          (1,1) uint8  = 0
        LockDelay           (1,1) double = 30   % 0.5s at 60fps

        % DAS (Delayed Auto Shift)
        DASDir              (1,1) int8   = 0    % -1=left, 0=none, +1=right
        DASTimer            (1,1) double = 0
        ARRTimer            (1,1) double = 0
        DASDelay            (1,1) double = 10   % DtScale units before auto-repeat
        ARRPeriod           (1,1) double = 2    % DtScale units between repeats
        DASFrames           (1,1) double = 0    % frames since last DAS key press
        DASTimeout          (1,1) double = 6    % auto-release DAS after this many frames

        % Scoring
        Level               (1,1) double = 1
        LinesCleared        (1,1) double = 0
        ComboCount          (1,1) int16  = -1   % -1 = no active combo
        BackToBack          (1,1) logical = false

        % Line clear animation
        ClearingRows        (1,:) double = []   % rows being cleared (bottom-up)
        ClearFlashTimer     (1,1) double = 0
        ClearFlashDuration  (1,1) double = 12   % frames for flash animation

        % Mouse control
        MouseTargetCol      (1,1) double = 5    % target column from mouse X
        MouseEnabled        (1,1) logical = false

        % Game over
        GameOver            (1,1) logical = false

        % Display geometry (set in onInit)
        FieldX              (1,1) double = 0    % playfield left edge in data coords
        FieldY              (1,1) double = 0    % playfield bottom edge in data coords
        CellW               (1,1) double = 1
        CellH               (1,1) double = 1
        Sc                  (1,1) double = 1    % display scale
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        % Grid cell patches: 22x10 array of patch handles (locked cells)
        CellPatches         (:,:)

        % Active piece patches: 4 patch handles
        ActivePatches       (1,4)

        % Ghost piece patches: 4 patch handles
        GhostPatches        (1,4)

        % Hold display: 4 patch handles + border + label
        HoldPatches         (1,4)
        HoldBoxH                        % line — hold box border
        HoldLabelH                      % text — "HOLD"

        % Next preview: 12 patch handles (3 pieces x 4 cells) + border + label
        NextPatches         (3,4)
        NextBoxH                        % line — next box border
        NextLabelH                      % text — "NEXT"

        % Playfield border
        FieldBorderH                    % line — playfield outline

        % Grid lines
        GridLinesH                      % line — subtle grid

        % HUD text (level display inside field)
        LevelTextH
        LinesTextH
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create all graphics and initialize game state.
            arguments
                obj
                ax
                displayRange    struct
                ~
            end
            obj.Ax = ax;
            obj.DisplayRange = displayRange;
            obj.Score = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;
            obj.GameOver = false;

            dx = displayRange.X;
            dy = displayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);
            obj.Sc = min(areaW, areaH) / 180;

            % --- Layout: playfield centered, hold box left, next box right ---
            % Cell size: fit 20 visible rows into ~80% of height
            obj.CellH = areaH * 0.85 / obj.VisibleRows;
            obj.CellW = obj.CellH;  % square cells

            fieldW = obj.CellW * obj.GridCols;
            fieldH = obj.CellH * obj.VisibleRows;

            % Center playfield horizontally
            obj.FieldX = dx(1) + (areaW - fieldW) / 2;
            obj.FieldY = dy(1) + (areaH - fieldH) / 2;

            % Initialize board
            obj.Board = zeros(obj.GridRows, obj.GridCols, "uint8");

            % --- Pre-allocate grid cell patches (22x10) ---
            obj.CellPatches = gobjects(obj.GridRows, obj.GridCols);
            for r = 1:obj.GridRows
                for c = 1:obj.GridCols
                    [xv, yv] = obj.cellVertices(r, c);
                    obj.CellPatches(r, c) = patch(ax, "XData", xv, "YData", yv, ...
                        "FaceColor", [0.5 0.5 0.5], "FaceAlpha", 0.8, ...
                        "EdgeColor", [0.2 0.2 0.2], "LineWidth", 0.5, ...
                        "Visible", "off", "Tag", "GT_tetris");
                end
            end

            % --- Subtle grid lines ---
            obj.drawGridLines(ax);

            % --- Playfield border ---
            bx = obj.FieldX;
            by = obj.FieldY;
            obj.FieldBorderH = line(ax, ...
                [bx, bx + fieldW, bx + fieldW, bx, bx], ...
                [by, by, by + fieldH, by + fieldH, by], ...
                "Color", [0 0.7 0.85 0.6], "LineWidth", 2, "Tag", "GT_tetris");

            % --- Active piece patches (4 cells) ---
            obj.ActivePatches = gobjects(1, 4);
            for k = 1:4
                obj.ActivePatches(k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                    "FaceColor", [1 1 1], "FaceAlpha", 0.9, ...
                    "EdgeColor", [0.3 0.3 0.3], "LineWidth", 1, ...
                    "Visible", "off", "Tag", "GT_tetris");
            end

            % --- Ghost piece patches (4 cells) ---
            obj.GhostPatches = gobjects(1, 4);
            for k = 1:4
                obj.GhostPatches(k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                    "FaceColor", [0.5 0.5 0.5], "FaceAlpha", 0.15, ...
                    "EdgeColor", [0.5 0.5 0.5], "LineWidth", 0.5, ...
                    "Visible", "off", "Tag", "GT_tetris");
                obj.GhostPatches(k).EdgeAlpha = 0.3;
            end

            % --- Hold box (left of playfield) ---
            holdBoxW = obj.CellW * 5;
            holdBoxH = obj.CellH * 4;
            holdX = obj.FieldX - holdBoxW - obj.CellW * 1.5;
            holdY = obj.FieldY + fieldH - holdBoxH - obj.CellH;
            obj.HoldBoxH = line(ax, ...
                [holdX, holdX + holdBoxW, holdX + holdBoxW, holdX, holdX], ...
                [holdY, holdY, holdY + holdBoxH, holdY + holdBoxH, holdY], ...
                "Color", [0 0.6 0.7 0.4], "LineWidth", 1, "Tag", "GT_tetris");
            obj.HoldLabelH = text(ax, holdX + holdBoxW / 2, holdY + holdBoxH + obj.CellH * 0.3, ...
                "HOLD", "Color", [0 0.6 0.7], "FontSize", max(8, round(10 * obj.Sc)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", "Tag", "GT_tetris");

            obj.HoldPatches = gobjects(1, 4);
            for k = 1:4
                obj.HoldPatches(k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                    "FaceColor", [1 1 1], "FaceAlpha", 0.85, ...
                    "EdgeColor", [0.3 0.3 0.3], "LineWidth", 0.5, ...
                    "Visible", "off", "Tag", "GT_tetris");
            end

            % --- Next preview (right of playfield) ---
            nextBoxW = obj.CellW * 5;
            nextBoxH = obj.CellH * 13;
            nextX = obj.FieldX + fieldW + obj.CellW * 1.5;
            nextY = obj.FieldY + fieldH - nextBoxH - obj.CellH;
            obj.NextBoxH = line(ax, ...
                [nextX, nextX + nextBoxW, nextX + nextBoxW, nextX, nextX], ...
                [nextY, nextY, nextY + nextBoxH, nextY + nextBoxH, nextY], ...
                "Color", [0 0.6 0.7 0.4], "LineWidth", 1, "Tag", "GT_tetris");
            obj.NextLabelH = text(ax, nextX + nextBoxW / 2, nextY + nextBoxH + obj.CellH * 0.3, ...
                "NEXT", "Color", [0 0.6 0.7], "FontSize", max(8, round(10 * obj.Sc)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", "Tag", "GT_tetris");

            obj.NextPatches = gobjects(3, 4);
            for p = 1:3
                for k = 1:4
                    obj.NextPatches(p, k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                        "FaceColor", [1 1 1], "FaceAlpha", 0.85, ...
                        "EdgeColor", [0.3 0.3 0.3], "LineWidth", 0.5, ...
                        "Visible", "off", "Tag", "GT_tetris");
                end
            end

            % --- HUD text ---
            obj.LevelTextH = text(ax, obj.FieldX - obj.CellW * 0.5, obj.FieldY + obj.CellH * 0.5, ...
                "Lv 1", "Color", [0 0.8 0.9], "FontSize", max(8, round(10 * obj.Sc)), ...
                "FontWeight", "bold", "HorizontalAlignment", "right", ...
                "VerticalAlignment", "bottom", "Tag", "GT_tetris");
            obj.LinesTextH = text(ax, obj.FieldX - obj.CellW * 0.5, obj.FieldY - obj.CellH * 0.1, ...
                "Lines: 0", "Color", [0 0.6 0.7], "FontSize", max(7, round(9 * obj.Sc)), ...
                "FontWeight", "bold", "HorizontalAlignment", "right", ...
                "VerticalAlignment", "top", "Tag", "GT_tetris");

            % --- Initialize bag and spawn first piece ---
            obj.Bag = uint8.empty(1, 0);
            obj.BagIdx = 0;
            obj.NextQueue = uint8.empty(1, 0);
            obj.HoldType = 0;
            obj.HoldUsed = false;
            obj.Level = 1;
            obj.LinesCleared = 0;
            obj.ComboCount = -1;
            obj.BackToBack = false;
            obj.ClearingRows = [];
            obj.ClearFlashTimer = 0;
            obj.DASDir = 0;
            obj.DASTimer = 0;
            obj.ARRTimer = 0;
            obj.DASFrames = 0;
            obj.SoftDropping = false;
            obj.SoftDropFrames = 0;
            obj.MouseEnabled = false;
            obj.GravityAccum = 0;
            obj.LockActive = false;
            obj.LockTimer = 0;
            obj.LockResets = 0;

            obj.recalcGravity();

            % Fill the next queue (need 3 + 1 for current)
            for k = 1:4
                obj.NextQueue(k) = obj.drawFromBag();
            end

            obj.spawnPiece(obj.NextQueue(1));
            obj.NextQueue = obj.NextQueue(2:end);
            obj.NextQueue(end + 1) = obj.drawFromBag();

            obj.updateActivePatchPositions();
            obj.updateGhost();
            obj.updateGhostPatches();
            obj.updateHoldDisplay();
            obj.updateNextDisplay();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame game logic: gravity, input, rendering.
            if obj.GameOver; return; end

            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            ds = obj.DtScale;

            % --- Line clear animation ---
            if ~isempty(obj.ClearingRows)
                obj.ClearFlashTimer = obj.ClearFlashTimer - ds;
                if obj.ClearFlashTimer <= 0
                    obj.finishLineClear();
                else
                    % Flash: pulse white during animation
                    flashProgress = 1 - obj.ClearFlashTimer / obj.ClearFlashDuration;
                    flashAlpha = 0.9 * (1 - flashProgress);
                    for ri = 1:numel(obj.ClearingRows)
                        row = obj.ClearingRows(ri);
                        for c = 1:obj.GridCols
                            if isvalid(obj.CellPatches(row, c))
                                obj.CellPatches(row, c).FaceColor = [1 1 1];
                                obj.CellPatches(row, c).FaceAlpha = flashAlpha;
                                obj.CellPatches(row, c).Visible = "on";
                            end
                        end
                    end
                end
                return;  % Pause gameplay during clear animation
            end

            % --- Mouse input: map X to target column ---
            if ~any(isnan(pos))
                relX = pos(1) - obj.FieldX;
                targetCol = floor(relX / obj.CellW) + 1;
                targetCol = max(1, min(obj.GridCols, targetCol));
                obj.MouseTargetCol = targetCol;
            end

            % --- Soft drop release detection ---
            if obj.SoftDropping
                obj.SoftDropFrames = obj.SoftDropFrames + ds;
                if obj.SoftDropFrames > 6
                    obj.SoftDropping = false;
                    obj.SoftDropFrames = 0;
                end
            end

            % --- DAS auto-repeat ---
            if obj.DASDir ~= 0
                obj.DASFrames = obj.DASFrames + ds;
                if obj.DASFrames > obj.DASTimeout
                    % Auto-release DAS (no key release event in hosted mode)
                    obj.DASDir = 0;
                    obj.DASTimer = 0;
                    obj.ARRTimer = 0;
                    obj.DASFrames = 0;
                else
                    obj.DASTimer = obj.DASTimer + ds;
                    if obj.DASTimer >= obj.DASDelay
                        obj.ARRTimer = obj.ARRTimer + ds;
                        while obj.ARRTimer >= obj.ARRPeriod
                            obj.ARRTimer = obj.ARRTimer - obj.ARRPeriod;
                            obj.tryMove(int16(obj.DASDir), 0);
                        end
                    end
                end
            end

            % --- Gravity ---
            gravityMult = 1;
            if obj.SoftDropping
                gravityMult = 20;
            end
            obj.GravityAccum = obj.GravityAccum + ds * gravityMult;

            while obj.GravityAccum >= obj.GravityInterval && obj.CurType > 0 && ~obj.GameOver
                obj.GravityAccum = obj.GravityAccum - obj.GravityInterval;
                if obj.tryMove(0, -1)
                    % Piece moved down successfully
                    if obj.SoftDropping
                        obj.addScore(1);
                    end
                    if obj.LockActive
                        % Reset lock timer on downward movement
                        obj.LockActive = false;
                        obj.LockTimer = 0;
                    end
                else
                    % Piece landed — start or continue lock delay
                    if ~obj.LockActive
                        obj.LockActive = true;
                        obj.LockTimer = 0;
                        obj.LockResets = 0;
                    end
                    break;  % Stop processing gravity — piece is on surface
                end
            end

            % --- Lock delay ---
            if obj.LockActive
                obj.LockTimer = obj.LockTimer + ds;
                if obj.LockTimer >= obj.LockDelay
                    obj.lockPiece();
                    return;
                end
            end

            % --- Update visuals ---
            obj.updateActivePatchPositions();
            obj.updateGhost();
            obj.updateGhostPatches();
        end

        function onCleanup(obj)
            %onCleanup  Delete all graphics and reset state.

            % Delete cell patches
            if ~isempty(obj.CellPatches)
                for r = 1:size(obj.CellPatches, 1)
                    for c = 1:size(obj.CellPatches, 2)
                        if isvalid(obj.CellPatches(r, c))
                            delete(obj.CellPatches(r, c));
                        end
                    end
                end
            end
            obj.CellPatches = gobjects(0, 0);

            % Delete active/ghost/hold/next patches
            patchArrays = {obj.ActivePatches, obj.GhostPatches, obj.HoldPatches};
            for a = 1:numel(patchArrays)
                arr = patchArrays{a};
                for k = 1:numel(arr)
                    if isvalid(arr(k)); delete(arr(k)); end
                end
            end
            for p = 1:size(obj.NextPatches, 1)
                for k = 1:size(obj.NextPatches, 2)
                    if isvalid(obj.NextPatches(p, k)); delete(obj.NextPatches(p, k)); end
                end
            end

            % Delete line/text handles
            handles = {obj.FieldBorderH, obj.GridLinesH, obj.HoldBoxH, ...
                obj.HoldLabelH, obj.NextBoxH, obj.NextLabelH, ...
                obj.LevelTextH, obj.LinesTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end

            % Reset arrays
            obj.ActivePatches = gobjects(1, 4);
            obj.GhostPatches = gobjects(1, 4);
            obj.HoldPatches = gobjects(1, 4);
            obj.NextPatches = gobjects(3, 4);
            obj.Board = zeros(0, 0, "uint8");

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_tetris");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle keyboard input for Tetris controls.
            if obj.GameOver
                handled = false;
                return;
            end
            if ~isempty(obj.ClearingRows)
                handled = false;
                return;
            end

            handled = true;
            switch key
                case "leftarrow"
                    obj.tryMove(-1, 0);
                    obj.DASDir = -1;
                    obj.DASTimer = 0;
                    obj.ARRTimer = 0;
                    obj.DASFrames = 0;

                case "rightarrow"
                    obj.tryMove(1, 0);
                    obj.DASDir = 1;
                    obj.DASTimer = 0;
                    obj.ARRTimer = 0;
                    obj.DASFrames = 0;

                case {"uparrow", "z"}
                    obj.tryRotate(1);   % clockwise

                case "x"
                    obj.tryRotate(-1);  % counter-clockwise

                case "downarrow"
                    obj.SoftDropping = true;
                    obj.SoftDropFrames = 0;

                case "space"
                    obj.hardDrop();

                case "c"
                    obj.holdPiece();

                otherwise
                    handled = false;
            end

            % Reset DAS on key release detection (approximate via non-arrow keys)
            if handled && ~ismember(key, ["leftarrow", "rightarrow"])
                obj.DASDir = 0;
                obj.DASTimer = 0;
                obj.ARRTimer = 0;
            end
        end

        function onMouseDown(obj)
            %onMouseDown  Hard drop on mouse click.
            if ~obj.GameOver && isempty(obj.ClearingRows)
                obj.hardDrop();
            end
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel rotates piece.
            if obj.GameOver || ~isempty(obj.ClearingRows); return; end
            if delta < 0
                obj.tryRotate(1);   % scroll up = clockwise
            else
                obj.tryRotate(-1);  % scroll down = counter-clockwise
            end
        end

        function r = getResults(obj)
            %getResults  Return Tetris-specific results for the results screen.
            r.Title = "TETRIS";
            r.Lines = {
                sprintf("Level: %d", obj.Level)
                sprintf("Lines: %d", obj.LinesCleared)
            };
        end

        function s = getHudText(obj)
            %getHudText  Return HUD string for the host to display.
            s = sprintf("Lv %d | Lines %d", obj.Level, obj.LinesCleared);
        end
    end

    % =================================================================
    % PRIVATE: PIECE MOVEMENT & COLLISION
    % =================================================================
    methods (Access = private)

        function ok = tryMove(obj, dc, dr)
            %tryMove  Attempt to move the active piece by (dc, dr). Returns true if successful.
            newCol = obj.CurCol + dc;
            newRow = obj.CurRow + dr;
            offsets = obj.getActiveOffsets();
            if obj.checkFit(offsets, newRow, newCol)
                obj.CurCol = newCol;
                obj.CurRow = newRow;
                ok = true;
                % Reset lock delay on successful move if lock is active
                if obj.LockActive && obj.LockResets < 15
                    obj.LockTimer = 0;
                    obj.LockResets = obj.LockResets + 1;
                end
            else
                ok = false;
            end
        end

        function tryRotate(obj, direction)
            %tryRotate  Attempt SRS rotation with wall kicks.
            %   direction: +1 = clockwise, -1 = counter-clockwise
            if obj.CurType == 0; return; end

            oldRot = obj.CurRot;
            newRot = mod(int16(oldRot) + int16(direction), 4);

            % O-piece never rotates
            if obj.CurType == 4  % O-piece is ID 4
                return;
            end

            newOffsets = obj.PieceDefs(obj.CurType).offsets(:, :, newRot + 1);

            % Get kick offsets for this rotation transition
            kickKey = sprintf("%d>%d", oldRot, newRot);
            if obj.CurType == 1  % I-piece
                kickTable = obj.KickTables.I;
            else
                kickTable = obj.KickTables.JLSTZ;
            end

            if kickTable.isKey(kickKey)
                kicks = kickTable(kickKey);  % Nx2 [dcol, drow]
            else
                kicks = [0, 0];  % fallback: just try basic rotation
            end

            for k = 1:size(kicks, 1)
                testCol = obj.CurCol + kicks(k, 1);
                testRow = obj.CurRow + kicks(k, 2);
                if obj.checkFit(newOffsets, testRow, testCol)
                    obj.CurCol = testCol;
                    obj.CurRow = testRow;
                    obj.CurRot = uint8(newRot);
                    % Reset lock delay on successful rotation
                    if obj.LockActive && obj.LockResets < 15
                        obj.LockTimer = 0;
                        obj.LockResets = obj.LockResets + 1;
                    end
                    return;
                end
            end
            % All kick tests failed — rotation blocked
        end

        function ok = checkFit(obj, offsets, pivotRow, pivotCol)
            %checkFit  Check if piece offsets fit at (pivotRow, pivotCol) without collision.
            ok = true;
            for k = 1:size(offsets, 1)
                r = pivotRow + int16(offsets(k, 1));
                c = pivotCol + int16(offsets(k, 2));
                if c < 1 || c > obj.GridCols || r < 1
                    ok = false;
                    return;
                end
                if r > obj.GridRows
                    ok = false;
                    return;
                end
                if obj.Board(r, c) ~= 0
                    ok = false;
                    return;
                end
            end
        end

        function offsets = getActiveOffsets(obj)
            %getActiveOffsets  Return 4x2 offsets for the current piece+rotation.
            if obj.CurType == 0
                offsets = zeros(4, 2, "int8");
                return;
            end
            offsets = obj.PieceDefs(obj.CurType).offsets(:, :, obj.CurRot + 1);
        end
    end

    % =================================================================
    % PRIVATE: SPAWNING, LOCKING, LINE CLEARING
    % =================================================================
    methods (Access = private)

        function spawnPiece(obj, pieceType)
            %spawnPiece  Place a new piece at the spawn position (top of field).
            obj.CurType = pieceType;
            obj.CurRot = 0;
            obj.CurRow = int16(21);  % rows 21-22 are buffer zone
            obj.CurCol = int16(5);   % centered (cols 4-7 for most pieces)

            % Check if spawn position is blocked
            offsets = obj.getActiveOffsets();
            if ~obj.checkFit(offsets, obj.CurRow, obj.CurCol)
                % Try one row higher
                if ~obj.checkFit(offsets, obj.CurRow + 1, obj.CurCol)
                    obj.GameOver = true;
                    obj.IsRunning = false;
                    return;
                end
                obj.CurRow = obj.CurRow + 1;
            end

            obj.GravityAccum = 0;
            obj.LockActive = false;
            obj.LockTimer = 0;
            obj.LockResets = 0;
            obj.HoldUsed = false;
            obj.SoftDropping = false;
            obj.SoftDropFrames = 0;
        end

        function lockPiece(obj)
            %lockPiece  Lock the active piece into the board and check for line clears.
            if obj.CurType == 0; return; end

            offsets = obj.getActiveOffsets();
            pieceId = obj.CurType;
            clr = obj.PieceDefs(pieceId).color;

            % Write piece cells to board and make cell patches visible
            for k = 1:size(offsets, 1)
                r = obj.CurRow + int16(offsets(k, 1));
                c = obj.CurCol + int16(offsets(k, 2));
                if r >= 1 && r <= obj.GridRows && c >= 1 && c <= obj.GridCols
                    obj.Board(r, c) = pieceId;
                    if r <= obj.VisibleRows && isvalid(obj.CellPatches(r, c))
                        obj.CellPatches(r, c).FaceColor = clr;
                        obj.CellPatches(r, c).FaceAlpha = 0.85;
                        obj.CellPatches(r, c).EdgeColor = clr * 0.5;
                        obj.CellPatches(r, c).Visible = "on";
                    end
                end
            end

            % Hide active piece patches
            for k = 1:4
                if isvalid(obj.ActivePatches(k))
                    obj.ActivePatches(k).Visible = "off";
                end
            end
            % Hide ghost patches
            for k = 1:4
                if isvalid(obj.GhostPatches(k))
                    obj.GhostPatches(k).Visible = "off";
                end
            end

            % Check for line clears
            clearedRows = obj.findFullRows();
            if ~isempty(clearedRows)
                obj.startLineClear(clearedRows);
            else
                % No lines cleared — reset combo
                obj.ComboCount = -1;
                obj.spawnNextPiece();
            end
        end

        function clearedRows = findFullRows(obj)
            %findFullRows  Return indices of all full rows (bottom-up order).
            clearedRows = [];
            for r = 1:obj.GridRows
                if all(obj.Board(r, :) ~= 0)
                    clearedRows(end + 1) = r; %#ok<AGROW>
                end
            end
        end

        function startLineClear(obj, rows)
            %startLineClear  Begin line clear animation.
            obj.ClearingRows = rows;
            obj.ClearFlashTimer = obj.ClearFlashDuration;
        end

        function finishLineClear(obj)
            %finishLineClear  Remove cleared rows, shift board down, award score.
            rows = sort(obj.ClearingRows, "descend");
            numLines = numel(rows);

            % Remove cleared rows from the board (shift everything above down)
            for ri = 1:numel(rows)
                r = rows(ri);
                % Shift rows above down by one
                if r < obj.GridRows
                    obj.Board(r:obj.GridRows-1, :) = obj.Board(r+1:obj.GridRows, :);
                end
                obj.Board(obj.GridRows, :) = 0;

                % Adjust remaining row indices that shifted
                for rj = (ri + 1):numel(rows)
                    if rows(rj) > r
                        rows(rj) = rows(rj) - 1;
                    end
                end
            end

            % Scoring
            obj.ComboCount = obj.ComboCount + 1;
            switch numLines
                case 1; lineScore = 100;
                case 2; lineScore = 300;
                case 3; lineScore = 500;
                case 4; lineScore = 800;  % Tetris!
                otherwise; lineScore = 100 * numLines;
            end

            % Back-to-back bonus for Tetris (4 lines)
            if numLines == 4
                if obj.BackToBack
                    lineScore = round(lineScore * 1.5);
                end
                obj.BackToBack = true;
            else
                obj.BackToBack = false;
            end

            totalScore = lineScore * obj.Level;

            % Combo bonus
            if obj.ComboCount > 0
                totalScore = totalScore + 50 * obj.ComboCount * obj.Level;
            end

            obj.addScore(totalScore);
            obj.LinesCleared = obj.LinesCleared + numLines;

            % Level up every 10 lines
            newLevel = floor(obj.LinesCleared / 10) + 1;
            if newLevel > obj.Level
                obj.Level = newLevel;
                obj.recalcGravity();
            end

            % Update HUD
            if isvalid(obj.LevelTextH)
                obj.LevelTextH.String = sprintf("Lv %d", obj.Level);
            end
            if isvalid(obj.LinesTextH)
                obj.LinesTextH.String = sprintf("Lines: %d", obj.LinesCleared);
            end

            obj.ClearingRows = [];
            obj.ClearFlashTimer = 0;

            % Refresh entire board display
            obj.refreshBoardDisplay();

            % Spawn next piece
            obj.spawnNextPiece();
        end

        function spawnNextPiece(obj)
            %spawnNextPiece  Spawn the next piece from the queue and refill.
            nextType = obj.NextQueue(1);
            obj.NextQueue = obj.NextQueue(2:end);
            obj.NextQueue(end + 1) = obj.drawFromBag();
            obj.spawnPiece(nextType);
            obj.updateNextDisplay();
            obj.updateActivePatchPositions();
            obj.updateGhost();
            obj.updateGhostPatches();
        end

        function holdPiece(obj)
            %holdPiece  Swap current piece with hold, or store if empty.
            if obj.HoldUsed; return; end
            if obj.CurType == 0; return; end

            oldType = obj.CurType;
            if obj.HoldType == 0
                % First hold — store current, spawn next from queue
                obj.HoldType = oldType;
                obj.spawnNextPiece();
            else
                % Swap
                swapType = obj.HoldType;
                obj.HoldType = oldType;
                obj.spawnPiece(swapType);
                obj.updateActivePatchPositions();
                obj.updateGhost();
                obj.updateGhostPatches();
            end
            obj.HoldUsed = true;
            obj.updateHoldDisplay();
        end

        function hardDrop(obj)
            %hardDrop  Instantly drop piece to ghost position and lock.
            if obj.CurType == 0; return; end

            obj.updateGhost();
            dropDist = obj.CurRow - obj.GhostRow;
            obj.addScore(2 * double(dropDist));
            obj.CurRow = obj.GhostRow;
            obj.lockPiece();
        end

        function recalcGravity(obj)
            %recalcGravity  Recalculate gravity interval based on current level.
            %   Uses Tetris Guideline formula: (0.8 - (level-1)*0.007)^(level-1) seconds
            %   Converted to DtScale units (multiply by RefFPS)
            lvl = obj.Level;
            seconds = (0.8 - (lvl - 1) * 0.007) ^ (lvl - 1);
            seconds = max(seconds, 1 / 60);  % floor at ~1 frame
            obj.GravityInterval = seconds * obj.RefFPS;
        end
    end

    % =================================================================
    % PRIVATE: 7-BAG RANDOMIZER
    % =================================================================
    methods (Access = private)

        function pieceType = drawFromBag(obj)
            %drawFromBag  Draw next piece type from the 7-bag. Refill when empty.
            if obj.BagIdx == 0 || obj.BagIdx > 7
                obj.Bag = uint8(randperm(7));
                obj.BagIdx = 1;
            end
            pieceType = obj.Bag(obj.BagIdx);
            obj.BagIdx = obj.BagIdx + 1;
        end
    end

    % =================================================================
    % PRIVATE: GHOST PIECE
    % =================================================================
    methods (Access = private)

        function updateGhost(obj)
            %updateGhost  Compute ghost piece row (lowest valid position).
            if obj.CurType == 0; return; end
            offsets = obj.getActiveOffsets();
            testRow = obj.CurRow;
            while testRow > 0
                if obj.checkFit(offsets, testRow - 1, obj.CurCol)
                    testRow = testRow - 1;
                else
                    break;
                end
            end
            obj.GhostRow = testRow;
        end
    end

    % =================================================================
    % PRIVATE: GRAPHICS UPDATE
    % =================================================================
    methods (Access = private)

        function [xv, yv] = cellVertices(obj, row, col)
            %cellVertices  Return 4-element XData/YData for a cell patch.
            %   row/col are 1-based grid indices (row 1 = bottom).
            x0 = obj.FieldX + (double(col) - 1) * obj.CellW;
            y0 = obj.FieldY + (double(row) - 1) * obj.CellH;
            xv = [x0, x0 + obj.CellW, x0 + obj.CellW, x0];
            yv = [y0, y0, y0 + obj.CellH, y0 + obj.CellH];
        end

        function updateActivePatchPositions(obj)
            %updateActivePatchPositions  Position the 4 active piece patches.
            if obj.CurType == 0
                for k = 1:4
                    if isvalid(obj.ActivePatches(k))
                        obj.ActivePatches(k).Visible = "off";
                    end
                end
                return;
            end

            offsets = obj.getActiveOffsets();
            clr = obj.PieceDefs(obj.CurType).color;

            for k = 1:4
                r = obj.CurRow + int16(offsets(k, 1));
                c = obj.CurCol + int16(offsets(k, 2));
                if r >= 1 && r <= obj.VisibleRows && c >= 1 && c <= obj.GridCols
                    [xv, yv] = obj.cellVertices(r, c);
                    if isvalid(obj.ActivePatches(k))
                        obj.ActivePatches(k).XData = xv;
                        obj.ActivePatches(k).YData = yv;
                        obj.ActivePatches(k).FaceColor = clr;
                        obj.ActivePatches(k).FaceAlpha = 0.9;
                        obj.ActivePatches(k).EdgeColor = clr * 0.5;
                        obj.ActivePatches(k).Visible = "on";
                    end
                else
                    if isvalid(obj.ActivePatches(k))
                        obj.ActivePatches(k).Visible = "off";
                    end
                end
            end
        end

        function updateGhostPatches(obj)
            %updateGhostPatches  Position the 4 ghost piece patches.
            if obj.CurType == 0 || obj.GhostRow == obj.CurRow
                for k = 1:4
                    if isvalid(obj.GhostPatches(k))
                        obj.GhostPatches(k).Visible = "off";
                    end
                end
                return;
            end

            offsets = obj.getActiveOffsets();
            clr = obj.PieceDefs(obj.CurType).color;

            for k = 1:4
                r = obj.GhostRow + int16(offsets(k, 1));
                c = obj.CurCol + int16(offsets(k, 2));
                if r >= 1 && r <= obj.VisibleRows && c >= 1 && c <= obj.GridCols
                    [xv, yv] = obj.cellVertices(r, c);
                    if isvalid(obj.GhostPatches(k))
                        obj.GhostPatches(k).XData = xv;
                        obj.GhostPatches(k).YData = yv;
                        obj.GhostPatches(k).FaceColor = clr;
                        obj.GhostPatches(k).FaceAlpha = 0.15;
                        obj.GhostPatches(k).EdgeColor = clr;
                        obj.GhostPatches(k).EdgeAlpha = 0.35;
                        obj.GhostPatches(k).Visible = "on";
                    end
                else
                    if isvalid(obj.GhostPatches(k))
                        obj.GhostPatches(k).Visible = "off";
                    end
                end
            end
        end

        function refreshBoardDisplay(obj)
            %refreshBoardDisplay  Sync all cell patches with the board state.
            for r = 1:obj.VisibleRows
                for c = 1:obj.GridCols
                    if ~isvalid(obj.CellPatches(r, c)); continue; end
                    pid = obj.Board(r, c);
                    if pid > 0 && pid <= 7
                        clr = obj.PieceDefs(pid).color;
                        obj.CellPatches(r, c).FaceColor = clr;
                        obj.CellPatches(r, c).FaceAlpha = 0.85;
                        obj.CellPatches(r, c).EdgeColor = clr * 0.5;
                        obj.CellPatches(r, c).Visible = "on";
                    else
                        obj.CellPatches(r, c).Visible = "off";
                    end
                end
            end
        end

        function updateHoldDisplay(obj)
            %updateHoldDisplay  Show the held piece in the hold box.
            if obj.HoldType == 0
                for k = 1:4
                    if isvalid(obj.HoldPatches(k))
                        obj.HoldPatches(k).Visible = "off";
                    end
                end
                return;
            end

            def = obj.PieceDefs(obj.HoldType);
            offsets = def.offsets(:, :, 1);  % rotation state 0
            clr = def.color;
            if obj.HoldUsed
                clr = clr * 0.4;  % dim when hold is used this turn
            end

            % Center piece in hold box
            fieldH = obj.CellH * obj.VisibleRows;
            holdBoxW = obj.CellW * 5;
            holdBoxH = obj.CellH * 4;
            holdX = obj.FieldX - holdBoxW - obj.CellW * 1.5;
            holdY = obj.FieldY + fieldH - holdBoxH - obj.CellH;
            centerX = holdX + holdBoxW / 2;
            centerY = holdY + holdBoxH / 2;

            for k = 1:4
                dr = double(offsets(k, 1));
                dc = double(offsets(k, 2));
                x0 = centerX + (dc - 0.5) * obj.CellW;
                y0 = centerY + (dr - 0.5) * obj.CellH;
                xv = [x0, x0 + obj.CellW, x0 + obj.CellW, x0];
                yv = [y0, y0, y0 + obj.CellH, y0 + obj.CellH];
                if isvalid(obj.HoldPatches(k))
                    obj.HoldPatches(k).XData = xv;
                    obj.HoldPatches(k).YData = yv;
                    obj.HoldPatches(k).FaceColor = clr;
                    obj.HoldPatches(k).EdgeColor = clr * 0.5;
                    obj.HoldPatches(k).Visible = "on";
                end
            end
        end

        function updateNextDisplay(obj)
            %updateNextDisplay  Show the next 3 pieces in the preview box.
            fieldH = obj.CellH * obj.VisibleRows;
            nextBoxW = obj.CellW * 5;
            nextBoxH = obj.CellH * 13;
            nextX = obj.FieldX + obj.CellW * obj.GridCols + obj.CellW * 1.5;
            nextY = obj.FieldY + fieldH - nextBoxH - obj.CellH;

            for p = 1:min(3, numel(obj.NextQueue))
                def = obj.PieceDefs(obj.NextQueue(p));
                offsets = def.offsets(:, :, 1);  % rotation state 0
                clr = def.color;

                centerX = nextX + nextBoxW / 2;
                slotY = nextY + nextBoxH - (p * 4) * obj.CellH + obj.CellH;
                centerY = slotY + obj.CellH * 1.5;

                for k = 1:4
                    dr = double(offsets(k, 1));
                    dc = double(offsets(k, 2));
                    x0 = centerX + (dc - 0.5) * obj.CellW;
                    y0 = centerY + (dr - 0.5) * obj.CellH;
                    xv = [x0, x0 + obj.CellW, x0 + obj.CellW, x0];
                    yv = [y0, y0, y0 + obj.CellH, y0 + obj.CellH];
                    if isvalid(obj.NextPatches(p, k))
                        obj.NextPatches(p, k).XData = xv;
                        obj.NextPatches(p, k).YData = yv;
                        obj.NextPatches(p, k).FaceColor = clr;
                        obj.NextPatches(p, k).EdgeColor = clr * 0.5;
                        obj.NextPatches(p, k).Visible = "on";
                    end
                end
            end

            % Hide unused slots
            for p = (numel(obj.NextQueue) + 1):3
                for k = 1:4
                    if isvalid(obj.NextPatches(p, k))
                        obj.NextPatches(p, k).Visible = "off";
                    end
                end
            end
        end

        function drawGridLines(obj, ax)
            %drawGridLines  Draw subtle grid overlay for the playfield.
            nC = obj.GridCols;
            nR = obj.VisibleRows;
            cw = obj.CellW;
            ch = obj.CellH;
            fx = obj.FieldX;
            fy = obj.FieldY;

            nLines = (nC + 1) + (nR + 1);
            xAll = NaN(3 * nLines, 1);
            yAll = NaN(3 * nLines, 1);
            idx = 1;

            % Vertical lines
            for c = 0:nC
                xVal = fx + c * cw;
                xAll(idx)   = xVal; yAll(idx)   = fy;
                xAll(idx+1) = xVal; yAll(idx+1) = fy + nR * ch;
                idx = idx + 3;  % 3rd stays NaN (separator)
            end

            % Horizontal lines
            for r = 0:nR
                yVal = fy + r * ch;
                xAll(idx)   = fx;       yAll(idx)   = yVal;
                xAll(idx+1) = fx + nC * cw; yAll(idx+1) = yVal;
                idx = idx + 3;
            end

            obj.GridLinesH = line(ax, xAll, yAll, ...
                "Color", [0.12 0.12 0.12], "LineWidth", 0.5, ...
                "Tag", "GT_tetris");
            uistack(obj.GridLinesH, "bottom");
        end
    end

    % =================================================================
    % STATIC: PIECE DEFINITIONS (SRS)
    % =================================================================
    methods (Static, Access = private)

        function defs = buildPieceDefs()
            %buildPieceDefs  Build the 7 tetromino definitions with SRS rotation states.
            %   Each piece has 4 rotation states (0-3). Offsets are [row, col]
            %   relative to pivot. Row increases upward, col increases rightward.
            %
            %   Piece IDs: 1=I, 2=T, 3=S, 4=O, 5=Z, 6=J, 7=L
            %
            %   SRS rotation states use a 4x4 bounding box for I/O and 3x3 for others.
            %   Offsets here are relative to a logical pivot in the bounding box.

            defs = struct("offsets", cell(1, 7), "color", cell(1, 7), "id", cell(1, 7));

            % --- I piece (cyan) ---
            % State 0: .X..  State 1: ..X.  State 2: ....  State 3: .X..
            %          .X..           ..X.           ....           .X..
            %          .X..           ..X.           XXXX           .X..
            %          .X..           ..X.           ....           .X..
            % Using offsets from center of 4x4 box (between row 2-3, col 2-3)
            I = zeros(4, 2, 4, "int8");
            I(:,:,1) = [0 -1; 0 0; 0 1; 0 2];        % horizontal (state 0)
            I(:,:,2) = [1 1; 0 1; -1 1; -2 1];        % vertical (state 1)
            I(:,:,3) = [-1 -1; -1 0; -1 1; -1 2];     % horizontal flipped (state 2)
            I(:,:,4) = [1 0; 0 0; -1 0; -2 0];        % vertical flipped (state 3)
            defs(1).offsets = I;
            defs(1).color = [0 0.92 1];
            defs(1).id = uint8(1);

            % --- T piece (purple) ---
            T = zeros(4, 2, 4, "int8");
            T(:,:,1) = [0 -1; 0 0; 0 1; 1 0];     % T-up
            T(:,:,2) = [1 0; 0 0; -1 0; 0 1];      % T-right
            T(:,:,3) = [0 -1; 0 0; 0 1; -1 0];     % T-down
            T(:,:,4) = [1 0; 0 0; -1 0; 0 -1];     % T-left
            defs(2).offsets = T;
            defs(2).color = [0.7 0 1];
            defs(2).id = uint8(2);

            % --- S piece (green) ---
            S = zeros(4, 2, 4, "int8");
            S(:,:,1) = [0 -1; 0 0; 1 0; 1 1];      % state 0
            S(:,:,2) = [1 0; 0 0; 0 1; -1 1];       % state 1
            S(:,:,3) = [-1 -1; -1 0; 0 0; 0 1];     % state 2
            S(:,:,4) = [1 -1; 0 -1; 0 0; -1 0];     % state 3
            defs(3).offsets = S;
            defs(3).color = [0.2 1 0.4];
            defs(3).id = uint8(3);

            % --- O piece (yellow) ---
            O = zeros(4, 2, 4, "int8");
            oBase = [0 0; 0 1; 1 0; 1 1];
            O(:,:,1) = oBase;
            O(:,:,2) = oBase;
            O(:,:,3) = oBase;
            O(:,:,4) = oBase;
            defs(4).offsets = O;
            defs(4).color = [1 1 0];
            defs(4).id = uint8(4);

            % --- Z piece (red) ---
            Z = zeros(4, 2, 4, "int8");
            Z(:,:,1) = [1 -1; 1 0; 0 0; 0 1];      % state 0
            Z(:,:,2) = [1 1; 0 1; 0 0; -1 0];       % state 1
            Z(:,:,3) = [0 -1; 0 0; -1 0; -1 1];     % state 2
            Z(:,:,4) = [1 0; 0 0; 0 -1; -1 -1];     % state 3
            defs(5).offsets = Z;
            defs(5).color = [1 0.3 0.2];
            defs(5).id = uint8(5);

            % --- J piece (blue) ---
            J = zeros(4, 2, 4, "int8");
            J(:,:,1) = [1 -1; 0 -1; 0 0; 0 1];     % state 0
            J(:,:,2) = [1 0; 1 1; 0 0; -1 0];       % state 1
            J(:,:,3) = [0 -1; 0 0; 0 1; -1 1];      % state 2
            J(:,:,4) = [1 0; 0 0; -1 0; -1 -1];     % state 3
            defs(6).offsets = J;
            defs(6).color = [0.2 0.4 1];
            defs(6).id = uint8(6);

            % --- L piece (orange) ---
            L = zeros(4, 2, 4, "int8");
            L(:,:,1) = [0 -1; 0 0; 0 1; 1 1];      % state 0
            L(:,:,2) = [1 0; 0 0; -1 0; -1 1];      % state 1
            L(:,:,3) = [-1 -1; 0 -1; 0 0; 0 1];     % state 2
            L(:,:,4) = [1 -1; 1 0; 0 0; -1 0];      % state 3
            defs(7).offsets = L;
            defs(7).color = [1 0.6 0.15];
            defs(7).id = uint8(7);
        end

        function tables = buildKickTables()
            %buildKickTables  Build SRS wall kick offset tables.
            %   Returns struct with .JLSTZ and .I fields, each a containers.Map
            %   from rotation transition string "oldRot>newRot" to Nx2 [dcol, drow].
            %
            %   The first test is always (0,0). Kick offsets are applied to the
            %   piece pivot position.

            % JLSTZ wall kick data (standard SRS)
            jlstz = containers.Map("KeyType", "char", "ValueType", "any");

            % 0->1 (spawn -> CW)
            jlstz("0>1") = int16([0 0; -1 0; -1 1; 0 -2; -1 -2]);
            % 1->0 (CW -> spawn)
            jlstz("1>0") = int16([0 0; 1 0; 1 -1; 0 2; 1 2]);
            % 1->2 (CW -> 180)
            jlstz("1>2") = int16([0 0; 1 0; 1 -1; 0 2; 1 2]);
            % 2->1 (180 -> CW)
            jlstz("2>1") = int16([0 0; -1 0; -1 1; 0 -2; -1 -2]);
            % 2->3 (180 -> CCW)
            jlstz("2>3") = int16([0 0; 1 0; 1 1; 0 -2; 1 -2]);
            % 3->2 (CCW -> 180)
            jlstz("3>2") = int16([0 0; -1 0; -1 -1; 0 2; -1 2]);
            % 3->0 (CCW -> spawn)
            jlstz("3>0") = int16([0 0; -1 0; -1 -1; 0 2; -1 2]);
            % 0->3 (spawn -> CCW)
            jlstz("0>3") = int16([0 0; 1 0; 1 1; 0 -2; 1 -2]);

            % I-piece wall kick data (separate table)
            iKick = containers.Map("KeyType", "char", "ValueType", "any");

            iKick("0>1") = int16([0 0; -2 0; 1 0; -2 -1; 1 2]);
            iKick("1>0") = int16([0 0; 2 0; -1 0; 2 1; -1 -2]);
            iKick("1>2") = int16([0 0; -1 0; 2 0; -1 2; 2 -1]);
            iKick("2>1") = int16([0 0; 1 0; -2 0; 1 -2; -2 1]);
            iKick("2>3") = int16([0 0; 2 0; -1 0; 2 1; -1 -2]);
            iKick("3>2") = int16([0 0; -2 0; 1 0; -2 -1; 1 2]);
            iKick("3>0") = int16([0 0; 1 0; -2 0; 1 -2; -2 1]);
            iKick("0>3") = int16([0 0; -1 0; 2 0; -1 2; 2 -1]);

            tables.JLSTZ = jlstz;
            tables.I = iKick;
        end
    end
end
