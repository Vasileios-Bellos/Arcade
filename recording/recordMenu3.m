function recordMenu3(outputDir)
%recordMenu3  Record menu with faster arrow-key navigation through all 15 games.

if nargin < 1; outputDir = "assets"; end
if ~isfolder(outputDir); mkdir(outputDir); end

fprintf("Recording menu (arrow key navigation)...\n");

fig = figure("Color", [0.015 0.015 0.03], "MenuBar", "none", "ToolBar", "none", ...
    "NumberTitle", "off", "Name", "MATLAB Arcade", "Resize", "off");
fig.Position = [100, 100, 854, 480];
drawnow;

range = struct("X", [0 854], "Y", [0 480]);
ax = axes(fig, "Units", "normalized", "Position", [0 0 1 1], ...
    "Color", [0.015 0.015 0.03], "XLim", range.X, "YLim", range.Y, ...
    "YDir", "reverse", "Visible", "off", "XTick", [], "YTick", []);
hold(ax, "on");

% Build registry
registry = dictionary;
registryOrder = strings(0);
gameEntries = {
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
for i = 1:size(gameEntries, 1)
    entry.ctor = gameEntries{i, 2};
    entry.name = gameEntries{i, 3};
    entry.key = gameEntries{i, 1};
    registry(gameEntries{i, 1}) = entry;
    registryOrder(end + 1) = gameEntries{i, 1};
end

menu = ui.GameMenu(ax, range, registry, registryOrder, ...
    "SelectionMode", "click", ...
    "SelectionFcn", @(~) [], ...
    "TagPrefix", "GT_arc", ...
    "Title", "A  R  C  A  D  E", ...
    "Subtitle", "S E L E C T   G A M E");
menu.show();

% Let menu settle
for i = 1:30
    menu.update([NaN NaN]);
    drawnow;
end

% --- Recording parameters ---
recFps = 30;
framesPerGame = 15;      % ~0.5s per game highlight
settleFrames = 15;       % initial pause on game 1
nGames = 15;
totalFrames = settleFrames + nGames * framesPerGame + 30; % + 30 end pause
frames = cell(1, totalFrames);
frameIdx = 0;

% --- Initial settle on game 1 (already selected) ---
for i = 1:settleFrames
    menu.update([NaN NaN]);
    drawnow;
    frameIdx = frameIdx + 1;
    frames{frameIdx} = getframe(fig);
end

% --- Arrow down through each game ---
for g = 2:nGames
    % Press down arrow
    menu.moveSelection(1);

    % Record frames at this position
    for f = 1:framesPerGame
        menu.update([NaN NaN]);
        drawnow;
        frameIdx = frameIdx + 1;
        frames{frameIdx} = getframe(fig);
    end
end

% --- End pause on game 15 ---
for i = 1:30
    menu.update([NaN NaN]);
    drawnow;
    frameIdx = frameIdx + 1;
    frames{frameIdx} = getframe(fig);
end

frames = frames(1:frameIdx);

% --- Save GIF ---
gifFile = fullfile(outputDir, "menu_scroll_3.gif");
gifFps = 15;
gifDelay = 1 / gifFps;
skip = max(1, round(recFps / gifFps));

% Global colormap from sampled frames
sampleIdx = round(linspace(1, frameIdx, min(20, frameIdx)));
samplePixels = [];
for si = 1:numel(sampleIdx)
    img = frames{sampleIdx(si)}.cdata;
    samplePixels = [samplePixels; reshape(img, [], 3)]; %#ok<AGROW>
end
% Build colormap from sample pixels using rgb2ind on a composite image
sampleImg = reshape(samplePixels, [], 1, 3);
[~, globalMap] = rgb2ind(uint8(sampleImg), 256, "nodither");

for gi = 1:skip:frameIdx
    img = frames{gi}.cdata;
    imind = rgb2ind(img, globalMap, "dither");
    if gi == 1
        imwrite(imind, globalMap, gifFile, "gif", "LoopCount", inf, "DelayTime", gifDelay);
    else
        imwrite(imind, globalMap, gifFile, "gif", "WriteMode", "append", "DelayTime", gifDelay);
    end
end

% --- Save MP4 ---
mp4File = fullfile(outputDir, "menu_scroll_3.mp4");
vw = VideoWriter(mp4File, "MPEG-4");
vw.FrameRate = recFps;
vw.Quality = 95;
open(vw);
for i = 1:frameIdx
    writeVideo(vw, frames{i}.cdata);
end
close(vw);

fprintf("  Saved menu_scroll_3.gif and menu_scroll_3.mp4 (%d frames)\n", frameIdx);

menu.cleanup();
close(fig);
end
