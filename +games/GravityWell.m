classdef GravityWell < GameBase
    %GravityWell  N-body gravity sandbox with finger attractor.
    %   Six colored particles orbit around a finger-controlled gravity well.
    %   Real 1/r^2 gravity with leapfrog integration. Particles spawn from
    %   edges with tangential velocity for orbital injection. Score by keeping
    %   2+ particles in orbit near the finger.
    %
    %   Controls:
    %       M     — cycle attract / repel
    %
    %   Standalone: games.GravityWell().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Gravity Well"
    end

    % =================================================================
    % PHYSICS CONSTANTS
    % =================================================================
    properties (Access = private, Constant)
        GravConst       (1,1) double = 5       % gravitational constant
        FingerMass      (1,1) double = 100     % finger attractor mass
        Softening       (1,1) double = 225     % 15^2 softening
        Damping         (1,1) double = 0.998   % per-frame velocity damping
        VelocityCap     (1,1) double = 4       % max speed px/frame
        MaxParticles    (1,1) double = 6
        TrailLength     (1,1) double = 20
        SpawnInterval   (1,1) double = 12      % frames between spawns
        RepelRadius     (1,1) double = 60      % short-range repel cutoff
        OffScreenMargin (1,1) double = 40
        OrbitFraction   (1,1) double = 0.4     % orbit scoring radius
    end

    % =================================================================
    % SCALED PHYSICS (computed in onInit from display size)
    % =================================================================
    properties (Access = private)
        ScaledGravConst     (1,1) double = 5
        ScaledSoftening     (1,1) double = 225
        ScaledVelocityCap   (1,1) double = 4
        ScaledRepelRadius   (1,1) double = 60
        ScaledOffScreenMargin (1,1) double = 40
        DisplayScale        (1,1) double = 1       % min(areaW,areaH)/180
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        Particles       struct = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                                        "particleMass", {}, "colorIdx", {}, ...
                                        "coreH", {}, "glowH", {}, ...
                                        "trailX", {}, "trailY", {}, "trailIdx", {}, ...
                                        "trailGlowH", {}, "trailH", {})
        SpawnTimer      (1,1) double = 0
        FrameCount      (1,1) double = 0
        SubMode         (1,1) string = "attract"   % attract | repel
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        FingerGlowH             % scatter — outer glow
        FingerGlowH2            % scatter — inner core
        ModeTextH               % text — sub-mode label
        ShowOrb         (1,1) logical = false
    end

    % =================================================================
    % PARTICLE COLORS
    % =================================================================
    properties (Access = private, Constant)
        ParticleColors = [0, 0.92, 1;       % cyan
                          0.2, 1, 0.4;      % green
                          1, 0.85, 0.2;     % gold
                          1, 0.3, 0.85;     % magenta
                          0.6, 0.4, 1.0;    % purple
                          1, 0.3, 0.2]      % red
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize N-body sandbox state.
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

            obj.SpawnTimer = 0;
            obj.FrameCount = 0;
            obj.SubMode = "attract";

            % Scale physics constants to display size (tuned for ~180px minDim)
            areaW = displayRange.X(2) - displayRange.X(1);
            areaH = displayRange.Y(2) - displayRange.Y(1);
            sc = min(areaW, areaH) / 180;
            obj.DisplayScale          = sc;
            obj.ScaledGravConst       = obj.GravConst * sc^2;
            obj.ScaledSoftening       = obj.Softening * sc^2;   % (15*sc)^2
            obj.ScaledVelocityCap     = obj.VelocityCap * sc;
            obj.ScaledRepelRadius     = obj.RepelRadius * sc;
            obj.ScaledOffScreenMargin = obj.OffScreenMargin * sc;

            obj.Particles = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "particleMass", {}, "colorIdx", {}, "coreH", {}, "glowH", {}, ...
                "trailX", {}, "trailY", {}, "trailIdx", {}, ...
                "trailGlowH", {}, "trailH", {});

            dx = displayRange.X;
            dy = displayRange.Y;

            % Mode text indicator
            obj.ModeTextH = text(ax, dx(1) + 5, dy(2) - 5, ...
                "ATTRACT [M]", ...
                "Color", [obj.ColorCyan, 0.6], "FontSize", 8, ...
                "VerticalAlignment", "bottom", "Tag", "GT_gravitywell");

            % Finger attractor orb (2-layer: outer glow + opaque core)
            if obj.ShowOrb
                obj.FingerGlowH2 = scatter(ax, mean(dx), mean(dy), 1000, ...
                    obj.ColorCyan, "filled", "MarkerFaceAlpha", 0.15, ...
                    "Tag", "GT_gravitywell");
                obj.FingerGlowH = scatter(ax, mean(dx), mean(dy), 350, ...
                    obj.ColorCyan, "filled", "MarkerFaceAlpha", 1.0, ...
                    "Tag", "GT_gravitywell");
            end
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame N-body gravity simulation.
            obj.FrameCount = obj.FrameCount + 1;

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            tLen = obj.TrailLength;

            % Update finger glow position
            if ~any(isnan(pos))
                if ~isempty(obj.FingerGlowH) && isvalid(obj.FingerGlowH)
                    obj.FingerGlowH.XData = pos(1);
                    obj.FingerGlowH.YData = pos(2);
                end
                if ~isempty(obj.FingerGlowH2) && isvalid(obj.FingerGlowH2)
                    obj.FingerGlowH2.XData = pos(1);
                    obj.FingerGlowH2.YData = pos(2);
                end
            end

            % Spawn particles on timer
            obj.SpawnTimer = obj.SpawnTimer + 1;
            if obj.SpawnTimer >= obj.SpawnInterval ...
                    && numel(obj.Particles) < obj.MaxParticles
                obj.SpawnTimer = 0;
                obj.spawnParticle();
            end

            % Build attractor array: [x, y, mass]
            attractorData = [];
            if ~any(isnan(pos))
                fMass = obj.FingerMass;
                if obj.SubMode == "repel"
                    fMass = -fMass;
                end
                attractorData = [pos(1), pos(2), fMass];
            end

            % Physics update for each particle
            pidx = 1;
            while pidx <= numel(obj.Particles)
                p = obj.Particles(pidx);
                accelX = 0;
                accelY = 0;

                % Gravity from finger (1/r^2)
                for ai = 1:size(attractorData, 1)
                    ddx = attractorData(ai, 1) - p.x;
                    ddy = attractorData(ai, 2) - p.y;
                    r2 = ddx^2 + ddy^2 + obj.ScaledSoftening;
                    rDist = sqrt(r2);
                    forceVal = obj.ScaledGravConst * attractorData(ai, 3) ...
                        * p.particleMass / r2;

                    % Repel mode: short-range only (quadratic falloff)
                    if attractorData(ai, 3) < 0
                        if rDist > obj.ScaledRepelRadius
                            forceVal = 0;
                        else
                            forceVal = forceVal ...
                                * (1 - rDist / obj.ScaledRepelRadius)^2;
                        end
                    end
                    accelX = accelX + forceVal * ddx / rDist;
                    accelY = accelY + forceVal * ddy / rDist;
                end

                % Leapfrog integration (half-step velocity)
                p.vx = p.vx + accelX * 0.5;
                p.vy = p.vy + accelY * 0.5;
                p.x = p.x + p.vx;
                p.y = p.y + p.vy;
                p.vx = p.vx + accelX * 0.5;
                p.vy = p.vy + accelY * 0.5;

                % Gentle damping + velocity cap
                p.vx = p.vx * obj.Damping;
                p.vy = p.vy * obj.Damping;
                spd = sqrt(p.vx^2 + p.vy^2);
                if spd > obj.ScaledVelocityCap
                    scaleFactor = obj.ScaledVelocityCap / spd;
                    p.vx = p.vx * scaleFactor;
                    p.vy = p.vy * scaleFactor;
                end

                % Trail update (circular buffer)
                p.trailIdx = mod(p.trailIdx, tLen) + 1;
                p.trailX(p.trailIdx) = p.x;
                p.trailY(p.trailIdx) = p.y;

                obj.Particles(pidx) = p;

                % Off-screen removal — combo resets on particle loss
                if p.x < dx(1) - obj.ScaledOffScreenMargin ...
                        || p.x > dx(2) + obj.ScaledOffScreenMargin ...
                        || p.y < dy(1) - obj.ScaledOffScreenMargin ...
                        || p.y > dy(2) + obj.ScaledOffScreenMargin
                    obj.deleteParticleGraphics(p);
                    obj.Particles(pidx) = [];
                    obj.resetCombo();
                    continue;
                end

                % Update core + glow positions
                if ~isempty(p.coreH) && isvalid(p.coreH)
                    p.coreH.XData = p.x;
                    p.coreH.YData = p.y;
                end
                if ~isempty(p.glowH) && isvalid(p.glowH)
                    p.glowH.XData = p.x;
                    p.glowH.YData = p.y;
                end

                % Trail rendering (oldest to newest)
                trailOrder = mod(p.trailIdx:p.trailIdx + tLen - 1, tLen) + 1;
                tx = p.trailX(trailOrder);
                ty = p.trailY(trailOrder);
                validMask = ~isnan(tx);
                if sum(validMask) > 1
                    if ~isempty(p.trailGlowH) && isvalid(p.trailGlowH)
                        p.trailGlowH.XData = tx(validMask);
                        p.trailGlowH.YData = ty(validMask);
                    end
                    if ~isempty(p.trailH) && isvalid(p.trailH)
                        p.trailH.XData = tx(validMask);
                        p.trailH.YData = ty(validMask);
                    end
                end

                pidx = pidx + 1;
            end

            % Scoring: reward keeping particles in orbit near finger
            if ~any(isnan(pos))
                areaW = dx(2) - dx(1);
                areaH = dy(2) - dy(1);
                orbitR = min(areaW, areaH) * obj.OrbitFraction;
                nearCount = 0;
                for qi = 1:numel(obj.Particles)
                    pp = obj.Particles(qi);
                    pDist = sqrt((pp.x - pos(1))^2 + (pp.y - pos(2))^2);
                    if pDist < orbitR
                        nearCount = nearCount + 1;
                    end
                end
                if nearCount >= 2
                    obj.incrementCombo();
                    comboMult = obj.comboMultiplier();
                    obj.addScore(round(nearCount * comboMult));
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all gravity graphics.
            handles = {obj.FingerGlowH, obj.FingerGlowH2, obj.ModeTextH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.FingerGlowH = [];
            obj.FingerGlowH2 = [];
            obj.ModeTextH = [];

            for k = 1:numel(obj.Particles)
                obj.deleteParticleGraphics(obj.Particles(k));
            end
            obj.Particles = struct("x", {}, "y", {}, "vx", {}, "vy", {}, ...
                "particleMass", {}, "colorIdx", {}, "coreH", {}, "glowH", {}, ...
                "trailX", {}, "trailY", {}, "trailIdx", {}, ...
                "trailGlowH", {}, "trailH", {});
            obj.FrameCount = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_gravitywell");
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle gravity well key events.
            handled = false;
            if key == "m"
                modes = ["attract", "repel"];
                idx = find(modes == obj.SubMode, 1);
                obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                obj.updateModeLabel();
                handled = true;
            end
        end

        function r = getResults(obj)
            %getResults  Return gravity well results.
            elapsed = 0;
            if ~isempty(obj.StartTic)
                elapsed = toc(obj.StartTic);
            end
            r.Title = "GRAVITY WELL";
            r.Lines = {
                sprintf("Score: %d  |  Max Combo: %d  |  Time: %.0fs", ...
                    obj.Score, obj.MaxCombo, elapsed)
            };
        end

    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function spawnParticle(obj)
            %spawnParticle  Spawn a particle at a random edge with tangential velocity.
            axHandle = obj.Ax;
            if isempty(axHandle) || ~isvalid(axHandle); return; end

            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            areaW = dx(2) - dx(1);
            areaH = dy(2) - dy(1);

            side = randi(4);
            switch side
                case 1; x = dx(1); y = dy(1) + rand * areaH;
                case 2; x = dx(2); y = dy(1) + rand * areaH;
                case 3; x = dx(1) + rand * areaW; y = dy(1);
                case 4; x = dx(1) + rand * areaW; y = dy(2);
            end

            % Aim toward center with tangential component for orbital injection
            toCenterAngle = atan2(mean(dy) - y, mean(dx) - x);
            tangentOffset = (rand - 0.5) * pi * 0.6;   % +/-54 deg offset
            launchAngle = toCenterAngle + tangentOffset;
            launchSpeed = (0.5 + rand * 0.8) * obj.DisplayScale;
            vx = launchSpeed * cos(launchAngle);
            vy = launchSpeed * sin(launchAngle);
            pMass = 0.5 + rand * 1.5;

            % One particle per color — find which color is missing
            usedColors = zeros(1, size(obj.ParticleColors, 1));
            for ci = 1:numel(obj.Particles)
                usedColors(obj.Particles(ci).colorIdx) = 1;
            end
            available = find(~usedColors);
            if isempty(available); return; end
            cidx = available(randi(numel(available)));
            col = obj.ParticleColors(cidx, :);
            tLen = obj.TrailLength;
            trailX = NaN(1, tLen);
            trailY = NaN(1, tLen);
            trailX(1) = x;
            trailY(1) = y;

            % Firefly-style rendering: glow aura + core + trail lines
            coreSize = round(pMass * 80);
            glowH = scatter(axHandle, x, y, coreSize * 3.5, col, "filled", ...
                "MarkerFaceAlpha", 0.35, "Tag", "GT_gravitywell");
            trailGlowH = line(axHandle, x, y, "Color", [col, 0.12], ...
                "LineWidth", 4, "Tag", "GT_gravitywell");
            trailH = line(axHandle, x, y, "Color", [col, 0.5], ...
                "LineWidth", 1.5, "Tag", "GT_gravitywell");
            coreH = scatter(axHandle, x, y, coreSize, col, "filled", ...
                "MarkerFaceAlpha", 1.0, "Tag", "GT_gravitywell");

            obj.Particles(end + 1) = struct( ...
                "x", x, "y", y, "vx", vx, "vy", vy, ...
                "particleMass", pMass, "colorIdx", cidx, ...
                "coreH", coreH, "glowH", glowH, ...
                "trailX", trailX, "trailY", trailY, "trailIdx", 1, ...
                "trailGlowH", trailGlowH, "trailH", trailH);
        end

        function updateModeLabel(obj)
            %updateModeLabel  Update gravity sub-mode text label.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = upper(obj.SubMode) + " [M]";
            end
        end
    end

    % =================================================================
    % STATIC UTILITIES
    % =================================================================
    methods (Static, Access = private)
        function deleteParticleGraphics(p)
            %deleteParticleGraphics  Delete all graphics handles on a particle struct.
            if ~isempty(p.coreH) && isvalid(p.coreH); delete(p.coreH); end
            if ~isempty(p.glowH) && isvalid(p.glowH); delete(p.glowH); end
            if ~isempty(p.trailGlowH) && isvalid(p.trailGlowH); delete(p.trailGlowH); end
            if ~isempty(p.trailH) && isvalid(p.trailH); delete(p.trailH); end
        end
    end
end
