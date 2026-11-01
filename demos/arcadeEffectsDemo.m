function arcadeEffectsDemo(lifetimeSeconds, repetitions, options)
%arcadeEffectsDemo  Inspect a short-lived expanding ring and eight rays.
%   arcadeEffectsDemo creates a burst at the mouse position on each click
%   inside the playfield. Bursts can overlap and run independently. Resize
%   the window to scale the scene, and close it to stop. The default
%   lifetime is 0.9 seconds, making the expansion and fade easier to see.
%   The default number of repetitions is Inf, and the demo runs until the
%   figure is closed. A finite repetition count limits the number of bursts;
%   the figure closes automatically after the last burst completes.
%
%   arcadeEffectsDemo(lifetimeSeconds, repetitions) sets the lifetime of each
%   burst and the number of repetitions.
%       arcadeEffectsDemo(0.3)     % Match Arcade's nominal impact duration
%       arcadeEffectsDemo(0.9, 4)  % Limit the demo to four bursts
%
%   arcadeEffectsDemo(..., Mode="automatic") replaces mouse-triggered
%   bursts with automatic playback at the center, with a short pause
%   between bursts.
%       arcadeEffectsDemo(Mode="automatic")
%       arcadeEffectsDemo(0.9, 4, Mode="automatic")
%
%   The equations adapt Arcade's shared radial hit effect, used by
%   Flick It!, Firefly Chase, Fruit Ninja, Juggler, and Target Practice.
%
%   Opacity reaches zero before the nominal lifetime ends. Each burst keeps
%   its graphics until expiration, then deletes them. Elapsed time is capped
%   at 0.1 seconds per update.
%
%   See also line, drawnow, onCleanup.

arguments
    lifetimeSeconds (1,1) double {mustBeReal, mustBeFinite, mustBePositive} = 0.9
    repetitions (1,1) double {mustBeReal, mustBePositive, mustBeIntegerOrInf} = Inf
    options.Mode (1,1) string {mustBeMember(options.Mode, ["manual", "automatic"])} = "manual"
end

referenceWindowSize = [720, 480];
fig = figure(Name="Arcade: Effects Demo", NumberTitle="off", WindowStyle="normal", ...
    Units="pixels", Color="black", MenuBar="none", ToolBar="none", Visible="off", ...
    Tag="ArcadeArticle.ImpactDemo");
% Keep the cleanup guard outside the workspace retained by nested callbacks
figureCleanup = onCleanup(@() deleteOwnedFigure(fig));
fig.Position(3:4) = referenceWindowSize;
movegui(fig, "center")
animateImpact(fig, referenceWindowSize, lifetimeSeconds, repetitions, options.Mode)
end

function animateImpact(fig, referenceWindowSize, lifetimeSeconds, repetitions, mode)
worldSize = [240, 160];
center = [120, 85];
radiusParameter = 20;
cyan = [0, 0.92, 1];
backgroundColor = [0.015, 0.015, 0.03];

% Precompute the fixed ring and ray directions
ringAngles = linspace(0, 2*pi, 48);
ringCos = cos(ringAngles);
ringSin = sin(ringAngles);
rayAngles = linspace(0, 2*pi, 9);
rayAngles = rayAngles(1:end-1);
rayCos = cos(rayAngles);
raySin = sin(rayAngles);
ring = [];
rays = [];
progress = 0;
displayScale = 1;
keepRunning = true;
burstIndex = 0;
activeEffects = struct('Ring', {}, 'Rays', {}, 'Center', {}, ...
    'AgeSeconds', {}, 'LastTime', {});
animationClock = tic;

fig.CloseRequestFcn = @requestClose;
ax = axes(Parent=fig, Units="pixels", ...
    Position=[1, 1, referenceWindowSize], PositionConstraint="innerposition", ...
    XLim=[0, worldSize(1)], YLim=[0, worldSize(2)], YDir="reverse", ...
    DataAspectRatio=[1, 1, 1], Visible="off", NextPlot="add", ...
    Tag="ArcadeArticle.ImpactAxes");
