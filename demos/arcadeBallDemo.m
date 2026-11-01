function arcadeBallDemo(durationSeconds, pauseSeconds)
%arcadeBallDemo  Animate a retained, layered ball in a resizable window.
%   arcadeBallDemo runs until its figure is closed. Each mouse press reverses
%   the vertical velocity. Resize the window to scale the scene while
%   preserving the playfield's aspect ratio.
%
%   arcadeBallDemo(durationSeconds, pauseSeconds) optionally limits the
%   duration and changes the requested pause between updates. The defaults
%   are Inf seconds and a 0.02-second pause. For example:
%       arcadeBallDemo(12)         % Stop after 12 seconds or on close
%       arcadeBallDemo(Inf, 0.04)  % Run until closed, with a longer pause
%
%   The pause is a pacing request, not a guaranteed frame rate. Motion uses
%   measured elapsed time, capped at 0.1 seconds per update. For longer
%   delays, the elapsed time beyond that cap is discarded.
%
%   This standalone teaching example adapts Arcade's Pong ball layers and
%   scaling concepts. Like Pong's top/bottom collision, the ball center
%   reaches the playfield edge at contact. This example applies that
%   contact rule to all four edges with constant speed.
%
%   See also line, scatter, drawnow, onCleanup.

arguments
    durationSeconds (1,1) double {mustBeReal, mustBePositive} = Inf
    pauseSeconds (1,1) double {mustBeReal, mustBeFinite, mustBeNonnegative} = 0.02
end

worldSize = [854, 480];
fig = figure(Name="Arcade: Ball Demo", NumberTitle="off", WindowStyle="normal", ...
    Units="pixels", Color="black", MenuBar="none", ToolBar="none", Visible="off", ...
    Tag="ArcadeArticle.BallDemo");
% Keep the cleanup guard outside the workspace retained by nested callbacks
figureCleanup = onCleanup(@() deleteOwnedFigure(fig));
fig.Position(3:4) = worldSize;
movegui(fig, "center")
animateBall(fig, worldSize, durationSeconds, pauseSeconds)
end

function animateBall(fig, worldSize, durationSeconds, pauseSeconds)
% State is expressed in game coordinates, independently of window size
position = worldSize / 2;
velocity = [5, 3];       % Game units per reference interval
referenceFPS = 60;       % Reference intervals per second (not a render target)
keepRunning = true;

cyan = [0, 0.92, 1];
backgroundColor = [0.015, 0.015, 0.03];
radiusParameter = max(3, round(min(worldSize) * 0.035));
baseCoreSize = 2 * radiusParameter;
baseDotSize = 5 * radiusParameter;
baseGlowArea = pi * (1.25 * radiusParameter)^2;
baseFontSize = 12;

fig.CloseRequestFcn = @requestClose;

ax = axes(Parent=fig, Units="pixels", Position=[1, 1, worldSize], ...
    PositionConstraint="innerposition", XLim=[0, worldSize(1)], ...
    YLim=[0, worldSize(2)], YDir="reverse", ...
    DataAspectRatio=[1, 1, 1], Visible="off", NextPlot="add", ...
    Tag="ArcadeArticle.BallAxes");
disableDefaultInteractivity(ax)
ax.Toolbar.Visible = "off";

playfield = patch(ax, XData=[0, worldSize(1), worldSize(1), 0], ...
    YData=[0, 0, worldSize(2), worldSize(2)], ...
    FaceColor=backgroundColor, EdgeColor=[0.07, 0.09, 0.12], ...
    LineWidth=0.5, HitTest="off", PickableParts="none", ...
    Tag="ArcadeArticle.Playfield");

% Draw back to front: colored dot, translucent scatter, white center
coloredDot = line(ax, NaN, NaN, ...
    Marker=".", MarkerSize=baseDotSize, LineStyle="none", Color=[cyan, 0.15], ...
    HitTest="off", PickableParts="none", Tag="ArcadeArticle.ColoredDot");
glow = scatter(ax, position(1), position(2), baseGlowArea, cyan, "filled", ...
    MarkerFaceAlpha=0.4, ...
    HitTest="off", PickableParts="none", Tag="ArcadeArticle.Glow");
