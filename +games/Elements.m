classdef Elements < GameBase
    %Elements  Cellular automaton with 15 materials and complex interactions.
    %   Falling sand simulation with sand, water, oil, fire, lava, acid,
    %   stone, wood, metal, glass, ice, concrete, snow, steam, and smoke.
    %   Dual flow modes (laminar/turbulent), density hierarchy with swaps,
    %   concrete curing, snow compaction, 10 spawn patterns in 5 pairs.
    %
    %   Standalone: games.Elements().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, games.FallingSandUtils

    properties (Constant)
        Name = "Elements"
    end

    % =================================================================
    % PUBLIC CONFIGURATION
    % =================================================================
    properties
        FallingGapTol   (1,1) double = 0    % max empty cells below liquid before falling (0=strict)
        DebugFalling    (1,1) logical = false  % color falling cells red in render
        WaterFlowMode   (1,1) string = "laminar"  % "laminar" or "turbulent"
    end

    % =================================================================
    % GRID STATE
    % =================================================================
    properties (Access = private)
        CellGrid        (:,:) uint8         % material grid (Ny x Nx)
        CellLife        (:,:) uint8         % lifetime for fire/steam/smoke/concrete/snow
        ColorNoise      (:,:,:) uint8       % per-cell noise (Ny x Nx x 3)
        GridW           (1,1) double = 120  % grid width (columns)
        GridH           (1,1) double = 90   % grid height (rows)
        BrushSize       (1,1) double = 3    % brush radius (1-8)
        SnowCompactRatio (1,1) double = 3   % snow cells consumed per 1 ice cell
        CurrentMaterial (1,1) uint8 = 1     % current draw material (1=sand)
        SubMode         (1,1) string = "sand"
        SpawnPattern    (1,1) string = "flow"
        FrameCount      (1,1) double = 0
        SimAccum        (1,1) double = 0   % FPS accumulator for fixed-rate physics
    end

    % =================================================================
    % MATERIAL CYCLE
    % =================================================================
    properties (Constant, Access = private)
        MaterialNames = ["sand", "water", "oil", "fire", "lava", "acid", ...
            "stone", "wood", "metal", "glass", "ice", "concrete", "snow", "eraser"]
        MaterialIDs   = uint8([1, 2, 5, 4, 9, 7, 3, 6, 11, 12, 13, 14, 15, 0])
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ImageH                              % image object handle
        ModeTextH                           % text — HUD label
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods

        function onInit(obj, ax, displayRange, ~)
            %onInit  Create Elements grid, image overlay, and HUD.
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

            dx = displayRange.X;
            dy = displayRange.Y;
            Ny = obj.GridH;
            Nx = obj.GridW;

            obj.CellGrid = zeros(Ny, Nx, "uint8");
            obj.CellLife = zeros(Ny, Nx, "uint8");
            obj.ColorNoise = uint8(randi([0, 35], Ny, Nx, 3));
            obj.CurrentMaterial = 1;
            obj.SubMode = "sand";
            obj.BrushSize = 3;
            obj.FrameCount = 0;
            obj.SpawnPattern = "flow";

            blackFrame = zeros(Ny, Nx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", blackFrame, "Interpolation", "bilinear", ...
                "Tag", "GT_elements");
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");

            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, "", ...
                "Color", [1, 0.85, 0.2, 0.8], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_elements");
            obj.refreshHud();
        end

        function onUpdate(obj, fingerPos)
            %onUpdate  Per-frame cellular automaton update + render.
            cellGrid = obj.CellGrid;
            if isempty(cellGrid); return; end
            Ny = obj.GridH;  Nx = obj.GridW;
            obj.FrameCount = obj.FrameCount + 1;
            cellLife = obj.CellLife;
            showDebug = obj.DebugFalling;

            % === FINGER INPUT ===
            hasFinger = ~isempty(fingerPos) && all(~isnan(fingerPos));
            gx = 0; gy = 0; mtrl = obj.CurrentMaterial; bRad = obj.BrushSize;
            bx = 0; by = 0;
            if hasFinger
                dxR = obj.DisplayRange.X;  dyR = obj.DisplayRange.Y;
                gx = round(1 + (fingerPos(1) - dxR(1)) / (dxR(2) - dxR(1)) * (Nx - 1));
                gy = round(1 + (fingerPos(2) - dyR(1)) / (dyR(2) - dyR(1)) * (Ny - 1));
                gx = max(1, min(Nx, gx));  gy = max(1, min(Ny, gy));
                bx = gx;  by = gy;
                if mtrl ~= 255  % 255 = none (no-op brush)
                    r1 = max(1, gy - bRad); r2 = min(Ny, gy + bRad);
                    c1 = max(1, gx - bRad); c2 = min(Nx, gx + bRad);
                    if mtrl == 0
                        cellGrid(r1:r2, c1:c2) = 0;
                        cellLife(r1:r2, c1:c2) = 0;
                    else
                        % Always replace entire brush zone
                        cellGrid(r1:r2, c1:c2) = mtrl;
                        if mtrl == 4  % fire
                            cellLife(r1:r2, c1:c2) = uint8(randi([20, 40], r2-r1+1, c2-c1+1));
                        elseif mtrl == 8  % steam
                            cellLife(r1:r2, c1:c2) = uint8(randi([15, 30], r2-r1+1, c2-c1+1));
                        elseif mtrl == 14  % concrete
                            cellLife(r1:r2, c1:c2) = uint8(randi([80, 120], r2-r1+1, c2-c1+1));
                        else
                            cellLife(r1:r2, c1:c2) = 0;
                        end
                    end
                end
            end

            % Brush exclusion mask
            brushMask = false(Ny, Nx);
            if hasFinger && mtrl ~= 255
                brushMask(max(1, by-bRad):min(Ny, by+bRad), max(1, bx-bRad):min(Nx, bx+bRad)) = true;
            end

            % Emit material from below brush based on spawn pattern
            if hasFinger && mtrl ~= 0 && mtrl ~= 255 && ...
                    ~(mtrl == 3 || mtrl == 6 || mtrl == 11 || mtrl == 12 || mtrl == 13)
                emitRow = min(Ny, by + bRad) + 1;
                if emitRow <= Ny
                    ec1 = max(1, bx - bRad);  ec2 = min(Nx, bx + bRad);
                    emitCols = ec1:ec2;
                    nCols = numel(emitCols);
                    emitMask = obj.buildEmitMask(emitCols, nCols, true);
                    emptyBelow = cellGrid(emitRow, emitCols) == 0;
                    % Snow emits sparsely
                    if mtrl == 15
                        emitMask = emitMask & (rand(1, nCols) < 0.30);
                    end
                    fillMask = emitMask & emptyBelow;
                    if any(fillMask)
                        cellGrid(emitRow, emitCols(fillMask)) = mtrl;
                        if mtrl == 4
                            nN = nnz(fillMask);
                            cellLife(emitRow, emitCols(fillMask)) = uint8(randi([20, 40], 1, nN));
                        elseif mtrl == 8
                            nN = nnz(fillMask);
                            cellLife(emitRow, emitCols(fillMask)) = uint8(randi([15, 30], 1, nN));
                        elseif mtrl == 14
                            nN = nnz(fillMask);
                            cellLife(emitRow, emitCols(fillMask)) = uint8(randi([80, 120], 1, nN));
                        end
                    end
                end
            end

            % === CELLULAR AUTOMATON UPDATE ===
            % FPS normalization: run physics at design rate (~25 Hz)
            obj.SimAccum = obj.SimAccum + obj.DtScale;
            if obj.SimAccum < 1.0
                % Skip physics this frame, still render below
                obj.CellGrid = cellGrid;  obj.CellLife = cellLife;
            else
            obj.SimAccum = obj.SimAccum - 1.0;
            randMat = rand(Ny, Nx);
            gapTol = obj.FallingGapTol;
            flowMode = obj.WaterFlowMode;

            % --- FIRE ---
            isFire = (cellGrid == 4);
            if any(isFire, "all")
                cellLife(isFire) = cellLife(isFire) - 1;
                expired = isFire & (cellLife == 0);
                cellGrid(expired) = 0;  isFire(expired) = false;
                if any(isFire, "all")
                    % Ignite adjacent oil and wood
                    adjF = [false(1, Nx); isFire(1:end-1, :)] | [isFire(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isFire(:, 1:end-1)] | [isFire(:, 2:end), false(Ny, 1)];
                    isOilNow = (cellGrid == 5);
                    ignOil = isOilNow & adjF;  nI = nnz(ignOil);
                    if nI > 0
                        cellGrid(ignOil) = 4;  cellLife(ignOil) = uint8(randi([20, 40], nI, 1));
                    end
                    isWoodNow = (cellGrid == 6);
                    ignWood = isWoodNow & adjF & (randMat < 0.15);
                    nW = nnz(ignWood);
                    if nW > 0
                        wIdx = find(ignWood);
                        abE = (wIdx > 1) & (cellGrid(max(wIdx - 1, 1)) == 0);
                        sIdx = wIdx(abE) - 1;
                        nSm = numel(sIdx);
                        if nSm > 0
                            cellGrid(sIdx) = 10;
                            cellLife(sIdx) = uint8(randi([10, 20], nSm, 1));
                        end
                        cellGrid(ignWood) = 4;
                        cellLife(ignWood) = uint8(randi([30, 60], nW, 1));
                    end
                    % Fire shatters glass -> sand
                    isGlassNow = (cellGrid == 12);
                    shatter = isGlassNow & adjF;
                    cellGrid(shatter) = 1;
                    isFire = (cellGrid == 4);
                end
                if any(isFire, "all")
                    abE = [false(1, Nx); cellGrid(1:end-1, :) == 0];
                    canR = isFire & abE;  canR(1, :) = false;
                    dL = [false(Ny, 1), cellGrid(:, 1:end-1) == 0] & (randMat < 0.15);
                    dR = [cellGrid(:, 2:end) == 0, false(Ny, 1)] & (randMat > 0.85);
                    cDL = isFire & ~canR & dL;  cDL(:, 1) = false;
                    cDR = isFire & ~canR & ~cDL & dR;  cDR(:, end) = false;
                    idx = find(canR);
                    if ~isempty(idx)
                        cellGrid(idx - 1) = 4;  cellLife(idx - 1) = cellLife(idx);
                        cellGrid(idx) = 0;  cellLife(idx) = 0;
                    end
                    idx = find(cDL);
                    if ~isempty(idx)
                        cellGrid(idx - Ny) = 4;  cellLife(idx - Ny) = cellLife(idx);
                        cellGrid(idx) = 0;  cellLife(idx) = 0;
                    end
                    idx = find(cDR);
                    if ~isempty(idx)
                        cellGrid(idx + Ny) = 4;  cellLife(idx + Ny) = cellLife(idx);
                        cellGrid(idx) = 0;  cellLife(idx) = 0;
                    end
                end
                % Sand smothers fire
                isFire = (cellGrid == 4);
                if any(isFire, "all")
                    isSandNow = (cellGrid == 1);
                    adjSand = [false(1, Nx); isSandNow(1:end-1, :)] | ...
                        [isSandNow(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isSandNow(:, 1:end-1)] | ...
                        [isSandNow(:, 2:end), false(Ny, 1)];
                    killF = isFire & adjSand;
                    cellGrid(killF) = 0;  cellLife(killF) = 0;
                end
            end

            % --- SAND ---
            isSand = (cellGrid == 1);
            if any(isSand, "all")
                % Bottom-to-top gravity: connected patches fall as one unit
                willFall = false(Ny, Nx);
                for r = Ny-1:-1:1
                    willFall(r, :) = isSand(r, :) & ~brushMask(r, :) & ...
                        (cellGrid(r+1, :) == 0 | willFall(r+1, :));
                end
                idx = find(willFall);
                if ~isempty(idx); cellGrid(idx + 1) = 1; cellGrid(idx) = 0; end
                % Density swaps: sand sinks through lighter materials
                isSand = (cellGrid == 1);
                sandFalling = games.FallingSandUtils.fsdFallingMask(cellGrid, isSand, 1, brushMask, gapTol);
                bv = [cellGrid(2:end, :); zeros(1, Nx, "uint8")];
                isLighter = (bv == 2 | bv == 5 | bv == 7 | bv == 8 | bv == 10);
                belowFalling = false(Ny, Nx);
                for lm = uint8([2, 5, 7, 8, 10])
                    lmMask = (cellGrid == lm);
                    if ~any(lmMask, "all"); continue; end
                    if ismember(lm, [2, 5, 7]) && flowMode == "turbulent"
                        lf = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, lmMask, lm, brushMask, gapTol);
                    else
                        lf = games.FallingSandUtils.fsdFallingMask(cellGrid, lmMask, lm, brushMask, gapTol);
                    end
                    belowFalling = belowFalling | lf;
                end
                belowFallingShifted = [belowFalling(2:end, :); false(1, Nx)];
                cs = isSand & ~sandFalling & isLighter & ~belowFallingShifted;
                cs(end, :) = false;
                idx = find(cs);
                if ~isempty(idx)
                    displaced = cellGrid(idx + 1);
                    cellGrid(idx + 1) = 1;  cellGrid(idx) = displaced;
                end
                isSand = (cellGrid == 1);
                supported = false(Ny, Nx);
                supported(Ny, :) = (cellGrid(Ny, :) ~= 0);
                isStaticG = (cellGrid == 3) | (cellGrid == 6) | (cellGrid == 11) | ...
                    (cellGrid == 12) | (cellGrid == 13);
                for r = Ny-1:-1:1
                    supported(r, :) = (cellGrid(r, :) ~= 0) & ...
                        (supported(r+1, :) | isStaticG(r, :) | brushMask(r+1, :));
                end
                bb = isSand & supported & ~brushMask;
                bb(end, :) = false;
                if any(bb, "all")
                    % Diagonal fall into empty
                    blE = false(Ny, Nx);
                    blE(1:end-1, 2:end) = (cellGrid(2:end, 1:end-1) == 0);
                    brE = false(Ny, Nx);
                    brE(1:end-1, 1:end-1) = (cellGrid(2:end, 2:end) == 0);
                    cBL = bb & blE;  cBR = bb & brE;
                    bo = cBL & cBR;  pR = bo & (randMat > 0.5);
                    cBL(pR) = false;  cBR(bo & ~pR) = false;  cBR(cBL) = false;
                    idx = find(cBL);
                    if ~isempty(idx); cellGrid(idx + 1 - Ny) = 1; cellGrid(idx) = 0; end
                    idx = find(cBR);
                    if ~isempty(idx); cellGrid(idx + 1 + Ny) = 1; cellGrid(idx) = 0; end

                    % Diagonal fall into liquid (swap)
                    isSand = (cellGrid == 1);
                    belowG = [cellGrid(2:end, :); zeros(1, Nx, "uint8")];
                    onSolid = (belowG == 1) | (belowG == 3) | (belowG == 6) | ...
                        (belowG == 9) | (belowG == 11) | (belowG == 12) | ...
                        (belowG == 13) | (belowG == 14) | (belowG == 15);
                    bbLiq = isSand & onSolid;
                    bbLiq(end, :) = false;
                    if any(bbLiq, "all")
                        gBL = cellGrid(2:end, 1:end-1);
                        blLiq = false(Ny, Nx);
                        blLiq(1:end-1, 2:end) = (gBL == 2) | (gBL == 5) | (gBL == 7);
                        gBR = cellGrid(2:end, 2:end);
                        brLiq = false(Ny, Nx);
                        brLiq(1:end-1, 1:end-1) = (gBR == 2) | (gBR == 5) | (gBR == 7);
                        cBL = bbLiq & blLiq;  cBR = bbLiq & brLiq;
                        bo = cBL & cBR;  pR = bo & (randMat > 0.5);
                        cBL(pR) = false;  cBR(bo & ~pR) = false;  cBR(cBL) = false;
                        idx = find(cBL);
                        if ~isempty(idx)
                            dst = idx + 1 - Ny;
                            displaced = cellGrid(dst);
                            cellGrid(dst) = 1;  cellGrid(idx) = displaced;
                        end
                        idx = find(cBR);
                        if ~isempty(idx)
                            dst = idx + 1 + Ny;
                            displaced = cellGrid(dst);
                            cellGrid(dst) = 1;  cellGrid(idx) = displaced;
                        end
                    end
                end
            end

            % --- OIL (5) ---
            isOil = (cellGrid == 5);
            if any(isOil, "all")
                [cellGrid, cellLife] = obj.updateLiquid(cellGrid, cellLife, isOil, ...
                    uint8(5), uint8([8, 10]), uint8([8, 10]), ...
                    brushMask, randMat, gapTol, flowMode, ...
                    hasFinger, mtrl, bx, by, bRad, Ny, Nx);
            end

            % --- WATER (2) ---
            isWater = (cellGrid == 2);
            if any(isWater, "all")
                % Density swap: water sinks through oil and gases
                if flowMode == "turbulent"
                    waterFalling = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, isWater, 2, brushMask, gapTol);
                else
                    waterFalling = games.FallingSandUtils.fsdFallingMask(cellGrid, isWater, 2, brushMask, gapTol);
                end
                bv = [cellGrid(2:end, :); zeros(1, Nx, "uint8")];
                isLighter = (bv == 5 | bv == 8 | bv == 10);
                belowFalling = false(Ny, Nx);
                for lm = uint8([5, 8, 10])
                    lmMask = (cellGrid == lm);
                    if ~any(lmMask, "all"); continue; end
                    if lm == 5 && flowMode == "turbulent"
                        lf = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, lmMask, lm, brushMask, gapTol);
                    else
                        lf = games.FallingSandUtils.fsdFallingMask(cellGrid, lmMask, lm, brushMask, gapTol);
                    end
                    belowFalling = belowFalling | lf;
                end
                belowFallingShifted = [belowFalling(2:end, :); false(1, Nx)];
                cs = isWater & ~waterFalling & isLighter & ~belowFallingShifted;
                cs(end, :) = false;
                idx = find(cs);
                if ~isempty(idx)
                    displaced = cellGrid(idx + 1);
                    cellGrid(idx + 1) = 2;  cellGrid(idx) = displaced;
                end
                isWater = (cellGrid == 2);

                % Water extinguishes adjacent fire -> steam
                isFire = (cellGrid == 4);
                if any(isFire, "all")
                    realWater = isWater & (cellLife == 0);
                    adjW = [false(1, Nx); realWater(1:end-1, :)] | ...
                        [realWater(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), realWater(:, 1:end-1)] | ...
                        [realWater(:, 2:end), false(Ny, 1)];
                    isIceNow = (cellGrid == 13);
                    adjIceNow = [false(1, Nx); isIceNow(1:end-1, :)] | ...
                        [isIceNow(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isIceNow(:, 1:end-1)] | ...
                        [isIceNow(:, 2:end), false(Ny, 1)];
                    ext = isFire & adjW & ~adjIceNow;
                    if any(ext, "all")
                        nS = nnz(ext);
                        cellGrid(ext) = 8;  cellLife(ext) = uint8(randi([15, 30], nS, 1));
                    end
                    % Ice-melt water kills fire silently
                    isFire = (cellGrid == 4);
                    if any(isFire, "all")
                        meltW = isWater & (cellLife > 0);
                        adjMW = [false(1, Nx); meltW(1:end-1, :)] | ...
                            [meltW(2:end, :); false(1, Nx)] | ...
                            [false(Ny, 1), meltW(:, 1:end-1)] | ...
                            [meltW(:, 2:end), false(Ny, 1)];
                        killFire = isFire & adjMW;
                        if any(killFire, "all")
                            cellGrid(killFire) = 0;  cellLife(killFire) = 0;
                        end
                    end
                end

                % Water flow (laminar or turbulent)
                [cellGrid, cellLife] = obj.flowLiquid(cellGrid, cellLife, uint8(2), ...
                    uint8([5, 8, 10]), brushMask, randMat, gapTol, flowMode, ...
                    hasFinger, mtrl, bx, by, bRad, Ny, Nx);
            end

            % --- ACID (7) ---
            isAcid = (cellGrid == 7);
            if any(isAcid, "all")
                % Density swap: acid sinks through lighter liquids and gases
                if flowMode == "turbulent"
                    acidFalling = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, isAcid, 7, brushMask, gapTol);
                else
                    acidFalling = games.FallingSandUtils.fsdFallingMask(cellGrid, isAcid, 7, brushMask, gapTol);
                end
                bv = [cellGrid(2:end, :); zeros(1, Nx, "uint8")];
                isLighter = (bv == 2 | bv == 5 | bv == 8 | bv == 10);
                belowFalling = false(Ny, Nx);
                for lm = uint8([2, 5, 8, 10])
                    lmMask = (cellGrid == lm);
                    if ~any(lmMask, "all"); continue; end
                    if ismember(lm, [2, 5]) && flowMode == "turbulent"
                        lf = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, lmMask, lm, brushMask, gapTol);
                    else
                        lf = games.FallingSandUtils.fsdFallingMask(cellGrid, lmMask, lm, brushMask, gapTol);
                    end
                    belowFalling = belowFalling | lf;
                end
                belowFallingShifted = [belowFalling(2:end, :); false(1, Nx)];
                cs = isAcid & ~acidFalling & isLighter & ~belowFallingShifted;
                cs(end, :) = false;
                idx = find(cs);
                if ~isempty(idx)
                    displaced = cellGrid(idx + 1);
                    cellGrid(idx + 1) = 7;  cellGrid(idx) = displaced;
                end
                isAcid = (cellGrid == 7);

                % Acid + water -> neutralize + steam
                isWNow = (cellGrid == 2);
                if any(isWNow, "all")
                    adjW = [false(1, Nx); isWNow(1:end-1, :)] | ...
                        [isWNow(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isWNow(:, 1:end-1)] | ...
                        [isWNow(:, 2:end), false(Ny, 1)];
                    adjA = [false(1, Nx); isAcid(1:end-1, :)] | ...
                        [isAcid(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isAcid(:, 1:end-1)] | ...
                        [isAcid(:, 2:end), false(Ny, 1)];
                    acidNeut = isAcid & adjW & (randMat < 0.25);
                    waterNeut = isWNow & adjA & (randMat < 0.25);
                    nAN = nnz(acidNeut);  nWN = nnz(waterNeut);
                    if nAN > 0
                        cellGrid(acidNeut) = 8;
                        cellLife(acidNeut) = uint8(randi([10, 20], nAN, 1));
                    end
                    if nWN > 0
                        cellGrid(waterNeut) = 8;
                        cellLife(waterNeut) = uint8(randi([10, 20], nWN, 1));
                    end
                    isAcid = (cellGrid == 7);
                end
                % Acid extinguishes fire -> smoke
                isFire = (cellGrid == 4);
                if any(isFire, "all")
                    adjA = [false(1, Nx); isAcid(1:end-1, :)] | ...
                        [isAcid(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isAcid(:, 1:end-1)] | ...
                        [isAcid(:, 2:end), false(Ny, 1)];
                    ext = isFire & adjA;
                    if any(ext, "all")
                        nS = nnz(ext);
                        cellGrid(ext) = 10;  cellLife(ext) = uint8(randi([10, 20], nS, 1));
                    end
                    isAcid = (cellGrid == 7);
                end
                % Corrode: sand/wood/oil/snow
                corrodable = (cellGrid == 1 | cellGrid == 6 | cellGrid == 5 | cellGrid == 15);
                if any(corrodable, "all")
                    belowC = [corrodable(2:end, :); false(1, Nx)];
                    leftC = [false(Ny, 1), corrodable(:, 1:end-1)];
                    rightC = [corrodable(:, 2:end), false(Ny, 1)];
                    aboveC = [false(1, Nx); corrodable(1:end-1, :)];
                    % Acid eats below first
                    eatB = isAcid & belowC & (randMat < 0.30);
                    idx = find(eatB);
                    if ~isempty(idx)
                        cellGrid(idx + 1) = 0;
                        nE = numel(idx);
                        cellGrid(idx) = 10;
                        cellLife(idx) = uint8(randi([5, 12], nE, 1));
                    end
                    isAcid = (cellGrid == 7);
                    eatL = isAcid & leftC & (randMat < 0.15);
                    idx = find(eatL);
                    if ~isempty(idx)
                        cellGrid(idx - Ny) = 0;
                        nE = numel(idx);
                        cellGrid(idx) = 10;  cellLife(idx) = uint8(randi([5, 12], nE, 1));
                    end
                    isAcid = (cellGrid == 7);
                    eatR = isAcid & rightC & (randMat > 0.85);
                    idx = find(eatR);
                    if ~isempty(idx)
                        cellGrid(idx + Ny) = 0;
                        nE = numel(idx);
                        cellGrid(idx) = 10;  cellLife(idx) = uint8(randi([5, 12], nE, 1));
                    end
                    isAcid = (cellGrid == 7);
                    eatU = isAcid & aboveC & (randMat < 0.10);
                    idx = find(eatU);
                    if ~isempty(idx)
                        cellGrid(idx - 1) = 0;
                        nE = numel(idx);
                        cellGrid(idx) = 10;  cellLife(idx) = uint8(randi([5, 12], nE, 1));
                    end
                end
                % Acid corrodes metal (10%)
                isAcid = (cellGrid == 7);
                isMtl = (cellGrid == 11);
                if any(isMtl, "all")
                    adjMtl = [false(1, Nx); isMtl(1:end-1, :)] | ...
                        [isMtl(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isMtl(:, 1:end-1)] | ...
                        [isMtl(:, 2:end), false(Ny, 1)];
                    adjA2 = [false(1, Nx); isAcid(1:end-1, :)] | ...
                        [isAcid(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isAcid(:, 1:end-1)] | ...
                        [isAcid(:, 2:end), false(Ny, 1)];
                    eatMtl = isMtl & adjA2 & (randMat < 0.10);
                    acidUsed = isAcid & adjMtl & (randMat < 0.10);
                    nEM = nnz(eatMtl);  nAU = nnz(acidUsed);
                    if nEM > 0; cellGrid(eatMtl) = 0; end
                    if nAU > 0; cellGrid(acidUsed) = 10; cellLife(acidUsed) = uint8(randi([5, 12], nAU, 1)); end
                    isAcid = (cellGrid == 7);
                end
                % Acid corrodes stone (5%)
                isStn = (cellGrid == 3);
                if any(isStn, "all")
                    adjStn = [false(1, Nx); isStn(1:end-1, :)] | ...
                        [isStn(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isStn(:, 1:end-1)] | ...
                        [isStn(:, 2:end), false(Ny, 1)];
                    adjA3 = [false(1, Nx); isAcid(1:end-1, :)] | ...
                        [isAcid(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isAcid(:, 1:end-1)] | ...
                        [isAcid(:, 2:end), false(Ny, 1)];
                    eatStn = isStn & adjA3 & (randMat < 0.05);
                    acidUsed2 = isAcid & adjStn & (randMat < 0.05);
                    nES = nnz(eatStn);  nAU2 = nnz(acidUsed2);
                    if nES > 0; cellGrid(eatStn) = 0; end
                    if nAU2 > 0; cellGrid(acidUsed2) = 10; cellLife(acidUsed2) = uint8(randi([5, 12], nAU2, 1)); end
                end

                % Acid flow (laminar or turbulent)
                [cellGrid, cellLife] = obj.flowLiquid(cellGrid, cellLife, uint8(7), ...
                    uint8([2, 5, 8, 10]), brushMask, randMat, gapTol, flowMode, ...
                    hasFinger, mtrl, bx, by, bRad, Ny, Nx);
            end

            % --- STEAM (8) / SMOKE (10) ---
            for gasMat = uint8([8, 10])
                isGas = (cellGrid == gasMat);
                if any(isGas, "all")
                    cellLife(isGas) = cellLife(isGas) - 1;
                    expired = isGas & (cellLife == 0);
                    cellGrid(expired) = 0;  isGas(expired) = false;
                    if any(isGas, "all")
                        % Rise up into empty
                        av = [zeros(1, Nx, "uint8"); cellGrid(1:end-1, :)];
                        cf = isGas & (av == 0);  cf(1, :) = false;
                        idx = find(cf);
                        if ~isempty(idx)
                            cellGrid(idx - 1) = gasMat;  cellLife(idx - 1) = cellLife(idx);
                            cellGrid(idx) = 0;  cellLife(idx) = 0;
                        end
                        % Rise through liquids (density swap)
                        isGas = (cellGrid == gasMat);
                        av = [zeros(1, Nx, "uint8"); cellGrid(1:end-1, :)];
                        isLiq = (av == 2 | av == 5 | av == 7 | av == 9);
                        cSwap = isGas & isLiq;  cSwap(1, :) = false;
                        idx = find(cSwap);
                        if ~isempty(idx)
                            liqVal = cellGrid(idx - 1);
                            cellGrid(idx - 1) = gasMat;
                            cellLife(idx - 1) = cellLife(idx);
                            cellGrid(idx) = liqVal;
                            cellLife(idx) = 0;
                        end
                        % Diagonal rise
                        isGas = (cellGrid == gasMat);
                        abEL = false(Ny, Nx);
                        abEL(2:end, 2:end) = (cellGrid(1:end-1, 1:end-1) == 0);
                        arER = false(Ny, Nx);
                        arER(2:end, 1:end-1) = (cellGrid(1:end-1, 2:end) == 0);
                        cUL = isGas & abEL & (randMat < 0.4);
                        cUR = isGas & arER & ~cUL & (randMat > 0.6);
                        idx = find(cUL);
                        if ~isempty(idx)
                            cellGrid(idx - 1 - Ny) = gasMat;  cellLife(idx - 1 - Ny) = cellLife(idx);
                            cellGrid(idx) = 0;  cellLife(idx) = 0;
                        end
                        idx = find(cUR);
                        if ~isempty(idx)
                            cellGrid(idx - 1 + Ny) = gasMat;  cellLife(idx - 1 + Ny) = cellLife(idx);
                            cellGrid(idx) = 0;  cellLife(idx) = 0;
                        end
                    end
                end
            end

            % --- LAVA (9) ---
            isLava = (cellGrid == 9);
            if any(isLava, "all")
                adjL = [false(1, Nx); isLava(1:end-1, :)] | ...
                    [isLava(2:end, :); false(1, Nx)] | ...
                    [false(Ny, 1), isLava(:, 1:end-1)] | ...
                    [isLava(:, 2:end), false(Ny, 1)];
                % Lava eats through sand -> smoke
                isSandNow = (cellGrid == 1);
                meltSand = isSandNow & adjL;
                if any(meltSand, "all")
                    nMs = nnz(meltSand);
                    cellGrid(meltSand) = 10;
                    cellLife(meltSand) = uint8(randi([8, 16], nMs, 1));
                end
                % Ignite adjacent wood and oil
                ignW = (cellGrid == 6) & adjL & (randMat < 0.25);
                nW = nnz(ignW);
                if nW > 0; cellGrid(ignW) = 4; cellLife(ignW) = uint8(randi([30, 60], nW, 1)); end
                ignO = (cellGrid == 5) & adjL;
                nO = nnz(ignO);
                if nO > 0; cellGrid(ignO) = 4; cellLife(ignO) = uint8(randi([20, 40], nO, 1)); end
                % Lava melts glass -> steam
                isGlassNow = (cellGrid == 12);
                meltGlass = isGlassNow & adjL & (randMat < 0.15);
                nMg = nnz(meltGlass);
                if nMg > 0
                    meltIdx = find(meltGlass);
                    cellGrid(meltGlass) = 0;
                    abEmpty = (meltIdx > 1) & (cellGrid(max(meltIdx - 1, 1)) == 0);
                    sIdx = meltIdx(abEmpty) - 1;
                    nSm = numel(sIdx);
                    if nSm > 0; cellGrid(sIdx) = 8; cellLife(sIdx) = uint8(randi([10, 20], nSm, 1)); end
                end
                % Lava + acid -> acid boils to smoke
                isANow = (cellGrid == 7);
                if any(isANow, "all")
                    acidBoil = isANow & adjL;
                    nAB = nnz(acidBoil);
                    if nAB > 0
                        cellGrid(acidBoil) = 10;
                        cellLife(acidBoil) = uint8(randi([10, 20], nAB, 1));
                    end
                end
                % Lava slowly melts ice and snow
                isIceNow = (cellGrid == 13);
                if any(isIceNow, "all")
                    meltIce = isIceNow & adjL & (randMat < 0.10);
                    cellGrid(meltIce) = 0;  cellLife(meltIce) = 0;
                end
                isSnowNow = (cellGrid == 15);
                if any(isSnowNow, "all")
                    meltSnowL = isSnowNow & adjL & (randMat < 0.10);
                    nMs = nnz(meltSnowL);
                    if nMs > 0
                        cellGrid(meltSnowL) = 8;
                        cellLife(meltSnowL) = uint8(randi([10, 20], nMs, 1));
                    end
                end
                % Lava + water -> stone (4-ring conversion)
                isWNow = (cellGrid == 2);
                adjW1 = [false(1, Nx); isWNow(1:end-1, :)] | ...
                    [isWNow(2:end, :); false(1, Nx)] | ...
                    [false(Ny, 1), isWNow(:, 1:end-1)] | ...
                    [isWNow(:, 2:end), false(Ny, 1)];
                lavaCool1 = isLava & adjW1;
                waterHeat = isWNow & adjL;
                cellGrid(lavaCool1) = 3;
                cellGrid(waterHeat) = 3;
                % Ring 2
                isLava2 = (cellGrid == 9);
                newStone = lavaCool1;
                adjS2 = [false(1, Nx); newStone(1:end-1, :)] | ...
                    [newStone(2:end, :); false(1, Nx)] | ...
                    [false(Ny, 1), newStone(:, 1:end-1)] | ...
                    [newStone(:, 2:end), false(Ny, 1)];
                lavaCool2 = isLava2 & adjS2 & (randMat < 0.9);
                cellGrid(lavaCool2) = 3;
                % Ring 3
                isLava3 = (cellGrid == 9);
                newStone2 = lavaCool2;
                adjS3 = [false(1, Nx); newStone2(1:end-1, :)] | ...
                    [newStone2(2:end, :); false(1, Nx)] | ...
                    [false(Ny, 1), newStone2(:, 1:end-1)] | ...
                    [newStone2(:, 2:end), false(Ny, 1)];
                lavaCool3 = isLava3 & adjS3 & (randMat < 0.7);
                cellGrid(lavaCool3) = 3;
                % Ring 4
                isLava4 = (cellGrid == 9);
                newStone3 = lavaCool3;
                adjS4 = [false(1, Nx); newStone3(1:end-1, :)] | ...
                    [newStone3(2:end, :); false(1, Nx)] | ...
                    [false(Ny, 1), newStone3(:, 1:end-1)] | ...
                    [newStone3(:, 2:end), false(Ny, 1)];
                lavaCool4 = isLava4 & adjS4 & (randMat < 0.4);
                cellGrid(lavaCool4) = 3;
                % Gravity — viscous (80%)
                isLava = (cellGrid == 9);
                bv = [cellGrid(2:end, :); ones(1, Nx, "uint8")];
                cf = isLava & (bv == 0 | bv == 13 | bv == 15) & (randMat < 0.8);
                cf(end, :) = false;
                idx = find(cf);
                if ~isempty(idx); cellGrid(idx + 1) = 9; cellGrid(idx) = 0; end
                % Diagonal fall (viscous)
                isLava = (cellGrid == 9);
                bv = [cellGrid(2:end, :); ones(1, Nx, "uint8")];
                bbL = isLava & (bv ~= 0);  bbL(end, :) = false;
                gBL = cellGrid(2:end, 1:end-1);
                blE = false(Ny, Nx); blE(1:end-1, 2:end) = (gBL == 0 | gBL == 13 | gBL == 15);
                gBR = cellGrid(2:end, 2:end);
                brE = false(Ny, Nx); brE(1:end-1, 1:end-1) = (gBR == 0 | gBR == 13 | gBR == 15);
                cBL = bbL & blE;  cBR = bbL & brE;
                bo = cBL & cBR;  pR = bo & (randMat > 0.5);
                cBL(pR) = false;  cBR(bo & ~pR) = false;  cBR(cBL) = false;
                idx = find(cBL);
                if ~isempty(idx); cellGrid(idx + 1 - Ny) = 9; cellGrid(idx) = 0; end
                idx = find(cBR);
                if ~isempty(idx); cellGrid(idx + 1 + Ny) = 9; cellGrid(idx) = 0; end
                % Horizontal slide (30%)
                isLava = (cellGrid == 9);
                bv = [cellGrid(2:end, :); ones(1, Nx, "uint8")];
                bbL = isLava & (bv ~= 0);  bbL(end, :) = false;
                blF = false(Ny, Nx); blF(1:end-1, 2:end) = (cellGrid(2:end, 1:end-1) ~= 0);
                brF = false(Ny, Nx); brF(1:end-1, 1:end-1) = (cellGrid(2:end, 2:end) ~= 0);
                stuck = bbL & (blF | ~blE) & (brF | ~brE);
                lE = [false(Ny, 1), cellGrid(:, 1:end-1) == 0 | cellGrid(:, 1:end-1) == 13 | cellGrid(:, 1:end-1) == 15];
                rE = [cellGrid(:, 2:end) == 0 | cellGrid(:, 2:end) == 13 | cellGrid(:, 2:end) == 15, false(Ny, 1)];
                canL = stuck & lE & (randMat < 0.30);
                canR = stuck & rE & (randMat < 0.30);
                bo = canL & canR;  pR = bo & (randMat > 0.5);
                canL(pR) = false;  canR(bo & ~pR) = false;  canR(canL) = false;
                idx = find(canL);
                if ~isempty(idx); cellGrid(idx - Ny) = 9; cellGrid(idx) = 0; end
                idx = find(canR);
                if ~isempty(idx); cellGrid(idx + Ny) = 9; cellGrid(idx) = 0; end
            end

            % --- ICE (13) ---
            isIce = (cellGrid == 13);
            if any(isIce, "all")
                % Tick down melt cooldown on water cells
                wCool = (cellGrid == 2) & (cellLife > 0);
                if any(wCool, "all")
                    cellLife(wCool) = cellLife(wCool) - 1;
                end
                % Ice + fire -> ice melts to water, fire dies
                isFire = (cellGrid == 4);
                if any(isFire, "all")
                    adjFire = [false(1, Nx); isFire(1:end-1, :)] | ...
                        [isFire(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isFire(:, 1:end-1)] | ...
                        [isFire(:, 2:end), false(Ny, 1)];
                    adjIce = [false(1, Nx); isIce(1:end-1, :)] | ...
                        [isIce(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isIce(:, 1:end-1)] | ...
                        [isIce(:, 2:end), false(Ny, 1)];
                    meltIce = isIce & adjFire;
                    killFire = isFire & adjIce;
                    cellGrid(meltIce) = 2;  cellLife(meltIce) = 100;
                    cellGrid(killFire) = 0;  cellLife(killFire) = 0;
                end
                % Acid + ice -> both steam
                isIce = (cellGrid == 13);
                isAcid = (cellGrid == 7);
                if any(isAcid, "all") && any(isIce, "all")
                    adjAcid = [false(1, Nx); isAcid(1:end-1, :)] | ...
                        [isAcid(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isAcid(:, 1:end-1)] | ...
                        [isAcid(:, 2:end), false(Ny, 1)];
                    adjIceA = [false(1, Nx); isIce(1:end-1, :)] | ...
                        [isIce(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isIce(:, 1:end-1)] | ...
                        [isIce(:, 2:end), false(Ny, 1)];
                    dissolveIce = isIce & adjAcid;
                    acidNeut = isAcid & adjIceA;
                    nDI = nnz(dissolveIce);  nAN = nnz(acidNeut);
                    if nDI > 0; cellGrid(dissolveIce) = 8; cellLife(dissolveIce) = uint8(randi([10, 20], nDI, 1)); end
                    if nAN > 0; cellGrid(acidNeut) = 8; cellLife(acidNeut) = uint8(randi([10, 20], nAN, 1)); end
                end
                % Water freezes near ice
                isIce = (cellGrid == 13);
                isWNow = (cellGrid == 2);
                if any(isWNow, "all")
                    adjIce = [false(1, Nx); isIce(1:end-1, :)] | ...
                        [isIce(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isIce(:, 1:end-1)] | ...
                        [isIce(:, 2:end), false(Ny, 1)];
                    freeze = isWNow & adjIce & (cellLife == 0);
                    if any(freeze, "all")
                        cellGrid(freeze) = 13;
                    end
                end
            end

            % --- CONCRETE (14) ---
            isCon = (cellGrid == 14);
            if any(isCon, "all")
                % Decrement visual cure timer
                curing = isCon & (cellLife > 0) & ~brushMask;
                if any(curing, "all")
                    cellLife(curing) = cellLife(curing) - 1;
                    % Water hydration
                    isW = (cellGrid == 2);
                    if any(isW, "all")
                        adjCon = [false(1, Nx); curing(1:end-1, :)] | [curing(2:end, :); false(1, Nx)] | ...
                            [false(Ny, 1), curing(:, 1:end-1)] | [curing(:, 2:end), false(Ny, 1)];
                        waterUsed = isW & adjCon;
                        if any(waterUsed, "all")
                            adjWU = [false(1, Nx); waterUsed(1:end-1, :)] | [waterUsed(2:end, :); false(1, Nx)] | ...
                                [false(Ny, 1), waterUsed(:, 1:end-1)] | [waterUsed(:, 2:end), false(Ny, 1)];
                            wetCon = curing & adjWU;
                            cellLife(wetCon) = cellLife(wetCon) - min(cellLife(wetCon), 60);
                            cellGrid(waterUsed) = 0;  cellLife(waterUsed) = 0;
                        end
                    end
                end
                % Gravity: chain falls, top of chain cleared
                willFall = false(Ny, Nx);
                for r = Ny-1:-1:1
                    willFall(r, :) = isCon(r, :) & ~brushMask(r, :) & ...
                        (cellGrid(r+1, :) == 0 | willFall(r+1, :));
                end
                idx = find(willFall);
                if ~isempty(idx)
                    cl = cellLife(idx);
                    cellGrid(idx + 1) = 14;  cellLife(idx + 1) = cl;
                    topOfChain = willFall & ~[false(1, Nx); willFall(1:end-1, :)];
                    cellGrid(topOfChain) = 0;  cellLife(topOfChain) = 0;
                end
                % Density swap: concrete sinks through lighter materials
                isCon = (cellGrid == 14);
                conFalling = games.FallingSandUtils.fsdFallingMask(cellGrid, isCon, 14, brushMask, gapTol);
                bv = [cellGrid(2:end, :); zeros(1, Nx, "uint8")];
                isLighter = (bv == 2 | bv == 5 | bv == 7 | bv == 8 | bv == 10);
                belowFalling = false(Ny, Nx);
                for lm = uint8([2, 5, 7, 8, 10])
                    lmMask = (cellGrid == lm);
                    if ~any(lmMask, "all"); continue; end
                    if ismember(lm, [2, 5, 7]) && flowMode == "turbulent"
                        lf = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, lmMask, lm, brushMask, gapTol);
                    else
                        lf = games.FallingSandUtils.fsdFallingMask(cellGrid, lmMask, lm, brushMask, gapTol);
                    end
                    belowFalling = belowFalling | lf;
                end
                belowFallingShifted = [belowFalling(2:end, :); false(1, Nx)];
                cs = isCon & ~conFalling & isLighter & ~belowFallingShifted;
                cs(end, :) = false;
                idx = find(cs);
                if ~isempty(idx)
                    cl = cellLife(idx);
                    displaced = cellGrid(idx + 1);  dlf = cellLife(idx + 1);
                    cellGrid(idx + 1) = 14;  cellLife(idx + 1) = cl;
                    cellGrid(idx) = displaced;  cellLife(idx) = dlf;
                end
                % Extra emission at bottom of brush
                if hasFinger && mtrl == 14
                    eRow = min(Ny, gy + obj.BrushSize) + 1;
                    if eRow <= Ny
                        ec1 = max(1, gx - obj.BrushSize);
                        ec2 = min(Nx, gx + obj.BrushSize);
                        emptyR = cellGrid(eRow, ec1:ec2) == 0;
                        if any(emptyR)
                            cellGrid(eRow, ec1 - 1 + find(emptyR)) = 14;
                            cellLife(eRow, ec1 - 1 + find(emptyR)) = uint8(randi([80, 120], 1, nnz(emptyR)));
                        end
                    end
                end
            end

            % --- SNOW (15) ---
            isSnow = (cellGrid == 15);
            if any(isSnow, "all")
                % Age all snow cells
                isSnowAlive = isSnow & (cellLife < 255);
                if any(isSnowAlive, "all")
                    cellLife(isSnowAlive) = cellLife(isSnowAlive) + 1;
                end
                % Compaction: settled aged snow under 5+ cells -> ice
                snowFalling = games.FallingSandUtils.fsdFallingMask(cellGrid, isSnow, 15, brushMask, gapTol);
                settled = isSnow & ~snowFalling & ~brushMask & (cellLife >= 60);
                if any(settled, "all")
                    aboveCount = zeros(Ny, Nx);
                    for r = 2:Ny
                        aboveCount(r, :) = double(cellGrid(r-1, :) > 0) .* (aboveCount(r-1, :) + 1);
                    end
                    canCompact = settled & (aboveCount >= 5);
                    if any(canCompact, "all")
                        nConsume = obj.SnowCompactRatio;
                        for c = 1:Nx
                            col = canCompact(:, c);
                            if ~any(col); continue; end
                            rowsC = find(col);
                            if numel(rowsC) < nConsume; continue; end
                            cellGrid(rowsC(end), c) = 13;  cellLife(rowsC(end), c) = 0;
                            for kk = 1:nConsume-1
                                rRem = rowsC(kk);
                                rTop = rRem - 1;
                                while rTop >= 1 && cellGrid(rTop, c) ~= 0
                                    rTop = rTop - 1;
                                end
                                rTop = rTop + 1;
                                if rTop <= rRem
                                    cellGrid(rTop+1:rRem, c) = cellGrid(rTop:rRem-1, c);
                                    cellLife(rTop+1:rRem, c) = cellLife(rTop:rRem-1, c);
                                    cellGrid(rTop, c) = 0;  cellLife(rTop, c) = 0;
                                end
                            end
                        end
                    end
                end
                % Fire + snow -> water, fire dies
                isSnow = (cellGrid == 15);
                isFire = (cellGrid == 4);
                if any(isFire, "all") && any(isSnow, "all")
                    adjFire = [false(1, Nx); isFire(1:end-1, :)] | ...
                        [isFire(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isFire(:, 1:end-1)] | ...
                        [isFire(:, 2:end), false(Ny, 1)];
                    adjSnow = [false(1, Nx); isSnow(1:end-1, :)] | ...
                        [isSnow(2:end, :); false(1, Nx)] | ...
                        [false(Ny, 1), isSnow(:, 1:end-1)] | ...
                        [isSnow(:, 2:end), false(Ny, 1)];
                    meltSnow = isSnow & adjFire;
                    killFire = isFire & adjSnow;
                    cellGrid(meltSnow) = 2;  cellLife(meltSnow) = 0;
                    cellGrid(killFire) = 0;  cellLife(killFire) = 0;
                end
                % Gravity: chain falls, top-of-chain clearing
                isSnow = (cellGrid == 15);
                willFall = false(Ny, Nx);
                for r = Ny-1:-1:1
                    willFall(r, :) = isSnow(r, :) & ~brushMask(r, :) & ...
                        (cellGrid(r+1, :) == 0 | willFall(r+1, :));
                end
                idx = find(willFall);
                if ~isempty(idx)
                    cellGrid(idx + 1) = 15;
                    topOfChain = willFall & ~[false(1, Nx); willFall(1:end-1, :)];
                    cellGrid(topOfChain) = 0;
                end
                % Lateral drift: falling snow randomly shifts
                isSnow = (cellGrid == 15);
                snowFalling = games.FallingSandUtils.fsdFallingMask(cellGrid, isSnow, 15, brushMask, gapTol);
                driftCand = isSnow & snowFalling & ~brushMask & (randMat < 0.40);
                driftCand(end, :) = false;
                if any(driftCand, "all")
                    lEmpty = [false(Ny, 1), cellGrid(:, 1:end-1) == 0];
                    rEmpty = [cellGrid(:, 2:end) == 0, false(Ny, 1)];
                    goRight = rand(Ny, Nx) > 0.5;
                    cBL = driftCand & lEmpty & ~goRight;
                    cBR = driftCand & rEmpty & goRight;
                    idx = find(cBL);
                    if ~isempty(idx); cellGrid(idx - Ny) = 15; cellGrid(idx) = 0; end
                    idx = find(cBR);
                    if ~isempty(idx); cellGrid(idx + Ny) = 15; cellGrid(idx) = 0; end
                end
                % Diagonal piling
                isSnow = (cellGrid == 15);
                snowFalling = games.FallingSandUtils.fsdFallingMask(cellGrid, isSnow, 15, brushMask, gapTol);
                bv = [cellGrid(2:end, :); ones(1, Nx, "uint8")];
                bbS = isSnow & ~snowFalling & ~brushMask & (bv ~= 0);
                bbS(end, :) = false;
                blE = false(Ny, Nx); blE(1:end-1, 2:end) = (cellGrid(2:end, 1:end-1) == 0);
                brE = false(Ny, Nx); brE(1:end-1, 1:end-1) = (cellGrid(2:end, 2:end) == 0);
                cBL = bbS & blE;  cBR = bbS & brE;
                bo = cBL & cBR;  pR = bo & (randMat > 0.5);
                cBL(pR) = false;  cBR(bo & ~pR) = false;
                idx = find(cBL);
                if ~isempty(idx); cellGrid(idx + 1 - Ny) = 15; cellGrid(idx) = 0; end
                idx = find(cBR);
                if ~isempty(idx); cellGrid(idx + 1 + Ny) = 15; cellGrid(idx) = 0; end
                % Density swap: snow sinks through gases
                isSnow = (cellGrid == 15);
                snowFalling = games.FallingSandUtils.fsdFallingMask(cellGrid, isSnow, 15, brushMask, gapTol);
                bv = [cellGrid(2:end, :); zeros(1, Nx, "uint8")];
                isLighter = (bv == 8 | bv == 10);
                belowFalling = false(Ny, Nx);
                for lm = uint8([8, 10])
                    lmMask = (cellGrid == lm);
                    if any(lmMask, "all")
                        belowFalling = belowFalling | games.FallingSandUtils.fsdFallingMask(cellGrid, lmMask, lm, brushMask, gapTol);
                    end
                end
                belowFallingShifted = [belowFalling(2:end, :); false(1, Nx)];
                cs = isSnow & ~snowFalling & isLighter & ~belowFallingShifted;
                cs(end, :) = false;
                idx = find(cs);
                if ~isempty(idx)
                    displaced = cellGrid(idx + 1);  dlf = cellLife(idx + 1);
                    cellGrid(idx + 1) = 15;
                    cellGrid(idx) = displaced;  cellLife(idx) = dlf;
                end
            end

            obj.CellGrid = cellGrid;  obj.CellLife = cellLife;
            end  % SimAccum gate

            % === RENDER ===
            if ~isempty(obj.ImageH) && isvalid(obj.ImageH)
                noiseData = obj.ColorNoise;
                R = zeros(Ny, Nx, "uint8"); G = R; B = R;
                mu = uint8(cellGrid == 1);
                R = R + mu .* (220 + noiseData(:,:,1));
                G = G + mu .* (180 + noiseData(:,:,2));
                B = B + mu .* (50 + noiseData(:,:,3));
                mu = uint8(cellGrid == 2);
                R = R + mu .* (30 + min(noiseData(:,:,1), uint8(20)));
                G = G + mu .* (100 + noiseData(:,:,2));
                B = B + mu .* min(uint8(255), 200 + noiseData(:,:,3));
                mu = uint8(cellGrid == 3);
                R = R + mu .* (120 + min(noiseData(:,:,1), uint8(20)));
                G = G + mu .* (120 + min(noiseData(:,:,2), uint8(20)));
                B = B + mu .* (130 + min(noiseData(:,:,3), uint8(20)));
                fm = (cellGrid == 4);
                if any(fm, "all")
                    mu = uint8(fm); nF = nnz(fm);
                    fR = zeros(Ny, Nx, "uint8"); fG = fR;
                    fR(fm) = uint8(randi([220, 255], nF, 1));
                    fG(fm) = uint8(randi([80, 200], nF, 1));
                    R = R + mu .* fR;  G = G + mu .* fG;
                end
                mu = uint8(cellGrid == 5);
                R = R + mu .* (40 + min(noiseData(:,:,1), uint8(20)));
                G = G + mu .* (80 + min(noiseData(:,:,2), uint8(20)));
                B = B + mu .* (30 + min(noiseData(:,:,3), uint8(15)));
                mu = uint8(cellGrid == 6);
                R = R + mu .* (140 + min(noiseData(:,:,1), uint8(30)));
                G = G + mu .* (80 + min(noiseData(:,:,2), uint8(20)));
                B = B + mu .* (30 + min(noiseData(:,:,3), uint8(10)));
                mu = uint8(cellGrid == 7);
                R = R + mu .* (100 + min(noiseData(:,:,1), uint8(30)));
                G = G + mu .* min(uint8(255), 220 + noiseData(:,:,2));
                B = B + mu .* (20 + min(noiseData(:,:,3), uint8(15)));
                sm = (cellGrid == 8);
                if any(sm, "all")
                    mu = uint8(sm);
                    R = R + mu .* (180 + min(noiseData(:,:,1), uint8(40)));
                    G = G + mu .* (185 + min(noiseData(:,:,2), uint8(40)));
                    B = B + mu .* (195 + min(noiseData(:,:,3), uint8(40)));
                end
                lavaMask = (cellGrid == 9);
                if any(lavaMask, "all")
                    mu = uint8(lavaMask); nLv = nnz(lavaMask);
                    lvR = zeros(Ny, Nx, "uint8"); lvG = lvR;
                    lvR(lavaMask) = uint8(randi([220, 255], nLv, 1));
                    lvG(lavaMask) = uint8(randi([80, 160], nLv, 1));
                    R = R + mu .* lvR;  G = G + mu .* lvG;
                    B = B + mu .* uint8(20);
                end
                mu = uint8(cellGrid == 10);
                R = R + mu .* (70 + min(noiseData(:,:,1), uint8(25)));
                G = G + mu .* (72 + min(noiseData(:,:,2), uint8(25)));
                B = B + mu .* (75 + min(noiseData(:,:,3), uint8(25)));
                mu = uint8(cellGrid == 11);
                R = R + mu .* (160 + min(noiseData(:,:,1), uint8(25)));
                G = G + mu .* (165 + min(noiseData(:,:,2), uint8(25)));
                B = B + mu .* (180 + min(noiseData(:,:,3), uint8(25)));
                mu = uint8(cellGrid == 12);
                R = R + mu .* (120 + min(noiseData(:,:,1), uint8(30)));
                G = G + mu .* (180 + min(noiseData(:,:,2), uint8(30)));
                B = B + mu .* min(uint8(255), 220 + noiseData(:,:,3));
                mu = uint8(cellGrid == 13);
                R = R + mu .* (200 + min(noiseData(:,:,1), uint8(40)));
                G = G + mu .* min(uint8(255), 230 + noiseData(:,:,2));
                B = B + mu .* min(uint8(255), 240 + noiseData(:,:,3));
                conM = (cellGrid == 14);
                if any(conM, "all")
                    mu = uint8(conM);
                    conLife = double(cellLife) .* double(conM);
                    cureF = 1 - min(conLife / 120, 1);
                    baseR = uint8(75 + cureF * 105);
                    baseG = uint8(68 + cureF * 112);
                    baseB = uint8(60 + cureF * 125);
                    R = R + mu .* (baseR + min(noiseData(:,:,1), uint8(12)));
                    G = G + mu .* (baseG + min(noiseData(:,:,2), uint8(10)));
                    B = B + mu .* (baseB + min(noiseData(:,:,3), uint8(8)));
                end
                mu = uint8(cellGrid == 15);
                R = R + mu .* (235 + min(noiseData(:,:,1), uint8(20)));
                G = G + mu .* (237 + min(noiseData(:,:,2), uint8(18)));
                B = B + mu .* min(uint8(255), 245 + noiseData(:,:,3));
                % Debug: override falling cells to red
                if showDebug
                    isMat = (cellGrid > 0);
                    isStaticG = (cellGrid == 3) | (cellGrid == 6) | ...
                        (cellGrid == 11) | (cellGrid == 12) | (cellGrid == 13);
                    isDynamic = isMat & ~isStaticG;
                    if flowMode == "laminar"
                        fl = games.FallingSandUtils.fsdFallingMask(cellGrid, isDynamic, 0, brushMask, gapTol);
                    else
                        fl = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, isDynamic, 0, brushMask, gapTol);
                    end
                    R(fl) = 255;  G(fl) = 0;  B(fl) = 0;
                end
                obj.ImageH.CData = cat(3, R, G, B);
            end
            obj.Score = nnz(cellGrid > 0);
        end

        function onCleanup(obj)
            %onCleanup  Delete Elements graphics and reset state.
            h = {obj.ImageH, obj.ModeTextH};
            for k = 1:numel(h)
                if ~isempty(h{k}) && isvalid(h{k}); delete(h{k}); end
            end
            obj.ImageH = [];  obj.ModeTextH = [];
            obj.CellGrid = [];  obj.CellLife = [];
            obj.ColorNoise = [];  obj.FrameCount = 0;
            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_elements");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle Elements key events.
            handled = true;
            switch key
                case "m"
                    % Cycle material
                    modes = obj.MaterialNames;
                    idx = find(modes == obj.SubMode, 1);
                    nextIdx = mod(idx, numel(modes)) + 1;
                    obj.SubMode = modes(nextIdx);
                    obj.CurrentMaterial = obj.MaterialIDs(nextIdx);
                    obj.refreshHud();
                case "n"
                    % Cycle spawn pattern
                    if obj.WaterFlowMode == "turbulent"
                        patterns = ["flood", "rain", "waterfall", "cascade", "jet"];
                    else
                        patterns = ["flow", "drizzle", "curtain", "veil", "trickle"];
                    end
                    idx = find(patterns == obj.SpawnPattern, 1);
                    if isempty(idx); idx = 1; end
                    obj.SpawnPattern = patterns(mod(idx, numel(patterns)) + 1);
                    obj.refreshHud();
                case "b"
                    % Toggle flow mode
                    laminar  = ["flow", "drizzle", "curtain", "veil", "trickle"];
                    turb     = ["flood", "rain", "waterfall", "cascade", "jet"];
                    if obj.WaterFlowMode == "laminar"
                        obj.WaterFlowMode = "turbulent";
                        idxL = find(laminar == obj.SpawnPattern, 1);
                        if ~isempty(idxL)
                            obj.SpawnPattern = turb(idxL);
                        end
                    else
                        obj.WaterFlowMode = "laminar";
                        idxT = find(turb == obj.SpawnPattern, 1);
                        if ~isempty(idxT)
                            obj.SpawnPattern = laminar(idxT);
                        end
                    end
                    obj.refreshHud();
                case "uparrow"
                    obj.BrushSize = min(8, obj.BrushSize + 1);
                    obj.refreshHud();
                case "downarrow"
                    obj.BrushSize = max(1, obj.BrushSize - 1);
                    obj.refreshHud();
                case "numpad1"
                    obj.SubMode = "concrete";
                    obj.CurrentMaterial = uint8(14);
                    obj.refreshHud();
                case "numpad2"
                    obj.SubMode = "snow";
                    obj.CurrentMaterial = uint8(15);
                    obj.refreshHud();
                case "backspace"
                    obj.SubMode = "eraser";
                    obj.CurrentMaterial = uint8(0);
                    obj.refreshHud();
                case "backquote"
                    obj.DebugFalling = ~obj.DebugFalling;
                    obj.refreshHud();
                case "equal"
                    obj.SubMode = "none";
                    obj.CurrentMaterial = uint8(255);
                    obj.refreshHud();
                case "hyphen"
                    obj.SubMode = "ice";
                    obj.CurrentMaterial = uint8(13);
                    obj.refreshHud();
                case "numpad0"
                    if ~isempty(obj.CellGrid)
                        obj.CellGrid(:) = 0;
                        obj.CellLife(:) = 0;
                    end
                otherwise
                    if strlength(key) == 1 && key >= "0" && key <= "9"
                        d = str2double(key);
                        if d == 0
                            obj.SubMode = "glass";
                            obj.CurrentMaterial = uint8(12);
                        elseif d <= numel(obj.MaterialNames) - 1
                            obj.SubMode = obj.MaterialNames(d);
                            obj.CurrentMaterial = obj.MaterialIDs(d);
                        end
                        obj.refreshHud();
                    else
                        handled = false;
                    end
            end
        end

    end

    % =================================================================
    % OPTIONAL OVERRIDES
    % =================================================================
    methods

        function r = getResults(obj)
            %getResults  Return Elements results struct.
            r.Title = obj.Name;
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            totalCells = 0;
            if ~isempty(obj.CellGrid)
                totalCells = nnz(obj.CellGrid > 0);
            end
            r.Lines = {sprintf("Cells: %d  |  Time: %.0fs", totalCells, elapsed)};
        end

    end

    % =================================================================
    % PRIVATE HELPERS
    % =================================================================
    methods (Access = private)

        function refreshHud(obj)
            %refreshHud  Refresh the Elements HUD text handle.
            if isempty(obj.ModeTextH) || ~isvalid(obj.ModeTextH); return; end
            obj.ModeTextH.String = obj.buildHudString();
            switch obj.SubMode
                case "sand";     obj.ModeTextH.Color = [1, 0.85, 0.2, 0.8];
                case "water";    obj.ModeTextH.Color = [0, 0.92, 1, 0.8];
                case "stone";    obj.ModeTextH.Color = [0.75, 0.78, 0.82, 0.8];
                case "fire";     obj.ModeTextH.Color = [1, 0.3, 0.2, 0.8];
                case "oil";      obj.ModeTextH.Color = [0.14, 0.7, 0.28, 0.8];
                case "wood";     obj.ModeTextH.Color = [0.6, 0.35, 0.15, 0.8];
                case "acid";     obj.ModeTextH.Color = [0.6, 1.0, 0.0, 0.8];
                case "lava";     obj.ModeTextH.Color = [1.0, 0.4, 0.0, 0.8];
                case "metal";    obj.ModeTextH.Color = [0.7, 0.72, 0.8, 0.8];
                case "glass";    obj.ModeTextH.Color = [0.5, 0.8, 1.0, 0.8];
                case "ice";      obj.ModeTextH.Color = [0.8, 0.95, 1.0, 0.8];
                case "concrete"; obj.ModeTextH.Color = [0.5, 0.5, 0.55, 0.8];
                case "snow";     obj.ModeTextH.Color = [0.9, 0.95, 1.0, 0.8];
                case "eraser";   obj.ModeTextH.Color = [1, 0.3, 0.3, 0.9];
                case "none";     obj.ModeTextH.Color = [0.6, 0.6, 0.6, 0.8];
            end
        end

        function s = buildHudString(obj)
            %buildHudString  Build the HUD text string.
            dispPattern = obj.SpawnPattern;
            if ~ismember(obj.SubMode, ["water", "oil", "acid"])
                turbNames   = ["flood", "rain", "waterfall", "cascade", "jet"];
                laminarNames = ["flow", "drizzle", "curtain", "veil", "trickle"];
                idxT = find(turbNames == dispPattern, 1);
                if ~isempty(idxT); dispPattern = laminarNames(idxT); end
            end
            s = upper(obj.SubMode) + ...
                " [M]  |  " + upper(dispPattern) + ...
                " [N]  |  " + upper(obj.WaterFlowMode) + ...
                " [B]  |  Brush " + obj.BrushSize + ...
                " [" + char(8593) + char(8595) + "]  |  Grid " + ...
                obj.GridW + char(215) + obj.GridH;
        end

        function eMask = buildEmitMask(obj, emitCols, nCols, ~)
            %buildEmitMask  Build emission mask based on current spawn pattern.
            switch obj.SpawnPattern
                case {"flow", "flood"}
                    eMask = true(1, nCols);
                case "trickle"
                    eMask = false(1, nCols);
                    mid = ceil(nCols / 2);
                    if obj.BrushSize >= 6
                        hw = min(1, floor(nCols / 5));
                        eMask(max(1, mid - hw):min(nCols, mid + hw)) = true;
                    else
                        eMask(mid) = true;
                    end
                case "jet"
                    eMask = false(1, nCols);
                    mid = ceil(nCols / 2);
                    if obj.BrushSize >= 7
                        hw = min(2, floor(nCols / 4));
                    else
                        hw = min(1, floor(nCols / 5));
                    end
                    eMask(max(1, mid - hw):min(nCols, mid + hw)) = true;
                case {"drizzle", "rain"}
                    eMask = rand(1, nCols) < 0.30;
                case {"curtain", "waterfall"}
                    eMask = mod(emitCols, 2) == 0;
                case "veil"
                    eMask = mod(emitCols + obj.FrameCount, 2) == 0;
                case "cascade"
                    if mod(obj.FrameCount, 2) == 0
                        eMask = true(1, nCols);
                    else
                        eMask = mod(emitCols + obj.FrameCount, 2) == 0;
                    end
                otherwise
                    eMask = true(1, nCols);
            end
        end

        function eMask = buildSecondEmitMask(obj, eCols, nEC)
            %buildSecondEmitMask  Build emission mask for second emission (turbulent).
            switch obj.SpawnPattern
                case "flood"
                    eMask = true(1, nEC);
                case "jet"
                    eMask = false(1, nEC);
                    mid = ceil(nEC / 2);
                    hw = min(1, floor(nEC / 5));
                    eMask(max(1, mid - hw):min(nEC, mid + hw)) = true;
                case "rain"
                    eMask = rand(1, nEC) < 0.30;
                case "waterfall"
                    eMask = mod(eCols, 2) == 0;
                case "cascade"
                    if mod(obj.FrameCount, 2) == 0
                        eMask = true(1, nEC);
                    else
                        eMask = mod(eCols + obj.FrameCount, 2) == 0;
                    end
                otherwise
                    eMask = true(1, nEC);
            end
        end

        function [cellGrid, cellLife] = updateLiquid(obj, cellGrid, cellLife, ...
                isLiq, liqID, lighterIDs, gasDrainIDs, ...
                brushMask, randMat, gapTol, flowMode, ...
                hasFinger, mtrl, bx, by, bRad, Ny, Nx)
            %updateLiquid  Shared density swap + flow for oil (5).
            %   Oil is lighter — only sinks through gases.
            if flowMode == "turbulent"
                liqFalling = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, isLiq, liqID, brushMask, gapTol);
            else
                liqFalling = games.FallingSandUtils.fsdFallingMask(cellGrid, isLiq, liqID, brushMask, gapTol);
            end
            bv = [cellGrid(2:end, :); zeros(1, Nx, "uint8")];
            isLighter = false(Ny, Nx);
            for ii = 1:numel(lighterIDs)
                isLighter = isLighter | (bv == lighterIDs(ii));
            end
            belowFalling = false(Ny, Nx);
            for lm = lighterIDs(:)'
                lmMask = (cellGrid == lm);
                if any(lmMask, "all")
                    belowFalling = belowFalling | games.FallingSandUtils.fsdFallingMask(cellGrid, lmMask, lm, brushMask, gapTol);
                end
            end
            belowFallingShifted = [belowFalling(2:end, :); false(1, Nx)];
            cs = isLiq & ~liqFalling & isLighter & ~belowFallingShifted;
            cs(end, :) = false;
            idx = find(cs);
            if ~isempty(idx)
                displaced = cellGrid(idx + 1);
                cellGrid(idx + 1) = liqID;  cellGrid(idx) = displaced;
            end

            % Build set of drain material IDs for cascade
            drainSet = gasDrainIDs;

            [cellGrid, cellLife] = obj.flowLiquid(cellGrid, cellLife, liqID, ...
                drainSet, brushMask, randMat, gapTol, flowMode, ...
                hasFinger, mtrl, bx, by, bRad, Ny, Nx);
        end

        function [cellGrid, cellLife] = flowLiquid(obj, cellGrid, cellLife, liqID, ...
                drainIDs, brushMask, randMat, gapTol, flowMode, ...
                hasFinger, mtrl, bx, by, bRad, Ny, Nx)
            %flowLiquid  Shared laminar/turbulent flow pipeline for a liquid.
            %   drainIDs: materials that count as drain targets in cascade
            %   (lighter materials that the liquid can displace horizontally).

            if flowMode == "laminar"
                % === LAMINAR: cascade(1) + gravity ===
                for eqPass = 1:1
                    isLiq = (cellGrid == liqID);
                    falling = games.FallingSandUtils.fsdFallingMask(cellGrid, isLiq, liqID, brushMask, gapTol);
                    notFalling = isLiq & ~falling;
                    notFalling(end, :) = false;
                    if ~any(notFalling, "all"); break; end
                    belowGrid = [cellGrid(2:end, :); zeros(1, Nx, "uint8")];
                    isBelowEmpty = (belowGrid == 0);
                    isBelowDrain = isBelowEmpty;
                    for dd = 1:numel(drainIDs)
                        isBelowDrain = isBelowDrain | (belowGrid == drainIDs(dd));
                    end
                    distL = inf(Ny, Nx);  distR = inf(Ny, Nx);
                    for c = 2:Nx
                        hit = isBelowDrain(:, c-1);
                        distL(hit, c) = 0;
                        distL(~hit, c) = distL(~hit, c-1) + 1;
                    end
                    for c = Nx-1:-1:1
                        hit = isBelowDrain(:, c+1);
                        distR(hit, c) = 0;
                        distR(~hit, c) = distR(~hit, c+1) + 1;
                    end
                    goL = notFalling & (distL < distR);
                    goR = notFalling & (distR < distL);
                    tied = notFalling & (distL == distR) & isfinite(distL);
                    goL(tied) = randMat(tied) > 0.5;
                    goR(tied & ~goL) = true;
                    dMin = min(distL, distR);
                    canMove = false(Ny, Nx);
                    for r = 1:Ny-1
                        nfR = find(notFalling(r, :));
                        if isempty(nfR); continue; end
                        nDrains = sum(isBelowDrain(r, :));
                        if nDrains == 0; continue; end
                        nMove = min(nDrains, numel(nfR));
                        [~, sortIdx] = sort(dMin(r, nfR));
                        chosen = false(1, numel(nfR));
                        chosen(sortIdx(1:nMove)) = true;
                        canMove(r, nfR(chosen)) = true;
                    end
                    goL = goL & canMove;
                    goR = goR & canMove;
                    movableSet = [0, drainIDs(:)'];
                    for c = 2:Nx
                        movable = goL(:, c) & ismember(cellGrid(:, c-1), movableSet);
                        if any(movable)
                            ri = find(movable);
                            src = ri + (c-1) * Ny;  dst = ri + (c-2) * Ny;
                            dstMat = cellGrid(dst);  dstLf = cellLife(dst);
                            cellGrid(dst) = liqID;  cellGrid(src) = dstMat;
                            cellLife(dst) = cellLife(src);  cellLife(src) = dstLf;
                        end
                    end
                    for c = Nx-1:-1:1
                        movable = goR(:, c) & ismember(cellGrid(:, c+1), movableSet);
                        if any(movable)
                            ri = find(movable);
                            src = ri + (c-1) * Ny;  dst = ri + c * Ny;
                            dstMat = cellGrid(dst);  dstLf = cellLife(dst);
                            cellGrid(dst) = liqID;  cellGrid(src) = dstMat;
                            cellLife(dst) = cellLife(src);  cellLife(src) = dstLf;
                        end
                    end
                end

                % Gravity
                isLiq = (cellGrid == liqID);
                willFall = false(Ny, Nx);
                for r = Ny-1:-1:1
                    willFall(r, :) = isLiq(r, :) & ~brushMask(r, :) & ...
                        (cellGrid(r+1, :) == 0 | willFall(r+1, :));
                end
                idx = find(willFall);
                if ~isempty(idx)
                    fl = cellLife(idx);
                    cellGrid(idx + 1) = liqID;  cellGrid(idx) = 0;
                    cellLife(idx + 1) = fl;  cellLife(idx) = 0;
                end

            else
                % === TURBULENT: spray + cascade(2-4) + gravity + diagonal + 2nd emit + post-grav ===

                % Spray (skip for cascade pattern)
                if obj.SpawnPattern ~= "cascade"
                    isLiq = (cellGrid == liqID);
                    wfLiq = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, isLiq, liqID, brushMask, gapTol);
                    spray = isLiq & wfLiq & ~brushMask & (randMat < 0.15);
                    spray(end, :) = false;
                    if any(spray, "all")
                        blE = false(Ny, Nx);
                        blE(1:end-1, 2:end) = (cellGrid(2:end, 1:end-1) == 0);
                        brE = false(Ny, Nx);
                        brE(1:end-1, 1:end-1) = (cellGrid(2:end, 2:end) == 0);
                        sL = spray & blE;  sR = spray & brE;
                        bo = sL & sR;
                        pR = bo & (rand(Ny, Nx) > 0.5);
                        sL(pR) = false;
                        sR(bo & ~pR) = false;
                        sR(sL) = false;
                        idx = find(sL);
                        if ~isempty(idx)
                            fl = cellLife(idx);
                            cellGrid(idx + 1 - Ny) = liqID;  cellGrid(idx) = 0;
                            cellLife(idx + 1 - Ny) = fl;  cellLife(idx) = 0;
                        end
                        idx = find(sR);
                        if ~isempty(idx)
                            fl = cellLife(idx);
                            cellGrid(idx + 1 + Ny) = liqID;  cellGrid(idx) = 0;
                            cellLife(idx + 1 + Ny) = fl;  cellLife(idx) = 0;
                        end
                    end
                end

                % Cascade (2-4 passes)
                for eqPass = 1:randi([2, 4])
                    isLiq = (cellGrid == liqID);
                    falling = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, isLiq, liqID, brushMask, gapTol);
                    notFalling = isLiq & ~falling;
                    notFalling(end, :) = false;
                    if ~any(notFalling, "all"); break; end
                    belowGrid = [cellGrid(2:end, :); zeros(1, Nx, "uint8")];
                    isBelowEmpty = (belowGrid == 0);
                    isBelowDrain = isBelowEmpty;
                    for dd = 1:numel(drainIDs)
                        isBelowDrain = isBelowDrain | (belowGrid == drainIDs(dd));
                    end
                    distL = inf(Ny, Nx);  distR = inf(Ny, Nx);
                    for c = 2:Nx
                        hit = isBelowDrain(:, c-1);
                        distL(hit, c) = 0;
                        distL(~hit, c) = distL(~hit, c-1) + 1;
                    end
                    for c = Nx-1:-1:1
                        hit = isBelowDrain(:, c+1);
                        distR(hit, c) = 0;
                        distR(~hit, c) = distR(~hit, c+1) + 1;
                    end
                    goL = notFalling & (distL < distR);
                    goR = notFalling & (distR < distL);
                    tied = notFalling & (distL == distR) & isfinite(distL);
                    goL(tied) = randMat(tied) > 0.5;
                    goR(tied & ~goL) = true;
                    dMin = min(distL, distR);
                    canMove = false(Ny, Nx);
                    for r = 1:Ny-1
                        nfR = find(notFalling(r, :));
                        if isempty(nfR); continue; end
                        nDrains = sum(isBelowDrain(r, :));
                        if nDrains == 0; continue; end
                        nMove = min(nDrains, numel(nfR));
                        [~, sortIdx] = sort(dMin(r, nfR));
                        chosen = false(1, numel(nfR));
                        chosen(sortIdx(1:nMove)) = true;
                        canMove(r, nfR(chosen)) = true;
                    end
                    goL = goL & canMove;
                    goR = goR & canMove;
                    movableSet = [0, drainIDs(:)'];
                    for c = 2:Nx
                        movable = goL(:, c) & ismember(cellGrid(:, c-1), movableSet);
                        if any(movable)
                            ri = find(movable);
                            src = ri + (c-1) * Ny;  dst = ri + (c-2) * Ny;
                            dstMat = cellGrid(dst);  dstLf = cellLife(dst);
                            cellGrid(dst) = liqID;  cellGrid(src) = dstMat;
                            cellLife(dst) = cellLife(src);  cellLife(src) = dstLf;
                        end
                    end
                    for c = Nx-1:-1:1
                        movable = goR(:, c) & ismember(cellGrid(:, c+1), movableSet);
                        if any(movable)
                            ri = find(movable);
                            src = ri + (c-1) * Ny;  dst = ri + c * Ny;
                            dstMat = cellGrid(dst);  dstLf = cellLife(dst);
                            cellGrid(dst) = liqID;  cellGrid(src) = dstMat;
                            cellLife(dst) = cellLife(src);  cellLife(src) = dstLf;
                        end
                    end
                end

                % Gravity
                isLiq = (cellGrid == liqID);
                willFall = false(Ny, Nx);
                for r = Ny-1:-1:1
                    willFall(r, :) = isLiq(r, :) & ~brushMask(r, :) & ...
                        (cellGrid(r+1, :) == 0 | willFall(r+1, :));
                end
                idx = find(willFall);
                if ~isempty(idx)
                    fl = cellLife(idx);
                    cellGrid(idx + 1) = liqID;  cellGrid(idx) = 0;
                    cellLife(idx + 1) = fl;  cellLife(idx) = 0;
                end

                % Diagonal fall (non-falling, skip if on sand)
                isLiq = (cellGrid == liqID);
                wfLiq = games.FallingSandUtils.fsdFallingMaskTurbulent(cellGrid, isLiq, liqID, brushMask, gapTol);
                onSand = [cellGrid(2:end, :) == 1; false(1, Nx)];
                bbDiag = isLiq & ~wfLiq & ~onSand;
                bbDiag(end, :) = false;
                if any(bbDiag, "all")
                    blE = false(Ny, Nx);
                    blE(1:end-1, 2:end) = (cellGrid(2:end, 1:end-1) == 0);
                    brE = false(Ny, Nx);
                    brE(1:end-1, 1:end-1) = (cellGrid(2:end, 2:end) == 0);
                    cBL = bbDiag & blE;  cBR = bbDiag & brE;
                    bo = cBL & cBR;
                    pR = bo & (randMat > 0.5);
                    cBL(pR) = false;
                    cBR(bo & ~pR) = false;
                    cBR(cBL) = false;
                    idx = find(cBL);
                    if ~isempty(idx)
                        fl = cellLife(idx);
                        cellGrid(idx + 1 - Ny) = liqID;  cellGrid(idx) = 0;
                        cellLife(idx + 1 - Ny) = fl;  cellLife(idx) = 0;
                    end
                    idx = find(cBR);
                    if ~isempty(idx)
                        fl = cellLife(idx);
                        cellGrid(idx + 1 + Ny) = liqID;  cellGrid(idx) = 0;
                        cellLife(idx + 1 + Ny) = fl;  cellLife(idx) = 0;
                    end
                end

                % Second emission
                if hasFinger && mtrl == liqID
                    er = min(Ny, by + bRad) + 1;
                    if er <= Ny
                        ec1 = max(1, bx - bRad);  ec2 = min(Nx, bx + bRad);
                        eCols = ec1:ec2;
                        emptyNow = cellGrid(er, eCols) == 0;
                        eMask = obj.buildSecondEmitMask(eCols, numel(eCols));
                        fill2 = eMask & emptyNow;
                        if any(fill2)
                            cellGrid(er, eCols(fill2)) = liqID;
                        end
                    end
                end

                % Post-diagonal gravity
                isLiq = (cellGrid == liqID);
                willFall = false(Ny, Nx);
                for r = Ny-1:-1:1
                    willFall(r, :) = isLiq(r, :) & ~brushMask(r, :) & ...
                        (cellGrid(r+1, :) == 0 | willFall(r+1, :));
                end
                idx = find(willFall);
                if ~isempty(idx)
                    fl = cellLife(idx);
                    cellGrid(idx + 1) = liqID;  cellGrid(idx) = 0;
                    cellLife(idx + 1) = fl;  cellLife(idx) = 0;
                end
            end
        end

    end
end
