function createHeroGif(outputDir)
%createHeroGif  Create a collage GIF from the best game recordings.
%   Picks 4-6 games and tiles their frames into a single hero image.

if nargin < 1; outputDir = "assets"; end

fprintf("Creating hero GIF...\n");

% Pick 6 showcase games (good visual variety)
showcaseGames = ["pong", "breakout", "asteroids", "spaceinvaders", "flappybird", "tetris"];

% Load MP4 frames for each game
gameFrames = cell(1, numel(showcaseGames));
minFrames = inf;

for i = 1:numel(showcaseGames)
    mp4File = fullfile(outputDir, showcaseGames(i) + ".mp4");
    if ~isfile(mp4File)
        fprintf("  Skipping %s (no MP4 found)\n", showcaseGames(i));
        continue;
    end
    v = VideoReader(mp4File);
    frames = {};
    while hasFrame(v)
        frames{end+1} = readFrame(v); %#ok<AGROW>
    end
    gameFrames{i} = frames;
    minFrames = min(minFrames, numel(frames));
end

if minFrames == inf || minFrames < 10
    fprintf("  Not enough recordings. Run recordAll first.\n");
    return;
end

% Limit to ~4 seconds at 12fps = 48 frames from source
heroFps = 12;
sourceSkip = max(1, round(30 / heroFps)); % assuming 30fps source
heroFrameCount = min(48, floor(minFrames / sourceSkip));

% Create 3x2 tiled frames (3 columns, 2 rows)
tileW = 320;
tileH = 180;
heroW = tileW * 3;
heroH = tileH * 2;

gifFile = fullfile(outputDir, "hero.gif");
gifDelay = 1 / heroFps;

for fi = 1:heroFrameCount
    srcIdx = (fi - 1) * sourceSkip + 1;
    heroImg = zeros(heroH, heroW, 3, "uint8");

    for gi = 1:min(6, numel(gameFrames))
        if isempty(gameFrames{gi}); continue; end
        idx = min(srcIdx, numel(gameFrames{gi}));
        tile = imresize(gameFrames{gi}{idx}, [tileH, tileW]);

        row = ceil(gi / 3);
        col = mod(gi - 1, 3) + 1;
        y1 = (row - 1) * tileH + 1;
        x1 = (col - 1) * tileW + 1;
        heroImg(y1:y1+tileH-1, x1:x1+tileW-1, :) = tile;
    end

    [imind, cm] = rgb2ind(heroImg, 256, "nodither");
    if fi == 1
        imwrite(imind, cm, gifFile, "gif", "LoopCount", inf, "DelayTime", gifDelay);
    else
        imwrite(imind, cm, gifFile, "gif", "WriteMode", "append", "DelayTime", gifDelay);
    end
end

fprintf("  Saved hero.gif (%dx%d, %d frames)\n", heroW, heroH, heroFrameCount);
end
