# Arcade - Packaging Guide

Build and distribute the Arcade as a standalone Windows executable or MATLAB Toolbox.

---

## Prerequisites

| Requirement | Purpose |
|---|---|
| MATLAB R2024b+ | Development and build environment |
| MATLAB Compiler toolbox | Standalone executable (`compiler.build.standaloneApplication`) |
| (Optional) ImageMagick | Convert icon.png to icon.ico |

Verify MATLAB Compiler is installed:
```matlab
ver("compiler")
```

## Project Structure

```
Arcade/
├── Arcade.m                 % Entry point (main class)
├── +engine/
│   └── GameBase.m           % Abstract base class for all games
├── +games/
│   ├── Pong.m               % 15 game classes
│   ├── Breakout.m
│   ├── Snake.m
│   ├── Tetris.m
│   ├── Asteroids.m
│   ├── SpaceInvaders.m
│   ├── FlappyBird.m
│   ├── FruitNinja.m
│   ├── TargetPractice.m
│   ├── FireflyChase.m
│   ├── FlickIt.m
│   ├── Juggler.m
│   ├── OrbitalDefense.m
│   ├── ShieldGuardian.m
│   └── RailShooter.m
├── +ui/
│   └── GameMenu.m           % Scrollable neon menu
├── +services/
│   └── ScoreManager.m       % Persistent high-score storage
├── data/
│   └── scores.mat           % High scores (created at runtime)
└── packaging/
    ├── scripts/
    │   ├── buildExecutable.m % Standalone executable build script
    │   ├── buildToolbox.m    % Toolbox (.mltbx) build script
    │   └── generateIcon.m    % Icon/splash generator
    ├── assets/
    │   ├── icon.png          % 256x256 app icon
    │   ├── icon.ico          % Multi-resolution Windows icon
    │   └── splash.png        % 800x600 splash screen
    ├── Arcade.mltbx          % Pre-built toolbox
    ├── ArcadeInstaller.exe   % Pre-built installer
    └── README.md             % This file
```

---

## Standalone Executable

### Step 1: Generate Icon and Splash

```matlab
cd packaging/scripts
generateIcon
```

This creates:
- `packaging/assets/icon.png` - 256x256 app icon (neon ship wireframe)
- `packaging/assets/splash.png` - 800x600 splash screen

#### Converting to .ico (optional, recommended for Windows)

The `.png` icon works with `compiler.build.standaloneApplication`. For a proper Windows `.ico` with multiple resolutions:

**Option A - ImageMagick (command line):**
```bash
magick convert packaging/assets/icon.png -define icon:auto-resize=256,128,64,48,32,16 packaging/assets/icon.ico
```

**Option B - Online converter:**
- https://convertio.co/png-ico/

### Step 2: Build the Executable

```matlab
cd packaging/scripts
buildExecutable
```

The build script:
1. Verifies MATLAB Compiler is installed
2. Locates the entry point (`Arcade.m`) and all `+package` folders
3. Includes `data/` for score persistence
4. Uses `icon.ico` or `icon.png` if present
5. Outputs to `packaging/build/Arcade/`

Build time: 3-10 minutes on first build (MATLAB Compiler analyzes all dependencies).

#### Build Output

```
packaging/build/
└── Arcade/
    ├── Arcade.exe          % Standalone executable
    ├── requiredMCRProducts.txt
    └── readme.txt                % Auto-generated runtime info
```

### Step 3: Distribute

#### What to ship

1. **`Arcade.exe`** - the compiled executable
2. **MATLAB Runtime installer** - required on machines without MATLAB

#### MATLAB Runtime

End users need the MATLAB Runtime matching your MATLAB version. It is a free download:

https://www.mathworks.com/products/compiler/matlab-runtime.html

| Your MATLAB | Runtime Version |
|---|---|
| R2024b | R2024b (24.2) |
| R2025a | R2025a (25.1) |

