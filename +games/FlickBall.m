classdef FlickBall < GameBase
    %FlickBall  Physics-based flick ball game with wall bounces.
    %   A ball sits at the center of the screen. Move your finger through
    %   it with velocity to flick it. The ball bounces off walls with
    %   parametric collision detection. Re-flicking a moving ball builds
    %   combo. Speed-to-color gradient, 3-layer rendering (core + glow +
    %   aura), and a 30-frame comet trail provide visual feedback.
    %
    %   Standalone: games.FlickBall().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Flick Ball"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Ball physics
        BallPos             (1,2) double = [NaN, NaN]   % ball center [x, y]
        BallVel             (1,2) double = [0, 0]        % velocity [vx, vy] px/frame
        BallRadius          (1,1) double = 10            % display radius
        HitRadius           (1,1) double = 22            % flick detection radius
        Friction            (1,1) double = 0.99          % velocity decay per frame
        Restitution         (1,1) double = 0.80          % energy retained on wall bounce
        BallMoving          (1,1) logical = false         % ball is in motion
        BallPhase           (1,1) double = 0             % animation phase (radians)
        FlickSpeed          (1,1) double = 0             % speed of most recent flick

        % Trail circular buffer
        TrailBufX           (1,:) double                 % trail X positions
        TrailBufY           (1,:) double                 % trail Y positions
        TrailIdx            (1,1) double = 0             % trail write index
        TrailLen            (1,1) double = 30            % trail buffer capacity

        % Finger velocity tracking
        PrevFingerPos       (1,2) double = [NaN, NaN]   % previous finger position
        FingerVelBuf        (:,2) double = zeros(5, 2)   % 5-frame velocity ring buffer
        FingerVelIdx        (1,1) double = 0             % velocity buffer write index
        FlickLocked         (1,1) logical = false         % one flick per contact

        % Session stats
        Bounces             (1,1) double = 0             % bounces in current flight
        TotalBounces        (1,1) double = 0             % total bounces this session
        TotalFlicks         (1,1) double = 0             % total flicks this session
        MaxSpeed            (1,1) double = 0             % peak speed (px/frame)
        LastFlickTic        uint64                        % tic of last flick (combo decay)

        % Combo display
        ComboTextH                                        % text handle for combo display
        ComboFadeTic        uint64                        % tic when combo fade-out started
        ComboFadeColor      (1,3) double = [0.2, 1, 0.4] % fade color
        ComboShowTic        uint64                        % tic when combo text appeared

        % Display scaling
        SpeedScale          (1,1) double = 1               % visual speed normalization: 240/minDim

        % Cached constants
        ThetaCircle48       (1,48) double                 % pre-computed linspace(0,2pi,48)
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        CoreH                   % line — bright core dot
        GlowH                   % line — neon glow ring
        AuraH                   % line — outer soft aura
        TrailH                   % line — comet trail
        TrailGlowH               % line — trail soft glow
        SpeedTextH               % text — speed/bounces near ball
        ModeTextH                % text — bottom-left HUD label
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize ball at center.
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
            obj.ShowHostCombo = false;

            dx = displayRange.X;
            dy = displayRange.Y;
            cx = mean(dx);
            cy = mean(dy);

            % Scale ball size to display
            areaW = diff(dx);
            areaH = diff(dy);
            minDim = min(areaH, areaW);
            obj.BallRadius = max(5, round(minDim * 0.042));
            obj.HitRadius = max(10, round(obj.BallRadius * 2.2));

            % Visual speed normalization (like Pong's SpeedScale pattern)
            obj.SpeedScale = 240 / minDim;

            % Ball state
            obj.BallPos = [cx, cy];
            obj.BallVel = [0, 0];
            obj.BallMoving = false;
            obj.Bounces = 0;
            obj.TotalBounces = 0;
            obj.TotalFlicks = 0;
            obj.MaxSpeed = 0;
            obj.BallPhase = 0;
            obj.FlickSpeed = 0;
            obj.PrevFingerPos = [NaN, NaN];
            obj.FingerVelBuf = zeros(5, 2);
            obj.FingerVelIdx = 0;
            obj.FlickLocked = false;
            obj.LastFlickTic = uint64.empty;
            obj.ComboFadeTic = uint64.empty;
            obj.ComboShowTic = uint64.empty;

            % Trail buffer
            obj.TrailBufX = NaN(1, obj.TrailLen);
            obj.TrailBufY = NaN(1, obj.TrailLen);
            obj.TrailIdx = 0;

            % Pre-compute constant arrays
            obj.ThetaCircle48 = linspace(0, 2*pi, 48);

            % --- Create graphics (layered for depth) ---

            % Trail glow (wide, soft, behind everything)
            obj.TrailGlowH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.12], "LineWidth", 8, ...
                "LineStyle", "-", "Visible", "on", "Tag", "GT_flick");

            % Trail line (thinner, on top of glow)
            obj.TrailH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.5], "LineWidth", 2.5, ...
                "LineStyle", "-", "Visible", "on", "Tag", "GT_flick");

            % Outer aura (large soft glow)
            obj.AuraH = line(ax, NaN, NaN, ...
                "Color", [obj.ColorCyan, 0.15], "Marker", ".", ...
                "MarkerSize", 50, "LineStyle", "none", ...
                "Visible", "on", "Tag", "GT_flick");

            % Glow ring
            theta = linspace(0, 2*pi, 48);
            rr = obj.BallRadius;
            obj.GlowH = line(ax, cx + rr * cos(theta), cy + rr * sin(theta), ...
                "Color", [obj.ColorCyan, 0.4], "LineWidth", 6, ...
                "LineStyle", "-", "Visible", "on", "Tag", "GT_flick");

            % Bright core dot
            obj.CoreH = line(ax, cx, cy, ...
                "Color", [1, 1, 1, 1], "Marker", ".", ...
                "MarkerSize", 18, "LineStyle", "none", ...
                "Visible", "on", "Tag", "GT_flick");

            % Speed/bounces text (near ball)
            obj.SpeedTextH = text(ax, cx, cy - rr - 8, "", ...
                "Color", [obj.ColorCyan, 0.8], "FontSize", 10, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "bottom", "Visible", "off", ...
                "Tag", "GT_flick");

            % Combo text (pre-allocated, hidden until needed)
            obj.ComboTextH = text(ax, 0, 0, "", ...
                "Color", obj.ColorGold * 0.8, "FontSize", 13, ...
                "FontWeight", "bold", "HorizontalAlignment", "center", ...
                "VerticalAlignment", "top", "Visible", "off", "Tag", "GT_flick");

            % Bottom-left HUD text (static)
            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, ...
                "FLICK [move through ball]  |  RESET [0]", ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_flick");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame flick ball physics and rendering.

            % --- 1. Update finger velocity buffer ---
            if ~any(isnan(pos)) && ~any(isnan(obj.PrevFingerPos))
                fvel = pos - obj.PrevFingerPos;
                writeIdx = mod(obj.FingerVelIdx, 5) + 1;
                obj.FingerVelBuf(writeIdx, :) = fvel;
                obj.FingerVelIdx = writeIdx;
            end
            obj.PrevFingerPos = pos;

            % --- 2. Check for flick (finger contacts ball with velocity) ---
            if ~any(isnan(pos)) && ~any(isnan(obj.BallPos))
                distToBall = norm(pos - obj.BallPos);
                if distToBall <= obj.HitRadius
                    if ~obj.FlickLocked
                        nFilled = min(obj.FingerVelIdx, 5);
                        if nFilled >= 2
                            avgVel = mean(obj.FingerVelBuf(1:nFilled, :), 1);
                            flickSpd = norm(avgVel);
                            if flickSpd >= 3 / obj.SpeedScale  % scaled flick threshold
                                obj.applyFlick(avgVel);
                                obj.FlickLocked = true;
                            end
                        end
                    end
                else
                    % Finger left the radius -- unlock for next contact
                    obj.FlickLocked = false;
                end
            else
                obj.FlickLocked = false;
            end

            % --- 3. Ball physics (if moving) ---
            if obj.BallMoving
                obj.stepBallPhysics();
            end

            % --- 4. Animation phase ---
            obj.BallPhase = obj.BallPhase + 0.08;

            % --- 5. Combo decay (2s after last flick) ---
            obj.updateComboDecay();

            % --- 6. Combo text fade animation ---
            obj.updateComboFade();

            % --- 7. Update graphics ---
            obj.updateGraphics();
        end

        function onCleanup(obj)
            %onCleanup  Delete all flick ball graphics.
            handles = {obj.CoreH, obj.GlowH, obj.AuraH, ...
                       obj.TrailH, obj.TrailGlowH, obj.SpeedTextH, ...
                       obj.ComboTextH, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h)
                    delete(h);
                end
            end
            obj.CoreH = [];
            obj.GlowH = [];
            obj.AuraH = [];
            obj.TrailH = [];
            obj.TrailGlowH = [];
            obj.SpeedTextH = [];
            obj.ComboTextH = [];
            obj.ModeTextH = [];

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_flick");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle mode-specific keys.
            %   0 key resets the ball to center.
            handled = false;
            if key == "0"
                obj.resetBall();
                handled = true;
            end
        end

        function r = getResults(obj)
            %getResults  Return flick ball session results.
            r.Title = "FLICK BALL";
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            r.Lines = {
                sprintf("Flicks: %d  |  Bounces: %d  |  Max Speed: %.0f  |  Max Combo: %d", ...
                    obj.TotalFlicks, obj.TotalBounces, obj.MaxSpeed * 10, obj.MaxCombo)
                sprintf("Time: %.1fs", elapsed)
            };
        end

        function s = getHudText(~)
            %getHudText  HUD managed by ModeTextH; return empty for host.
            s = "";
        end
    end

    % =================================================================
    % PRIVATE METHODS — PHYSICS
    % =================================================================
    methods (Access = private)

        function applyFlick(obj, fingerVel)
            %applyFlick  Transfer finger velocity to ball.
            wasMoving = obj.BallMoving;

            % Transfer velocity (1.3x boost for satisfying feel)
            obj.BallVel = fingerVel * 1.3;
            obj.BallMoving = true;
            obj.Bounces = 0;
            obj.TotalFlicks = obj.TotalFlicks + 1;

            spd = norm(obj.BallVel);
            obj.FlickSpeed = spd;
            obj.MaxSpeed = max(obj.MaxSpeed, spd);
            obj.LastFlickTic = tic;

            % Combo: re-flicking a moving ball increases combo
            if wasMoving
                obj.incrementCombo();
            else
                obj.Combo = 1;
                obj.MaxCombo = max(obj.MaxCombo, 1);
            end

            % Flick launch bonus: base points proportional to speed
            launchPoints = round(spd * obj.SpeedScale * 5 * max(1, obj.Combo * 0.5));
            obj.addScore(launchPoints);

            % Reset trail for clean start
            obj.TrailBufX(:) = NaN;
            obj.TrailBufY(:) = NaN;
            obj.TrailIdx = 0;

            % Visual effects
            clr = obj.flickSpeedColor(spd * obj.SpeedScale);
            obj.spawnHitEffect(obj.BallPos, clr, launchPoints, obj.BallRadius + 5);
            if obj.Combo >= 2
                obj.showComboText(obj.BallPos + [0, -20]);
            end

            % Clear velocity buffer to prevent re-triggering next frame
            obj.FingerVelBuf(:) = 0;
            obj.FingerVelIdx = 0;
        end

        function stepBallPhysics(obj)
            %stepBallPhysics  Advance ball position, apply friction, handle wall bounces.

            % Save pre-move position for parametric wall intersection
            prePos = obj.BallPos;
            stepVel = obj.BallVel;

            % Apply velocity
            obj.BallPos = obj.BallPos + obj.BallVel;

            % Apply air friction
            obj.BallVel = obj.BallVel * obj.Friction;

            % Wall collision — parametric intersection so both X and Y
            % are at the exact contact point (preserves approach angle)
            xLim = obj.DisplayRange.X;
            yLim = obj.DisplayRange.Y;
            bounced = false;
            bouncePos = obj.BallPos;
            bounceNormal = [0, 0];

            % Left wall
            if obj.BallPos(1) < xLim(1) && stepVel(1) ~= 0
                tHit = min(1, max(0, (xLim(1) - prePos(1)) / stepVel(1)));
                obj.BallPos(2) = prePos(2) + tHit * stepVel(2);
                obj.BallPos(1) = xLim(1);
                obj.BallVel(1) = -obj.BallVel(1) * obj.Restitution;
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [1, 0];
            end
            % Right wall
            if obj.BallPos(1) > xLim(2) && stepVel(1) ~= 0
                tHit = min(1, max(0, (xLim(2) - prePos(1)) / stepVel(1)));
                obj.BallPos(2) = prePos(2) + tHit * stepVel(2);
                obj.BallPos(1) = xLim(2);
                obj.BallVel(1) = -obj.BallVel(1) * obj.Restitution;
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [-1, 0];
            end
            % Top wall
            if obj.BallPos(2) < yLim(1) && stepVel(2) ~= 0
                tHit = min(1, max(0, (yLim(1) - prePos(2)) / stepVel(2)));
                obj.BallPos(1) = prePos(1) + tHit * stepVel(1);
                obj.BallPos(2) = yLim(1);
                obj.BallVel(2) = -obj.BallVel(2) * obj.Restitution;
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [0, 1];
            end
            % Bottom wall
            if obj.BallPos(2) > yLim(2) && stepVel(2) ~= 0
                tHit = min(1, max(0, (yLim(2) - prePos(2)) / stepVel(2)));
                obj.BallPos(1) = prePos(1) + tHit * stepVel(1);
                obj.BallPos(2) = yLim(2);
                obj.BallVel(2) = -obj.BallVel(2) * obj.Restitution;
                bounced = true;
                bouncePos = obj.BallPos;
                bounceNormal = [0, -1];
            end

            if bounced
                obj.Bounces = obj.Bounces + 1;
                obj.TotalBounces = obj.TotalBounces + 1;

                % Score per bounce: base + speed bonus, scaled by combo
                spd = norm(obj.BallVel);
                bouncePoints = round((5 + spd * obj.SpeedScale * 2) * max(1, obj.Combo * 0.5));
                obj.addScore(bouncePoints);

                % Spawn wall spark effect with points display
                obj.spawnBounceEffect(bouncePos, bounceNormal, bouncePoints, spd * obj.SpeedScale);
            end

            % Track max speed
            spd = norm(obj.BallVel);
            obj.MaxSpeed = max(obj.MaxSpeed, spd);

            % Update trail buffer (ball center position)
            tidx = mod(obj.TrailIdx, obj.TrailLen) + 1;
            obj.TrailBufX(tidx) = obj.BallPos(1);
            obj.TrailBufY(tidx) = obj.BallPos(2);
            obj.TrailIdx = tidx;

            % Check if ball stopped
            if spd < 0.3 / obj.SpeedScale
                obj.BallVel = [0, 0];
                obj.BallMoving = false;
                obj.Bounces = 0;
                obj.FlickLocked = false;
                % Clear trail
                obj.TrailBufX(:) = NaN;
                obj.TrailBufY(:) = NaN;
                obj.TrailIdx = 0;
            end
        end

        function resetBall(obj)
            %resetBall  Reset ball to center, clear state.
            cx = mean(obj.DisplayRange.X);
            cy = mean(obj.DisplayRange.Y);
            obj.BallPos = [cx, cy];
            obj.BallVel = [0, 0];
            obj.BallMoving = false;
            obj.Bounces = 0;
            obj.BallPhase = 0;
            obj.FlickLocked = false;
            obj.TrailBufX(:) = NaN;
            obj.TrailBufY(:) = NaN;
            obj.TrailIdx = 0;
            obj.FingerVelBuf(:) = 0;
            obj.FingerVelIdx = 0;
        end
    end

    % =================================================================
    % PRIVATE METHODS — GRAPHICS
    % =================================================================
    methods (Access = private)

        function updateGraphics(obj)
            %updateGraphics  Render ball, trail, and info text.
            if any(isnan(obj.BallPos)); return; end

            bx = obj.BallPos(1);
            by = obj.BallPos(2);
            spd = norm(obj.BallVel);
            rr = obj.BallRadius;

            % Speed-based color
            clr = obj.flickSpeedColor(spd * obj.SpeedScale);

            % --- Idle breathing (ball not moving) ---
            if ~obj.BallMoving
                breath = 1 + 0.12 * sin(obj.BallPhase);
                auraScale = 1.2 + 0.15 * sin(obj.BallPhase * 0.7);
            else
                breath = 1;
                auraScale = 1 + min(1.5, spd * 0.08);  % aura grows with speed
            end

            % --- Core dot ---
            if ~isempty(obj.CoreH) && isvalid(obj.CoreH)
                obj.CoreH.XData = bx;
                obj.CoreH.YData = by;
                coreSize = round(18 * breath);
                obj.CoreH.MarkerSize = coreSize;
                coreAlpha = min(1, 0.8 + spd * 0.02);
                obj.CoreH.Color = [1, 1, 1, coreAlpha];
            end

            % --- Glow ring ---
            if ~isempty(obj.GlowH) && isvalid(obj.GlowH)
                gr = rr * breath;
                obj.GlowH.XData = bx + gr * cos(obj.ThetaCircle48);
                obj.GlowH.YData = by + gr * sin(obj.ThetaCircle48);
                glowAlpha = 0.3 + min(0.5, spd * 0.04);
                glowWidth = 4 + min(4, spd * 0.3);
                obj.GlowH.Color = [clr, glowAlpha];
                obj.GlowH.LineWidth = glowWidth;
            end

            % --- Outer aura ---
            if ~isempty(obj.AuraH) && isvalid(obj.AuraH)
                obj.AuraH.XData = bx;
                obj.AuraH.YData = by;
                auraSize = round(50 * auraScale);
                auraAlpha = 0.1 + min(0.2, spd * 0.015);
                obj.AuraH.MarkerSize = auraSize;
                obj.AuraH.Color = [clr, auraAlpha];
            end

            % --- Trail ---
            if obj.BallMoving && obj.TrailIdx > 0
                % Extract trail in order (oldest to newest)
                nBuf = obj.TrailLen;
                trailOrder = mod((obj.TrailIdx:obj.TrailIdx + nBuf - 1), nBuf) + 1;
                tx = obj.TrailBufX(trailOrder);
                ty = obj.TrailBufY(trailOrder);
                % Remove NaN-only prefix
                firstValid = find(~isnan(tx), 1, "first");
                if ~isempty(firstValid)
                    tx = tx(firstValid:end);
                    ty = ty(firstValid:end);
                end

                trailAlpha = min(0.6, 0.2 + spd * 0.04);
                trailWidth = min(4, 1.5 + spd * 0.15);
                glowTrailWidth = trailWidth * 3;
                glowTrailAlpha = trailAlpha * 0.25;

                if ~isempty(obj.TrailH) && isvalid(obj.TrailH)
                    obj.TrailH.XData = tx;
                    obj.TrailH.YData = ty;
                    obj.TrailH.Color = [clr, trailAlpha];
                    obj.TrailH.LineWidth = trailWidth;
                end
                if ~isempty(obj.TrailGlowH) && isvalid(obj.TrailGlowH)
                    obj.TrailGlowH.XData = tx;
                    obj.TrailGlowH.YData = ty;
                    obj.TrailGlowH.Color = [clr, glowTrailAlpha];
                    obj.TrailGlowH.LineWidth = glowTrailWidth;
                end
            else
                % Hide trail when stopped
                if ~isempty(obj.TrailH) && isvalid(obj.TrailH)
                    obj.TrailH.XData = NaN;
                    obj.TrailH.YData = NaN;
                end
                if ~isempty(obj.TrailGlowH) && isvalid(obj.TrailGlowH)
                    obj.TrailGlowH.XData = NaN;
                    obj.TrailGlowH.YData = NaN;
                end
            end

            % --- Speed/bounce info text ---
            if ~isempty(obj.SpeedTextH) && isvalid(obj.SpeedTextH)
                if obj.BallMoving
                    obj.SpeedTextH.String = sprintf("%.0f  |  %d bounces", ...
                        spd * 10, obj.Bounces);
                    obj.SpeedTextH.Position = [bx, by - rr * breath - 6, 0];
                    obj.SpeedTextH.Color = [clr, 0.7];
                    obj.SpeedTextH.Visible = "on";
                else
                    obj.SpeedTextH.String = "FLICK ME";
                    obj.SpeedTextH.Position = [bx, by - rr * breath - 6, 0];
                    flicker = 0.4 + 0.3 * sin(obj.BallPhase * 1.5);
                    obj.SpeedTextH.Color = [obj.ColorCyan, flicker];
                    obj.SpeedTextH.Visible = "on";
                end
            end
        end
    end

    % =================================================================
    % PRIVATE METHODS — COMBO DISPLAY
    % =================================================================
    methods (Access = private)

        function showComboText(obj, hitPos)
            %showComboText  Show combo text briefly at hit location.
            if obj.Combo >= 2
                % Cancel any active fade
                obj.ComboFadeTic = uint64.empty;
                if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH); return; end
                obj.ComboTextH.String = sprintf("%dx Combo", obj.Combo);
                obj.ComboTextH.Color = obj.ColorGreen * 0.9;
                if ~any(isnan(hitPos))
                    obj.ComboTextH.Position = [hitPos(1), hitPos(2) + 12, 0];
                end
                obj.ComboTextH.Visible = "on";
                obj.ComboShowTic = tic;
            else
                % Start fade-out instead of immediate delete
                if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                    obj.ComboFadeTic = tic;
                    obj.ComboFadeColor = obj.ColorGreen * 0.9;
                end
            end
        end

        function updateComboDecay(obj)
            %updateComboDecay  Decay combo 2s after last flick, with pre-fade.
            if obj.Combo > 0 && ~isempty(obj.LastFlickTic)
                comboAge = toc(obj.LastFlickTic);
                if comboAge > 2
                    obj.resetCombo();
                    if ~isempty(obj.ComboTextH) && isvalid(obj.ComboTextH)
                        obj.ComboFadeTic = tic;
                        obj.ComboFadeColor = obj.ColorGreen * 0.9;
                    end
                elseif comboAge > 0.5 && ~isempty(obj.ComboTextH) ...
                        && isvalid(obj.ComboTextH)
                    % Pre-reset fade: 0.5s to 2s window
                    fade = 1 - (comboAge - 0.5) / 1.5;
                    obj.ComboTextH.Color = [obj.ColorGreen * 0.9, max(fade, 0)];
                end
            end
        end

        function updateComboFade(obj)
            %updateComboFade  Animate combo text fade-out, hide when done.
            if isempty(obj.ComboTextH) || ~isvalid(obj.ComboTextH)
                obj.ComboFadeTic = uint64.empty;
                obj.ComboShowTic = uint64.empty;
                return;
            end

            % Auto-trigger fade after 1s display
            if ~isempty(obj.ComboShowTic) && isempty(obj.ComboFadeTic)
                if toc(obj.ComboShowTic) >= 1.0
                    obj.ComboFadeTic = tic;
                    obj.ComboFadeColor = obj.ColorGreen * 0.9;
                    obj.ComboShowTic = uint64.empty;
                end
            end

            % Animate fade-out
            if isempty(obj.ComboFadeTic); return; end
            elapsed = toc(obj.ComboFadeTic);
            fadeDur = 0.6;
            if elapsed >= fadeDur
                obj.ComboTextH.Visible = "off";
                obj.ComboFadeTic = uint64.empty;
            else
                alphaVal = max(0, 1 - elapsed / fadeDur);
                obj.ComboTextH.Color = [obj.ComboFadeColor, alphaVal];
            end
        end
    end
end
