classdef Ecosystem < GameBase
    %Ecosystem  Cellular automaton ecosystem simulation (living petri dish).
    %   5 organism types: plant (1), herbivore (2), predator (3), decomposer
    %   (4), toxin (5). Plants photosynthesize and spread; herbivores eat
    %   plants, reproduce, die to decomposers; predators hunt herbivores
    %   with directional scanning; decomposers decay and boost plant growth;
    %   toxin kills adjacent life and spreads.
    %
    %   Controls:
    %     M     — cycle sub-mode (balanced/bloom/plague/extinction)
    %     N     — cycle spawn type (plant/herbivore/predator/decomposer/toxin)
    %     Up/Dn — adjust brush size
    %     L/R   — adjust sim speed (1-6)
    %     0     — reset grid (re-seed current sub-mode)
    %
    %   Standalone: games.Ecosystem().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Ecosystem"
    end

    % =================================================================
    % SIMULATION STATE
    % =================================================================
    properties (Access = private)
        GridW           (1,1) double = 160      % grid width (columns)
        GridH           (1,1) double = 120      % grid height (rows)
        Grid            (:,:) uint8             % 0=empty,1=plant,2=herbivore,3=predator,4=decomposer,5=toxin
        Energy          (:,:) uint8             % energy/lifetime per cell (0-255)
        SubMode         (1,1) string = "balanced"  % balanced/bloom/plague/extinction
        BrushSize       (1,1) double = 3        % brush radius in cells (1-8)
        SpawnType       (1,1) uint8 = 1         % current spawn type
        SpawnNames      (1,5) string = ["plant", "herbivore", "predator", "decomposer", "toxin"]
        PeakPop         (1,1) double = 0        % peak total population
        FrameCount      (1,1) double = 0
        SimAccum        (1,1) double = 0      % FPS accumulator for fixed-rate physics
        SimRate         (1,1) double = 30     % target sim rate in Hz (10:10:60)
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
            %onInit  Create ecosystem grid, image overlay, and HUD.
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
            obj.Energy = zeros(Ny, Nx, "uint8");
            obj.SpawnType = 1;
            obj.BrushSize = 3;
            obj.FrameCount = 0;
            obj.PeakPop = 0;

            % Seed initial organisms based on sub-mode
            obj.seedGrid();

            blackFrame = zeros(Ny, Nx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", blackFrame, "Interpolation", "bilinear", ...
                "Tag", "GT_ecosystem");
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");

            obj.HudTextH = text(ax, dxRange(1) + 5, dyRange(2) - 5, "", ...
                "Color", [0.3, 1, 0.4, 0.8], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_ecosystem");
            obj.updateHud();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame ecosystem cellular automaton update + render.
            grid = obj.Grid;
            if isempty(grid); return; end

            % Tunable sim rate: accumulate real dt, skip entire frame if
            % not enough time has passed.  Speed 1-6 (SimRate 10-60 Hz).
            realDt = obj.DtScale * GameBase.RefDt;
            obj.SimAccum = obj.SimAccum + realDt;
            stepPeriod = 1.0 / obj.SimRate;
            if obj.SimAccum < stepPeriod; return; end
            obj.SimAccum = obj.SimAccum - stepPeriod;

            Ny = obj.GridH;
            Nx = obj.GridW;
            obj.FrameCount = obj.FrameCount + 1;
            energy = obj.Energy;

            % Sub-mode rate multipliers
            switch obj.SubMode
                case "balanced"
                    plantGrowProb = 0.03;  toxinSpreadProb = 0.02;
                    predReproThresh = uint8(180);  toxinDecay = uint8(8);
                case "bloom"
                    plantGrowProb = 0.09;  toxinSpreadProb = 0.05;
                    predReproThresh = uint8(180);  toxinDecay = uint8(5);
                case "plague"
                    plantGrowProb = 0.03;  toxinSpreadProb = 0.15;
                    predReproThresh = uint8(180);  toxinDecay = uint8(2);
                case "extinction"
                    plantGrowProb = 0.03;  toxinSpreadProb = 0.05;
                    predReproThresh = uint8(120);  toxinDecay = uint8(5);
                otherwise
                    plantGrowProb = 0.03;  toxinSpreadProb = 0.05;
                    predReproThresh = uint8(180);  toxinDecay = uint8(5);
            end

            % === FINGER INPUT ===
            hasFinger = ~isempty(pos) && all(~isnan(pos));
            if hasFinger
                dxRange = obj.DisplayRange.X;
                dyRange = obj.DisplayRange.Y;
                gx = round(1 + (pos(1) - dxRange(1)) / diff(dxRange) * (Nx - 1));
                gy = round(1 + (pos(2) - dyRange(1)) / diff(dyRange) * (Ny - 1));
                gx = max(1, min(Nx, gx));
                gy = max(1, min(Ny, gy));
                br = obj.BrushSize;
                mtrl = obj.SpawnType;
                r1 = max(1, gy - br); r2 = min(Ny, gy + br);
                c1 = max(1, gx - br); c2 = min(Nx, gx + br);
                brushRegion = grid(r1:r2, c1:c2);
                emptyMask = (brushRegion == 0);
                brushRegion(emptyMask) = mtrl;
                grid(r1:r2, c1:c2) = brushRegion;
                % Set initial energy for spawned organisms
                eR = energy(r1:r2, c1:c2);
                switch mtrl
                    case 1; eR(emptyMask) = 200;   % plant
                    case 2; eR(emptyMask) = 100;   % herbivore
                    case 3; eR(emptyMask) = 120;   % predator
                    case 4; eR(emptyMask) = 150;   % decomposer
                    case 5; eR(emptyMask) = 200;   % toxin
                end
                energy(r1:r2, c1:c2) = eR;
            end

            % === CELLULAR AUTOMATON UPDATE ===

            randMat = rand(Ny, Nx);
            newGrid = grid;
            newEnergy = energy;

            % --- TOXIN: kill + spread ---
            isToxin = (grid == 5);
            if any(isToxin, "all")
                toxIdx = find(isToxin);
                eTox = energy(toxIdx);
                deadV = eTox <= toxinDecay;
                eTox(~deadV) = eTox(~deadV) - toxinDecay;
                eTox(deadV) = 0;
                newEnergy(toxIdx) = eTox;
                newGrid(toxIdx(deadV)) = 0;

                % Kill adjacent living organisms (types 1-4)
                liveToxin = isToxin;
                liveToxin(toxIdx(deadV)) = false;
                padToxKill = false(Ny + 2, Nx + 2);
                padToxKill(2:end-1, 2:end-1) = liveToxin;
                padKill = false(Ny + 2, Nx + 2);  % padded accumulator for killed victims
                for dd = 1:4
                    switch dd
                        case 1; dr = 1; dc = 0;
                        case 2; dr = -1; dc = 0;
                        case 3; dr = 0; dc = 1;
                        case 4; dr = 0; dc = -1;
                    end
                    toxNeighbor = padToxKill((2:Ny+1) + dr, (2:Nx+1) + dc);
                    isLiving = (newGrid >= 1) & (newGrid <= 4);
                    killHere = toxNeighbor & isLiving;
                    newGrid(killHere) = 0;
                    newEnergy(killHere) = 0;
                    % Mark the toxin cell responsible: toxin at (r+dr,c+dc) killed (r,c)
                    padKill((2:Ny+1) + dr, (2:Nx+1) + dc) = ...
                        padKill((2:Ny+1) + dr, (2:Nx+1) + dc) | killHere;
                end
                killedSomething = padKill(2:end-1, 2:end-1) & liveToxin;

                % Energy cost for killing — toxin cells that killed lose 10
                killCostIdx = find(killedSomething);
                if ~isempty(killCostIdx)
                    eCost = newEnergy(killCostIdx);
                    died = eCost <= 10;
                    eCost(~died) = eCost(~died) - 10;
                    eCost(died) = 0;
                    newEnergy(killCostIdx) = eCost;
                    newGrid(killCostIdx(died)) = 0;
                end

                % Spread to adjacent empty cells
                isToxinNow = (newGrid == 5);
                spreadMask = (newGrid == 0) & (randMat < toxinSpreadProb);
                padTox = false(Ny + 2, Nx + 2);
                padTox(2:end-1, 2:end-1) = isToxinNow;
                hasToxNeighbor = padTox(1:Ny, 2:Nx+1) | padTox(3:Ny+2, 2:Nx+1) | ...
                                padTox(2:Ny+1, 1:Nx) | padTox(2:Ny+1, 3:Nx+2);
                spread = spreadMask & hasToxNeighbor;
                if any(spread, "all")
                    newGrid(spread) = 5;
                    newEnergy(spread) = 200;
                end
            end

            % --- PLANTS: photosynthesis + growth ---
            isPlant = (newGrid == 1);
            if any(isPlant, "all")
                pIdx = find(isPlant);
                eP = newEnergy(pIdx);
                eP(eP < 255) = eP(eP < 255) + 1;
                newEnergy(pIdx) = eP;

                % Growth: spread into adjacent empty cells
                padGridNow = zeros(Ny + 2, Nx + 2, "uint8");
                padGridNow(2:end-1, 2:end-1) = newGrid;
                adjE_plant = uint8(padGridNow(1:Ny, 2:Nx+1) == 0) + ...
                             uint8(padGridNow(3:Ny+2, 2:Nx+1) == 0) + ...
                             uint8(padGridNow(2:Ny+1, 1:Nx) == 0) + ...
                             uint8(padGridNow(2:Ny+1, 3:Nx+2) == 0);
                canGrow = isPlant & (adjE_plant > 0) & (randMat < plantGrowProb);
                growIdx = find(canGrow);
                if ~isempty(growIdx)
                    for k = 1:numel(growIdx)
                        idx = growIdx(k);
                        [rr, cc] = ind2sub([Ny, Nx], idx);
                        dirs = [];
                        if rr > 1 && newGrid(rr-1, cc) == 0; dirs(end+1) = 1; end %#ok<AGROW>
                        if rr < Ny && newGrid(rr+1, cc) == 0; dirs(end+1) = 2; end %#ok<AGROW>
                        if cc > 1 && newGrid(rr, cc-1) == 0; dirs(end+1) = 3; end %#ok<AGROW>
                        if cc < Nx && newGrid(rr, cc+1) == 0; dirs(end+1) = 4; end %#ok<AGROW>
                        if ~isempty(dirs)
                            d = dirs(randi(numel(dirs)));
                            switch d
                                case 1; newGrid(rr-1, cc) = 1; newEnergy(rr-1, cc) = 200;
                                case 2; newGrid(rr+1, cc) = 1; newEnergy(rr+1, cc) = 200;
                                case 3; newGrid(rr, cc-1) = 1; newEnergy(rr, cc-1) = 200;
                                case 4; newGrid(rr, cc+1) = 1; newEnergy(rr, cc+1) = 200;
                            end
                        end
                    end
                end
            end

            % --- DECOMPOSERS: decay, boost nearby plant growth ---
            isDecomp = (newGrid == 4);
            if any(isDecomp, "all")
                dIdx = find(isDecomp);
                eD = newEnergy(dIdx);
                dead = eD <= 3;
                eD(~dead) = eD(~dead) - 3;
                eD(dead) = 0;
                newEnergy(dIdx) = eD;
                deadIdx = dIdx(dead);
                newGrid(deadIdx) = 0;
                % Boost: spawn plants in adjacent empty cells with 15% prob
                for k = 1:numel(deadIdx)
                    [rr, cc] = ind2sub([Ny, Nx], deadIdx(k));
                    if rr > 1 && newGrid(rr-1, cc) == 0 && rand < 0.15
                        newGrid(rr-1, cc) = 1; newEnergy(rr-1, cc) = 200;
                    end
                    if rr < Ny && newGrid(rr+1, cc) == 0 && rand < 0.15
                        newGrid(rr+1, cc) = 1; newEnergy(rr+1, cc) = 200;
                    end
                    if cc > 1 && newGrid(rr, cc-1) == 0 && rand < 0.15
                        newGrid(rr, cc-1) = 1; newEnergy(rr, cc-1) = 200;
                    end
                    if cc < Nx && newGrid(rr, cc+1) == 0 && rand < 0.15
                        newGrid(rr, cc+1) = 1; newEnergy(rr, cc+1) = 200;
                    end
                end
            end

            % --- HERBIVORES: move, eat plants, reproduce, die ---
            isHerb = (newGrid == 2);
            if any(isHerb, "all")
                hIdx = find(isHerb);
                hIdx = hIdx(randperm(numel(hIdx)));
                for k = 1:numel(hIdx)
                    idx = hIdx(k);
                    if newGrid(idx) ~= 2; continue; end
                    [rr, cc] = ind2sub([Ny, Nx], idx);
                    eH = newEnergy(idx);

                    % Metabolism
                    if eH <= 1
                        newGrid(idx) = 4; newEnergy(idx) = 150;
                        continue;
                    end
                    eH = eH - 1;

                    % Check neighbors
                    neighbors = zeros(4, 3);
                    nCount = 0;
                    if rr > 1;  nCount = nCount + 1; neighbors(nCount, :) = [rr-1, cc, newGrid(rr-1, cc)]; end
                    if rr < Ny; nCount = nCount + 1; neighbors(nCount, :) = [rr+1, cc, newGrid(rr+1, cc)]; end
                    if cc > 1;  nCount = nCount + 1; neighbors(nCount, :) = [rr, cc-1, newGrid(rr, cc-1)]; end
                    if cc < Nx; nCount = nCount + 1; neighbors(nCount, :) = [rr, cc+1, newGrid(rr, cc+1)]; end
                    neighbors = neighbors(1:nCount, :);

                    % Try to eat adjacent plant
                    plantN = find(neighbors(:, 3) == 1, 1);
                    if ~isempty(plantN)
                        pr = neighbors(plantN, 1); pc = neighbors(plantN, 2);
                        newGrid(pr, pc) = 0; newEnergy(pr, pc) = 0;
                        eH = min(255, eH + 50);
                    end

                    % Reproduce if energy > 150
                    if eH > 150
                        emptyN = find(neighbors(:, 3) == 0);
                        if ~isempty(emptyN)
                            ri = emptyN(randi(numel(emptyN)));
                            nr = neighbors(ri, 1); nc = neighbors(ri, 2);
                            newGrid(nr, nc) = 2; newEnergy(nr, nc) = 60;
                            eH = eH - 60;
                            neighbors(ri, 3) = 2;
                        end
                    end

                    % Move to random empty neighbor
                    emptyN = find(neighbors(:, 3) == 0);
                    if ~isempty(emptyN)
                        mi = emptyN(randi(numel(emptyN)));
                        mr = neighbors(mi, 1); mc = neighbors(mi, 2);
                        newGrid(mr, mc) = 2; newEnergy(mr, mc) = eH;
                        newGrid(rr, cc) = 0; newEnergy(rr, cc) = 0;
                    else
                        newEnergy(idx) = eH;
                    end
                end
            end

            % --- PREDATORS: hunt herbivores, move, reproduce, die ---
            isPred = (newGrid == 3);
            if any(isPred, "all")
                pPredIdx = find(isPred);
                pPredIdx = pPredIdx(randperm(numel(pPredIdx)));
                for k = 1:numel(pPredIdx)
                    idx = pPredIdx(k);
                    if newGrid(idx) ~= 3; continue; end
                    [rr, cc] = ind2sub([Ny, Nx], idx);
                    eP = newEnergy(idx);

                    % Fast metabolism
                    if eP <= 2
                        newGrid(idx) = 4; newEnergy(idx) = 150;
                        continue;
                    end
                    eP = eP - 2;

                    % Check neighbors
                    neighbors = zeros(4, 3);
                    nCount = 0;
                    if rr > 1;  nCount = nCount + 1; neighbors(nCount, :) = [rr-1, cc, newGrid(rr-1, cc)]; end
                    if rr < Ny; nCount = nCount + 1; neighbors(nCount, :) = [rr+1, cc, newGrid(rr+1, cc)]; end
                    if cc > 1;  nCount = nCount + 1; neighbors(nCount, :) = [rr, cc-1, newGrid(rr, cc-1)]; end
                    if cc < Nx; nCount = nCount + 1; neighbors(nCount, :) = [rr, cc+1, newGrid(rr, cc+1)]; end
                    neighbors = neighbors(1:nCount, :);

                    % Try to eat adjacent herbivore
                    herbN = find(neighbors(:, 3) == 2, 1);
                    ate = false;
                    if ~isempty(herbN)
                        hr = neighbors(herbN, 1); hc = neighbors(herbN, 2);
                        newGrid(hr, hc) = 0; newEnergy(hr, hc) = 0;
                        eP = min(255, eP + 80);
                        ate = true;
                        % 5% chance: toxin spawns in adjacent empty cell
                        if rand < 0.05
                            emptyN = find(neighbors(:, 3) == 0);
                            if ~isempty(emptyN)
                                ti = emptyN(randi(numel(emptyN)));
                                tr = neighbors(ti, 1); tc = neighbors(ti, 2);
                                newGrid(tr, tc) = 5; newEnergy(tr, tc) = 200;
                            end
                        end
                        neighbors(herbN, 3) = 0;
                    end

                    % If didn't eat, move toward nearest herbivore
                    if ~ate
                        bestDir = 0;
                        bestCount = 0;
                        scanR = 5;
                        for dd = 1:4
                            switch dd
                                case 1; dr = -1; dc = 0;
                                case 2; dr = 1;  dc = 0;
                                case 3; dr = 0;  dc = -1;
                                case 4; dr = 0;  dc = 1;
                            end
                            cnt = 0;
                            for s = 1:scanR
                                sr = rr + dr * s; sc = cc + dc * s;
                                if sr >= 1 && sr <= Ny && sc >= 1 && sc <= Nx
                                    if newGrid(sr, sc) == 2; cnt = cnt + 1; end
                                end
                            end
                            if cnt > bestCount
                                bestCount = cnt; bestDir = dd;
                            end
                        end
                        moved = false;
                        if bestDir > 0
                            switch bestDir
                                case 1; mr = rr - 1; mc = cc;
                                case 2; mr = rr + 1; mc = cc;
                                case 3; mr = rr;     mc = cc - 1;
                                case 4; mr = rr;     mc = cc + 1;
                            end
                            if mr >= 1 && mr <= Ny && mc >= 1 && mc <= Nx && newGrid(mr, mc) == 0
                                newGrid(mr, mc) = 3; newEnergy(mr, mc) = eP;
                                newGrid(rr, cc) = 0; newEnergy(rr, cc) = 0;
                                moved = true;
                            end
                        end
                        if ~moved
                            emptyN = find(neighbors(:, 3) == 0);
                            if ~isempty(emptyN)
                                mi = emptyN(randi(numel(emptyN)));
                                mr = neighbors(mi, 1); mc = neighbors(mi, 2);
                                newGrid(mr, mc) = 3; newEnergy(mr, mc) = eP;
                                newGrid(rr, cc) = 0; newEnergy(rr, cc) = 0;
                                moved = true;
                            end
                        end
                        if ~moved
                            newEnergy(idx) = eP;
                        end
                    else
                        newEnergy(idx) = eP;
                    end

                    % Reproduce if well-fed
                    if newEnergy(idx) > 0 && newGrid(idx) == 3 && eP > predReproThresh
                        [rrr, ccc] = ind2sub([Ny, Nx], idx);
                        emptyAdj = [];
                        if rrr > 1 && newGrid(rrr-1, ccc) == 0; emptyAdj(end+1) = sub2ind([Ny, Nx], rrr-1, ccc); end %#ok<AGROW>
                        if rrr < Ny && newGrid(rrr+1, ccc) == 0; emptyAdj(end+1) = sub2ind([Ny, Nx], rrr+1, ccc); end %#ok<AGROW>
                        if ccc > 1 && newGrid(rrr, ccc-1) == 0; emptyAdj(end+1) = sub2ind([Ny, Nx], rrr, ccc-1); end %#ok<AGROW>
                        if ccc < Nx && newGrid(rrr, ccc+1) == 0; emptyAdj(end+1) = sub2ind([Ny, Nx], rrr, ccc+1); end %#ok<AGROW>
                        if ~isempty(emptyAdj)
                            offIdx = emptyAdj(randi(numel(emptyAdj)));
                            newGrid(offIdx) = 3; newEnergy(offIdx) = 60;
                            newEnergy(idx) = eP - 60;
                        end
                    end
                end
            end

            obj.Grid = newGrid;
            obj.Energy = newEnergy;

            % Track peak population
            totalPop = nnz(newGrid > 0 & newGrid < 5);
            if totalPop > obj.PeakPop
                obj.PeakPop = totalPop;
            end

            % === RENDER ===
            obj.renderGrid();
            obj.Score = nnz(obj.Grid > 0 & obj.Grid < 5);
        end

        function onCleanup(obj)
            %onCleanup  Delete ecosystem graphics and reset state.
            handles = {obj.ImageH, obj.HudTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.ImageH = [];
            obj.HudTextH = [];
            obj.Grid = [];
            obj.Energy = [];
            obj.FrameCount = 0;
            obj.PeakPop = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_ecosystem");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["balanced", "bloom", "plague", "extinction"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.updateHud();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle ecosystem keys.
            handled = true;
            switch key
                case "m"
                    modes = ["balanced", "bloom", "plague", "extinction"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.updateHud();
                case "n"
                    obj.SpawnType = uint8(mod(double(obj.SpawnType), 5) + 1);
                    obj.updateHud();
                case "uparrow"
                    obj.BrushSize = min(8, obj.BrushSize + 1);
                    obj.updateHud();
                case "downarrow"
                    obj.BrushSize = max(1, obj.BrushSize - 1);
                    obj.updateHud();
                case "rightarrow"
                    obj.SimRate = min(60, obj.SimRate + 10);
                    obj.updateHud();
                case "leftarrow"
                    obj.SimRate = max(10, obj.SimRate - 10);
                    obj.updateHud();
                case "0"
                    obj.Grid = zeros(obj.GridH, obj.GridW, "uint8");
                    obj.Energy = zeros(obj.GridH, obj.GridW, "uint8");
                    obj.PeakPop = 0;
                    obj.seedGrid();
                    obj.updateHud();
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return ecosystem results.
            r.Title = "ECOSYSTEM";
            elapsed = toc(obj.StartTic);
            g = obj.Grid;
            nPlant = 0; nHerb = 0; nPred = 0; nDecomp = 0;
            if ~isempty(g)
                nPlant = nnz(g == 1); nHerb = nnz(g == 2);
                nPred = nnz(g == 3);  nDecomp = nnz(g == 4);
            end
            r.Lines = {
                sprintf("Plant:%d  Herb:%d  Pred:%d  Decomp:%d  |  Peak:%d  |  %s  |  %.0fs", ...
                    nPlant, nHerb, nPred, nDecomp, obj.PeakPop, obj.SubMode, elapsed)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function renderGrid(obj)
            %renderGrid  Render ecosystem grid to image.
            if isempty(obj.ImageH) || ~isvalid(obj.ImageH); return; end
            grid = obj.Grid;
            energy = obj.Energy;
            Ny = obj.GridH;
            Nx = obj.GridW;
            fc = obj.FrameCount;

            % Dark background (petri dish blue-black)
            R = uint8(zeros(Ny, Nx) + 5);
            G = uint8(zeros(Ny, Nx) + 8);
            B = uint8(zeros(Ny, Nx) + 15);

            eNorm = double(energy) / 255.0;

            % Plants: dark green to bright green
            m1 = (grid == 1);
            if any(m1, "all")
                t = eNorm(m1);
                R(m1) = uint8(10 + t * 40);
                G(m1) = uint8(80 + t * 175);
                B(m1) = uint8(15 + t * 30);
            end

            % Herbivores: yellow-orange
            m2 = (grid == 2);
            if any(m2, "all")
                t = eNorm(m2);
                R(m2) = uint8(200 + t * 55);
                G(m2) = uint8(150 + t * 80);
                B(m2) = uint8(20 + t * 20);
            end

            % Predators: red-crimson
            m3 = (grid == 3);
            if any(m3, "all")
                t = eNorm(m3);
                R(m3) = uint8(160 + t * 95);
                G(m3) = uint8(20 + t * 50);
                B(m3) = uint8(20 + t * 30);
            end

            % Decomposers: brown
            m4 = (grid == 4);
            if any(m4, "all")
                t = eNorm(m4);
                R(m4) = uint8(40 + t * 100);
                G(m4) = uint8(25 + t * 50);
                B(m4) = uint8(10 + t * 15);
            end

            % Toxin: purple, pulsing
            m5 = (grid == 5);
            if any(m5, "all")
                pulse = 0.7 + 0.3 * sin(double(fc) * 0.3);
                t = eNorm(m5) * pulse;
                R(m5) = uint8(120 + t * 135);
                G(m5) = uint8(10 + t * 30);
                B(m5) = uint8(140 + t * 115);
            end

            obj.ImageH.CData = cat(3, R, G, B);
        end

        function updateHud(obj)
            %updateHud  Refresh the ecosystem HUD text.
            if ~isempty(obj.HudTextH) && isvalid(obj.HudTextH)
                spawnName = obj.SpawnNames(obj.SpawnType);
                obj.HudTextH.String = upper(obj.SubMode) + ...
                    " [M]  |  Spawn: " + upper(spawnName) + ...
                    " [N]  |  Brush " + obj.BrushSize + ...
                    " [" + char(8593) + char(8595) + "]  |  " + ...
                    "Speed " + round(obj.SimRate / 10) + ...
                    " [" + char(8592) + char(8594) + "]";
                switch obj.SpawnType
                    case 1; obj.HudTextH.Color = [0.3, 1.0, 0.4, 0.8];
                    case 2; obj.HudTextH.Color = [1.0, 0.85, 0.2, 0.8];
                    case 3; obj.HudTextH.Color = [1.0, 0.3, 0.2, 0.8];
                    case 4; obj.HudTextH.Color = [0.6, 0.35, 0.15, 0.8];
                    case 5; obj.HudTextH.Color = [0.7, 0.2, 0.9, 0.8];
                end
            end
        end

        function seedGrid(obj)
            %seedGrid  Place initial organisms based on sub-mode.
            Ny = obj.GridH;
            Nx = obj.GridW;
            grid = zeros(Ny, Nx, "uint8");
            energy = zeros(Ny, Nx, "uint8");

            nPlants = round(Ny * Nx * 0.05);
            nHerbs = round(Ny * Nx * 0.01);
            nPreds = round(Ny * Nx * 0.003);
            nToxin = 0;

            switch obj.SubMode
                case "bloom"
                    nPlants = round(Ny * Nx * 0.10);
                case "plague"
                    nToxin = round(Ny * Nx * 0.005);
                case "extinction"
                    nPreds = round(Ny * Nx * 0.008);
            end

            allIdx = randperm(Ny * Nx);
            curPos = 1;

            % Place plants
            for k = 1:nPlants
                grid(allIdx(curPos)) = 1;
                energy(allIdx(curPos)) = uint8(randi([150, 250]));
                curPos = curPos + 1;
            end
            % Place herbivores
            for k = 1:nHerbs
                grid(allIdx(curPos)) = 2;
                energy(allIdx(curPos)) = uint8(randi([80, 120]));
                curPos = curPos + 1;
            end
            % Place predators
            for k = 1:nPreds
                grid(allIdx(curPos)) = 3;
                energy(allIdx(curPos)) = uint8(randi([100, 150]));
                curPos = curPos + 1;
            end

            % Plague: also seed some toxin
            if obj.SubMode == "plague"
                for k = 1:nToxin
                    grid(allIdx(curPos)) = 5;
                    energy(allIdx(curPos)) = 200;
                    curPos = curPos + 1;
                end
            end

            obj.Grid = grid;
            obj.Energy = energy;
        end
    end
end
