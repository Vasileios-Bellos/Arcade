classdef Juggler < engine.GameBase
    %Juggler  Gravity-based ball juggling game with flick physics.
    %   Keep the ball in the air by flicking it with your cursor. Gravity
    %   pulls the ball down; dropping it past the bottom edge resets combo.
    %   Extra balls spawn at combo milestones (every 10).
    %
    %   Standalone: games.Juggler().play()
    %   Hosted:     Arcade hosts via init/onUpdate/onCleanup
    %
    %   See also engine.GameBase, Arcade

    properties (Constant)
        Name = "Juggler"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Main ball
        BallPos         (1,2) double = [NaN, NaN]
        BallVel         (1,2) double = [0, 0]
        BallRadius      (1,1) double = 10
        HitRadius       (1,1) double = 22
        Gravity         (1,1) double = 0.0625
        Friction        (1,1) double = 0.9992
        Restitution     (1,1) double = 0.75
        BallPhase       (1,1) double = 0
        Alive           (1,1) logical = false

        % Finger tracking
        PrevFingerPos   (1,2) double = [NaN, NaN]
        FingerVelBuf    (:,2) double = zeros(5, 2)
        FingerVelIdx    (1,1) double = 0
        FlickLocked     (1,1) logical = false

        % Trail
        TrailBufX       (1,:) double
        TrailBufY       (1,:) double
        TrailIdx        (1,1) double = 0
        TrailLen        (1,1) double = 30

        % Display scaling
        SpeedScale      (1,1) double = 1               % visual speed normalization: 180/minDim

        % Stats
        Bounces         (1,1) double = 0
        Flicks          (1,1) double = 0   % session total (for results)
        BallFlicks      (1,1) double = 0   % current main ball's flick count
        BestStreak      (1,1) double = 0   % longest single-ball flick streak
        MaxSpeed        (1,1) double = 0
        Drops           (1,1) double = 0
        LastFlickTic    uint64

        % Extra balls (spawned at combo milestones)
        ExtraBallPos        double = zeros(0, 2)
        ExtraBallVel        double = zeros(0, 2)
        ExtraBallLocked     logical = logical.empty(0, 1)
        ExtraBallFlicks     double = zeros(0, 1)
        ExtraBallTrailBufX  cell = {}
        ExtraBallTrailBufY  cell = {}
        ExtraBallTrailIdx   double = zeros(0, 1)
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        % Main ball graphics
        BallCoreH
        BallGlowH
        BallAuraH
        BallTrailH
        BallTrailGlowH
        BallInfoTextH
        DeathLineH

        % Extra ball graphics (cell arrays)
        ExtraBallCoreH      cell = {}
        ExtraBallGlowH      cell = {}
        ExtraBallAuraH      cell = {}
        ExtraBallTrailH     cell = {}
        ExtraBallTrailGlowH cell = {}
        ExtraBallInfoTextH  cell = {}
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize juggle state.
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
            cx = mean(dx);
            cy = mean(dy);

            % Scale to display area (tuned for ~180px minDim)
            areaH = diff(dy);
            areaW = diff(dx);
            obj.Gravity = max(0.021, areaH * 0.000417);
            obj.BallRadius = max(5, round(min(areaH, areaW) * 0.042));
            obj.HitRadius = max(10, round(obj.BallRadius * 2.2));

            % Visual speed normalization (like Pong's SpeedScale pattern)
            obj.SpeedScale = 180 / min(areaW, areaH);

            % Initialize state
            obj.BallPos = [cx, cy * 0.7];
            obj.BallVel = [0, 0];
            obj.Alive = true;
            obj.Bounces = 0;
            obj.Flicks = 0;
            obj.BallFlicks = 0;
            obj.BestStreak = 0;
            obj.Drops = 0;
            obj.MaxSpeed = 0;
            obj.BallPhase = 0;
            obj.PrevFingerPos = [NaN, NaN];
            obj.FingerVelBuf = zeros(5, 2);
            obj.FingerVelIdx = 0;
            obj.FlickLocked = false;
            obj.LastFlickTic = tic;
            obj.removeAllExtraBalls();

            obj.TrailBufX = NaN(1, obj.TrailLen);
            obj.TrailBufY = NaN(1, obj.TrailLen);
            obj.TrailIdx = 0;

            % --- Graphics ---
            r = obj.BallRadius;
            obj.BallTrailGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.12], "LineWidth", 4.3 * obj.FontScale, ...
                "Tag", "GT_juggle");
            obj.BallTrailH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.5], "LineWidth", 1.35 * obj.FontScale, ...
                "Tag", "GT_juggle");
            obj.BallAuraH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.15], "Marker", ".", ...
                "MarkerSize", 54 * obj.FontScale, "LineStyle", "none", "Tag", "GT_juggle");
            glowSize = r * 2.5 * obj.FontScale;
            obj.BallGlowH = scatter(ax, cx, cy*0.7, pi * (glowSize/2)^2, ...
                obj.ColorCyan, "filled", "MarkerFaceAlpha", 0.4, "Tag", "GT_juggle");
            obj.BallCoreH = line(ax, cx, cy*0.7, ...
                "Color", [1, 1, 1, 1], "Marker", ".", "MarkerSize", 20 * obj.FontScale, ...
                "LineStyle", "none", "Tag", "GT_juggle");
            obj.BallInfoTextH = text(ax, cx, cy*0.7 - r - 14, "HIT ME UP!", ...
                "Color", [obj.ColorCyan, 0.8], "FontSize", 6.5 * obj.FontScale, "FontWeight", "bold", ...
                "HorizontalAlignment", "center", "VerticalAlignment", "bottom", ...
                "Tag", "GT_juggle");

            % Danger line at bottom
            dangerY = dy(2) - 5;
            obj.DeathLineH = line(ax, [dx(1), dx(2)], [dangerY, dangerY], ...
                "Color", [obj.ColorRed, 0.25], "LineWidth", 1.1 * obj.FontScale, ...
                "LineStyle", "--", "Tag", "GT_juggle");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame juggle physics, flick detection, and rendering.

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % --- 1. Finger velocity buffer ---
            if ~any(isnan(pos)) && ~any(isnan(obj.PrevFingerPos))
                fvel = pos - obj.PrevFingerPos;
                bufIdx = mod(obj.FingerVelIdx, 5) + 1;
                obj.FingerVelBuf(bufIdx, :) = fvel;
                obj.FingerVelIdx = bufIdx;
            end
            obj.PrevFingerPos = pos;

            % --- 2. Average finger velocity ---
            nFilled = min(obj.FingerVelIdx, 5);
            if nFilled >= 1
                avgVel = mean(obj.FingerVelBuf(1:nFilled, :), 1);
            else
                avgVel = [0, 0];
            end

            % --- 3. Main ball contact detection ---
            %   After flicking, lock persists until mouse has been outside
            %   the hit radius for at least one frame (prevents double-flick
            %   when ball bounces back toward stationary mouse).
            if ~any(isnan(pos)) && ~any(isnan(obj.BallPos))
                distToBall = norm(pos - obj.BallPos);
                inside = distToBall <= obj.HitRadius;
                if inside && ~obj.FlickLocked
                    obj.flickBall(avgVel);
                    obj.FlickLocked = true;
                    obj.LastFlickTic = tic;
                elseif ~inside && obj.FlickLocked && toc(obj.LastFlickTic) > 0.15
                    obj.FlickLocked = false;
                end
            else
                obj.FlickLocked = false;
            end

            % --- 4. Apply gravity (positive = down in YDir=reverse) ---
            ds = obj.DtScale;
            obj.BallVel(2) = obj.BallVel(2) + obj.Gravity * ds;

            % --- 5. Move ball ---
            prePos = obj.BallPos;
            stepVel = obj.BallVel * ds;
            obj.BallPos = obj.BallPos + stepVel;
            obj.BallVel = obj.BallVel * obj.Friction ^ ds;

            % --- 6. Wall collisions: TOP, LEFT, RIGHT only ---
            bounced = false;
            bouncePos = obj.BallPos;
            bounceNormal = [0, 0];

            if obj.BallPos(2) < dy(1) && stepVel(2) ~= 0
                tContact = min(1, max(0, (dy(1) - prePos(2)) / stepVel(2)));
                obj.BallPos(1) = prePos(1) + tContact * stepVel(1);
                obj.BallPos(2) = dy(1);
                obj.BallVel(2) = -obj.BallVel(2) * obj.Restitution;
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [0, 1];
            end
            if obj.BallPos(1) < dx(1) && stepVel(1) ~= 0
                tContact = min(1, max(0, (dx(1) - prePos(1)) / stepVel(1)));
                obj.BallPos(2) = prePos(2) + tContact * stepVel(2);
                obj.BallPos(1) = dx(1);
                obj.BallVel(1) = -obj.BallVel(1) * obj.Restitution;
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [1, 0];
            end
            if obj.BallPos(1) > dx(2) && stepVel(1) ~= 0
                tContact = min(1, max(0, (dx(2) - prePos(1)) / stepVel(1)));
                obj.BallPos(2) = prePos(2) + tContact * stepVel(2);
                obj.BallPos(1) = dx(2);
                obj.BallVel(1) = -obj.BallVel(1) * obj.Restitution;
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [-1, 0];
            end

            if bounced
                obj.Bounces = obj.Bounces + 1;
                obj.spawnBounceEffect(bouncePos, bounceNormal, 0, norm(obj.BallVel) * obj.SpeedScale);
            end

            % --- 7. Extra ball physics + contact ---
            obj.updateExtraBalls(pos, avgVel);

            % --- 8. Bottom edge = main ball dropped ---
            if obj.BallPos(2) > dy(2) + obj.BallRadius
                obj.BestStreak = max(obj.BestStreak, obj.BallFlicks);
                obj.spawnHitEffect(obj.BallPos, obj.ColorRed, 0);
                obj.resetCombo();
                obj.Drops = obj.Drops + 1;

                nExtras = size(obj.ExtraBallPos, 1);
                if nExtras > 0
                    % Promote first extra ball to main
                    obj.BallPos = obj.ExtraBallPos(1, :);
                    obj.BallVel = obj.ExtraBallVel(1, :);
                    obj.TrailBufX = obj.ExtraBallTrailBufX{1};
                    obj.TrailBufY = obj.ExtraBallTrailBufY{1};
                    obj.TrailIdx = obj.ExtraBallTrailIdx(1);
                    obj.FlickLocked = obj.ExtraBallLocked(1);
                    obj.BallFlicks = obj.ExtraBallFlicks(1);
                    obj.removeExtraBall(1);
                else
                    % No balls left — respawn at center top
                    obj.BallPos = [mean(dx), dy(1) + diff(dy) * 0.3];
                    obj.BallVel = [0, 0];
                    obj.TrailBufX(:) = NaN;
                    obj.TrailBufY(:) = NaN;
                    obj.TrailIdx = 0;
                    obj.FlickLocked = false;
                    obj.BallFlicks = 0;
                end
            end

            % --- 9. Stats ---
            ballSpeed = norm(obj.BallVel);
            obj.MaxSpeed = max(obj.MaxSpeed, ballSpeed);

            % --- 10. Trail buffer ---
            tidx = mod(obj.TrailIdx, obj.TrailLen) + 1;
            obj.TrailBufX(tidx) = obj.BallPos(1);
            obj.TrailBufY(tidx) = obj.BallPos(2);
            obj.TrailIdx = tidx;

            % --- 11. Animation + render ---
            obj.BallPhase = obj.BallPhase + 0.0333 * ds;
            obj.renderBall();

            % --- 12. Danger line pulse ---
            obj.renderDeathLine();

        end

        function onCleanup(obj)
            %onCleanup  Delete all juggle graphics.
            handles = {obj.BallCoreH, obj.BallGlowH, obj.BallAuraH, ...
                       obj.BallTrailH, obj.BallTrailGlowH, ...
                       obj.BallInfoTextH, obj.DeathLineH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.BallCoreH = [];
            obj.BallGlowH = [];
            obj.BallAuraH = [];
            obj.BallTrailH = [];
            obj.BallTrailGlowH = [];
            obj.BallInfoTextH = [];
            obj.DeathLineH = [];

            obj.removeAllExtraBalls();

            % Orphan guard
            engine.GameBase.deleteTaggedGraphics(obj.Ax, "^GT_juggle");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for juggling.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return juggling-specific results.
            r.Title = "JUGGLER";
            % Capture current ball's streak before results
            bestStreak = max(obj.BestStreak, obj.BallFlicks);
            r.Lines = {
                sprintf("Total Flicks: %d  |  Best Flick Streak: %d", ...
                    obj.Flicks, bestStreak)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS — MAIN BALL
    % =================================================================
    methods (Access = private)

        function flickBall(obj, fingerVel)
            %flickBall  Apply bounce velocity to main ball from finger contact.
            fingerSpeed = norm(fingerVel);
            if fingerSpeed > 1.0 / obj.SpeedScale
                % Active flick — finger velocity drives the ball
                obj.BallVel = fingerVel * 1.3;
            else
                % Natural bounce — reflect downward velocity off finger
                bounceVy = -abs(obj.BallVel(2)) * obj.Restitution;
                minBounce = -obj.Gravity * 20;
                obj.BallVel(2) = min(bounceVy, minBounce);
                obj.BallVel(1) = obj.BallVel(1) * 0.8;
            end
            hitSpeed = norm(obj.BallVel);

            % Clear trail on hit
            obj.TrailBufX(:) = NaN;
            obj.TrailBufY(:) = NaN;
            obj.TrailIdx = 0;

            obj.BallFlicks = obj.BallFlicks + 1;
            obj.scoreFlick(obj.BallPos, hitSpeed);

            % Reset finger velocity buffer
            obj.FingerVelBuf(:) = 0;
            obj.FingerVelIdx = 0;
        end

        function scoreFlick(obj, hitPos, hitSpeed)
            %scoreFlick  Shared scoring for main + extra ball hits.
            obj.Flicks = obj.Flicks + 1;
            obj.MaxSpeed = max(obj.MaxSpeed, hitSpeed);
            obj.LastFlickTic = tic;

            obj.incrementCombo();

            % Spawn extra ball at every multiple of 10 combo
            if obj.Combo >= 10 && mod(obj.Combo, 10) == 0
                obj.spawnExtraBall();
            end

            flickPoints = round((20 + hitSpeed * 3) * max(1, obj.Combo * 0.5));
            obj.addScore(flickPoints);

            clr = obj.flickSpeedColor(hitSpeed * obj.SpeedScale);
            obj.spawnHitEffect(hitPos + [0, 4], clr, flickPoints, obj.BallRadius + 5);
        end

        function renderBall(obj)
            %renderBall  Update main ball graphics based on current state.
            if any(isnan(obj.BallPos)); return; end
            bx = obj.BallPos(1);
            by = obj.BallPos(2);
            ballSpeed = norm(obj.BallVel);
            r = obj.BallRadius;
            clr = obj.flickSpeedColor(ballSpeed * obj.SpeedScale);

            % Core dot
            if ~isempty(obj.BallCoreH) && isvalid(obj.BallCoreH)
                obj.BallCoreH.XData = bx;
                obj.BallCoreH.YData = by;
            end
            % Glow ring
            if ~isempty(obj.BallGlowH) && isvalid(obj.BallGlowH)
                obj.BallGlowH.XData = bx;
                obj.BallGlowH.YData = by;
                obj.BallGlowH.CData = clr;
            end
            % Aura
            if ~isempty(obj.BallAuraH) && isvalid(obj.BallAuraH)
                obj.BallAuraH.XData = bx;
                obj.BallAuraH.YData = by;
                auraScale = 1 + min(1.5, ballSpeed * 0.08);
                obj.BallAuraH.MarkerSize = 54 * auraScale * obj.FontScale;
                obj.BallAuraH.Color = [clr, 0.12];
            end
            % Trail
            if obj.TrailIdx > 0
                n = obj.TrailLen;
                order = mod((obj.TrailIdx:obj.TrailIdx + n - 1), n) + 1;
                tx = obj.TrailBufX(order);
                ty = obj.TrailBufY(order);
                firstValid = find(~isnan(tx), 1, "first");
                if ~isempty(firstValid)
                    tx = tx(firstValid:end);
                    ty = ty(firstValid:end);
                end
                gps = obj.FontScale;
                trailAlpha = min(0.6, 0.2 + ballSpeed * 0.04);
                trailWidth = min(2.2 * gps, (0.8 + ballSpeed * 0.08) * gps);
                if ~isempty(obj.BallTrailH) && isvalid(obj.BallTrailH)
                    set(obj.BallTrailH, "XData", tx, "YData", ty, ...
                        "Color", [clr, trailAlpha], "LineWidth", trailWidth);
                end
                if ~isempty(obj.BallTrailGlowH) && isvalid(obj.BallTrailGlowH)
                    set(obj.BallTrailGlowH, "XData", tx, "YData", ty, ...
                        "Color", [clr, trailAlpha * 0.25], "LineWidth", trailWidth * 3);
                end
            else
                if ~isempty(obj.BallTrailH) && isvalid(obj.BallTrailH)
                    obj.BallTrailH.XData = NaN;
                    obj.BallTrailH.YData = NaN;
                end
                if ~isempty(obj.BallTrailGlowH) && isvalid(obj.BallTrailGlowH)
                    obj.BallTrailGlowH.XData = NaN;
                    obj.BallTrailGlowH.YData = NaN;
                end
            end
            % Info text
            if ~isempty(obj.BallInfoTextH) && isvalid(obj.BallInfoTextH)
                elapsed = 0;
                if ~isempty(obj.StartTic)
                    elapsed = toc(obj.StartTic);
                end
                obj.BallInfoTextH.String = sprintf("%.1fs  |  %d flicks", elapsed, obj.BallFlicks);
                obj.BallInfoTextH.Position = [bx, by - r - 14, 0];
                obj.BallInfoTextH.Color = [clr, 0.7];
            end
        end

        function renderDeathLine(obj)
            %renderDeathLine  Pulse the bottom danger line based on ball proximity.
            if isempty(obj.DeathLineH) || ~isvalid(obj.DeathLineH); return; end
            dy = obj.DisplayRange.Y;
            if ~any(isnan(obj.BallPos))
                proximity = (obj.BallPos(2) - dy(1)) / diff(dy);
                pulseAlpha = 0.1 + 0.5 * max(0, min(1, (proximity - 0.5) / 0.5));
                pulseAlpha = pulseAlpha + 0.08 * sin(obj.BallPhase * 3);
                obj.DeathLineH.Color = [obj.ColorRed, max(0, min(1, pulseAlpha))];
            end
        end
    end

    % =================================================================
    % PRIVATE METHODS — EXTRA BALLS
    % =================================================================
    methods (Access = private)

        function spawnExtraBall(obj)
            %spawnExtraBall  Add an extra ball with full graphics.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % Random position in upper quarter
            xPos = dx(1) + rand() * diff(dx);
            yPos = dy(1) + diff(dy) * 0.25 * rand();

            obj.ExtraBallPos(end+1, :) = [xPos, yPos];
            obj.ExtraBallVel(end+1, :) = [0, 0];
            obj.ExtraBallLocked(end+1) = false;
            obj.ExtraBallFlicks(end+1) = 0;

            % Trail buffers
            obj.ExtraBallTrailBufX{end+1} = NaN(1, obj.TrailLen);
            obj.ExtraBallTrailBufY{end+1} = NaN(1, obj.TrailLen);
            obj.ExtraBallTrailIdx(end+1) = 0;

            r = obj.BallRadius;
            ps = obj.FontScale;
            glowSize = r * 2.5 * ps;

            % Graphics (same z-order as main ball)
            eps_ = obj.FontScale;
            trailGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.12], "LineWidth", 4.3 * eps_, ...
                "Tag", "GT_juggle");
            trailH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.5], "LineWidth", 1.35 * eps_, ...
                "Tag", "GT_juggle");
            auraH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.15], "Marker", ".", ...
                "MarkerSize", 54 * eps_, "LineStyle", "none", ...
                "Tag", "GT_juggle");
            glowH = scatter(ax, xPos, yPos, pi * (glowSize/2)^2, ...
                obj.ColorCyan, "filled", "MarkerFaceAlpha", 0.4, ...
                "Tag", "GT_juggle");
            coreH = line(ax, xPos, yPos, ...
                "Color", [1, 1, 1, 1], "Marker", ".", "MarkerSize", 20 * eps_, ...
                "LineStyle", "none", "Tag", "GT_juggle");
            infoH = text(ax, xPos, yPos - r - 14, "", ...
                "Color", [obj.ColorCyan, 0.8], "FontSize", 6.5 * eps_, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", "Tag", "GT_juggle");

            obj.ExtraBallTrailGlowH{end+1} = trailGlowH;
            obj.ExtraBallTrailH{end+1} = trailH;
            obj.ExtraBallAuraH{end+1} = auraH;
            obj.ExtraBallGlowH{end+1} = glowH;
            obj.ExtraBallCoreH{end+1} = coreH;
            obj.ExtraBallInfoTextH{end+1} = infoH;
        end

        function updateExtraBalls(obj, fingerPos, avgVel)
            %updateExtraBalls  Physics, contact, and rendering for extra balls.
            nExtra = size(obj.ExtraBallPos, 1);
            if nExtra == 0; return; end
            ds = obj.DtScale;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            r = obj.BallRadius;
            n = obj.TrailLen;
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            toRemove = [];

            for bi = 1:nExtra
                % Contact detection
                if ~any(isnan(fingerPos))
                    distToExtra = norm(fingerPos - obj.ExtraBallPos(bi, :));
                    if distToExtra <= obj.HitRadius
                        if ~obj.ExtraBallLocked(bi)
                            fspeed = norm(avgVel);
                            if fspeed > 1.0 / obj.SpeedScale
                                obj.ExtraBallVel(bi, :) = avgVel * 1.3;
                            else
                                bounceVy = -abs(obj.ExtraBallVel(bi, 2)) * obj.Restitution;
                                minBounce = -obj.Gravity * 20;
                                obj.ExtraBallVel(bi, 2) = min(bounceVy, minBounce);
                                obj.ExtraBallVel(bi, 1) = obj.ExtraBallVel(bi, 1) * 0.8;
                            end
                            extraSpeed = norm(obj.ExtraBallVel(bi, :));
                            obj.ExtraBallFlicks(bi) = obj.ExtraBallFlicks(bi) + 1;
                            obj.scoreFlick(obj.ExtraBallPos(bi, :), extraSpeed);
                            % Clear trail on hit
                            obj.ExtraBallTrailBufX{bi}(:) = NaN;
                            obj.ExtraBallTrailBufY{bi}(:) = NaN;
                            obj.ExtraBallTrailIdx(bi) = 0;
                            obj.ExtraBallLocked(bi) = true;
                        end
                    else
                        obj.ExtraBallLocked(bi) = false;
                    end
                else
                    obj.ExtraBallLocked(bi) = false;
                end

                % Gravity
                obj.ExtraBallVel(bi, 2) = obj.ExtraBallVel(bi, 2) + obj.Gravity * ds;

                % Move
                obj.ExtraBallPos(bi, :) = obj.ExtraBallPos(bi, :) + obj.ExtraBallVel(bi, :) * ds;
                obj.ExtraBallVel(bi, :) = obj.ExtraBallVel(bi, :) * obj.Friction ^ ds;

                % Wall collisions (top, left, right)
                if obj.ExtraBallPos(bi, 2) < dy(1)
                    obj.ExtraBallPos(bi, 2) = dy(1);
                    obj.ExtraBallVel(bi, 2) = -obj.ExtraBallVel(bi, 2) * obj.Restitution;
                end
                if obj.ExtraBallPos(bi, 1) < dx(1)
                    obj.ExtraBallPos(bi, 1) = dx(1);
                    obj.ExtraBallVel(bi, 1) = -obj.ExtraBallVel(bi, 1) * obj.Restitution;
                end
                if obj.ExtraBallPos(bi, 1) > dx(2)
                    obj.ExtraBallPos(bi, 1) = dx(2);
                    obj.ExtraBallVel(bi, 1) = -obj.ExtraBallVel(bi, 1) * obj.Restitution;
                end

                % Bottom death — remove this extra, reset combo
                if obj.ExtraBallPos(bi, 2) > dy(2) + r
                    obj.BestStreak = max(obj.BestStreak, obj.ExtraBallFlicks(bi));
                    obj.spawnHitEffect(obj.ExtraBallPos(bi, :), obj.ColorRed, 0);
                    obj.resetCombo();
                    obj.Drops = obj.Drops + 1;
                    toRemove(end + 1) = bi; %#ok<AGROW>
                    continue;
                end

                % Trail buffer
                tidx = mod(obj.ExtraBallTrailIdx(bi), n) + 1;
                obj.ExtraBallTrailBufX{bi}(tidx) = obj.ExtraBallPos(bi, 1);
                obj.ExtraBallTrailBufY{bi}(tidx) = obj.ExtraBallPos(bi, 2);
                obj.ExtraBallTrailIdx(bi) = tidx;

                % --- Render extra ball ---
                bx = obj.ExtraBallPos(bi, 1);
                by = obj.ExtraBallPos(bi, 2);
                extraSpeed = norm(obj.ExtraBallVel(bi, :));
                clr = obj.flickSpeedColor(extraSpeed * obj.SpeedScale);

                % Core
                h = obj.ExtraBallCoreH{bi};
                if ~isempty(h) && isvalid(h)
                    h.XData = bx;
                    h.YData = by;
                end
                % Glow ring
                h = obj.ExtraBallGlowH{bi};
                if ~isempty(h) && isvalid(h)
                    h.XData = bx;
                    h.YData = by;
                    h.CData = clr;
                end
                % Aura
                h = obj.ExtraBallAuraH{bi};
                if ~isempty(h) && isvalid(h)
                    h.XData = bx;
                    h.YData = by;
                    auraScale = 1 + min(1.5, extraSpeed * 0.08);
                    h.MarkerSize = 54 * auraScale * obj.FontScale;
                    h.Color = [clr, 0.12];
                end
                % Trail
                tIdx = obj.ExtraBallTrailIdx(bi);
                if tIdx > 0
                    order = mod((tIdx:tIdx + n - 1), n) + 1;
                    tx = obj.ExtraBallTrailBufX{bi}(order);
                    ty = obj.ExtraBallTrailBufY{bi}(order);
                    fv = find(~isnan(tx), 1, "first");
                    if ~isempty(fv)
                        tx = tx(fv:end);
                        ty = ty(fv:end);
                    end
                    egps = obj.FontScale;
                    trailAlpha = min(0.6, 0.2 + extraSpeed * 0.04);
                    trailWidth = min(2.2 * egps, (0.8 + extraSpeed * 0.08) * egps);
                    h = obj.ExtraBallTrailH{bi};
                    if ~isempty(h) && isvalid(h)
                        set(h, "XData", tx, "YData", ty, ...
                            "Color", [clr, trailAlpha], "LineWidth", trailWidth);
                    end
                    h = obj.ExtraBallTrailGlowH{bi};
                    if ~isempty(h) && isvalid(h)
                        set(h, "XData", tx, "YData", ty, ...
                            "Color", [clr, trailAlpha * 0.25], "LineWidth", trailWidth * 3);
                    end
                end
                % Info text
                h = obj.ExtraBallInfoTextH{bi};
                if ~isempty(h) && isvalid(h)
                    h.String = sprintf("%.1fs  |  %d flicks", elapsed, obj.ExtraBallFlicks(bi));
                    h.Position = [bx, by - r - 14, 0];
                    h.Color = [clr, 0.7];
                end
            end

            % Remove fallen extras in reverse order (preserves indices)
            for ri = numel(toRemove):-1:1
                obj.removeExtraBall(toRemove(ri));
            end
        end

        function removeExtraBall(obj, idx)
            %removeExtraBall  Delete one extra ball and its graphics.
            allHandles = {obj.ExtraBallCoreH, obj.ExtraBallGlowH, ...
                          obj.ExtraBallAuraH, obj.ExtraBallTrailH, ...
                          obj.ExtraBallTrailGlowH, obj.ExtraBallInfoTextH};
            for k = 1:numel(allHandles)
                if idx <= numel(allHandles{k})
                    h = allHandles{k}{idx};
                    if ~isempty(h) && isvalid(h)
                        delete(h);
                    end
                end
            end
            obj.ExtraBallPos(idx, :) = [];
            obj.ExtraBallVel(idx, :) = [];
            obj.ExtraBallLocked(idx) = [];
            obj.ExtraBallFlicks(idx) = [];
            obj.ExtraBallTrailBufX(idx) = [];
            obj.ExtraBallTrailBufY(idx) = [];
            obj.ExtraBallTrailIdx(idx) = [];
            obj.ExtraBallCoreH(idx) = [];
            obj.ExtraBallGlowH(idx) = [];
            obj.ExtraBallAuraH(idx) = [];
            obj.ExtraBallTrailH(idx) = [];
            obj.ExtraBallTrailGlowH(idx) = [];
            obj.ExtraBallInfoTextH(idx) = [];
        end

        function removeAllExtraBalls(obj)
            %removeAllExtraBalls  Delete all extra balls and their graphics.
            allHandles = [obj.ExtraBallCoreH, obj.ExtraBallGlowH, ...
                          obj.ExtraBallAuraH, obj.ExtraBallTrailH, ...
                          obj.ExtraBallTrailGlowH, obj.ExtraBallInfoTextH];
            for k = 1:numel(allHandles)
                h = allHandles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.ExtraBallPos = zeros(0, 2);
            obj.ExtraBallVel = zeros(0, 2);
            obj.ExtraBallLocked = logical.empty(0, 1);
            obj.ExtraBallFlicks = zeros(0, 1);
            obj.ExtraBallTrailBufX = {};
            obj.ExtraBallTrailBufY = {};
            obj.ExtraBallTrailIdx = zeros(0, 1);
            obj.ExtraBallCoreH = {};
            obj.ExtraBallGlowH = {};
            obj.ExtraBallAuraH = {};
            obj.ExtraBallTrailH = {};
            obj.ExtraBallTrailGlowH = {};
            obj.ExtraBallInfoTextH = {};
        end
    end
end
