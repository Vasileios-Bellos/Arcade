classdef SpaceInvaders < GameBase
    %SpaceInvaders  Classic space invaders with alien waves, power-ups, and shields.
    %   3 alien shapes (crab/squid/UFO), 5 distinct wave formations with
    %   increasing difficulty. Shield intercepts at radius. Power-ups:
    %   laser (double fire rate), shield (projectile barrier), extra life.
    %   Victory after wave 5.
    %
    %   Standalone: games.SpaceInvaders().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Space Invaders"
    end

    % =================================================================
    % POOL SIZES
    % =================================================================
    properties (Constant, Access = private)
        BulletPoolSize  (1,1) double = 10
        EBulletPoolSize (1,1) double = 15
        PUPoolSize      (1,1) double = 4
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Ship
        ShipX               (1,1) double = NaN
        ShipW               (1,1) double = 16
        ShipH               (1,1) double = 10
        ShipY               (1,1) double = NaN

        % Aliens
        Aliens              struct = struct("x", {}, "y", {}, "hp", {}, "maxHp", {}, ...
                                            "type", {}, "shapeX", {}, "shapeY", {}, ...
                                            "patchH", {}, "glowH", {})
        AlienDir            (1,1) double = 1            % 1=right, -1=left
        AlienSpeed          (1,1) double = 0.125
        AlienDropDist       (1,1) double = 6

        % Player bullet pool
        BulletPoolLine              % cell array of line handles (core)
        BulletPoolGlow              % cell array of line handles (glow)
        BulletX                     % x position per slot
        BulletY                     % y position per slot
        BulletActive                % logical array, true = in use

        % Enemy bullet pool
        EBulletPoolLine             % cell array of line handles
        EBulletX                    % x position per slot
        EBulletY                    % y position per slot
        EBulletActive               % logical array, true = in use

        % Auto-fire
        FireCD              (1,1) double = 0
        FireRate             (1,1) double = 29           % frames between shots

        % Wave / Lives
        Wave                (1,1) double = 1
        Lives               (1,1) double = 3
        InvulnFrames        (1,1) double = 0
        GameOver            (1,1) logical = false

        % Power-up pool
        PUPoolPatch                 % cell array of patch handles (capsule body)
        PUPoolGlow                  % cell array of line handles (dot marker glow)
        PUPoolText                  % cell array of text handles (label)
        PUX                         % x position per slot
        PUY                         % y position per slot
        PUType                      % string array of types
        PUActive                    % logical array, true = in use

        LaserActive         (1,1) logical = false
        LaserExpiry         uint64
        ShieldActive        (1,1) logical = false
        ShieldExpiry        uint64

        % Pre-computed theta arrays
        ThetaCircle24               % 24-point circle for capsule
        ThetaCircle32               % 32-point circle for shield

        % Display scale factor (1.0 at ~180px reference)
        Sc              (1,1) double = 1
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        ShipPatchH                          % patch - player ship
        ShipGlowH                           % patch - ship glow
        LivesTextH                          % text - lives flash display
        LivesFlashTic       = []            % tic - flash timer
        WaveTextH                           % text - wave name display
        WaveFlashTic        = []            % tic - wave name timer
        ShieldPatchH                        % patch - shield circle (pre-allocated)
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

            dx = displayRange.X;
            dy = displayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);

            % Display scale factor (1.0 at ~180px reference)
            obj.Sc = min(areaW, areaH) / 180;

            % Pre-compute theta arrays once
            obj.ThetaCircle24 = linspace(0, 2*pi, 24);
            obj.ThetaCircle32 = linspace(0, 2*pi, 32);

            % Ship setup
            obj.ShipW = max(12, round(areaW * 0.06));
            obj.ShipH = max(6, round(areaH * 0.06));
            obj.ShipY = dy(2) - round(areaH * 0.1);
            obj.ShipX = mean(dx);

            obj.Lives = 3;
            obj.Wave = 1;
            obj.FireCD = 0;
            obj.FireRate = 12;
            obj.AlienDir = 1;
            obj.AlienSpeed = max(0.083, areaW * 0.000833);
            obj.AlienDropDist = max(3, areaH * 0.04);
            obj.InvulnFrames = 0;
            obj.GameOver = false;
            obj.LaserActive = false;
            obj.ShieldActive = false;

            % Create ship - arrow-like shape
            sw = obj.ShipW;
            sh = obj.ShipH;
            shipXCoords = [obj.ShipX, obj.ShipX - sw/2, obj.ShipX - sw/3, ...
                           obj.ShipX + sw/3, obj.ShipX + sw/2];
            shipYCoords = [obj.ShipY - sh, obj.ShipY, obj.ShipY + sh*0.3, ...
                           obj.ShipY + sh*0.3, obj.ShipY];
            obj.ShipGlowH = patch(ax, "XData", shipXCoords, "YData", shipYCoords, ...
                "FaceColor", obj.ColorCyan, "FaceAlpha", 0.1, ...
                "EdgeColor", obj.ColorCyan, "LineWidth", 2, "Tag", "GT_spaceinvaders");
            obj.ShipPatchH = patch(ax, "XData", shipXCoords, "YData", shipYCoords, ...
                "FaceColor", obj.ColorCyan, "FaceAlpha", 0.3, ...
                "EdgeColor", obj.ColorCyan, "LineWidth", 1.5, "Tag", "GT_spaceinvaders");

            % Lives flash display (centered, hidden - flashes on change)
            cx = mean(dx);
            obj.LivesTextH = text(ax, cx, mean(dy), "", ...
                "Color", obj.ColorRed, "FontSize", max(18, round(areaH * 0.1)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_spaceinvaders");
            obj.LivesFlashTic = [];

            % Wave name display (centered, hidden - flashes on wave start)
            obj.WaveTextH = text(ax, cx, mean(dy) - areaH * 0.15, "", ...
                "Color", obj.ColorGold, "FontSize", max(16, round(areaH * 0.08)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_spaceinvaders");
            obj.WaveFlashTic = [];

            % --- Pre-allocate player bullet pool ---
            nB = obj.BulletPoolSize;
            obj.BulletPoolLine = cell(1, nB);
            obj.BulletPoolGlow = cell(1, nB);
            obj.BulletX = zeros(1, nB);
            obj.BulletY = zeros(1, nB);
            obj.BulletActive = false(1, nB);
            for k = 1:nB
                obj.BulletPoolGlow{k} = line(ax, [0, 0], [0, 0], ...
                    "Color", [obj.ColorCyan, 0.3], "LineWidth", 4, ...
                    "Visible", "off", "Tag", "GT_spaceinvaders");
                obj.BulletPoolLine{k} = line(ax, [0, 0], [0, 0], ...
                    "Color", obj.ColorCyan, "LineWidth", 1.5, ...
                    "Visible", "off", "Tag", "GT_spaceinvaders");
            end

            % --- Pre-allocate enemy bullet pool ---
            nE = obj.EBulletPoolSize;
            obj.EBulletPoolLine = cell(1, nE);
            obj.EBulletX = zeros(1, nE);
            obj.EBulletY = zeros(1, nE);
            obj.EBulletActive = false(1, nE);
            for k = 1:nE
                obj.EBulletPoolLine{k} = line(ax, [0, 0], [0, 0], ...
                    "Color", obj.ColorRed, "LineWidth", 2, ...
                    "Visible", "off", "Tag", "GT_spaceinvaders");
            end

            % --- Pre-allocate power-up pool ---
            nP = obj.PUPoolSize;
            obj.PUPoolPatch = cell(1, nP);
            obj.PUPoolGlow = cell(1, nP);
            obj.PUPoolText = cell(1, nP);
            obj.PUX = zeros(1, nP);
            obj.PUY = zeros(1, nP);
            obj.PUType = repmat("", 1, nP);
            obj.PUActive = false(1, nP);
            capR = round(5 * obj.Sc);
            thetaCap = obj.ThetaCircle24;
            for k = 1:nP
                obj.PUPoolGlow{k} = line(ax, 0, 0, "Color", [obj.ColorGold, 0.2], ...
                    "Marker", ".", "MarkerSize", 20, ...
                    "LineStyle", "none", "Visible", "off", "Tag", "GT_spaceinvaders");
                obj.PUPoolPatch{k} = patch(ax, "XData", capR * cos(thetaCap), ...
                    "YData", capR * sin(thetaCap), ...
                    "FaceColor", obj.ColorGold, "FaceAlpha", 0.6, ...
                    "EdgeColor", obj.ColorGold, "LineWidth", 1.5, ...
                    "Visible", "off", "Tag", "GT_spaceinvaders");
                obj.PUPoolText{k} = text(ax, 0, 0, "", ...
                    "Color", [1, 1, 1], "FontSize", 15, "FontWeight", "bold", ...
                    "HorizontalAlignment", "center", "VerticalAlignment", "middle", ...
                    "Visible", "off", "Tag", "GT_spaceinvaders");
            end

            % --- Pre-allocate shield patch (hidden) ---
            sr = obj.ShipW * 0.8;
            thetaShield = obj.ThetaCircle32;
            obj.ShieldPatchH = patch(ax, ...
                "XData", obj.ShipX + sr * cos(thetaShield), ...
                "YData", obj.ShipY + sr * sin(thetaShield), ...
                "FaceColor", obj.ColorCyan, "FaceAlpha", 0.08, ...
                "EdgeColor", obj.ColorCyan, "LineWidth", 1, ...
                "Visible", "off", "Tag", "GT_spaceinvaders");

            % Build alien grid + show wave name
            obj.buildAlienGrid(obj.Wave);
            obj.showWaveName(obj.Wave);
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame space invaders update.
            if obj.GameOver
                obj.IsRunning = false;
                return;
            end

            ds = obj.DtScale;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % Move ship to finger X
            if ~any(isnan(pos))
                targetX = max(dx(1) + obj.ShipW/2, min(dx(2) - obj.ShipW/2, pos(1)));
                deltaX = targetX - obj.ShipX;
                obj.ShipX = targetX;
                if ~isempty(obj.ShipPatchH) && isvalid(obj.ShipPatchH)
                    obj.ShipPatchH.XData = obj.ShipPatchH.XData + deltaX;
                end
                if ~isempty(obj.ShipGlowH) && isvalid(obj.ShipGlowH)
                    obj.ShipGlowH.XData = obj.ShipGlowH.XData + deltaX;
                end
                if obj.ShieldActive && ~isempty(obj.ShieldPatchH) && isvalid(obj.ShieldPatchH)
                    obj.ShieldPatchH.XData = obj.ShieldPatchH.XData + deltaX;
                end
            end

            % Auto-fire
            obj.FireCD = obj.FireCD + ds;
            currentFireRate = obj.FireRate;
            if obj.LaserActive; currentFireRate = max(10, currentFireRate / 2); end
            if obj.FireCD >= currentFireRate
                obj.FireCD = 0;
                obj.fireBullet();
            end

            % Move player bullets upward
            bulletSpeed = max(0.833, diff(dy) * 0.0104);
            bLen = max(3, diff(dy) * 0.02);
            for k = 1:obj.BulletPoolSize
                if ~obj.BulletActive(k); continue; end
                obj.BulletY(k) = obj.BulletY(k) - bulletSpeed * ds;
                by = obj.BulletY(k);
                bx = obj.BulletX(k);

                % Update line positions
                bLineH = obj.BulletPoolLine{k};
                if ~isempty(bLineH) && isvalid(bLineH)
                    bLineH.YData = [by, by + bLen];
                    bLineH.XData = [bx, bx];
                end
                bGlowH = obj.BulletPoolGlow{k};
                if ~isempty(bGlowH) && isvalid(bGlowH)
                    bGlowH.YData = [by - 1, by + bLen + 1];
                    bGlowH.XData = [bx, bx];
                end

                % Off screen — deactivate
                if by < dy(1) - 10
                    obj.deactivateBullet(k);
                    continue;
                end

                % Check bullet-alien collision
                hitAlien = false;
                for a = numel(obj.Aliens):-1:1
                    al = obj.Aliens(a);
                    if abs(bx - al.x) < obj.ShipW * 0.7 && abs(by - al.y) < obj.ShipH * 0.8
                        obj.Aliens(a).hp = obj.Aliens(a).hp - 1;
                        if obj.Aliens(a).hp <= 0
                            obj.spawnBounceEffect([al.x, al.y], [0, -1], 0, 8);
                            if ~isempty(al.patchH) && isvalid(al.patchH); delete(al.patchH); end
                            if ~isempty(al.glowH) && isvalid(al.glowH); delete(al.glowH); end
                            obj.Aliens(a) = [];
                            obj.addScore(50 * al.type);
                            obj.incrementCombo();
                            % Chance to drop power-up
                            if rand < 0.08
                                obj.spawnPowerUp(al.x, al.y);
                            end
                        else
                            % Proportional alpha: more visible damage per hit
                            hpRatio = obj.Aliens(a).hp / obj.Aliens(a).maxHp;
                            if ~isempty(obj.Aliens(a).patchH) && isvalid(obj.Aliens(a).patchH)
                                obj.Aliens(a).patchH.FaceAlpha = 0.15 + 0.35 * hpRatio;
                            end
                            if ~isempty(obj.Aliens(a).glowH) && isvalid(obj.Aliens(a).glowH)
                                obj.Aliens(a).glowH.FaceAlpha = 0.05 + 0.10 * hpRatio;
                            end
                        end
                        hitAlien = true;
                        break;
                    end
                end
                if hitAlien
                    obj.deactivateBullet(k);
                end
            end

            % Move aliens
            edgeHit = false;
            for a = 1:numel(obj.Aliens)
                obj.Aliens(a).x = obj.Aliens(a).x + obj.AlienDir * obj.AlienSpeed * ds;
                if obj.Aliens(a).x > dx(2) - 10 || obj.Aliens(a).x < dx(1) + 10
                    edgeHit = true;
                end
            end
            if edgeHit
                obj.AlienDir = -obj.AlienDir;
                for a = 1:numel(obj.Aliens)
                    obj.Aliens(a).y = obj.Aliens(a).y + obj.AlienDropDist;
                end
            end
            % Update alien graphics (direct position from stored shape offsets)
            for a = 1:numel(obj.Aliens)
                al = obj.Aliens(a);
                newX = al.x + al.shapeX;
                newY = al.y + al.shapeY;
                if ~isempty(al.patchH) && isvalid(al.patchH)
                    al.patchH.XData = newX;
                    al.patchH.YData = newY;
                end
                if ~isempty(al.glowH) && isvalid(al.glowH)
                    al.glowH.XData = newX;
                    al.glowH.YData = newY;
                end
            end

            % Enemy fire (random alien shoots) — use pool
            if ~isempty(obj.Aliens) && rand < 0.0083 * (1 + obj.Wave * 0.3)
                shooter = obj.Aliens(randi(numel(obj.Aliens)));
                obj.activateEBullet(shooter.x, shooter.y);
            end

            % Move enemy bullets
            eBulletSpeed = max(0.625, diff(dy) * 0.00625);
            for k = 1:obj.EBulletPoolSize
                if ~obj.EBulletActive(k); continue; end
                obj.EBulletY(k) = obj.EBulletY(k) + eBulletSpeed * ds;
                ebx = obj.EBulletX(k);
                eby = obj.EBulletY(k);
                ebLineH = obj.EBulletPoolLine{k};
                if ~isempty(ebLineH) && isvalid(ebLineH)
                    ebLineH.YData = [eby, eby + round(4 * obj.Sc)];
                    ebLineH.XData = [ebx, ebx];
                end
                if eby > dy(2) + 10
                    obj.deactivateEBullet(k);
                    continue;
                end
                % Shield intercept (at shield radius, before reaching ship)
                if obj.ShieldActive
                    sr = obj.ShipW * 0.8;
                    if (ebx - obj.ShipX)^2 + (eby - obj.ShipY)^2 < sr^2
                        obj.spawnBounceEffect([ebx, eby], [0, -1], 0, 6);
                        obj.deactivateEBullet(k);
                        continue;
                    end
                end
                % Hit player?
                if obj.InvulnFrames <= 0 && ...
                        abs(ebx - obj.ShipX) < obj.ShipW / 2 && ...
                        abs(eby - obj.ShipY) < obj.ShipH
                    obj.loseLife();
                    obj.deactivateEBullet(k);
                    if obj.Lives <= 0; return; end
                end
            end

            % Invulnerability blink
            if obj.InvulnFrames > 0
                obj.InvulnFrames = obj.InvulnFrames - ds;
                vis = "off";
                if mod(obj.InvulnFrames, 8) < 4; vis = "on"; end
                if ~isempty(obj.ShipPatchH) && isvalid(obj.ShipPatchH)
                    obj.ShipPatchH.Visible = vis;
                end
                if obj.InvulnFrames <= 0 && ~isempty(obj.ShipPatchH) && isvalid(obj.ShipPatchH)
                    obj.ShipPatchH.Visible = "on";
                end
            end

            % Check alien reaching bottom (game over)
            for a = 1:numel(obj.Aliens)
                if obj.Aliens(a).y > obj.ShipY - 5
                    obj.Lives = 0;
                    obj.GameOver = true;
                    return;
                end
            end

            % Wave cleared?
            if isempty(obj.Aliens)
                obj.addScore(500 * obj.Wave);
                if obj.Wave >= 5
                    % Victory - all waves beaten
                    obj.GameOver = true;
                    return;
                end
                obj.Wave = obj.Wave + 1;
                obj.buildAlienGrid(obj.Wave);
                obj.showWaveName(obj.Wave);
            end

            % Update power-ups (falling) — pool-based
            capR = round(5 * obj.Sc);
            thetaCap = obj.ThetaCircle24;
            for k = 1:obj.PUPoolSize
                if ~obj.PUActive(k); continue; end
                obj.PUY(k) = obj.PUY(k) + 0.4167 * ds;
                puX = obj.PUX(k);
                puY = obj.PUY(k);

                % Update capsule body position
                puPatchH = obj.PUPoolPatch{k};
                if ~isempty(puPatchH) && isvalid(puPatchH)
                    puPatchH.XData = puX + capR * cos(thetaCap);
                    puPatchH.YData = puY + capR * sin(thetaCap);
                end
                % Update glow dot position
                puGlowH = obj.PUPoolGlow{k};
                if ~isempty(puGlowH) && isvalid(puGlowH)
                    puGlowH.XData = puX;
                    puGlowH.YData = puY;
                end
                % Update text label position
                puTextH = obj.PUPoolText{k};
                if ~isempty(puTextH) && isvalid(puTextH)
                    puTextH.Position = [puX, puY, 0];
                end

                % Catch by ship
                if abs(puX - obj.ShipX) < obj.ShipW && ...
                        abs(puY - obj.ShipY) < obj.ShipH
                    obj.applyPowerUp(obj.PUType(k));
                    obj.deactivatePU(k);
                    continue;
                end
                if puY > dy(2) + 20
                    obj.deactivatePU(k);
                end
            end

            % Expire power-ups
            if obj.LaserActive && ~isempty(obj.LaserExpiry) && toc(obj.LaserExpiry) > 8
                obj.LaserActive = false;
            end
            if obj.ShieldActive && ~isempty(obj.ShieldExpiry) && toc(obj.ShieldExpiry) > 10
                obj.ShieldActive = false;
                if ~isempty(obj.ShieldPatchH) && isvalid(obj.ShieldPatchH)
                    obj.ShieldPatchH.Visible = "off";
                end
            end

            % --- Lives flash (0.6s visible, then 0.4s fade out) ---
            if ~isempty(obj.LivesFlashTic) && ~isempty(obj.LivesTextH) && ...
                    isgraphics(obj.LivesTextH) && isvalid(obj.LivesTextH)
                flashElapsed = toc(obj.LivesFlashTic);
                showDur = 0.6;
                fadeDur = 0.4;
                if flashElapsed < showDur
                    obj.LivesTextH.Color = obj.ColorRed;
                elseif flashElapsed < showDur + fadeDur
                    fadeAlpha = 1 - (flashElapsed - showDur) / fadeDur;
                    obj.LivesTextH.Color = [obj.ColorRed, max(0, fadeAlpha)];
                else
                    obj.LivesTextH.Visible = "off";
                    obj.LivesFlashTic = [];
                end
            end

            % --- Wave name flash (1.2s visible, then 0.5s fade out) ---
            if ~isempty(obj.WaveFlashTic) && ~isempty(obj.WaveTextH) && ...
                    isgraphics(obj.WaveTextH) && isvalid(obj.WaveTextH)
                wElapsed = toc(obj.WaveFlashTic);
                wShowDur = 1.2;
                wFadeDur = 0.5;
                if wElapsed < wShowDur
                    obj.WaveTextH.Color = obj.ColorGold;
                elseif wElapsed < wShowDur + wFadeDur
                    wAlpha = 1 - (wElapsed - wShowDur) / wFadeDur;
                    obj.WaveTextH.Color = [obj.ColorGold, max(0, wAlpha)];
                else
                    obj.WaveTextH.Visible = "off";
                    obj.WaveFlashTic = [];
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all space invaders graphics.
            handles = {obj.ShipPatchH, obj.ShipGlowH, obj.LivesTextH, ...
                obj.ShieldPatchH, obj.WaveTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.ShipPatchH = [];
            obj.ShipGlowH = [];
            obj.LivesTextH = [];
            obj.ShieldPatchH = [];
            obj.WaveTextH = [];
            obj.LivesFlashTic = [];
            obj.WaveFlashTic = [];

            % Aliens
            for k = 1:numel(obj.Aliens)
                if ~isempty(obj.Aliens(k).patchH) && isvalid(obj.Aliens(k).patchH)
                    delete(obj.Aliens(k).patchH);
                end
                if ~isempty(obj.Aliens(k).glowH) && isvalid(obj.Aliens(k).glowH)
                    delete(obj.Aliens(k).glowH);
                end
            end
            obj.Aliens = struct("x", {}, "y", {}, "hp", {}, "maxHp", {}, ...
                "type", {}, "shapeX", {}, "shapeY", {}, "patchH", {}, "glowH", {});

            % Player bullet pool
            if ~isempty(obj.BulletPoolLine)
                for k = 1:numel(obj.BulletPoolLine)
                    h = obj.BulletPoolLine{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            if ~isempty(obj.BulletPoolGlow)
                for k = 1:numel(obj.BulletPoolGlow)
                    h = obj.BulletPoolGlow{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.BulletPoolLine = {};
            obj.BulletPoolGlow = {};
            obj.BulletActive = false(1, 0);

            % Enemy bullet pool
            if ~isempty(obj.EBulletPoolLine)
                for k = 1:numel(obj.EBulletPoolLine)
                    h = obj.EBulletPoolLine{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.EBulletPoolLine = {};
            obj.EBulletActive = false(1, 0);

            % Power-up pool
            if ~isempty(obj.PUPoolPatch)
                for k = 1:numel(obj.PUPoolPatch)
                    h = obj.PUPoolPatch{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            if ~isempty(obj.PUPoolGlow)
                for k = 1:numel(obj.PUPoolGlow)
                    h = obj.PUPoolGlow{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            if ~isempty(obj.PUPoolText)
                for k = 1:numel(obj.PUPoolText)
                    h = obj.PUPoolText{k};
                    if ~isempty(h) && isvalid(h); delete(h); end
                end
            end
            obj.PUPoolPatch = {};
            obj.PUPoolGlow = {};
            obj.PUPoolText = {};
            obj.PUActive = false(1, 0);

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_spaceinvaders");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for space invaders.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return space invaders results.
            if obj.Wave >= 5 && isempty(obj.Aliens)
                r.Title = "YOU WIN!";
            else
                r.Title = "SPACE INVADERS";
            end
            r.Lines = {
                sprintf("Wave: %d", obj.Wave)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function buildAlienGrid(obj, wave)
            %buildAlienGrid  Create alien formation for given wave.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = diff(dx);
            areaH = diff(dy);

            % Wave-specific formations (5 distinct waves)
            %   Wave 1 "Scouts":    8x2 - Green + Magenta
            %   Wave 2 "Battalion": 9x3 - Red top, Magenta mid, Green bottom
            %   Wave 3 "Armada":   10x3 - all Magenta (HP2) - wide uniform wall
            %   Wave 4 "Elites":    8x4 - Red top two, Magenta, Green - tall
            %   Wave 5 "Onslaught":10x4 - all Red (HP3) - full grid boss wave
            switch wave
                case 1; cols = 8;  rows = 2; rowTypes = [2, 1];
                case 2; cols = 9;  rows = 3; rowTypes = [3, 2, 1];
                case 3; cols = 10; rows = 3; rowTypes = [3, 2, 1];
                case 4; cols = 8;  rows = 4; rowTypes = [3, 3, 2, 1];
                otherwise; cols = 10; rows = 4; rowTypes = [3, 3, 3, 3];
            end
            alienW = max(6, round(areaW * 0.04));
            alienH = alienW;  % square bounding box
            gapX = alienW * 1.8;
            gapY = alienH * 1.6;
            gridW = cols * gapX;
            startX = mean(dx) - gridW / 2 + gapX / 2;
            startY = dy(1) + areaH * 0.08;

            % Clean old aliens
            for k = 1:numel(obj.Aliens)
                if ~isempty(obj.Aliens(k).patchH) && isvalid(obj.Aliens(k).patchH)
                    delete(obj.Aliens(k).patchH);
                end
                if ~isempty(obj.Aliens(k).glowH) && isvalid(obj.Aliens(k).glowH)
                    delete(obj.Aliens(k).glowH);
                end
            end
            obj.Aliens = struct("x", {}, "y", {}, "hp", {}, "maxHp", {}, ...
                "type", {}, "shapeX", {}, "shapeY", {}, "patchH", {}, "glowH", {});

            alienColors = {obj.ColorGreen, obj.ColorMagenta, obj.ColorRed};
            for rowIdx = 1:rows
                aType = rowTypes(rowIdx);
                clr = alienColors{aType};
                hp = aType;
                for colIdx = 1:cols
                    alienX = startX + (colIdx - 1) * gapX;
                    alienY = startY + (rowIdx - 1) * gapY;

                    % Alien shape - invader-style polygon (vertices relative to center)
                    aw2 = alienW / 2;
                    ah2 = alienH / 2;
                    [sx, sy] = games.SpaceInvaders.alienShapeVertices(aType, aw2, ah2);
                    px = alienX + sx;
                    py = alienY + sy;

                    glowH = patch(ax, "XData", px, "YData", py, ...
                        "FaceColor", clr, "FaceAlpha", 0.15, ...
                        "EdgeColor", clr * 0.5, "LineWidth", 2.5, "Tag", "GT_spaceinvaders");
                    patchH = patch(ax, "XData", px, "YData", py, ...
                        "FaceColor", clr, "FaceAlpha", 0.5, ...
                        "EdgeColor", clr, "LineWidth", 1.5, "Tag", "GT_spaceinvaders");

                    obj.Aliens(end + 1) = struct("x", alienX, "y", alienY, ...
                        "hp", hp, "maxHp", hp, "type", aType, ...
                        "shapeX", sx, "shapeY", sy, ...
                        "patchH", patchH, "glowH", glowH);
                end
            end

            obj.AlienSpeed = max(0.083, diff(dx) * 0.000833) * (1 + 0.15 * (wave - 1));
        end

        function fireBullet(obj)
            %fireBullet  Fire a bullet from the ship using the pre-allocated pool.
            dy = obj.DisplayRange.Y;
            bLen = max(3, diff(dy) * 0.02);
            bColor = obj.ColorCyan;
            if obj.LaserActive; bColor = obj.ColorRed; end

            % Find first inactive slot
            slot = find(~obj.BulletActive, 1);
            if isempty(slot); return; end  % pool full, skip shot

            bx = obj.ShipX;
            by = obj.ShipY - obj.ShipH;
            obj.BulletX(slot) = bx;
            obj.BulletY(slot) = by;
            obj.BulletActive(slot) = true;

            glowH = obj.BulletPoolGlow{slot};
            if ~isempty(glowH) && isvalid(glowH)
                glowH.XData = [bx, bx];
                glowH.YData = [by - 1, by - bLen - 1];
                glowH.Color = [bColor, 0.3];
                glowH.Visible = "on";
            end
            lineH = obj.BulletPoolLine{slot};
            if ~isempty(lineH) && isvalid(lineH)
                lineH.XData = [bx, bx];
                lineH.YData = [by, by - bLen];
                lineH.Color = bColor;
                lineH.Visible = "on";
            end
        end

        function deactivateBullet(obj, k)
            %deactivateBullet  Hide a player bullet and mark slot as inactive.
            obj.BulletActive(k) = false;
            h = obj.BulletPoolLine{k};
            if ~isempty(h) && isvalid(h); h.Visible = "off"; end
            h = obj.BulletPoolGlow{k};
            if ~isempty(h) && isvalid(h); h.Visible = "off"; end
        end

        function activateEBullet(obj, x, y)
            %activateEBullet  Activate an enemy bullet from the pool.
            slot = find(~obj.EBulletActive, 1);
            if isempty(slot); return; end  % pool full, skip shot

            obj.EBulletX(slot) = x;
            obj.EBulletY(slot) = y;
            obj.EBulletActive(slot) = true;

            h = obj.EBulletPoolLine{slot};
            if ~isempty(h) && isvalid(h)
                h.XData = [x, x];
                h.YData = [y, y + 4];
                h.Visible = "on";
            end
        end

        function deactivateEBullet(obj, k)
            %deactivateEBullet  Hide an enemy bullet and mark slot as inactive.
            obj.EBulletActive(k) = false;
            h = obj.EBulletPoolLine{k};
            if ~isempty(h) && isvalid(h); h.Visible = "off"; end
        end

        function deactivatePU(obj, k)
            %deactivatePU  Hide a power-up and mark slot as inactive.
            obj.PUActive(k) = false;
            h = obj.PUPoolPatch{k};
            if ~isempty(h) && isvalid(h); h.Visible = "off"; end
            h = obj.PUPoolGlow{k};
            if ~isempty(h) && isvalid(h); h.Visible = "off"; end
            h = obj.PUPoolText{k};
            if ~isempty(h) && isvalid(h); h.Visible = "off"; end
        end

        function loseLife(obj)
            %loseLife  Handle player ship hit.
            obj.Lives = obj.Lives - 1;
            obj.resetCombo();
            obj.updateLivesDisplay();
            obj.spawnBounceEffect([obj.ShipX, obj.ShipY], [0, -1], 0, 15);
            if obj.Lives <= 0
                obj.GameOver = true;
                return;
            end
            obj.InvulnFrames = 144;
        end

        function updateLivesDisplay(obj)
            %updateLivesDisplay  Flash lives remaining in center of screen.
            if isempty(obj.LivesTextH) || ~isgraphics(obj.LivesTextH) || ...
                    ~isvalid(obj.LivesTextH); return; end
            if obj.Lives > 0
                obj.LivesTextH.String = sprintf("Lives: %d", obj.Lives);
            else
                obj.LivesTextH.String = "GAME OVER";
            end
            obj.LivesTextH.Color = obj.ColorRed;
            obj.LivesTextH.Visible = "on";
            obj.LivesFlashTic = tic;
        end

        function showWaveName(obj, wave)
            %showWaveName  Flash wave number and name in center of screen.
            if isempty(obj.WaveTextH) || ~isgraphics(obj.WaveTextH) || ...
                    ~isvalid(obj.WaveTextH); return; end
            names = ["Scouts", "Battalion", "Armada", "Elites", "Onslaught"];
            if wave <= numel(names)
                waveName = names(wave);
            else
                waveName = "Wave " + wave;
            end
            obj.WaveTextH.String = sprintf("Wave %d — %s", wave, waveName);
            obj.WaveTextH.Color = obj.ColorGold;
            obj.WaveTextH.Visible = "on";
            obj.WaveFlashTic = tic;
        end

        function spawnPowerUp(obj, x, y)
            %spawnPowerUp  Activate a falling power-up capsule from the pool.
            types = ["L", "S", "+"];  % Laser, Shield, Extra Life
            colors = {obj.ColorRed, obj.ColorCyan, obj.ColorGold};
            idx = randi(numel(types));
            pType = types(idx);
            pColor = colors{idx};

            % Find first inactive slot
            slot = find(~obj.PUActive, 1);
            if isempty(slot); return; end  % pool full, skip spawn

            capR = round(5 * obj.Sc);
            thetaCap = obj.ThetaCircle24;

            obj.PUX(slot) = x;
            obj.PUY(slot) = y;
            obj.PUType(slot) = pType;
            obj.PUActive(slot) = true;

            % Update capsule body
            puPatchH = obj.PUPoolPatch{slot};
            if ~isempty(puPatchH) && isvalid(puPatchH)
                puPatchH.XData = x + capR * cos(thetaCap);
                puPatchH.YData = y + capR * sin(thetaCap);
                puPatchH.FaceColor = pColor;
                puPatchH.EdgeColor = pColor;
                puPatchH.Visible = "on";
            end

            % Update glow dot
            puGlowH = obj.PUPoolGlow{slot};
            if ~isempty(puGlowH) && isvalid(puGlowH)
                puGlowH.XData = x;
                puGlowH.YData = y;
                puGlowH.Color = [pColor, 0.2];
                puGlowH.Visible = "on";
            end

            % Update label
            puTextH = obj.PUPoolText{slot};
            if ~isempty(puTextH) && isvalid(puTextH)
                puTextH.Position = [x, y, 0];
                puTextH.String = char(pType);
                puTextH.Visible = "on";
            end
        end

        function applyPowerUp(obj, puType)
            %applyPowerUp  Activate a power-up.
            switch puType
                case "L"
                    obj.LaserActive = true;
                    obj.LaserExpiry = tic;
                case "S"
                    obj.ShieldActive = true;
                    obj.ShieldExpiry = tic;
                    % Show pre-allocated shield patch at current ship position
                    if ~isempty(obj.ShieldPatchH) && isvalid(obj.ShieldPatchH)
                        sr = obj.ShipW * 0.8;
                        thetaShield = obj.ThetaCircle32;
                        obj.ShieldPatchH.XData = obj.ShipX + sr * cos(thetaShield);
                        obj.ShieldPatchH.YData = obj.ShipY + sr * sin(thetaShield);
                        obj.ShieldPatchH.Visible = "on";
                    end
                case "+"
                    obj.Lives = min(obj.Lives + 1, 5);
                    obj.updateLivesDisplay();
            end
            obj.addScore(50);
        end
    end

    % =================================================================
    % STATIC UTILITIES
    % =================================================================
    methods (Static, Access = private)
        function [sx, sy] = alienShapeVertices(aType, aw2, ah2)
            %alienShapeVertices  Return alien shape vertices by type.
            %   aType 1 = Crab, 2 = Squid, 3 = UFO dome
            %   aw2, ah2 = half-width, half-height
            if aType == 1
                % Crab: antenna ears on top, wide shoulders, zigzag legs
                sx = [-0.2, -0.5, -0.35, -0.9, -0.9, -0.5, -0.8, -0.35, 0, ...
                       0.35,  0.8,  0.5,  0.9,  0.9,  0.35,  0.5,  0.2] * aw2;
                sy = [-1, -0.4, -0.4, -0.15, 0.3, 0.25, 1, 0.55, 0.9, ...
                       0.55, 1, 0.25, 0.3, -0.15, -0.4, -0.4, -1] * ah2;
            elseif aType == 2
                % Squid: crown peak top, diamond body, dangling tentacles
                sx = [0, -0.4, -0.95, -0.85, -0.6, -0.25, -0.45, 0, ...
                      0.45,  0.25,  0.6,  0.85,  0.95,  0.4] * aw2;
                sy = [-1, -0.35, -0.1, 0.4, 1, 0.5, 1, 0.65, ...
                       1, 0.5, 1, 0.4, -0.1, -0.35] * ah2;
            else
                % UFO dome: wide rounded top, narrow waist, three legs
                sx = [-0.3, -0.7, -1, -1, -0.65, -0.45, -0.7, -0.3, 0, ...
                       0.3,  0.7,  0.45,  0.65,  1,  1,  0.7,  0.3] * aw2;
                sy = [-1, -0.8, -0.25, 0.2, 0.4, 0.3, 1, 0.55, 0.9, ...
                       0.55, 1, 0.3, 0.4, 0.2, -0.25, -0.8, -1] * ah2;
            end
        end
    end
end
