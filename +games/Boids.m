classdef Boids < GameBase
    %Boids  Formation-based flocking simulation with per-boid trails.
    %   150 agents (default) follow the finger in 4 formation modes:
    %   flock, predator, vortex, and murmuration. Per-boid colored trails
    %   rendered via a single patch object with FaceVertexAlphaData.
    %
    %   Controls:
    %     M         — cycle sub-mode (flock/predator/vortex/murmuration)
    %     B         — cycle color scheme (rainbow/speed/depth)
    %     Up/Down   — adjust boid count +-50 (range 50-500)
    %     0         — reset to current sub-mode
    %
    %   Standalone: games.Boids().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Boids"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        Count           (1,1) double = 150
        PosX            (:,1) double
        PosY            (:,1) double
        VelX            (:,1) double
        VelY            (:,1) double
        SubMode         (1,1) string = "flock"
        MaxSpeed        (1,1) double = 4
        PerceptRadius   (1,1) double = 60
        SepRadius       (1,1) double = 25
        HomeOffsetX     (:,1) double
        HomeOffsetY     (:,1) double
        RandPhase       (:,4) double
        ColorScheme     (1,1) double = 1
        FrameCount      (1,1) double = 0

        % Trail circular buffer
        TrailX          (:,:) double
        TrailY          (:,:) double
        TrailIdx        (1,1) double = 0
        TrailLen        (1,1) double = 8
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BodyH
        GlowH
        TrailH
        BackgroundH
        ModeTextH
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create boids graphics and initialize flocking state.
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
            areaW = diff(dxRange);
            areaH = diff(dyRange);
            nBoids = obj.Count;

            % Circular spawn — uniform distribution inside ellipse
            spawnAngles = rand(nBoids, 1) * 2 * pi;
            spawnRadii = sqrt(rand(nBoids, 1));  % sqrt for uniform area
            spawnRx = areaW * 0.3;
            spawnRy = areaH * 0.3;
            centerX0 = mean(dxRange);
            centerY0 = mean(dyRange);
            obj.PosX = centerX0 + spawnRadii .* cos(spawnAngles) * spawnRx;
            obj.PosY = centerY0 + spawnRadii .* sin(spawnAngles) * spawnRy;

            % Record formation offsets from centroid
            obj.HomeOffsetX = obj.PosX - centerX0;
            obj.HomeOffsetY = obj.PosY - centerY0;

            % Per-boid random phases for vortex angular offset and
            % murmuration per-boid wandering
            obj.RandPhase = rand(nBoids, 4) * 2 * pi;

            velAngles = rand(nBoids, 1) * 2 * pi;
            speeds = 0.5 + rand(nBoids, 1) * 1.0;
            obj.VelX = speeds .* cos(velAngles);
            obj.VelY = speeds .* sin(velAngles);

            obj.SubMode = "flock";
            obj.FrameCount = 0;

            % Trail circular buffer (pre-filled at spawn to avoid NaN artifacts)
            tLen = obj.TrailLen;
            obj.TrailX = repmat(obj.PosX', tLen, 1);
            obj.TrailY = repmat(obj.PosY', tLen, 1);
            obj.TrailIdx = tLen;

            % Semi-transparent black background
            obj.BackgroundH = image(ax, "XData", dxRange, "YData", dyRange, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_boids");
            uistack(obj.BackgroundH, "bottom");
            uistack(obj.BackgroundH, "up");

            initSpeeds = sqrt(obj.VelX.^2 + obj.VelY.^2);
            initCol = zeros(nBoids, 3);
            for k = 1:nBoids
                initCol(k, :) = obj.flickSpeedColor(initSpeeds(k));
            end

            % Per-boid trail patch (no NaN — duplicate newest at alpha=0
            % so closure edge is fully transparent on both ends)
            nVPB = tLen + 1;
            nVerts = nVPB * nBoids;
            verts = zeros(nVerts, 2);
            faces = zeros(nBoids, nVPB);
            fadeAlpha = zeros(nVerts, 1);
            for k = 1:nBoids
                base = (k - 1) * nVPB;
                faces(k, :) = base + (1:nVPB);
                % Vertex 1: newest pos duplicate, alpha=0 (invisible)
                % Vertices 2..nVPB: newest->oldest, alpha 0.4->0
                fadeAlpha(base + 1) = 0;
                fadeAlpha(base + (2:nVPB)) = linspace(0.4, 0, tLen)';
            end
            obj.TrailH = patch(ax, "Vertices", verts, "Faces", faces, ...
                "FaceColor", "none", "EdgeColor", "interp", ...
                "FaceVertexCData", zeros(nVerts, 3), ...
                "FaceVertexAlphaData", fadeAlpha, ...
                "EdgeAlpha", "interp", ...
                "LineWidth", 1.0, "Tag", "GT_boids");

            obj.GlowH = scatter(ax, obj.PosX, obj.PosY, ...
                80 * ones(nBoids, 1), initCol, "filled", ...
                "MarkerFaceAlpha", 0.15, "Tag", "GT_boids");
            obj.BodyH = scatter(ax, obj.PosX, obj.PosY, ...
                20 * ones(nBoids, 1), initCol, "filled", ...
                "MarkerFaceAlpha", 0.9, "Tag", "GT_boids");

            obj.ModeTextH = text(ax, dxRange(1) + 5, dyRange(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_boids");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame formation-based flocking with per-mode forces.
            nBoids = numel(obj.PosX);
            if nBoids == 0; return; end

            obj.FrameCount = obj.FrameCount + 1;
            dxRange = obj.DisplayRange.X;
            dyRange = obj.DisplayRange.Y;
            areaW = diff(dxRange);
            areaH = diff(dyRange);
            spdCap = obj.MaxSpeed;
            perceptR = obj.PerceptRadius;

            px = obj.PosX;
            py = obj.PosY;
            vx = obj.VelX;
            vy = obj.VelY;

            % Ensure home offsets and random phases exist
            if numel(obj.HomeOffsetX) ~= nBoids
                centX0 = mean(px); centY0 = mean(py);
                obj.HomeOffsetX = px - centX0;
                obj.HomeOffsetY = py - centY0;
            end
            if size(obj.RandPhase, 1) ~= nBoids
                obj.RandPhase = rand(nBoids, 4) * 2 * pi;
            end

            % Shared offset scale — same spread for all formation modes
            offScale = 0.6;
            offX = obj.HomeOffsetX * offScale;
            offY = obj.HomeOffsetY * offScale;

            formForceX = zeros(nBoids, 1);
            formForceY = zeros(nBoids, 1);

            switch obj.SubMode
                case "flock"
                    % Formation around finger with organic wobble.
                    if ~any(isnan(pos))
                        targetX = pos(1) + offX;
                        targetY = pos(2) + offY;
                    else
                        targetX = px;
                        targetY = py;
                    end
                    formForceX = (targetX - px) * 0.06 + 0.15 * randn(nBoids, 1);
                    formForceY = (targetY - py) * 0.06 + 0.15 * randn(nBoids, 1);

                case "predator"
                    % Formation flees from finger. Flee components that
                    % push toward a nearby wall are zeroed so the flock
                    % slides along edges instead of flying off-screen.
                    centX = mean(px); centY = mean(py);
                    if ~any(isnan(pos))
                        dfx = centX - pos(1);
                        dfy = centY - pos(2);
                        dist2F = max(sqrt(dfx^2 + dfy^2), 1);
                        fleeR = perceptR * 3;
                        if dist2F < fleeR
                            pushStr = 4.0 * (1 - dist2F / fleeR);
                            tangX = -dfy / dist2F;
                            tangY = dfx / dist2F;
                            fleeX = pushStr * (dfx / dist2F + 0.7 * tangX);
                            fleeY = pushStr * (dfy / dist2F + 0.7 * tangY);
                            % Clip flee toward nearby walls
                            wallZone = 30;
                            if centX < dxRange(1) + wallZone
                                fleeX = max(fleeX, 0);
                            end
                            if centX > dxRange(2) - wallZone
                                fleeX = min(fleeX, 0);
                            end
                            if centY < dyRange(1) + wallZone
                                fleeY = max(fleeY, 0);
                            end
                            if centY > dyRange(2) - wallZone
                                fleeY = min(fleeY, 0);
                            end
                            formForceX(:) = fleeX;
                            formForceY(:) = fleeY;
                        end
                    end
                    targetX = centX + offX;
                    targetY = centY + offY;
                    formForceX = formForceX + (targetX - px) * 0.06 ...
                        + 0.15 * randn(nBoids, 1);
                    formForceY = formForceY + (targetY - py) * 0.06 ...
                        + 0.15 * randn(nBoids, 1);

                case "vortex"
                    % Force-based orbiting with per-boid unique radii.
                    % Each boid gets a distinct orbit radius (spread via
                    % random phase), inner boids orbit faster.
                    if ~any(isnan(pos))
                        dfx = px - pos(1);
                        dfy = py - pos(2);
                        dist2F = sqrt(dfx.^2 + dfy.^2);
                        safeD = max(dist2F, 1);
                        tangX = -dfy ./ safeD;
                        tangY = dfx ./ safeD;
                        % Per-boid orbit radius — uniformly spread
                        maxHomeR = max(sqrt(offX.^2 + offY.^2));
                        minR = 15;
                        maxR = max(maxHomeR * 0.6, 30);
                        orbitR = minR + (maxR - minR) ...
                            * obj.RandPhase(:, 1) / (2 * pi);
                        % Per-boid radial breathing
                        fc = obj.FrameCount;
                        orbitR = orbitR .* (1 + 0.2 * sin( ...
                            fc * 0.03 + obj.RandPhase(:, 2)));
                        % Radial spring toward orbit radius
                        radStr = 0.3 * (dist2F - orbitR) ./ safeD;
                        % Tangential force — inner faster
                        tangSpd = 2.0 + 1.5 ...
                            * (1 - orbitR / max(maxR, 1));
                        formForceX = tangSpd .* tangX ...
                            - radStr .* dfx ./ safeD ...
                            + 0.15 * randn(nBoids, 1);
                        formForceY = tangSpd .* tangY ...
                            - radStr .* dfy ./ safeD ...
                            + 0.15 * randn(nBoids, 1);
                    end

                case "murmuration"
                    % Starling murmuration: flock cycles through 6
                    % distinct shapes with smoothstep blending.
                    fc = obj.FrameCount;
                    if ~any(isnan(pos))
                        centerX = pos(1);
                        centerY = pos(2);
                    else
                        centerX = mean(px);
                        centerY = mean(py);
                    end
                    % Normalize home offsets to unit space
                    homeR = sqrt(offX.^2 + offY.^2);
                    mxR = max(homeR);
                    if mxR < 1; mxR = 1; end
                    nX = offX / mxR;
                    nY = offY / mxR;
                    hA = atan2(nY, nX);
                    dispScale = mxR * 0.5;
                    % Shape cycle: 100 frames hold, 40 frames blend
                    nShapes = 6; shapeDur = 100; blendDur = 40;
                    cyclePos = mod(fc, nShapes * shapeDur);
                    sIdx = floor(cyclePos / shapeDur);
                    bP = min((cyclePos - sIdx * shapeDur) / blendDur, 1);
                    bP = bP * bP * (3 - 2 * bP);
                    curr = mod(sIdx, nShapes) + 1;
                    nxt = mod(sIdx + 1, nShapes) + 1;
                    [csX, csY] = games.Boids.murmurationShape(nX, nY, hA, curr);
                    [nsX, nsY] = games.Boids.murmurationShape(nX, nY, hA, nxt);
                    tX = (1 - bP) * csX + bP * nsX;
                    tY = (1 - bP) * csY + bP * nsY;
                    ph = obj.RandPhase;
                    targetX = centerX + tX * dispScale ...
                        + 3 * sin(fc * 0.04 + ph(:, 1));
                    targetY = centerY + tY * dispScale ...
                        + 3 * sin(fc * 0.035 + ph(:, 2));
                    formForceX = (targetX - px) * 0.15 + 0.08 * randn(nBoids, 1);
                    formForceY = (targetY - py) * 0.15 + 0.08 * randn(nBoids, 1);
            end

            % Integrate: damp then apply forces
            vx = vx * 0.92 + formForceX;
            vy = vy * 0.92 + formForceY;

            spd = sqrt(vx.^2 + vy.^2);
            tooFast = spd > spdCap;
            if any(tooFast)
                vx(tooFast) = vx(tooFast) .* spdCap ./ spd(tooFast);
                vy(tooFast) = vy(tooFast) .* spdCap ./ spd(tooFast);
                spd(tooFast) = spdCap;
            end

            % Soft wall avoidance
            margin = 10; wallStr = 0.2;
            lPen = max(dxRange(1) + margin - px, 0);
            rPen = max(px - (dxRange(2) - margin), 0);
            tPen = max(dyRange(1) + margin - py, 0);
            bPen = max(py - (dyRange(2) - margin), 0);
            vx = vx + wallStr * lPen - wallStr * rPen;
            vy = vy + wallStr * tPen - wallStr * bPen;

            px = px + vx;
            py = py + vy;

            % Hard clamp — never more than 15px past screen edge
            px = max(dxRange(1) - 15, min(dxRange(2) + 15, px));
            py = max(dyRange(1) - 15, min(dyRange(2) + 15, py));

            obj.PosX = px; obj.PosY = py;
            obj.VelX = vx; obj.VelY = vy;

            % Trail buffer update
            tLen = obj.TrailLen;
            if ~isempty(obj.TrailX) && size(obj.TrailX, 2) == nBoids
                obj.TrailIdx = mod(obj.TrailIdx, tLen) + 1;
                obj.TrailX(obj.TrailIdx, :) = px';
                obj.TrailY(obj.TrailIdx, :) = py';
            end

            % Per-boid coloring (3 schemes cycled with B key)
            boidCol = obj.computeBoidColors(spd);

            % Trail rendering — Vertices/Faces patch with per-vertex alpha
            if ~isempty(obj.TrailH) && isvalid(obj.TrailH) ...
                    && ~isempty(obj.TrailX)
                tIdx = obj.TrailIdx;
                order = mod((tIdx:tIdx + tLen - 1), tLen) + 1;
                trailXBuf = obj.TrailX(order, :);  % tLen x N, row1=oldest
                trailYBuf = obj.TrailY(order, :);
                nVPB = tLen + 1;
                verts = zeros(nVPB * nBoids, 2);
                vertCol = zeros(nVPB * nBoids, 3);
                for k = 1:nBoids
                    base = (k - 1) * nVPB;
                    tx = trailXBuf(tLen:-1:1, k);  % newest to oldest
                    ty = trailYBuf(tLen:-1:1, k);
                    verts(base + 1, :) = [tx(1), ty(1)];  % newest dup (alpha=0)
                    verts(base + (2:nVPB), :) = [tx, ty];  % newest->oldest
                    vertCol(base + (1:nVPB), :) = repmat(boidCol(k, :), nVPB, 1);
                end
                obj.TrailH.Vertices = verts;
                obj.TrailH.FaceVertexCData = vertCol;
            end

            if ~isempty(obj.BodyH) && isvalid(obj.BodyH)
                obj.BodyH.XData = px; obj.BodyH.YData = py;
                obj.BodyH.CData = boidCol;
            end
            if ~isempty(obj.GlowH) && isvalid(obj.GlowH)
                obj.GlowH.XData = px; obj.GlowH.YData = py;
                obj.GlowH.CData = boidCol;
            end

            % Scoring: flock coherence
            centX = mean(px); centY = mean(py);
            distToCent = sqrt((px - centX).^2 + (py - centY).^2);
            avgDist = mean(distToCent);
            coherence = max(0, 1 - avgDist / (min(areaW, areaH) * 0.5));
            if coherence > 0.3
                comboMult = max(1, obj.Combo * 0.1);
                obj.addScore(round(coherence * 5 * comboMult));
                obj.incrementCombo();
            else
                obj.Combo = max(0, obj.Combo - 1);
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all boids graphics and reset state.
            handles = {obj.BodyH, obj.GlowH, obj.TrailH, ...
                       obj.BackgroundH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_boids");

            obj.BodyH = []; obj.GlowH = []; obj.TrailH = [];
            obj.BackgroundH = []; obj.ModeTextH = [];
            obj.PosX = []; obj.PosY = [];
            obj.VelX = []; obj.VelY = [];
            obj.TrailX = []; obj.TrailY = [];
            obj.HomeOffsetX = []; obj.HomeOffsetY = [];
            obj.RandPhase = [];
            obj.TrailIdx = 0;
            obj.FrameCount = 0;
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle boids-specific key events.
            handled = true;
            switch key
                case "m"
                    modes = ["flock", "predator", "vortex", "murmuration"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.updateHud();

                case "b"
                    obj.ColorScheme = mod(obj.ColorScheme, 3) + 1;
                    obj.updateHud();

                case "uparrow"
                    prevSub = obj.SubMode;
                    prevScheme = obj.ColorScheme;
                    obj.Count = min(500, obj.Count + 50);
                    obj.onCleanup();
                    obj.onInit(obj.Ax, obj.DisplayRange, struct());
                    obj.SubMode = prevSub;
                    obj.ColorScheme = prevScheme;
                    obj.updateHud();

                case "downarrow"
                    prevSub = obj.SubMode;
                    prevScheme = obj.ColorScheme;
                    obj.Count = max(50, obj.Count - 50);
                    obj.onCleanup();
                    obj.onInit(obj.Ax, obj.DisplayRange, struct());
                    obj.SubMode = prevSub;
                    obj.ColorScheme = prevScheme;
                    obj.updateHud();

                case "0"
                    prevSub = obj.SubMode;
                    prevScheme = obj.ColorScheme;
                    obj.onCleanup();
                    obj.onInit(obj.Ax, obj.DisplayRange, struct());
                    obj.SubMode = prevSub;
                    obj.ColorScheme = prevScheme;
                    obj.updateHud();

                otherwise
                    handled = false;
            end
        end

        function r = getResults(obj)
            %getResults  Return boids-specific results.
            r.Title = "BOIDS";
            r.Lines = {
                sprintf("Score: %d  |  Max Combo: %d  |  N=%d  |  Mode: %s", ...
                    obj.Score, obj.MaxCombo, obj.Count, upper(obj.SubMode))
            };
        end

        function s = getHudText(obj)
            %getHudText  Return current HUD string for host display.
            s = obj.buildHudString();
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function boidCol = computeBoidColors(obj, spd)
            %computeBoidColors  Per-boid RGB based on current color scheme.
            nBoids = numel(obj.PosX);
            switch obj.ColorScheme
                case 1  % Rainbow — home angle
                    homeA = atan2(obj.HomeOffsetY, obj.HomeOffsetX);
                    hue = mod(homeA, 2 * pi) / (2 * pi);
                    boidCol = hsv2rgb([hue, ones(nBoids, 1) * 0.9, ...
                        ones(nBoids, 1)]);
                case 2  % Speed — cyan -> green -> gold
                    maxSpd = max(spd);
                    if maxSpd < 0.1; maxSpd = 1; end
                    boidCol = zeros(nBoids, 3);
                    for k = 1:nBoids
                        boidCol(k, :) = obj.flickSpeedColor( ...
                            spd(k) / maxSpd * 11);
                    end
                case 3  % Depth — distance from centroid
                    centX = mean(obj.PosX); centY = mean(obj.PosY);
                    distC = sqrt((obj.PosX - centX).^2 ...
                        + (obj.PosY - centY).^2);
                    maxD = max(distC);
                    if maxD < 1; maxD = 1; end
                    t = distC / maxD;
                    boidCol = (1 - t) .* obj.ColorCyan ...
                        + t .* [0.4, 0.1, 0.9];
                otherwise
                    boidCol = repmat(obj.ColorCyan, nBoids, 1);
            end
        end

        function updateHud(obj)
            %updateHud  Refresh mode label text.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

        function s = buildHudString(obj)
            %buildHudString  Compose HUD string from current state.
            colNames = ["RAINBOW", "SPEED", "DEPTH"];
            colName = colNames(obj.ColorScheme);
            s = upper(obj.SubMode) + " [M]  |  " ...
                + colName + " [B]  |  N=" ...
                + obj.Count + " [" + char(8593) + char(8595) + "]";
        end
    end

    % =================================================================
    % STATIC UTILITIES
    % =================================================================
    methods (Static, Access = private)
        function [sx, sy] = murmurationShape(nX, nY, ~, idx)
            %murmurationShape  Map unit-circle boid offsets to organic flock shapes.
            %   idx: 1=ellipse, 2=column, 3=crescent, 4=teardrop, 5=swoosh,
            %        6=hourglass
            switch idx
                case 1  % Horizontal ellipse
                    sx = nX * 1.4;
                    sy = nY * 0.7;
                case 2  % Vertical column
                    sx = nX * 0.5;
                    sy = nY * 1.8;
                case 3  % Crescent (C-curve)
                    sx = nX + nY.^2 * 0.9 - 0.4;
                    sy = nY * 1.4;
                case 4  % Teardrop (wide right, tapered left)
                    taper = max(0.2 + 0.8 * (nX + 1) / 2, 0.15);
                    sx = nX * 1.5;
                    sy = nY .* taper;
                case 5  % Swoosh (S-curve)
                    sx = nX * 1.5 + nY * 0.5;
                    sy = nY * 0.6 + sin(nX * pi * 0.8) * 0.6;
                case 6  % Hourglass (pinched middle)
                    pinch = 0.3 + 0.7 * abs(nY);
                    sx = nX .* pinch * 1.2;
                    sy = nY * 1.4;
                otherwise
                    sx = nX;
                    sy = nY;
            end
        end
    end
end
