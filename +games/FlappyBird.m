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

        % Pipe parameters
        Pipes           struct = struct("x", {}, "gapY", {}, "gapH", {}, ...
                                        "topH", {}, "botH", {}, "scored", {})
        PipeSpeed       (1,1) double = 1.5
        PipeBaseSpeed   (1,1) double = 1.5
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
            obj.BirdRadius = max(10, round(min(areaW, areaH) * 0.15));

            % Collision radius: convert scatter core size (points) to data
            % units so collision matches what the player sees on screen.
            coreSD = (max(8, obj.BirdRadius * 2))^2;  % SizeData in pts^2
            coreDiamPts = 2 * sqrt(coreSD / pi);
            axPos = getpixelposition(ax);
            pxPerUnit = axPos(3) / areaW;
            dpi = get(groot, "ScreenPixelsPerInch");
            obj.CollisionR = coreDiamPts / 2 * (dpi / 72) / pxPerUnit;

            obj.PipeWidth = max(12, round(areaW * 0.08));
            obj.PipeGapH = max(35, round(areaH * 0.55));
            obj.PipeBaseGapH = obj.PipeGapH;
            obj.PipeSpacing = max(40, round(areaW * 0.35));
            obj.PipeBaseSpeed = max(0.8, areaW * 0.008);
            obj.PipeSpeed = obj.PipeBaseSpeed;

            % Reset session state
            obj.PipesCleared = 0;
            obj.InvulnFrames = 0;
            obj.Pipes = struct("x", {}, "gapY", {}, "gapH", {}, ...
                "topH", {}, "botH", {}, "scored", {});

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

            % ---- Move pipes left ----
            spd = obj.PipeSpeed;
            for k = 1:numel(obj.Pipes)
                obj.Pipes(k).x = obj.Pipes(k).x - spd;
                px = obj.Pipes(k).x;
                xd = [px, px + pw, px + pw, px];
                if ~isempty(obj.Pipes(k).topH) && isvalid(obj.Pipes(k).topH)
                    obj.Pipes(k).topH.XData = xd;
                end
                if ~isempty(obj.Pipes(k).botH) && isvalid(obj.Pipes(k).botH)
                    obj.Pipes(k).botH.XData = xd;
                end
            end

            % ---- Remove pipes that exited left ----
            while ~isempty(obj.Pipes) && obj.Pipes(1).x + pw < dx(1)
                if ~isempty(obj.Pipes(1).topH) && isvalid(obj.Pipes(1).topH)
                    delete(obj.Pipes(1).topH);
                end
                if ~isempty(obj.Pipes(1).botH) && isvalid(obj.Pipes(1).botH)
                    delete(obj.Pipes(1).botH);
                end
                obj.Pipes(1) = [];
            end

            % ---- Spawn new pipes ----
            if isempty(obj.Pipes) || obj.Pipes(end).x < dx(2) - obj.PipeSpacing
                obj.spawnPipe(dx(2));
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
                    % Restore bird color after invulnerability ends
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
                for k = 1:numel(obj.Pipes)
                    p = obj.Pipes(k);
                    if bx + cr > p.x && bx - cr < p.x + pw
                        gapTop = p.gapY - p.gapH / 2;
                        gapBot = p.gapY + p.gapH / 2;
                        if by - cr < gapTop || by + cr > gapBot
                            obj.loseLife([bx, by]);
                            return;
                        end
                    end
                end
            end

            % ---- Mark pipes passed during invulnerability (no points) ----
            if obj.InvulnFrames > 0
                for k = 1:numel(obj.Pipes)
                    if ~obj.Pipes(k).scored
                        pipeCX = obj.Pipes(k).x + pw / 2;
                        if pipeCX < bx
                            obj.Pipes(k).scored = true;
                        end
                    end
                end
            end

            % ---- Score pipe passes (normal state only) ----
            if obj.InvulnFrames <= 0
                for k = 1:numel(obj.Pipes)
                    if ~obj.Pipes(k).scored
                        pipeCX = obj.Pipes(k).x + pw / 2;
                        if pipeCX < bx
                            obj.Pipes(k).scored = true;
                            obj.PipesCleared = obj.PipesCleared + 1;
                            obj.incrementCombo();
                            totalPts = round(100 * obj.comboMultiplier());
                            obj.addScore(totalPts);

                            % Aggressive scaling
                            obj.PipeSpeed = obj.PipeBaseSpeed ...
                                * (1 + 0.12 * obj.Combo);
                            obj.PipeGapH = max(obj.CollisionR * 8, ...
                                obj.PipeBaseGapH * max(0.25, ...
                                1 - 0.05 * obj.Combo));

                            % Flash scored pipe gold
                            if ~isempty(obj.Pipes(k).topH) && isvalid(obj.Pipes(k).topH)
                                obj.Pipes(k).topH.EdgeColor = obj.ColorGold;
                            end
                            if ~isempty(obj.Pipes(k).botH) && isvalid(obj.Pipes(k).botH)
                                obj.Pipes(k).botH.EdgeColor = obj.ColorGold;
                            end
                        end
                    end
                end
            end

            % ---- Animate hit effects ----
            obj.updateHitEffects();
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

            for k = 1:numel(obj.Pipes)
                if ~isempty(obj.Pipes(k).topH) && isvalid(obj.Pipes(k).topH)
                    delete(obj.Pipes(k).topH);
                end
                if ~isempty(obj.Pipes(k).botH) && isvalid(obj.Pipes(k).botH)
                    delete(obj.Pipes(k).botH);
                end
            end
            obj.Pipes = struct("x", {}, "gapY", {}, "gapH", {}, ...
                "topH", {}, "botH", {}, "scored", {});

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
            %spawnPipe  Create a new pipe pair at spawnX.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dy = obj.DisplayRange.Y;
            pw = obj.PipeWidth;
            gapH = obj.PipeGapH;

            % Random gap Y (constrained so both pipe halves are visible)
            minPipeH = gapH * 0.3;
            gapMinY = dy(1) + gapH / 2 + minPipeH;
            gapMaxY = dy(2) - gapH / 2 - minPipeH;
            gapY = gapMinY + rand * (gapMaxY - gapMinY);
            gapTop = gapY - gapH / 2;
            gapBot = gapY + gapH / 2;

            % Extend top/bottom edges beyond screen so outer edges are
            % invisible (10px overshoot).
            topPatch = patch(ax, ...
                "XData", [spawnX, spawnX + pw, spawnX + pw, spawnX], ...
                "YData", [dy(1) - 10, dy(1) - 10, gapTop, gapTop], ...
                "FaceColor", obj.ColorGreen, "FaceAlpha", 0.15, ...
                "EdgeColor", obj.ColorGreen, "LineWidth", 1.5, ...
                "Tag", "GT_flappy");
            botPatch = patch(ax, ...
                "XData", [spawnX, spawnX + pw, spawnX + pw, spawnX], ...
                "YData", [gapBot, gapBot, dy(2) + 10, dy(2) + 10], ...
                "FaceColor", obj.ColorGreen, "FaceAlpha", 0.15, ...
                "EdgeColor", obj.ColorGreen, "LineWidth", 1.5, ...
                "Tag", "GT_flappy");

            obj.Pipes(end + 1) = struct("x", spawnX, "gapY", gapY, ...
                "gapH", gapH, "topH", topPatch, "botH", botPatch, ...
                "scored", false);
        end

        function loseLife(obj, birdPos)
            %loseLife  Handle pipe collision -- reset combo + gap, keep speed.
            obj.resetCombo();
            obj.PipeGapH = obj.PipeBaseGapH;

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