disableDefaultInteractivity(ax)
ax.Toolbar.Visible = "off";
playfield = patch(ax, XData=[0, worldSize(1), worldSize(1), 0], ...
    YData=[0, 0, worldSize(2), worldSize(2)], ...
    FaceColor=backgroundColor, EdgeColor=[0.07, 0.09, 0.12], LineWidth=0.5, ...
    HitTest="off", PickableParts="none", ...
    Tag="ArcadeArticle.ImpactBackground");
instruction = text(ax, worldSize(1)/2, 12, "", ...
    Color=[0.75, 0.8, 0.85], Units="data", ...
    FontName="Arial", FontUnits="points", FontSize=12, ...
    HorizontalAlignment="center", Interpreter="none", ...
    HitTest="off", PickableParts="none", ...
    Tag="ArcadeArticle.ImpactInstruction");

fig.SizeChangedFcn = @fitScene;
if mode == "manual"
    instruction.String = "Click to create an impact. Resize the window to scale.";
    fig.WindowButtonDownFcn = @createManualImpact;
end
fig.Visible = "on";
fitScene([], [])
drawnow

if mode == "manual"
    runManualEffects()
    return
end

while keepRunning && isgraphics(fig) && burstIndex < repetitions
    burstIndex = burstIndex + 1;
    if isinf(repetitions)
        instruction.String = sprintf("Impact %d. Resize the window; close the figure to stop.", burstIndex);
    else
        instruction.String = sprintf("Impact %d of %d. Resize the window; close the figure to stop.", ...
            burstIndex, repetitions);
    end
    progress = 0;

    [ring, rays] = createEffect(center);
    drawnow

    burstClock = tic;
    previousTime = 0;
    ageSeconds = 0;
    while keepRunning && isgraphics(fig) && ageSeconds < lifetimeSeconds
        currentTime = toc(burstClock);
        dtSeconds = min(currentTime - previousTime, 0.1);
        previousTime = currentTime;
        ageSeconds = min(lifetimeSeconds, ageSeconds + dtSeconds);
        progress = ageSeconds / lifetimeSeconds;
        updateEffect(ring, rays, center, progress)
        drawnow
        if keepRunning && isgraphics(fig)
            pause(0.01)
        end
    end

    if ~keepRunning || ~isgraphics(fig)
        return
    end
    delete(ring)
    delete(rays)
    ring = [];
    rays = [];
    drawnow
    if burstIndex < repetitions && keepRunning && isgraphics(fig)
        pause(0.35)
    end
