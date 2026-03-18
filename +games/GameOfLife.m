classdef GameOfLife < GameBase
    %GameOfLife  Conway's Game of Life with age-based neon coloring.
    %   B3/S23 cellular automaton rendered via bilinear-interpolated image.
    %   Finger draws live cells. Inset population graph tracks history.
    %
    %   Standalone: games.GameOfLife().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Game of Life"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        Grid            (:,:) logical
        Age             (:,:) uint16
        GridW           (1,1) double = 120
        GridH           (1,1) double = 90
        GridLevel       (1,1) double = 6
        Generation      (1,1) double = 0
        FramesPerGen    (1,1) double = 3
        FrameAccum      (1,1) double = 0
        SubMode         (1,1) string = "random"
        PopHistory      (1,200) double = zeros(1, 200)
        PopIdx          (1,1) double = 0
        FrameCount      (1,1) double = 0
        PeakPop         (1,1) double = 0
        SimAccum        (1,1) double = 0   % FPS accumulator for fixed-rate physics
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ImageH
        ModeTextH
        PopAxH
        PopLineH
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create Game of Life grid and image overlay.
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

            dx = displayRange.X;
            dy = displayRange.Y;

            widths = [40 60 80 100 120 150 180 200 240 300];
            lvl = max(1, min(10, obj.GridLevel));
            obj.GridW = widths(lvl);
            obj.GridH = round(widths(lvl) * 0.75);
            Nx = obj.GridW;
            Ny = obj.GridH;

            obj.Grid = false(Ny, Nx);
            obj.Age = zeros(Ny, Nx, "uint16");
            obj.seedPattern();

            obj.Generation = 0;
            obj.FrameAccum = 0;
            obj.FrameCount = 0;
            obj.PeakPop = nnz(obj.Grid);
            obj.PopHistory = zeros(1, 200);
            obj.PopIdx = 0;

            % Dark background image — covers camera feed
            bgImg = image(ax, "XData", dx, "YData", dy, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_gameoflife");
            uistack(bgImg, "bottom");
            uistack(bgImg, "up");

            % Cell rendering image (bilinear interpolation gives soft neon glow)
            blackFrame = zeros(Ny, Nx, 3, "uint8");
            obj.ImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", blackFrame, "Interpolation", "bilinear", ...
                "Tag", "GT_gameoflife");

            % Population graph inset
            fig = ancestor(ax, "figure");
            axPos = getpixelposition(ax);
            insetW = axPos(3) * 0.22;
            insetH = axPos(4) * 0.12;
            insetX = axPos(1) + axPos(3) - insetW - 8;
            insetY = axPos(2) + axPos(4) - insetH - 8;
            obj.PopAxH = axes(fig, "Units", "pixels", ...
                "Position", [insetX, insetY, insetW, insetH], ...
                "Color", "none", "XColor", "none", "YColor", "none", ...
                "XTick", [], "YTick", [], "Box", "off", ...
                "Tag", "GT_gameoflife");
            hold(obj.PopAxH, "on");
            obj.PopLineH = plot(obj.PopAxH, 1:200, zeros(1, 200), ...
                "Color", [obj.ColorCyan, 0.8], "LineWidth", 1.5, ...
                "Tag", "GT_gameoflife");
            obj.PopAxH.XLim = [1 200];
            obj.PopAxH.YLim = [0 max(100, Nx * Ny * 0.5)];

            % HUD text
            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, ...
                obj.hudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_gameoflife");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame generation step + age rendering.
            if isempty(obj.Grid); return; end

            Ny = obj.GridH;
            Nx = obj.GridW;
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            obj.FrameCount = obj.FrameCount + 1;

            % Finger draws live cells
            if ~isempty(pos) && all(~isnan(pos))
                fx = round(1 + (pos(1) - dx(1)) / (dx(2) - dx(1)) * (Nx - 1));
                fy = round(1 + (pos(2) - dy(1)) / (dy(2) - dy(1)) * (Ny - 1));
                fx = max(1, min(Nx, fx));
                fy = max(1, min(Ny, fy));
                brushR = 3;
                r1 = max(1, fy - brushR);
                r2 = min(Ny, fy + brushR);
                c1 = max(1, fx - brushR);
                c2 = min(Nx, fx + brushR);
                for ri = r1:r2
                    for ci = c1:c2
                        if (ri - fy)^2 + (ci - fx)^2 <= brushR^2
                            if ~obj.Grid(ri, ci)
                                obj.Grid(ri, ci) = true;
                                obj.Age(ri, ci) = 1;
                            end
                        end
                    end
                end
            end

            % FPS normalization: run physics at design rate
            obj.SimAccum = obj.SimAccum + obj.DtScale;
            if obj.SimAccum < 1.0
                % Skip physics this frame, still render below
            else
            obj.SimAccum = obj.SimAccum - 1.0;

            % Advance generation
            obj.FrameAccum = obj.FrameAccum + 1;
            if obj.FrameAccum >= obj.FramesPerGen
                obj.FrameAccum = 0;
                obj.Generation = obj.Generation + 1;

                gridNow = obj.Grid;
                ageNow = double(obj.Age);

                % B3/S23 via conv2
                kernel = ones(3, 3);
                kernel(2, 2) = 0;
                neighbors = conv2(double(gridNow), kernel, "same");

                newGrid = (neighbors == 3) | (gridNow & neighbors == 2);

                survived = newGrid & gridNow;
                born = newGrid & ~gridNow;
                ageNow(survived) = ageNow(survived) + 1;
                ageNow(born) = 1;
                ageNow(~newGrid) = 0;

                obj.Grid = newGrid;
                obj.Age = uint16(ageNow);

                pop = nnz(newGrid);
                obj.PeakPop = max(obj.PeakPop, pop);
                obj.PopIdx = mod(obj.PopIdx, 200) + 1;
                obj.PopHistory(obj.PopIdx) = pop;
            end

            end  % SimAccum gate

            % Render: neon age-based coloring
            % Newborn = bright cyan, young = green, mature = gold, elder = magenta
            ageNow = double(obj.Age);
            maxAge = max(max(ageNow), 1);
            normAge = min(ageNow / max(50, maxAge), 1);
            alive = double(obj.Grid);

            t = normAge;
            % Neon colormap: cyan(0) -> green(0.33) -> gold(0.66) -> magenta(1.0)
            R = alive .* (60 + 195 * max(0, min(1, (t - 0.25) * 2.5)));
            G = alive .* (255 * max(0, 1 - max(0, t - 0.5) * 2.5));
            B = alive .* (255 * max(0, 1 - t * 2.5) + 180 * max(0, t - 0.7) * 3.3);
            % Brightness boost — bilinear interpolation bleeds into neighboring
            % pixels, creating a natural neon glow halo around live cells
            boost = alive .* (1.0 + 0.3 * (1 - t));
            R = uint8(min(255, R .* boost));
            G = uint8(min(255, G .* boost));
            B = uint8(min(255, B .* boost));

            cellFrame = cat(3, R, G, B);
            if ~isempty(obj.ImageH) && isvalid(obj.ImageH)
                obj.ImageH.CData = cellFrame;
            end

            % Population graph
            if ~isempty(obj.PopLineH) && isvalid(obj.PopLineH)
                popIdx = obj.PopIdx;
                order = [popIdx+1:200, 1:popIdx];
                popData = obj.PopHistory(order);
                obj.PopLineH.YData = popData;
                maxPop = max(popData);
                if maxPop > 0 && ~isempty(obj.PopAxH) && isvalid(obj.PopAxH)
                    obj.PopAxH.YLim = [0, maxPop * 1.2 + 1];
                end
            end

            % Update HUD with live generation + population count
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH) ...
                    && mod(obj.FrameCount, 5) == 0
                pop = nnz(obj.Grid);
                obj.ModeTextH.String = obj.hudString() + ...
                    "  |  Gen " + obj.Generation + "  Pop " + pop;
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all Game of Life graphics.
            handles = {obj.ImageH, obj.ModeTextH, obj.PopLineH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            if ~isempty(obj.PopAxH) && isvalid(obj.PopAxH)
                delete(obj.PopAxH);
            end
            % Orphan guard — axes children
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_gameoflife");
            % Orphan guard — inset axes created on the figure
            if ~isempty(obj.Ax) && isvalid(obj.Ax)
                fig = ancestor(obj.Ax, "figure");
                if ~isempty(fig) && isvalid(fig)
                    orphanAx = findall(fig, "Type", "axes", "Tag", "GT_gameoflife");
                    delete(orphanAx);
                end
            end
            obj.ImageH = [];
            obj.ModeTextH = [];
            obj.PopAxH = [];
            obj.PopLineH = [];
            obj.Grid = [];
            obj.Age = [];
            obj.FrameCount = 0;
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle Game of Life keys.
            handled = true;
            switch key
                case "m"
                    modes = ["random", "gliders", "pulsar", "soup"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();
                case {"uparrow", "downarrow"}
                    obj.changeGridLevel(key);
                case {"leftarrow", "rightarrow"}
                    obj.changeSpeed(key);
                case "0"
                    obj.applySubMode();
                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return Game of Life results.
            r.Title = "GAME OF LIFE";
            elapsed = 0;
            if ~isempty(obj.StartTic); elapsed = toc(obj.StartTic); end
            r.Lines = {
                sprintf("Gen: %d  |  Peak Pop: %d  |  Time: %.0fs", ...
                    obj.Generation, obj.PeakPop, elapsed)
            };
        end

    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function applySubMode(obj)
            %applySubMode  Reset grid with new pattern.
            if isempty(obj.Grid); return; end
            Ny = obj.GridH;
            Nx = obj.GridW;
            obj.Grid = false(Ny, Nx);
            obj.Age = zeros(Ny, Nx, "uint16");
            obj.Generation = 0;
            obj.PopHistory = zeros(1, 200);
            obj.PopIdx = 0;
            obj.PeakPop = 0;
            obj.seedPattern();
            obj.PeakPop = nnz(obj.Grid);
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.hudString();
            end
        end

        function seedPattern(obj)
            %seedPattern  Seed the grid based on current sub-mode.
            Ny = obj.GridH;
            Nx = obj.GridW;
            cy = round(Ny / 2);
            cx = round(Nx / 2);
            switch obj.SubMode
                case "random"
                    obj.Grid = rand(Ny, Nx) < 0.25;
                    obj.Age(obj.Grid) = 1;
                case "gliders"
                    if Nx >= 40 && Ny >= 20
                        gun = games.GameOfLife.gosperGun();
                        obj.stampPattern(gun, 2, 2);
                        if Nx >= 80 && Ny >= 40
                            gunFlip = flipud(fliplr(gun));
                            obj.stampPattern(gunFlip, Ny - size(gun, 1) - 2, Nx - size(gun, 2) - 2);
                        end
                    else
                        glider = [0 1 0; 0 0 1; 1 1 1];
                        obj.stampPattern(glider, 3, 3);
                        obj.stampPattern(glider, round(Ny/3), round(Nx/3));
                    end
                case "pulsar"
                    pulsarPat = zeros(17, 17);
                    rows = [3 3 3 5 6 7 8 8 8 5 6 7];
                    cols = [5 6 7 3 3 3 5 6 7 8 8 8];
                    for k = 1:numel(rows)
                        rr = rows(k); cc = cols(k);
                        pulsarPat(rr, cc) = 1;
                        pulsarPat(rr, 18 - cc) = 1;
                        pulsarPat(18 - rr, cc) = 1;
                        pulsarPat(18 - rr, 18 - cc) = 1;
                    end
                    obj.stampPattern(pulsarPat, cy - 8, cx - 8);
                case "soup"
                    patchW = round(Nx * 0.3);
                    patchH = round(Ny * 0.3);
                    r1 = max(1, cy - round(patchH/2));
                    r2 = min(Ny, r1 + patchH - 1);
                    c1 = max(1, cx - round(patchW/2));
                    c2 = min(Nx, c1 + patchW - 1);
                    obj.Grid(r1:r2, c1:c2) = rand(r2-r1+1, c2-c1+1) < 0.45;
                    obj.Age(obj.Grid) = 1;
            end
        end

        function stampPattern(obj, pattern, row, col)
            %stampPattern  Stamp a binary pattern onto the grid.
            [ph, pw] = size(pattern);
            Ny = obj.GridH;
            Nx = obj.GridW;
            for ri = 1:ph
                for ci = 1:pw
                    gr = row + ri - 1;
                    gc = col + ci - 1;
                    if gr >= 1 && gr <= Ny && gc >= 1 && gc <= Nx && pattern(ri, ci)
                        obj.Grid(gr, gc) = true;
                        obj.Age(gr, gc) = 1;
                    end
                end
            end
        end

        function changeGridLevel(obj, key)
            %changeGridLevel  Adjust grid resolution and reinitialize.
            oldLevel = obj.GridLevel;
            if key == "uparrow"
                obj.GridLevel = min(10, oldLevel + 1);
            else
                obj.GridLevel = max(1, oldLevel - 1);
            end
            if obj.GridLevel == oldLevel; return; end
            obj.onCleanup();
            obj.onInit(obj.Ax, obj.DisplayRange, struct());
        end

        function changeSpeed(obj, key)
            %changeSpeed  Adjust frames per generation.
            if key == "rightarrow"
                obj.FramesPerGen = max(1, obj.FramesPerGen - 1);
            else
                obj.FramesPerGen = min(10, obj.FramesPerGen + 1);
            end
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.hudString();
            end
        end

        function s = hudString(obj)
            %hudString  Build HUD label string for Game of Life.
            s = upper(obj.SubMode) + " [M]  |  Grid " + ...
                obj.GridW + char(215) + obj.GridH + ...
                " [" + char(8593) + char(8595) + "]  |  Speed " + ...
                obj.FramesPerGen + " [" + char(8592) + char(8594) + "]";
        end
    end

    % =================================================================
    % STATIC UTILITIES
    % =================================================================
    methods (Static, Access = private)
        function gun = gosperGun()
            %gosperGun  Return Gosper glider gun as binary matrix.
            gun = zeros(11, 38);
            gun(5, 1) = 1; gun(5, 2) = 1;
            gun(6, 1) = 1; gun(6, 2) = 1;
            gun(3, 13) = 1; gun(3, 14) = 1;
            gun(4, 12) = 1; gun(4, 16) = 1;
            gun(5, 11) = 1; gun(5, 17) = 1;
            gun(6, 11) = 1; gun(6, 15) = 1;
            gun(6, 17) = 1; gun(6, 18) = 1;
            gun(7, 11) = 1; gun(7, 17) = 1;
            gun(8, 12) = 1; gun(8, 16) = 1;
            gun(9, 13) = 1; gun(9, 14) = 1;
            gun(1, 25) = 1;
            gun(2, 23) = 1; gun(2, 25) = 1;
            gun(3, 21) = 1; gun(3, 22) = 1;
            gun(4, 21) = 1; gun(4, 22) = 1;
            gun(5, 21) = 1; gun(5, 22) = 1;
            gun(6, 23) = 1; gun(6, 25) = 1;
            gun(7, 25) = 1;
            gun(3, 35) = 1; gun(3, 36) = 1;
            gun(4, 35) = 1; gun(4, 36) = 1;
        end
    end
end