The runtime is approximately 3 GB installed. Users only need to install it once.

#### Distribution options

**Option A - Ship exe + link to Runtime:**
Provide the `.exe` and tell users to install MATLAB Runtime from the link above.

**Option B - Include Runtime installer:**
```matlab
compiler.build.standaloneApplication("Arcade.m", ...
    "AdditionalFiles", {"+engine", "+games", "+services", "+ui", "data"}, ...
    "OutputDir", "packaging/build", ...
    "ExecutableName", "Arcade");

compiler.package.installer( ...
    "packaging/build/Arcade", ...
    "OutputDir", "packaging/installer", ...
    "InstallerName", "Arcade_Installer", ...
    "RuntimeDelivery", "installer");
```
This bundles the Runtime into a single installer (approximately 1.5 GB).

---

## Toolbox (.mltbx)

For users who have MATLAB installed, a toolbox is simpler to distribute than a standalone executable.

### Build

```matlab
cd packaging/scripts
buildToolbox
```

This produces `packaging/Arcade.mltbx`.

### What is included

| Included | Path |
|----------|------|
| Entry point | `Arcade.m` |
| Engine | `+engine/GameBase.m` |
| UI | `+ui/GameMenu.m` |
| Services | `+services/ScoreManager.m` |
| Games (15) | `+games/*.m` |
| Documentation | `README.md`, `LICENSE` |

### What is excluded

| Excluded | Reason |
|----------|--------|
| `index.html`, `technical.html` | Browser port, not needed for MATLAB |
| `dev/`, `assets/` | Documentation and media |
| `data/` | Auto-generated at runtime (`scores.mat`) |
| `misc/` | Legacy scripts and videos |
| `packaging/` | This build infrastructure |

### Install

Double-click the `.mltbx` file, or:

```matlab
matlab.addons.toolbox.installToolbox("Arcade.mltbx")
```

After installation, `Arcade()` and all `games.*` classes are on the path automatically.

### Distribute

Upload the `.mltbx` file to any of:

- **MATLAB File Exchange** (link to the GitHub repo, attach `.mltbx` as a release asset)
- **GitHub Releases** (tag a version, attach the `.mltbx`)
- **Direct download** (share the file)

### Version bumps

Edit the `opts.ToolboxVersion` line in `scripts/buildToolbox.m` before rebuilding.

### Older MATLAB versions

`matlab.addons.toolbox.ToolboxOptions` was introduced in R2023a. On older releases you can package manually:

1. Open **MATLAB > HOME > Add-Ons > Package Toolbox**
2. Add the project root folder
3. Fill in the metadata (name, version, author, description)
4. Include only `Arcade.m`, `+engine/`, `+games/`, `+services/`, `+ui/`, `README.md`, `LICENSE`
5. Click **Package**

---

## Known Issues

### Score file path in compiled mode

`ScoreManager` locates `data/scores.mat` relative to its own `.m` file via `which("services.ScoreManager")`. In compiled mode, `which` returns the CTF (Component Technology File) extraction path. The `data/` folder must be included as an additional file (the build script handles this). Scores will be written to the CTF extraction directory, which persists between runs on the same machine.

If scores need to persist across application updates, consider modifying `ScoreManager.filePath()` to use `ctfroot` (compiled) or `userpath` as an alternative storage location:

```matlab
function p = filePath()
    if isdeployed
        baseDir = ctfroot;
    else
        baseDir = fileparts(fileparts(which("services.ScoreManager")));
    end
    dataDir = fullfile(baseDir, "data");
    if ~isfolder(dataDir)
        mkdir(dataDir);
    end
    p = fullfile(dataDir, "scores.mat");
end
```

### Graphics rendering

The compiled application uses the same MATLAB graphics engine. Performance should match running from MATLAB directly. The `figure` window will not show the MATLAB desktop or command window.

### Timer behavior

`Arcade.m` uses a MATLAB `timer` object for the render loop. This works identically in compiled mode.
