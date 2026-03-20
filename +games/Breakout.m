classdef Breakout < GameBase
    %Breakout  Classic Arkanoid-style brick-breaking game.
    %   Paddle controlled by finger X position. 5 levels with escalating
    %   difficulty, power-ups (Fireball, Multi-ball, Slow, Wide, Life),
    %   neon brick destruction effects, and multi-ball support.
    %
    %   Standalone: games.Breakout().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Breakout"
    end

    % =================================================================
    % GAME CONSTANTS
    % =================================================================
    properties (Constant, Access = private)
        ColorOrange     (1,3) double = [1, 0.6, 0.15]
        ColorSilver     (1,3) double = [0.75, 0.78, 0.82]
        MaxLevel        (1,1) double = 5
        MaxLives        (1,1) double = 5
        MaxBalls        (1,1) double = 3
        TrailLen        (1,1) double = 20
        SpeedGain       (1,1) double = 1.04
        Restitution     (1,1) double = 1.0
        BrickCols       (1,1) double = 10
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Ball
        BallPos         (1,2) double = [NaN, NaN]
        BallVel         (1,2) double = [0, 0]
        BallRadius      (1,1) double = 6
        BallPhase       (1,1) double = 0
        BallBaseSpeed   (1,1) double = 1.458
        BallSpeed       (1,1) double = 1.458

        % Paddle
        PaddleX         (1,1) double = NaN
        PaddleW         (1,1) double = 40
        PaddleBaseW     (1,1) double = 40
        PaddleHt        (1,1) double = 8
        PaddleY         (1,1) double = NaN

        % Bricks
        Bricks          struct = struct("hp", {}, "color", {}, ...
                                        "x", {}, "y", {}, "w", {}, "h", {}, ...
                                        "patchH", {}, "glowH", {})
        BrickRows       (1,1) double = 6
        BricksRemaining (1,1) double = 0
        BrickAreaTop    (1,1) double = 0
        BrickAreaBot    (1,1) double = 0

        % Lives / Level
        Lives           (1,1) double = 3
        Level           (1,1) double = 1
        Serving         (1,1) logical = false
        ServeCountdown  (1,1) double = 0
        BricksDestroyed (1,1) double = 0

        % Trail
        TrailBufX       (1,:) double
        TrailBufY       (1,:) double
        TrailIdx        (1,1) double = 0

        % Multi-ball
        ExtraBalls      struct = struct("pos", {}, "vel", {}, ...
                                        "coreH", {}, "glowH", {}, "auraH", {}, ...
                                        "trailH", {}, "trailGlowH", {}, ...
                                        "trailBufX", {}, "trailBufY", {}, "trailIdx", {})

        % Power-ups
        PowerUps        struct = struct("type", {}, "x", {}, "y", {}, ...
                                        "speed", {}, "patchH", {}, ...
                                        "glowH", {}, "textH", {})
        ActivePowers    struct = struct("wide", {{}}, "slow", {{}}, "fireball", NaN)
        CatchHeld       (1,1) logical = false
        CatchOffset     (1,1) double = 0

        % Level transition
        LevelPhase      (1,1) string = "play"
        LevelTransFrames (1,1) double = 0

        % Display scale factor (1.0 at ~180px reference)
        Sc              (1,1) double = 1

        % Pre-computed circle geometry (avoid linspace/cos/sin per frame)
        Theta48         (1,48) double       % glow ring (ball, extra balls)
        CosT48          (1,48) double
        SinT48          (1,48) double
        Theta24         (1,24) double       % power-up capsule
        CosT24          (1,24) double
        SinT24          (1,24) double
        PowerUpCapR     (1,1) double = 5    % cached capsule radius
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        BallCoreH
        BallGlowH
        BallAuraH
        BallTrailH
        BallTrailGlowH
        PaddleH
        PaddleGlowH
        LivesH
        LivesFlashTic       = []
        LevelTextH
        PowerBarH           = {}
        ModeTextH                           % text -- bottom-left HUD label
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create breakout graphics and initialize state.
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
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);

            % Display scale factor (1.0 at ~180px reference)
            obj.Sc = min(areaW, areaH) / 180;

            % Scale sizes to display area
            obj.BallRadius = max(3, round(min(areaH, areaW) * 0.025));
            obj.BallBaseSpeed = max(0.625, areaH * 0.01125);
            obj.BallSpeed = obj.BallBaseSpeed;
            obj.PaddleBaseW = max(20, round(areaW * 0.15));
            obj.PaddleW = obj.PaddleBaseW;
            obj.PaddleHt = max(4, round(areaH * 0.03));
            obj.PaddleY = dy(2) - round(areaH * 0.08);

            % Pre-compute circle geometry (avoid per-frame linspace/trig)
            obj.Theta48 = linspace(0, 2*pi, 48);
            obj.CosT48 = cos(obj.Theta48);
            obj.SinT48 = sin(obj.Theta48);
            obj.Theta24 = linspace(0, 2*pi, 24);
            obj.CosT24 = cos(obj.Theta24);
            obj.SinT24 = sin(obj.Theta24);
            obj.PowerUpCapR = round(5 * obj.Sc);

            % Reset state
            obj.Lives = 3;
            obj.Level = 1;
            obj.BricksDestroyed = 0;
            obj.Serving = true;
            obj.ServeCountdown = 0;
            obj.CatchHeld = false;
            obj.CatchOffset = 0;
            obj.BallPhase = 0;
            obj.ExtraBalls = struct("pos", {}, "vel", {}, ...
                "coreH", {}, "glowH", {}, "auraH", {}, "trailH", {}, "trailGlowH", {}, ...
                "trailBufX", {}, "trailBufY", {}, "trailIdx", {});
            obj.PowerUps = struct("type", {}, "x", {}, "y", {}, ...
                "speed", {}, "patchH", {}, "glowH", {}, "textH", {});
            obj.ActivePowers = struct("wide", {{}}, "slow", {{}}, "fireball", NaN);
            obj.LevelPhase = "play";
            obj.LevelTransFrames = 0;

            % Trail buffer
            obj.TrailBufX = NaN(1, obj.TrailLen);
            obj.TrailBufY = NaN(1, obj.TrailLen);
            obj.TrailIdx = 0;

            % --- Build brick grid ---
            obj.buildBrickGrid(1);

            % --- Create graphics ---
            % Trail glow + trail
            obj.BallTrailGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.12], "LineWidth", 8, ...
                "LineStyle", "-", "Tag", "GT_breakout");
            obj.BallTrailH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.5], "LineWidth", 2.5, ...
                "LineStyle", "-", "Tag", "GT_breakout");

            % Ball aura, glow ring, core
            ballR = obj.BallRadius;
            auraSize = max(15, ballR * 5);
            coreSize = max(6, ballR * 2);
            glowWidth = max(2, ballR * 0.6);
            obj.BallAuraH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.15], "Marker", ".", ...
                "MarkerSize", auraSize, "LineStyle", "none", "Tag", "GT_breakout");
            theta = linspace(0, 2*pi, 48);
            obj.BallGlowH = line(ax, cx + ballR*cos(theta), cx + ballR*sin(theta), ...
                "Color", [obj.ColorCyan, 0.4], "LineWidth", glowWidth, ...
                "Tag", "GT_breakout");
            obj.BallCoreH = line(ax, cx, cx, ...
                "Color", [1, 1, 1, 1], "Marker", ".", ...
                "MarkerSize", coreSize, "LineStyle", "none", "Tag", "GT_breakout");

            % Paddle
            py = obj.PaddleY;
            pw = obj.PaddleW;
            ph = obj.PaddleHt;
            obj.PaddleGlowH = patch(ax, ...
                [cx - pw/2, cx + pw/2, cx + pw/2, cx - pw/2], ...
                [py, py, py + ph, py + ph], ...
                obj.ColorCyan, "FaceAlpha", 0.12, ...
                "EdgeColor", obj.ColorCyan * 0.3, "LineWidth", 5, ...
                "Tag", "GT_breakout");
            obj.PaddleH = patch(ax, ...
                [cx - pw/2, cx + pw/2, cx + pw/2, cx - pw/2], ...
                [py, py, py + ph, py + ph], ...
                obj.ColorCyan, "FaceAlpha", 0.35, ...
                "EdgeColor", obj.ColorCyan, "LineWidth", 2, ...
                "Tag", "GT_breakout");

            % Lives flash text (hidden until life lost, shown centered)
            obj.LivesH = text(ax, cx, mean(dy), "", ...
                "Color", obj.ColorRed, "FontSize", max(18, round(areaH * 0.1)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_breakout");

            % Level text (initially hidden)
            obj.LevelTextH = text(ax, cx, mean(dy), "", ...
                "Color", obj.ColorGold, "FontSize", max(16, round(areaH * 0.15)), ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "middle", "Visible", "off", ...
                "Tag", "GT_breakout");

            % Bottom-left HUD text
            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, ...
                obj.buildHudString(), ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_breakout");

            % Place ball on paddle
            obj.PaddleX = cx;
            obj.serveBall();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame breakout game logic.
            ds = obj.DtScale;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;

            % --- Level transition phase ---
            if obj.LevelPhase == "transition"
                obj.LevelTransFrames = obj.LevelTransFrames - ds;
                tProgress = 1 - obj.LevelTransFrames / 96;

                % Fade out old bricks
                if tProgress < 0.5
                    fadeAlpha = max(0, 1 - tProgress * 4);
                    for k = 1:numel(obj.Bricks)
                        brk = obj.Bricks(k);
                        if ~isempty(brk.patchH) && isvalid(brk.patchH)
                            brk.patchH.FaceAlpha = fadeAlpha * 0.8;
                        end
                    end
                end

                % Fade level text
                if ~isempty(obj.LevelTextH) && isvalid(obj.LevelTextH)
                    textAlpha = 1;
                    if tProgress > 0.7
                        textAlpha = max(0, (1 - tProgress) / 0.3);
                    end
                    obj.LevelTextH.Color = [obj.ColorGold, textAlpha];
                end

                if obj.LevelTransFrames <= 0
                    obj.LevelPhase = "play";
                    if ~isempty(obj.LevelTextH) && isvalid(obj.LevelTextH)
                        obj.LevelTextH.Visible = "off";
                    end
                    obj.buildBrickGrid(obj.Level);
                    obj.serveBall();
                end
                return;
            end

            % --- Paddle tracking ---
            if ~any(isnan(pos))
                obj.PaddleX = max(dx(1) + obj.PaddleW/2, ...
                    min(dx(2) - obj.PaddleW/2, pos(1)));
            end

            % Update paddle graphics
            pw = obj.PaddleW;
            ph = obj.PaddleHt;
            py = obj.PaddleY;
            px = obj.PaddleX;
            xv = [px - pw/2, px + pw/2, px + pw/2, px - pw/2];
            yv = [py, py, py + ph, py + ph];
            if ~isempty(obj.PaddleH) && isvalid(obj.PaddleH)
                set(obj.PaddleH, "XData", xv, "YData", yv);
            end
            if ~isempty(obj.PaddleGlowH) && isvalid(obj.PaddleGlowH)
                set(obj.PaddleGlowH, "XData", xv, "YData", yv);
                % Breathing glow
                obj.BallPhase = obj.BallPhase + 0.0333 * ds;
                glowAlpha = 0.08 + 0.04 * sin(obj.BallPhase);
                obj.PaddleGlowH.FaceAlpha = glowAlpha;
            end

            % --- Serve mode ---
            if obj.Serving
                obj.BallPos = [obj.PaddleX, py - obj.BallRadius - 2];
                obj.ServeCountdown = obj.ServeCountdown - ds;
                if obj.ServeCountdown <= 0
                    obj.launchBall();
                end
                obj.updateBallGraphics();
                return;
            end

            % --- Ball physics ---
            prePos = obj.BallPos;
            obj.BallPos = obj.BallPos + obj.BallVel * ds;

            % Wall collisions (top, left, right)
            bounced = false;
            bouncePos = obj.BallPos;
            bounceNormal = [0, 0];

            % Top wall
            if obj.BallPos(2) < dy(1) && obj.BallVel(2) ~= 0
                tWall = min(1, max(0, (dy(1) - prePos(2)) / obj.BallVel(2)));
                obj.BallPos(1) = prePos(1) + tWall * obj.BallVel(1);
                obj.BallPos(2) = dy(1);
                obj.BallVel(2) = -obj.BallVel(2);
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [0, 1];
            end
            % Left wall
            if obj.BallPos(1) < dx(1) && obj.BallVel(1) ~= 0
                tWall = min(1, max(0, (dx(1) - prePos(1)) / obj.BallVel(1)));
                obj.BallPos(2) = prePos(2) + tWall * obj.BallVel(2);
                obj.BallPos(1) = dx(1);
                obj.BallVel(1) = -obj.BallVel(1);
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [1, 0];
            end
            % Right wall
            if obj.BallPos(1) > dx(2) && obj.BallVel(1) ~= 0
                tWall = min(1, max(0, (dx(2) - prePos(1)) / obj.BallVel(1)));
                obj.BallPos(2) = prePos(2) + tWall * obj.BallVel(2);
                obj.BallPos(1) = dx(2);
                obj.BallVel(1) = -obj.BallVel(1);
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [-1, 0];
            end

            if bounced
                % Slight speed gain per wall bounce
                obj.BallVel = obj.BallVel * 1.005;
                spd = norm(obj.BallVel);
                obj.BallSpeed = spd;
                sRatio = spd / max(obj.BallBaseSpeed, 1);
                mSpeed = 3 + (sRatio - 1) * 12;
                obj.spawnBounceEffect(bouncePos, bounceNormal, 0, mSpeed);
            end

            % --- Paddle collision (swept: detect crossing from above) ---
            crossedPaddle = prePos(2) < py && obj.BallPos(2) >= py && obj.BallVel(2) > 0;
            atPaddle = obj.BallPos(2) >= py && obj.BallPos(2) <= py + ph && obj.BallVel(2) > 0;
            if crossedPaddle || atPaddle
                % Interpolate X at paddle Y crossing
                if crossedPaddle && obj.BallVel(2) > 0
                    tHit = (py - prePos(2)) / (obj.BallVel(2) * ds);
                    hitX = prePos(1) + tHit * obj.BallVel(1) * ds;
                else
                    hitX = obj.BallPos(1);
                end
                if hitX >= px - pw/2 && hitX <= px + pw/2
                    % Reflect with angle based on hit position
                    hitOffset = hitX - px;
                    normalizedOffset = max(-1, min(1, hitOffset / (pw / 2)));

                    maxAngle = pi / 3;  % +/-60 deg
                    returnAngle = normalizedOffset * maxAngle;

                    currentSpeed = norm(obj.BallVel);
                    newSpeed = currentSpeed * obj.SpeedGain;
                    newSpeed = max(newSpeed, obj.BallBaseSpeed);
                    obj.BallSpeed = newSpeed;

                    obj.BallVel = newSpeed * [sin(returnAngle), -cos(returnAngle)];
                    obj.BallPos(2) = py - obj.BallRadius - 1;

                    % Clear trail on paddle hit
                    obj.TrailBufX(:) = NaN;
                    obj.TrailBufY(:) = NaN;
                    obj.TrailIdx = 0;
                end
            end

            % --- Bottom edge: lose life ---
            if obj.BallPos(2) > dy(2) + obj.BallRadius * 2
                if ~isempty(obj.ExtraBalls)
                    % Promote first extra ball to primary
                    eb = obj.ExtraBalls(1);
                    obj.BallPos = eb.pos;
                    obj.BallVel = eb.vel;
                    obj.BallSpeed = norm(eb.vel);
                    obj.TrailBufX(:) = NaN;
                    obj.TrailBufY(:) = NaN;
                    obj.TrailIdx = 0;
                    % Delete promoted ball graphics
                    obj.deleteExtraBallGraphics(eb);
                    obj.ExtraBalls(1) = [];
                else
                    obj.loseLife();
                    return;
                end
            end

            % --- Brick collisions ---
            if ~any(isnan(obj.BallPos))
                [obj.BallPos, obj.BallVel] = obj.brickCollision( ...
                    obj.BallPos, obj.BallVel);
                obj.BallSpeed = norm(obj.BallVel);
            end

            % --- Extra balls ---
            obj.updateExtraBalls(dx, dy, px, pw, py, ph);

            % All balls lost?
            if any(isnan(obj.BallPos)) && isempty(obj.ExtraBalls)
                obj.loseLife();
                return;
            end

            % --- Level clear check ---
            if obj.BricksRemaining <= 0
                obj.nextLevel();
                return;
            end

            % --- Danger zone glow ---

            % --- Update power-ups ---
            obj.updatePowerUps();

            % --- Update ball graphics ---
            obj.updateBallGraphics();

            % --- Lives flash (0.6s hold + 0.4s fade) ---
            if ~isempty(obj.LivesFlashTic) && ~isempty(obj.LivesH) ...
                    && isgraphics(obj.LivesH) && isvalid(obj.LivesH)
                flashElapsed = toc(obj.LivesFlashTic);
                showDur = 0.6;
                fadeDur = 0.4;
                if flashElapsed < showDur
                    obj.LivesH.Color = obj.ColorRed;
                elseif flashElapsed < showDur + fadeDur
                    fadeAlpha = 1 - (flashElapsed - showDur) / fadeDur;
                    obj.LivesH.Color = [obj.ColorRed, max(0, fadeAlpha)];
                else
                    obj.LivesH.Visible = "off";
                    obj.LivesFlashTic = [];
                end
            end

        end

        function onCleanup(obj)
            %onCleanup  Delete all breakout graphics.
            % Ball graphics
            handles = {obj.BallCoreH, obj.BallGlowH, obj.BallAuraH, ...
                       obj.BallTrailH, obj.BallTrailGlowH, ...
                       obj.PaddleH, obj.PaddleGlowH, ...
                       obj.LevelTextH, ...
                       obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.BallCoreH = []; obj.BallGlowH = []; obj.BallAuraH = [];
            obj.BallTrailH = []; obj.BallTrailGlowH = [];
            obj.PaddleH = []; obj.PaddleGlowH = [];
            obj.LevelTextH = [];
            obj.ModeTextH = [];

            % Bricks
            if isstruct(obj.Bricks)
                for k = 1:numel(obj.Bricks)
                    if isfield(obj.Bricks, "patchH") && ~isempty(obj.Bricks(k).patchH) ...
                            && isvalid(obj.Bricks(k).patchH)
                        delete(obj.Bricks(k).patchH);
                    end
                    if isfield(obj.Bricks, "glowH") && ~isempty(obj.Bricks(k).glowH) ...
                            && isvalid(obj.Bricks(k).glowH)
                        delete(obj.Bricks(k).glowH);
                    end
                end
            end
            obj.Bricks = struct("hp", {}, "color", {}, ...
                "x", {}, "y", {}, "w", {}, "h", {}, ...
                "patchH", {}, "glowH", {});

            % Lives text
            if ~isempty(obj.LivesH) && isgraphics(obj.LivesH) && isvalid(obj.LivesH)
                delete(obj.LivesH);
            end
            obj.LivesH = [];
            obj.LivesFlashTic = [];

            % Extra balls
            obj.cleanupExtraBalls();

            % Power-ups
            obj.cleanupPowerUpGraphics();

            % Power bar indicators
            for k = 1:numel(obj.PowerBarH)
                if ~isempty(obj.PowerBarH{k}) && isvalid(obj.PowerBarH{k})
                    delete(obj.PowerBarH{k});
                end
            end
            obj.PowerBarH = {};

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_breakout");
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for breakout.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return breakout-specific results.
            r.Title = "BREAKOUT";

            if obj.Level > obj.MaxLevel
                statusStr = "YOU WIN!";
            elseif obj.Lives <= 0
                statusStr = "GAME OVER";
            else
                statusStr = sprintf("SCORE: %d", obj.Score);
            end

            r.Lines = {
                statusStr
                sprintf("Level: %d/%d  |  Bricks: %d", ...
                    min(obj.Level, obj.MaxLevel), obj.MaxLevel, ...
                    obj.BricksDestroyed)
            };
        end

        function s = getHudText(~)
            %getHudText  HUD managed by ModeTextH; return empty for host.
            s = "";
        end
    end

    % =================================================================
    % PRIVATE METHODS — HUD
    % =================================================================
    methods (Access = private)
        function s = buildHudString(obj)
            %buildHudString  Build HUD string with level and lives.
            s = sprintf("Level %d/%d  |  Lives %d", ...
                min(obj.Level, obj.MaxLevel), obj.MaxLevel, obj.Lives);
        end

        function updateHud(obj)
            %updateHud  Refresh the bottom-left HUD text.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end
    end

    % =================================================================
    % PRIVATE METHODS — brick grid
    % =================================================================
    methods (Access = private)
        function buildBrickGrid(obj, level)
            %buildBrickGrid  Generate brick layout for given level.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);

            % Clear old bricks
            for k = 1:numel(obj.Bricks)
                if ~isempty(obj.Bricks(k).patchH) && isvalid(obj.Bricks(k).patchH)
                    delete(obj.Bricks(k).patchH);
                end
                if ~isempty(obj.Bricks(k).glowH) && isvalid(obj.Bricks(k).glowH)
                    delete(obj.Bricks(k).glowH);
                end
            end

            % Grid dimensions
            nCols = obj.BrickCols;
            brickMargin = round(areaW * 0.03);
            gridW = areaW - 2 * brickMargin;
            brickW = gridW / nCols;
            brickH = max(8, round(areaH * 0.04));
            brickGap = round(2 * obj.Sc);
            gridTop = dy(1) + round(areaH * 0.08);

            % Row colors (top to bottom: red, orange, gold, green, cyan, magenta)
            rowColors = [obj.ColorRed; obj.ColorOrange; obj.ColorGold; ...
                         obj.ColorGreen; obj.ColorCyan; obj.ColorMagenta];

            % Build HP grid based on level
            switch level
                case 1  % Classic: 4 rows, all HP-1
                    nRows = 4;
                    rowHP = [1, 1, 1, 1];
                case 2  % Layered: 5 rows, top rows tougher
                    nRows = 5;
                    rowHP = [2, 2, 1, 1, 1];
                case 3  % Sandwich: 6 rows, tough-soft-tough
                    nRows = 6;
                    rowHP = [3, 2, 1, 1, 2, 3];
                case 4  % Armored: 6 rows, escalating with indestructible shield
                    nRows = 6;
                    rowHP = [3, 3, -1, 2, 2, 1];
                case 5  % Gauntlet: 6 rows all HP-3, indestructible middle
                    nRows = 6;
                    rowHP = [3, 3, -1, 3, 3, 3];
                otherwise
                    nRows = 4;
                    rowHP = [1, 1, 1, 1];
            end
            hpGrid = zeros(nRows, nCols);
            for rowIdx = 1:nRows
                hpGrid(rowIdx, :) = rowHP(rowIdx);
            end
            obj.BrickRows = nRows;

            obj.BrickAreaTop = gridTop;
            obj.BrickAreaBot = gridTop + nRows * brickH;

            % Create brick structs and graphics
            obj.Bricks = struct("hp", {}, "color", {}, ...
                "x", {}, "y", {}, "w", {}, "h", {}, ...
                "patchH", {}, "glowH", {});
            obj.BricksRemaining = 0;
            brickIdx = 0;
            for rowIdx = 1:nRows
                for colIdx = 1:nCols
                    hp = hpGrid(rowIdx, colIdx);
                    if hp == 0; continue; end

                    brickIdx = brickIdx + 1;
                    bx = dx(1) + brickMargin + (colIdx - 1) * brickW;
                    by = gridTop + (rowIdx - 1) * brickH;

                    % Color by row
                    colorIdx = min(rowIdx, size(rowColors, 1));
                    if hp == -1
                        brickColor = obj.ColorSilver;
                    else
                        brickColor = rowColors(colorIdx, :);
                    end

                    % Face alpha by HP
                    if hp == -1
                        fAlpha = 0.5;
                    elseif hp == 1
                        fAlpha = 0.55;
                    elseif hp == 2
                        fAlpha = 0.7;
                    else
                        fAlpha = 0.85;
                    end

                    xv = [bx + brickGap/2, bx + brickW - brickGap/2, ...
                          bx + brickW - brickGap/2, bx + brickGap/2];
                    yv = [by + brickGap/2, by + brickGap/2, ...
                          by + brickH - brickGap/2, by + brickH - brickGap/2];

                    % Glow (behind)
                    glowH = patch(ax, xv, yv, brickColor, ...
                        "FaceAlpha", 0, "EdgeColor", brickColor * 0.35, ...
                        "LineWidth", 4, "Tag", "GT_breakout");

                    % Brick face
                    patchH = patch(ax, xv, yv, brickColor, ...
                        "FaceAlpha", fAlpha, "EdgeColor", brickColor, ...
                        "LineWidth", 1.2, "Tag", "GT_breakout");

                    actualHp = hp;
                    if hp == -1; actualHp = 0; end  % 0 = indestructible

                    obj.Bricks(brickIdx) = struct("hp", actualHp, "color", brickColor, ...
                        "x", bx, "y", by, "w", brickW, "h", brickH, ...
                        "patchH", patchH, "glowH", glowH);

                    if actualHp > 0
                        obj.BricksRemaining = obj.BricksRemaining + 1;
                    end
                end
            end
        end
    end

    % =================================================================
    % PRIVATE METHODS — ball control
    % =================================================================
    methods (Access = private)
        function serveBall(obj)
            %serveBall  Place ball on paddle, prepare serve.
            obj.Serving = true;
            obj.ServeCountdown = 60;  % ~1s at 60fps
            obj.BallPos = [obj.PaddleX, obj.PaddleY - obj.BallRadius - 2];
            obj.BallVel = [0, 0];
            obj.CatchHeld = false;
            obj.TrailBufX(:) = NaN;
            obj.TrailBufY(:) = NaN;
            obj.TrailIdx = 0;
        end

        function launchBall(obj)
            %launchBall  Launch ball from paddle at random upward angle.
            serveAngle = -pi/2 + (rand - 0.5) * pi/3;  % -90 +/- 30 deg
            obj.BallVel = obj.BallSpeed * [cos(serveAngle), sin(serveAngle)];
            obj.Serving = false;
        end

        function [newPos, newVel] = brickCollision(obj, ballPos, ballVel)
            %brickCollision  AABB ball-brick collision with center-based reflection.
            %   Returns updated [newPos, newVel] after all brick bounces.
            %   In fireball mode, ball burns through bricks without bouncing.
            ballR = obj.BallRadius;
            newPos = ballPos;
            newVel = ballVel;
            isFireball = ~isnan(obj.ActivePowers.fireball);

            for k = 1:numel(obj.Bricks)
                brk = obj.Bricks(k);
                if isempty(brk.patchH) || ~isvalid(brk.patchH)
                    continue;
                end

                % AABB closest-point distance check
                bx1 = brk.x;
                bx2 = brk.x + brk.w;
                by1 = brk.y;
                by2 = brk.y + brk.h;
                nearX = max(bx1, min(newPos(1), bx2));
                nearY = max(by1, min(newPos(2), by2));
                distSq = (newPos(1) - nearX)^2 + (newPos(2) - nearY)^2;
                if distSq > ballR^2; continue; end

                % Hit face: compare ball-to-center offset
                bcx = brk.x + brk.w / 2;
                bcy = brk.y + brk.h / 2;
                dcx = newPos(1) - bcx;
                dcy = newPos(2) - bcy;

                if isFireball
                    bounceNormal = [0, sign(dcy)];
                else
                    if abs(dcx / brk.w) > abs(dcy / brk.h)
                        bounceNormal = [sign(dcx), 0];
                        newVel(1) = -newVel(1);
                        newPos(1) = bcx + sign(dcx) * (brk.w/2 + ballR + 1);
                        newVel = newVel * 1.008;
                    else
                        bounceNormal = [0, sign(dcy)];
                        newVel(2) = -newVel(2);
                        newPos(2) = bcy + sign(dcy) * (brk.h/2 + ballR + 1);
                        newVel = newVel * 1.008;
                    end
                end

                % Damage brick
                if brk.hp > 0
                    if isFireball
                        % Fireball: instant destroy regardless of HP
                        obj.Bricks(k).hp = 0;
                        obj.destroyBrick(k);
                    else
                        obj.Bricks(k).hp = brk.hp - 1;
                        if obj.Bricks(k).hp == 0
                            obj.destroyBrick(k);
                        else
                            % Reduce alpha as brick takes damage
                            newAlpha = 0.2 + obj.Bricks(k).hp * 0.25;
                            if isvalid(brk.patchH)
                                brk.patchH.FaceAlpha = newAlpha;
                            end
                        end
                    end

                    % Scoring
                    basePoints = brk.hp * 100 + 100;
                    totalPoints = round(basePoints * obj.comboMultiplier());
                    obj.addScore(totalPoints);
                    obj.incrementCombo();
                else
                    % Indestructible — bounce even in fireball mode
                    if isFireball
                        if abs(dcx / brk.w) > abs(dcy / brk.h)
                            newVel(1) = -newVel(1);
                            newPos(1) = bcx + sign(dcx) * (brk.w/2 + ballR + 1);
                        else
                            newVel(2) = -newVel(2);
                            newPos(2) = bcy + sign(dcy) * (brk.h/2 + ballR + 1);
                        end
                    end
                    spd = norm(ballVel);
                    sRatio = spd / max(obj.BallBaseSpeed, 1);
                    mSpeed = 3 + (sRatio - 1) * 12;
                    obj.spawnBounceEffect([brk.x + brk.w/2, brk.y + brk.h/2], ...
                        bounceNormal, 0, mSpeed);
                end

                if ~isFireball
                    break;  % one collision per frame (fireball passes through)
                end
            end
        end

        function destroyBrick(obj, brickIdx)
            %destroyBrick  Remove brick, spawn bounce effect, maybe power-up.
            brk = obj.Bricks(brickIdx);
            brickCenter = [brk.x + brk.w/2, brk.y + brk.h/2];

            % Spawn bounce effect at brick center
            isFireball = ~isnan(obj.ActivePowers.fireball);
            if isFireball
                mappedSpeed = 17;  % Force red during fireball
            else
                spd = norm(obj.BallVel);
                speedRatio = spd / max(obj.BallBaseSpeed, 1);
                mappedSpeed = 3 + (speedRatio - 1) * 12;
            end
            obj.spawnBounceEffect(brickCenter, [0, 1], 0, mappedSpeed);

            % Delete brick graphics
            if ~isempty(brk.patchH) && isvalid(brk.patchH)
                delete(brk.patchH);
            end
            if ~isempty(brk.glowH) && isvalid(brk.glowH)
                delete(brk.glowH);
            end
            obj.Bricks(brickIdx).patchH = [];
            obj.Bricks(brickIdx).glowH = [];
            obj.BricksRemaining = obj.BricksRemaining - 1;
            obj.BricksDestroyed = obj.BricksDestroyed + 1;

            % Maybe spawn power-up (~18% chance)
            if rand < 0.18
                obj.spawnPowerUp(brickCenter(1), brickCenter(2));
            end
        end
    end

    % =================================================================
    % PRIVATE METHODS — lives and levels
    % =================================================================
    methods (Access = private)
        function loseLife(obj)
            %loseLife  Handle ball exiting bottom.
            obj.Lives = obj.Lives - 1;
            obj.updateLivesDisplay();
            obj.updateHud();
            obj.resetCombo();

            % Clean up extra balls
            obj.cleanupExtraBalls();

            % Clear all falling and active power-ups
            obj.cleanupPowerUpGraphics();
            obj.PaddleW = obj.PaddleBaseW;
            obj.BallSpeed = obj.BallBaseSpeed;
            obj.CatchHeld = false;
            obj.ActivePowers = struct("wide", {{}}, "slow", {{}}, "fireball", NaN);

            if obj.Lives <= 0
                obj.IsRunning = false;
            else
                obj.serveBall();
            end
        end

        function updateLivesDisplay(obj)
            %updateLivesDisplay  Flash lives remaining in center of screen.
            if isempty(obj.LivesH) || ~isgraphics(obj.LivesH) || ~isvalid(obj.LivesH)
                return;
            end
            if obj.Lives > 0
                obj.LivesH.String = sprintf("Lives: %d", obj.Lives);
            else
                obj.LivesH.String = "GAME OVER";
            end
            obj.LivesH.Color = obj.ColorRed;
            obj.LivesH.Visible = "on";
            obj.LivesFlashTic = tic;
        end

        function nextLevel(obj)
            %nextLevel  Advance to next level with transition effect.
            obj.Level = obj.Level + 1;
            obj.updateHud();
            if obj.Level > obj.MaxLevel
                % Won the game
                obj.IsRunning = false;
                return;
            end

            % Level transition
            obj.LevelPhase = "transition";
            obj.LevelTransFrames = 96;

            % Flash remaining bricks white
            for k = 1:numel(obj.Bricks)
                brk = obj.Bricks(k);
                if ~isempty(brk.patchH) && isvalid(brk.patchH)
                    brk.patchH.FaceColor = [1, 1, 1];
                    brk.patchH.FaceAlpha = 0.8;
                end
            end

            % Show level text
            if ~isempty(obj.LevelTextH) && isvalid(obj.LevelTextH)
                obj.LevelTextH.String = sprintf("LEVEL %d", obj.Level);
                obj.LevelTextH.Color = [obj.ColorGold, 1];
                obj.LevelTextH.Visible = "on";
            end

            % Level clear bonus
            obj.addScore(500 * (obj.Level - 1));

            % Reset power-ups and extra balls
            obj.cleanupExtraBalls();
            obj.cleanupPowerUpGraphics();
            obj.PaddleW = obj.PaddleBaseW;
            obj.BallSpeed = obj.BallBaseSpeed;
            obj.CatchHeld = false;
            obj.ActivePowers = struct("wide", {{}}, "slow", {{}}, "fireball", NaN);
        end
    end

    % =================================================================
    % PRIVATE METHODS — power-ups
    % =================================================================
    methods (Access = private)
        function spawnPowerUp(obj, x, y)
            %spawnPowerUp  Create falling power-up capsule.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            types = ["F", "M", "S", "W", "L"];
            colors = {obj.ColorRed, obj.ColorMagenta, obj.ColorGreen, ...
                      obj.ColorCyan, obj.ColorGold};
            typeIdx = randi(numel(types));
            pType = types(typeIdx);
            pColor = colors{typeIdx};
            pSpeed = 0.625 * obj.Sc;

            % Glow aura
            glowH = line(ax, x, y, "Color", [pColor, 0.2], ...
                "Marker", ".", "MarkerSize", 20, ...
                "LineStyle", "none", "Tag", "GT_breakout");

            % Capsule body
            theta = linspace(0, 2*pi, 24);
            capR = round(5 * obj.Sc);
            patchH = patch(ax, x + capR*cos(theta), y + capR*sin(theta), ...
                pColor, "FaceAlpha", 0.6, "EdgeColor", pColor, ...
                "LineWidth", 1.5, "Tag", "GT_breakout");

            % Label
            textH = text(ax, x, y, char(pType), "Color", [1, 1, 1], ...
                "FontSize", 15, "FontWeight", "bold", ...
                "HorizontalAlignment", "center", "VerticalAlignment", "middle", ...
                "Tag", "GT_breakout");

            pu.type = pType;
            pu.x = x;
            pu.y = y;
            pu.speed = pSpeed;
            pu.patchH = patchH;
            pu.glowH = glowH;
            pu.textH = textH;
            obj.PowerUps(end + 1) = pu;
        end

        function applyPowerUp(obj, pType)
            %applyPowerUp  Activate a caught power-up.
            switch pType
                case "W"
                    % Wide paddle (stacks: each adds 1.6x)
                    obj.ActivePowers.wide{end + 1} = tic;
                    obj.PaddleW = obj.PaddleBaseW * 1.6 ^ numel(obj.ActivePowers.wide);
                case "M"
                    % Multi-ball: each existing ball splits into 3
                    obj.spawnExtraBalls();
                case "S"
                    % Slow ball (stacks: each adds 0.6x)
                    obj.ActivePowers.slow{end + 1} = tic;
                    slowFactor = 0.6 ^ numel(obj.ActivePowers.slow);
                    obj.BallSpeed = obj.BallBaseSpeed * slowFactor;
                    obj.applySpeedToAllBalls(obj.BallSpeed);
                case "F"
                    % Fireball: ball burns through bricks without bouncing
                    obj.ActivePowers.fireball = tic;
                case "L"
                    % Extra life
                    if obj.Lives < obj.MaxLives
                        obj.Lives = obj.Lives + 1;
                        obj.updateLivesDisplay();
                        obj.updateHud();
                    end
            end

            % Score for catching
            obj.addScore(50);
        end

        function updatePowerUps(obj)
            %updatePowerUps  Move falling capsules, check catch, expire.
            dy = obj.DisplayRange.Y;
            toRemove = [];

            for k = 1:numel(obj.PowerUps)
                pu = obj.PowerUps(k);
                pu.y = pu.y + pu.speed * obj.DtScale;
                obj.PowerUps(k).y = pu.y;

                % Update graphics position
                if ~isempty(pu.patchH) && isvalid(pu.patchH)
                    set(pu.patchH, "XData", pu.x + obj.PowerUpCapR * obj.CosT24, ...
                        "YData", pu.y + obj.PowerUpCapR * obj.SinT24);
                end
                if ~isempty(pu.glowH) && isvalid(pu.glowH)
                    set(pu.glowH, "XData", pu.x, "YData", pu.y);
                end
                if ~isempty(pu.textH) && isvalid(pu.textH)
                    pu.textH.Position = [pu.x, pu.y, 0];
                end

                % Check paddle catch
                if pu.y >= obj.PaddleY && pu.y <= obj.PaddleY + obj.PaddleHt
                    if abs(pu.x - obj.PaddleX) <= obj.PaddleW / 2
                        obj.applyPowerUp(pu.type);
                        toRemove(end + 1) = k; %#ok<AGROW>
                        continue;
                    end
                end

                % Off screen
                if pu.y > dy(2) + 20
                    toRemove(end + 1) = k; %#ok<AGROW>
                end
            end

            % Remove caught/off-screen power-ups
            for k = numel(toRemove):-1:1
                removeIdx = toRemove(k);
                pu = obj.PowerUps(removeIdx);
                if ~isempty(pu.patchH) && isvalid(pu.patchH); delete(pu.patchH); end
                if ~isempty(pu.glowH) && isvalid(pu.glowH); delete(pu.glowH); end
                if ~isempty(pu.textH) && isvalid(pu.textH); delete(pu.textH); end
                obj.PowerUps(removeIdx) = [];
            end

            % Expire timed power-ups (stacking: remove expired entries)
            expired = false(1, numel(obj.ActivePowers.wide));
            for wIdx = 1:numel(obj.ActivePowers.wide)
                if toc(obj.ActivePowers.wide{wIdx}) > 12
                    expired(wIdx) = true;
                end
            end
            if any(expired)
                obj.ActivePowers.wide(expired) = [];
                nWide = numel(obj.ActivePowers.wide);
                if nWide == 0
                    obj.PaddleW = obj.PaddleBaseW;
                else
                    obj.PaddleW = obj.PaddleBaseW * 1.6 ^ nWide;
                end
            end

            expired = false(1, numel(obj.ActivePowers.slow));
            for wIdx = 1:numel(obj.ActivePowers.slow)
                if toc(obj.ActivePowers.slow{wIdx}) > 8
                    expired(wIdx) = true;
                end
            end
            if any(expired)
                obj.ActivePowers.slow(expired) = [];
                nSlow = numel(obj.ActivePowers.slow);
                if nSlow == 0
                    obj.BallSpeed = obj.BallBaseSpeed;
                else
                    obj.BallSpeed = obj.BallBaseSpeed * 0.6 ^ nSlow;
                end
                obj.applySpeedToAllBalls(obj.BallSpeed);
            end

            if ~isnan(obj.ActivePowers.fireball) && toc(obj.ActivePowers.fireball) > 6
                obj.ActivePowers.fireball = NaN;
            end
        end

        function cleanupPowerUpGraphics(obj)
            %cleanupPowerUpGraphics  Delete all falling power-up graphics.
            for k = 1:numel(obj.PowerUps)
                pu = obj.PowerUps(k);
                if ~isempty(pu.patchH) && isvalid(pu.patchH); delete(pu.patchH); end
                if ~isempty(pu.glowH) && isvalid(pu.glowH); delete(pu.glowH); end
                if ~isempty(pu.textH) && isvalid(pu.textH); delete(pu.textH); end
            end
            obj.PowerUps = struct("type", {}, "x", {}, "y", {}, ...
                "speed", {}, "patchH", {}, "glowH", {}, "textH", {});
        end
    end

    % =================================================================
    % PRIVATE METHODS — multi-ball
    % =================================================================
    methods (Access = private)
        function spawnExtraBalls(obj)
            %spawnExtraBalls  Each existing ball splits into 3 (2 clones each).
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            ballR = obj.BallRadius;
            auraSize = max(15, ballR * 5);
            coreSize = max(6, ballR * 2);
            glowWidth = max(2, ballR * 0.6);
            theta = linspace(0, 2*pi, 48);
            splitAngles = [-pi/4, pi/4];

            % Collect source ball positions/velocities (primary + extras)
            sources = {};
            if ~any(isnan(obj.BallPos))
                sources{end + 1} = struct("pos", obj.BallPos, "vel", obj.BallVel);
            end
            for k = 1:numel(obj.ExtraBalls)
                sources{end + 1} = struct("pos", obj.ExtraBalls(k).pos, ...
                    "vel", obj.ExtraBalls(k).vel); %#ok<AGROW>
            end

            % Spawn 2 clones per source ball
            for sIdx = 1:numel(sources)
                src = sources{sIdx};
                spd = norm(src.vel);
                if spd < 1; spd = obj.BallSpeed; end
                for aIdx = 1:2
                    bpos = src.pos;
                    bvel = spd * [cos(splitAngles(aIdx) - pi/2), ...
                                  sin(splitAngles(aIdx) - pi/2)];

                    aH = line(ax, bpos(1), bpos(2), ...
                        "Color", [obj.ColorCyan, 0.15], "Marker", ".", ...
                        "MarkerSize", auraSize, "LineStyle", "none", "Tag", "GT_breakout");
                    gH = line(ax, bpos(1) + ballR*cos(theta), bpos(2) + ballR*sin(theta), ...
                        "Color", [obj.ColorCyan, 0.4], "LineWidth", glowWidth, ...
                        "Tag", "GT_breakout");
                    cH = line(ax, bpos(1), bpos(2), ...
                        "Color", [1, 1, 1, 1], "Marker", ".", ...
                        "MarkerSize", coreSize, "LineStyle", "none", "Tag", "GT_breakout");
                    tH = line(ax, NaN, NaN, ...
                        "Color", [obj.ColorCyan, 0.3], "LineWidth", 1.5, "Tag", "GT_breakout");
                    tgH = line(ax, NaN, NaN, ...
                        "Color", [obj.ColorCyan, 0.08], "LineWidth", 5, "Tag", "GT_breakout");

                    eb = struct("pos", bpos, "vel", bvel, ...
                        "coreH", cH, "glowH", gH, "auraH", aH, ...
                        "trailH", tH, "trailGlowH", tgH, ...
                        "trailBufX", NaN(1, 15), "trailBufY", NaN(1, 15), "trailIdx", 0);
                    obj.ExtraBalls(end + 1) = eb;
                end
            end
        end

        function applySpeedToAllBalls(obj, targetSpeed)
            %applySpeedToAllBalls  Set speed on primary + all extra balls.
            if ~any(isnan(obj.BallPos))
                currentSpeed = norm(obj.BallVel);
                if currentSpeed > 0
                    obj.BallVel = obj.BallVel / currentSpeed * targetSpeed;
                end
            end
            for k = 1:numel(obj.ExtraBalls)
                ebSpeed = norm(obj.ExtraBalls(k).vel);
                if ebSpeed > 0
                    obj.ExtraBalls(k).vel = obj.ExtraBalls(k).vel / ebSpeed * targetSpeed;
                end
            end
        end

        function updateExtraBalls(obj, dx, dy, px, pw, py, ph)
            %updateExtraBalls  Physics, collision, rendering for extra balls.
            extraToRemove = [];
            for k = 1:numel(obj.ExtraBalls)
                eb = obj.ExtraBalls(k);
                eb.pos = eb.pos + eb.vel * obj.DtScale;

                % Wall bounces
                if eb.pos(2) < dy(1)
                    eb.pos(2) = dy(1);
                    eb.vel(2) = -eb.vel(2);
                end
                if eb.pos(1) < dx(1)
                    eb.pos(1) = dx(1);
                    eb.vel(1) = -eb.vel(1);
                end
                if eb.pos(1) > dx(2)
                    eb.pos(1) = dx(2);
                    eb.vel(1) = -eb.vel(1);
                end

                % Paddle collision
                if eb.pos(2) >= py && eb.pos(2) <= py + ph && eb.vel(2) > 0
                    if eb.pos(1) >= px - pw/2 && eb.pos(1) <= px + pw/2
                        hitOffset = eb.pos(1) - px;
                        normalizedOffset = max(-1, min(1, hitOffset / (pw/2)));
                        returnAngle = normalizedOffset * pi/3;
                        ebSpeed = norm(eb.vel);
                        eb.vel = ebSpeed * [sin(returnAngle), -cos(returnAngle)];
                        eb.pos(2) = py - obj.BallRadius - 1;
                    end
                end

                % Bottom exit
                if eb.pos(2) > dy(2) + obj.BallRadius * 2
                    extraToRemove(end + 1) = k; %#ok<AGROW>
                    obj.ExtraBalls(k) = eb;
                    continue;
                end

                % Brick collision for extra ball
                [eb.pos, eb.vel] = obj.brickCollision(eb.pos, eb.vel);

                % Trail
                eb.trailIdx = mod(eb.trailIdx, 15) + 1;
                eb.trailBufX(eb.trailIdx) = eb.pos(1);
                eb.trailBufY(eb.trailIdx) = eb.pos(2);

                % Speed-based color
                ebSpeed = norm(eb.vel);
                ebRatio = ebSpeed / max(obj.BallBaseSpeed, 1);
                ebMapped = 3 + (ebRatio - 1) * 12;
                ebColor = obj.flickSpeedColor(ebMapped);
                ebFireball = ~isnan(obj.ActivePowers.fireball);

                % Update graphics (3-layer: aura, glow ring, core)
                if ~isempty(eb.auraH) && isvalid(eb.auraH)
                    if ebFireball
                        set(eb.auraH, "XData", eb.pos(1), "YData", eb.pos(2), ...
                            "Color", [obj.ColorRed, 0.25], ...
                            "MarkerSize", max(20, obj.BallRadius * 7));
                    else
                        set(eb.auraH, "XData", eb.pos(1), "YData", eb.pos(2), ...
                            "Color", [ebColor, 0.15], ...
                            "MarkerSize", max(15, obj.BallRadius * 5));
                    end
                end
                if ~isempty(eb.glowH) && isvalid(eb.glowH)
                    if ebFireball
                        glC = obj.ColorRed; glA = 0.7;
                    else
                        glC = ebColor; glA = 0.5;
                    end
                    set(eb.glowH, "XData", eb.pos(1) + obj.BallRadius * obj.CosT48, ...
                        "YData", eb.pos(2) + obj.BallRadius * obj.SinT48, ...
                        "Color", [glC, glA]);
                end
                if ~isempty(eb.coreH) && isvalid(eb.coreH)
                    set(eb.coreH, "XData", eb.pos(1), "YData", eb.pos(2));
                end

                % Trail rendering
                trailN = 15;
                trailOrder = mod((eb.trailIdx:eb.trailIdx + trailN - 1), trailN) + 1;
                tx = eb.trailBufX(trailOrder);
                ty = eb.trailBufY(trailOrder);
                firstValid = find(~isnan(tx), 1, "first");
                if ~isempty(firstValid)
                    tx = tx(firstValid:end);
                    ty = ty(firstValid:end);
                end
                if ebFireball
                    trailColor = obj.ColorRed;
                else
                    trailColor = ebColor;
                end
                if ~isempty(eb.trailH) && isvalid(eb.trailH)
                    set(eb.trailH, "XData", tx, "YData", ty, ...
                        "Color", [trailColor, 0.3]);
                end
                if ~isempty(eb.trailGlowH) && isvalid(eb.trailGlowH)
                    set(eb.trailGlowH, "XData", tx, "YData", ty, ...
                        "Color", [trailColor, 0.08]);
                end

                obj.ExtraBalls(k) = eb;
            end

            % Remove dead extra balls
            for k = numel(extraToRemove):-1:1
                removeIdx = extraToRemove(k);
                eb = obj.ExtraBalls(removeIdx);
                obj.deleteExtraBallGraphics(eb);
                obj.ExtraBalls(removeIdx) = [];
            end
        end

        function cleanupExtraBalls(obj)
            %cleanupExtraBalls  Delete all extra ball graphics.
            for k = 1:numel(obj.ExtraBalls)
                obj.deleteExtraBallGraphics(obj.ExtraBalls(k));
            end
            obj.ExtraBalls = struct("pos", {}, "vel", {}, ...
                "coreH", {}, "glowH", {}, "auraH", {}, "trailH", {}, "trailGlowH", {}, ...
                "trailBufX", {}, "trailBufY", {}, "trailIdx", {});
        end
    end

    % =================================================================
    % PRIVATE METHODS — ball graphics
    % =================================================================
    methods (Access = private)
        function updateBallGraphics(obj)
            %updateBallGraphics  Update ball, trail, and glow visuals.
            if any(isnan(obj.BallPos))
                % Hide ball
                if ~isempty(obj.BallCoreH) && isvalid(obj.BallCoreH)
                    obj.BallCoreH.XData = NaN; obj.BallCoreH.YData = NaN;
                end
                if ~isempty(obj.BallGlowH) && isvalid(obj.BallGlowH)
                    obj.BallGlowH.XData = NaN; obj.BallGlowH.YData = NaN;
                end
                if ~isempty(obj.BallAuraH) && isvalid(obj.BallAuraH)
                    obj.BallAuraH.XData = NaN; obj.BallAuraH.YData = NaN;
                end
                return;
            end

            spd = norm(obj.BallVel);
            % Map ball speed to flickSpeedColor range
            speedRatio = spd / max(obj.BallBaseSpeed, 1);
            mappedSpeed = 3 + (speedRatio - 1) * 12;
            ballColor = obj.flickSpeedColor(mappedSpeed);
            ballR = obj.BallRadius;
            isFireball = ~isnan(obj.ActivePowers.fireball);

            % Core
            if ~isempty(obj.BallCoreH) && isvalid(obj.BallCoreH)
                set(obj.BallCoreH, "XData", obj.BallPos(1), ...
                    "YData", obj.BallPos(2));
            end

            % Glow ring — red outglow during fireball
            if ~isempty(obj.BallGlowH) && isvalid(obj.BallGlowH)
                if isFireball
                    glowColor = obj.ColorRed;
                    glowAlpha = 0.7;
                else
                    glowColor = ballColor;
                    glowAlpha = 0.5;
                end
                set(obj.BallGlowH, ...
                    "XData", obj.BallPos(1) + ballR * obj.CosT48, ...
                    "YData", obj.BallPos(2) + ballR * obj.SinT48, ...
                    "Color", [glowColor, glowAlpha]);
            end

            % Aura — larger red aura during fireball
            if ~isempty(obj.BallAuraH) && isvalid(obj.BallAuraH)
                if isFireball
                    auraColor = obj.ColorRed;
                    auraAlpha = 0.25;
                    auraSize = max(20, ballR * 7);
                else
                    auraColor = ballColor;
                    auraAlpha = 0.15;
                    auraSize = max(15, ballR * 5);
                end
                set(obj.BallAuraH, "XData", obj.BallPos(1), ...
                    "YData", obj.BallPos(2), "Color", [auraColor, auraAlpha], ...
                    "MarkerSize", auraSize);
            end

            % Trail buffer
            if spd > 0.3
                obj.TrailIdx = mod(obj.TrailIdx, obj.TrailLen) + 1;
                obj.TrailBufX(obj.TrailIdx) = obj.BallPos(1);
                obj.TrailBufY(obj.TrailIdx) = obj.BallPos(2);
            end

            % Trail rendering
            if spd > 0.5 && obj.TrailIdx > 0
                trailN = obj.TrailLen;
                trailOrder = mod((obj.TrailIdx:obj.TrailIdx + trailN - 1), trailN) + 1;
                tx = obj.TrailBufX(trailOrder);
                ty = obj.TrailBufY(trailOrder);
                firstValid = find(~isnan(tx), 1, "first");
                if ~isempty(firstValid)
                    tx = tx(firstValid:end);
                    ty = ty(firstValid:end);
                end
                trailAlpha = min(0.5, 0.15 + spd * 0.03);
                trailWidth = min(3.5, 1.5 + spd * 0.1);
                if isFireball
                    trailColor = obj.ColorRed;
                else
                    trailColor = ballColor;
                end
                if ~isempty(obj.BallTrailH) && isvalid(obj.BallTrailH)
                    set(obj.BallTrailH, "XData", tx, "YData", ty, ...
                        "Color", [trailColor, trailAlpha], "LineWidth", trailWidth);
                end
                if ~isempty(obj.BallTrailGlowH) && isvalid(obj.BallTrailGlowH)
                    set(obj.BallTrailGlowH, "XData", tx, "YData", ty, ...
                        "Color", [trailColor, trailAlpha * 0.25], ...
                        "LineWidth", trailWidth * 3);
                end
            else
                if ~isempty(obj.BallTrailH) && isvalid(obj.BallTrailH)
                    obj.BallTrailH.XData = NaN; obj.BallTrailH.YData = NaN;
                end
                if ~isempty(obj.BallTrailGlowH) && isvalid(obj.BallTrailGlowH)
                    obj.BallTrailGlowH.XData = NaN; obj.BallTrailGlowH.YData = NaN;
                end
            end
        end
    end

    % =================================================================
    % STATIC UTILITIES
    % =================================================================
    methods (Static, Access = private)
        function deleteExtraBallGraphics(eb)
            %deleteExtraBallGraphics  Delete graphics for a single extra ball.
            if ~isempty(eb.coreH) && isvalid(eb.coreH); delete(eb.coreH); end
            if ~isempty(eb.glowH) && isvalid(eb.glowH); delete(eb.glowH); end
            if ~isempty(eb.auraH) && isvalid(eb.auraH); delete(eb.auraH); end
            if ~isempty(eb.trailH) && isvalid(eb.trailH); delete(eb.trailH); end
            if ~isempty(eb.trailGlowH) && isvalid(eb.trailGlowH); delete(eb.trailGlowH); end
        end
    end
end
