classdef Tetris < GameBase
    %Tetris  Classic falling-block puzzle game with SRS rotation and wall kicks.
    %   10-wide x 20-visible playfield (+ 2 hidden buffer rows at top).
    %   7-bag randomizer, ghost piece, hold, 3-piece next preview, DAS/ARR
    %   auto-repeat, lock delay with move resets, combo and back-to-back
    %   scoring. Two-layer neon patch rendering (glow + face) matching the
    %   Breakout brick style.
    %
    %   Controls:
    %     Mouse/finger X -> horizontal piece targeting
    %     Click / Space  -> hard drop
    %     Scroll wheel   -> rotate (up=CW, down=CCW)
    %     Left/Right     -> shift piece (DAS auto-repeat)
    %     Up / Z         -> rotate clockwise
    %     X              -> rotate counter-clockwise
    %     Down           -> soft drop (20x gravity)
    %     C              -> hold piece
    %
    %   Coordinate convention (YDir = "reverse"):
    %     Row 1  = TOP of the board (low Y on screen, where pieces spawn)
    %     Row 22 = BOTTOM of the board (high Y on screen)
    %     Gravity INCREASES the row number.
    %     Cell (r,c) top-left corner: x = FieldX + (c-1)*CellW,
    %                                  y = FieldY + (r-1)*CellH
    %
    %   Standalone: games.Tetris().play()
    %   Hosted:     Called via ArcadeGameLauncher / GameHost
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Tetris"
    end

    % =================================================================
    % GRID CONSTANTS
    % =================================================================
    properties (Constant, Access = private)
        NCols       (1,1) double = 10
        NRows       (1,1) double = 22   % 20 visible + 2 hidden buffer at top
        NVisible    (1,1) double = 20   % rows 3..22 are visible (indices 3-22)

        % Piece colors (neon palette)
        ColorI      (1,3) double = [0, 0.92, 1]       % cyan
        ColorO      (1,3) double = [1, 0.85, 0.2]     % gold
        ColorT      (1,3) double = [0.7, 0.3, 1]      % neon purple
        ColorS      (1,3) double = [0.2, 1, 0.4]      % green
        ColorZ      (1,3) double = [1, 0.3, 0.2]      % red
        ColorJ      (1,3) double = [0.3, 0.5, 1]      % neon blue
        ColorL      (1,3) double = [1, 0.6, 0.15]     % orange
    end

    % =================================================================
    % PIECE DATA (built once via static methods, shared across instances)
    % =================================================================
    properties (Constant, Access = private)
        % PieceCells: 7x1 cell array. Each cell holds a 4x2x4 int8 array.
        %   Dim 1 = 4 minos, Dim 2 = [row, col] offset from pivot,
        %   Dim 3 = rotation state 0..3.
        %   Row increases downward, col increases rightward.
        PieceCells = games.Tetris.buildPieceCells()

        % PieceColors: 7x3 double array of RGB colors indexed by piece ID.
        PieceClrs = [0 0.92 1; 1 0.85 0.2; 0.7 0.3 1; ...
                     0.2 1 0.4; 1 0.3 0.2; 0.3 0.5 1; 1 0.6 0.15]

        % Wall kick tables: struct with .JLSTZ and .I, each containers.Map
        % Key = "R0>R1" (e.g. "0>1"), Value = Nx2 int16 [dcol, drow]
        % drow positive = downward (increasing row).
        KickTables = games.Tetris.buildKickTables()
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Board: NRows x NCols uint8 (0 = empty, 1-7 = piece ID)
        Board               (:,:) uint8

        % Active piece
        CurPiece            (1,1) uint8  = 0     % piece ID 1-7, 0 = none
        CurRot              (1,1) uint8  = 0     % rotation state 0-3
        CurRow              (1,1) int16  = 0     % pivot row (row 1 = top)
        CurCol              (1,1) int16  = 0     % pivot col (col 1 = left)

        % Ghost
        GhostRow            (1,1) int16  = 0     % ghost pivot row

        % Hold
        HoldPiece           (1,1) uint8  = 0     % held piece ID, 0 = none
        HoldLocked          (1,1) logical = false % true = already held this turn

        % 7-bag randomizer
        Bag                 (1,:) uint8  = uint8.empty(1, 0)
        BagIdx              (1,1) uint8  = 0
        NextQueue           (1,:) uint8  = uint8.empty(1, 0)

        % Gravity
        GravAccum           (1,1) double = 0
        GravInterval        (1,1) double = 48    % DtScale units per row drop
        IsSoftDrop          (1,1) logical = false
        SoftDropTimer       (1,1) double = 0     % frames since soft drop key

        % Lock delay
        LockActive          (1,1) logical = false
        LockTimer           (1,1) double = 0
        LockMoveCount       (1,1) uint8  = 0     % move/rotate resets used
        LockDelay           (1,1) double = 30    % 0.5s at 60 fps

        % DAS (Delayed Auto Shift)
        DASDir              (1,1) int8   = 0     % -1 left, 0 none, +1 right
        DASTimer            (1,1) double = 0     % accumulator for initial delay
        ARRTimer            (1,1) double = 0     % accumulator for repeat rate
        DASDelay            (1,1) double = 10    % DtScale units before repeat
        ARRPeriod           (1,1) double = 2     % DtScale units between repeats
        DASAge              (1,1) double = 0     % frames since DAS key pressed
        DASTimeout          (1,1) double = 6     % auto-release after N frames

        % Scoring / progression
        Level               (1,1) double = 1
        TotalLines          (1,1) double = 0
        ComboCount          (1,1) int16  = -1    % -1 = no active combo
        IsBackToBack        (1,1) logical = false

        % Line clear animation
        ClearRows           (1,:) double = []    % row indices being cleared
        ClearTimer          (1,1) double = 0
        ClearDuration       (1,1) double = 12    % frames for flash

        % Mouse / finger control
        MouseTargetCol      (1,1) double = 5
        MouseActive         (1,1) logical = false

        % Game over flag
        GameOver            (1,1) logical = false

        % Layout geometry (computed in onInit)
        FieldX              (1,1) double = 0     % left edge of playfield
        FieldY              (1,1) double = 0     % top edge of VISIBLE field
        CellW               (1,1) double = 1     % cell width in data units
        CellH               (1,1) double = 1     % cell height in data units
        Sc                  (1,1) double = 1     % display scale factor
        CellGap             (1,1) double = 0     % gap between cells (data units)

        % Hold / Next box geometry (cached for display updates)
        HoldCenterX         (1,1) double = 0
        HoldCenterY         (1,1) double = 0
        NextBoxX            (1,1) double = 0
        NextBoxY            (1,1) double = 0
        NextBoxW            (1,1) double = 0
        NextBoxH            (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        % Locked board cells: NRows x NCols x 2 (glow, face)
        % Only visible rows (3..22) get rendered, but we allocate for all
        % 22 rows so indexing is direct.
        BoardGlow           (:,:)   % NRows x NCols patch handles (glow layer)
        BoardFace           (:,:)   % NRows x NCols patch handles (face layer)

        % Active piece: 4 glow + 4 face patches
        ActiveGlow          (1,4)
        ActiveFace          (1,4)

        % Ghost piece: 4 patches (single layer, translucent)
        GhostPatch          (1,4)

        % Hold display: 4 glow + 4 face patches
        HoldGlow            (1,4)
        HoldFace            (1,4)
        HoldBorderH                 % line handle
        HoldLabelH                  % text handle

        % Next preview: 3 pieces x 4 cells = 12 glow + 12 face patches
        NextGlow            (3,4)
        NextFace            (3,4)
        NextBorderH                 % line handle
        NextLabelH                  % text handle

        % Field border and grid
        FieldBorderH                % line handle
        GridLinesH                  % line handle

        % In-field HUD
        LevelTextH                  % text handle
        LinesTextH                  % text handle
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

            % --- Compute cell size: field ~35-40% of width, square cells ---
            cellSz = areaW * 0.035;
            fieldH = cellSz * obj.NVisible;
            if fieldH > areaH * 0.90
                cellSz = (areaH * 0.90) / obj.NVisible;
            end
            obj.CellW = cellSz;
            obj.CellH = cellSz;
            obj.CellGap = max(1, round(1.5 * obj.Sc));

            fieldW = obj.CellW * obj.NCols;
            fieldH = obj.CellH * obj.NVisible;

            % Center playfield horizontally and vertically
            obj.FieldX = dx(1) + (areaW - fieldW) / 2;
            obj.FieldY = dy(1) + (areaH - fieldH) / 2;

            % --- Initialize board ---
            obj.Board = zeros(obj.NRows, obj.NCols, "uint8");

            % --- Pre-allocate board cell patches (glow + face for all rows) ---
            obj.BoardGlow = gobjects(obj.NRows, obj.NCols);
            obj.BoardFace = gobjects(obj.NRows, obj.NCols);
            for r = 1:obj.NRows
                for c = 1:obj.NCols
                    [xv, yv] = obj.cellVerts(r, c);
                    obj.BoardGlow(r, c) = patch(ax, "XData", xv, "YData", yv, ...
                        "FaceColor", [0.5 0.5 0.5], "FaceAlpha", 0, ...
                        "EdgeColor", [0.15 0.15 0.15], "LineWidth", 3, ...
                        "Visible", "off", "Tag", "GT_tetris");
                    obj.BoardFace(r, c) = patch(ax, "XData", xv, "YData", yv, ...
                        "FaceColor", [0.5 0.5 0.5], "FaceAlpha", 0.7, ...
                        "EdgeColor", [0.3 0.3 0.3], "LineWidth", 1, ...
                        "Visible", "off", "Tag", "GT_tetris");
                end
            end

            % --- Subtle grid lines ---
            obj.drawGrid(ax);

            % --- Playfield border (cyan outline) ---
            bx = obj.FieldX;
            by = obj.FieldY;
            obj.FieldBorderH = line(ax, ...
                [bx, bx + fieldW, bx + fieldW, bx, bx], ...
                [by, by, by + fieldH, by + fieldH, by], ...
                "Color", [0, 0.7, 0.85, 0.6], "LineWidth", 2, "Tag", "GT_tetris");

            % --- Active piece patches (4 cells, glow + face) ---
            obj.ActiveGlow = gobjects(1, 4);
            obj.ActiveFace = gobjects(1, 4);
            for k = 1:4
                obj.ActiveGlow(k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                    "FaceColor", [1 1 1], "FaceAlpha", 0, ...
                    "EdgeColor", [0.15 0.15 0.15], "LineWidth", 3, ...
                    "Visible", "off", "Tag", "GT_tetris");
                obj.ActiveFace(k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                    "FaceColor", [1 1 1], "FaceAlpha", 0.85, ...
                    "EdgeColor", [1 1 1], "LineWidth", 1, ...
                    "Visible", "off", "Tag", "GT_tetris");
            end

            % --- Ghost piece patches (single-layer, translucent) ---
            obj.GhostPatch = gobjects(1, 4);
            for k = 1:4
                obj.GhostPatch(k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                    "FaceColor", [0.5 0.5 0.5], "FaceAlpha", 0.12, ...
                    "EdgeColor", [0.5 0.5 0.5], "LineWidth", 0.5, ...
                    "Visible", "off", "Tag", "GT_tetris");
            end

            % --- Hold box (left of playfield) ---
            holdBoxW = obj.CellW * 5;
            holdBoxH = obj.CellH * 4;
            holdX = obj.FieldX - holdBoxW - obj.CellW * 1.5;
            holdY = obj.FieldY + obj.CellH;
            obj.HoldCenterX = holdX + holdBoxW / 2;
            obj.HoldCenterY = holdY + holdBoxH / 2;

            obj.HoldBorderH = line(ax, ...
                [holdX, holdX + holdBoxW, holdX + holdBoxW, holdX, holdX], ...
                [holdY, holdY, holdY + holdBoxH, holdY + holdBoxH, holdY], ...
                "Color", [0, 0.6, 0.7, 0.4], "LineWidth", 1, "Tag", "GT_tetris");
            obj.HoldLabelH = text(ax, holdX + holdBoxW / 2, holdY - obj.CellH * 0.3, ...
                "HOLD", "Color", [0, 0.6, 0.7], ...
                "FontSize", max(8, round(10 * obj.Sc)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", "Tag", "GT_tetris");

            obj.HoldGlow = gobjects(1, 4);
            obj.HoldFace = gobjects(1, 4);
            for k = 1:4
                obj.HoldGlow(k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                    "FaceColor", [1 1 1], "FaceAlpha", 0, ...
                    "EdgeColor", [0.15 0.15 0.15], "LineWidth", 3, ...
                    "Visible", "off", "Tag", "GT_tetris");
                obj.HoldFace(k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                    "FaceColor", [1 1 1], "FaceAlpha", 0.7, ...
                    "EdgeColor", [1 1 1], "LineWidth", 1, ...
                    "Visible", "off", "Tag", "GT_tetris");
            end

            % --- Next preview (right of playfield) ---
            nextBoxW = obj.CellW * 5;
            nextBoxH = obj.CellH * 13;
            nextX = obj.FieldX + fieldW + obj.CellW * 1.5;
            nextY = obj.FieldY + obj.CellH;
            obj.NextBoxX = nextX;
            obj.NextBoxY = nextY;
            obj.NextBoxW = nextBoxW;
            obj.NextBoxH = nextBoxH;

            obj.NextBorderH = line(ax, ...
                [nextX, nextX + nextBoxW, nextX + nextBoxW, nextX, nextX], ...
                [nextY, nextY, nextY + nextBoxH, nextY + nextBoxH, nextY], ...
                "Color", [0, 0.6, 0.7, 0.4], "LineWidth", 1, "Tag", "GT_tetris");
            obj.NextLabelH = text(ax, nextX + nextBoxW / 2, nextY - obj.CellH * 0.3, ...
                "NEXT", "Color", [0, 0.6, 0.7], ...
                "FontSize", max(8, round(10 * obj.Sc)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", "Tag", "GT_tetris");

            obj.NextGlow = gobjects(3, 4);
            obj.NextFace = gobjects(3, 4);
            for p = 1:3
                for k = 1:4
                    obj.NextGlow(p, k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                        "FaceColor", [1 1 1], "FaceAlpha", 0, ...
                        "EdgeColor", [0.15 0.15 0.15], "LineWidth", 3, ...
                        "Visible", "off", "Tag", "GT_tetris");
                    obj.NextFace(p, k) = patch(ax, "XData", [0 1 1 0], "YData", [0 0 1 1], ...
                        "FaceColor", [1 1 1], "FaceAlpha", 0.7, ...
                        "EdgeColor", [1 1 1], "LineWidth", 1, ...
                        "Visible", "off", "Tag", "GT_tetris");
                end
            end

            % --- In-field HUD text (bottom-left area) ---
            obj.LevelTextH = text(ax, obj.FieldX - obj.CellW * 0.5, ...
                obj.FieldY + fieldH - obj.CellH * 0.5, ...
                "Lv 1", "Color", [0, 0.8, 0.9], ...
                "FontSize", max(8, round(10 * obj.Sc)), ...
                "FontWeight", "bold", "HorizontalAlignment", "right", ...
                "VerticalAlignment", "top", "Tag", "GT_tetris");
            obj.LinesTextH = text(ax, obj.FieldX - obj.CellW * 0.5, ...
                obj.FieldY + fieldH + obj.CellH * 0.1, ...
                "Lines: 0", "Color", [0, 0.6, 0.7], ...
                "FontSize", max(7, round(9 * obj.Sc)), ...
                "FontWeight", "bold", "HorizontalAlignment", "right", ...
                "VerticalAlignment", "top", "Tag", "GT_tetris");

            % --- Reset all game state ---
            obj.Bag = uint8.empty(1, 0);
            obj.BagIdx = 0;
            obj.NextQueue = uint8.empty(1, 0);
            obj.HoldPiece = 0;
            obj.HoldLocked = false;
            obj.Level = 1;
            obj.TotalLines = 0;
            obj.ComboCount = -1;
            obj.IsBackToBack = false;
            obj.ClearRows = [];
            obj.ClearTimer = 0;
            obj.DASDir = 0;
            obj.DASTimer = 0;
            obj.ARRTimer = 0;
            obj.DASAge = 0;
            obj.IsSoftDrop = false;
            obj.SoftDropTimer = 0;
            obj.MouseActive = true;
            obj.GravAccum = 0;
            obj.LockActive = false;
            obj.LockTimer = 0;
            obj.LockMoveCount = 0;

            obj.recalcGravity();

            % Fill next queue (need 3 previews + 1 to spawn now)
            for k = 1:4
                obj.NextQueue(k) = obj.pullFromBag();
            end

            % Spawn first piece
            obj.spawnPiece(obj.NextQueue(1));
            obj.NextQueue = obj.NextQueue(2:end);
            obj.NextQueue(end + 1) = obj.pullFromBag();

            % Initial display
            obj.renderActive();
            obj.computeGhost();
            obj.renderGhost();
            obj.renderHold();
            obj.renderNext();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame game logic: gravity, input, line clears, rendering.
            if obj.GameOver; return; end

            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            ds = obj.DtScale;

            % =============================================================
            % LINE CLEAR ANIMATION (pauses gameplay)
            % =============================================================
            if ~isempty(obj.ClearRows)
                obj.ClearTimer = obj.ClearTimer - ds;
                if obj.ClearTimer <= 0
                    obj.finishClear();
                else
                    % Flash cleared rows white with fading alpha
                    progress = 1 - obj.ClearTimer / obj.ClearDuration;
                    alpha = 0.9 * (1 - progress);
                    for ri = 1:numel(obj.ClearRows)
                        row = obj.ClearRows(ri);
                        if row < 3; continue; end  % skip hidden buffer rows
                        for c = 1:obj.NCols
                            if isvalid(obj.BoardGlow(row, c))
                                obj.BoardGlow(row, c).EdgeColor = [1 1 1] * 0.35;
                                obj.BoardGlow(row, c).Visible = "on";
                            end
                            if isvalid(obj.BoardFace(row, c))
                                obj.BoardFace(row, c).FaceColor = [1 1 1];
                                obj.BoardFace(row, c).FaceAlpha = alpha;
                                obj.BoardFace(row, c).EdgeColor = [1 1 1];
                                obj.BoardFace(row, c).Visible = "on";
                            end
                        end
                    end
                end
                return;
            end

            % =============================================================
            % MOUSE / FINGER INPUT: map X to target column, shift piece
            % =============================================================
            if obj.MouseActive && ~any(isnan(pos)) && obj.CurPiece > 0
                relX = pos(1) - obj.FieldX;
                targetCol = round(relX / obj.CellW) + 1;
                targetCol = max(1, min(obj.NCols, targetCol));
                obj.MouseTargetCol = targetCol;

                % Shift piece toward target column (one step per frame)
                offsets = obj.activeOffsets();
                cols = obj.CurCol + int16(offsets(:, 2));
                pieceCenter = double(min(cols) + max(cols)) / 2;
                if targetCol < pieceCenter - 0.5
                    obj.tryShift(-1, 0);
                elseif targetCol > pieceCenter + 0.5
                    obj.tryShift(1, 0);
                end
            end

            % =============================================================
            % SOFT DROP RELEASE DETECTION
            % =============================================================
            if obj.IsSoftDrop
                obj.SoftDropTimer = obj.SoftDropTimer + ds;
                if obj.SoftDropTimer > 6
                    obj.IsSoftDrop = false;
                    obj.SoftDropTimer = 0;
                end
            end

            % =============================================================
            % DAS AUTO-REPEAT
            % =============================================================
            if obj.DASDir ~= 0
                obj.DASAge = obj.DASAge + ds;
                if obj.DASAge > obj.DASTimeout
                    % Auto-release (no key-up event in hosted mode)
                    obj.DASDir = 0;
                    obj.DASTimer = 0;
                    obj.ARRTimer = 0;
                    obj.DASAge = 0;
                else
                    obj.DASTimer = obj.DASTimer + ds;
                    if obj.DASTimer >= obj.DASDelay
                        obj.ARRTimer = obj.ARRTimer + ds;
                        while obj.ARRTimer >= obj.ARRPeriod
                            obj.ARRTimer = obj.ARRTimer - obj.ARRPeriod;
                            obj.tryShift(int16(obj.DASDir), 0);
                        end
                    end
                end
            end

            % =============================================================
            % GRAVITY
            % =============================================================
            gravMul = 1;
            if obj.IsSoftDrop
                gravMul = 20;
            end
            obj.GravAccum = obj.GravAccum + ds * gravMul;

            while obj.GravAccum >= obj.GravInterval && obj.CurPiece > 0 && ~obj.GameOver
                obj.GravAccum = obj.GravAccum - obj.GravInterval;
                if obj.tryShift(0, 1)
                    % Piece moved down one row
                    if obj.IsSoftDrop
                        obj.addScore(1);
                    end
                    if obj.LockActive
                        % Moving down resets lock (piece lifted off surface)
                        obj.LockActive = false;
                        obj.LockTimer = 0;
                    end
                else
                    % Piece cannot move down: on a surface
                    if ~obj.LockActive
                        obj.LockActive = true;
                        obj.LockTimer = 0;
                        obj.LockMoveCount = 0;
                    end
                    break;
                end
            end

            % =============================================================
            % LOCK DELAY
            % =============================================================
            if obj.LockActive
                obj.LockTimer = obj.LockTimer + ds;
                if obj.LockTimer >= obj.LockDelay
                    obj.lockPiece();
                    return;
                end
            end

            % =============================================================
            % UPDATE VISUALS
            % =============================================================
            obj.renderActive();
            obj.computeGhost();
            obj.renderGhost();
        end

        function onCleanup(obj)
            %onCleanup  Delete all graphics and reset state.

            % Board patches
            if ~isempty(obj.BoardGlow)
                for r = 1:size(obj.BoardGlow, 1)
                    for c = 1:size(obj.BoardGlow, 2)
                        if isvalid(obj.BoardGlow(r, c)); delete(obj.BoardGlow(r, c)); end
                        if isvalid(obj.BoardFace(r, c)); delete(obj.BoardFace(r, c)); end
                    end
                end
            end
            obj.BoardGlow = gobjects(0, 0);
            obj.BoardFace = gobjects(0, 0);

            % Active / ghost / hold patches
            arrays = {obj.ActiveGlow, obj.ActiveFace, obj.GhostPatch, ...
                      obj.HoldGlow, obj.HoldFace};
            for a = 1:numel(arrays)
                arr = arrays{a};
                for k = 1:numel(arr)
                    if isvalid(arr(k)); delete(arr(k)); end
                end
            end

            % Next patches
            for p = 1:size(obj.NextGlow, 1)
                for k = 1:size(obj.NextGlow, 2)
                    if isvalid(obj.NextGlow(p, k)); delete(obj.NextGlow(p, k)); end
                    if isvalid(obj.NextFace(p, k)); delete(obj.NextFace(p, k)); end
                end
            end

            % Line and text handles
            handles = {obj.FieldBorderH, obj.GridLinesH, obj.HoldBorderH, ...
                obj.HoldLabelH, obj.NextBorderH, obj.NextLabelH, ...
                obj.LevelTextH, obj.LinesTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end

            % Reset handle arrays
            obj.ActiveGlow = gobjects(1, 4);
            obj.ActiveFace = gobjects(1, 4);
            obj.GhostPatch = gobjects(1, 4);
            obj.HoldGlow   = gobjects(1, 4);
            obj.HoldFace   = gobjects(1, 4);
            obj.NextGlow   = gobjects(3, 4);
            obj.NextFace   = gobjects(3, 4);
            obj.Board = zeros(0, 0, "uint8");

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_tetris");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle keyboard input.
            if obj.GameOver
                handled = false;
                return;
            end
            if ~isempty(obj.ClearRows)
                handled = false;
                return;
            end

            handled = true;
            switch key
                case "leftarrow"
                    obj.tryShift(-1, 0);
                    obj.DASDir = -1;
                    obj.DASTimer = 0;
                    obj.ARRTimer = 0;
                    obj.DASAge = 0;

                case "rightarrow"
                    obj.tryShift(1, 0);
                    obj.DASDir = 1;
                    obj.DASTimer = 0;
                    obj.ARRTimer = 0;
                    obj.DASAge = 0;

                case {"uparrow", "z"}
                    obj.tryRotate(1);    % clockwise

                case "x"
                    obj.tryRotate(-1);   % counter-clockwise

                case "downarrow"
                    obj.IsSoftDrop = true;
                    obj.SoftDropTimer = 0;

                case "space"
                    obj.hardDrop();

                case "c"
                    obj.doHold();

                otherwise
                    handled = false;
            end

            % Clear DAS on non-arrow key
            if handled && ~ismember(key, ["leftarrow", "rightarrow"])
                obj.DASDir = 0;
                obj.DASTimer = 0;
                obj.ARRTimer = 0;
            end
        end

        function onMouseDown(obj)
            %onMouseDown  Hard drop on click.
            if ~obj.GameOver && isempty(obj.ClearRows)
                obj.hardDrop();
            end
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel rotates piece.
            if obj.GameOver || ~isempty(obj.ClearRows); return; end
            if delta < 0
                obj.tryRotate(1);    % scroll up = clockwise
            else
                obj.tryRotate(-1);   % scroll down = counter-clockwise
            end
        end

        function r = getResults(obj)
            %getResults  Return Tetris results for the results screen.
            r.Title = "TETRIS";
            r.Lines = {
                sprintf("Level: %d", obj.Level)
                sprintf("Lines: %d", obj.TotalLines)
            };
        end

        function s = getHudText(obj)
            %getHudText  Return HUD string.
            s = sprintf("Lv %d | Lines %d", obj.Level, obj.TotalLines);
        end
    end

    % =================================================================
    % PRIVATE: PIECE MOVEMENT & COLLISION
    % =================================================================
    methods (Access = private)

        function ok = tryShift(obj, dc, dr)
            %tryShift  Attempt to shift the active piece by (dc, dr).
            %   dc = column delta (+1=right), dr = row delta (+1=down).
            %   Returns true if the move succeeded.
            if obj.CurPiece == 0; ok = false; return; end

            newCol = obj.CurCol + int16(dc);
            newRow = obj.CurRow + int16(dr);
            offsets = obj.activeOffsets();

            if obj.fits(offsets, newRow, newCol)
                obj.CurCol = newCol;
                obj.CurRow = newRow;
                ok = true;
                % Reset lock delay on successful move (max 15 resets)
                if obj.LockActive && obj.LockMoveCount < 15
                    obj.LockTimer = 0;
                    obj.LockMoveCount = obj.LockMoveCount + 1;
                end
            else
                ok = false;
            end
        end

        function tryRotate(obj, direction)
            %tryRotate  Attempt SRS rotation with wall kicks.
            %   direction: +1 = clockwise, -1 = counter-clockwise.
            if obj.CurPiece == 0; return; end

            % O-piece (ID 2) never rotates
            if obj.CurPiece == 2; return; end

            oldRot = obj.CurRot;
            newRot = uint8(mod(int16(oldRot) + int16(direction), 4));

            newOffsets = obj.PieceCells{obj.CurPiece}(:, :, newRot + 1);

            % Look up wall kick offsets
            kickKey = sprintf("%d>%d", oldRot, newRot);
            if obj.CurPiece == 1   % I-piece
                kickMap = obj.KickTables.I;
            else
                kickMap = obj.KickTables.JLSTZ;
            end

            if kickMap.isKey(kickKey)
                kicks = kickMap(kickKey);   % Nx2 [dcol, drow]
            else
                kicks = int16([0, 0]);
            end

            for k = 1:size(kicks, 1)
                testCol = obj.CurCol + kicks(k, 1);
                testRow = obj.CurRow + kicks(k, 2);
                if obj.fits(newOffsets, testRow, testCol)
                    obj.CurCol = testCol;
                    obj.CurRow = testRow;
                    obj.CurRot = newRot;
                    % Reset lock delay on successful rotation
                    if obj.LockActive && obj.LockMoveCount < 15
                        obj.LockTimer = 0;
                        obj.LockMoveCount = obj.LockMoveCount + 1;
                    end
                    return;
                end
            end
            % All kick tests failed; rotation blocked.
        end

        function ok = fits(obj, offsets, pivotRow, pivotCol)
            %fits  Check if piece offsets fit at (pivotRow, pivotCol).
            ok = true;
            for k = 1:size(offsets, 1)
                r = pivotRow + int16(offsets(k, 1));
                c = pivotCol + int16(offsets(k, 2));
                % Out of bounds?
                if c < 1 || c > obj.NCols || r < 1 || r > obj.NRows
                    ok = false;
                    return;
                end
                % Cell occupied?
                if obj.Board(r, c) ~= 0
                    ok = false;
                    return;
                end
            end
        end

        function offsets = activeOffsets(obj)
            %activeOffsets  Return 4x2 [drow, dcol] offsets for current piece+rotation.
            if obj.CurPiece == 0
                offsets = zeros(4, 2, "int8");
                return;
            end
            offsets = obj.PieceCells{obj.CurPiece}(:, :, obj.CurRot + 1);
        end
    end

    % =================================================================
    % PRIVATE: SPAWNING, LOCKING, LINE CLEARING
    % =================================================================
    methods (Access = private)

        function spawnPiece(obj, pieceId)
            %spawnPiece  Place a new piece at the spawn position.
            %   Spawn at row 2 (near top of board, inside the 2-row hidden buffer).
            %   The piece center sits at row 2 so minos span rows 1-3.
            obj.CurPiece = pieceId;
            obj.CurRot = 0;
            obj.CurRow = int16(2);    % row 2 so minos span rows 1-3
            obj.CurCol = int16(5);    % centered

            offsets = obj.activeOffsets();
            if ~obj.fits(offsets, obj.CurRow, obj.CurCol)
                % Try one row up
                if ~obj.fits(offsets, obj.CurRow - 1, obj.CurCol)
                    obj.GameOver = true;
                    obj.IsRunning = false;
                    return;
                end
                obj.CurRow = obj.CurRow - 1;
            end

            obj.GravAccum = 0;
            obj.LockActive = false;
            obj.LockTimer = 0;
            obj.LockMoveCount = 0;
            obj.HoldLocked = false;
            obj.IsSoftDrop = false;
            obj.SoftDropTimer = 0;
        end

        function lockPiece(obj)
            %lockPiece  Lock the active piece into the board.
            if obj.CurPiece == 0; return; end

            offsets = obj.activeOffsets();
            pid = obj.CurPiece;
            clr = obj.PieceClrs(pid, :);

            % Write cells to board and update board patches
            for k = 1:size(offsets, 1)
                r = obj.CurRow + int16(offsets(k, 1));
                c = obj.CurCol + int16(offsets(k, 2));
                if r >= 1 && r <= obj.NRows && c >= 1 && c <= obj.NCols
                    obj.Board(r, c) = pid;
                    % Update visible board patches
                    if r >= 3 && isvalid(obj.BoardGlow(r, c)) && isvalid(obj.BoardFace(r, c))
                        obj.BoardGlow(r, c).EdgeColor = clr * 0.35;
                        obj.BoardGlow(r, c).Visible = "on";
                        obj.BoardFace(r, c).FaceColor = clr;
                        obj.BoardFace(r, c).FaceAlpha = 0.7;
                        obj.BoardFace(r, c).EdgeColor = clr;
                        obj.BoardFace(r, c).Visible = "on";
                    end
                end
            end

            % Hide active piece patches
            for k = 1:4
                if isvalid(obj.ActiveGlow(k)); obj.ActiveGlow(k).Visible = "off"; end
                if isvalid(obj.ActiveFace(k)); obj.ActiveFace(k).Visible = "off"; end
            end
            % Hide ghost patches
            for k = 1:4
                if isvalid(obj.GhostPatch(k)); obj.GhostPatch(k).Visible = "off"; end
            end

            % Check for full rows
            fullRows = obj.findFullRows();
            if ~isempty(fullRows)
                obj.beginClear(fullRows);
            else
                obj.ComboCount = -1;
                obj.spawnNext();
            end
        end

        function rows = findFullRows(obj)
            %findFullRows  Return row indices of all full rows.
            rows = [];
            for r = 1:obj.NRows
                if all(obj.Board(r, :) ~= 0)
                    rows(end + 1) = r; %#ok<AGROW>
                end
            end
        end

        function beginClear(obj, rows)
            %beginClear  Start the line clear flash animation.
            obj.ClearRows = rows;
            obj.ClearTimer = obj.ClearDuration;
        end

        function finishClear(obj)
            %finishClear  Remove cleared rows, collapse board, award score.
            rows = sort(obj.ClearRows, "ascend");   % top-first removal
            numLines = numel(rows);

            % Remove rows: for each cleared row, shift everything above
            % (smaller row index) down by one, and clear row 1.
            for ri = numel(rows):-1:1
                r = rows(ri);
                if r > 1
                    obj.Board(2:r, :) = obj.Board(1:r-1, :);
                end
                obj.Board(1, :) = 0;

                % Adjust remaining indices (rows above shifted down by 1)
                for rj = 1:(ri - 1)
                    if rows(rj) < r
                        rows(rj) = rows(rj) + 1;
                    end
                end
            end

            % --- Scoring ---
            obj.ComboCount = obj.ComboCount + 1;
            switch numLines
                case 1; baseScore = 100;
                case 2; baseScore = 300;
                case 3; baseScore = 500;
                case 4; baseScore = 800;
                otherwise; baseScore = 100 * numLines;
            end

            % Back-to-back bonus for Tetris (4 lines)
            if numLines == 4
                if obj.IsBackToBack
                    baseScore = round(baseScore * 1.5);
                end
                obj.IsBackToBack = true;
            else
                obj.IsBackToBack = false;
            end

            pts = baseScore * obj.Level;

            % Combo bonus
            if obj.ComboCount > 0
                pts = pts + 50 * obj.ComboCount * obj.Level;
            end

            obj.addScore(pts);
            obj.TotalLines = obj.TotalLines + numLines;

            % Level up every 10 lines
            newLevel = floor(obj.TotalLines / 10) + 1;
            if newLevel > obj.Level
                obj.Level = newLevel;
                obj.recalcGravity();
            end

            % Update in-field HUD
            if ~isempty(obj.LevelTextH) && isvalid(obj.LevelTextH)
                obj.LevelTextH.String = sprintf("Lv %d", obj.Level);
            end
            if ~isempty(obj.LinesTextH) && isvalid(obj.LinesTextH)
                obj.LinesTextH.String = sprintf("Lines: %d", obj.TotalLines);
            end

            obj.ClearRows = [];
            obj.ClearTimer = 0;

            % Refresh entire board display
            obj.syncBoard();

            % Spawn next piece
            obj.spawnNext();
        end

        function spawnNext(obj)
            %spawnNext  Spawn the next piece from the queue and refill.
            nextType = obj.NextQueue(1);
            obj.NextQueue = obj.NextQueue(2:end);
            obj.NextQueue(end + 1) = obj.pullFromBag();
            obj.spawnPiece(nextType);
            obj.renderNext();
            obj.renderActive();
            obj.computeGhost();
            obj.renderGhost();
        end

        function doHold(obj)
            %doHold  Swap current piece with hold, or store if empty.
            if obj.HoldLocked; return; end
            if obj.CurPiece == 0; return; end

            oldPiece = obj.CurPiece;
            if obj.HoldPiece == 0
                obj.HoldPiece = oldPiece;
                obj.spawnNext();
            else
                swapPiece = obj.HoldPiece;
                obj.HoldPiece = oldPiece;
                obj.spawnPiece(swapPiece);
                obj.renderActive();
                obj.computeGhost();
                obj.renderGhost();
            end
            obj.HoldLocked = true;
            obj.renderHold();
        end

        function hardDrop(obj)
            %hardDrop  Instantly drop piece to ghost position and lock.
            if obj.CurPiece == 0; return; end

            obj.computeGhost();
            dropDist = obj.GhostRow - obj.CurRow;   % positive (ghost is below)
            obj.addScore(2 * max(0, double(dropDist)));
            obj.CurRow = obj.GhostRow;
            obj.lockPiece();
        end

        function recalcGravity(obj)
            %recalcGravity  Recalculate gravity interval from current level.
            %   Tetris Guideline: (0.8 - (level-1)*0.007)^(level-1) seconds.
            lvl = obj.Level;
            secs = (0.8 - (lvl - 1) * 0.007) ^ (lvl - 1);
            secs = max(secs, 1 / 60);
            obj.GravInterval = secs * obj.RefFPS;
        end
    end

    % =================================================================
    % PRIVATE: 7-BAG RANDOMIZER
    % =================================================================
    methods (Access = private)

        function pieceId = pullFromBag(obj)
            %pullFromBag  Draw next piece from the 7-bag. Refill when empty.
            if obj.BagIdx == 0 || obj.BagIdx > 7
                obj.Bag = uint8(randperm(7));
                obj.BagIdx = 1;
            end
            pieceId = obj.Bag(obj.BagIdx);
            obj.BagIdx = obj.BagIdx + 1;
        end
    end

    % =================================================================
    % PRIVATE: GHOST PIECE
    % =================================================================
    methods (Access = private)

        function computeGhost(obj)
            %computeGhost  Find the lowest valid row for the ghost (hard drop target).
            if obj.CurPiece == 0; return; end
            offsets = obj.activeOffsets();
            testRow = obj.CurRow;
            % Move downward (increasing row number) until blocked
            while testRow <= obj.NRows
                if obj.fits(offsets, testRow + 1, obj.CurCol)
                    testRow = testRow + 1;
                else
                    break;
                end
            end
            obj.GhostRow = testRow;
        end
    end

    % =================================================================
    % PRIVATE: GRAPHICS RENDERING
    % =================================================================
    methods (Access = private)

        function [xv, yv] = cellVerts(obj, row, col)
            %cellVerts  Return 4-element XData/YData for a cell patch with gap.
            %   Row 1 = top of board. Row increases downward.
            %   Visible rows are 3..22 (rows 1-2 are hidden buffer).
            %   For visible row r, screen Y = FieldY + (r - 3) * CellH.
            %   Rows 1-2 are above the field: Y = FieldY - (3 - r) * CellH.
            g = obj.CellGap;
            x0 = obj.FieldX + (double(col) - 1) * obj.CellW;
            y0 = obj.FieldY + (double(row) - 3) * obj.CellH;
            xv = [x0 + g, x0 + obj.CellW - g, x0 + obj.CellW - g, x0 + g];
            yv = [y0 + g, y0 + g, y0 + obj.CellH - g, y0 + obj.CellH - g];
        end

        function [xv, yv] = miniCellVerts(obj, centerX, centerY, dr, dc)
            %miniCellVerts  Vertices for a cell in a preview/hold box.
            %   (dr, dc) are offsets from piece center. Positive dr = down.
            g = obj.CellGap;
            x0 = centerX + (double(dc) - 0.5) * obj.CellW;
            y0 = centerY + (double(dr) - 0.5) * obj.CellH;
            xv = [x0 + g, x0 + obj.CellW - g, x0 + obj.CellW - g, x0 + g];
            yv = [y0 + g, y0 + g, y0 + obj.CellH - g, y0 + obj.CellH - g];
        end

        function renderActive(obj)
            %renderActive  Position the 4 active piece patches (glow + face).
            if obj.CurPiece == 0
                for k = 1:4
                    if isvalid(obj.ActiveGlow(k)); obj.ActiveGlow(k).Visible = "off"; end
                    if isvalid(obj.ActiveFace(k)); obj.ActiveFace(k).Visible = "off"; end
                end
                return;
            end

            offsets = obj.activeOffsets();
            clr = obj.PieceClrs(obj.CurPiece, :);

            for k = 1:4
                r = obj.CurRow + int16(offsets(k, 1));
                c = obj.CurCol + int16(offsets(k, 2));
                % Only show in visible area (rows 3..22)
                if r >= 3 && r <= obj.NRows && c >= 1 && c <= obj.NCols
                    [xv, yv] = obj.cellVerts(r, c);
                    if isvalid(obj.ActiveGlow(k))
                        obj.ActiveGlow(k).XData = xv;
                        obj.ActiveGlow(k).YData = yv;
                        obj.ActiveGlow(k).EdgeColor = clr * 0.35;
                        obj.ActiveGlow(k).Visible = "on";
                    end
                    if isvalid(obj.ActiveFace(k))
                        obj.ActiveFace(k).XData = xv;
                        obj.ActiveFace(k).YData = yv;
                        obj.ActiveFace(k).FaceColor = clr;
                        obj.ActiveFace(k).FaceAlpha = 0.85;
                        obj.ActiveFace(k).EdgeColor = clr;
                        obj.ActiveFace(k).Visible = "on";
                    end
                else
                    if isvalid(obj.ActiveGlow(k)); obj.ActiveGlow(k).Visible = "off"; end
                    if isvalid(obj.ActiveFace(k)); obj.ActiveFace(k).Visible = "off"; end
                end
            end
        end

        function renderGhost(obj)
            %renderGhost  Position the 4 ghost piece patches.
            if obj.CurPiece == 0 || obj.GhostRow == obj.CurRow
                for k = 1:4
                    if isvalid(obj.GhostPatch(k)); obj.GhostPatch(k).Visible = "off"; end
                end
                return;
            end

            offsets = obj.activeOffsets();
            clr = obj.PieceClrs(obj.CurPiece, :);

            for k = 1:4
                r = obj.GhostRow + int16(offsets(k, 1));
                c = obj.CurCol + int16(offsets(k, 2));
                if r >= 3 && r <= obj.NRows && c >= 1 && c <= obj.NCols
                    [xv, yv] = obj.cellVerts(r, c);
                    if isvalid(obj.GhostPatch(k))
                        obj.GhostPatch(k).XData = xv;
                        obj.GhostPatch(k).YData = yv;
                        obj.GhostPatch(k).FaceColor = clr;
                        obj.GhostPatch(k).FaceAlpha = 0.12;
                        obj.GhostPatch(k).EdgeColor = clr;
                        obj.GhostPatch(k).Visible = "on";
                    end
                else
                    if isvalid(obj.GhostPatch(k)); obj.GhostPatch(k).Visible = "off"; end
                end
            end
        end

        function renderHold(obj)
            %renderHold  Show the held piece in the hold box.
            if obj.HoldPiece == 0
                for k = 1:4
                    if isvalid(obj.HoldGlow(k)); obj.HoldGlow(k).Visible = "off"; end
                    if isvalid(obj.HoldFace(k)); obj.HoldFace(k).Visible = "off"; end
                end
                return;
            end

            offsets = obj.PieceCells{obj.HoldPiece}(:, :, 1);   % rotation 0
            clr = obj.PieceClrs(obj.HoldPiece, :);
            if obj.HoldLocked
                clr = clr * 0.4;   % dimmed when hold already used
            end

            for k = 1:4
                dr = double(offsets(k, 1));
                dc = double(offsets(k, 2));
                [xv, yv] = obj.miniCellVerts(obj.HoldCenterX, obj.HoldCenterY, dr, dc);
                if isvalid(obj.HoldGlow(k))
                    obj.HoldGlow(k).XData = xv;
                    obj.HoldGlow(k).YData = yv;
                    obj.HoldGlow(k).EdgeColor = clr * 0.35;
                    obj.HoldGlow(k).Visible = "on";
                end
                if isvalid(obj.HoldFace(k))
                    obj.HoldFace(k).XData = xv;
                    obj.HoldFace(k).YData = yv;
                    obj.HoldFace(k).FaceColor = clr;
                    obj.HoldFace(k).FaceAlpha = 0.7;
                    obj.HoldFace(k).EdgeColor = clr;
                    obj.HoldFace(k).Visible = "on";
                end
            end
        end

        function renderNext(obj)
            %renderNext  Show the next 3 pieces in the preview box.
            centerX = obj.NextBoxX + obj.NextBoxW / 2;

            for p = 1:min(3, numel(obj.NextQueue))
                offsets = obj.PieceCells{obj.NextQueue(p)}(:, :, 1);
                clr = obj.PieceClrs(obj.NextQueue(p), :);

                % Vertical slot: evenly spaced within the next box
                slotCenterY = obj.NextBoxY + (p - 0.5) * (obj.NextBoxH / 3);

                for k = 1:4
                    dr = double(offsets(k, 1));
                    dc = double(offsets(k, 2));
                    [xv, yv] = obj.miniCellVerts(centerX, slotCenterY, dr, dc);
                    if isvalid(obj.NextGlow(p, k))
                        obj.NextGlow(p, k).XData = xv;
                        obj.NextGlow(p, k).YData = yv;
                        obj.NextGlow(p, k).EdgeColor = clr * 0.35;
                        obj.NextGlow(p, k).Visible = "on";
                    end
                    if isvalid(obj.NextFace(p, k))
                        obj.NextFace(p, k).XData = xv;
                        obj.NextFace(p, k).YData = yv;
                        obj.NextFace(p, k).FaceColor = clr;
                        obj.NextFace(p, k).FaceAlpha = 0.7;
                        obj.NextFace(p, k).EdgeColor = clr;
                        obj.NextFace(p, k).Visible = "on";
                    end
                end
            end

            % Hide unused slots
            for p = (numel(obj.NextQueue) + 1):3
                for k = 1:4
                    if isvalid(obj.NextGlow(p, k)); obj.NextGlow(p, k).Visible = "off"; end
                    if isvalid(obj.NextFace(p, k)); obj.NextFace(p, k).Visible = "off"; end
                end
            end
        end

        function syncBoard(obj)
            %syncBoard  Refresh all board patches to match the Board array.
            for r = 3:obj.NRows   % only visible rows
                for c = 1:obj.NCols
                    pid = obj.Board(r, c);
                    if pid > 0 && pid <= 7
                        clr = obj.PieceClrs(pid, :);
                        if isvalid(obj.BoardGlow(r, c))
                            obj.BoardGlow(r, c).EdgeColor = clr * 0.35;
                            obj.BoardGlow(r, c).Visible = "on";
                        end
                        if isvalid(obj.BoardFace(r, c))
                            obj.BoardFace(r, c).FaceColor = clr;
                            obj.BoardFace(r, c).FaceAlpha = 0.7;
                            obj.BoardFace(r, c).EdgeColor = clr;
                            obj.BoardFace(r, c).Visible = "on";
                        end
                    else
                        if isvalid(obj.BoardGlow(r, c))
                            obj.BoardGlow(r, c).Visible = "off";
                        end
                        if isvalid(obj.BoardFace(r, c))
                            obj.BoardFace(r, c).Visible = "off";
                        end
                    end
                end
            end
        end

        function drawGrid(obj, ax)
            %drawGrid  Draw subtle grid overlay for the visible playfield.
            nC = obj.NCols;
            nR = obj.NVisible;
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
                idx = idx + 3;
            end

            % Horizontal lines
            for r = 0:nR
                yVal = fy + r * ch;
                xAll(idx)   = fx;       yAll(idx)   = yVal;
                xAll(idx+1) = fx + nC * cw; yAll(idx+1) = yVal;
                idx = idx + 3;
            end

            obj.GridLinesH = line(ax, xAll, yAll, ...
                "Color", [0.12, 0.12, 0.12], "LineWidth", 0.5, ...
                "Tag", "GT_tetris");
            uistack(obj.GridLinesH, "bottom");
        end
    end

    % =================================================================
    % STATIC: PIECE DEFINITIONS (SRS)
    % =================================================================
    methods (Static, Access = private)

        function cells = buildPieceCells()
            %buildPieceCells  Build 7 tetromino definitions with SRS rotations.
            %
            %   Each piece is a 4x2x4 int8 array.
            %     Dim 1: 4 minos
            %     Dim 2: [drow, dcol] offset from pivot
            %     Dim 3: rotation states 0, 1, 2, 3
            %
            %   Convention: drow positive = down, dcol positive = right.
            %   Row 1 = top of board, row increases downward.
            %
            %   Piece IDs: 1=I, 2=O, 3=T, 4=S, 5=Z, 6=J, 7=L
            %
            %   SRS cell positions are taken from the Tetris Guideline.
            %   I/O use a 4x4 bounding box; T/S/Z/J/L use a 3x3 bounding box.
            %   Offsets are relative to a pivot within the bounding box.

            cells = cell(7, 1);

            % ----- 1: I-piece (cyan) -----
            % 4x4 bounding box. Pivot between cells (row 1.5, col 1.5 of box).
            % State 0:  . . . .     State 1:  . . X .
            %           X X X X               . . X .
            %           . . . .               . . X .
            %           . . . .               . . X .
            %
            % State 2:  . . . .     State 3:  . X . .
            %           . . . .               . X . .
            %           X X X X               . X . .
            %           . . . .               . X . .
            I = zeros(4, 2, 4, "int8");
            % State 0: row offset 0, cols -1,0,1,2
            I(:,:,1) = [ 0, -1;  0,  0;  0,  1;  0,  2];
            % State 1: col offset 1, rows -1,0,1,2
            I(:,:,2) = [-1,  1;  0,  1;  1,  1;  2,  1];
            % State 2: row offset 1, cols -1,0,1,2
            I(:,:,3) = [ 1, -1;  1,  0;  1,  1;  1,  2];
            % State 3: col offset 0, rows -1,0,1,2
            I(:,:,4) = [-1,  0;  0,  0;  1,  0;  2,  0];
            cells{1} = I;

            % ----- 2: O-piece (gold) -----
            % 2x2 block, all rotations identical.
            % State 0:  X X
            %           X X
            O = zeros(4, 2, 4, "int8");
            oBase = int8([0, 0; 0, 1; 1, 0; 1, 1]);
            O(:,:,1) = oBase;
            O(:,:,2) = oBase;
            O(:,:,3) = oBase;
            O(:,:,4) = oBase;
            cells{2} = O;

            % ----- 3: T-piece (purple) -----
            % 3x3 bounding box. Pivot at center (row 1, col 1 of box, 0-indexed).
            % State 0:  . X .     State 1:  . X .
            %           X X X               . X X
            %           . . .               . X .
            %
            % State 2:  . . .     State 3:  . X .
            %           X X X               X X .
            %           . X .               . X .
            T = zeros(4, 2, 4, "int8");
            T(:,:,1) = [-1,  0;  0, -1;  0,  0;  0,  1];   % T-up
            T(:,:,2) = [-1,  0;  0,  0;  0,  1;  1,  0];   % T-right
            T(:,:,3) = [ 0, -1;  0,  0;  0,  1;  1,  0];   % T-down
            T(:,:,4) = [-1,  0;  0, -1;  0,  0;  1,  0];   % T-left
            cells{3} = T;

            % ----- 4: S-piece (green) -----
            % State 0:  . X X     State 1:  . X .
            %           X X .               . X X
            %           . . .               . . X
            %
            % State 2:  . . .     State 3:  X . .
            %           . X X               X X .
            %           X X .               . X .
            S = zeros(4, 2, 4, "int8");
            S(:,:,1) = [-1,  0; -1,  1;  0, -1;  0,  0];
            S(:,:,2) = [-1,  0;  0,  0;  0,  1;  1,  1];
            S(:,:,3) = [ 0,  0;  0,  1;  1, -1;  1,  0];
            S(:,:,4) = [-1, -1;  0, -1;  0,  0;  1,  0];
            cells{4} = S;

            % ----- 5: Z-piece (red) -----
            % State 0:  X X .     State 1:  . . X
            %           . X X               . X X
            %           . . .               . X .
            %
            % State 2:  . . .     State 3:  . X .
            %           X X .               X X .
            %           . X X               X . .
            Z = zeros(4, 2, 4, "int8");
            Z(:,:,1) = [-1, -1; -1,  0;  0,  0;  0,  1];
            Z(:,:,2) = [-1,  1;  0,  0;  0,  1;  1,  0];
            Z(:,:,3) = [ 0, -1;  0,  0;  1,  0;  1,  1];
            Z(:,:,4) = [-1,  0;  0, -1;  0,  0;  1, -1];
            cells{5} = Z;

            % ----- 6: J-piece (blue) -----
            % State 0:  X . .     State 1:  . X X
            %           X X X               . X .
            %           . . .               . X .
            %
            % State 2:  . . .     State 3:  . X .
            %           X X X               . X .
            %           . . X               X X .
            J = zeros(4, 2, 4, "int8");
            J(:,:,1) = [-1, -1;  0, -1;  0,  0;  0,  1];
            J(:,:,2) = [-1,  0; -1,  1;  0,  0;  1,  0];
            J(:,:,3) = [ 0, -1;  0,  0;  0,  1;  1,  1];
            J(:,:,4) = [-1,  0;  0,  0;  1, -1;  1,  0];
            cells{6} = J;

            % ----- 7: L-piece (orange) -----
            % State 0:  . . X     State 1:  . X .
            %           X X X               . X .
            %           . . .               . X X
            %
            % State 2:  . . .     State 3:  X X .
            %           X X X               . X .
            %           X . .               . X .
            L = zeros(4, 2, 4, "int8");
            L(:,:,1) = [-1,  1;  0, -1;  0,  0;  0,  1];
            L(:,:,2) = [-1,  0;  0,  0;  1,  0;  1,  1];
            L(:,:,3) = [ 0, -1;  0,  0;  0,  1;  1, -1];
            L(:,:,4) = [-1, -1; -1,  0;  0,  0;  1,  0];
            cells{7} = L;
        end

        function tables = buildKickTables()
            %buildKickTables  Build SRS wall kick offset tables.
            %   Returns struct with .JLSTZ and .I fields, each a
            %   containers.Map from "R0>R1" to Nx2 int16 [dcol, drow].
            %   drow positive = downward (increasing row index).
            %
            %   The first test is always (0, 0). Kick offsets are applied
            %   to the piece pivot position: newCol += dcol, newRow += drow.
            %
            %   Source: Tetris Guideline SRS wall kick data, adapted for
            %   row-increases-downward convention (drow signs flipped from
            %   the standard row-up formulation).

            % --- JLSTZ wall kicks ---
            jlstz = containers.Map("KeyType", "char", "ValueType", "any");

            %                        dcol  drow
            % 0 -> 1 (CW from spawn)
            jlstz("0>1") = int16([ 0,  0; -1,  0; -1, -1;  0,  2; -1,  2]);
            % 1 -> 0
            jlstz("1>0") = int16([ 0,  0;  1,  0;  1,  1;  0, -2;  1, -2]);
            % 1 -> 2
            jlstz("1>2") = int16([ 0,  0;  1,  0;  1,  1;  0, -2;  1, -2]);
            % 2 -> 1
            jlstz("2>1") = int16([ 0,  0; -1,  0; -1, -1;  0,  2; -1,  2]);
            % 2 -> 3
            jlstz("2>3") = int16([ 0,  0;  1,  0;  1, -1;  0,  2;  1,  2]);
            % 3 -> 2
            jlstz("3>2") = int16([ 0,  0; -1,  0; -1,  1;  0, -2; -1, -2]);
            % 3 -> 0
            jlstz("3>0") = int16([ 0,  0; -1,  0; -1,  1;  0, -2; -1, -2]);
            % 0 -> 3 (CCW from spawn)
            jlstz("0>3") = int16([ 0,  0;  1,  0;  1, -1;  0,  2;  1,  2]);

            % --- I-piece wall kicks ---
            iKick = containers.Map("KeyType", "char", "ValueType", "any");

            iKick("0>1") = int16([ 0,  0; -2,  0;  1,  0; -2,  1;  1, -2]);
            iKick("1>0") = int16([ 0,  0;  2,  0; -1,  0;  2, -1; -1,  2]);
            iKick("1>2") = int16([ 0,  0; -1,  0;  2,  0; -1, -2;  2,  1]);
            iKick("2>1") = int16([ 0,  0;  1,  0; -2,  0;  1,  2; -2, -1]);
            iKick("2>3") = int16([ 0,  0;  2,  0; -1,  0;  2, -1; -1,  2]);
            iKick("3>2") = int16([ 0,  0; -2,  0;  1,  0; -2,  1;  1, -2]);
            iKick("3>0") = int16([ 0,  0;  1,  0; -2,  0;  1,  2; -2, -1]);
            iKick("0>3") = int16([ 0,  0; -1,  0;  2,  0; -1, -2;  2,  1]);

            tables.JLSTZ = jlstz;
            tables.I = iKick;
        end
    end
end