core = line(ax, position(1), position(2), ...
    Marker=".", MarkerSize=baseCoreSize, LineStyle="none", Color=[1, 1, 1, 1], ...
    HitTest="off", PickableParts="none", Tag="ArcadeArticle.Core");
ballLayers = {coloredDot, glow, core};

instruction = text(ax, worldSize(1)/2, 28, ...
    "Click to reverse vertically. Resize the window to scale the scene. Close to stop.", ...
    HorizontalAlignment="center", VerticalAlignment="middle", ...
    Color=[0.75, 0.8, 0.85], Units="data", ...
    FontName="Arial", FontUnits="points", FontSize=baseFontSize, ...
    Interpreter="none", HitTest="off", PickableParts="none", ...
    Tag="ArcadeArticle.Instruction");

% Assign callback functions after the state and graphics they use exist
fig.SizeChangedFcn = @fitScene;
fig.WindowButtonDownFcn = @reverseVerticalDirection;
fig.Visible = "on";
fitScene([], [])
drawnow

animationClock = tic;
previousTime = 0;
while keepRunning && isgraphics(fig)
    currentTime = toc(animationClock);
    if currentTime >= durationSeconds
        break
    end
    dtSeconds = min(currentTime - previousTime, 0.1);
    previousTime = currentTime;
    dtScale = dtSeconds * referenceFPS;

    previousPosition = position;
    step = velocity * dtScale;
    position = previousPosition + step;

    % Pong places the center at the wall contact before the next update.
    % Find the first crossed edge, using the full playfield limits.
    contactFraction = [Inf, Inf];
    contactBoundary = [0, 0];
    for coordinate = 1:2
        if position(coordinate) <= 0 && step(coordinate) < 0
            contactFraction(coordinate) = -previousPosition(coordinate)/step(coordinate);
        elseif position(coordinate) >= worldSize(coordinate) && step(coordinate) > 0
            contactBoundary(coordinate) = worldSize(coordinate);
            contactFraction(coordinate) = ...
                (worldSize(coordinate) - previousPosition(coordinate))/step(coordinate);
        end
    end
    firstContact = min(contactFraction);
    if firstContact <= 1
        position = previousPosition + firstContact*step;
        hitCoordinates = abs(contactFraction - firstContact) <= 8*eps(1);
        position(hitCoordinates) = contactBoundary(hitCoordinates);
        velocity(hitCoordinates) = -velocity(hitCoordinates);
    end

    for layerIndex = 1:numel(ballLayers)
        ballLayers{layerIndex}.XData = position(1);
        ballLayers{layerIndex}.YData = position(2);
    end
    glow.CData = cyan;
    coloredDot.Color = [cyan, 0.12];
    drawnow
    if keepRunning && isgraphics(fig) && pauseSeconds > 0
        pause(pauseSeconds)
    end
end

    function fitScene(~, ~)
        if ~isgraphics(ax)
            return
        end
        availableSize = max(fig.Position(3:4), [1, 1]);
        displayScale = min(availableSize ./ worldSize);
        fittedSize = worldSize * displayScale;
        ax.Position = [(availableSize - fittedSize)/2 + 1, fittedSize];

        % Always derive sizes from their reference values. Scatter uses area.
        core.MarkerSize = baseCoreSize * displayScale;
        coloredDot.MarkerSize = baseDotSize * displayScale;
        glow.SizeData = baseGlowArea * displayScale^2;
        instruction.FontSize = baseFontSize * displayScale;
        playfield.LineWidth = 0.5 * displayScale;
    end

    function reverseVerticalDirection(~, ~)
        % Arcade forwards every mouse-down, including double-click presses
        velocity(2) = -velocity(2);
    end

    function requestClose(~, ~)
        % Let the current property update finish before deleting its objects
        keepRunning = false;
        if isgraphics(fig)
            fig.Visible = "off";
        end
    end
end

function deleteOwnedFigure(fig)
% Remove only this example's figure, if it still exists
if isgraphics(fig)
    delete(fig)
end
end
