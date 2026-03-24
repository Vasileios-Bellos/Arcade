%buildExecutable  Build standalone Arcade executable and installer.
%   Builds a Windows standalone application with custom icon and splash,
%   then packages it as an installer with web-delivered MATLAB Runtime.
%
%   Prerequisites:
%       - MATLAB Compiler toolbox (verify with: ver("compiler"))
%       - All game classes in +games/, +engine/, +ui/, +services/
%       - Run generateIcon.m first to create icon.png, splash.png, icon.ico
%
%   Usage:
%       cd packaging
%       buildExecutable
%
%   Output:
%       packaging/build/Arcade/  - standalone executable
%       packaging/installer/           - installer with web runtime download
%
%   See also compiler.build.standaloneWindowsApplication,
%            compiler.package.installer, generateIcon, buildToolbox

%% Resolve paths
scriptDir = fileparts(mfilename("fullpath"));
projectDir = fileparts(scriptDir);
buildDir = fullfile(scriptDir, "build");
installerDir = fullfile(scriptDir, "installer");

fprintf("=== Arcade - Standalone Build ===\n\n");
fprintf("Project root  : %s\n", projectDir);
fprintf("Build output  : %s\n", buildDir);
fprintf("Installer out : %s\n\n", installerDir);

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
fprintf("\n");

%% Resolve icon and splash assets
% Icon - .png for executable build (compiler converts to .ico internally),
%         .ico for installer branding (Add/Remove Programs, shortcut)
icoFile = fullfile(scriptDir, "icon.ico");
pngFile = fullfile(scriptDir, "icon.png");

% Executable build only accepts PNG/BMP/JPG/GIF
if isfile(pngFile)
    exeIcon = pngFile;
    fprintf("  Executable icon : %s\n", pngFile);
else
    exeIcon = "";
    fprintf("  Executable icon : none - run generateIcon.m first\n");
end

% Installer also requires PNG (compiler converts internally)
installerIcon = exeIcon;  % same .png

% Splash screen - shown while the executable loads
splashFile = fullfile(scriptDir, "splash.png");
if isfile(splashFile)
    exeSplash = splashFile;
    fprintf("  Splash screen   : %s\n", splashFile);
else
    exeSplash = "";
    fprintf("  Splash screen   : none - run generateIcon.m first\n");
end

% Preview/logo - used for installer branding
previewFile = fullfile(scriptDir, "preview.png");
if isfile(previewFile)
    installerLogo = previewFile;
    fprintf("  Installer logo  : %s\n", previewFile);
else
    installerLogo = "";
end

fprintf("\n");

%% Build standalone Windows application
try
    fprintf("Building standalone application...\n");
    fprintf("This may take several minutes on the first build.\n\n");

    buildTic = tic;

    opts = {};
    opts{end + 1} = entryPoint;
    opts = [opts, {"AdditionalFiles", string(additionalFiles)}];
    opts = [opts, {"OutputDir", buildDir}];
    opts = [opts, {"ExecutableName", "Arcade"}];
    opts = [opts, {"ExecutableVersion", "1.0.0.0"}];
    opts = [opts, {"Verbose", "on"}];
    opts = [opts, {"AutoDetectDataFiles", "on"}];

    if strlength(exeIcon) > 0
        opts = [opts, {"ExecutableIcon", exeIcon}];
    end
    if strlength(exeSplash) > 0
        opts = [opts, {"ExecutableSplashScreen", exeSplash}];
    end

    buildResult = compiler.build.standaloneWindowsApplication(opts{:});

    elapsed = toc(buildTic);
    fprintf("\n=== BUILD SUCCEEDED (%.1f seconds) ===\n\n", elapsed);
    fprintf("Output directory:\n  %s\n\n", buildResult.Options.OutputDir);

    % List output files
    outFiles = dir(fullfile(buildResult.Options.OutputDir, "**/*"));
    outFiles = outFiles(~[outFiles.isdir]);
    if ~isempty(outFiles)
        fprintf("Output files:\n");
        for k = 1:numel(outFiles)
            fprintf("  %s  (%.1f MB)\n", ...
                outFiles(k).name, outFiles(k).bytes / 1e6);
        end
    end

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
    fprintf(2, "  3. Ensure no syntax errors: checkcode('%s')\n", entryPoint);
    rethrow(ME);
end

%% Package installer with web-delivered MATLAB Runtime
try
    fprintf("\n=== Packaging Installer ===\n\n");
    installerTic = tic;

    instOpts = {};
    instOpts = [instOpts, {"ApplicationName", "Arcade"}];
    instOpts = [instOpts, {"AuthorName", "Vasileios Bellos"}];
    instOpts = [instOpts, {"Version", "1.0.0"}];
    instOpts = [instOpts, {"Summary", "15 neon-styled arcade games in pure MATLAB"}];
    instOpts = [instOpts, {"Description", ...
        "A collection of 15 arcade games (8 classics + 7 originals) with a " + ...
        "neon-styled launcher, persistent high scores, frame-rate independence, " + ...
        "and automatic display scaling. No toolboxes required."}];
    instOpts = [instOpts, {"InstallerName", "ArcadeInstaller"}];
    instOpts = [instOpts, {"OutputDir", installerDir}];
    instOpts = [instOpts, {"RuntimeDelivery", "web"}];
    instOpts = [instOpts, {"DefaultInstallationDir", ...
        fullfile("C:", "Program Files", "Arcade")}];
    instOpts = [instOpts, {"Verbose", "on"}];

    % Installer icon - for Add/Remove Programs and installer exe thumbnail
    if strlength(installerIcon) > 0
        instOpts = [instOpts, {"InstallerIcon", installerIcon}];
        instOpts = [instOpts, {"AddRemoveProgramsIcon", installerIcon}];
        fprintf("  Installer icon         : %s\n", installerIcon);
    end

    % Installer splash - shown while installer initializes
    if strlength(exeSplash) > 0
        instOpts = [instOpts, {"InstallerSplash", exeSplash}];
        fprintf("  Installer splash       : %s\n", exeSplash);
    end

    % Installer logo - displayed during installation wizard pages
    if strlength(installerLogo) > 0
        instOpts = [instOpts, {"InstallerLogo", installerLogo}];
        fprintf("  Installer logo         : %s\n", installerLogo);
    end

    fprintf("  Runtime delivery       : web (download during install)\n\n");

    compiler.package.installer(buildResult, instOpts{:});

    elapsed = toc(installerTic);
    fprintf("\n=== INSTALLER PACKAGED (%.1f seconds) ===\n\n", elapsed);

    % List installer files
    instFiles = dir(fullfile(installerDir, "*"));
    instFiles = instFiles(~[instFiles.isdir]);
    if ~isempty(instFiles)
        fprintf("Installer files:\n");
        for k = 1:numel(instFiles)
            fprintf("  %s  (%.1f MB)\n", ...
                instFiles(k).name, instFiles(k).bytes / 1e6);
        end
    end

    fprintf("\nThe installer will download MATLAB Runtime R%s during installation.\n", ...
        version("-release"));
    fprintf("End users do NOT need MATLAB installed.\n");

catch ME
    fprintf(2, "\n=== INSTALLER PACKAGING FAILED ===\n\n");
    fprintf(2, "Error: %s\n", ME.message);
    fprintf(2, "\nThe standalone .exe was built successfully.\n");
    fprintf(2, "To run it, the target machine needs MATLAB Runtime R%s.\n", ...
        version("-release"));
    fprintf(2, "Download: https://www.mathworks.com/products/compiler/matlab-runtime.html\n");
end

fprintf("\n=== All done ===\n");
