function recordGame(gameName, duration, outputPath, options)
%recordGame  Record gameplay of an arcade game as GIF and MP4.

arguments
    gameName    string
    duration    double = 6
    outputPath  string = ""
    options.GifFps   double = 15
    options.GifScale double = 0.75
    options.RecFps   double = 60
    options.FigSize  (1,2) double = [854 480]
    options.TrimStart double = 0
end

if outputPath == ""
    outputPath = fullfile("assets", lower(gameName));
end

fprintf("Recording %s (%.0fs)...\n", gameName, duration);

fig = figure("Color", "k", "MenuBar", "none", "ToolBar", "none", ...
    "NumberTitle", "off", "Name", gameName, "Resize", "off");
fig.Position = [100, 100, options.FigSize(1), options.FigSize(2)];
drawnow;

range = struct("X", [0 854], "Y", [0 480]);
ax = axes(fig, "Units", "normalized", "Position", [0 0 1 1], ...
    "Color", "k", "XLim", range.X, "YLim", range.Y, ...
    "YDir", "reverse", "Visible", "off", "XTick", [], "YTick", []);
hold(ax, "on");

ctor = str2func("games." + gameName);
game = ctor();
game.init(ax, range);
game.beginGame();

totalDur = duration + options.TrimStart;
nFrames = round(totalDur * options.RecFps);
trimFrames = round(options.TrimStart * options.RecFps);
dt = 1 / options.RecFps;
allFrames = cell(1, nFrames);
pos = [mean(range.X), mean(range.Y)];
captureCount = 0;

st = struct("prevBallPos", [NaN NaN], "flickPhase", 0, ...
    "flapCD", 0, "snakeDir", "rightarrow", ...
    "tetrisCol", 5, "tetrisPiece", 0);

for i = 1:nFrames
    [pos, keys, doClick, st] = gameAI(gameName, pos, ax, i, range, st);

    for k = 1:numel(keys)
        try game.onKeyPress(keys(k)); catch; end
    end
    if doClick
        try game.onMouseDown(); catch; end
    end

    game.DtScale = dt * game.RefFPS;
    game.onUpdate(pos);
    game.updateHitEffects();
    drawnow;

    if i > trimFrames
        captureCount = captureCount + 1;
        allFrames{captureCount} = getframe(fig);
    end

    if ~game.IsRunning; break; end
end
allFrames = allFrames(1:captureCount);

try game.onCleanup(); game.cleanupHitEffects(); catch; end
close(fig);

if captureCount == 0; fprintf("  No frames!\n"); return; end

% --- GIF ---
gifFile = outputPath + ".gif";
d = fileparts(gifFile);
if strlength(d) > 0 && ~isfolder(d); mkdir(d); end
gifDelay = 1 / options.GifFps;
skip = max(1, round(options.RecFps / options.GifFps));
idx = 1:skip:captureCount;
for gi = 1:numel(idx)
    img = allFrames{idx(gi)}.cdata;
    if options.GifScale ~= 1; img = imresize(img, options.GifScale); end
    [imind, cm] = rgb2ind(img, 256, "nodither");
    if gi == 1
        imwrite(imind, cm, gifFile, "gif", "LoopCount", inf, "DelayTime", gifDelay);
    else
        imwrite(imind, cm, gifFile, "gif", "WriteMode", "append", "DelayTime", gifDelay);
    end
end

% --- MP4 ---
mp4File = outputPath + ".mp4";
vw = VideoWriter(mp4File, "MPEG-4");
vw.FrameRate = 30;
vw.Quality = 95;
open(vw);
mp4Skip = max(1, round(options.RecFps / 30));
for i = 1:mp4Skip:captureCount
    writeVideo(vw, allFrames{i}.cdata);
end
close(vw);

fprintf("  Done: %d frames, %s, %s\n", captureCount, gifFile, mp4File);
end

