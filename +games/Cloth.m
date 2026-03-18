classdef Cloth < GameBase
    %Cloth  Verlet spring-mass cloth simulation with finger interaction.
    %   Grid of nodes connected by structural + shear springs. Finger pushes
    %   cloth in-plane (XY) and into-screen (Z depth). Sub-modes: curtain
    %   (top pinned, gravity), flag (left pinned, wind), drum (perimeter
    %   pinned). Quad or tri mesh rendering with Z-depth coloring.
    %
    %   Standalone: games.Cloth().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Cloth"
    end

    % =================================================================
    % TUNABLE PARAMETERS
    % =================================================================
    properties (Access = private)
        Gravity         (1,1) double = 0.08
        Sc              (1,1) double = 1    % display scale (1.0 at ~180px)
        Damping         (1,1) double = 0.995
        SubSteps        (1,1) double = 8
        ConstraintPasses (1,1) double = 3
        ConstraintFactor (1,1) double = 0.12
        GridLevel       (1,1) double = 5   % 1-10 resolution levels
        SubMode         (1,1) string = "curtain"
        MeshType        (1,1) string = "quad"  % "quad" or "tri"
        ShowEdges       (1,1) logical = true
        Transparent     (1,1) logical = false
    end

    % =================================================================
    % NODE / SPRING STATE
    % =================================================================
    properties (Access = private)
        PosX            (:,1) double
        PosY            (:,1) double
        PosZ            (:,1) double   % depth (into/out of screen)
        PrevX           (:,1) double
        PrevY           (:,1) double
        PrevZ           (:,1) double
        Pinned          (:,1) logical
        SpringI         (:,1) uint32
        SpringJ         (:,1) uint32
        RestLen         (:,1) double
        RestPosX        (:,1) double   % initial rest positions per mode
        RestPosY        (:,1) double
        GridW           (1,1) double = 25
        GridH           (1,1) double = 25
    end

    % =================================================================
    % STATS / ANIMATION
    % =================================================================
    properties (Access = private)
        FrameCount      (1,1) double = 0
        SimStartTic     uint64
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BgImageH
        MeshPatchH
        PinScatterH
        PinGlowH
        ModeTextH
    end

    % =================================================================
    % GRID SIZES (constant lookup table)
    % =================================================================
    properties (Constant, Access = private)
        GridSizes = [8, 12, 16, 20, 25, 30, 36, 42, 50, 60]
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create cloth grid with structural + shear springs.
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

            obj.buildCloth();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame Verlet cloth physics + rendering.
            nodeCount = numel(obj.PosX);
            if nodeCount == 0; return; end

            obj.FrameCount = obj.FrameCount + 1;
            gw = obj.GridW;
            gh = obj.GridH;
            dampVal = obj.Damping;
            nSub = obj.SubSteps;
            bI = double(obj.SpringI);
            bJ = double(obj.SpringJ);
            rLen = obj.RestLen;
            pinMask = obj.Pinned;

            gravVal = obj.Gravity;

            px = obj.PosX;
            py = obj.PosY;
            pz = obj.PosZ;
            prevX = obj.PrevX;
            prevY = obj.PrevY;
            prevZ = obj.PrevZ;

            restX = obj.RestPosX;
            restY = obj.RestPosY;
            dxR = obj.DisplayRange.X;
            dyR = obj.DisplayRange.Y;

            % Wind force for flag sub-mode
            windX = 0;
            isFlag = obj.SubMode == "flag";
            isCurtain = obj.SubMode == "curtain";
            if isFlag
                windX = gravVal ...
                    + 0.008 * obj.Sc * sin(obj.FrameCount * 0.05) ...
                    + 0.004 * obj.Sc * sin(obj.FrameCount * 0.13);
                gravVal = 0;  % no droop — wind is the only force
            end

            % Precompute per-column/row distance limits
            maxS = 1.03;
            hSpacing = (max(restX) - min(restX)) / max(gw - 1, 1);
            vSpacing = (max(restY) - min(restY)) / max(gh - 1, 1);
            if isFlag
                pinXval = min(restX(pinMask));
                pinYval = min(restY);
                colMaxX = pinXval + ((1:gw)' - 1) * hSpacing * maxS;
                rowMaxY = pinYval + ((1:gh)' - 1) * vSpacing * maxS;
            elseif isCurtain
                pinYval = min(restY(pinMask));
                rowMaxY = pinYval + ((1:gh)' - 1) * vSpacing * maxS;
            end

            fingerRadius = min(diff(dxR), diff(dyR)) * 0.2;
            nPasses = obj.ConstraintPasses;

            % Verlet integration with substeps (3D: X,Y in-plane + Z depth)
            for sub = 1:nSub
                velX = (px - prevX) * dampVal;
                velY = (py - prevY) * dampVal;
                velZ = (pz - prevZ) * dampVal;
                prevX = px; prevY = py; prevZ = pz;

                py = py + velY + gravVal / nSub;
                px = px + velX + windX / nSub;
                pz = pz + velZ;  % Z spring-back only (no gravity)

                % Finger interaction: push cloth INTO screen (Z axis)
                if ~any(isnan(pos))
                    dxF = px - pos(1);
                    dyF = py - pos(2);
                    distF = sqrt(dxF.^2 + dyF.^2);
                    inRange = distF < fingerRadius & distF > 0 & ~pinMask;
                    if any(inRange)
                        % Z push: closer to finger center = stronger push
                        falloff = (1 - distF(inRange) / fingerRadius).^2 / nSub;
                        pz(inRange) = pz(inRange) + 1.5 * falloff;
                        % XY push: gentle for drum skin, moderate otherwise
                        if obj.SubMode == "drum"
                            xyStr = 0.3;
                        else
                            xyStr = 0.8;
                        end
                        pushXY = xyStr * falloff;
                        safeDist = max(distF(inRange), 0.5);
                        px(inRange) = px(inRange) + pushXY .* dxF(inRange) ./ safeDist;
                        py(inRange) = py(inRange) + pushXY .* dyF(inRange) ./ safeDist;
                    end
                end

                % Spring constraint projection in 3D (Jacobi)
                cFactor = obj.ConstraintFactor;
                for cp = 1:nPasses
                    dxS = px(bJ) - px(bI);
                    dyS = py(bJ) - py(bI);
                    dzS = pz(bJ) - pz(bI);
                    lenS = max(sqrt(dxS.^2 + dyS.^2 + dzS.^2), 0.001);
                    errS = (lenS - rLen) ./ lenS * cFactor;
                    corrX = dxS .* errS;
                    corrY = dyS .* errS;
                    corrZ = dzS .* errS;
                    corrAccX = accumarray(bI, corrX, [nodeCount, 1]) ...
                             - accumarray(bJ, corrX, [nodeCount, 1]);
                    corrAccY = accumarray(bI, corrY, [nodeCount, 1]) ...
                             - accumarray(bJ, corrY, [nodeCount, 1]);
                    corrAccZ = accumarray(bI, corrZ, [nodeCount, 1]) ...
                             - accumarray(bJ, corrZ, [nodeCount, 1]);
                    px = px + corrAccX;
                    py = py + corrAccY;
                    pz = pz + corrAccZ;
                end

                % Enforce pinning
                if any(pinMask)
                    px(pinMask) = restX(pinMask);
                    py(pinMask) = restY(pinMask);
                    pz(pinMask) = 0;
                end

                % Per-column/row distance constraint
                if isFlag
                    for col = 2:gw
                        nIdx = (0:gh-1)' * gw + col;
                        cMask = px(nIdx) > colMaxX(col) & ~pinMask(nIdx);
                        cIdx = nIdx(cMask);
                        px(cIdx) = colMaxX(col);
                        prevX(cIdx) = colMaxX(col);
                    end
                    for row = 2:gh
                        nIdx = (row - 1) * gw + (1:gw)';
                        rMask = py(nIdx) > rowMaxY(row) & ~pinMask(nIdx);
                        rIdx = nIdx(rMask);
                        py(rIdx) = rowMaxY(row);
                        prevY(rIdx) = rowMaxY(row);
                    end
                elseif isCurtain
                    for row = 2:gh
                        nIdx = (row - 1) * gw + (1:gw)';
                        rMask = py(nIdx) > rowMaxY(row) & ~pinMask(nIdx);
                        rIdx = nIdx(rMask);
                        py(rIdx) = rowMaxY(row);
                        prevY(rIdx) = rowMaxY(row);
                    end
                end

                % Clamp to display bounds
                px = max(dxR(1), min(dxR(2), px));
                py = max(dyR(1), min(dyR(2), py));
            end

            obj.PosX = px;
            obj.PosY = py;
            obj.PosZ = pz;
            obj.PrevX = prevX;
            obj.PrevY = prevY;
            obj.PrevZ = prevZ;

            % Per-vertex coloring: Z-depth drives hue (cyan=flat, gold=pushed,
            % red=deep push). Darken based on Z for depth cue.
            maxZ = max(abs(pz));
            zNorm = min(abs(pz) / max(maxZ, 2), 1);

            vertCol = zeros(nodeCount, 3);
            lo = zNorm <= 0.5;
            hi = ~lo;
            t1 = zNorm(lo) * 2;
            vertCol(lo, :) = (1 - t1) .* obj.ColorCyan + t1 .* obj.ColorGold;
            t2 = (zNorm(hi) - 0.5) * 2;
            vertCol(hi, :) = (1 - t2) .* obj.ColorGold + t2 .* obj.ColorRed;

            shade = 1 - 0.4 * zNorm;
            vertCol = vertCol .* shade;

            if ~isempty(obj.MeshPatchH) && isvalid(obj.MeshPatchH)
                obj.MeshPatchH.Vertices = [px, py];
                obj.MeshPatchH.FaceVertexCData = vertCol;
            end

            pinIdx = find(pinMask);
            if ~isempty(obj.PinGlowH) && isvalid(obj.PinGlowH)
                if ~isempty(pinIdx)
                    obj.PinGlowH.XData = px(pinIdx);
                    obj.PinGlowH.YData = py(pinIdx);
                else
                    obj.PinGlowH.XData = NaN;
                    obj.PinGlowH.YData = NaN;
                end
            end
            if ~isempty(obj.PinScatterH) && isvalid(obj.PinScatterH)
                if ~isempty(pinIdx)
                    obj.PinScatterH.XData = px(pinIdx);
                    obj.PinScatterH.YData = py(pinIdx);
                else
                    obj.PinScatterH.XData = NaN;
                    obj.PinScatterH.YData = NaN;
                end
            end

            % Scoring: Z-depth energy (combo capped, decays when idle)
            totalDisp = sum(abs(pz)) ...
                + sum(sqrt((px - restX).^2 + (py - restY).^2));
            if totalDisp > nodeCount * 3.0
                comboMult = max(1, obj.Combo * 0.1);
                obj.addScore(round(min(totalDisp * 0.01, 50) * comboMult));
                if mod(obj.FrameCount, 15) == 0
                    obj.Combo = min(obj.Combo + 1, 50);
                    obj.MaxCombo = max(obj.MaxCombo, obj.Combo);
                end
            elseif totalDisp < nodeCount * 0.5
                if mod(obj.FrameCount, 30) == 0
                    obj.Combo = max(0, obj.Combo - 1);
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all cloth graphics and reset state.
            handles = {obj.MeshPatchH, obj.PinScatterH, obj.PinGlowH, ...
                obj.BgImageH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.MeshPatchH = [];
            obj.PinScatterH = [];
            obj.PinGlowH = [];
            obj.BgImageH = [];
            obj.ModeTextH = [];
            obj.PosX = [];
            obj.PosY = [];
            obj.PosZ = [];
            obj.PrevX = [];
            obj.PrevY = [];
            obj.PrevZ = [];
            obj.RestPosX = [];
            obj.RestPosY = [];
            obj.Pinned = [];
            obj.SpringI = [];
            obj.SpringJ = [];
            obj.RestLen = [];
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_cloth");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle cloth-specific keys.
            handled = true;
            switch key
                case "m"
                    % Cycle sub-mode: curtain -> flag -> drum
                    modes = ["curtain", "flag", "drum"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();
                case "n"
                    % Toggle tri/quad mesh — requires full rebuild
                    if obj.MeshType == "tri"
                        obj.MeshType = "quad";
                    else
                        obj.MeshType = "tri";
                    end
                    obj.rebuildCloth();
                case "v"
                    % Toggle edge visibility
                    obj.ShowEdges = ~obj.ShowEdges;
                    if ~isempty(obj.MeshPatchH) && isvalid(obj.MeshPatchH)
                        if obj.ShowEdges
                            obj.MeshPatchH.EdgeColor = obj.ColorCyan;
                            obj.MeshPatchH.EdgeAlpha = 0.15;
                        else
                            obj.MeshPatchH.EdgeColor = "none";
                        end
                    end
                    obj.updateHud();
                case "b"
                    % Toggle transparency
                    obj.Transparent = ~obj.Transparent;
                    if ~isempty(obj.MeshPatchH) && isvalid(obj.MeshPatchH)
                        if obj.Transparent
                            obj.MeshPatchH.FaceAlpha = 0.7;
                        else
                            obj.MeshPatchH.FaceAlpha = 1.0;
                        end
                    end
                    obj.updateHud();
                case {"uparrow", "downarrow"}
                    obj.changeGridLevel(key);
                case "0"
                    % Reset cloth to rest position
                    obj.applySubMode();
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return cloth-specific results.
            r.Title = "CLOTH";
            elapsed = toc(obj.SimStartTic);
            r.Lines = {
                sprintf("Mode: %s  |  Time: %.0fs", obj.SubMode, elapsed)
            };
        end

    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function buildCloth(obj)
            %buildCloth  Create cloth grid, springs, and graphics.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % Grid sizes per level (1-10). The level sets the number of
            % nodes along the SHORTER axis; the longer axis scales
            % proportionally to the display aspect ratio.
            lvl = max(1, min(10, obj.GridLevel));
            areaW = diff(dx);
            areaH = diff(dy);
            obj.Sc = min(areaW, areaH) / 180;
            obj.Gravity = 0.08 * obj.Sc;
            baseN = obj.GridSizes(lvl);
            if areaW >= areaH
                obj.GridH = baseN;
                obj.GridW = max(baseN, round(baseN * areaW / areaH));
            else
                obj.GridW = baseN;
                obj.GridH = max(baseN, round(baseN * areaH / areaW));
            end
            gw = obj.GridW;
            gh = obj.GridH;
            nodeCount = gw * gh;

            obj.Pinned = false(nodeCount, 1);
            obj.SimStartTic = tic;
            obj.FrameCount = 0;

            % Apply sub-mode — sets positions and pinning
            obj.applySubMode();

            % Build spring connectivity from grid topology
            sI = zeros(0, 1, "uint32");
            sJ = zeros(0, 1, "uint32");
            for row = 1:gh
                for col = 1:gw
                    idx = (row - 1) * gw + col;
                    if col < gw
                        sI(end + 1, 1) = uint32(idx); %#ok<AGROW>
                        sJ(end + 1, 1) = uint32(idx + 1); %#ok<AGROW>
                    end
                    if row < gh
                        sI(end + 1, 1) = uint32(idx); %#ok<AGROW>
                        sJ(end + 1, 1) = uint32(idx + gw); %#ok<AGROW>
                    end
                    if row < gh && col < gw
                        sI(end + 1, 1) = uint32(idx); %#ok<AGROW>
                        sJ(end + 1, 1) = uint32(idx + gw + 1); %#ok<AGROW>
                    end
                    if row < gh && col > 1
                        sI(end + 1, 1) = uint32(idx); %#ok<AGROW>
                        sJ(end + 1, 1) = uint32(idx + gw - 1); %#ok<AGROW>
                    end
                end
            end
            obj.SpringI = sI;
            obj.SpringJ = sJ;

            % Rest lengths from actual initial positions
            dxS = obj.PosX(sJ) - obj.PosX(sI);
            dyS = obj.PosY(sJ) - obj.PosY(sI);
            obj.RestLen = sqrt(dxS.^2 + dyS.^2);

            % --- Graphics ---
            % Semi-transparent black background
            obj.BgImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_cloth");
            uistack(obj.BgImageH, "bottom");
            uistack(obj.BgImageH, "up");

            % Build face connectivity — triangular or quad mesh
            nCells = (gw - 1) * (gh - 1);
            if obj.MeshType == "quad"
                faces = zeros(nCells, 4);
                fi = 0;
                for row = 1:gh - 1
                    for col = 1:gw - 1
                        tl = (row - 1) * gw + col;
                        fi = fi + 1;
                        faces(fi, :) = [tl, tl + 1, tl + gw + 1, tl + gw];
                    end
                end
            else
                faces = zeros(nCells * 2, 3);
                fi = 0;
                for row = 1:gh - 1
                    for col = 1:gw - 1
                        tl = (row - 1) * gw + col;
                        tr = tl + 1;
                        bl = tl + gw;
                        br = bl + 1;
                        fi = fi + 1;
                        faces(fi, :) = [tl, tr, bl];
                        fi = fi + 1;
                        faces(fi, :) = [tr, br, bl];
                    end
                end
            end

            % Per-vertex color: starts all cyan
            vertCol = repmat(obj.ColorCyan, nodeCount, 1);
            if obj.ShowEdges
                edgeCol = obj.ColorCyan;
                edgeAlp = 0.15;
            else
                edgeCol = "none";
                edgeAlp = 0;
            end
            if obj.Transparent
                faceAlp = 0.7;
            else
                faceAlp = 1.0;
            end
            obj.MeshPatchH = patch(ax, "Faces", faces, ...
                "Vertices", [obj.PosX, obj.PosY], ...
                "FaceVertexCData", vertCol, ...
                "FaceColor", "interp", "EdgeColor", edgeCol, ...
                "FaceAlpha", faceAlp, "EdgeAlpha", edgeAlp, ...
                "LineWidth", 0.5, "Tag", "GT_cloth");

            % Pinned node scatter markers
            pinIdx = find(obj.Pinned);
            if ~isempty(pinIdx)
                obj.PinGlowH = scatter(ax, obj.PosX(pinIdx), obj.PosY(pinIdx), ...
                    300, obj.ColorGold, "filled", "MarkerFaceAlpha", 0.15, ...
                    "Tag", "GT_cloth");
                obj.PinScatterH = scatter(ax, obj.PosX(pinIdx), obj.PosY(pinIdx), ...
                    80, obj.ColorGold, "filled", "MarkerFaceAlpha", 0.9, ...
                    "Tag", "GT_cloth");
            else
                obj.PinGlowH = scatter(ax, NaN, NaN, 300, obj.ColorGold, ...
                    "filled", "MarkerFaceAlpha", 0.15, "Tag", "GT_cloth");
                obj.PinScatterH = scatter(ax, NaN, NaN, 80, obj.ColorGold, ...
                    "filled", "MarkerFaceAlpha", 0.9, "Tag", "GT_cloth");
            end

            % Mode text (HUD)
            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 2, "", ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "top", "Tag", "GT_cloth");
            obj.updateHud();
        end

        function applySubMode(obj)
            %applySubMode  Set pinning + positions for current sub-mode.
            gw = obj.GridW;
            gh = obj.GridH;
            nodeCount = gw * gh;
            if nodeCount == 0; return; end
            obj.Pinned = false(nodeCount, 1);

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaHR = diff(dy);
            offset = areaHR * 0.04;
            gLeft = dx(1) + offset;
            gRight = dx(2) - offset;
            gTop = dy(1) + offset;
            gBot = dy(2) - offset;

            switch obj.SubMode
                case "curtain"
                    [rcx, rcy] = meshgrid( ...
                        linspace(gLeft, gRight, gw), ...
                        linspace(gTop, gBot, gh));
                    obj.Pinned(1:gw) = true;
                case "flag"
                    [rcx, rcy] = meshgrid( ...
                        linspace(gLeft, gRight, gw), ...
                        linspace(gTop, gBot, gh));
                    for row = 1:gh
                        obj.Pinned((row - 1) * gw + 1) = true;
                    end
                case "drum"
                    [rcx, rcy] = meshgrid( ...
                        linspace(gLeft, gRight, gw), ...
                        linspace(gTop, gBot, gh));
                    for row = 1:gh
                        for col = 1:gw
                            if row == 1 || row == gh || col == 1 || col == gw
                                obj.Pinned((row - 1) * gw + col) = true;
                            end
                        end
                    end
            end
            obj.PosX = reshape(rcx', [], 1);
            obj.PosY = reshape(rcy', [], 1);
            obj.PosZ = zeros(nodeCount, 1);
            obj.PrevX = obj.PosX;
            obj.PrevY = obj.PosY;
            obj.PrevZ = zeros(nodeCount, 1);
            obj.RestPosX = obj.PosX;
            obj.RestPosY = obj.PosY;

            % Update pin marker positions
            pinIdx = find(obj.Pinned);
            if ~isempty(obj.PinGlowH) && isvalid(obj.PinGlowH)
                if ~isempty(pinIdx)
                    obj.PinGlowH.XData = obj.PosX(pinIdx);
                    obj.PinGlowH.YData = obj.PosY(pinIdx);
                else
                    obj.PinGlowH.XData = NaN;
                    obj.PinGlowH.YData = NaN;
                end
            end
            if ~isempty(obj.PinScatterH) && isvalid(obj.PinScatterH)
                if ~isempty(pinIdx)
                    obj.PinScatterH.XData = obj.PosX(pinIdx);
                    obj.PinScatterH.YData = obj.PosY(pinIdx);
                else
                    obj.PinScatterH.XData = NaN;
                    obj.PinScatterH.YData = NaN;
                end
            end

            obj.updateHud();
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Change cloth mesh resolution (arrow keys).
            oldLevel = obj.GridLevel;
            if key == "uparrow"
                obj.GridLevel = min(10, oldLevel + 1);
            else
                obj.GridLevel = max(1, oldLevel - 1);
            end
            if obj.GridLevel == oldLevel; return; end
            obj.rebuildCloth();
        end

        function rebuildCloth(obj)
            %rebuildCloth  Tear down and rebuild cloth preserving settings.
            subMode = obj.SubMode;
            meshType = obj.MeshType;
            showEdg = obj.ShowEdges;
            transp = obj.Transparent;
            obj.onCleanup();
            obj.SubMode = subMode;
            obj.MeshType = meshType;
            obj.ShowEdges = showEdg;
            obj.Transparent = transp;
            obj.buildCloth();
        end

        function updateHud(obj)
            %updateHud  Update cloth HUD text with mode/mesh/grid info.
            if isempty(obj.ModeTextH) || ~isvalid(obj.ModeTextH); return; end
            obj.ModeTextH.String = obj.buildHudString();
        end

        function s = buildHudString(obj)
            %buildHudString  Compose HUD text from current state.
            meshStr = upper(obj.MeshType);
            edgeStr = "ON";
            if ~obj.ShowEdges; edgeStr = "OFF"; end
            alphaStr = "OPAQUE";
            if obj.Transparent; alphaStr = "TRANSP"; end
            s = upper(obj.SubMode) + " [M] | " + meshStr + " [N] | Grid " ...
                + obj.GridLevel + "/10 [" + char(8593) + char(8595) + ...
                "] | Edge " + edgeStr + " [V] | " + alphaStr + " [B] | Reset [0]";
        end
    end
end
