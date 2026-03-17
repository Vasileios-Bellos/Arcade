classdef FallingSandUtils
    %FallingSandUtils  Shared static methods for falling sand / elements simulation.
    %   Provides falling mask computation used by games.Elements and GestureTrainer.
    %
    %   See also games.Elements, GestureTrainer

    methods (Static)

        function falling = fsdFallingMask(cellGrid, matMask, matID, brushMask, ~)
            %fsdFallingMask  Bottom-up chain falling mask.
            %   Falling if empty below, or same material below is falling.
            %   Brush cells forced falling but don't propagate upward.
            %   matID=0: chain through any dynamic material below.
            [Ny, ~] = size(cellGrid);
            falling = false(size(cellGrid));
            isStaticMat = (cellGrid == 3) | (cellGrid == 6) | ...
                (cellGrid == 11) | (cellGrid == 12) | (cellGrid == 13);
            for r = Ny-1:-1:1
                below = cellGrid(r+1, :);
                if matID > 0
                    sameBelow = (below == matID);
                else
                    sameBelow = (below > 0) & ~isStaticMat(r+1, :);
                end
                falling(r, :) = matMask(r, :) & ...
                    (below == 0 | (sameBelow & falling(r+1, :) & ~brushMask(r+1, :)));
            end
            falling = falling | (matMask & brushMask);
        end

        function falling = fsdFallingMaskTurbulent(cellGrid, matMask, matID, brushMask, gapTol)
            %fsdFallingMaskTurbulent  Liquid-style mask (any same-material below = support).
            %   dSup uses ALL matching material (not just non-falling).
            [Ny, Nx] = size(cellGrid);
            isStaticMat = (cellGrid == 3) | (cellGrid == 6) | ...
                (cellGrid == 11) | (cellGrid == 12) | (cellGrid == 13);
            emptyCount = zeros(Ny, Nx);
            for r = Ny-1:-1:1
                isE = (cellGrid(r+1, :) == 0);
                isS = isStaticMat(r+1, :) | brushMask(r+1, :);
                emptyCount(r, :) = ~isS .* (emptyCount(r+1, :) + isE);
            end
            falling = matMask & (emptyCount > gapTol);
            if matID > 0
                dSup = matMask & [(cellGrid(2:end, :) == matID) | isStaticMat(2:end, :); false(1, Nx)];
            else
                dSup = matMask & [((cellGrid(2:end, :) ~= 0 & ~isStaticMat(2:end, :)) | isStaticMat(2:end, :)); false(1, Nx)];
            end
            colNF = any(~falling & matMask, 1);
            falling = falling & ~(dSup & ([false, colNF(1:end-1)] | [colNF(2:end), false]));
            falling = falling | (matMask & brushMask);
        end

    end
end
