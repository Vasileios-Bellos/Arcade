%generateIcon  Generate icon and splash screen for Arcade.
%   Creates:
%       packaging/icon.png    - 256x256 app icon (neon "A" on dark background)
%       packaging/splash.png  - 640x480 splash screen ("ARCADE" title)
%
%   The .png icon works directly with compiler.build.standaloneApplication.
%   For a .ico file (Windows shortcut icon), convert icon.png using:
%       - Online: https://convertio.co/png-ico/
%       - ImageMagick: magick convert icon.png -define icon:auto-resize icon.ico
%
%   Usage:
%       cd packaging
%       generateIcon
%
%   See also buildExecutable

scriptDir = fileparts(mfilename("fullpath"));

%% Color palette (matching Arcade.m neon theme)
bgColor = [0.015, 0.015, 0.03];
neonCyan = [0, 0.92, 1];
glowCyan = [0, 0.45, 0.55];

%% ===== ICON (256x256) =====
fprintf("Generating icon.png (256x256)...\n");

fig = figure("Visible", "off", ...
    "Color", bgColor, ...
    "Units", "pixels", ...
    "Position", [100, 100, 256, 256], ...
    "MenuBar", "none", ...
    "ToolBar", "none");

ax = axes(fig, ...
    "Units", "normalized", ...
    "Position", [0, 0, 1, 1], ...
    "Color", bgColor, ...
    "XColor", "none", ...
    "YColor", "none", ...
    "XLim", [0, 1], ...
    "YLim", [0, 1]);
hold(ax, "on");

% Draw the Asteroids ship wireframe (triangle/arrow) as the icon
% Ship vertices - a forward-pointing arrow/chevron, scaled up to fill icon
sc = 1.30;  % scale factor from center
cx = 0.50; cy = 0.529;  % equalize top/bottom margins
shipX = cx + ([0.50, 0.22, 0.38, 0.50, 0.62, 0.78, 0.50] - cx) * sc;
shipY = cy + ([0.85, 0.18, 0.32, 0.25, 0.32, 0.18, 0.85] - cy) * sc;

% Outer glow (thick, dim)
plot(ax, shipX, shipY, "-", ...
    "Color", [glowCyan, 0.35], ...
    "LineWidth", 10);

% Mid glow
plot(ax, shipX, shipY, "-", ...
    "Color", [glowCyan, 0.6], ...
    "LineWidth", 5);

% Core line (bright neon)
plot(ax, shipX, shipY, "-", ...
    "Color", neonCyan, ...
    "LineWidth", 2.5);

% Inner void - rhombus inscribed inside the A via polybuffer inset
% Outer quad scaled by same factor
oqX = cx + ([0.50, 0.70, 0.50, 0.30] - cx) * sc;
oqY = cy + ([0.85, 0.37, 0.25, 0.37] - cy) * sc;
oqPoly = polyshape(oqX, oqY);
insetPoly = polybuffer(oqPoly, -0.08 * sc, "JoinType", "miter");
[cbX, cbY] = boundary(insetPoly);

% 3-layer glow (slightly thinner than outer to fit cleanly)
plot(ax, cbX, cbY, "-", ...
    "Color", [glowCyan, 0.35], ...
    "LineWidth", 7);
plot(ax, cbX, cbY, "-", ...
    "Color", [glowCyan, 0.6], ...
    "LineWidth", 3.5);
plot(ax, cbX, cbY, "-", ...
    "Color", neonCyan, ...
    "LineWidth", 1.8);

hold(ax, "off");

iconPath = fullfile(scriptDir, "icon.png");
fr = getframe(fig);
imwrite(imresize(fr.cdata, [256, 256]), iconPath);
close(fig);
fprintf("  Saved: %s\n\n", iconPath);

%% ===== SPLASH / PREVIEW IMAGE (800x600, 4:3) =====
%  Used for: splash.png (exe installer), File Exchange preview, social card.
fprintf("Generating splash.png (800x600)...\n");

pw = 800; ph = 600;
fig = figure("Visible", "off", ...
    "Color", bgColor, ...
    "Units", "pixels", ...
    "Position", [100, 100, pw, ph], ...
    "MenuBar", "none", ...
    "ToolBar", "none");

ax = axes(fig, ...
    "Units", "normalized", ...
    "Position", [0, 0, 1, 1], ...
    "Color", bgColor, ...
    "XColor", "none", ...
    "YColor", "none", ...
    "XLim", [0, pw], ...
    "YLim", [0, ph]);
hold(ax, "on");

% Starfield background (matching GameMenu dim dots)
rng(42);
nStars = 180;
starX = rand(nStars, 1) * pw;
starY = rand(nStars, 1) * ph;
plot(ax, starX, starY, ".", ...
    "MarkerSize", 3, "Color", [0.35, 0.40, 0.55, 0.4]);

% --- Two static comet trails (top-left and bottom-right) ---
nTP = 200;
headClr = [0.85, 0.90, 0.95];
tailClr = [0.30, 0.35, 0.50];
cFaces = [(1:nTP-1)', (2:nTP)'];

% Comet positions: [headX, headY, angle, length]
comets = [
    pw * 0.22, ph * 0.70, deg2rad(145), pw * 0.22;   % top-left
    pw * 0.78, ph * 0.70, deg2rad(35),  pw * 0.22;   % top-right (mirror)
    pw * 0.88, ph * 0.09, deg2rad(145), pw * 0.22;   % bottom-right
    pw * 0.12, ph * 0.09, deg2rad(35),  pw * 0.22;   % bottom-left
];

