classdef (Abstract) GameBase < handle
    %GameBase  Abstract base class for all standalone/hosted games.
    %   Provides shared infrastructure: scoring, combo, hit effects, color
    %   constants, and speed-to-color mapping. Each game subclass implements
    %   4 abstract methods: onInit, onUpdate, onCleanup, onKeyPress.
    %
    %   Standalone usage:
    %       game = games.FlickBall();
    %       game.play();   % opens figure, uses mouse input
    %
    %   Hosted usage (inside GestureMouse via GameHost):
    %       game = games.FlickBall();
    %       game.onInit(ax, displayRange);
    %       game.onUpdate(fingerPos);  % called each frame by host
    %       game.onCleanup();
    %
    %   See also GameHost, GestureMouse

    % =================================================================
    % PUBLIC READABLE PROPERTIES
    % =================================================================
    properties (SetAccess = {?GameBase, ?GameHost})
        Ax                              % axes handle (set by onInit)
        DisplayRange    struct = struct("X", [0 640], "Y", [0 480])
        Score           (1,1) double = 0
        Combo           (1,1) double = 0
        MaxCombo        (1,1) double = 0
        IsRunning       (1,1) logical = false
        StartTic                        % tic at game start
    end

    % =================================================================
    % HIT EFFECTS POOL
    % =================================================================
    properties (SetAccess = protected)
        HitEffects      struct = struct("handles", {}, "frames", {}, ...
                                        "maxFrames", {}, "x", {}, "y", {}, ...
                                        "color", {}, "radius", {}, "nRays", {})
    end

    % =================================================================
    % COLOR CONSTANTS
    % =================================================================
    properties (Constant)
        ColorCyan       (1,3) double = [0, 0.92, 1]
        ColorGreen      (1,3) double = [0.2, 1, 0.4]
        ColorGold       (1,3) double = [1, 0.85, 0.2]
        ColorRed        (1,3) double = [1, 0.3, 0.2]
        ColorWhite      (1,3) double = [1, 1, 1]
        ColorMagenta    (1,3) double = [1, 0.3, 0.85]
    end

    % =================================================================
    % GAME IDENTITY (override in subclasses)
    % =================================================================
    properties (Constant, Abstract)
        Name            string          % display name (e.g., "Flick Ball")
    end

    % =================================================================
    % ABSTRACT METHODS — must be implemented by every game
    % =================================================================
    methods (Abstract)
        onInit(obj, ax, displayRange, caps)
        %onInit  Create graphics, initialize state.
        %   ax           — axes handle to draw on
        %   displayRange — struct with .X=[min max], .Y=[min max]
        %   caps         — struct with optional host capabilities (default empty)

        onUpdate(obj, pos)
        %onUpdate  Per-frame update. pos = [x, y] finger/mouse position.

        onCleanup(obj)
        %onCleanup  Delete all graphics, reset state.

        handled = onKeyPress(obj, key)
        %onKeyPress  Handle key event. Return true if consumed.
    end

    % =================================================================
    % OPTIONAL OVERRIDES (default implementations provided)
    % =================================================================
    methods
        function r = getResults(obj)
            %getResults  Return struct with game-specific results.
            %   Override in subclasses for custom results display.
            r.Title = obj.Name;
            r.Lines = {};
        end

        function s = getHudText(~)
            %getHudText  Return mode-specific HUD string (bottom of screen).
            %   Override in subclasses. Return "" for no HUD.
            s = "";
        end

        function onPause(~)
            %onPause  Called when host pauses game. Override if needed.
        end

        function onResume(~)
            %onResume  Called when host resumes game. Override if needed.
        end
    end

    % =================================================================
    % SCORING HELPERS (call from subclasses)
    % =================================================================
    methods (Access = protected)
        function addScore(obj, pts)
            %addScore  Add points to the score.
            obj.Score = obj.Score + pts;
        end

        function incrementCombo(obj)
            %incrementCombo  Increment combo counter, update max.
            obj.Combo = obj.Combo + 1;
            obj.MaxCombo = max(obj.MaxCombo, obj.Combo);
        end

        function resetCombo(obj)
            %resetCombo  Reset combo counter to zero.
            obj.Combo = 0;
        end

        function m = comboMultiplier(obj)
            %comboMultiplier  Score multiplier from current combo.
            m = max(1, obj.Combo / 10);
        end
    end

    % =================================================================
    % HIT EFFECTS — shared visual effects system
    % =================================================================
    methods (Access = protected)
        function spawnBounceEffect(obj, pos, normal, points, speed)
            %spawnBounceEffect  Wall impact spark with points display.
            %   Creates ring + directional rays + points text.
            %   pos    — [x, y] impact position
            %   normal — [nx, ny] impact direction (for ray spread)
            %   points — score to display (0 = no text)
            %   speed  — ball speed for color/size (optional, default 5)
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            if nargin < 5; speed = 5; end
            clr = obj.flickSpeedColor(speed);
            sparkLen = 6 + speed * 1.5;

            nRays = 5;
            maxFrames = 22;
            handles = gobjects(1, nRays + 2);

            % Handle 1: expanding ring at impact point
            theta = linspace(0, 2*pi, 48);
            ringR = sparkLen * 0.5;
            handles(1) = line(ax, pos(1) + ringR * cos(theta), ...
                pos(2) + ringR * sin(theta), ...
                "Color", [clr, 0.8], "LineWidth", 2, "Tag", "GT_fx");

            % Handles 2..nRays+1: spark rays from impact point
            baseAngle = atan2(normal(2), normal(1));
            sparkAngles = baseAngle + linspace(-pi/3, pi/3, nRays);
            for k = 1:nRays
                sdx = cos(sparkAngles(k));
                sdy = sin(sparkAngles(k));
                handles(k + 1) = line(ax, ...
                    [pos(1), pos(1) + sparkLen * sdx], ...
                    [pos(2), pos(2) + sparkLen * sdy], ...
                    "Color", [clr, 0.9], "LineWidth", 2, "Tag", "GT_fx");
            end

            % Handle end: points text (skip if zero)
            if points > 0
                handles(end) = text(ax, pos(1), pos(2) - sparkLen - 4, ...
                    sprintf("+%d", points), ...
                    "Color", clr, "FontSize", 10, ...
                    "FontWeight", "bold", "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "bottom", "Tag", "GT_fx");
            else
                handles(end) = [];
            end

            effect.handles = handles;
            effect.frames = maxFrames;
            effect.maxFrames = maxFrames;
            effect.x = pos(1);
            effect.y = pos(2);
            effect.color = clr;
            effect.radius = sparkLen;
            effect.nRays = nRays;
            obj.HitEffects(end + 1) = effect;
        end

        function spawnHitEffect(obj, pos, clr, points, effectRadius)
            %spawnHitEffect  Expanding ring + radial burst at pos.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end
            if nargin < 5; effectRadius = 20; end

            nRays = 8;
            maxFrames = 18;
            handles = gobjects(1, nRays + 2);

            % Expanding ring
            theta = linspace(0, 2*pi, 48);
            handles(1) = line(ax, pos(1) + effectRadius * cos(theta), ...
                pos(2) + effectRadius * sin(theta), ...
                "Color", [clr, 0.9], "LineWidth", 3, "Tag", "GT_fx");

            % Radial burst lines
            angles = linspace(0, 2*pi, nRays + 1);
            angles = angles(1:end-1);
            for k = 1:nRays
                ddx = cos(angles(k));
                ddy = sin(angles(k));
                r0 = effectRadius * 0.5;
                handles(k + 1) = line(ax, ...
                    [pos(1) + r0 * ddx, pos(1) + effectRadius * ddx], ...
                    [pos(2) + r0 * ddy, pos(2) + effectRadius * ddy], ...
                    "Color", [clr, 0.8], "LineWidth", 2, "Tag", "GT_fx");
            end

            % Points text
            if points > 0
                handles(end) = text(ax, pos(1), pos(2) - effectRadius - 8, ...
                    sprintf("+%d", points), ...
                    "Color", clr, "FontSize", 14, ...
                    "FontWeight", "bold", "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "bottom", "Tag", "GT_fx");
            else
                handles(end) = text(ax, pos(1), pos(2) - effectRadius - 8, ...
                    "MISS", ...
                    "Color", clr, "FontSize", 12, ...
                    "FontWeight", "bold", "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "bottom", "Tag", "GT_fx");
            end

            effect.handles = handles;
            effect.frames = maxFrames;
            effect.maxFrames = maxFrames;
            effect.x = pos(1);
            effect.y = pos(2);
            effect.color = clr;
            effect.radius = effectRadius;
            effect.nRays = nRays;
            obj.HitEffects(end + 1) = effect;
        end

    end

    % =================================================================
    % HIT EFFECTS — public animation/cleanup (called by GameHost)
    % =================================================================
    methods
        function updateHitEffects(obj)
            %updateHitEffects  Animate and clean up active hit effects.
            toRemove = [];
            for k = 1:numel(obj.HitEffects)
                fx = obj.HitEffects(k);
                fx.frames = fx.frames - 1;
                obj.HitEffects(k).frames = fx.frames;

                if fx.frames <= 0
                    for j = 1:numel(fx.handles)
                        if isvalid(fx.handles(j))
                            delete(fx.handles(j));
                        end
                    end
                    toRemove(end + 1) = k; %#ok<AGROW>
                    continue;
                end

                % Animation progress (0->1, where 1 = fully faded)
                t = 1 - fx.frames / fx.maxFrames;
                eased = 1 - (1 - t)^2;  % ease-out
                alpha = max(0, 1 - eased * 1.5);
                expandScale = 1 + eased * 2.5;

                % Update ring (handle 1)
                baseR = fx.radius;
                if numel(fx.handles) >= 1 && isvalid(fx.handles(1))
                    if fx.nRays > 0 || ~isa(fx.handles(1), "matlab.graphics.primitive.Text")
                        theta = linspace(0, 2*pi, 48);
                        r = baseR * expandScale;
                        fx.handles(1).XData = fx.x + r * cos(theta);
                        fx.handles(1).YData = fx.y + r * sin(theta);
                        fx.handles(1).Color = [fx.color, alpha * 0.8];
                        fx.handles(1).LineWidth = max(0.5, 3 * (1 - eased));
                    end
                end

                % Update burst lines (handles 2 to nRays+1)
                nRays = fx.nRays;
                if nRays > 0
                    angles = linspace(0, 2*pi, nRays + 1);
                    angles = angles(1:end-1);
                    for j = 1:nRays
                        h = fx.handles(j + 1);
                        if ~isvalid(h); continue; end
                        ddx = cos(angles(j));
                        ddy = sin(angles(j));
                        r0 = baseR * (0.5 + eased * 1.5);
                        r1 = baseR * (1.0 + eased * 3.0);
                        h.XData = [fx.x + r0 * ddx, fx.x + r1 * ddx];
                        h.YData = [fx.y + r0 * ddy, fx.y + r1 * ddy];
                        h.Color = [fx.color, alpha * 0.6];
                        h.LineWidth = max(0.5, 2 * (1 - eased));
                    end
                end

                % Update points text (last handle)
                textH = fx.handles(end);
                if isvalid(textH) && isa(textH, "matlab.graphics.primitive.Text")
                    textH.Position(2) = fx.y - baseR - 8 - eased * 20;
                    textH.Color = [fx.color, max(alpha, 0)];
                    textH.FontSize = max(8, round(14 * (1 + eased * 0.3)));
                end
            end

            % Remove expired effects
            if ~isempty(toRemove)
                obj.HitEffects(toRemove) = [];
            end
        end

        function cleanupHitEffects(obj)
            %cleanupHitEffects  Delete all active hit effect graphics.
            for k = 1:numel(obj.HitEffects)
                for j = 1:numel(obj.HitEffects(k).handles)
                    if isvalid(obj.HitEffects(k).handles(j))
                        delete(obj.HitEffects(k).handles(j));
                    end
                end
            end
            obj.HitEffects = struct("handles", {}, "frames", {}, ...
                "maxFrames", {}, "x", {}, "y", {}, "color", {}, ...
                "radius", {}, "nRays", {});
        end
    end

    % =================================================================
    % COLOR UTILITIES
    % =================================================================
    methods (Access = protected)
        function c = flickSpeedColor(obj, speed)
            %flickSpeedColor  Map speed to neon color gradient.
            %   cyan (slow) -> green (medium) -> gold (fast) -> red (very fast)
            if speed < 3
                c = obj.ColorCyan;
            elseif speed < 7
                t = (speed - 3) / 4;
                c = obj.ColorCyan * (1 - t) + obj.ColorGreen * t;
            elseif speed < 12
                t = (speed - 7) / 5;
                c = obj.ColorGreen * (1 - t) + obj.ColorGold * t;
            else
                t = min(1, (speed - 12) / 5);
                c = obj.ColorGold * (1 - t) + obj.ColorRed * t;
            end
        end
    end

    % =================================================================
    % STATIC UTILITIES (shared across many games)
    % =================================================================
    methods (Static)
        function [r, g, b] = hsvToRgb(h)
            %hsvToRgb  Convert hue [0,1] to saturated RGB (S=1, V=1).
            hi = floor(h * 6);
            f = h * 6 - hi;
            switch mod(hi, 6)
                case 0; r = 1; g = f;     b = 0;
                case 1; r = 1-f; g = 1;   b = 0;
                case 2; r = 0; g = 1;     b = f;
                case 3; r = 0; g = 1-f;   b = 1;
                case 4; r = f; g = 0;     b = 1;
                case 5; r = 1; g = 0;     b = 1-f;
            end
        end

        function names = lbmColormapNames()
            %lbmColormapNames  17 curated MATLAB colormap names.
            names = ["parula", "turbo", "jet", "hsv", "hot", "cool", ...
                "spring", "summer", "autumn", "winter", "gray", "bone", ...
                "copper", "pink", "sky", "abyss", "nebula"];
        end

        function deleteTaggedGraphics(ax, tagPattern)
            %deleteTaggedGraphics  Delete all graphics matching tag regex.
            if isempty(ax) || ~isvalid(ax); return; end
            orphans = findall(ax, "-regexp", "Tag", tagPattern);
            if ~isempty(orphans); delete(orphans); end
        end
    end

    % =================================================================
    % STANDALONE PLAY (mouse-driven, creates own figure)
    % =================================================================
    methods
        function play(obj)
            %play  Launch game in standalone mode with mouse input.
            %   Creates figure, axes, timer, and mouse tracking.
            %   Close the figure to stop.
            fig = figure("Color", "k", "WindowState", "maximized", ...
                "MenuBar", "none", "ToolBar", "none", ...
                "Name", obj.Name, "NumberTitle", "off");
            ax = axes(fig, "Position", [0 0 1 1], "Color", "k", ...
                "XLim", [0 640], "YLim", [0 480], "YDir", "reverse", ...
                "Visible", "off", "XTick", [], "YTick", []);
            hold(ax, "on");
            range = struct("X", [0 640], "Y", [0 480]);

            % Initialize game
            obj.onInit(ax, range, struct());
            obj.IsRunning = true;
            obj.StartTic = tic;

            % Mouse tracking state (closure variable)
            mousePos = [320, 240];  % center default

            fig.WindowButtonMotionFcn = @(~, ~) updateMouse();
            fig.KeyPressFcn = @(~, e) onKey(e);

            % Timer for physics ticking
            tmr = timer("ExecutionMode", "fixedSpacing", "Period", 0.02, ...
                "TimerFcn", @(~, ~) tick(), ...
                "ErrorFcn", @(~, ~) []);
            start(tmr);

            fig.CloseRequestFcn = @(~, ~) cleanup();

            % --- Score HUD ---
            scoreH = text(ax, range.X(1) + 2, range.Y(1) + 2, "Score: 0", ...
                "Color", obj.ColorGreen * 0.9, "FontSize", 14, ...
                "FontWeight", "bold", "HorizontalAlignment", "left", ...
                "VerticalAlignment", "top", "Tag", "GT_standaloneHUD");

            function updateMouse()
                cp = get(ax, "CurrentPoint");
                mousePos = cp(1, 1:2);
            end

            function tick()
                if ~obj.IsRunning; return; end
                try
                    obj.onUpdate(mousePos);
                    obj.updateHitEffects();
                    % Update score display
                    scoreH.String = sprintf("Score: %d", obj.Score);
                    drawnow;
                catch me
                    fprintf(2, "[GameBase.play] %s\n", me.message);
                end
            end

            function onKey(e)
                key = string(e.Key);
                if key == "escape"
                    cleanup();
                    return;
                end
                obj.onKeyPress(key);
            end

            function cleanup()
                obj.IsRunning = false;
                if isvalid(tmr)
                    stop(tmr);
                    delete(tmr);
                end
                obj.onCleanup();
                obj.cleanupHitEffects();
                if isvalid(fig)
                    delete(fig);
                end
            end
        end
    end
end
