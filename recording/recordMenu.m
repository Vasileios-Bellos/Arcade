function recordMenu(outputDir)
%recordMenu  Record the arcade menu - still shot and scrolling animation.

if nargin < 1; outputDir = "assets"; end
if ~isfolder(outputDir); mkdir(outputDir); end

fprintf("Recording menu (still + scroll)...\n");

% --- Create Arcade instance but intercept before timer starts ---
% We'll manually drive the menu by creating the components directly.
fig = figure("Color", [0.015 0.015 0.03], "MenuBar", "none", "ToolBar", "none", ...
    "NumberTitle", "off", "Name", "Arcade", "Resize", "off");
fig.Position = [100, 100, 854, 480];
drawnow;

range = struct("X", [0 854], "Y", [0 480]);
ax = axes(fig, "Units", "normalized", "Position", [0 0 1 1], ...
    "Color", [0.015 0.015 0.03], "XLim", range.X, "YLim", range.Y, ...
    "YDir", "reverse", "Visible", "off", "XTick", [], "YTick", []);
hold(ax, "on");

% Build registry (same as Arcade.buildRegistry)
registry = dictionary;
registryOrder = strings(0);
games = {
    "1",  @games.Pong,            "Pong"
    "2",  @games.Breakout,        "Breakout"
    "3",  @games.Snake,           "Snake"
    "4",  @games.Tetris,          "Tetris"
    "5",  @games.Asteroids,       "Asteroids"
    "6",  @games.SpaceInvaders,   "Space Invaders"
    "7",  @games.FlappyBird,      "Flappy Bird"
    "8",  @games.FruitNinja,      "Fruit Ninja"
    "9",  @games.TargetPractice,  "Target Practice"
    "10", @games.FireflyChase,    "Firefly Chase"
    "11", @games.FlickIt,         "Flick It!"
    "12", @games.Juggler,         "Juggler"
    "13", @games.OrbitalDefense,  "Orbital Defense"
    "14", @games.ShieldGuardian,  "Shield Guardian"
    "15", @games.RailShooter,     "Rail Shooter"
};
for i = 1:size(games, 1)
    entry.ctor = games{i, 2};
    entry.name = games{i, 3};
    entry.key = games{i, 1};
    registry(games{i, 1}) = entry;
    registryOrder(end + 1) = games{i, 1};
end

% Create menu
menu = ui.GameMenu(ax, range, registry, registryOrder, ...
    "SelectionMode", "click", ...
    "SelectionFcn", @(~) [], ...
    "TagPrefix", "GT_arc", ...
    "Title", "A  R  C  A  D  E", ...
    "Subtitle", "S E L E C T   G A M E");
menu.show();

% --- Still shot (let menu settle with a few updates) ---
for i = 1:30
    menu.update([NaN NaN]);
    drawnow;
end
stillFrame = getframe(fig);

% Save still as PNG
imwrite(stillFrame.cdata, fullfile(outputDir, "menu_still.png"));
fprintf("  Saved menu_still.png\n");

% --- Scrolling animation ---
recFps = 30;
gifFps = 12;
duration = 6; % seconds
nFrames = round(duration * recFps);
frames = cell(1, nFrames);

for i = 1:nFrames
    % Gradually scroll down then back up
    t = i / nFrames;
    if t < 0.45
        % Scroll down
        scrollProgress = t / 0.45;
        delta = 1;
    elseif t < 0.55
        % Pause at bottom
        delta = 0;
    else
        % Scroll back up
        scrollProgress = (t - 0.55) / 0.45;
        delta = -1;
    end

    % Apply scroll every few frames
    if delta ~= 0 && mod(i, 8) == 0
        menu.scrollByDelta(delta);
    end

    % Hover cursor over items for highlight effect
    itemY = range.Y(1) + 120 + sin(i * 0.1) * 80;
    menu.update([mean(range.X), itemY]);
    drawnow;
    frames{i} = getframe(fig);
end

% Save scroll GIF
gifFile = fullfile(outputDir, "menu_scroll.gif");
gifDelay = 1 / gifFps;
skipRate = max(1, round(recFps / gifFps));
gifIdx = 1:skipRate:nFrames;
for gi = 1:numel(gifIdx)
    img = imresize(frames{gifIdx(gi)}.cdata, 0.75);
    [imind, cm] = rgb2ind(img, 256, "nodither");
    if gi == 1
        imwrite(imind, cm, gifFile, "gif", "LoopCount", inf, "DelayTime", gifDelay);
    else
        imwrite(imind, cm, gifFile, "gif", "WriteMode", "append", "DelayTime", gifDelay);
    end
end

% Save scroll MP4
mp4File = fullfile(outputDir, "menu_scroll.mp4");
vw = VideoWriter(mp4File, "MPEG-4");
vw.FrameRate = recFps;
vw.Quality = 95;
open(vw);
for i = 1:nFrames
    writeVideo(vw, frames{i}.cdata);
end
close(vw);

fprintf("  Saved menu_scroll.gif and menu_scroll.mp4\n");

% Cleanup
menu.cleanup();
close(fig);
end
