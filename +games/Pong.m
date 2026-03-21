classdef Pong < GameBase
    %Pong  Classic pong game with AI opponent and rally escalation.
    %   Player controls the right paddle with finger/mouse position.
    %   AI controls the left paddle with difficulty that scales as the
    %   match progresses. Ball speed increases on each paddle hit and
    %   the hit angle depends on where the ball strikes the paddle.
    %   First to WinScore (default 10) wins.
    %
    %   Standalone: games.Pong().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Pong"
    end

    % =================================================================
    % GAME CONFIGURATION
    % =================================================================
    properties (Access = private)
        BallBaseSpeed   (1,1) double = 1.875     % initial serve speed (px/frame)
        BallSpeedGain   (1,1) double = 1.08     % speed multiplier per paddle hit
        WinScore        (1,1) double = 10       % first to this wins
        PaddleHalfH     (1,1) double = 35       % paddle half-height in px
        PaddleWidth     (1,1) double = 6        % paddle visual width in px
        PaddleMargin    (1,1) double = 15       % paddle X offset from edge
        BallRadius      (1,1) double = 8        % ball display radius
        AIBaseSpeed     (1,1) double = 1.25      % base AI max speed (px/frame)
        AIErrorPx       (1,1) double = 20       % base intentional offset error
        Restitution     (1,1) double = 0.95     % wall bounce energy retention
        TrailLen        (1,1) double = 20       % trail buffer capacity
        SpeedScale      (1,1) double = 1        % visual speed normalization factor
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        BallPos         (1,2) double = [NaN, NaN]   % ball center [x, y]
        BallVel         (1,2) double = [0, 0]        % velocity [vx, vy] px/frame
        BallPhase       (1,1) double = 0             % animation phase
        PlayerScore     (1,1) double = 0
        OpponentScore   (1,1) double = 0
        PlayerPaddleY   (1,1) double = NaN           % player paddle center Y
        AIPaddleY       (1,1) double = NaN           % AI paddle center Y
        AITargetY       (1,1) double = NaN           % predicted intercept Y
        AIRecalcCD      (1,1) double = 0             % frames until next recalc
        ServeDir        (1,1) double = 1             % +1 = toward player (right)
        ServeCountdown  (1,1) double = 0             % frames until serve
        Serving         (1,1) logical = false        % in serve countdown
        RallyHits       (1,1) double = 0             % hits in current rally
        MaxRally        (1,1) double = 0             % longest rally
        TotalRallies    (1,1) double = 0             % total rallies played

        % Trail circular buffer
        TrailBufX       (1,:) double
        TrailBufY       (1,:) double
        TrailIdx        (1,1) double = 0


        % Combo fade
        ComboTextH                                   % text — combo display
        ComboFadeTic    = []                         % tic when fade started
        ComboFadeColor  (1,3) double = [0.2, 1, 0.4]
        ComboShowTic    = []                         % tic when combo was shown

        % Cached constants (avoid per-frame allocation)
        ThetaCircle48   (1,48) double                % pre-computed linspace(0,2pi,48)

        % Dirty flags for HUD updates
        PrevPlayerScore   (1,1) double = -1
        PrevOpponentScore (1,1) double = -1
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BallCoreH               % line — ball core dot
        BallGlowH               % line — ball glow ring
        BallAuraH               % line — ball outer aura
        BallTrailH              % line — ball trail
        BallTrailGlowH          % line — trail glow
        AIPaddleH               % patch — AI paddle
        AIPaddleGlowH           % patch — AI paddle glow
        PlayerPaddleH           % patch — player paddle
        PlayerPaddleGlowH       % patch — player paddle glow
        ScoreTextH              % text — score display
        CenterLineH             % line — dashed center line
        ServeTextH              % text — serve/point flash
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, caps)
            %onInit  Create pong graphics and initialize state.
            arguments
                obj
                ax
                displayRange struct
                caps struct = struct()
            end
            obj.Ax = ax;
            obj.DisplayRange = displayRange;
            obj.Score = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;
            obj.ShowHostCombo = false;

            dx = displayRange.X;
            dy = displayRange.Y;
            cx = mean(dx);
            cy = mean(dy);

            % Scale sizes to display area
            areaH = dy(2) - dy(1);
            areaW = dx(2) - dx(1);
            ps = obj.getPixelScale();
            obj.PaddleHalfH = max(8, round(areaH * 0.15));
            obj.PaddleWidth = max(3, round(areaW * 0.025));
            obj.PaddleMargin = max(6, round(areaW * 0.06));
            obj.BallRadius = max(3, round(min(areaH, areaW) * 0.035));
            % Speed scales with display so ball crosses screen in same time
            obj.BallBaseSpeed = max(0.625, areaW * 0.00833);
            obj.AIBaseSpeed = max(0.417, areaH * 0.00833);
            obj.AIErrorPx = max(5, areaH * 0.12);

            % flickSpeedColor expects speeds in the ~3-12 range (calibrated
            % for GestureMouse's ~240px ROI). Scale visual speed down so the
            % full cyan→green→gold→red spectrum maps across the rally.
            obj.SpeedScale = 4.8 / max(obj.BallBaseSpeed, 1);

            % Reset state
            obj.BallPos = [cx, cy];
            obj.BallVel = [0, 0];
            obj.BallPhase = 0;
            obj.PlayerScore = 0;
            obj.OpponentScore = 0;
            obj.RallyHits = 0;
            obj.MaxRally = 0;
            obj.TotalRallies = 0;
            obj.AIPaddleY = cy;
            obj.AITargetY = cy;
            obj.AIRecalcCD = 0;
            obj.PlayerPaddleY = cy;
            obj.Serving = false;

            % Trail buffer
            obj.TrailBufX = NaN(1, obj.TrailLen);
            obj.TrailBufY = NaN(1, obj.TrailLen);
            obj.TrailIdx = 0;

            % Combo state
            obj.ComboFadeTic = [];
            obj.ComboShowTic = [];

            % Pre-compute constant arrays
            obj.ThetaCircle48 = linspace(0, 2*pi, 48);

            % Dirty flags
            obj.PrevPlayerScore = -1;
            obj.PrevOpponentScore = -1;

            % --- Create graphics ---
            % Center dashed line
            obj.CenterLineH = line(ax, [cx, cx], [dy(1), dy(2)], ...
                "Color", [1, 1, 1, 0.12], "LineWidth", 1, ...
                "LineStyle", "--", "Tag", "GT_pong");

            % Trail glow + trail
            obj.BallTrailGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.12], "LineWidth", 8 * ps, ...
                "LineStyle", "-", "Tag", "GT_pong");
            obj.BallTrailH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.5], "LineWidth", 2.5 * ps, ...
                "LineStyle", "-", "Tag", "GT_pong");

            % Ball aura, glow ring, core (screen-space sizes scaled by ps)
            r = obj.BallRadius;
            auraSize = r * 5 * ps;
            coreSize = r * 2 * ps;
            obj.BallAuraH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.15], "Marker", ".", ...
                "MarkerSize", auraSize, "LineStyle", "none", "Tag", "GT_pong");
            glowSize = r * 3 * ps;
            obj.BallGlowH = scatter(ax, cx, cy, pi * (glowSize/2)^2, ...
                obj.ColorCyan, "filled", "MarkerFaceAlpha", 0.4, ...
                "Tag", "GT_pong");
            obj.BallCoreH = line(ax, cx, cy, ...
                "Color", [1, 1, 1, 1], "Marker", ".", ...
                "MarkerSize", coreSize, "LineStyle", "none", "Tag", "GT_pong");

            % AI paddle (left, red) — outline only
            aiX = dx(1) + obj.PaddleMargin;
            pw = obj.PaddleWidth;
            ph = obj.PaddleHalfH;
            obj.AIPaddleGlowH = patch(ax, ...
                [aiX - pw/2, aiX + pw/2, aiX + pw/2, aiX - pw/2], ...
                [cy - ph, cy - ph, cy + ph, cy + ph], ...
                obj.ColorRed * 0.65, "EdgeColor", obj.ColorRed, ...
                "LineWidth", 2.5 * ps, "Tag", "GT_pong");
            obj.AIPaddleH = patch(ax, ...
                [aiX - pw/2, aiX + pw/2, aiX + pw/2, aiX - pw/2], ...
                [cy - ph, cy - ph, cy + ph, cy + ph], ...
                obj.ColorRed * 0.65, "EdgeColor", obj.ColorRed, ...
                "LineWidth", 2.5 * ps, "Tag", "GT_pong");

            % Player paddle (right, cyan)
            plX = dx(2) - obj.PaddleMargin;
            obj.PlayerPaddleGlowH = patch(ax, ...
                [plX - pw/2, plX + pw/2, plX + pw/2, plX - pw/2], ...
                [cy - ph, cy - ph, cy + ph, cy + ph], ...
                obj.ColorCyan * 0.65, "EdgeColor", obj.ColorCyan, ...
                "LineWidth", 2.5 * ps, "Tag", "GT_pong");
            obj.PlayerPaddleH = patch(ax, ...
                [plX - pw/2, plX + pw/2, plX + pw/2, plX - pw/2], ...
                [cy - ph, cy - ph, cy + ph, cy + ph], ...
                obj.ColorCyan * 0.65, "EdgeColor", obj.ColorCyan, ...
                "LineWidth", 2.5 * ps, "Tag", "GT_pong");

            % Score text
            obj.ScoreTextH = text(ax, cx, dy(1) + 5, "CPU  0 - 0  YOU", ...
                "Color", [1, 1, 1] * 0.8, "FontSize", 26 * ps, ...
                "FontWeight", "bold", ...
                "HorizontalAlignment", "center", "VerticalAlignment", "top", ...
                "Tag", "GT_pong");

            % Serve text
            obj.ServeTextH = text(ax, cx, dy(1) + areaH * 0.25, "", ...
                "Color", obj.ColorCyan * 0.9, "FontSize", 47 * ps, ...
                "FontWeight", "bold", ...
                "HorizontalAlignment", "center", "VerticalAlignment", "middle", ...
                "Visible", "off", "Tag", "GT_pong");

            % Combo text (pre-allocated, hidden until needed)
            obj.ComboTextH = text(ax, 0, 0, "", ...
                "Color", obj.ColorGold * 0.8, "FontSize", 7 * ps, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "top", "Visible", "off", "Tag", "GT_pong");

            % Start first serve
            obj.beginServe();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame pong game loop.
            if ~obj.IsRunning; return; end

            ds = obj.DtScale;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % Update player paddle from finger position
            if ~any(isnan(pos))
                obj.PlayerPaddleY = max(dy(1) + obj.PaddleHalfH, ...
                    min(dy(2) - obj.PaddleHalfH, pos(2)));
            end

            % --- Serve countdown ---
            if obj.Serving
                obj.ServeCountdown = obj.ServeCountdown - ds;
                if obj.ServeCountdown <= 0
                    obj.launchBall();
                else
                    % Animate serve text
                    remaining = ceil(obj.ServeCountdown / 40);
                    if ~isempty(obj.ServeTextH) && isvalid(obj.ServeTextH)
                        obj.ServeTextH.String = string(remaining);
                        progress = mod(obj.ServeCountdown, 40) / 40;
                        serveScale = 1 + 0.2 * sin(progress * pi);
                        obj.ServeTextH.FontSize = 16 * obj.getPixelScale() * serveScale;
                        obj.ServeTextH.Visible = "on";
                    end
                end
                obj.updateAIPaddle();
                obj.BallPhase = obj.BallPhase + 0.0333 * ds;
                obj.updateGraphics();
                obj.updateComboFade();
                return;
            end

            % --- Ball physics ---
            prePos = obj.BallPos;
            stepVel = obj.BallVel * ds;
            obj.BallPos = obj.BallPos + stepVel;

            % Top/bottom wall collision (parametric)
            bounced = false;
            bouncePos = obj.BallPos;
            bounceNormal = [0, 0];

            wallSpeedGain = 1 + (obj.BallSpeedGain - 1) * 0.5;

            % Top wall
            if obj.BallPos(2) < dy(1) && stepVel(2) ~= 0
                tHit = min(1, max(0, (dy(1) - prePos(2)) / stepVel(2)));
                obj.BallPos(1) = prePos(1) + tHit * stepVel(1);
                obj.BallPos(2) = dy(1);
                obj.BallVel(2) = -obj.BallVel(2) * obj.Restitution;
                obj.BallVel = obj.BallVel * wallSpeedGain;
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [0, 1];
            end
            % Bottom wall
            if obj.BallPos(2) > dy(2) && stepVel(2) ~= 0
                tHit = min(1, max(0, (dy(2) - prePos(2)) / stepVel(2)));
                obj.BallPos(1) = prePos(1) + tHit * stepVel(1);
                obj.BallPos(2) = dy(2);
                obj.BallVel(2) = -obj.BallVel(2) * obj.Restitution;
                obj.BallVel = obj.BallVel * wallSpeedGain;
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [0, -1];
            end

            if bounced
                obj.spawnBounceEffect(bouncePos, bounceNormal, 0, ...
                    norm(obj.BallVel) * obj.SpeedScale);
            end

            % --- Paddle collision (front-face only) ---
            % Player paddle (right side)
            plX = dx(2) - obj.PaddleMargin;
            if prePos(1) + obj.BallRadius < plX && ...
                    obj.BallPos(1) + obj.BallRadius >= plX && obj.BallVel(1) > 0
                if abs(obj.BallPos(2) - obj.PlayerPaddleY) <= obj.PaddleHalfH
                    obj.paddleHit("player", obj.PlayerPaddleY, plX);
                end
            end
            % AI paddle (left side)
            aiX = dx(1) + obj.PaddleMargin;
            if prePos(1) - obj.BallRadius > aiX && ...
                    obj.BallPos(1) - obj.BallRadius <= aiX && obj.BallVel(1) < 0
                if abs(obj.BallPos(2) - obj.AIPaddleY) <= obj.PaddleHalfH
                    obj.paddleHit("ai", obj.AIPaddleY, aiX);
                end
            end

            % --- Goal detection ---
            if obj.BallPos(1) > dx(2) + obj.BallRadius * 2
                % Ball exits right -> AI scores
                obj.onGoal("opponent");
                return;
            end
            if obj.BallPos(1) < dx(1) - obj.BallRadius * 2
                % Ball exits left -> Player scores
                obj.onGoal("player");
                return;
            end

            % --- AI paddle movement ---
            obj.updateAIPaddle();

            % --- Trail buffer ---
            tidx = mod(obj.TrailIdx, obj.TrailLen) + 1;
            obj.TrailBufX(tidx) = obj.BallPos(1);
            obj.TrailBufY(tidx) = obj.BallPos(2);
            obj.TrailIdx = tidx;

            % --- Animation + render ---
            obj.BallPhase = obj.BallPhase + 0.0333 * ds;
            obj.updateGraphics();
            obj.updateComboFade();
        end

        function onCleanup(obj)
            %onCleanup  Delete all pong graphics.
            handles = {obj.BallCoreH, obj.BallGlowH, obj.BallAuraH, ...
                       obj.BallTrailH, obj.BallTrailGlowH, ...
                       obj.AIPaddleH, obj.AIPaddleGlowH, ...
                       obj.PlayerPaddleH, obj.PlayerPaddleGlowH, ...
                       obj.ScoreTextH, obj.CenterLineH, obj.ServeTextH, ...
                       obj.ComboTextH};
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
            obj.AIPaddleH = [];
            obj.AIPaddleGlowH = [];
            obj.PlayerPaddleH = [];
            obj.PlayerPaddleGlowH = [];
            obj.ScoreTextH = [];
            obj.CenterLineH = [];
            obj.ServeTextH = [];
            obj.ComboTextH = [];

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_pong");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for pong.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return pong-specific results.
            r.Title = "PONG";
            if obj.PlayerScore >= obj.WinScore
                outcome = "YOU WIN!";
            elseif obj.OpponentScore >= obj.WinScore
                outcome = "YOU LOSE";
            else
                outcome = "GAME OVER";
            end
            r.Lines = {
                sprintf("%s  |  Player %d - %d CPU  |  Best Rally: %d", ...
                    outcome, obj.PlayerScore, obj.OpponentScore, ...
                    obj.MaxRally)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS — GAME LOGIC
    % =================================================================
    methods (Access = private)

        function beginServe(obj)
            %beginServe  Start a serve countdown.
            cx = mean(obj.DisplayRange.X);
            cy = mean(obj.DisplayRange.Y);
            obj.BallPos = [cx, cy];
            obj.BallVel = [0, 0];
            obj.Serving = true;
            obj.ServeCountdown = 120;
            obj.ServeDir = 1;  % always serve toward player (right)
            obj.TrailBufX(:) = NaN;
            obj.TrailBufY(:) = NaN;
            obj.TrailIdx = 0;
        end

        function launchBall(obj)
            %launchBall  Launch ball after serve countdown.
            launchAngle = (rand - 0.5) * pi / 3;
            ballSpeed = obj.BallBaseSpeed;
            obj.BallVel = ballSpeed * [obj.ServeDir * cos(launchAngle), sin(launchAngle)];
            obj.Serving = false;
            if ~isempty(obj.ServeTextH) && isvalid(obj.ServeTextH)
                obj.ServeTextH.Visible = "off";
            end
        end

        function paddleHit(obj, who, paddleY, paddleX)
            %paddleHit  Handle ball hitting a paddle.
            hitOffset = obj.BallPos(2) - paddleY;
            normalizedOffset = max(-1, min(1, hitOffset / obj.PaddleHalfH));

            % Return angle: offset from center -> +/-60 degrees
            maxAngle = pi / 3;
            returnAngle = normalizedOffset * maxAngle;

            % Speed increases each hit
            currentSpeed = norm(obj.BallVel);
            newSpeed = max(currentSpeed * obj.BallSpeedGain, obj.BallBaseSpeed);

            if who == "player"
                % Ball goes left (negative X) after player hit
                obj.BallVel = newSpeed * [-cos(returnAngle), sin(returnAngle)];
                obj.BallPos(1) = paddleX - obj.BallRadius;
            else
                % Ball goes right after AI hit
                difficultyVal = obj.computeDifficulty();
                aiBoost = 1 + difficultyVal * 0.3;
                obj.BallVel = newSpeed * aiBoost * [cos(returnAngle), sin(returnAngle)];
                obj.BallPos(1) = paddleX + obj.BallRadius;
            end

            % Rally tracking
            obj.RallyHits = obj.RallyHits + 1;
            obj.MaxRally = max(obj.MaxRally, obj.RallyHits);

            if who == "player"
                obj.incrementCombo();
                obj.addScore(round(10 * obj.Combo));
                if obj.Combo >= 2
                    obj.showCombo(obj.BallPos + [0, -20]);
                end
            end

            % Clear trail on direction change
            obj.TrailBufX(:) = NaN;
            obj.TrailBufY(:) = NaN;
            obj.TrailIdx = 0;
        end

        function onGoal(obj, who)
            %onGoal  Handle a point being scored.
            if who == "player"
                obj.PlayerScore = obj.PlayerScore + 1;
                pointBonus = 100 + obj.RallyHits * 10;
                obj.addScore(pointBonus);
                if ~isempty(obj.ServeTextH) && isvalid(obj.ServeTextH)
                    obj.ServeTextH.String = "PLAYER SCORES!";
                    obj.ServeTextH.Color = [obj.ColorGreen, 0.9];
                    obj.ServeTextH.Visible = "on";
                end
            else
                obj.OpponentScore = obj.OpponentScore + 1;
                if ~isempty(obj.ServeTextH) && isvalid(obj.ServeTextH)
                    obj.ServeTextH.String = "CPU SCORES!";
                    obj.ServeTextH.Color = [obj.ColorRed, 0.9];
                    obj.ServeTextH.Visible = "on";
                end
            end

            % Update score display
            obj.refreshScoreText();

            % Reset rally
            obj.TotalRallies = obj.TotalRallies + 1;
            obj.RallyHits = 0;
            if who == "opponent"
                obj.resetCombo();
            end

            % Check win condition
            if obj.PlayerScore >= obj.WinScore || ...
                    obj.OpponentScore >= obj.WinScore
                obj.IsRunning = false;
                return;
            end

            obj.beginServe();
        end

        function updateAIPaddle(obj)
            %updateAIPaddle  AI paddle movement with difficulty scaling.
            dy = obj.DisplayRange.Y;
            difficultyVal = obj.computeDifficulty();

            % Derived parameters — AI starts bad, gets good
            paddleSpeed = obj.AIBaseSpeed * (0.4 + difficultyVal * 0.6);
            reactionFrames = round(20 - difficultyVal * 16);
            errorPx = obj.AIErrorPx * (1.5 - difficultyVal * 1.2);

            % Recalculate target periodically
            obj.AIRecalcCD = obj.AIRecalcCD - 1;
            if obj.AIRecalcCD <= 0
                obj.AIRecalcCD = max(2, reactionFrames);
                if obj.BallVel(1) < 0
                    obj.AITargetY = obj.predictIntercept();
                else
                    obj.AITargetY = mean(dy) + (rand - 0.5) * 30;
                end
                obj.AITargetY = obj.AITargetY + (rand - 0.5) * 2 * errorPx;
            end

            % Move toward target (scale by dt for frame-rate independence)
            scaledSpeed = paddleSpeed * obj.DtScale;
            deltaY = obj.AITargetY - obj.AIPaddleY;
            if abs(deltaY) > scaledSpeed
                obj.AIPaddleY = obj.AIPaddleY + sign(deltaY) * scaledSpeed;
            else
                obj.AIPaddleY = obj.AITargetY;
            end

            % Clamp to bounds
            obj.AIPaddleY = max(dy(1) + obj.PaddleHalfH, ...
                min(dy(2) - obj.PaddleHalfH, obj.AIPaddleY));
        end

        function d = computeDifficulty(obj)
            %computeDifficulty  Compute AI difficulty 0.0 to 1.0.
            totalPoints = obj.PlayerScore + obj.OpponentScore;
            d = min(1.0, totalPoints / (obj.WinScore * 2 - 2));
            maxScore = max(obj.PlayerScore, obj.OpponentScore);
            if maxScore >= 7
                urgency = (maxScore - 6) / 4;
                d = max(d, urgency);
            end
        end

        function targetY = predictIntercept(obj)
            %predictIntercept  Predict where ball will hit AI paddle X.
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            aiX = dx(1) + obj.PaddleMargin;

            simX = obj.BallPos(1);
            simY = obj.BallPos(2);
            simVx = obj.BallVel(1);
            simVy = obj.BallVel(2);

            if simVx >= 0
                targetY = mean(dy);
                return;
            end

            for bounceIter = 1:10
                if simVx == 0; break; end
                tPaddle = (aiX - simX) / simVx;
                if tPaddle < 0; break; end

                if simVy ~= 0
                    if simVy < 0
                        tWall = (dy(1) - simY) / simVy;
                    else
                        tWall = (dy(2) - simY) / simVy;
                    end
                else
                    tWall = inf;
                end

                if tWall > 0 && tWall < tPaddle
                    simX = simX + simVx * tWall;
                    simY = simY + simVy * tWall;
                    simVy = -simVy;
                else
                    targetY = simY + simVy * tPaddle;
                    return;
                end
            end
            targetY = simY;
        end

        % --- Combo display ---

        function showCombo(obj, hitPos)
            %showCombo  Show combo text at hit location.
            if obj.Combo < 2; return; end
            obj.ComboFadeTic = [];
            if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH); return; end
            obj.ComboTextH.String = sprintf("%dx Combo", obj.Combo);
            obj.ComboTextH.Color = obj.ColorGreen * 0.9;
            if ~any(isnan(hitPos))
                obj.ComboTextH.Position = [hitPos(1), hitPos(2) + 12, 0];
            end
            obj.ComboTextH.Visible = "on";
            obj.ComboShowTic = tic;
            obj.ComboFadeTic = tic;  % start 1s display + 0.6s fade
            obj.ComboFadeColor = obj.ColorGreen * 0.9;
        end

        function updateComboFade(obj)
            %updateComboFade  Animate combo text fade-out.
            if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH)
                obj.ComboFadeTic = [];
                obj.ComboShowTic = [];
                return;
            end

            % Auto-trigger fade after 1s display
            if ~isempty(obj.ComboShowTic) && isempty(obj.ComboFadeTic)
                if toc(obj.ComboShowTic) >= 1.0
                    obj.ComboFadeTic = tic;
                    obj.ComboFadeColor = obj.ColorGreen * 0.9;
                    obj.ComboShowTic = [];
                end
            end

            % Animate fade-out
            if isempty(obj.ComboFadeTic); return; end
            elapsed = toc(obj.ComboFadeTic);
            % Show solid for 1s, then fade over 0.6s
            if elapsed < 1.0
                return;
            end
            fadeDur = 0.6;
            fadeElapsed = elapsed - 1.0;
            if fadeElapsed >= fadeDur
                obj.ComboTextH.Visible = "off";
                obj.ComboFadeTic = [];
            else
                alphaVal = max(0, 1 - fadeElapsed / fadeDur);
                obj.ComboTextH.Color = [obj.ComboFadeColor, alphaVal];
            end
        end
    end

    % =================================================================
    % PRIVATE METHODS — RENDERING
    % =================================================================
    methods (Access = private)

        function updateGraphics(obj)
            %updateGraphics  Render ball, paddles, trail.
            if any(isnan(obj.BallPos)); return; end
            bx = obj.BallPos(1);
            by = obj.BallPos(2);
            ballSpeed = norm(obj.BallVel);
            r = obj.BallRadius;
            visSpeed = ballSpeed * obj.SpeedScale;
            clr = obj.flickSpeedColor(visSpeed);

            % Ball core
            if ~isempty(obj.BallCoreH) && isvalid(obj.BallCoreH)
                obj.BallCoreH.XData = bx;
                obj.BallCoreH.YData = by;
            end
            % Ball glow
            if ~isempty(obj.BallGlowH) && isvalid(obj.BallGlowH)
                obj.BallGlowH.XData = bx;
                obj.BallGlowH.YData = by;
                obj.BallGlowH.CData = clr;
            end
            % Ball aura
            if ~isempty(obj.BallAuraH) && isvalid(obj.BallAuraH)
                obj.BallAuraH.XData = bx;
                obj.BallAuraH.YData = by;
                obj.BallAuraH.Color = [clr, 0.12];
            end

            % Trail
            if ballSpeed > 0.5 && obj.TrailIdx > 0
                n = obj.TrailLen;
                order = mod((obj.TrailIdx:obj.TrailIdx + n - 1), n) + 1;
                tx = obj.TrailBufX(order);
                ty = obj.TrailBufY(order);
                firstValid = find(~isnan(tx), 1, "first");
                if ~isempty(firstValid)
                    tx = tx(firstValid:end);
                    ty = ty(firstValid:end);
                end
                trailAlpha = min(0.5, 0.15 + visSpeed * 0.03);
                trailWidth = min(3.5, 1.5 + visSpeed * 0.1);
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

            % --- Paddles ---
            ph = obj.PaddleHalfH;
            % AI paddle (left)
            aiY = obj.AIPaddleY;
            if ~isnan(aiY)
                paddleYData = [aiY-ph, aiY-ph, aiY+ph, aiY+ph];
                if ~isempty(obj.AIPaddleH) && isvalid(obj.AIPaddleH)
                    obj.AIPaddleH.YData = paddleYData;
                end
                if ~isempty(obj.AIPaddleGlowH) && isvalid(obj.AIPaddleGlowH)
                    obj.AIPaddleGlowH.YData = paddleYData;
                end
            end
            % Player paddle (right)
            plY = obj.PlayerPaddleY;
            if ~isnan(plY)
                paddleYData = [plY-ph, plY-ph, plY+ph, plY+ph];
                if ~isempty(obj.PlayerPaddleH) && isvalid(obj.PlayerPaddleH)
                    obj.PlayerPaddleH.YData = paddleYData;
                end
                if ~isempty(obj.PlayerPaddleGlowH) && isvalid(obj.PlayerPaddleGlowH)
                    obj.PlayerPaddleGlowH.YData = paddleYData;
                end
            end

            % Score display — only update when changed
            if obj.PlayerScore ~= obj.PrevPlayerScore || ...
                    obj.OpponentScore ~= obj.PrevOpponentScore
                obj.refreshScoreText();
                obj.PrevPlayerScore = obj.PlayerScore;
                obj.PrevOpponentScore = obj.OpponentScore;
            end
        end

        function refreshScoreText(obj)
            %refreshScoreText  Update the score text display.
            if ~isempty(obj.ScoreTextH) && isvalid(obj.ScoreTextH)
                obj.ScoreTextH.String = sprintf("CPU  %d - %d  YOU", ...
                    obj.OpponentScore, obj.PlayerScore);
            end
        end
    end
end
