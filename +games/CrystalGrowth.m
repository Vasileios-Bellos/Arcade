classdef CrystalGrowth < GameBase
    %CrystalGrowth  Cellular automaton crystal growth simulation.
    %   Finger places seed crystals that grow via directional probability.
    %   4 crystal types with age-based coloring, 4 sub-modes: dendrite,
    %   snowflake (6-fold symmetry), coral, competition (multi-species).
    %
    %   Controls:
    %     M     — cycle sub-mode (dendrite/snowflake/coral/competition)
    %     N     — cycle seed type (blue/red/green/gold)
    %     Up/Dn — adjust growth probability
    %     L/R   — adjust brush size
    %     0     — reset grid
    %
    %   Standalone: games.CrystalGrowth().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Crystal Growth"
    end

    % =================================================================
    % SIMULATION STATE
    % =================================================================
    properties (Access = private)
        Grid            (:,:) uint8             % 0=empty, 1-4=crystal types
        Age             (:,:) uint16            % growth age per cell (for color gradient)
        Dir             (:,:) uint8             % growth direction index (1-8) per cell
        GridW           (1,1) double = 160      % grid width (columns)
        GridH           (1,1) double = 120      % grid height (rows)
        MaxAge          (1,1) uint16 = 500      % max age for color normalization
        GrowthProb      (1,1) double = 0.08     % base growth probability per frame
        BranchProb      (1,1) double = 0.15     % probability of branching
        SubMode         (1,1) string = "dendrite"  % dendrite/snowflake/coral/competition
        SeedType        (1,1) uint8 = 1         % current seed type (1-4, cycle with N)
        BrushSize       (1,1) double = 2        % seed brush radius in cells
        SeedNames       (1,4) string = ["blue", "red", "green", "gold"]
        TotalGrown      (1,1) double = 0        % total cells grown (for results)
        FrameCount      (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ImageH                                  % image object handle
        HudTextH                                % text -- HUD label
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create crystal growth grid, image overlay, and HUD.
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

            dxRange = displayRange.X;
            dyRange = displayRange.Y;
            Ny = obj.GridH;
            Nx = obj.GridW;

            obj.Grid = zeros(Ny, Nx, "uint8");
            obj.Age = zeros(Ny, Nx, "uint16");
            obj.Dir = zeros(Ny, Nx, "uint8");
            obj.SeedType = 1;
            obj.BrushSize = 2;
            obj.FrameCount = 0;
            obj.TotalGrown = 0;

            bgFrame = zeros(Ny, Nx, 3, "uint8");
            bgFrame(:,:,1) = 8;   % dark purple-black
            bgFrame(:,:,2) = 4;
            bgFrame(:,:,3) = 16;
            obj.ImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", bgFrame, "Interpolation", "bilinear", ...
                "Tag", "GT_crystalgrowth");
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");

            obj.HudTextH = text(ax, dxRange(1) + 5, dyRange(2) - 5, "", ...
                "Color", [0.4, 0.8, 1, 0.8], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_crystalgrowth");

            % Apply sub-mode (may place initial seeds)
            obj.applySubMode();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame crystal growth update + render.
            grid = obj.Grid;
            if isempty(grid); return; end
            Ny = obj.GridH;
            Nx = obj.GridW;
            obj.FrameCount = obj.FrameCount + 1;
            age = obj.Age;
            dirField = obj.Dir;

            % === FINGER INPUT: place seeds ===
            hasFinger = ~isempty(pos) && all(~isnan(pos));
            if hasFinger
                dxRange = obj.DisplayRange.X;
                dyRange = obj.DisplayRange.Y;
                gx = round(1 + (pos(1) - dxRange(1)) / diff(dxRange) * (Nx - 1));
                gy = round(1 + (pos(2) - dyRange(1)) / diff(dyRange) * (Ny - 1));
                gx = max(1, min(Nx, gx));
                gy = max(1, min(Ny, gy));
                br = obj.BrushSize;
                seedT = obj.SeedType;
                r1 = max(1, gy - br);  r2 = min(Ny, gy + br);
                c1 = max(1, gx - br);  c2 = min(Nx, gx + br);
                brushRegion = grid(r1:r2, c1:c2);
                emptyMask = (brushRegion == 0);
                brushRegion(emptyMask) = seedT;
                grid(r1:r2, c1:c2) = brushRegion;
                ageRegion = age(r1:r2, c1:c2);
                ageRegion(emptyMask) = 1;
                age(r1:r2, c1:c2) = ageRegion;
                dirRegion = dirField(r1:r2, c1:c2);
                nNew = nnz(emptyMask);
                if nNew > 0
                    dirRegion(emptyMask) = uint8(randi(8, nNew, 1));
                end
                dirField(r1:r2, c1:c2) = dirRegion;
            end

            % === CRYSTAL GROWTH UPDATE ===
            isXtal = (grid > 0);
            if ~any(isXtal, "all")
                obj.Grid = grid;
                obj.Age = age;
                obj.Dir = dirField;
                obj.renderGrid();
                return;
            end

            % Increment age of existing crystals (capped at MaxAge)
            age(isXtal) = min(age(isXtal) + 1, obj.MaxAge);

            growProb = obj.GrowthProb;
            branchProb = obj.BranchProb;
            subMode = obj.SubMode;

            % 8 neighbor offsets: 1=N, 2=NE, 3=E, 4=SE, 5=S, 6=SW, 7=W, 8=NW
            dR = int32([-1, -1, 0, +1, +1, +1,  0, -1]);
            dC = int32([ 0, +1,+1, +1,  0, -1, -1, -1]);

            % Directional bias weights based on sub-mode
            switch subMode
                case "dendrite"
                    dirBias = 4.0;   sideBias = 0.3;
                case "snowflake"
                    dirBias = 3.0;   sideBias = 0.5;
                case "coral"
                    dirBias = 1.2;   sideBias = 0.9;
                case "competition"
                    dirBias = 2.5;   sideBias = 0.5;
                otherwise
                    dirBias = 3.0;   sideBias = 0.4;
            end

            % Precompute weight lookup: angleDiff (0-4) -> weight
            wLUT = [dirBias, dirBias * 0.6, sideBias, sideBias * 0.3, 0.05];

            % Pad grid for safe neighbor access
            padGrid = zeros(Ny + 2, Nx + 2, "uint8");
            padGrid(2:end-1, 2:end-1) = grid;
            padDir = zeros(Ny + 2, Nx + 2, "uint8");
            padDir(2:end-1, 2:end-1) = dirField;

            newGrid = grid;
            newAge = age;
            newDir = dirField;
            randMat = rand(Ny, Nx);
            branchRand = rand(Ny, Nx);

            % Process each neighbor direction vectorized
            for d = 1:8
                nr = -dR(d);
                nc = -dC(d);
                neighborType = padGrid((2:Ny+1) + nr, (2:Nx+1) + nc);
                neighborDir  = padDir((2:Ny+1) + nr, (2:Nx+1) + nc);

                canGrow = (newGrid == 0) & (neighborType > 0);
                if ~any(canGrow, "all"); continue; end

                % Vectorized directional weight computation
                pDir = double(neighborDir);
                angleDiff = min(abs(d - pDir), 8 - abs(d - pDir));
                angleDiff(pDir == 0) = 2;
                angleDiff = min(angleDiff, 4);
                weight = zeros(Ny, Nx);
                for ai = 0:4
                    aMask = canGrow & (angleDiff == ai);
                    weight(aMask) = wLUT(ai + 1);
                end

                growMask = canGrow & (randMat < growProb .* weight);
                if ~any(growMask, "all"); continue; end

                % Competition: cannot overwrite existing cells of different type
                if subMode == "competition"
                    conflict = growMask & (newGrid > 0);
                    growMask(conflict) = false;
                end

                newGrid(growMask) = neighborType(growMask);
                newAge(growMask) = 1;
                newDir(growMask) = uint8(d);

                % Branching: deviate direction for some cells
                isBranch = growMask & (branchRand < branchProb);
                if any(isBranch, "all")
                    branchIdx = find(isBranch);
                    nB = numel(branchIdx);
                    branchOffset = randi([-3, 3], nB, 1);
                    branchOffset(branchOffset == 0) = 2;
                    newDirs = mod(d - 1 + branchOffset, 8) + 1;
                    newDir(branchIdx) = uint8(newDirs);
                end
            end

            % === SNOWFLAKE MODE: enforce 6-fold symmetry ===
            if subMode == "snowflake"
                [newGrid, newAge] = CrystalGrowth.enforceSymmetry( ...
                    newGrid, newAge, grid, Ny, Nx);
            end

            obj.TotalGrown = obj.TotalGrown + nnz((newGrid > 0) & (grid == 0));
            obj.Grid = newGrid;
            obj.Age = newAge;
            obj.Dir = newDir;

            % === RENDER ===
            obj.renderGrid();
            obj.Score = nnz(newGrid > 0);
        end

        function onCleanup(obj)
            %onCleanup  Delete crystal growth graphics and reset state.
            handles = {obj.ImageH, obj.HudTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.ImageH = [];
            obj.HudTextH = [];
            obj.Grid = [];
            obj.Age = [];
            obj.Dir = [];
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_crystalgrowth");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle crystal growth keys.
            handled = true;
            switch key
                case "m"
                    modes = ["dendrite", "snowflake", "coral", "competition"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();
                case "n"
                    obj.SeedType = uint8(mod(double(obj.SeedType), 4) + 1);
                    obj.updateHud();
                case "uparrow"
                    obj.GrowthProb = min(0.5, obj.GrowthProb + 0.02);
                    obj.updateHud();
                case "downarrow"
                    obj.GrowthProb = max(0.01, obj.GrowthProb - 0.02);
                    obj.updateHud();
                case "rightarrow"
                    obj.BrushSize = min(8, obj.BrushSize + 1);
                    obj.updateHud();
                case "leftarrow"
                    obj.BrushSize = max(1, obj.BrushSize - 1);
                    obj.updateHud();
                case "0"
                    obj.applySubMode();
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return crystal growth results.
            r.Title = "CRYSTAL GROWTH";
            elapsed = toc(obj.StartTic);
            totalCells = 0;
            if ~isempty(obj.Grid)
                totalCells = nnz(obj.Grid > 0);
            end
            r.Lines = {
                sprintf("Cells: %d  |  Grown: %d  |  Mode: %s  |  Time: %.0fs", ...
                    totalCells, obj.TotalGrown, obj.SubMode, elapsed)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function renderGrid(obj)
            %renderGrid  Render crystal growth grid to image.
            if isempty(obj.ImageH) || ~isvalid(obj.ImageH); return; end
            grid = obj.Grid;
            age = obj.Age;
            Ny = obj.GridH;
            Nx = obj.GridW;
            maxA = double(obj.MaxAge);

            % Background: dark purple-black
            R = uint8(zeros(Ny, Nx) + 8);
            G = uint8(zeros(Ny, Nx) + 4);
            B = uint8(zeros(Ny, Nx) + 16);

            ageNorm = min(double(age) / maxA, 1.0);

            % Type 1: blue/cyan
            m1 = (grid == 1);
            if any(m1, "all")
                t = ageNorm(m1);
                R(m1) = uint8(40 + (1 - t) .* 100);
                G(m1) = uint8(180 + (1 - t) .* 75);
                B(m1) = uint8(255 - t .* 40);
            end

            % Type 2: red/magenta
            m2 = (grid == 2);
            if any(m2, "all")
                t = ageNorm(m2);
                R(m2) = uint8(255 - t .* 40);
                G(m2) = uint8(60 + (1 - t) .* 120);
                B(m2) = uint8(180 + (1 - t) .* 75);
            end

            % Type 3: green/lime
            m3 = (grid == 3);
            if any(m3, "all")
                t = ageNorm(m3);
                R(m3) = uint8(40 + (1 - t) .* 80);
                G(m3) = uint8(255 - t .* 60);
                B(m3) = uint8(60 + (1 - t) .* 80);
            end

            % Type 4: gold/yellow
            m4 = (grid == 4);
            if any(m4, "all")
                t = ageNorm(m4);
                R(m4) = uint8(255 - t .* 30);
                G(m4) = uint8(220 - t .* 80);
                B(m4) = uint8(40 + (1 - t) .* 60);
            end

            % Glow effect: freshly grown cells (age < 10) get extra brightness
            fresh = (grid > 0) & (age < 10);
            if any(fresh, "all")
                glow = (10 - double(age(fresh))) * 8;
                R(fresh) = uint8(min(255, double(R(fresh)) + glow));
                G(fresh) = uint8(min(255, double(G(fresh)) + glow));
                B(fresh) = uint8(min(255, double(B(fresh)) + glow));
            end

            % Sparkle: random bright pixels on crystal edges every 3 frames
            if mod(obj.FrameCount, 3) == 0
                isXtal = (grid > 0);
                padX = false(Ny + 2, Nx + 2);
                padX(2:end-1, 2:end-1) = isXtal;
                hasEmpty = isXtal & ~( ...
                    padX(1:Ny, 2:Nx+1) & padX(3:Ny+2, 2:Nx+1) & ...
                    padX(2:Ny+1, 1:Nx) & padX(2:Ny+1, 3:Nx+2));
                sparkle = hasEmpty & (rand(Ny, Nx) < 0.03);
                if any(sparkle, "all")
                    R(sparkle) = 255;
                    G(sparkle) = 255;
                    B(sparkle) = 255;
                end
            end

            obj.ImageH.CData = cat(3, R, G, B);
        end

        function updateHud(obj)
            %updateHud  Refresh the crystal growth HUD text.
            if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                seedName = obj.SeedNames(obj.SeedType);
                obj.HudTextH.String = upper(obj.SubMode) + ...
                    " [M]  |  Seed: " + upper(seedName) + ...
                    " [N]  |  Growth " + sprintf("%.0f%%", obj.GrowthProb * 100) + ...
                    " [" + char(8593) + char(8595) + "]" + ...
                    "  |  Brush " + obj.BrushSize + ...
                    " [" + char(8592) + char(8594) + "]";
                switch obj.SeedType
                    case 1; obj.HudTextH.Color = [0.4, 0.8, 1.0, 0.8];
                    case 2; obj.HudTextH.Color = [1.0, 0.3, 0.6, 0.8];
                    case 3; obj.HudTextH.Color = [0.3, 1.0, 0.4, 0.8];
                    case 4; obj.HudTextH.Color = [1.0, 0.85, 0.2, 0.8];
                end
            end
        end

        function applySubMode(obj)
            %applySubMode  Apply sub-mode parameters and reset grid.
            Ny = obj.GridH;
            Nx = obj.GridW;
            obj.Grid = zeros(Ny, Nx, "uint8");
            obj.Age = zeros(Ny, Nx, "uint16");
            obj.Dir = zeros(Ny, Nx, "uint8");
            obj.TotalGrown = 0;

            switch obj.SubMode
                case "dendrite"
                    obj.GrowthProb = 0.08;
                    obj.BranchProb = 0.15;
                case "snowflake"
                    obj.GrowthProb = 0.06;
                    obj.BranchProb = 0.12;
                    % Place initial seed at center
                    cy = round(Ny / 2);
                    cx = round(Nx / 2);
                    obj.Grid(cy, cx) = 1;
                    obj.Age(cy, cx) = 1;
                    obj.Dir(cy, cx) = 1;
                case "coral"
                    obj.GrowthProb = 0.12;
                    obj.BranchProb = 0.25;
                case "competition"
                    obj.GrowthProb = 0.10;
                    obj.BranchProb = 0.18;
                    % Place 4 seeds at quadrant centers
                    qr = round([Ny * 0.3, Ny * 0.3, Ny * 0.7, Ny * 0.7]);
                    qc = round([Nx * 0.3, Nx * 0.7, Nx * 0.3, Nx * 0.7]);
                    for k = 1:4
                        obj.Grid(qr(k), qc(k)) = uint8(k);
                        obj.Age(qr(k), qc(k)) = 1;
                        obj.Dir(qr(k), qc(k)) = uint8(randi(8));
                    end
            end

            obj.updateHud();
        end
    end

    % =================================================================
    % STATIC METHODS
    % =================================================================
    methods (Static, Access = private)

        function [symGrid, symAge] = enforceSymmetry(grid, age, origGrid, Ny, Nx)
            %enforceSymmetry  Enforce 6-fold symmetry on crystal grid and age.
            symGrid = grid;
            symAge = age;
            cy = Ny / 2;
            cx = Nx / 2;

            % Find newly grown crystal cells (present now but not before)
            newCells = (grid > 0) & (origGrid == 0);
            [rows, cols] = find(newCells);
            if isempty(rows); return; end

            yr = double(rows) - cy;
            xr = double(cols) - cx;

            % 6-fold rotation: 60, 120, 180, 240, 300 degrees
            angles = (1:5) * pi / 3;

            for a = 1:5
                cosA = cos(angles(a));
                sinA = sin(angles(a));
                ryr = yr * cosA - xr * sinA;
                rxr = yr * sinA + xr * cosA;
                newR = round(ryr + cy);
                newC = round(rxr + cx);
                valid = (newR >= 1) & (newR <= Ny) & (newC >= 1) & (newC <= Nx);
                vIdx = find(valid);
                for ki = 1:numel(vIdx)
                    kk = vIdx(ki);
                    rr = newR(kk);
                    cc = newC(kk);
                    if symGrid(rr, cc) == 0
                        symGrid(rr, cc) = grid(rows(kk), cols(kk));
                        symAge(rr, cc) = age(rows(kk), cols(kk));
                    end
                end
            end
        end
    end
end
