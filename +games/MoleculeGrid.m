classdef MoleculeGrid < GameBase
    %MoleculeGrid  Spring-mass rectangular lattice with finger interaction.
    %   Rectangular grid of nodes connected by springs. Finger repels or
    %   attracts nodes. Physics sub-modes control stiffness and damping.
    %   Node coloring and ambient breathing are togglable.
    %
    %   Standalone: games.MoleculeGrid().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Molecule Grid"
    end

    % =================================================================
    % TUNABLE PARAMETERS
    % =================================================================
    properties (Access = private)
        GridLevel       (1,1) double = 10
        GridSpacing     (1,1) double = 5
        SpringK         (1,1) double = 0.3
        AnchorK         (1,1) double = 0.08
        Retention       (1,1) double = 0.8620
        FingerRadius    (1,1) double = 28
        FingerForce     (1,1) double = 33
        NodeColorsOn    (1,1) logical = false
        BreathingOn     (1,1) logical = false
        SubMode         (1,1) string = "elastic"
        FingerMode      (1,1) string = "repel"
    end

    % =================================================================
    % NODE / BOND STATE
    % =================================================================
    properties (Access = private)
        NodeCount       (1,1) double = 0
        BondCount       (1,1) double = 0
        RestX           (:,1) double
        RestY           (:,1) double
        PosX            (:,1) double
        PosY            (:,1) double
        VelX            (:,1) double
        VelY            (:,1) double
        BondI           (:,1) double
        BondJ           (:,1) double
        BondRestLen     (:,1) double
        BondBroken      (:,1) logical
    end

    % =================================================================
    % STATS / ANIMATION
    % =================================================================
    properties (Access = private)
        PeakEnergy      (1,1) double = 0
        Phase           (1,1) double = 0
        GridStartTic    uint64
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BondGlowH
        BondLineH
        NodeGlowH
        NodeCoreH
        ModeTextH
    end

    % =================================================================
    % GRID SPACINGS (constant lookup table)
    % =================================================================
    properties (Constant, Access = private)
        Spacings = [40, 32, 24, 18, 14, 10, 8, 7, 6, 5, ...
                    4.5, 4, 3.5, 3, 2.5, 2.2, 2, 1.8, 1.5, 1.2]
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize state.
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

            % Reset state
            obj.GridLevel = 10;
            obj.SubMode = "elastic";
            obj.FingerMode = "repel";
            obj.NodeColorsOn = false;
            obj.BreathingOn = false;
            obj.PeakEnergy = 0;
            obj.Phase = 0;
            obj.GridStartTic = tic;

            % Build the lattice
            obj.buildGrid();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame spring-mass physics and rendering.
            numNodes = obj.NodeCount;
            numBonds = obj.BondCount;
            if numNodes == 0; return; end

            bI = obj.BondI;
            bJ = obj.BondJ;

            % --- Finger force (applied once before substeps) ---
            if ~any(isnan(pos))
                dxF = obj.PosX - pos(1);
                dyF = obj.PosY - pos(2);
                distF = sqrt(dxF.^2 + dyF.^2);
                inRange = distF < obj.FingerRadius & distF > 0;
                if any(inRange)
                    forceR = obj.FingerForce ...
                        * (1 - distF(inRange) / obj.FingerRadius).^2;
                    forceR = min(forceR, 1.25);
                    safeDist = max(distF(inRange), 1);
                    if obj.FingerMode == "attract"
                        obj.VelX(inRange) = obj.VelX(inRange) ...
                            - forceR .* dxF(inRange) ./ safeDist;
                        obj.VelY(inRange) = obj.VelY(inRange) ...
                            - forceR .* dyF(inRange) ./ safeDist;
                    else
                        obj.VelX(inRange) = obj.VelX(inRange) ...
                            + forceR .* dxF(inRange) ./ safeDist;
                        obj.VelY(inRange) = obj.VelY(inRange) ...
                            + forceR .* dyF(inRange) ./ safeDist;
                    end
                end
            end

            % --- Physics substeps (symplectic Euler, 4 substeps) ---
            baseNSub = 2;
            ds = obj.DtScale;
            nSub = max(1, round(baseNSub * ds));
            nSub = min(nSub, baseNSub * 4);  % safety cap
            subRetention = obj.Retention ^ (1 / nSub);
            for sub = 1:nSub %#ok<FXUP>
                % Spring forces (vectorized via accumarray)
                dxB = obj.PosX(bJ) - obj.PosX(bI);
                dyB = obj.PosY(bJ) - obj.PosY(bI);
                lenB = max(sqrt(dxB.^2 + dyB.^2), 0.01);
                stretch = lenB - obj.BondRestLen;
                fxB = (obj.SpringK / nSub) * stretch .* dxB ./ lenB;
                fyB = (obj.SpringK / nSub) * stretch .* dyB ./ lenB;

                % Accumulate forces per node
                fxAcc = accumarray(bI, fxB, [numNodes, 1]) ...
                      - accumarray(bJ, fxB, [numNodes, 1]);
                fyAcc = accumarray(bI, fyB, [numNodes, 1]) ...
                      - accumarray(bJ, fyB, [numNodes, 1]);

                % Anchor return
                fxAcc = fxAcc + (obj.AnchorK / nSub) ...
                    * (obj.RestX - obj.PosX);
                fyAcc = fyAcc + (obj.AnchorK / nSub) ...
                    * (obj.RestY - obj.PosY);

                % Integrate (symplectic Euler)
                obj.VelX = (obj.VelX + fxAcc) * subRetention;
                obj.VelY = (obj.VelY + fyAcc) * subRetention;
                obj.PosX = obj.PosX + obj.VelX / nSub;
                obj.PosY = obj.PosY + obj.VelY / nSub;
            end

            % --- Ambient breathing ---
            totalEnergy = sum(obj.VelX.^2 + obj.VelY.^2);
            obj.PeakEnergy = max(obj.PeakEnergy, totalEnergy);
            if obj.BreathingOn
                obj.Phase = obj.Phase + 0.0208;
                breathX = 0.5 * sin(obj.Phase + (1:numNodes)' * 0.1);
                breathY = 0.5 * cos(obj.Phase * 0.7 ...
                    + (1:numNodes)' * 0.13);
                displayX = obj.PosX + breathX;
                displayY = obj.PosY + breathY;
            else
                displayX = obj.PosX;
                displayY = obj.PosY;
            end

            % --- Energy scoring ---
            if totalEnergy > 5
                obj.addScore(floor(totalEnergy * 0.1));
                obj.incrementCombo();
            elseif totalEnergy < 0.5
                if obj.Combo > 0
                    obj.Combo = max(0, obj.Combo - 1);
                end
            end

            % --- Update bond rendering ---
            bx = NaN(3 * numBonds, 1);
            by = NaN(3 * numBonds, 1);
            bx(1:3:end) = displayX(bI);
            bx(2:3:end) = displayX(bJ);
            by(1:3:end) = displayY(bI);
            by(2:3:end) = displayY(bJ);

            if ~isempty(obj.BondLineH) && isvalid(obj.BondLineH)
                obj.BondLineH.XData = bx;
                obj.BondLineH.YData = by;
            end
            if ~isempty(obj.BondGlowH) && isvalid(obj.BondGlowH)
                obj.BondGlowH.XData = bx;
                obj.BondGlowH.YData = by;
            end

            % --- Update node rendering ---
            dispMag = sqrt((displayX - obj.RestX).^2 ...
                + (displayY - obj.RestY).^2);
            maxDisp = max(dispMag);
            dispNorm = min(dispMag / max(maxDisp, 10), 1);

            % Node coloring: uniform cyan or displacement-based
            if obj.NodeColorsOn
                nodeCol = zeros(numNodes, 3);
                lo = dispNorm <= 0.5;
                hi = ~lo;
                t1 = dispNorm(lo) * 2;
                nodeCol(lo, :) = (1 - t1) .* obj.ColorCyan ...
                    + t1 .* obj.ColorGold;
                t2 = (dispNorm(hi) - 0.5) * 2;
                nodeCol(hi, :) = (1 - t2) .* obj.ColorGold ...
                    + t2 .* obj.ColorRed;
            else
                nodeCol = repmat(obj.ColorCyan, numNodes, 1);
            end

            fs2 = obj.FontScale^2;
            coreSize = (18 + dispNorm * 12) * fs2;
            glowSize = (60 + dispNorm * 30) * fs2;

            if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH) ...
                    && numel(obj.NodeCoreH.XData) == numNodes
                obj.NodeCoreH.XData = displayX;
                obj.NodeCoreH.YData = displayY;
                obj.NodeCoreH.CData = nodeCol;
                obj.NodeCoreH.SizeData = coreSize;
            end
            if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH) ...
                    && numel(obj.NodeGlowH.XData) == numNodes
                obj.NodeGlowH.XData = displayX;
                obj.NodeGlowH.YData = displayY;
                obj.NodeGlowH.CData = nodeCol;
                obj.NodeGlowH.SizeData = glowSize;
            end

            % Displacement scoring
            totalDisp = sum(dispMag);
            if totalDisp > numNodes * 2
                obj.addScore(floor(totalDisp * 0.05 ...
                    * max(1, obj.Combo * 0.1)));
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all molecule grid graphics.
            obj.NodeCount = 0;
            obj.BondCount = 0;
            handles = {obj.BondGlowH, obj.BondLineH, ...
                obj.NodeGlowH, obj.NodeCoreH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.BondGlowH = [];
            obj.BondLineH = [];
            obj.NodeGlowH = [];
            obj.NodeCoreH = [];
            obj.ModeTextH = [];

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_moleculegrid");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles finger modes.
            modes = ["repel", "attract"];
            idx = find(modes == obj.FingerMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.FingerMode = modes(newIdx);
            obj.refreshHud();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle mode-specific keys.
            %   M = finger mode, N = physics sub-mode, B = node coloring,
            %   V = breathing, Up/Down = grid density, 0 = reset (in-game), R = restart.
            handled = true;
            switch key
                case "m"
                    if obj.FingerMode == "repel"
                        obj.FingerMode = "attract";
                    else
                        obj.FingerMode = "repel";
                    end
                    obj.refreshHud();

                case "n"
                    modes = ["elastic", "energetic", "damped"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();

                case "b"
                    obj.NodeColorsOn = ~obj.NodeColorsOn;
                    obj.refreshHud();

                case "v"
                    obj.BreathingOn = ~obj.BreathingOn;
                    obj.refreshHud();

                case {"uparrow", "downarrow"}
                    obj.changeGridLevel(key);

                case "0"
                    obj.NodeCount = 0;
                    obj.BondCount = 0;
                    obj.PeakEnergy = 0;
                    obj.Phase = 0;
                    obj.Score = 0;
                    obj.Combo = 0;
                    obj.MaxCombo = 0;
                    obj.GridStartTic = tic;
                    obj.buildGrid();

                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return molecule-grid-specific results.
            r.Title = "MOLECULE GRID";
            r.Lines = {
                sprintf("Peak Energy: %.1f", obj.PeakEnergy)
            };
        end

    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function buildGrid(obj)
            %buildGrid  Create rectangular lattice with spring bonds.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            % Sync spacing and radius from current grid level
            obj.GridSpacing = obj.Spacings(obj.GridLevel);
            obj.FingerRadius = obj.GridSpacing * 2.0;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);
            sp = obj.GridSpacing;

            % Generate rectangular grid with 1 buffer layer beyond edges
            innerCols = round(areaW / sp) + 1;
            innerRows = round(areaH / sp) + 1;
            actualSpX = areaW / max(1, innerCols - 1);
            actualSpY = areaH / max(1, innerRows - 1);

            xPos = linspace(dx(1) - actualSpX, dx(2) + actualSpX, ...
                innerCols + 2);
            yPos = linspace(dy(1) - actualSpY, dy(2) + actualSpY, ...
                innerRows + 2);
            [cxGrid, cyGrid] = meshgrid(xPos, yPos);
            restX = cxGrid(:);
            restY = cyGrid(:);
            numNodes = numel(restX);

            % Build structural bonds from grid topology (O(N), no N×N matrix)
            nR = numel(yPos);
            nC = numel(xPos);
            idx = reshape(1:numNodes, nR, nC);

            bI = zeros(0, 1);
            bJ = zeros(0, 1);

            % Right neighbors
            if nC > 1
                iR = idx(:, 1:end-1);
                jR = idx(:, 2:end);
                bI = iR(:);
                bJ = jR(:);
            end

            % Down neighbors
            if nR > 1
                iD = idx(1:end-1, :);
                jD = idx(2:end, :);
                bI = [bI; iD(:)];
                bJ = [bJ; jD(:)];
            end

            bondI = bI;
            bondJ = bJ;
            numBonds = numel(bondI);
            bondRestLen = sqrt((restX(bondI) - restX(bondJ)).^2 + ...
                (restY(bondI) - restY(bondJ)).^2);

            % Store state
            obj.NodeCount = numNodes;
            obj.BondCount = numBonds;
            obj.RestX = restX;
            obj.RestY = restY;
            obj.PosX = restX;
            obj.PosY = restY;
            obj.VelX = zeros(numNodes, 1);
            obj.VelY = zeros(numNodes, 1);
            obj.BondI = bondI;
            obj.BondJ = bondJ;
            obj.BondRestLen = bondRestLen;
            obj.BondBroken = false(numBonds, 1);

            % Scoring
            obj.PeakEnergy = 0;
            obj.Phase = 0;
            obj.GridStartTic = tic;

            % Build initial NaN-separated bond line data
            bx = NaN(3 * numBonds, 1);
            by = NaN(3 * numBonds, 1);
            bx(1:3:end) = restX(bondI);
            bx(2:3:end) = restX(bondJ);
            by(1:3:end) = restY(bondI);
            by(2:3:end) = restY(bondJ);

            % Graphics — reuse existing handles on grid level change
            nodeCol = repmat(obj.ColorCyan, numNodes, 1);
            if ~isempty(obj.BondGlowH) && isvalid(obj.BondGlowH)
                set(obj.BondGlowH, "XData", bx, "YData", by);
            else
                obj.BondGlowH = line(ax, bx, by, ...
                    "Color", [obj.ColorCyan, 0.06], "LineWidth", 3, ...
                    "Tag", "GT_moleculegrid");
            end
            if ~isempty(obj.BondLineH) && isvalid(obj.BondLineH)
                set(obj.BondLineH, "XData", bx, "YData", by);
            else
                obj.BondLineH = line(ax, bx, by, ...
                    "Color", [obj.ColorCyan, 0.25], "LineWidth", 0.5, ...
                    "Tag", "GT_moleculegrid");
            end
            if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH)
                set(obj.NodeGlowH, "XData", restX, "YData", restY, ...
                    "SizeData", 60 * ones(numNodes, 1), ...
                    "CData", nodeCol);
            else
                obj.NodeGlowH = scatter(ax, restX, restY, ...
                    60 * ones(numNodes, 1), nodeCol, "filled", ...
                    "MarkerFaceAlpha", 0.12, "Tag", "GT_moleculegrid");
            end
            if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH)
                set(obj.NodeCoreH, "XData", restX, "YData", restY, ...
                    "SizeData", 18 * ones(numNodes, 1), ...
                    "CData", nodeCol);
            else
                obj.NodeCoreH = scatter(ax, restX, restY, ...
                    18 * ones(numNodes, 1), nodeCol, "filled", ...
                    "MarkerFaceAlpha", 0.85, "Tag", "GT_moleculegrid");
            end
            if isempty(obj.ModeTextH) || ~isvalid(obj.ModeTextH)
                obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, "", ...
                    "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                    "VerticalAlignment", "bottom", ...
                    "Tag", "GT_moleculegrid");
            end

            obj.applySubMode();
            obj.refreshHud();
        end

        function applySubMode(obj)
            %applySubMode  Set physics parameters for current sub-mode.
            switch obj.SubMode
                case "damped"
                    obj.SpringK = 0.2;
                    obj.AnchorK = 0.06;
                    obj.Retention = 0.7491;
                    obj.FingerForce = 21;
                case "elastic"
                    obj.SpringK = 0.3;
                    obj.AnchorK = 0.08;
                    obj.Retention = 0.8620;
                    obj.FingerForce = 33;
                case "energetic"
                    obj.SpringK = 0.5;
                    obj.AnchorK = 0.10;
                    obj.Retention = 0.9571;
                    obj.FingerForce = 50;
            end
            obj.refreshHud();
        end

        function refreshHud(obj)
            %refreshHud  Refresh molecule grid HUD text handle.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

        function s = buildHudString(obj)
            %buildHudString  Assemble HUD string from current state.
            if obj.NodeColorsOn
                colStr = "ON";
            else
                colStr = "OFF";
            end
            if obj.BreathingOn
                brStr = "ON";
            else
                brStr = "OFF";
            end
            s = upper(obj.FingerMode) + " [M]  |  " ...
                + upper(obj.SubMode) + " [N]  |  Node Color " ...
                + colStr + " [B]  |  Breathe " + brStr ...
                + " [V]  |  Grid " + obj.GridLevel + "/20 [" ...
                + char(8593) + char(8595) + "]";
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Change grid discretization (arrow keys).
            radiusRatio = 2.0;
            oldLevel = obj.GridLevel;
            if key == "uparrow"
                obj.GridLevel = min(numel(obj.Spacings), oldLevel + 1);
            else
                obj.GridLevel = max(1, oldLevel - 1);
            end
            if obj.GridLevel == oldLevel; return; end
            obj.GridSpacing = obj.Spacings(obj.GridLevel);
            obj.FingerRadius = obj.GridSpacing * radiusRatio;
            obj.NodeCount = 0;
            obj.BondCount = 0;
            obj.buildGrid();
        end
    end
end
