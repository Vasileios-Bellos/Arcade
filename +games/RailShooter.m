classdef RailShooter < engine.GameBase
    %RailShooter  Pseudo-3D rail shooter with wave-based progression.
    %   Enemies approach from a vanishing point. Crosshair auto-fires at the
    %   monster under the cursor. Four monster types with increasing HP.

    properties (Constant)
        Name = "Rail Shooter"
    end

    % =================================================================
    % COLOR CONSTANTS (not in GameBase)
    % =================================================================
    properties (Constant, Access = private)
        ColorOrange (1,3) double = [1, 0.6, 0.15]
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Monster array
        Monsters            struct = struct( ...
            "type", {}, "hp", {}, "maxHp", {}, ...
            "depth", {}, "speed", {}, ...
            "screenX", {}, "screenY", {}, ...
            "spawnX", {}, "spawnY", {}, ...
            "phase", {}, ...
            "shapeX", {}, "shapeY", {}, ...
            "hitFlash", {}, ...
            "defeated", {}, "defeatFrame", {}, ...
            "defeatMaxFrames", {}, ...
            "bodyPatchH", {}, "glowPatchH", {}, ...
            "detailH", {}, "eyesH", {}, ...
            "ribsH", {}, ...
            "hpBarBgH", {}, "hpBarFgH", {}, ...
            "hpBarBorderH", {}, ...
            "bossNameH", {})

        % Wave / spawning
        Wave                (1,1) double = 1
        Lives               (1,1) double = 3
        SpawnQueue          (1,:) double = []
        SpawnTimer          (1,1) double = 0
        SpawnInterval       (1,1) double = 60
        WavePause           (1,1) double = 0
        EliminatedCount           (1,1) double = 0

        % Damage system
        DamageCD            (1,1) double = 0
        DamageRate          (1,1) double = 7
        DamageFlashFrames   (1,1) double = 0
        DamageShakeFrames   (1,1) double = 0

        % Perspective
        BaseSize            (1,1) double = 12
        VanishPt            (1,2) double = [0, 0]
        OrigXLim            (1,2) double = [0 1]
        OrigYLim            (1,2) double = [0 1]

        % Animation
        FrameCount          (1,1) double = 0
        CrossPhase          (1,1) double = 0
        CrossHitFlash       (1,1) double = 0
        MuzzleFlashFrames   (1,1) double = 0
        LivesFlashTic       = []
        WaveFlashTic        = []
        GameOver            (1,1) logical = false
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        CrossH                          % line -- crosshair inner
        CrossGlowH                      % line -- crosshair glow
        CrossDotH                       % scatter -- center red dot
        CrossRingH                      % line -- rotating outer ring
        MuzzleFlashH                    % patch -- bottom muzzle flash
        GridLinesH                      % line array -- perspective grid
        GroundLineH                     % line -- ground plane indicator
        DamageFlashH                    % patch -- red damage flash
        LivesTextH                      % text -- lives flash display
        WaveTextH                       % text -- wave flash display
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create FPS rail shooter graphics and state.
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
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);

            % State reset
            obj.Wave = 1;
            obj.Lives = 3;
            obj.EliminatedCount = 0;
            obj.DamageCD = 0;
            obj.DamageFlashFrames = 0;
            obj.SpawnTimer = 0;
            obj.SpawnInterval = 60;
            obj.WavePause = 0;
            obj.BaseSize = max(8, round(min(areaW, areaH) * 0.06));
            obj.VanishPt = [mean(dx), mean(dy)];
            obj.LivesFlashTic = [];
            obj.WaveFlashTic = [];
            obj.CrossPhase = 0;
            obj.CrossHitFlash = 0;
            obj.MuzzleFlashFrames = 0;
            obj.DamageShakeFrames = 0;
            obj.FrameCount = 0;
            obj.OrigXLim = dx;
            obj.OrigYLim = dy;
            obj.GameOver = false;

            obj.Monsters = struct( ...
                "type", {}, "hp", {}, "maxHp", {}, ...
                "depth", {}, "speed", {}, ...
                "screenX", {}, "screenY", {}, ...
                "spawnX", {}, "spawnY", {}, ...
                "phase", {}, ...
                "shapeX", {}, "shapeY", {}, ...
                "hitFlash", {}, ...
                "defeated", {}, "defeatFrame", {}, ...
                "defeatMaxFrames", {}, ...
                "bodyPatchH", {}, "glowPatchH", {}, ...
                "detailH", {}, "eyesH", {}, ...
                "ribsH", {}, ...
                "hpBarBgH", {}, "hpBarFgH", {}, ...
                "hpBarBorderH", {}, ...
                "bossNameH", {});
            obj.SpawnQueue = [];

            % --- Perspective grid lines (depth atmosphere) ---
            vpX = obj.VanishPt(1);
            vpY = obj.VanishPt(2);
            gridAngles = [-0.6, -0.3, 0, 0.3, 0.6];
            nGrid = numel(gridAngles);
            obj.GridLinesH = gobjects(1, nGrid);
            groundY = dy(2) - areaH * 0.08;
            for g = 1:nGrid
                endX = vpX + gridAngles(g) * areaW;
                endY = groundY;
                obj.GridLinesH(g) = line(ax, [vpX, endX], [vpY, endY], ...
                    "Color", [0.25, 0.4, 0.5, 0.18], "LineWidth", 0.54 * obj.FontScale, ...
                    "LineStyle", "-", "Tag", "GT_railshooter");
            end

            % --- Ground plane indicator ---
            obj.GroundLineH = line(ax, [dx(1), dx(2)], [groundY, groundY], ...
                "Color", [0.45, 0.75, 0.85, 0.5], "LineWidth", 1.1 * obj.FontScale, ...
                "Tag", "GT_railshooter");

            % --- Crosshair: glow + inner cross + red center dot + ring ---
            obj.CrossGlowH = line(ax, NaN(1,8), NaN(1,8), ...
                "Color", [obj.ColorGold, 0.25], "LineWidth", 2.7 * obj.FontScale, "Tag", "GT_railshooter");
            obj.CrossH = line(ax, NaN(1,8), NaN(1,8), ...
                "Color", obj.ColorGold, "LineWidth", 0.81 * obj.FontScale, "Tag", "GT_railshooter");
            obj.CrossDotH = scatter(ax, NaN, NaN, 30, [1, 0.15, 0.1], ...
                "filled", "MarkerFaceAlpha", 0.95, "Tag", "GT_railshooter");
            obj.CrossRingH = scatter(ax, NaN, NaN, 6000, ...
                "MarkerEdgeColor", "r", "LineWidth", 1.5, ...
                "MarkerFaceColor", "none", "Tag", "GT_railshooter");

            % --- Muzzle flash (bottom-center, initially invisible) ---
            mfW = areaW * 0.12;
            mfH = areaH * 0.08;
            mfCx = mean(dx);
            mfBy = dy(2);
            obj.MuzzleFlashH = patch(ax, ...
                [mfCx - mfW/2, mfCx + mfW/2, mfCx + mfW*0.3, mfCx, mfCx - mfW*0.3], ...
                [mfBy, mfBy, mfBy - mfH*0.5, mfBy - mfH, mfBy - mfH*0.5], ...
                [1, 0.95, 0.6], "FaceAlpha", 0, "EdgeColor", "none", ...
                "Tag", "GT_railshooter");

            % --- Damage flash overlay (full-screen red, invisible) ---
            obj.DamageFlashH = patch(ax, ...
                [dx(1) dx(2) dx(2) dx(1)], [dy(1) dy(1) dy(2) dy(2)], ...
                obj.ColorRed, "FaceAlpha", 0, "EdgeColor", "none", ...
                "Tag", "GT_railshooter");

            % --- HUD: Lives (top-left with heart icon) ---
            livesStr = obj.livesString(obj.Lives);
            obj.LivesTextH = text(ax, dx(1) + 8, dy(2) - 8, ...
                livesStr, ...
                "Color", obj.ColorCyan, "FontSize", 5.9 * obj.FontScale, "FontWeight", "bold", ...
                "VerticalAlignment", "bottom", ...
                "Tag", "GT_railshooter");

            % --- HUD: Wave (top-center, bold) ---
            obj.WaveTextH = text(ax, mean(dx), dy(1) + 28, ...
                sprintf("WAVE %d", obj.Wave), ...
                "Color", obj.ColorGold, "FontSize", 7.6 * obj.FontScale, "FontWeight", "bold", ...
                "HorizontalAlignment", "center", "Tag", "GT_railshooter");
            obj.WaveFlashTic = tic;

            % Spawn first wave
            obj.buildSpawnWave(obj.Wave);
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame FPS rail shooter update.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end
            if obj.GameOver; return; end

            ds = obj.DtScale;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);
            vpX = obj.VanishPt(1);
            vpY = obj.VanishPt(2);
            obj.FrameCount = obj.FrameCount + 1;
            fc = obj.FrameCount;

            % --- Screen shake recovery ---
            if obj.DamageShakeFrames > 0
                obj.DamageShakeFrames = obj.DamageShakeFrames - ds;
                if obj.DamageShakeFrames <= 0
                    ax.XLim = obj.OrigXLim;
                    ax.YLim = obj.OrigYLim;
                else
                    shakeAmt = obj.DamageShakeFrames * 0.625;
                    jx = (rand - 0.5) * shakeAmt * 2;
                    jy = (rand - 0.5) * shakeAmt * 2;
                    ax.XLim = obj.OrigXLim + jx;
                    ax.YLim = obj.OrigYLim + jy;
                end
            end

            % --- Update crosshair ---
            if ~any(isnan(pos))
                crLen = max(5, round(min(areaW, areaH) * 0.04));
                gap = max(2, round(crLen * 0.3));
                breathScale = 1.0 + 0.06 * sin(fc * 0.2);
                crLen = round(crLen * breathScale);
                cx = pos(1); cy = pos(2);

                xd = [cx-crLen cx-gap NaN cx+gap cx+crLen NaN cx cx NaN cx cx];
                yd = [cy cy NaN cy cy NaN cy-crLen cy-gap NaN cy+gap cy+crLen];

                if obj.CrossHitFlash > 0
                    crossCol = obj.ColorRed;
                    crossGlowCol = [obj.ColorRed, 0.5];
                    obj.CrossHitFlash = obj.CrossHitFlash - ds;
                else
                    crossCol = obj.ColorGold;
                    crossGlowCol = [obj.ColorGold, 0.25];
                end

                if ~isempty(obj.CrossH) && isvalid(obj.CrossH)
                    obj.CrossH.XData = xd;
                    obj.CrossH.YData = yd;
                    obj.CrossH.Color = crossCol;
                end
                if ~isempty(obj.CrossGlowH) && isvalid(obj.CrossGlowH)
                    obj.CrossGlowH.XData = xd;
                    obj.CrossGlowH.YData = yd;
                    obj.CrossGlowH.Color = crossGlowCol;
                end
                if ~isempty(obj.CrossDotH) && isvalid(obj.CrossDotH)
                    obj.CrossDotH.XData = cx;
                    obj.CrossDotH.YData = cy;
                end
                if ~isempty(obj.CrossRingH) && isvalid(obj.CrossRingH)
                    obj.CrossRingH.XData = cx;
                    obj.CrossRingH.YData = cy;
                end
            end

            % --- Muzzle flash decay ---
            if obj.MuzzleFlashFrames > 0
                obj.MuzzleFlashFrames = obj.MuzzleFlashFrames - ds;
                if ~isempty(obj.MuzzleFlashH) && isvalid(obj.MuzzleFlashH)
                    t = obj.MuzzleFlashFrames / 10;
                    obj.MuzzleFlashH.FaceAlpha = max(0, min(1, t * 0.7));
                end
            end

            % --- Wave pause (between waves) ---
            if obj.WavePause > 0
                obj.WavePause = obj.WavePause - ds;
                if obj.WavePause <= 0
                    obj.Wave = obj.Wave + 1;
                    obj.buildSpawnWave(obj.Wave);
                    if ~isempty(obj.WaveTextH) && isvalid(obj.WaveTextH)
                        obj.WaveTextH.String = sprintf("WAVE %d", obj.Wave);
                        obj.WaveTextH.FontSize = 7.6 * obj.FontScale;
                        % Restore to top-center HUD position
                        obj.WaveTextH.Position(2) = dy(1) + 28;
                    end
                    obj.WaveFlashTic = tic;
                end
                % Flash wave text during pause
                if ~isempty(obj.WaveFlashTic) && ~isempty(obj.WaveTextH) ...
                        && isvalid(obj.WaveTextH)
                    elapsed = toc(obj.WaveFlashTic);
                    if elapsed < 1.7
                        alphaVal = 1;
                        if elapsed > 1.2
                            alphaVal = max(0, 1 - (elapsed - 1.2) / 0.5);
                        end
                        obj.WaveTextH.Color = [obj.ColorGold, alphaVal];
                    end
                end
            end

            % --- Spawn from queue (skip during wave pause) ---
            if obj.WavePause <= 0
                obj.SpawnTimer = obj.SpawnTimer + ds;
                if obj.SpawnTimer >= obj.SpawnInterval && ~isempty(obj.SpawnQueue)
                    obj.SpawnTimer = 0;
                    mType = obj.SpawnQueue(1);
                    obj.SpawnQueue(1) = [];
                    obj.spawnMonster(mType);
                end
            end

            % --- Update monsters ---
            anyAlive = false;
            k = 1;
            while k <= numel(obj.Monsters)
                m = obj.Monsters(k);

                % Defeat animation
                if m.defeated
                    m.defeatFrame = m.defeatFrame + ds;
                    progress = m.defeatFrame / m.defeatMaxFrames;
                    if progress >= 1
                        obj.deleteMonsterGraphics(k);
                        obj.Monsters(k) = [];
                        continue;
                    end

                    expandFactor = 1 + progress^0.7 * 2.5;
                    baseScale = obj.depthScale(m.depth);
                    scaleVal = expandFactor * baseScale;
                    defeatAlpha = max(0, min(1, (1 - min(progress, 1))^0.6));

                    jitterAmp = progress * baseScale * obj.BaseSize * 0.15;
                    jX = jitterAmp * (rand - 0.5);
                    jY = jitterAmp * (rand - 0.5);

                    sx = m.screenX + jX + m.shapeX * scaleVal * obj.BaseSize;
                    sy = m.screenY + jY + m.shapeY * scaleVal * obj.BaseSize;

                    if ~isempty(m.bodyPatchH) && isvalid(m.bodyPatchH)
                        m.bodyPatchH.XData = sx;
                        m.bodyPatchH.YData = sy;
                        if progress < 0.15
                            m.bodyPatchH.FaceColor = obj.ColorWhite;
                        elseif progress < 0.4
                            t = (progress - 0.15) / 0.25;
                            m.bodyPatchH.FaceColor = [1, 1 - t*0.3, 0.3*(1 - t)];
                        elseif progress < 0.7
                            t = (progress - 0.4) / 0.3;
                            m.bodyPatchH.FaceColor = [1 - t*0.3, 0.7 - t*0.5, 0];
                        else
                            m.bodyPatchH.FaceColor = [0.7, 0.2, 0];
                        end
                        m.bodyPatchH.FaceAlpha = max(0, 0.6 * defeatAlpha);
                        m.bodyPatchH.EdgeAlpha = min(1, defeatAlpha);
                    end
                    if ~isempty(m.glowPatchH) && isvalid(m.glowPatchH)
                        m.glowPatchH.XData = sx;
                        m.glowPatchH.YData = sy;
                        glowBoost = 1 + sin(progress * pi) * 0.5;
                        m.glowPatchH.FaceAlpha = max(0, 0.2 * defeatAlpha * glowBoost);
                        m.glowPatchH.EdgeAlpha = max(0, 0.6 * defeatAlpha);
                        m.glowPatchH.EdgeColor = [1, 0.7*(1 - progress), 0];
                    end


                    obj.hideMonsterDetails(m);
                    obj.Monsters(k) = m;
                    k = k + 1;
                    continue;
                end

                anyAlive = true;

                % Advance depth (approach player)
                m.depth = m.depth - m.speed * ds;
                m.phase = m.phase + 0.033 * ds;

                % Compute screen position (perspective projection)
                scaleVal = obj.depthScale(m.depth);
                m.screenX = vpX + (m.spawnX - vpX) * scaleVal;
                m.screenY = vpY + (m.spawnY - vpY) * scaleVal;

                % Interceptor zigzag
                if m.type == 3
                    zigzag = sin(m.phase * 2.5) * areaW * 0.05 * scaleVal;
                    m.screenX = m.screenX + zigzag;
                end

                % Reached player (depth past threshold)
                if m.depth <= -0.15
                    obj.playerDamage();
                    obj.deleteMonsterGraphics(k);
                    obj.Monsters(k) = [];
                    if obj.Lives <= 0
                        if obj.DamageShakeFrames > 0
                            ax.XLim = obj.OrigXLim;
                            ax.YLim = obj.OrigYLim;
                            obj.DamageShakeFrames = 0;
                        end
                        obj.GameOver = true;
                        obj.IsRunning = false;
                        return;
                    end
                    continue;
                end

                % Update body patch with type-specific animation
                bodySize = scaleVal * obj.BaseSize;
                depthAlpha = min(1, 0.4 + 0.6 * (1 - m.depth));

                switch m.type
                    case 1  % Fighter: banking drift
                        shamble = sin(m.phase * 1.2) * 0.04 * scaleVal;
                        sx = m.screenX + m.shapeX * bodySize + shamble * bodySize;
                        sy = m.screenY + m.shapeY * bodySize + ...
                             abs(sin(m.phase * 2.4)) * 0.02 * bodySize;
                    case 2  % Cruiser: steady sway
                        sway = sin(m.phase * 0.5) * 0.025 * scaleVal;
                        sx = m.screenX + m.shapeX * bodySize + sway * bodySize;
                        sy = m.screenY + m.shapeY * bodySize;
                    case 3  % Interceptor: rapid flutter
                        flutter = sin(m.phase * 6) * 0.015 * scaleVal;
                        sx = m.screenX + m.shapeX * bodySize + flutter * bodySize;
                        sy = m.screenY + m.shapeY * bodySize + ...
                             sin(m.phase * 8) * 0.01 * bodySize;
                    case 4  % Dreadnought: menacing scale breathing
                        breathFactor = 1 + 0.03 * sin(m.phase * 0.7);
                        sx = m.screenX + m.shapeX * bodySize * breathFactor;
                        sy = m.screenY + m.shapeY * bodySize * breathFactor;
                    otherwise
                        sx = m.screenX + m.shapeX * bodySize;
                        sy = m.screenY + m.shapeY * bodySize;
                end

                if ~isempty(m.bodyPatchH) && isvalid(m.bodyPatchH)
                    m.bodyPatchH.XData = sx;
                    m.bodyPatchH.YData = sy;
                    m.bodyPatchH.FaceAlpha = min(1, 0.45 * depthAlpha);
                    m.bodyPatchH.EdgeAlpha = min(1, depthAlpha);
                end
                if ~isempty(m.glowPatchH) && isvalid(m.glowPatchH)
                    m.glowPatchH.XData = sx;
                    m.glowPatchH.YData = sy;
                    m.glowPatchH.FaceAlpha = min(1, 0.12 * depthAlpha);
                    m.glowPatchH.EdgeAlpha = min(1, 0.5 * depthAlpha);
                end

                % Hit flash decay (white flash on damage)
                if m.hitFlash > 0
                    m.hitFlash = m.hitFlash - ds;
                    if ~isempty(m.bodyPatchH) && isvalid(m.bodyPatchH)
                        if m.hitFlash > 0
                            m.bodyPatchH.FaceColor = obj.ColorWhite;
                            m.bodyPatchH.FaceAlpha = 0.7;
                        else
                            m.bodyPatchH.FaceColor = obj.monsterColor(m.type);
                        end
                    end
                end

                % --- Inner detail lines update ---
                if ~isempty(m.ribsH)
                    validRibs = arrayfun(@(h) ~isempty(h) && isvalid(h), m.ribsH);
                    obj.updateDetailLines(m, bodySize, depthAlpha, validRibs);
                end

                % --- HP bar update ---
                barW = bodySize * 1.6;
                barH = max(2, bodySize * 0.14);
                if m.type == 4
                    barW = bodySize * 2.2;
                    barH = max(3, bodySize * 0.18);
                end
                barX = m.screenX - barW / 2;
                barY = m.screenY - bodySize * 1.4;
                if ~isempty(m.hpBarBgH) && isvalid(m.hpBarBgH)
                    m.hpBarBgH.XData = [barX, barX+barW, barX+barW, barX];
                    m.hpBarBgH.YData = [barY, barY, barY+barH, barY+barH];
                end
                hpFrac = max(0, m.hp / m.maxHp);
                if ~isempty(m.hpBarFgH) && isvalid(m.hpBarFgH)
                    m.hpBarFgH.XData = [barX, barX+barW*hpFrac, ...
                                        barX+barW*hpFrac, barX];
                    m.hpBarFgH.YData = [barY, barY, barY+barH, barY+barH];
                    if hpFrac > 0.5
                        m.hpBarFgH.FaceColor = obj.ColorGreen;
                    elseif hpFrac > 0.25
                        m.hpBarFgH.FaceColor = obj.ColorGold;
                    else
                        m.hpBarFgH.FaceColor = obj.ColorRed;
                    end
                end
                if ~isempty(m.hpBarBorderH) && isvalid(m.hpBarBorderH)
                    m.hpBarBorderH.XData = [barX, barX+barW, barX+barW, barX, barX];
                    m.hpBarBorderH.YData = [barY, barY, barY+barH, barY+barH, barY];
                    m.hpBarBorderH.Color = [obj.ColorWhite, 0.4 * depthAlpha];
                end

                % Boss name label above HP bar
                if m.type == 4 && ~isempty(m.bossNameH) && isvalid(m.bossNameH)
                    m.bossNameH.Position = [m.screenX, barY - 4, 0];
                    m.bossNameH.Color = [obj.ColorOrange, depthAlpha];
                end

                % Boss weak point (pulsing scatter)
                if m.type == 4 && ~isempty(m.detailH) && isvalid(m.detailH)
                    wpPulse = 0.2 + 0.08 * sin(m.phase * 3);
                    wpR = bodySize * wpPulse;
                    wpAlpha = (0.5 + 0.3 * sin(m.phase * 3)) * depthAlpha;
                    glowDiam = wpR * 2.5 * obj.FontScale;
                    m.detailH.XData = m.screenX;
                    m.detailH.YData = m.screenY;
                    m.detailH.SizeData = pi * (glowDiam/2)^2;
                    m.detailH.MarkerFaceAlpha = wpAlpha;
                end

                obj.Monsters(k) = m;
                k = k + 1;
            end

            % --- DPS: auto-fire damage (skip during wave pause) ---
            if obj.WavePause <= 0 && ~any(isnan(pos))
                obj.DamageCD = obj.DamageCD + ds;
                if obj.DamageCD >= obj.DamageRate
                    obj.DamageCD = 0;
                    obj.applyDamage(pos);
                end
            end

            % --- Damage flash decay ---
            if obj.DamageFlashFrames > 0
                obj.DamageFlashFrames = obj.DamageFlashFrames - ds;
                if ~isempty(obj.DamageFlashH) && isvalid(obj.DamageFlashH)
                    alphaVal = obj.DamageFlashFrames / 19;
                    obj.DamageFlashH.FaceAlpha = max(0, min(0.35, alphaVal * 0.35));
                end
            end

            % --- Lives flash ---
            if ~isempty(obj.LivesFlashTic) && ~isempty(obj.LivesTextH) ...
                    && isvalid(obj.LivesTextH)
                elapsed = toc(obj.LivesFlashTic);
                if elapsed < 1.0
                    if elapsed < 0.6
                        obj.LivesTextH.Color = obj.ColorRed;
                    else
                        alphaVal = max(0, 1 - (elapsed - 0.6) / 0.4);
                        obj.LivesTextH.Color = ...
                            [obj.ColorRed * alphaVal + obj.ColorCyan * (1 - alphaVal), 1];
                    end
                else
                    obj.LivesTextH.Color = obj.ColorCyan;
                    obj.LivesFlashTic = [];
                end
            end

            % --- Wave text flash ---
            if ~isempty(obj.WaveFlashTic) && ~isempty(obj.WaveTextH) ...
                    && isvalid(obj.WaveTextH)
                elapsed = toc(obj.WaveFlashTic);
                if elapsed < 1.7
                    alphaVal = 1;
                    if elapsed > 1.2
                        alphaVal = max(0, 1 - (elapsed - 1.2) / 0.5);
                    end
                    obj.WaveTextH.Color = [obj.ColorGold, alphaVal];
                else
                    obj.WaveTextH.Color = [obj.ColorGold, 0.5];
                    obj.WaveFlashTic = [];
                end
            end

            % --- Wave completion check (skip during wave pause) ---
            if obj.WavePause <= 0 && ~anyAlive && isempty(obj.SpawnQueue)
                aliveCount = 0;
                for j = 1:numel(obj.Monsters)
                    if ~obj.Monsters(j).defeated
                        aliveCount = aliveCount + 1;
                    end
                end
                if aliveCount == 0
                    obj.addScore(300 * obj.Wave);
                    obj.WavePause = 96;
                    if ~isempty(obj.WaveTextH) && isvalid(obj.WaveTextH)
                        obj.WaveTextH.String = "WAVE CLEARED!";
                        obj.WaveTextH.Color = [obj.ColorGreen, 1];
                        obj.WaveTextH.FontSize = 9.7 * obj.FontScale;
                        % Move to 35% from top so it does not overlap combo text
                        obj.WaveTextH.Position(2) = dy(1) + areaH * 0.35;
                    end
                    obj.WaveFlashTic = tic;
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all FPS rail shooter graphics.
            for k = 1:numel(obj.Monsters)
                obj.deleteMonsterGraphics(k);
            end
            obj.Monsters = struct( ...
                "type", {}, "hp", {}, "maxHp", {}, ...
                "depth", {}, "speed", {}, ...
                "screenX", {}, "screenY", {}, ...
                "spawnX", {}, "spawnY", {}, ...
                "phase", {}, ...
                "shapeX", {}, "shapeY", {}, ...
                "hitFlash", {}, ...
                "defeated", {}, "defeatFrame", {}, ...
                "defeatMaxFrames", {}, ...
                "bodyPatchH", {}, "glowPatchH", {}, ...
                "detailH", {}, "eyesH", {}, ...
                "ribsH", {}, ...
                "hpBarBgH", {}, "hpBarFgH", {}, ...
                "hpBarBorderH", {}, ...
                "bossNameH", {});
            obj.SpawnQueue = [];

            % Delete scalar HUD/crosshair handles
            scalarHandles = {obj.CrossH, obj.CrossGlowH, obj.CrossDotH, ...
                obj.CrossRingH, obj.MuzzleFlashH, ...
                obj.DamageFlashH, obj.LivesTextH, obj.WaveTextH, ...
                obj.GroundLineH};
            for j = 1:numel(scalarHandles)
                h = scalarHandles{j};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            % Delete grid lines array
            if ~isempty(obj.GridLinesH)
                for j = 1:numel(obj.GridLinesH)
                    if isvalid(obj.GridLinesH(j)); delete(obj.GridLinesH(j)); end
                end
            end
            obj.CrossH = []; obj.CrossGlowH = [];
            obj.CrossDotH = []; obj.CrossRingH = [];
            obj.MuzzleFlashH = [];
            obj.DamageFlashH = [];
            obj.LivesTextH = []; obj.WaveTextH = [];
            obj.GridLinesH = []; obj.GroundLineH = [];

            % Restore axes limits if screen shake was active
            if obj.DamageShakeFrames > 0
                ax = obj.Ax;
                if ~isempty(ax) && isvalid(ax)
                    ax.XLim = obj.OrigXLim;
                    ax.YLim = obj.OrigYLim;
                end
                obj.DamageShakeFrames = 0;
            end

            % Orphan guard
            engine.GameBase.deleteTaggedGraphics(obj.Ax, "^GT_railshooter");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  Handle key events for FPS rail shooter.
            %   No mode-specific keys currently.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return rail shooter results.
            r.Title = "RAIL SHOOTER";
            r.Lines = {
                sprintf("Wave: %d  |  Enemies Eliminated: %d", obj.Wave, obj.EliminatedCount)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS - wave spawning
    % =================================================================
    methods (Access = private)
        function buildSpawnWave(obj, waveNum)
            %buildSpawnWave  Build spawn queue for given wave number.
            switch waveNum
                case 1
                    q = [1 1 1 1 1 1];
                case 2
                    q = [1 1 3 1 1 3 1];
                case 3
                    q = [1 1 2 1 3 1 1 3];
                case 4
                    q = [1 2 3 1 2 3 1 1 3];
                case 5
                    q = [2 1 3 2 1 4 1 3 1 3];
                otherwise
                    nGrunt = 4 + floor(waveNum / 2);
                    nBrute = 1 + floor(waveNum / 3);
                    nSpeed = 1 + floor(waveNum / 2);
                    nBoss = floor(waveNum / 5);
                    q = [ones(1, nGrunt), 2*ones(1, nBrute), ...
                         3*ones(1, nSpeed), 4*ones(1, nBoss)];
                    q = q(randperm(numel(q)));
            end
            obj.SpawnQueue = q;
            obj.SpawnTimer = obj.SpawnInterval - 7;
            obj.SpawnInterval = max(29, 60 - waveNum * 5);
        end

        function spawnMonster(obj, mType)
            %spawnMonster  Create one monster at far depth with full visuals.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);
            vpX = obj.VanishPt(1);
            vpY = obj.VanishPt(2);

            % Random spawn position (spread around vanishing point)
            spawnX = vpX + (rand - 0.5) * areaW * 0.7;
            spawnY = vpY + (rand - 0.5) * areaH * 0.5;

            % Monster stats by type
            switch mType
                case 1; hp = 3;  spd = 0.003;  sizeMult = 1.0;
                case 2; hp = 8;  spd = 0.0018; sizeMult = 1.5;
                case 3; hp = 2;  spd = 0.0038; sizeMult = 0.7;
                case 4; hp = 25; spd = 0.0012; sizeMult = 2.2;
                otherwise; hp = 3; spd = 0.003;  sizeMult = 1.0;
            end

            % Scale HP with wave
            hp = hp + floor(obj.Wave / 3);

            % Shape vertices (normalized, centered at 0,0)
            [shapeX, shapeY] = games.RailShooter.monsterShape(mType);
            shapeX = shapeX * sizeMult;
            shapeY = shapeY * sizeMult;

            % Initial depth (far away)
            depthVal = 0.95 + rand * 0.05;
            scaleVal = obj.depthScale(depthVal);
            scrX = vpX + (spawnX - vpX) * scaleVal;
            scrY = vpY + (spawnY - vpY) * scaleVal;
            bodySize = scaleVal * obj.BaseSize;

            % Color
            faceCol = obj.monsterColor(mType);

            % Body patch
            mps = obj.FontScale;
            bodyPatchH = patch(ax, scrX + shapeX * bodySize, ...
                scrY + shapeY * bodySize, faceCol, ...
                "FaceAlpha", 0.4, "EdgeColor", faceCol, ...
                "LineWidth", 1.1 * mps, "Tag", "GT_railshooter");

            % Glow patch
            glowPatchH = patch(ax, scrX + shapeX * bodySize, ...
                scrY + shapeY * bodySize, faceCol, ...
                "FaceAlpha", 0.1, "EdgeColor", faceCol, ...
                "EdgeAlpha", 0.45, "LineWidth", 2.7 * mps, "Tag", "GT_railshooter");

            % No eyes for spaceship designs
            eyesH = gobjects(1, 0);

            % Inner detail lines
            ribsH = obj.createDetailLines(mType, scrX, scrY, bodySize, faceCol);

            % HP bar with border
            barW = bodySize * 1.6;
            barH = max(2, bodySize * 0.14);
            if mType == 4
                barW = bodySize * 2.2;
                barH = max(3, bodySize * 0.18);
            end
            barX = scrX - barW / 2;
            barY = scrY - bodySize * 1.4;
            hpBarBgH = patch(ax, [barX barX+barW barX+barW barX], ...
                [barY barY barY+barH barY+barH], [0.1 0.1 0.12], ...
                "FaceAlpha", 0.5, "EdgeColor", "none", "Tag", "GT_railshooter");
            hpBarFgH = patch(ax, [barX barX+barW barX+barW barX], ...
                [barY barY barY+barH barY+barH], obj.ColorGreen, ...
                "FaceAlpha", 0.85, "EdgeColor", "none", "Tag", "GT_railshooter");
            hpBarBorderH = line(ax, ...
                [barX, barX+barW, barX+barW, barX, barX], ...
                [barY, barY, barY+barH, barY+barH, barY], ...
                "Color", [obj.ColorWhite, 0.3], "LineWidth", 0.54 * mps, ...
                "Tag", "GT_railshooter");

            % Boss-specific extras
            detailH = [];
            bossNameH = [];
            if mType == 4
                wpR = bodySize * 0.25;
                glowDiam = wpR * 2.5 * mps;
                detailH = scatter(ax, scrX, scrY, pi * (glowDiam/2)^2, ...
                    obj.ColorRed, "filled", "MarkerFaceAlpha", 0.7, ...
                    "Tag", "GT_railshooter");
                bossNameH = text(ax, scrX, barY - 4, "DREADNOUGHT", ...
                    "Color", [obj.ColorOrange, 0.8], "FontSize", 4.3 * mps, ...
                    "FontWeight", "bold", "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "bottom", "Tag", "GT_railshooter");
            end

            % Type-specific defeat animation length
            defeatFrames = [36, 48, 24, 67];
            dmf = defeatFrames(min(mType, 4));

            m = struct("type", mType, "hp", hp, "maxHp", hp, ...
                "depth", depthVal, "speed", spd, ...
                "screenX", scrX, "screenY", scrY, ...
                "spawnX", spawnX, "spawnY", spawnY, ...
                "phase", rand * 2 * pi, ...
                "shapeX", shapeX, "shapeY", shapeY, ...
                "hitFlash", 0, ...
                "defeated", false, "defeatFrame", 0, ...
                "defeatMaxFrames", dmf, ...
                "bodyPatchH", bodyPatchH, "glowPatchH", glowPatchH, ...
                "detailH", detailH, "eyesH", eyesH, ...
                "ribsH", ribsH, ...
                "hpBarBgH", hpBarBgH, "hpBarFgH", hpBarFgH, ...
                "hpBarBorderH", hpBarBorderH, ...
                "bossNameH", bossNameH);

            if isempty(obj.Monsters)
                obj.Monsters = m;
            else
                obj.Monsters(end + 1) = m;
            end
        end
    end

    % =================================================================
    % PRIVATE METHODS - combat
    % =================================================================
    methods (Access = private)
        function applyDamage(obj, fingerPos)
            %applyDamage  Apply DPS damage to monster under crosshair.
            for k = 1:numel(obj.Monsters)
                m = obj.Monsters(k);
                if m.defeated; continue; end

                scaleVal = obj.depthScale(m.depth);
                hitR = scaleVal * obj.BaseSize * 1.2;

                dist = norm([fingerPos(1) - m.screenX, fingerPos(2) - m.screenY]);
                if dist < hitR
                    dmg = 1;
                    % Boss weak point: 3x damage if within inner circle
                    if m.type == 4
                        wpR = scaleVal * obj.BaseSize * 0.3;
                        if dist < wpR
                            dmg = 3;
                        end
                    end

                    m.hp = m.hp - dmg;
                    m.hitFlash = 10;
                    pts = 10 * dmg;
                    obj.addScore(pts);
                    obj.incrementCombo();

                    % Muzzle flash
                    obj.MuzzleFlashFrames = 10;
                    if ~isempty(obj.MuzzleFlashH) && isvalid(obj.MuzzleFlashH)
                        obj.MuzzleFlashH.FaceAlpha = 0.7;
                    end

                    % Crosshair hit indicator (turns red briefly)
                    obj.CrossHitFlash = 10;

                    % Hit sparks at monster position
                    hitDir = [fingerPos(1) - m.screenX, fingerPos(2) - m.screenY];
                    hitNrm = norm(hitDir);
                    if hitNrm > 0; hitDir = hitDir / hitNrm; end
                    obj.spawnBounceEffect([m.screenX, m.screenY], hitDir, pts, 5);

                    if m.hp <= 0
                        obj.defeatMonster(k, m);
                        return;
                    end

                    obj.Monsters(k) = m;
                    return;
                end
            end
            % Missed -- combo decays slowly
            if obj.Combo > 0
                obj.Combo = max(0, obj.Combo - 1);
            end
        end

        function defeatMonster(obj, idx, m)
            %defeatMonster  Start defeat animation with explosion.
            obj.EliminatedCount = obj.EliminatedCount + 1;

            basePoints = [100, 200, 150, 500];
            defeatPts = basePoints(min(m.type, 4)) * max(1, floor(obj.Combo / 5));
            obj.addScore(defeatPts);

            % Defeat explosion - single big red burst
            obj.spawnBounceEffect([m.screenX, m.screenY], [0, -1], defeatPts, 15);

            % Start defeat animation
            obj.Monsters(idx).defeated = true;
            obj.Monsters(idx).defeatFrame = 0;
            obj.Monsters(idx).hp = 0;

            obj.hideMonsterDetails(m);
        end

        function playerDamage(obj)
            %playerDamage  Monster reached the player -- lose a life.
            obj.Lives = obj.Lives - 1;
            obj.resetCombo();
            obj.DamageFlashFrames = 24;
            obj.DamageShakeFrames = 12;
            obj.LivesFlashTic = tic;

            if ~isempty(obj.DamageFlashH) && isvalid(obj.DamageFlashH)
                obj.DamageFlashH.FaceAlpha = 0.45;
            end
            if ~isempty(obj.LivesTextH) && isvalid(obj.LivesTextH)
                obj.LivesTextH.String = obj.livesString(max(0, obj.Lives));
            end
        end
    end

    % =================================================================
    % PRIVATE METHODS - monster graphics management
    % =================================================================
    methods (Access = private)
        function deleteMonsterGraphics(obj, idx)
            %deleteMonsterGraphics  Delete all graphics for one monster.
            m = obj.Monsters(idx);
            scalarH = {m.bodyPatchH, m.glowPatchH, m.detailH, ...
                       m.hpBarBgH, m.hpBarFgH, m.hpBarBorderH, m.bossNameH};
            for j = 1:numel(scalarH)
                h = scalarH{j};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            if ~isempty(m.eyesH)
                for j = 1:numel(m.eyesH)
                    if isvalid(m.eyesH(j)); delete(m.eyesH(j)); end
                end
            end
            if ~isempty(m.ribsH)
                for j = 1:numel(m.ribsH)
                    if isvalid(m.ribsH(j)); delete(m.ribsH(j)); end
                end
            end
        end

        function ribsH = createDetailLines(obj, mType, scrX, scrY, bodySize, faceCol)
            %createDetailLines  Create inner detail lines for a monster.
            ax = obj.Ax;
            dlps = obj.FontScale;
            detailAlpha = 0.3;
            switch mType
                case 1  % Fighter: center spine line
                    ribsH = gobjects(1, 1);
                    ribsH(1) = line(ax, ...
                        [scrX, scrX], ...
                        [scrY - 0.8 * bodySize, scrY + 0.5 * bodySize], ...
                        "Color", [faceCol, detailAlpha], "LineWidth", 0.54 * dlps, ...
                        "Tag", "GT_railshooter");
                case 2  % Cruiser: horizontal rib lines (3 ribs)
                    ribsH = gobjects(1, 4);
                    ribsH(1) = line(ax, ...
                        [scrX, scrX], ...
                        [scrY - 0.8 * bodySize, scrY + 0.4 * bodySize], ...
                        "Color", [faceCol, detailAlpha], "LineWidth", 0.81 * dlps, ...
                        "Tag", "GT_railshooter");
                    ribYs = [-0.15, 0.1, 0.3];
                    for r = 1:3
                        ribsH(r + 1) = line(ax, ...
                            [scrX - 0.5 * bodySize, scrX + 0.5 * bodySize], ...
                            [scrY + ribYs(r) * bodySize, scrY + ribYs(r) * bodySize], ...
                            "Color", [faceCol, detailAlpha], "LineWidth", 0.54 * dlps, ...
                            "Tag", "GT_railshooter");
                    end
                case 3  % Interceptor: wing strut lines
                    ribsH = gobjects(1, 2);
                    ribsH(1) = line(ax, ...
                        [scrX - 0.1 * bodySize, scrX - 0.6 * bodySize], ...
                        [scrY - 0.2 * bodySize, scrY - 0.5 * bodySize], ...
                        "Color", [faceCol, detailAlpha * 1.2], "LineWidth", 0.54 * dlps, ...
                        "Tag", "GT_railshooter");
                    ribsH(2) = line(ax, ...
                        [scrX + 0.1 * bodySize, scrX + 0.6 * bodySize], ...
                        [scrY - 0.2 * bodySize, scrY - 0.5 * bodySize], ...
                        "Color", [faceCol, detailAlpha * 1.2], "LineWidth", 0.54 * dlps, ...
                        "Tag", "GT_railshooter");
                case 4  % Dreadnought: cross pattern (spine + shoulder line)
                    ribsH = gobjects(1, 2);
                    ribsH(1) = line(ax, ...
                        [scrX, scrX], ...
                        [scrY - 0.85 * bodySize, scrY + 0.6 * bodySize], ...
                        "Color", [faceCol, detailAlpha], "LineWidth", 1.1 * dlps, ...
                        "Tag", "GT_railshooter");
                    ribsH(2) = line(ax, ...
                        [scrX - 0.5 * bodySize, scrX + 0.5 * bodySize], ...
                        [scrY - 0.2 * bodySize, scrY - 0.2 * bodySize], ...
                        "Color", [faceCol, detailAlpha], "LineWidth", 0.81 * dlps, ...
                        "Tag", "GT_railshooter");
                otherwise
                    ribsH = gobjects(1, 0);
            end
        end

        function updateDetailLines(obj, m, bodySize, depthAlpha, validMask)
            %updateDetailLines  Update positions of inner detail lines per frame.
            faceCol = obj.monsterColor(m.type);
            detailAlpha = 0.35 * depthAlpha;
            switch m.type
                case 1  % Spine
                    if validMask(1)
                        m.ribsH(1).XData = [m.screenX, m.screenX];
                        m.ribsH(1).YData = [m.screenY - 0.8 * bodySize, ...
                                            m.screenY + 0.5 * bodySize];
                        m.ribsH(1).Color = [faceCol, detailAlpha];
                    end
                case 2  % Spine + 3 ribs
                    if validMask(1)
                        m.ribsH(1).XData = [m.screenX, m.screenX];
                        m.ribsH(1).YData = [m.screenY - 0.8 * bodySize, ...
                                            m.screenY + 0.4 * bodySize];
                        m.ribsH(1).Color = [faceCol, detailAlpha];
                    end
                    ribYs = [-0.15, 0.1, 0.3];
                    halfW = 0.5 * bodySize;
                    for r = 1:3
                        ribIdx = r + 1;
                        if ribIdx <= numel(validMask) && validMask(ribIdx)
                            ry = m.screenY + ribYs(r) * bodySize;
                            m.ribsH(ribIdx).XData = [m.screenX - halfW, m.screenX + halfW];
                            m.ribsH(ribIdx).YData = [ry, ry];
                            m.ribsH(ribIdx).Color = [faceCol, detailAlpha];
                        end
                    end
                case 3  % Wing struts
                    if validMask(1)
                        m.ribsH(1).XData = [m.screenX - 0.1 * bodySize, ...
                                            m.screenX - 0.6 * bodySize];
                        m.ribsH(1).YData = [m.screenY - 0.2 * bodySize, ...
                                            m.screenY - 0.5 * bodySize];
                        m.ribsH(1).Color = [faceCol, detailAlpha * 1.2];
                    end
                    if numel(validMask) >= 2 && validMask(2)
                        m.ribsH(2).XData = [m.screenX + 0.1 * bodySize, ...
                                            m.screenX + 0.6 * bodySize];
                        m.ribsH(2).YData = [m.screenY - 0.2 * bodySize, ...
                                            m.screenY - 0.5 * bodySize];
                        m.ribsH(2).Color = [faceCol, detailAlpha * 1.2];
                    end
                case 4  % Spine + shoulder
                    if validMask(1)
                        m.ribsH(1).XData = [m.screenX, m.screenX];
                        m.ribsH(1).YData = [m.screenY - 0.85 * bodySize, ...
                                            m.screenY + 0.6 * bodySize];
                        m.ribsH(1).Color = [faceCol, detailAlpha];
                    end
                    if numel(validMask) >= 2 && validMask(2)
                        m.ribsH(2).XData = [m.screenX - 0.5 * bodySize, ...
                                            m.screenX + 0.5 * bodySize];
                        m.ribsH(2).YData = [m.screenY - 0.2 * bodySize, ...
                                            m.screenY - 0.2 * bodySize];
                        m.ribsH(2).Color = [faceCol, detailAlpha];
                    end
            end
        end

        function hideMonsterDetails(~, m)
            %hideMonsterDetails  Hide eyes, ribs, detail, HP bar, boss name.
            if ~isempty(m.eyesH)
                for eIdx = 1:numel(m.eyesH)
                    if isvalid(m.eyesH(eIdx)); m.eyesH(eIdx).Visible = "off"; end
                end
            end
            if ~isempty(m.ribsH)
                for rIdx = 1:numel(m.ribsH)
                    if isvalid(m.ribsH(rIdx)); m.ribsH(rIdx).Visible = "off"; end
                end
            end
            if ~isempty(m.detailH) && isvalid(m.detailH)
                m.detailH.Visible = "off";
            end
            if ~isempty(m.hpBarBgH) && isvalid(m.hpBarBgH)
                m.hpBarBgH.Visible = "off";
            end
            if ~isempty(m.hpBarFgH) && isvalid(m.hpBarFgH)
                m.hpBarFgH.Visible = "off";
            end
            if ~isempty(m.hpBarBorderH) && isvalid(m.hpBarBorderH)
                m.hpBarBorderH.Visible = "off";
            end
            if ~isempty(m.bossNameH) && isvalid(m.bossNameH)
                m.bossNameH.Visible = "off";
            end
        end
    end

    % =================================================================
    % PRIVATE METHODS - utility
    % =================================================================
    methods (Access = private)
        function col = monsterColor(obj, mType)
            %monsterColor  Return face color for ship type.
            switch mType
                case 1; col = obj.ColorCyan;
                case 2; col = obj.ColorRed;
                case 3; col = obj.ColorMagenta;
                case 4; col = [1.0, 0.5, 0.0];
                otherwise; col = obj.ColorCyan;
            end
        end

        function scaleVal = depthScale(~, depthVal)
            %depthScale  Compute visual scale from depth [0,1].
            %   depth=1 is far (tiny), depth=0 is near (full size).
            scaleVal = 0.15 + (1 - depthVal) * 0.85;
        end
    end

    % =================================================================
    % STATIC METHODS
    % =================================================================
    methods (Static, Access = private)
        function [sx, sy] = monsterShape(mType)
            %monsterShape  Return normalized shape vertices for ship type.
            %   Centered at (0,0), roughly unit-sized. Y negative = nose.
            switch mType
                case 1  % Fighter -- sleek arrowhead with swept wings
                    sx = [0 -0.15 -0.25 -0.65 -0.45 -0.2 -0.15 0 ...
                          0.15 0.2 0.45 0.65 0.25 0.15];
                    sy = [-1 -0.65 -0.4 0.1 0.3 0 0.5 0.8 ...
                          0.5 0 0.3 0.1 -0.4 -0.65];
                case 2  % Cruiser -- wide hull
                    sx = [-0.15 -0.3 -0.4 -0.3 -0.45 -0.85 -0.9 -0.75 ...
                          -0.6 -0.7 -0.5 -0.4 -0.3 -0.1 0.1 0.3 0.4 ...
                          0.5 0.7 0.6 0.75 0.9 0.85 0.45 0.3 0.4 0.3 0.15];
                    sy = [-1 -0.9 -0.6 -0.45 -0.4 -0.3 -0.05 0.1 ...
                          0.2 0.35 0.3 0.4 0.6 0.95 0.95 0.6 0.4 ...
                          0.3 0.35 0.2 0.1 -0.05 -0.3 -0.4 -0.45 -0.6 -0.9 -1];
                case 3  % Interceptor -- fast with wings
                    sx = [0 -0.2 -0.4 -0.25 -0.8 -1 -0.6 ...
                          -0.3 -0.15 0 0.15 0.3 ...
                          0.6 1 0.8 0.25 0.4 0.2];
                    sy = [-1 -0.8 -0.9 -0.5 -0.3 0.05 0.2 ...
                          0.3 0.65 0.95 0.65 0.3 ...
                          0.2 0.05 -0.3 -0.5 -0.9 -0.8];
                case 4  % Dreadnought -- capital ship
                    sx = [0 -0.15 -0.3 -0.25 -0.2 -0.3 -0.4 ...
                          -0.7 -0.85 -0.75 -0.55 -0.45 -0.6 -0.5 -0.35 ...
                          -0.4 -0.3 -0.15 0.15 0.3 0.4 ...
                          0.35 0.5 0.6 0.45 0.55 0.75 0.85 0.7 ...
                          0.4 0.3 0.2 0.25 0.3 0.15];
                    sy = [-1 -0.95 -1 -0.75 -0.6 -0.5 -0.4 ...
                          -0.3 -0.1 0.1 0.15 0.25 0.35 0.3 0.2 ...
                          0.4 0.7 0.95 0.95 0.7 0.4 ...
                          0.2 0.3 0.35 0.25 0.15 0.1 -0.1 -0.3 ...
                          -0.4 -0.5 -0.6 -0.75 -1 -0.95];
                otherwise
                    sx = [-0.3 -0.3 0.3 0.3];
                    sy = [0.5 -0.5 -0.5 0.5];
            end
        end

        function s = livesString(nLives)
            %livesString  Format lives display string with heart symbols.
            hearts = repmat(char(9829), 1, max(0, nLives));
            s = sprintf("HP: %s", hearts);
        end
    end
end
