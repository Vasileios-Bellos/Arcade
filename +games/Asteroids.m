classdef Asteroids < engine.GameBase
    %Asteroids  Wireframe asteroid field with auto-fire and splitting.
    %   Ship follows cursor position. Auto-fires at nearest asteroid every
    %   10 frames. Large asteroids split into medium, medium into small.
    %   Lives system with invulnerability flash on hit.
    %
    %   Standalone: games.Asteroids().play()
    %   Hosted:     Arcade hosts via init/onUpdate/onCleanup
    %
    %   See also engine.GameBase, Arcade

    properties (Constant)
        Name = "Asteroids"
    end

    % =================================================================
    % COLOR CONSTANTS (not in GameBase)
    % =================================================================
    properties (Constant, Access = private)
        ColorSilver (1,3) double = [0.75, 0.78, 0.82]
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        TierRadii       (1,3) double = [15, 10, 5]  % scaled in onInit
        ShipPos         (1,2) double = [NaN, NaN]
        Rocks           struct = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                                        "radius", {}, "tier", {}, "angle", {}, ...
                                        "spin", {}, "patchH", {})
        Bullets         struct = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                                        "lineH", {}, "glowH", {})
        FireCooldown    (1,1) double = 0
        Lives           (1,1) double = 3
        ShipRadius      (1,1) double = 8
        Wave            (1,1) double = 1
        InvulnFrames    (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ShipCoreH                   % scatter — ship core
        ShipGlowH                   % scatter — ship glow
        ShipTrailH                  % line — engine trail
        LivesTextH                  % text — lives (flash on change)
        LivesFlashTic       = []    % tic for lives flash animation
        WaveTextH                   % text — wave display
        WaveFlashTic        = []    % tic for wave flash animation
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create asteroids game graphics and initialize state.
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

            obj.ShipPos = [mean(dx), mean(dy)];
            obj.Lives = 3;
            obj.Wave = 1;
            obj.FireCooldown = 0;
            obj.InvulnFrames = 0;

            % Scale asteroid radii to display (original tuned for ~180px minDim)
            sc = min(diff(dx), diff(dy)) / 180;
            obj.TierRadii = round([15, 10, 5] * sc);

            obj.Bullets = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "lineH", {}, "glowH", {});
            obj.Rocks = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "radius", {}, "tier", {}, "angle", {}, "spin", {}, "patchH", {});

            % Ship graphics — scatter (SizeData recomputed each frame for resize)
            obj.ShipRadius = max(4, round(min(diff(dx), diff(dy)) * 0.03));
            obj.ShipGlowH = scatter(ax, obj.ShipPos(1), obj.ShipPos(2), ...
                1, obj.ColorCyan, "filled", "MarkerFaceAlpha", 0.15, ...
                "Tag", "GT_asteroids");
            obj.ShipCoreH = scatter(ax, obj.ShipPos(1), obj.ShipPos(2), ...
                1, obj.ColorCyan, "filled", "Tag", "GT_asteroids");
            obj.ShipTrailH = line(ax, NaN, NaN, "Color", [obj.ColorCyan, 0.4], ...
                "LineWidth", 1 * obj.FontScale, "Tag", "GT_asteroids");

            % Lives text — centered, hidden, flash on change
            cx = mean(dx);
            obj.LivesTextH = text(ax, cx, mean(dy), "", ...
                "Color", obj.ColorRed, "FontSize", 26 * obj.FontScale, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_asteroids");
            obj.LivesFlashTic = [];

            % Wave text — centered, hidden, flash on wave change
            obj.WaveTextH = text(ax, cx, mean(dy) - diff(dy) * 0.15, "", ...
                "Color", obj.ColorGold, "FontSize", 21 * obj.FontScale, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_asteroids");
            obj.WaveFlashTic = [];

            % Spawn initial asteroids
            obj.spawnWave(obj.Wave);
            obj.showWaveText(obj.Wave);
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame asteroids update.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            ds = obj.DtScale;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % Move ship to finger + recompute SizeData for current axes size
            if ~any(isnan(pos))
                obj.ShipPos = pos;
                r = obj.ShipRadius;
                pixPos = getpixelposition(obj.Ax);
                pxPerData = pixPos(3) / diff(obj.DisplayRange.X);
                dpiVal = get(0, "ScreenPixelsPerInch");
                rPts = r * pxPerData * 72 / dpiVal;
                if ~isempty(obj.ShipCoreH) && isvalid(obj.ShipCoreH)
                    obj.ShipCoreH.XData = pos(1);
                    obj.ShipCoreH.YData = pos(2);
                    obj.ShipCoreH.SizeData = rPts^2 * pi;
                end
                if ~isempty(obj.ShipGlowH) && isvalid(obj.ShipGlowH)
                    obj.ShipGlowH.XData = pos(1);
                    obj.ShipGlowH.YData = pos(2);
                    obj.ShipGlowH.SizeData = (rPts * 2.5)^2 * pi;
                end
            end

            % Auto-fire toward nearest asteroid
            obj.FireCooldown = obj.FireCooldown + ds;
            if obj.FireCooldown >= 24 && ~isempty(obj.Rocks)
                obj.FireCooldown = 0;
                obj.fireAtNearest(ax, dx, dy);
            end

            % Move bullets and check collisions
            obj.updateBullets(ax, dx, dy);

            % Move asteroids + wrap around
            obj.updateRocks(dx, dy);

            % Asteroid-ship collision
            obj.checkShipCollision();

            % Lives flash animation (0.6s hold + 0.4s fade)
            obj.animateLivesFlash();

            % Wave flash animation (1.2s hold + 0.5s fade)
            obj.animateWaveFlash();

            % Wave cleared?
            if isempty(obj.Rocks)
                obj.Wave = obj.Wave + 1;
                obj.addScore(500 * obj.Wave);
                obj.spawnWave(obj.Wave);
                obj.showWaveText(obj.Wave);
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all asteroid graphics.
            handles = {obj.ShipCoreH, obj.ShipGlowH, obj.ShipTrailH, ...
                obj.LivesTextH, obj.WaveTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.ShipCoreH = [];
            obj.ShipGlowH = [];
            obj.ShipTrailH = [];
            obj.LivesTextH = [];
            obj.WaveTextH = [];

            for k = 1:numel(obj.Rocks)
                if ~isempty(obj.Rocks(k).patchH) && isvalid(obj.Rocks(k).patchH)
                    delete(obj.Rocks(k).patchH);
                end
            end
            obj.Rocks = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "radius", {}, "tier", {}, "angle", {}, "spin", {}, "patchH", {});

            for k = 1:numel(obj.Bullets)
                if ~isempty(obj.Bullets(k).lineH) && isvalid(obj.Bullets(k).lineH)
                    delete(obj.Bullets(k).lineH);
                end
                if ~isempty(obj.Bullets(k).glowH) && isvalid(obj.Bullets(k).glowH)
                    delete(obj.Bullets(k).glowH);
                end
            end
            obj.Bullets = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "lineH", {}, "glowH", {});

            % Orphan guard
            engine.GameBase.deleteTaggedGraphics(obj.Ax, "^GT_asteroids");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for asteroids.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return asteroids-specific results.
            r.Title = "ASTEROIDS";
            r.Lines = {
                sprintf("Wave: %d", obj.Wave)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function spawnWave(obj, waveNum)
            %spawnWave  Spawn asteroids for the given wave.
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);
            ax = obj.Ax;

            nAst = 3 + waveNum;
            for i = 1:nAst
                % Spawn at edges
                edgeSide = randi(4);
                switch edgeSide
                    case 1; x = dx(1) - 15; y = dy(1) + rand * areaH;
                    case 2; x = dx(2) + 15; y = dy(1) + rand * areaH;
                    case 3; x = dx(1) + rand * areaW; y = dy(1) - 15;
                    case 4; x = dx(1) + rand * areaW; y = dy(2) + 15;
                end
                spd = max(0.125, min(areaW, areaH) * 0.00167) * (0.5 + rand);
                theta = rand * 2 * pi;
                vx = spd * cos(theta);
                vy = spd * sin(theta);
                obj.createRock(ax, x, y, vx, vy, obj.TierRadii(1), 1);
            end
        end

        function createRock(obj, ax, x, y, vx, vy, rockRadius, tier)
            %createRock  Create a single asteroid with neon wireframe.
            nVerts = 8 + randi(4);
            vertAngles = sort(rand(1, nVerts) * 2 * pi);
            vertRadii = rockRadius * (0.7 + 0.3 * rand(1, nVerts));
            px = x + vertRadii .* cos(vertAngles);
            py = y + vertRadii .* sin(vertAngles);
            px(end + 1) = px(1); 
            py(end + 1) = py(1); 

            tierColors = {obj.ColorSilver, obj.ColorGold, obj.ColorRed};
            clr = tierColors{min(tier, 3)};

            pH = patch(ax, "XData", px, "YData", py, ...
                "FaceColor", clr, "FaceAlpha", 0.20, ...
                "EdgeColor", clr, "LineWidth", 0.8 * obj.FontScale, "Tag", "GT_asteroids");

            obj.Rocks(end + 1) = struct("x", x, "y", y, "vx", vx, "vy", vy, ...
                "radius", rockRadius, "tier", tier, "angle", 0, ...
                "spin", (rand - 0.5) * 0.0208, "patchH", pH);
        end

        function showWaveText(obj, waveNum)
            %showWaveText  Flash wave number on screen.
            if ~isempty(obj.WaveTextH) && isvalid(obj.WaveTextH)
                obj.WaveTextH.String = sprintf("Wave %d", waveNum);
                obj.WaveTextH.Color = obj.ColorGold;
                obj.WaveTextH.Visible = "on";
                obj.WaveFlashTic = tic;
            end
        end

        function fireAtNearest(obj, ax, dx, dy)
            %fireAtNearest  Fire a bullet toward the nearest asteroid.
            minDist = inf;
            nearIdx = 1;
            for a = 1:numel(obj.Rocks)
                rockDist = norm([obj.Rocks(a).x - obj.ShipPos(1), ...
                    obj.Rocks(a).y - obj.ShipPos(2)]);
                if rockDist < minDist
                    minDist = rockDist;
                    nearIdx = a;
                end
            end
            targetPos = [obj.Rocks(nearIdx).x, obj.Rocks(nearIdx).y];
            aimDir = targetPos - obj.ShipPos;
            if norm(aimDir) > 0
                aimDir = aimDir / norm(aimDir);
            end
            bSpeed = max(2.5, min(diff(dx), diff(dy)) * 0.025);
            bvx = aimDir(1) * bSpeed;
            bvy = aimDir(2) * bSpeed;
            sx = obj.ShipPos(1);
            sy = obj.ShipPos(2);

            beamLen = max(8, min(diff(dx), diff(dy)) * 0.04);
            bps = obj.FontScale;
            glowH = line(ax, [sx, sx + aimDir(1) * beamLen], [sy, sy + aimDir(2) * beamLen], ...
                "Color", [obj.ColorCyan, 0.3], "LineWidth", 1.6 * bps, "Tag", "GT_asteroids");
            lineH = line(ax, [sx, sx + aimDir(1) * beamLen * 0.75], [sy, sy + aimDir(2) * beamLen * 0.75], ...
                "Color", obj.ColorCyan, "LineWidth", 0.8 * bps, "Tag", "GT_asteroids");

            obj.Bullets(end + 1) = struct("x", sx, "y", sy, ...
                "vx", bvx, "vy", bvy, "lineH", lineH, "glowH", glowH);
        end

        function updateBullets(obj, ax, dx, dy)
            %updateBullets  Move bullets, check off-screen and collisions.
            ds = obj.DtScale;
            k = 1;
            while k <= numel(obj.Bullets)
                bul = obj.Bullets(k);
                bul.x = bul.x + bul.vx * ds;
                bul.y = bul.y + bul.vy * ds;
                obj.Bullets(k) = bul;

                if ~isempty(bul.lineH) && isvalid(bul.lineH)
                    bul.lineH.XData = [bul.x, bul.x - bul.vx * 1.5];
                    bul.lineH.YData = [bul.y, bul.y - bul.vy * 1.5];
                end
                if ~isempty(bul.glowH) && isvalid(bul.glowH)
                    bul.glowH.XData = [bul.x, bul.x - bul.vx * 2.0];
                    bul.glowH.YData = [bul.y, bul.y - bul.vy * 2.0];
                end

                % Off screen — remove
                if bul.x < dx(1) - 20 || bul.x > dx(2) + 20 || ...
                        bul.y < dy(1) - 20 || bul.y > dy(2) + 20
                    if ~isempty(bul.lineH) && isvalid(bul.lineH); delete(bul.lineH); end
                    if ~isempty(bul.glowH) && isvalid(bul.glowH); delete(bul.glowH); end
                    obj.Bullets(k) = [];
                    continue;
                end

                % Bullet-asteroid collision (sweep test along bullet path)
                hitDetected = false;
                for a = numel(obj.Rocks):-1:1
                    rock = obj.Rocks(a);
                    % Closest point on bullet segment [prev, current] to rock center
                    px = bul.x - bul.vx;  % previous position
                    py = bul.y - bul.vy;
                    segX = bul.vx;
                    segY = bul.vy;
                    segLen2 = segX^2 + segY^2;
                    if segLen2 > 0
                        t = max(0, min(1, ((rock.x - px) * segX + (rock.y - py) * segY) / segLen2));
                    else
                        t = 0;
                    end
                    closestX = px + t * segX;
                    closestY = py + t * segY;
                    if norm([closestX - rock.x, closestY - rock.y]) < rock.radius
                        hitDetected = true;
                        obj.spawnBounceEffect([rock.x, rock.y], [0, -1], 0, 8);
                        obj.addScore(round(300 / rock.radius * 10));
                        obj.incrementCombo();

                        % Split into next tier
                        nextTier = rock.tier + 1;
                        if nextTier <= numel(obj.TierRadii)
                            for s = 1:2
                                sAngle = rand * 2 * pi;
                                sSpeed = norm([rock.vx, rock.vy]) * (1.2 + rand * 0.5);
                                svx = sSpeed * cos(sAngle);
                                svy = sSpeed * sin(sAngle);
                                obj.createRock(ax, rock.x, rock.y, svx, svy, ...
                                    obj.TierRadii(nextTier), nextTier);
                            end
                        end
                        if ~isempty(rock.patchH) && isvalid(rock.patchH)
                            delete(rock.patchH);
                        end
                        obj.Rocks(a) = [];
                        break;
                    end
                end
                if hitDetected
                    if ~isempty(bul.lineH) && isvalid(bul.lineH); delete(bul.lineH); end
                    if ~isempty(bul.glowH) && isvalid(bul.glowH); delete(bul.glowH); end
                    obj.Bullets(k) = [];
                    continue;
                end
                k = k + 1;
            end
        end

        function updateRocks(obj, dx, dy)
            %updateRocks  Move asteroids and wrap around screen edges.
            ds = obj.DtScale;
            for a = 1:numel(obj.Rocks)
                rock = obj.Rocks(a);
                rock.x = rock.x + rock.vx * ds;
                rock.y = rock.y + rock.vy * ds;
                rock.angle = rock.angle + rock.spin * ds;

                % Wrap
                margin = rock.radius;
                if rock.x < dx(1) - margin; rock.x = dx(2) + margin; end
                if rock.x > dx(2) + margin; rock.x = dx(1) - margin; end
                if rock.y < dy(1) - margin; rock.y = dy(2) + margin; end
                if rock.y > dy(2) + margin; rock.y = dy(1) - margin; end

                obj.Rocks(a) = rock;

                % Update graphics (translate)
                if ~isempty(rock.patchH) && isvalid(rock.patchH)
                    origCX = mean(rock.patchH.XData);
                    origCY = mean(rock.patchH.YData);
                    rock.patchH.XData = rock.patchH.XData - origCX + rock.x;
                    rock.patchH.YData = rock.patchH.YData - origCY + rock.y;
                end
            end
        end

        function checkShipCollision(obj)
            %checkShipCollision  Handle asteroid-ship collision and invulnerability.
            if obj.InvulnFrames > 0
                obj.InvulnFrames = obj.InvulnFrames - obj.DtScale;
                vis = "off";
                if mod(obj.InvulnFrames, 8) < 4; vis = "on"; end
                if ~isempty(obj.ShipCoreH) && isvalid(obj.ShipCoreH)
                    obj.ShipCoreH.Visible = vis;
                end
                if obj.InvulnFrames <= 0 && ~isempty(obj.ShipCoreH) && isvalid(obj.ShipCoreH)
                    obj.ShipCoreH.Visible = "on";
                end
            else
                for a = 1:numel(obj.Rocks)
                    rock = obj.Rocks(a);
                    if norm([rock.x - obj.ShipPos(1), rock.y - obj.ShipPos(2)]) < rock.radius + obj.ShipRadius
                        obj.Lives = obj.Lives - 1;
                        obj.resetCombo();

                        % Flash lives on screen
                        if ~isempty(obj.LivesTextH) && isvalid(obj.LivesTextH)
                            obj.LivesTextH.String = sprintf("Lives: %d", obj.Lives);
                            obj.LivesTextH.Color = obj.ColorRed;
                            obj.LivesTextH.Visible = "on";
                            obj.LivesFlashTic = tic;
                        end
                        obj.spawnBounceEffect(obj.ShipPos, [0, -1], 0, 15);

                        if obj.Lives <= 0
                            obj.IsRunning = false;
                            return;
                        end
                        obj.InvulnFrames = 144;
                        break;
                    end
                end
            end
        end

        function animateLivesFlash(obj)
            %animateLivesFlash  Animate lives text (0.6s hold + 0.4s fade).
            if ~isempty(obj.LivesFlashTic) && ~isempty(obj.LivesTextH) && ...
                    isgraphics(obj.LivesTextH) && isvalid(obj.LivesTextH)
                el = toc(obj.LivesFlashTic);
                if el < 0.6
                    obj.LivesTextH.Color = obj.ColorRed;
                elseif el < 1.0
                    fadeAlpha = 1 - (el - 0.6) / 0.4;
                    obj.LivesTextH.Color = [obj.ColorRed, max(0, fadeAlpha)];
                else
                    obj.LivesTextH.Visible = "off";
                    obj.LivesFlashTic = [];
                end
            end
        end

        function animateWaveFlash(obj)
            %animateWaveFlash  Animate wave text (1.2s hold + 0.5s fade).
            if ~isempty(obj.WaveFlashTic) && ~isempty(obj.WaveTextH) && ...
                    isgraphics(obj.WaveTextH) && isvalid(obj.WaveTextH)
                wEl = toc(obj.WaveFlashTic);
                if wEl < 1.2
                    obj.WaveTextH.Color = obj.ColorGold;
                elseif wEl < 1.7
                    wAlpha = 1 - (wEl - 1.2) / 0.5;
                    obj.WaveTextH.Color = [obj.ColorGold, max(0, wAlpha)];
                else
                    obj.WaveTextH.Visible = "off";
                    obj.WaveFlashTic = [];
                end
            end
        end
    end
end