% =========================================================================
% AI CONTROLLER — plays each game as well as possible
% =========================================================================
function [pos, keys, doClick, st] = gameAI(name, prev, ax, frame, range, st)
keys = string.empty;
doClick = false;
cx = mean(range.X); cy = mean(range.Y);
w = diff(range.X);  h = diff(range.Y);

switch name

    % === PONG: track ball Y with prediction, play good rallies ===
    case "Pong"
        bp = findScatter(ax, "GT_pong");
        ty = cy;
        if ~isempty(bp)
            ty = bp(2);
            if ~isnan(st.prevBallPos(1))
                vy = bp(2) - st.prevBallPos(2);
                ty = ty + vy * 8; % strong prediction
            end
            st.prevBallPos = bp;
        end
        ty = clamp(ty, range.Y(1)+20, range.Y(2)-20);
        pos = prev + ([range.X(2)*0.82, ty] - prev) * 0.3;

    % === BREAKOUT: track ball X precisely, stay near paddle zone ===
    case "Breakout"
        bp = findScatter(ax, "GT_breakout");
        tx = prev(1);
        if ~isempty(bp)
            tx = bp(1);
            if ~isnan(st.prevBallPos(1))
                vx = bp(1) - st.prevBallPos(1);
                tx = tx + vx * 5;
            end
            st.prevBallPos = bp;
        end
        pos = prev + ([tx, range.Y(2)*0.93] - prev) * 0.4;

    % === SNAKE: lawn-mower pattern with tighter turns ===
    case "Snake"
        if mod(frame, 5) == 0
            period = 35;
            seg = mod(floor(frame / period), 4);
            dirs = ["rightarrow","downarrow","leftarrow","downarrow"];
            keys = dirs(seg+1);
        end
        pos = prev;

    % === TETRIS: keyboard only, fill rows flat ===
    case "Tetris"
        % Use keyboard to position and rotate pieces.
        % Strategy: rotate once to flatten, shift to fill from left.
        % Piece cycle: every ~40 frames a new piece.
        pieceCycle = mod(frame, 40);

        if pieceCycle == 2
            keys = "uparrow"; % rotate to flat orientation
        elseif pieceCycle == 5
            keys = "uparrow"; % rotate again if needed
        elseif pieceCycle >= 8 && pieceCycle <= 20 && mod(pieceCycle, 3) == 0
            % Shift piece left or right to fill gaps
            % Alternate: shift left for even pieces, right for odd
            pieceNum = floor(frame / 40);
            targetCol = mod(pieceNum, 8); % 0-7 across the field
            if targetCol < 4
                keys = "leftarrow";
            else
                keys = "rightarrow";
            end
        elseif pieceCycle == 25
            keys = "space"; % hard drop
        end
        % Keep cursor centered (mouse targeting supplements keyboard)
        pos = [cx - 25, cy];

    % === ASTEROIDS: orbit center, auto-fire handles shooting ===
    case "Asteroids"
        t = frame * 0.025;
        r = min(w,h) * 0.2;
        pos = [cx + r*sin(t), cy + r*cos(t)*0.7];

    % === SPACE INVADERS: track alien X positions, sweep to aim ===
    case "SpaceInvaders"
        % Smooth left-right sweep aligned with alien grid
        t = frame * 0.025;
        pos = [cx + sin(t)*w*0.35, range.Y(2)*0.88];

    % === FLAPPY BIRD: maintain center height through pipe gaps ===
    case "FlappyBird"
        birdPos = findScatter(ax, "GT_flappy");
        st.flapCD = max(0, st.flapCD - 1);
        if ~isempty(birdPos)
            % Maintain bird near center: flap when dropping below 55%
            if birdPos(2) > cy * 1.05 && st.flapCD <= 0
                keys = "space";
                st.flapCD = 12;
            elseif birdPos(2) > cy * 1.2 && st.flapCD <= 0
                % Emergency flap if dropping too fast
                keys = "space";
                st.flapCD = 8;
            end
        else
            if st.flapCD <= 0
                keys = "space";
                st.flapCD = 15;
            end
        end
        pos = [cx, cy];

    % === FRUIT NINJA: wide sweeps through fruit arcs ===
    case "FruitNinja"
        % Fruits arc from bottom to top. Sweep diagonals to intersect.
        % The sweep must ENTER then EXIT a fruit radius to slice.
        fruitPos = findAllPatchCenters(ax, "GT_fruitninja");
        if ~isempty(fruitPos)
            dists = vecnorm(fruitPos - prev, 2, 2);
            [minD, nearest] = min(dists);
            target = fruitPos(nearest, :);
            % Move toward fruit, then continue past (entry + exit = slice)
            speed = 0.25;
            if minD < 25
                speed = 0.5; % accelerate through fruit for clean exit
            end
            pos = prev + (target - prev) * speed;
        else
            % Sweep through center where fruits arc
            t = frame * 0.04;
            pos = [cx + sin(t*1.5)*w*0.35, cy + cos(t)*h*0.3];
        end

    % === TARGET PRACTICE: rush to target position ===
    case "TargetPractice"
        tp = findScatter(ax, "GT_targetpractice");
        if ~isempty(tp)
            % Rush directly to target — high speed approach
            pos = prev + (tp - prev) * 0.5;
        else
            pos = [cx, cy];
        end

    % === FIREFLY CHASE: chase nearest firefly aggressively ===
    case "FireflyChase"
        ff = findAllScatters(ax, "GT_fireflies");
        if ~isempty(ff)
            d = vecnorm(ff - prev, 2, 2);
            [~,i] = min(d);
            % Chase aggressively
            pos = prev + (ff(i,:) - prev) * 0.25;
        else
            t = frame*0.04;
            pos = [cx+sin(t)*w*0.3, cy+cos(t)*h*0.3];
        end

    % === FLICK IT: approach ball, flick in consistent direction ===
    case "FlickIt"
        bp = findScatter(ax, "GT_flick");
        if isempty(bp); bp = [cx, cy]; end
        st.flickPhase = st.flickPhase + 1;
        ph = mod(st.flickPhase, 80);
        if ph < 40
            % Approach from the left side
            pos = prev + ([bp(1) - 50, bp(2)] - prev) * 0.06;
        elseif ph < 55
            % Smooth flick to the right through the ball
            pos = prev + ([bp(1) + 80, bp(2) - 20] - prev) * 0.2;
        else
            % Drift back to center, wait
            pos = prev + ([cx, cy] - prev) * 0.04;
        end

    % === JUGGLER: gently keep cursor under ball, let it bounce ===
    case "Juggler"
        % DON'T flick — just track ball from directly below.
        % Low velocity = passive bounce (Restitution * 0.75).
        % Small X/Y variations for natural look.
        bp = findScatter(ax, "GT_juggle");
        if isempty(bp); bp = [cx, cy*0.5]; end
        % Stay directly under the ball, slightly below
        targetX = bp(1) + sin(frame*0.02) * 8; % gentle X sway
        targetY = bp(2) + 5; % just below ball center
        % Smooth tracking — low speed so velocity stays low (passive bounce)
        pos = prev + ([targetX, targetY] - prev) * 0.12;

    % === ORBITAL DEFENSE: aim at incoming asteroids ===
    case "OrbitalDefense"
        astPos = findAllScatters(ax, "GT_orbitaldefense");
        if ~isempty(astPos)
            % Target furthest asteroid from center (intercept early)
            dists = vecnorm(astPos - [cx,cy], 2, 2);
            [~,idx] = max(dists); % aim at the distant ones
            pos = prev + (astPos(idx,:) - prev) * 0.12;
        else
            t = frame * 0.025;
            r = min(w,h) * 0.35;
            pos = [cx + r*cos(t), cy + r*sin(t)];
        end

    % === SHIELD GUARDIAN: face shield toward nearest projectile ===
    case "ShieldGuardian"
        projPos = findAllScatters(ax, "GT_shieldguardian");
        if ~isempty(projPos)
            % Face shield toward the nearest incoming projectile
            dists = vecnorm(projPos - [cx,cy], 2, 2);
            [~,idx] = min(dists);
            dir = projPos(idx,:) - [cx,cy];
            if norm(dir) > 1; dir = dir / norm(dir); end
            r = min(w,h) * 0.18;
            targetPos = [cx + dir(1)*r, cy + dir(2)*r];
            pos = prev + (targetPos - prev) * 0.2;
        else
            t = frame * 0.02;
            r = min(w,h) * 0.18;
            pos = [cx + r*cos(t), cy + r*sin(t)];
        end

    % === RAIL SHOOTER: target nearest/foremost enemy center ===
    case "RailShooter"
        % Find ALL visible enemy patches, target the one closest to bottom
        % (foremost = most dangerous, largest on screen)
        monsterPositions = findAllPatchCenters(ax, "GT_railshooter");
        if ~isempty(monsterPositions)
            % Target the foremost enemy (highest Y = closest to player)
            [~, idx] = max(monsterPositions(:,2));
            target = monsterPositions(idx,:);
            % Smooth tracking directly to center
            pos = prev + (target - prev) * 0.25;
        else
            % Sweep waiting area
            t = frame * 0.03;
            pos = [cx + sin(t)*w*0.15, cy*0.5];
        end

    otherwise
        t = frame*0.04;
        pos = [cx+sin(t)*w*0.3, cy+cos(t)*h*0.3];
