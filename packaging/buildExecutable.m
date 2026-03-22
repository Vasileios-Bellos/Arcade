%buildExecutable  Build standalone MATLAB Arcade executable.
%   Uses compiler.build.standaloneApplication to package the Arcade
%   launcher and all game/engine/UI/services packages into a single
%   distributable executable.
%
%   Prerequisites:
%       - MATLAB Compiler toolbox (verify with: ver("compiler"))
%       - All game classes in +games/, +engine/, +ui/, +services/
%
%   Usage:
%       cd packaging
%       buildExecutable
%
%   Output: packaging/build/MATLABarcade/ containing the executable
%
%   See also compiler.build.standaloneApplication, Arcade

%% Resolve paths
scriptDir = fileparts(mfilename("fullpath"));
projectDir = fileparts(scriptDir);
buildDir = fullfile(scriptDir, "build");

fprintf("=== MATLAB Arcade — Standalone Build ===\n\n");
fprintf("Project root : %s\n", projectDir);
fprintf("Output folder: %s\n\n", buildDir);

%% Check MATLAB Compiler is available
if isempty(ver("compiler"))
    error("buildExecutable:MissingToolbox", ...
        "MATLAB Compiler toolbox is not installed.\n" + ...
        "Install it via Add-Ons > Get Add-Ons > search 'MATLAB Compiler'.");
end
fprintf("MATLAB Compiler: found (R%s)\n\n", version("-release"));

%% Entry point
entryPoint = fullfile(projectDir, "Arcade.m");
if ~isfile(entryPoint)
    error("buildExecutable:MissingEntry", ...
        "Entry point not found: %s\n" + ...
        "Run this script from the packaging/ folder inside the Arcade project.", ...
        entryPoint);
end

%% Collect package folders as additional files
%  compiler.build needs entire +package directories so that all classes
%  and their namespaced references resolve at runtime.
packageNames = ["+engine", "+games", "+services", "+ui"];
additionalFiles = {};
for k = 1:numel(packageNames)
    pkgDir = fullfile(projectDir, packageNames(k));
    if isfolder(pkgDir)
        additionalFiles{end + 1} = pkgDir; %#ok<SAGROW>
        fprintf("  Including package: %s\n", packageNames(k));
    else
        warning("buildExecutable:MissingPackage", ...
            "Expected package folder not found: %s", pkgDir);
    end
end

%% Include data/ folder (scores.mat lives here at runtime)
dataDir = fullfile(projectDir, "data");
if isfolder(dataDir)
    additionalFiles{end + 1} = dataDir;
    fprintf("  Including folder : data/\n");
end

fprintf("\n");

%% Icon (optional)
iconFile = fullfile(scriptDir, "icon.png");
useIcon = isfile(iconFile);
if useIcon
    fprintf("  Icon: %s\n\n", iconFile);
else
    iconFile = fullfile(scriptDir, "icon.ico");
    if isfile(iconFile)
        useIcon = true;
        fprintf("  Icon: %s\n\n", iconFile);
    else
        fprintf("  Icon: none found (build will use default MATLAB icon)\n");
        fprintf("  Run generateIcon.m first to create icon.png, then convert to .ico\n\n");
    end
end

%% Build
try
    fprintf("Building standalone application...\n");
    fprintf("This may take several minutes on the first build.\n\n");

    buildTic = tic;

    opts = {};
    opts{end + 1} = entryPoint;
    opts = [opts, {"AdditionalFiles", string(additionalFiles)}];
    opts = [opts, {"OutputDir", buildDir}];
    opts = [opts, {"ExecutableName", "MATLABarcade"}];
    opts = [opts, {"Verbose", "on"}];
    opts = [opts, {"AutoDetectDataFiles", "on"}];

    if useIcon
        opts = [opts, {"ExecutableIcon", iconFile}];
    end

    result = compiler.build.standaloneWindowsApplication(opts{:});

    elapsed = toc(buildTic);
    fprintf("\n=== BUILD SUCCEEDED (%.1f seconds) ===\n\n", elapsed);
    fprintf("Output directory:\n  %s\n\n", result.Options.OutputDir);

    % List output files
    outFiles = dir(fullfile(result.Options.OutputDir, "**/*"));
    outFiles = outFiles(~[outFiles.isdir]);
    if ~isempty(outFiles)
        fprintf("Output files:\n");
        for k = 1:numel(outFiles)
            fprintf("  %s  (%.1f MB)\n", ...
                outFiles(k).name, outFiles(k).bytes / 1e6);
        end
    end

    fprintf("\nTo run the executable, the target machine needs MATLAB Runtime R%s.\n", ...
        version("-release"));
    fprintf("Download: https://www.mathworks.com/products/compiler/matlab-runtime.html\n");

catch ME
    fprintf(2, "\n=== BUILD FAILED ===\n\n");
    fprintf(2, "Error: %s\n", ME.message);
    if ~isempty(ME.cause)
        for k = 1:numel(ME.cause)
            fprintf(2, "  Cause: %s\n", ME.cause{k}.message);
        end
    end
    fprintf(2, "\nTroubleshooting:\n");
    fprintf(2, "  1. Verify MATLAB Compiler: ver('compiler')\n");
    fprintf(2, "  2. Check all +package folders exist in project root\n");
    fprintf(2, "  3. Run depfun('Arcade') to find missing dependencies\n");
    fprintf(2, "  4. Ensure no syntax errors: checkcode('%s')\n", entryPoint);
    rethrow(ME);
end
