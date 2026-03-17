classdef FlappyBird < GameBase
    %FlappyBird  Pipe-dodge game controlled by finger position.
    %   Navigate a bird through scrolling pipe gaps. Combo resets on
    %   collision (no lives). Gap narrows and speed increases as combo
    %   grows. Collision triggers invulnerability blink.
    %
    %   Standalone: games.FlappyBird().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Flappy Bird"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Bird geometry
        BirdRadius      (1,1) double = 8
        CollisionR      (1,1) double = 4

        % Pipe parameters — ring buffer of pre-allocated patches
        PipePoolTop                 % cell array of top patch handles
        PipePoolBot                 % cell array of bottom patch handles
        PoolSize        (1,1) double = 6   % max pipes on screen + buffer
        PipeIdx                     % ring indices of active pipes (FIFO)
        PipeX                       % x position per pool slot
        PipeGapY                    % gap center Y per pool slot
        PipeGapHSlot                % gap height per pool slot
        PipeScored                  % scored flag per pool slot

        PipeSpeed       (1,1) double = 1.5
        PipeBaseSpeed   (1,1) double = 1.5
        PipeTargetSpeed (1,1) double = 1.5   % speed decays toward this after hit
        PipeSpeedDecay  (1,1) double = 0.005 % linear ramp per frame (slow)
        PipeWidth       (1,1) double = 20
        PipeGapH        (1,1) double = 40
        PipeBaseGapH    (1,1) double = 40
        PipeSpacing     (1,1) double = 60

        % Session
        PipesCleared    (1,1) double = 0
        InvulnFrames    (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BirdCoreH                   % scatter -- bird core
        BirdGlowH                   % scatter -- bird glow
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create pipe-dodge graphics and initialize state.
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

            % Scale sizes to display area
            obj.BirdRadius = max(6, round(min(areaW, areaH) * 0.06));

            % Collision radius: convert scatter core size (points) to data
            % units so collision matches what the player sees on screen.
            coreSD = (max(8, obj.BirdRadius * 2))^2;  % SizeData in pts^2
            coreDiamPts = 2 * sqrt(coreSD / pi);
            axPos = getpixelposition(ax);
            pxPerUnit = axPos(3) / areaW;
            dpi = get(groot, "ScreenPixelsPerInch");
            obj.CollisionR = coreDiamPts / 2 * (dpi / 72) / pxPerUnit;

            obj.PipeWidth = max(12, round(areaW * 0.08));
            obj.PipeGapH = max(35, round(areaH * 0.35));
            obj.PipeBaseGapH = obj.PipeGapH;
            obj.PipeSpacing = max(40, round(areaW * 0.35));
            obj.PipeBaseSpeed = max(0.8, areaW * 0.008);
            obj.PipeSpeed = obj.PipeBaseSpeed;
            obj.PipeTargetSpeed = obj.PipeBaseSpeed;

            % Reset session state
            obj.PipesCleared = 0;
            obj.InvulnFrames = 0;

            % Pre-allocate pipe patch pool (no patch() calls during play)
            nPool = obj.PoolSize;
            obj.PipePoolTop = cell(1, nPool);
            obj.PipePoolBot = cell(1, nPool);
            obj.PipeX       = nan(1, nPool);
            obj.PipeGapY    = nan(1, nPool);
            obj.PipeGapHSlot = nan(1, nPool);
            obj.PipeScored  = false(1, nPool);
            obj.PipeIdx     = [];   % active slot indices (FIFO order)

            offX = [-10, -10, -10, -10];  % off-screen placeholder
            offY = [-10, -10, -10, -10];
            for k = 1:nPool
                obj.PipePoolTop{k} = patch(ax, ...
                    "XData", offX, "YData", offY, ...
                    "FaceColor", obj.ColorGreen, "FaceAlpha", 0.15, ...
                    "EdgeColor", obj.ColorGreen, "LineWidth", 1.5, ...
                    "Visible", "off", "Tag", "GT_flappy");
                obj.PipePoolBot{k} = patch(ax, ...
                    "XData", offX, "YData", offY, ...
                    "FaceColor", obj.ColorGreen, "FaceAlpha", 0.15, ...
                    "EdgeColor", obj.ColorGreen, "LineWidth", 1.5, ...
                    "Visible", "off", "Tag", "GT_flappy");
            end

            % Create bird graphics (2-layer: glow + core)
            cx = mean(dx);
            cy = mean(dy);
            glowSize = max(15, obj.BirdRadius * 4);
            coreSize = max(8, obj.BirdRadius * 2);

            obj.BirdGlowH = scatter(ax, cx, cy, glowSize^2, ...
                obj.ColorCyan, "filled", "MarkerFaceAlpha", 0.25, ...
                "Tag", "GT_flappy");
            obj.BirdCoreH = scatter(ax, cx, cy, coreSize^2, ...
                obj.ColorCyan, "filled", "Tag", "GT_flappy");

            % Spawn first pipe with initial offset
            obj.spawnPipe(dx(2) + obj.PipeSpacing * 0.5);
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame pipe-dodge logic.
            if any(isnan(pos)); return; end
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            cr = obj.CollisionR;
            pw = obj.PipeWidth;
            active = obj.PipeIdx;

            % ---- Bird position (clamped to display) ----
            bx = max(dx(1) + cr, min(dx(2) - cr, pos(1)));
            by = max(dy(1) + cr, min(dy(2) - cr, pos(2)));
            if ~isempty(obj.BirdCoreH) && isvalid(obj.BirdCoreH)
                obj.BirdCoreH.XData = bx;
                obj.BirdCoreH.YData = by;
            end
            if ~isempty(obj.BirdGlowH) && isvalid(obj.BirdGlowH)
                obj.BirdGlowH.XData = bx;
                obj.BirdGlowH.YData = by;
            end

            % ---- Smooth speed toward target (ramp up and decay down) ----
            if obj.PipeSpeed ~= obj.PipeTargetSpeed
                step = obj.PipeSpeedDecay * obj.PipeSpeed;
                if obj.PipeSpeed < obj.PipeTargetSpeed
                    obj.PipeSpeed = min(obj.PipeTargetSpeed, obj.PipeSpeed + step);
                else
                    obj.PipeSpeed = max(obj.PipeTargetSpeed, obj.PipeSpeed - step);
                end
            end

            % ---- Move active pipes left ----
            spd = obj.PipeSpeed;
            for j = 1:numel(active)
                s = active(j);
                obj.PipeX(s) = obj.PipeX(s) - spd;
                px = obj.PipeX(s);
                xd = [px, px + pw, px + pw, px];
                obj.PipePoolTop{s}.XData = xd;
                obj.PipePoolBot{s}.XData = xd;
            end

            % ---- Recycle pipes that exited left ----
            while ~isempty(active) && obj.PipeX(active(1)) + pw < dx(1)
                s = active(1);
                obj.PipePoolTop{s}.Visible = "off";
                obj.PipePoolBot{s}.Visible = "off";
                active(1) = [];
            end
            obj.PipeIdx = active;

            % ---- Spawn new pipes (reuses pool slot) ----
            if isempty(active)
                obj.spawnPipe(dx(2));
                active = obj.PipeIdx;
            elseif obj.PipeX(active(end)) < dx(2) - obj.PipeSpacing
                obj.spawnPipe(dx(2));
                active = obj.PipeIdx;
            end

            % ---- Invulnerability blink ----
            if obj.InvulnFrames > 0
                obj.InvulnFrames = obj.InvulnFrames - 1;
                vis = "off";
                if mod(obj.InvulnFrames, 8) < 4; vis = "on"; end
                if ~isempty(obj.BirdCoreH) && isvalid(obj.BirdCoreH)
                    obj.BirdCoreH.Visible = vis;
                end
                if ~isempty(obj.BirdGlowH) && isvalid(obj.BirdGlowH)
                    obj.BirdGlowH.Visible = vis;
                end
                if obj.InvulnFrames == 0
                    if ~isempty(obj.BirdCoreH) && isvalid(obj.BirdCoreH)
                        obj.BirdCoreH.CData = obj.ColorCyan;
                        obj.BirdCoreH.Visible = "on";
                    end
                    if ~isempty(obj.BirdGlowH) && isvalid(obj.BirdGlowH)
                        obj.BirdGlowH.CData = obj.ColorCyan;
                        obj.BirdGlowH.Visible = "on";
                    end
                end
            else
                % ---- Collision detection ----
                for j = 1:numel(active)
                    s = active(j);
                    px = obj.PipeX(s);
                    if bx + cr > px && bx - cr < px + pw
                        gapTop = obj.PipeGapY(s) - obj.PipeGapHSlot(s) / 2;
                        gapBot = obj.PipeGapY(s) + obj.PipeGapHSlot(s) / 2;
                        if by - cr < gapTop || by + cr > gapBot
                            obj.loseLife([bx, by]);
                            return;
                        end
                    end
                end
            end

            % ---- Mark pipes passed during invulnerability (no points) ----
            if obj.InvulnFrames > 0
                for j = 1:numel(active)
                    s = active(j);
                    if ~obj.PipeScored(s)
                        if obj.PipeX(s) + pw / 2 < bx
                            obj.PipeScored(s) = true;
                        end
                    end
                end
            end

            % ---- Score pipe passes (normal state only) ----
            if obj.InvulnFrames <= 0
                for j = 1:numel(active)
                    s = active(j);
                    if ~obj.PipeScored(s)
                        if obj.PipeX(s) + pw / 2 < bx
                            obj.PipeScored(s) = true;
                            obj.PipesCleared = obj.PipesCleared + 1;
                            obj.incrementCombo();
                            totalPts = round(100 * obj.comboMultiplier());
                            obj.addScore(totalPts);

                            % Scaling — set target, speed ramps smoothly
                            obj.PipeTargetSpeed = obj.PipeBaseSpeed ...
                                * (1 + 0.06 * obj.Combo);
                            obj.PipeGapH = max(obj.CollisionR * 8, ...
                                obj.PipeBaseGapH * max(0.25, ...
                                1 - 0.05 * obj.Combo));

                            % Flash scored pipe gold
                            obj.PipePoolTop{s}.EdgeColor = obj.ColorGold;
                            obj.PipePoolBot{s}.EdgeColor = obj.ColorGold;
                        end
                    end
                end
            end

        end

        function onCleanup(obj)
            %onCleanup  Delete all flappy bird graphics.
            handles = {obj.BirdCoreH, obj.BirdGlowH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.BirdCoreH = [];
            obj.BirdGlowH = [];

            for k = 1:numel(obj.PipePoolTop)
                h = obj.PipePoolTop{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            for k = 1:numel(obj.PipePoolBot)
                h = obj.PipePoolBot{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.PipePoolTop = {};
            obj.PipePoolBot = {};
            obj.PipeIdx = [];

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_flappy");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for flappy bird.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return flappy-bird-specific results.
            r.Title = "FLAPPY BIRD";
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            r.Lines = {
                sprintf("Pipes: %d  |  Score: %d  |  Time: %.0fs  |  Max Combo: %d", ...
                    obj.PipesCleared, obj.Score, elapsed, obj.MaxCombo)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function spawnPipe(obj, spawnX)
            %spawnPipe  Activate an idle pool slot as a new pipe at spawnX.
            dy = obj.DisplayRange.Y;
            pw = obj.PipeWidth;
            gapH = obj.PipeGapH;

            % Find an idle pool slot (not in active list)
            allSlots = 1:obj.PoolSize;
            idle = setdiff(allSlots, obj.PipeIdx);
            if isempty(idle); return; end
            s = idle(1);

            % Random gap Y (constrained so both pipe halves are visible)
            minPipeH = gapH * 0.3;
            gapMinY = dy(1) + gapH / 2 + minPipeH;
            gapMaxY = dy(2) - gapH / 2 - minPipeH;
            gapY = gapMinY + rand * (gapMaxY - gapMinY);
            gapTop = gapY - gapH / 2;
            gapBot = gapY + gapH / 2;

            % Store state
            obj.PipeX(s)       = spawnX;
            obj.PipeGapY(s)    = gapY;
            obj.PipeGapHSlot(s) = gapH;
            obj.PipeScored(s)  = false;

            % Update patch geometry (no allocation — just property sets)
            xd = [spawnX, spawnX + pw, spawnX + pw, spawnX];
            obj.PipePoolTop{s}.XData = xd;
            obj.PipePoolTop{s}.YData = [dy(1) - 10, dy(1) - 10, gapTop, gapTop];
            obj.PipePoolTop{s}.EdgeColor = obj.ColorGreen;
            obj.PipePoolTop{s}.Visible = "on";

            obj.PipePoolBot{s}.XData = xd;
            obj.PipePoolBot{s}.YData = [gapBot, gapBot, dy(2) + 10, dy(2) + 10];
            obj.PipePoolBot{s}.EdgeColor = obj.ColorGreen;
            obj.PipePoolBot{s}.Visible = "on";

            % Append to active list (rightmost = newest)
            obj.PipeIdx(end + 1) = s;
        end

        function loseLife(obj, birdPos)
            %loseLife  Handle pipe collision -- reset combo, decay speed to base.
            obj.resetCombo();
            obj.PipeGapH = obj.PipeBaseGapH;
            obj.PipeTargetSpeed = obj.PipeBaseSpeed;

            % Red burst at bird
            obj.spawnBounceEffect(birdPos, [0, -1], 0, 15);

            % Red flash + invulnerability (bird blinks through pipes)
            obj.InvulnFrames = 40;
            if ~isempty(obj.BirdCoreH) && isvalid(obj.BirdCoreH)
                obj.BirdCoreH.CData = obj.ColorRed;
            end
            if ~isempty(obj.BirdGlowH) && isvalid(obj.BirdGlowH)
                obj.BirdGlowH.CData = obj.ColorRed;
            end
        end
    end
end
