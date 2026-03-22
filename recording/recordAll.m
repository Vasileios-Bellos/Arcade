%recordAll  Record gameplay GIFs and MP4s for all 15 arcade games + menu.
%   Run from the Arcade project root. Output: assets/*.gif and assets/*.mp4

close all force;
addpath(fileparts(mfilename("fullpath")));

outputDir = fullfile(fileparts(fileparts(mfilename("fullpath"))), "assets");
if ~isfolder(outputDir); mkdir(outputDir); end

% Game list: {name, duration, trimStart}
% Duration = total recording time, TrimStart = skip countdown/announce
gameList = {
    "Pong",             12,  2
    "Breakout",         14,  3
    "Snake",            12,  0
    "Tetris",           14,  0
    "Asteroids",        12,  2
    "SpaceInvaders",    12,  2
    "FlappyBird",       10,  0
    "FruitNinja",       10,  0
    "TargetPractice",   10,  0
    "FireflyChase",     10,  1
    "FlickIt",          12,  0
    "Juggler",          12,  0
    "OrbitalDefense",   12,  1
    "ShieldGuardian",   12,  1
    "RailShooter",      12,  2
};

nGames = size(gameList, 1);
results = cell(nGames, 1);

for i = 1:nGames
    gameName = gameList{i, 1};
    dur = gameList{i, 2};
    trim = gameList{i, 3};
    outPath = fullfile(outputDir, lower(gameName));

    fprintf("\n=== [%d/%d] %s (%.0fs, trim %.0fs) ===\n", i, nGames, gameName, dur, trim);
    try
        recordGame(gameName, dur, outPath, TrimStart=trim);
        results{i} = sprintf("[OK]  %s", gameName);
    catch me
        fprintf(2, "  FAILED: %s\n", me.message);
        results{i} = sprintf("[FAIL] %s: %s", gameName, me.message);
    end
    close all force;
    pause(0.5);
end

fprintf("\n=== ALL GAMES COMPLETE ===\n");
for i = 1:nGames
    fprintf("  %s\n", results{i});
end

% --- Record menu ---
fprintf("\n=== Recording Menu ===\n");
try
    recordMenu(outputDir);
catch me
    fprintf(2, "Menu recording FAILED: %s\n", me.message);
end

fprintf("\nOutput directory: %s\n", outputDir);