end

pos(1) = clamp(pos(1), range.X(1)+5, range.X(2)-5);
pos(2) = clamp(pos(2), range.Y(1)+5, range.Y(2)-5);
end

function v = clamp(v, lo, hi)
v = max(lo, min(hi, v));
end

function pos = findScatter(ax, tag)
pos = [];
s = findobj(ax, "Type", "scatter", "-regexp", "Tag", "^"+tag, "Visible", "on");
for i = 1:numel(s)
    x = s(i).XData; y = s(i).YData;
    if ~isempty(x) && ~isnan(x(1)) && ~isnan(y(1))
        pos = [x(1), y(1)]; return;
    end
end
end

function p = findAllScatters(ax, tag)
p = zeros(0,2);
s = findobj(ax, "Type", "scatter", "-regexp", "Tag", "^"+tag, "Visible", "on");
for i = 1:numel(s)
    x = s(i).XData; y = s(i).YData;
    if ~isempty(x) && ~isnan(x(1)) && ~isnan(y(1))
        p(end+1,:) = [x(1), y(1)]; %#ok<AGROW>
    end
end
end

function pos = findPatchCenter(ax, tag)
pos = [];
p = findobj(ax, "Type", "patch", "-regexp", "Tag", "^"+tag, "Visible", "on");
for i = 1:numel(p)
    xv = p(i).XData; yv = p(i).YData;
    if ~isempty(xv) && ~all(isnan(xv))
        pos = [mean(xv,"omitnan"), mean(yv,"omitnan")]; return;
    end
end
end

function positions = findAllPatchCenters(ax, tag)
positions = zeros(0,2);
p = findobj(ax, "Type", "patch", "-regexp", "Tag", "^"+tag, "Visible", "on");
for i = 1:numel(p)
    xv = p(i).XData; yv = p(i).YData;
    if ~isempty(xv) && ~all(isnan(xv)) && numel(xv) > 2
        c = [mean(xv,"omitnan"), mean(yv,"omitnan")];
        xSpan = max(xv) - min(xv);
        if xSpan > 5 && xSpan < 200
            positions(end+1,:) = c; %#ok<AGROW>
        end
    end
end
end
