classdef PathUtils
    %PathUtils  Shared static utilities for path-based games (tracing, etc.).
    %   Provides path generation, resampling, corridor construction, and
    %   boundary filtering used by the Tracing game and potentially others.
    %
    %   All methods are static — no instantiation needed.
    %   Usage: games.PathUtils.generatePath(tier, rangeX, rangeY, cw)
    %
    %   See also games.Tracing, GameBase

    methods (Static)

        function pathStruct = generatePath(tier, displayRangeX, displayRangeY, corridorWidth, applyRotation)
            %generatePath  Generate smooth tracing paths for thick neon bands.
            %   pathStruct = generatePath(tier, rangeX, rangeY, cw, applyRotation)
            %   All paths are smooth curves with adequate spacing for thick
            %   band rendering. Self-crossing at designated points (e.g.,
            %   figure-8 center) is intentional; turn-based overlap on
            %   spirals is prevented via dynamic turn count limiting.
            %   Set applyRotation=false to skip random orientation (for
            %   reference schematics).

            if nargin < 5; applyRotation = true; end
            if nargin < 4; corridorWidth = 20; end

            % Small edge margin — band clips naturally at axes boundaries
            edgeMargin = 25;
            xMin = displayRangeX(1) + edgeMargin;
            xMax = displayRangeX(2) - edgeMargin;
            yMin = displayRangeY(1) + edgeMargin;
            yMax = displayRangeY(2) - edgeMargin;

            xSpan = max(20, xMax - xMin);
            ySpan = max(20, yMax - yMin);
            cx = (xMin + xMax) / 2;
            cy = (yMin + yMax) / 2;
            spanVal = min(xSpan, ySpan);

            % Path types by tier
            switch tier
                case 1;  types = ["curve", "sCurve"];
                case 2;  types = ["wave", "oscillate", "arc"];
                case 3;  types = ["loop", "figure8", "spiral"];
                otherwise; types = "longSpiral";
            end
            pathType = types(randi(numel(types)));

            switch pathType
                case "curve"
                    % Gentle cubic Bezier spanning the area
                    p0 = [xMin + rand * xSpan * 0.1, cy + (rand - 0.5) * ySpan * 0.5];
                    p3 = [xMax - rand * xSpan * 0.1, cy + (rand - 0.5) * ySpan * 0.5];
                    c1 = [cx - xSpan * 0.1 + (rand-0.5)*xSpan*0.2, ...
                          cy + (rand-0.5) * ySpan * 0.7];
                    c2 = [cx + xSpan * 0.1 + (rand-0.5)*xSpan*0.2, ...
                          cy + (rand-0.5) * ySpan * 0.7];
                    tParam = linspace(0, 1, 400)';
                    rawX = (1-tParam).^3*p0(1) + 3*(1-tParam).^2.*tParam*c1(1) + 3*(1-tParam).*tParam.^2*c2(1) + tParam.^3*p3(1);
                    rawY = (1-tParam).^3*p0(2) + 3*(1-tParam).^2.*tParam*c1(2) + 3*(1-tParam).*tParam.^2*c2(2) + tParam.^3*p3(2);
                    rawX = rawX'; rawY = rawY';

                case "sCurve"
                    % S-curve: top lobe left, bottom lobe right (S with YDir=reverse)
                    tParam = linspace(0, 1, 400);
                    rawY = yMin + tParam * ySpan;
                    rawX = cx - sin(tParam * 2 * pi) * xSpan * 0.38;

                case "wave"
                    % Sine wave, 1.5 periods
                    tParam = linspace(0, 1, 500);
                    rawX = xMin + tParam * xSpan;
                    rawY = cy + sin(tParam * 2 * pi * 1.5) * ySpan * 0.35;

                case "oscillate"
                    % Longer sine wave, exactly 2 full periods
                    tParam = linspace(0, 1, 600);
                    rawX = xMin + tParam * xSpan;
                    rawY = cy + sin(tParam * 2 * pi * 2) * ySpan * 0.35;

                case "arc"
                    % Wide circular arc (not full circle)
                    arcAngle = pi * (0.6 + rand * 0.5);  % 108-198 deg
                    startAngle = rand * 2 * pi;
                    theta = linspace(startAngle, startAngle + arcAngle, 400);
                    arcR = spanVal * 0.42;
                    rawX = cx + arcR * cos(theta);
                    rawY = cy + arcR * sin(theta);

                case "loop"
                    % Smooth oval filling the area
                    theta = linspace(0, 2*pi, 500);
                    rx = xSpan * 0.40;
                    ry = ySpan * 0.40;
                    rawX = cx + rx * cos(theta);
                    rawY = cy + ry * sin(theta);

                case "figure8"
                    % Lissajous figure-8 (intentional single crossing at center)
                    theta = linspace(0, 2*pi, 600);
                    rx = xSpan * 0.38;
                    ry = ySpan * 0.38;
                    rawX = cx + rx * sin(theta);
                    rawY = cy + ry * sin(2 * theta);

                case "spiral"
                    % Archimedean spiral — turn spacing > corridorWidth
                    maxR = spanVal * 0.47;
                    minR = corridorWidth * 0.5;
                    minSpacing = corridorWidth * 1.3;
                    maxSafeTurns = max(1, maxR / minSpacing);
                    nTurns = min(1.5 + rand * 0.5, maxSafeTurns);
                    theta = linspace(0, 2 * pi * nTurns, 600);
                    spiralR = minR + (maxR - minR) * theta / max(theta);
                    rawX = cx + spiralR .* cos(theta);
                    rawY = cy + spiralR .* sin(theta);

                case "longSpiral"
                    % Wide spiral with enforced spacing for thick bands
                    maxR = spanVal * 0.48;
                    minR = corridorWidth * 0.5;
                    minSpacing = corridorWidth * 1.3;
                    maxSafeTurns = max(1.5, maxR / minSpacing);
                    nTurns = min(2 + rand * 0.5, maxSafeTurns);
                    theta = linspace(0, 2 * pi * nTurns, 700);
                    spiralR = minR + (maxR - minR) * theta / max(theta);
                    rawX = cx + spiralR .* cos(theta);
                    rawY = cy + spiralR .* sin(theta);

                otherwise
                    % Fallback: gentle curve
                    tParam = linspace(0, 1, 300);
                    rawX = xMin + tParam * xSpan;
                    rawY = cy + sin(tParam * pi) * ySpan * 0.35;
            end

            rawX = rawX(:)';
            rawY = rawY(:)';

            % --- Random orientation: rotate all types around centroid ---
            rotAngle = 0;
            if applyRotation
                rotAngle = rand * 2 * pi;
            end
            if rotAngle ~= 0
                centX = mean(rawX);
                centY = mean(rawY);
                ddx = rawX - centX;
                ddy = rawY - centY;
                cosA = cos(rotAngle);
                sinA = sin(rotAngle);
                rawX = centX + ddx * cosA - ddy * sinA;
                rawY = centY + ddx * sinA + ddy * cosA;
            end

            % 50% chance to reverse direction
            if rand > 0.5
                rawX = fliplr(rawX);
                rawY = fliplr(rawY);
            end

            % Scale to fit within display bounds (preserves shape after
            % rotation instead of hard-clamping which squashes it)
            pad = 5;
            xLo = displayRangeX(1) + pad;
            xHi = displayRangeX(2) - pad;
            yLo = displayRangeY(1) + pad;
            yHi = displayRangeY(2) - pad;
            centX = mean(rawX);
            centY = mean(rawY);
            extR = max(rawX) - centX;
            extL = centX - min(rawX);
            extD = max(rawY) - centY;
            extU = centY - min(rawY);
            scales = ones(1, 4);
            if extR > 0; scales(1) = (xHi - centX) / extR; end
            if extL > 0; scales(2) = (centX - xLo) / extL; end
            if extD > 0; scales(3) = (yHi - centY) / extD; end
            if extU > 0; scales(4) = (centY - yLo) / extU; end
            scaleFactor = min(scales);
            if scaleFactor < 1
                rawX = centX + (rawX - centX) * scaleFactor;
                rawY = centY + (rawY - centY) * scaleFactor;
            end
            % Safety clamp (floating point edge cases)
            rawX = max(xLo, min(xHi, rawX));
            rawY = max(yLo, min(yHi, rawY));

            % Random translation — applied AFTER scale-to-fit so the path
            % is never shrunk by the offset. Clamped to stay in bounds.
            if applyRotation
                maxShiftR = xHi - max(rawX);
                maxShiftL = xLo - min(rawX);
                maxShiftD = yHi - max(rawY);
                maxShiftU = yLo - min(rawY);
                offX = maxShiftL + rand * (maxShiftR - maxShiftL);
                offY = maxShiftU + rand * (maxShiftD - maxShiftU);
                rawX = rawX + offX;
                rawY = rawY + offY;
            end

            % Resample to uniform ~1px spacing
            [X, Y, cumDist] = games.PathUtils.resampleUniform(rawX, rawY);

            pathStruct.X = X;
            pathStruct.Y = Y;
            pathStruct.CumDist = cumDist;
            pathStruct.TotalLen = cumDist(end);
            pathStruct.Type = pathType;
            pathStruct.Difficulty = tier;
        end

        function [X, Y, cumDist] = resampleUniform(x, y)
            %resampleUniform  Resample a path to approximately 1px point spacing.
            %   [X, Y, cumDist] = games.PathUtils.resampleUniform(x, y)
            %   Input: raw x, y coordinate vectors (any spacing).
            %   Output: uniformly-spaced X, Y and cumulative arc length.

            segLen = hypot(diff(x), diff(y));
            cumLen = [0, cumsum(segLen)];
            totalLen = cumLen(end);

            if totalLen < 2
                X = x;
                Y = y;
                cumDist = cumLen;
                return
            end

            % ~1px spacing, minimum 3 points
            nPts = max(3, round(totalLen));
            cumDist = linspace(0, totalLen, nPts);
            X = interp1(cumLen, x, cumDist, "pchip");
            Y = interp1(cumLen, y, cumDist, "pchip");
        end

        function [lx, ly, rx, ry] = computeCorridorBounds(pathX, pathY, halfWidth)
            %computeCorridorBounds  Perpendicular offset for corridor edges.
            %   [lx, ly, rx, ry] = games.PathUtils.computeCorridorBounds(pathX, pathY, hw)
            %   Returns left and right boundary coordinates offset by halfWidth
            %   perpendicular to the path tangent at each point.

            nPts = numel(pathX);

            % Tangent vectors: central differences interior, one-sided at edges
            ddx = zeros(1, nPts);
            ddy = zeros(1, nPts);
            ddx(1) = pathX(min(2, nPts)) - pathX(1);
            ddy(1) = pathY(min(2, nPts)) - pathY(1);
            ddx(nPts) = pathX(nPts) - pathX(max(1, nPts-1));
            ddy(nPts) = pathY(nPts) - pathY(max(1, nPts-1));
            if nPts > 2
                ddx(2:nPts-1) = pathX(3:nPts) - pathX(1:nPts-2);
                ddy(2:nPts-1) = pathY(3:nPts) - pathY(1:nPts-2);
            end

            segLens = hypot(ddx, ddy);
            segLens(segLens == 0) = 1;

            % Perpendicular normals (rotate tangent 90 deg)
            nx = -ddy ./ segLens;
            ny = ddx ./ segLens;

            % Smooth normals to prevent boundary crossings at tight turns.
            if nPts > 5
                smoothWin = max(3, round(halfWidth * 1.5));
                nx = smoothdata(nx, "gaussian", smoothWin);
                ny = smoothdata(ny, "gaussian", smoothWin);
                nlen = hypot(nx, ny);
                nlen(nlen == 0) = 1;
                nx = nx ./ nlen;
                ny = ny ./ nlen;
            end

            lx = pathX + nx * halfWidth;
            ly = pathY + ny * halfWidth;
            rx = pathX - nx * halfWidth;
            ry = pathY - ny * halfWidth;
        end

        function [px, py] = buildBandPatch(pathX, pathY, halfWidth)
            %buildBandPatch  Build filled polygon for a corridor with semicircle caps.
            %   [px, py] = games.PathUtils.buildBandPatch(pathX, pathY, halfWidth)
            %   Returns closed polygon vertices for a corridor of width 2*halfWidth
            %   around the path, with semicircle caps at both endpoints.
            nPts = numel(pathX);
            if nPts < 2
                px = NaN; py = NaN; return;
            end

            % Corridor boundaries (perpendicular offsets)
            [lx, ly, rx, ry] = games.PathUtils.computeCorridorBounds( ...
                pathX, pathY, halfWidth);

            nCap = 12;  % points per semicircle cap

            % Semicircle cap at end (forward, from left(end) to right(end))
            dxE = pathX(nPts) - pathX(max(1, nPts - 1));
            dyE = pathY(nPts) - pathY(max(1, nPts - 1));
            angE = atan2(dyE, dxE);
            capAnglesE = linspace(angE + pi/2, angE - pi/2, nCap);
            capXE = pathX(nPts) + halfWidth * cos(capAnglesE);
            capYE = pathY(nPts) + halfWidth * sin(capAnglesE);

            % Semicircle cap at start (backward, from right(1) to left(1))
            dx1 = pathX(min(2, nPts)) - pathX(1);
            dy1 = pathY(min(2, nPts)) - pathY(1);
            ang1 = atan2(dy1, dx1);
            capAngles1 = linspace(ang1 - pi/2, ang1 - 3*pi/2, nCap);
            capX1 = pathX(1) + halfWidth * cos(capAngles1);
            capY1 = pathY(1) + halfWidth * sin(capAngles1);

            % Closed paths (start = end): left/right bounds are two closed
            % loops forming an annular corridor. Caps would overlap.
            startEndDist = hypot(pathX(end) - pathX(1), pathY(end) - pathY(1));
            if nPts > 50 && startEndDist < halfWidth * 2
                % Two closed loops separated by NaN
                px = [lx, lx(1), NaN, rx, rx(1)];
                py = [ly, ly(1), NaN, ry, ry(1)];
            else
                % Open path: single polygon with semicircle caps
                px = [lx, capXE, fliplr(rx), capX1];
                py = [ly, capYE, fliplr(ry), capY1];
            end
        end

        function ps = buildBandPolyshape(pathX, pathY, halfWidth)
            %buildBandPolyshape  Clean corridor polyshape via polybuffer.
            %   Handles self-intersecting paths (figure-8, loop closure)
            %   as a single connected region. Slower than buildBandPatch +
            %   polyshape (~50ms vs ~5ms) — use for one-time builds only.
            warnState = warning("off", "MATLAB:polyshape:repairedBySimplify");
            ps = polybuffer([pathX(:), pathY(:)], "lines", halfWidth);
            warning(warnState);
            holeThresh = halfWidth^2 * pi * 2;
            if ps.NumHoles > 0
                hs = holes(ps);
                for hIdx = 1:numel(hs)
                    if area(hs(hIdx)) < holeThresh
                        ps = union(ps, hs(hIdx));
                    end
                end
            end
        end

        function [fx, fy] = filterGlowBoundary(bx, by, corridorWidth)
            %filterGlowBoundary  Remove tiny crossing artifacts from glow outline.
            %   Polyshape boundary() includes small segments at corridor
            %   self-intersections. This filters them by perimeter threshold,
            %   keeping only the large outer boundary and inner lobe outlines.
            nanIdx = find(isnan(bx(:)'));
            if isempty(nanIdx)
                fx = bx; fy = by; return
            end
            starts = [1, nanIdx + 1];
            ends = [nanIdx - 1, numel(bx)];
            minPerim = corridorWidth * 4;
            fx = []; fy = [];
            for sIdx = 1:numel(starts)
                sx = bx(starts(sIdx):ends(sIdx));
                sy = by(starts(sIdx):ends(sIdx));
                perim = sum(sqrt(diff(sx).^2 + diff(sy).^2));
                if perim >= minPerim
                    if ~isempty(fx)
                        fx = [fx, NaN]; %#ok<AGROW>
                        fy = [fy, NaN]; %#ok<AGROW>
                    end
                    fx = [fx, sx(:)']; %#ok<AGROW>
                    fy = [fy, sy(:)']; %#ok<AGROW>
                end
            end
            if isempty(fx)
                fx = bx; fy = by;
            end
        end

    end
end