end

    function [newRing, newRays] = createEffect(position)
        newRing = line(ax, position(1) + radiusParameter*ringCos, ...
            position(2) + radiusParameter*ringSin, ...
            Color=[cyan, 0.9], LineWidth=3, ...
            HitTest="off", PickableParts="none", ...
            Tag="ArcadeArticle.ImpactRing");

        newRays = gobjects(1, numel(rayAngles));
        for rayIndex = 1:numel(rayAngles)
            innerRadius = radiusParameter * 0.5;
            newRays(rayIndex) = line(ax, ...
                position(1) + [innerRadius, radiusParameter]*rayCos(rayIndex), ...
                position(2) + [innerRadius, radiusParameter]*raySin(rayIndex), ...
                Color=[cyan, 0.8], LineWidth=2, ...
                HitTest="off", PickableParts="none", ...
                Tag="ArcadeArticle.ImpactRays");
        end
    end

    function createManualImpact(~, ~)
        if ~keepRunning || ~isgraphics(ax) || burstIndex >= repetitions
            return
        end
        point = ax.CurrentPoint;
        position = point(1, 1:2);
        if any(~isfinite(position)) || any(position < 0 | position > worldSize)
            return
        end
        [newRing, newRays] = createEffect(position);
        activeEffects(end+1) = struct('Ring', newRing, 'Rays', newRays, ...
            'Center', position, 'AgeSeconds', 0, 'LastTime', toc(animationClock));
        burstIndex = burstIndex + 1;
        if isinf(repetitions)
            instruction.String = sprintf("Impact %d. Click to create an impact; close the figure to stop.", burstIndex);
        else
            instruction.String = sprintf("Impact %d of %d. Click inside the playfield.", ...
                burstIndex, repetitions);
        end
    end

    function runManualEffects()
        while keepRunning && isgraphics(fig) && ...
                (burstIndex < repetitions || ~isempty(activeEffects))
            currentTime = toc(animationClock);
            for effectIndex = numel(activeEffects):-1:1
                effect = activeEffects(effectIndex);
                dtSeconds = min(currentTime-effect.LastTime, 0.1);
                effect.AgeSeconds = min(lifetimeSeconds, effect.AgeSeconds+dtSeconds);
                effect.LastTime = currentTime;
                if effect.AgeSeconds >= lifetimeSeconds
                    delete(effect.Ring)
                    delete(effect.Rays)
                    activeEffects(effectIndex) = [];
                else
                    activeEffects(effectIndex) = effect;
                    updateEffect(effect.Ring, effect.Rays, effect.Center, ...
                        effect.AgeSeconds/lifetimeSeconds)
                end
            end
            drawnow
            if keepRunning && isgraphics(fig)
                pause(0.01)
            end
        end
    end

    function updateEffect(effectRing, effectRays, position, effectProgress)
        if isempty(effectRing) || isempty(effectRays) || ...
                ~isgraphics(effectRing) || ~all(isgraphics(effectRays))
            return
        end
        eased = 1 - (1-effectProgress)^2;
        opacity = max(0, 1-1.5*eased);
        ringRadius = radiusParameter * (1+2.5*eased);
        innerRadius = radiusParameter * (0.5+1.5*eased);
        outerRadius = radiusParameter * (1+3*eased);

        effectRing.XData = position(1) + ringRadius*ringCos;
        effectRing.YData = position(2) + ringRadius*ringSin;
        effectRing.Color = [cyan, 0.8 * opacity];
        effectRing.LineWidth = max(0.5, 3*(1-eased));

        for rayIndex = 1:numel(effectRays)
            effectRays(rayIndex).XData = position(1) + [innerRadius, outerRadius]*rayCos(rayIndex);
            effectRays(rayIndex).YData = position(2) + [innerRadius, outerRadius]*raySin(rayIndex);
            effectRays(rayIndex).Color = [cyan, 0.6 * opacity];
            effectRays(rayIndex).LineWidth = max(0.5, 2*(1-eased));
        end
    end

    function fitScene(~, ~)
        if ~isgraphics(ax)
            return
        end
        availableSize = max(fig.Position(3:4), [1, 1]);
        displayScale = min(availableSize ./ referenceWindowSize);
        fittedSize = referenceWindowSize * displayScale;
        ax.Position = [(availableSize-fittedSize)/2 + 1, fittedSize];
        instruction.FontSize = 12 * displayScale;
        playfield.LineWidth = 0.5 * displayScale;
        updateEffect(ring, rays, center, progress)
        for effectIndex = 1:numel(activeEffects)
            effect = activeEffects(effectIndex);
            updateEffect(effect.Ring, effect.Rays, effect.Center, ...
                effect.AgeSeconds/lifetimeSeconds)
        end
    end

    function requestClose(~, ~)
        % Let the current property update finish before deleting its objects
        keepRunning = false;
        if isgraphics(fig)
            fig.Visible = "off";
        end
    end
end

function mustBeIntegerOrInf(value)
if value ~= Inf
    mustBeInteger(value)
end
end

function deleteOwnedFigure(fig)
% Remove only this example's figure, if it still exists
if isgraphics(fig)
    delete(fig)
end
end