for c = 1:size(comets, 1)
    chX = comets(c, 1);
    chY = comets(c, 2);
    cAng = comets(c, 3);
    cLen = comets(c, 4);
    cVertices = zeros(nTP, 2);
    cAlpha = zeros(nTP, 1);
    cColor = zeros(nTP, 3);
    for v = 1:nTP
        frac = (v - 1) / (nTP - 1);
        cVertices(v, :) = [chX + cos(cAng) * cLen * frac, ...
                           chY + sin(cAng) * cLen * frac];
        cAlpha(v) = 1 - frac;
        cColor(v, :) = headClr * (1 - frac) + tailClr * frac;
    end
    patch(ax, "Vertices", cVertices, "Faces", cFaces, ...
        "FaceColor", "none", "EdgeColor", "interp", ...
        "FaceVertexCData", cColor, ...
        "FaceVertexAlphaData", cAlpha, ...
        "EdgeAlpha", "interp", "AlphaDataMapping", "none", ...
        "LineWidth", 1.5);
    plot(ax, chX, chY, ".", "MarkerSize", 6, "Color", headClr);
end

% --- Title: "A R C A D E" (matching GameMenu style) ---
% Menu uses: shadow [0 0.12 0.17], main [0.0 0.55 0.65], offset (+2, +1.5)
menuTeal = [0.0, 0.55, 0.65];
shadowClr = [0, 0.12, 0.17];
titleY = ph * 0.88;
titleFs = 40;
glowOff = 5;  % visible shadow offset
% Shadow (down-right, matching GameMenu)
text(ax, pw/2 + glowOff, titleY - glowOff, "A R C A D E", ...
    "FontSize", titleFs, "FontWeight", "bold", ...
    "Color", shadowClr, ...
    "HorizontalAlignment", "center", "VerticalAlignment", "middle", ...
    "FontName", "Consolas");
% Main text
text(ax, pw/2, titleY, "A R C A D E", ...
    "FontSize", titleFs, "FontWeight", "bold", ...
    "Color", menuTeal, ...
    "HorizontalAlignment", "center", "VerticalAlignment", "middle", ...
    "FontName", "Consolas");

% --- Decorative line (wide, matching GameMenu glow + core) ---
lineY = ph * 0.81;
lineHW = pw * 0.25;
line(ax, [pw/2 - lineHW, pw/2 + lineHW], [lineY, lineY], ...
    "Color", [menuTeal, 0.25], "LineWidth", 6);
line(ax, [pw/2 - lineHW, pw/2 + lineHW], [lineY, lineY], ...
    "Color", [menuTeal, 0.6], "LineWidth", 1.2);

% --- Neon "A" ship icon (centered) ---
iconCx = pw / 2;
iconCy = ph * 0.48;
iconSz = ph * 0.55;
sX = @(x) iconCx + (x - 0.50) * iconSz;
sY = @(y) iconCy + (y - 0.50) * iconSz;

shipX = [0.50, 0.22, 0.38, 0.50, 0.62, 0.78, 0.50];
shipY = [0.85, 0.18, 0.32, 0.25, 0.32, 0.18, 0.85];
icoX = sX(shipX);
icoY = sY(shipY);

% Outer glow
plot(ax, icoX, icoY, "-", "Color", [glowCyan, 0.35], "LineWidth", 8);
% Mid glow
plot(ax, icoX, icoY, "-", "Color", [glowCyan, 0.6], "LineWidth", 4);
% Core line
plot(ax, icoX, icoY, "-", "Color", neonCyan, "LineWidth", 2);

% Inner rhombus (same polybuffer approach)
oqPoly = polyshape([0.50, 0.70, 0.50, 0.30], [0.85, 0.37, 0.25, 0.37]);
insetPoly = polybuffer(oqPoly, -0.08, "JoinType", "miter");
[cbXr, cbYr] = boundary(insetPoly);
icbX = sX(cbXr);
icbY = sY(cbYr);
plot(ax, icbX, icbY, "-", "Color", [glowCyan, 0.35], "LineWidth", 5);
plot(ax, icbX, icbY, "-", "Color", [glowCyan, 0.6], "LineWidth", 2.5);
plot(ax, icbX, icbY, "-", "Color", neonCyan, "LineWidth", 1.4);

% --- Bottom text ---
text(ax, pw/2, ph * 0.12, "15 Classic & Original Games", ...
    "FontSize", 14, "FontWeight", "bold", ...
    "Color", menuTeal, ...
    "HorizontalAlignment", "center", "VerticalAlignment", "middle", ...
    "FontName", "Consolas");

text(ax, pw/2, ph * 0.05, "Built Using MATLAB MCP Core Server", ...
    "FontSize", 11, ...
    "Color", [0.3, 0.35, 0.4], ...
    "HorizontalAlignment", "center", "VerticalAlignment", "middle", ...
    "FontName", "Consolas");

hold(ax, "off");

splashPath = fullfile(scriptDir, "splash.png");
exportgraphics(fig, splashPath, "Resolution", 300);
close(fig);
fprintf("  Saved: %s\n\n", splashPath);

fprintf("=== Icon and splash generation complete ===\n");
fprintf("\nTo convert icon.png to icon.ico for Windows:\n");
fprintf("  Option 1: https://convertio.co/png-ico/\n");
fprintf("  Option 2: magick convert icon.png -define icon:auto-resize icon.ico\n");
