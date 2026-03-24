%buildToolbox  Package the Arcade project as a .mltbx toolbox.
%   Run this script from MATLAB (R2023b+ recommended). It creates a
%   ToolboxOptions object, sets all metadata and file inclusions, then
%   calls matlab.addons.toolbox.packageToolbox to produce:
%
%       packaging/Arcade.mltbx
%
%   The script auto-detects the project root (parent of the packaging/
%   folder) so it works regardless of your current directory.
%
%   Requirements:
%       - MATLAB R2023b or newer (for matlab.addons.toolbox.ToolboxOptions)
%       - No additional toolboxes
%
%   Usage:
%       >> cd('<project>/packaging')
%       >> buildToolbox
%
%   See also matlab.addons.toolbox.ToolboxOptions,
%           matlab.addons.toolbox.packageToolbox

% =========================================================================
%  1. Resolve paths
% =========================================================================

% Project root is one level above this script's folder.
scriptDir  = fileparts(mfilename("fullpath"));
projectRoot = fileparts(scriptDir);

% Output .mltbx location.
outputFile = fullfile(scriptDir, "Arcade.mltbx");

fprintf("Project root : %s\n", projectRoot);
fprintf("Output file  : %s\n", outputFile);

% =========================================================================
%  2. Verify MATLAB version supports ToolboxOptions (R2023b+)
% =========================================================================

if verLessThan("matlab", "23.2")  %#ok<VERLESSMATLAB> - R2023b = 23.2
    error("buildToolbox:UnsupportedRelease", ...
        "matlab.addons.toolbox.ToolboxOptions requires R2023b or newer.\n" + ...
        "You are running %s. See README_PACKAGING.md for alternatives.", version);
end

% =========================================================================
%  3. Create ToolboxOptions and set metadata
% =========================================================================

% The ToolboxOptions constructor takes the toolbox folder (the root that
% will be added to the MATLAB path when the toolbox is installed).
opts = matlab.addons.toolbox.ToolboxOptions(projectRoot, ...
    "3f4a7b2c-e8d1-4a6f-9c0e-1b5d8f3a7e9d");  % fixed UUID for reproducibility

opts.ToolboxName           = "Arcade";
opts.ToolboxVersion        = "1.0.0";
opts.AuthorName            = "Vasileios Bellos";
opts.Summary               = "15 neon-styled arcade games in pure MATLAB";
opts.Description           = ...
    "A collection of 15 arcade games (8 classics + 7 originals) with a " + ...
    "neon-styled launcher, persistent high scores, frame-rate independence, " + ...
    "and automatic display scaling. No toolboxes required.";
opts.MinimumMatlabRelease  = "R2022b";

% =========================================================================
%  4. Define file inclusions
% =========================================================================
% By default ToolboxOptions includes the entire ToolboxFolder. We override
% with an explicit list so that recording/, assets/, data/, docs/TODO.md,
% .gitignore, .claude/, and packaging/ are excluded.

% --- Collect all files to include ---

% 4a. Root .m files (Arcade.m)
rootFiles = dir(fullfile(projectRoot, "*.m"));
includeFiles = fullfile(projectRoot, {rootFiles.name}');

% 4b. README.md and LICENSE
readmePath = fullfile(projectRoot, "README.md");
if isfile(readmePath)
    includeFiles{end+1, 1} = readmePath;
end
licensePath = fullfile(projectRoot, "LICENSE");
if isfile(licensePath)
    includeFiles{end+1, 1} = licensePath;
end

% 4c. Package folders: +engine, +games, +services, +ui
%     Recursively collect all .m files from each package.
packages = ["+engine", "+games", "+services", "+ui"];
for k = 1:numel(packages)
    pkgDir = fullfile(projectRoot, packages(k));
    if isfolder(pkgDir)
        pkgFiles = dir(fullfile(pkgDir, "**", "*.m"));
        for j = 1:numel(pkgFiles)
            includeFiles{end+1, 1} = fullfile(pkgFiles(j).folder, pkgFiles(j).name); %#ok<SAGROW>
        end
    end
end

% 4d. web/ folder - HTML5 port
webDir = fullfile(projectRoot, "web");
if isfolder(webDir)
    webFiles = dir(fullfile(webDir, "**", "*.*"));
    for j = 1:numel(webFiles)
        if webFiles(j).isdir; continue; end
        includeFiles{end+1, 1} = fullfile(webFiles(j).folder, webFiles(j).name); %#ok<SAGROW>
    end
end

% 4e. dev/ folder - include README.md (developer docs), exclude TODO.md
devDir = fullfile(projectRoot, "dev");
if isfolder(devDir)
    devReadme = fullfile(devDir, "README.md");
    if isfile(devReadme)
        includeFiles{end+1, 1} = devReadme; %#ok<SAGROW>
    end
end

% Convert to string array for ToolboxOptions.
includeFiles = string(includeFiles);

% Remove duplicates (safety).
includeFiles = unique(includeFiles);

% Print summary.
fprintf("\nFiles to include (%d):\n", numel(includeFiles));
for k = 1:numel(includeFiles)
    fprintf("  %s\n", extractAfter(includeFiles(k), strlength(projectRoot)));
end

% Assign to options. ToolboxMatlabPath is the folder added to the MATLAB
% path on install - the project root, so Arcade() and packages work.
opts.ToolboxFiles      = includeFiles;
opts.ToolboxMatlabPath = projectRoot;

% =========================================================================
%  5. Set the getting-started entry point
% =========================================================================
% Note: ToolboxGettingStartedGuide requires .m or .mlx files.
% README.md is included as a regular file instead.

% =========================================================================
%  5b. Set toolbox icon
% =========================================================================
iconFile = fullfile(scriptDir, "icon.png");
if isfile(iconFile)
    opts.ToolboxImageFile = iconFile;
    fprintf("\nIcon: %s\n", iconFile);
end

% =========================================================================
%  6. Build the .mltbx
% =========================================================================

fprintf("\nPackaging toolbox...\n");
opts.OutputFile = outputFile;
matlab.addons.toolbox.packageToolbox(opts);
fprintf("Done. Toolbox saved to:\n  %s\n", outputFile);
fprintf("\nTo install: double-click the .mltbx file or run:\n");
fprintf("  matlab.addons.toolbox.installToolbox(""%s"")\n", outputFile);
