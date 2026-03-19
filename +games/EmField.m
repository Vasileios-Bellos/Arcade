classdef EmField < GameBase
    %EmField  Electric field quiver visualization + cyclotron particle accelerator.
    %   Five sub-modes: monopole, dipole, quadrupole, random (Coulomb E-field
    %   with flowing test charges) and cyclotron (Boris pusher, D-shaped
    %   electrodes, RF resonance, extraction scoring).
    %
    %   Controls:
    %     M or 1-5  — sub-mode (monopole/dipole/quadrupole/random/cyclotron)
    %     N         — toggle finger charge (attract/repel)
    %     B         — toggle particle visibility (E-field modes only)
    %     Up/Down   — quiver density (E-field) or B field strength (cyclotron)
    %     Left/Right — E amplitude (cyclotron only)
    %     0         — reset
    %
    %   Standalone: games.EmField().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "EM Field"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Quiver grid
        LevelIdx        (1,1) double = 4      % quiver grid density tier
        GridNx          (1,1) double = 30      % quiver columns
        GridNy          (1,1) double = 22      % quiver rows

        % Flowing particles
        NodeCount       (1,1) double = 100     % flowing particle count
        PosX            (:,1) double
        PosY            (:,1) double
        Hue             (:,1) double           % per-particle hue [0,1]

        % Fixed charges
        ChargeX         (:,1) double           % fixed charge X positions
        ChargeY         (:,1) double           % fixed charge Y positions
        ChargeQ         (:,1) double           % fixed charge strength (+/-)

        % Finger charge
        FingerQ         (1,1) double = 1.0     % finger charge magnitude
        FingerMode      (1,1) string = "repel"

        % Field parameters
        FlowSpeed       (1,1) double = 2.5     % particle advection speed
        Softening       (1,1) double = 15.0    % field singularity softening
        SubMode         (1,1) string = "monopole"
        Transitioning   (1,1) logical = false   % guard: true during init/cleanup
        SpeedColors     (1,1) logical = true    % true = show flowing particles

        % Display range
        Dx              (1,2) double = [0 1]
        Dy              (1,2) double = [0 1]

        % Timing
        FrameCount      (1,1) double = 0

        % Trail arrays
        TrailX          (:,:) double
        TrailY          (:,:) double
        TrailLen        (1,1) double = 20

        % Cyclotron particle velocities
        VelX            (:,1) double
        VelY            (:,1) double

        % Cyclotron parameters
        BUniform        (1,1) double = 0.10    % uniform B field strength
        CycRadius       (1,1) double = 0       % cyclotron chamber radius (px)
        CycCx           (1,1) double = 0       % cyclotron center X
        CycCy           (1,1) double = 0       % cyclotron center Y
        CycGapW         (1,1) double = 0       % gap half-width (px)
        CycEAmp         (1,1) double = 0.30    % gap E field amplitude
        CycPhase        (1,1) double = 0       % RF oscillator phase (rad)
        CycSpawnTic     (1,1) double = 0       % frame counter for spawning
        CycSimTime      (1,1) double = 0       % cumulative simulation time
        CycDtSub        (1,1) double = 0.5     % substep time increment
        CycNSub         (1,1) double = 8       % substeps per frame
        CycExtractions  (1,1) double = 0       % total particles extracted
        CycTotalSpawned (1,1) double = 0       % running counter for unique hue

        % Quiver grid coordinates
        QGridX          (:,:) double
        QGridY          (:,:) double
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        FieldImageH                             % background field image
        QuiverH                                 % quiver plot handle
        ChargeGlowH                            % charge marker glow scatter
        ChargeCoreH                            % charge marker core scatter
        TrailH                                  % particle trail patch
        NodeGlowH                              % particle glow scatter
        NodeCoreH                              % particle core scatter
        ModeTextH                              % HUD text

        % Cyclotron-specific graphics
        DeeH                                    % dee patch handles [left, right]
        CycRingH                                % boundary circle line
        CycGapH                                 % gap indicator patch
        CycLineH                                % cell array: per-particle core trail patches
        CycGlowLineH                           % cell array: per-particle glow trail lines
        CycStreamH                             % dee streamline line handles
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create graphics and initialize EM field state.
            arguments
                obj
                ax
                displayRange struct
                ~
            end
            obj.Ax = ax;
            obj.DisplayRange = displayRange;
            obj.Score = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;

            obj.Dx = displayRange.X;
            obj.Dy = displayRange.Y;
            dxR = obj.Dx;
            dyR = obj.Dy;
            nPart = obj.NodeCount;
            isCyc = obj.SubMode == "cyclotron";

            % Scale display-space constants for actual display size
            sc = min(diff(dxR), diff(dyR)) / 180;
            obj.Softening = 15.0 * sc;
            obj.FlowSpeed = 2.5 * sc;

            % Trail length depends on mode
            if isCyc
                obj.TrailLen = 15;
            else
                obj.TrailLen = 20;
            end

            % Configure fixed charges for current sub-mode
            obj.configureCharges();

            if isCyc
                obj.initCyclotron();
                nPart = numel(obj.PosX);
            else
                obj.PosX = dxR(1) + rand(nPart, 1) * diff(dxR);
                obj.PosY = dyR(1) + rand(nPart, 1) * diff(dyR);
                obj.Hue  = rand(nPart, 1);
                obj.VelX = [];
                obj.VelY = [];

                % Field background image
                obj.renderFieldImage([NaN NaN]);
            end

            % Quiver grid
            if isCyc
                obj.buildCyclotronQuiver();
            else
                obj.buildQuiver();
            end

            % Trail history
            tLen = obj.TrailLen;
            obj.TrailX = repmat(obj.PosX, 1, tLen);
            obj.TrailY = repmat(obj.PosY, 1, tLen);

            % Trail patch
            nVerts = nPart * (tLen + 1);
            initV = zeros(nVerts, 2);
            initF = reshape(1:nVerts, tLen + 1, nPart)';
            initC = zeros(nVerts, 3);
            initA = zeros(nVerts, 1);
            trailVis = "on";
            if isCyc || ~obj.SpeedColors; trailVis = "off"; end
            scatVis = "on";
            if ~isCyc && ~obj.SpeedColors; scatVis = "off"; end
            if ~isempty(obj.TrailH) && isvalid(obj.TrailH)
                set(obj.TrailH, "Vertices", initV, "Faces", initF, ...
                    "FaceVertexCData", initC, "FaceVertexAlphaData", initA, ...
                    "Visible", trailVis);
            else
                obj.TrailH = patch(ax, "Vertices", initV, "Faces", initF, ...
                    "FaceColor", "none", "EdgeColor", "interp", ...
                    "FaceVertexCData", initC, "FaceVertexAlphaData", initA, ...
                    "EdgeAlpha", "interp", "LineWidth", 1.2, ...
                    "Tag", "GT_emfield", "Visible", trailVis);
            end

            % Per-particle fading trails for cyclotron (patch, like Newton's Cradle)
            if isCyc
                obj.CycLineH = cell(nPart, 1);
                obj.CycGlowLineH = {};
                for k = 1:nPart
                    obj.CycLineH{k} = patch(ax, "XData", NaN, "YData", NaN, ...
                        "CData", zeros(1, 1, 3), ...
                        "EdgeColor", "interp", "EdgeAlpha", "interp", ...
                        "FaceVertexAlphaData", 0, "AlphaDataMapping", "none", ...
                        "LineWidth", 2.0, "Tag", "GT_emfield");
                end
            end

            % Particle scatter (glow + core)
            if isCyc
                coreSize = 30;  glowSize = 120;
                coreAlpha = 0.95;  glowAlpha = 0.30;
            else
                coreSize = 14;  glowSize = 50;
                coreAlpha = 0.85;  glowAlpha = 0.15;
            end
            nodeCol = hsv2rgb([obj.Hue, ...
                ones(nPart, 1) * 0.9, ones(nPart, 1) * 0.95]);
            if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH)
                set(obj.NodeGlowH, "XData", obj.PosX, ...
                    "YData", obj.PosY, "SizeData", glowSize * ones(nPart, 1), ...
                    "CData", nodeCol, "MarkerFaceAlpha", glowAlpha, ...
                    "Visible", "off");
            else
                obj.NodeGlowH = scatter(ax, obj.PosX, obj.PosY, ...
                    glowSize * ones(nPart, 1), nodeCol, "filled", ...
                    "MarkerFaceAlpha", glowAlpha, "Tag", "GT_emfield", ...
                    "Visible", "off");
            end
            if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH)
                set(obj.NodeCoreH, "XData", obj.PosX, ...
                    "YData", obj.PosY, "SizeData", coreSize * ones(nPart, 1), ...
                    "CData", nodeCol, "MarkerFaceAlpha", coreAlpha, ...
                    "Visible", "off");
            else
                obj.NodeCoreH = scatter(ax, obj.PosX, obj.PosY, ...
                    coreSize * ones(nPart, 1), nodeCol, "filled", ...
                    "MarkerFaceAlpha", coreAlpha, "Tag", "GT_emfield", ...
                    "Visible", "off");
            end

            % Charge markers
            obj.renderChargeMarkers();

            % HUD text
            if isempty(obj.ModeTextH) || ~isvalid(obj.ModeTextH)
                obj.ModeTextH = text(ax, obj.Dx(1) + 5, ...
                    obj.Dy(2) - 5, "", ...
                    "Color", [0.6, 0.85, 1.0, 0.6], "FontSize", 8, ...
                    "VerticalAlignment", "bottom", "Tag", "GT_emfield");
            end

            obj.StartTic = tic;
            obj.FrameCount = 0;
            obj.updateHud();

            % Z-order: particles on top of dees/streamlines
            if isCyc
                if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH)
                    uistack(obj.NodeGlowH, "top");
                end
                if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH)
                    uistack(obj.NodeCoreH, "top");
                end
            end

            % Reveal scatter particles (structural elements already visible)
            if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH)
                obj.NodeGlowH.Visible = scatVis;
            end
            if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH)
                obj.NodeCoreH.Visible = scatVis;
            end
            if isCyc || ~obj.SpeedColors
                if ~isempty(obj.TrailH) && isvalid(obj.TrailH)
                    obj.TrailH.Visible = "off";
                end
            end
            if isCyc
                if ~isempty(obj.FieldImageH) && isvalid(obj.FieldImageH)
                    obj.FieldImageH.Visible = "off";
                end
            end
        end

        function onUpdate(obj, fingerPos)
            %onUpdate  Per-frame update: physics + rendering.
            if obj.Transitioning || isempty(obj.PosX) || ...
                    isempty(obj.Dx); return; end
            obj.FrameCount = obj.FrameCount + 1;
            dxR = obj.Dx;
            dyR = obj.Dy;
            ww = dxR(2) - dxR(1);
            hh = dyR(2) - dyR(1);
            isCyc = obj.SubMode == "cyclotron";
            nPart = obj.NodeCount;

            % Declare nodeCol for later use
            nodeCol = zeros(0, 3);

            if isCyc
                % ==== CYCLOTRON: Boris pusher + injection ====
                obj.borisPush(fingerPos);

                % Inject new particles periodically (max 25 visible)
                obj.CycSpawnTic = obj.CycSpawnTic + 1;
                rfPhase = cos(obj.BUniform * obj.CycSimTime);
                minSpawnTic = 15 + 15 * (numel(obj.PosX) >= 5);
                if obj.CycSpawnTic >= minSpawnTic ...
                        && numel(obj.PosX) < 25 && rfPhase > 0.3
                    obj.cycInject();
                    obj.CycSpawnTic = 0;
                end
                nPart = numel(obj.PosX); %#ok<NASGU>

                % Gap E-field indicator color pulse
                obj.updateGapIndicator();

                % Per-particle unique color from Hue
                nHue = numel(obj.Hue);
                nNowCyc = numel(obj.PosX);
                if nNowCyc > 0 && nHue == nNowCyc
                    nodeCol = hsv2rgb([obj.Hue(:), ...
                        ones(nHue, 1) * 0.9, ones(nHue, 1) * 0.95]);
                end

                % Quiver: gap RF E-field + finger Coulomb
                if ~isempty(obj.QGridX) && ~isempty(obj.QuiverH) ...
                        && isvalid(obj.QuiverH)
                    qx = obj.QGridX(:);
                    qy = obj.QGridY(:);
                    nQ = numel(qx);

                    gapE = obj.CycEAmp * cos( ...
                        obj.BUniform * obj.CycSimTime);
                    dxGap = abs(qx - obj.CycCx);
                    visualGapSigma = obj.CycRadius * 0.15;
                    gapWeight = exp(-0.5 * (dxGap / visualGapSigma).^2);
                    qEx = gapE * gapWeight;
                    qEy = zeros(nQ, 1);

                    % Finger Coulomb perturbation (everywhere inside)
                    if ~any(isnan(fingerPos))
                        [Efx, Efy] = obj.computeEField(qx, qy, fingerPos);
                        qEx = qEx + Efx * 25;
                        qEy = qEy + Efy * 25;
                    end

                    Emag = sqrt(qEx.^2 + qEy.^2);
                    maxE = max(Emag(:));
                    if maxE > 1e-12
                        arrowLen = Emag .^ 0.4;
                        arrowLen = arrowLen / max(arrowLen(:));
                        Ux = qEx ./ max(Emag, 1e-12) .* arrowLen;
                        Uy = qEy ./ max(Emag, 1e-12) .* arrowLen;
                    else
                        Ux = zeros(nQ, 1);
                        Uy = zeros(nQ, 1);
                    end
                    arrowScale = obj.CycRadius * 0.10;
                    Ux = Ux * arrowScale;
                    Uy = Uy * arrowScale;
                    set(obj.QuiverH, "UData", Ux, "VData", Uy, ...
                        "Visible", "on");
                end

                % Charge markers (finger position)
                obj.renderChargeMarkers(fingerPos);

            else
                % ==== E-FIELD: quiver + advection ====
                nGrid = numel(obj.QGridX);
                if nGrid ~= obj.GridNy * obj.GridNx
                    obj.buildQuiver();
                end
                [gEx, gEy] = obj.computeEField( ...
                    obj.QGridX(:), obj.QGridY(:), fingerPos);
                gEx = reshape(gEx, obj.GridNy, obj.GridNx);
                gEy = reshape(gEy, obj.GridNy, obj.GridNx);
                Emag = sqrt(gEx.^2 + gEy.^2);
                maxE = max(Emag(:));
                if maxE > 1e-12
                    arrowLen = Emag .^ 0.4;
                    maxLen = max(arrowLen(:));
                    arrowLen = arrowLen / maxLen;
                    Ux = gEx ./ max(Emag, 1e-12) .* arrowLen;
                    Uy = gEy ./ max(Emag, 1e-12) .* arrowLen;
                else
                    Ux = zeros(size(gEx));
                    Uy = zeros(size(gEy));
                end
                if ~isempty(obj.QuiverH) && isvalid(obj.QuiverH)
                    set(obj.QuiverH, "UData", Ux, "VData", Uy);
                end

                % Field background image
                obj.renderFieldImage(fingerPos);

                % Charge markers
                obj.renderChargeMarkers(fingerPos);

                % Particle advection along E
                if obj.SpeedColors
                    px = obj.PosX(:);
                    py = obj.PosY(:);
                    if numel(px) ~= numel(obj.Hue) || ...
                            numel(px) ~= size(obj.TrailX, 1); return; end

                    [Epx, Epy] = obj.computeEField(px, py, fingerPos);
                    Epmag = max(sqrt(Epx.^2 + Epy.^2), 1e-12);

                    % Flow along E: speed ~ |E|^0.3, capped
                    dsE = obj.DtScale;
                    spd = obj.FlowSpeed * min(Epmag.^0.3 * 20, 4.0) * dsE;
                    px = px + spd .* Epx ./ Epmag;
                    py = py + spd .* Epy ./ Epmag;

                    % Capture near negative charges (sinks)
                    captR2 = (obj.Softening * 0.8)^2;
                    fingerCaptR2 = (obj.Softening * 2.0)^2;
                    captured = false(numel(px), 1);
                    for k = 1:numel(obj.ChargeQ)
                        if obj.ChargeQ(k) < 0
                            d2 = (px - obj.ChargeX(k)).^2 + ...
                                (py - obj.ChargeY(k)).^2;
                            captured = captured | d2 < captR2;
                        end
                    end
                    if ~any(isnan(fingerPos)) && obj.FingerMode == "attract"
                        d2 = (px - fingerPos(1)).^2 + ...
                            (py - fingerPos(2)).^2;
                        captured = captured | d2 < fingerCaptR2;
                    end

                    % Respawn captured + out-of-bounds
                    oob = px < dxR(1) | px > dxR(2) | ...
                        py < dyR(1) | py > dyR(2);
                    dead = captured | oob;
                    if any(dead)
                        nDead = sum(dead);
                        px(dead) = dxR(1) + rand(nDead, 1) * ww;
                        py(dead) = dyR(1) + rand(nDead, 1) * hh;
                        obj.Hue(dead) = rand(nDead, 1);
                        tLen = obj.TrailLen;
                        obj.TrailX(dead, :) = repmat(px(dead), 1, tLen);
                        obj.TrailY(dead, :) = repmat(py(dead), 1, tLen);
                    end

                    obj.PosX = px;
                    obj.PosY = py;
                    nH = numel(obj.Hue);
                    nP = numel(px);
                    if nH == nP && nP > 0
                        nodeCol = hsv2rgb([obj.Hue(:), ...
                            ones(nH, 1) * 0.9, ones(nH, 1) * 0.95]);
                    end
                end
            end

            % ==== Trail + scatter update ====
            nNow = numel(obj.PosX);
            showPart = (isCyc || obj.SpeedColors) && nNow > 0 ...
                && size(nodeCol, 1) == nNow;
            if showPart
                px = obj.PosX;
                py = obj.PosY;

                % Auto-repair trail arrays if size mismatches particle count
                tLen = obj.TrailLen;
                if size(obj.TrailX, 1) ~= nNow || size(obj.TrailX, 2) ~= tLen
                    obj.TrailX = repmat(px, 1, tLen);
                    obj.TrailY = repmat(py, 1, tLen);
                end

                % Shift trail history
                obj.TrailX(:, 1:end-1) = obj.TrailX(:, 2:end);
                obj.TrailX(:, end) = px;
                obj.TrailY(:, 1:end-1) = obj.TrailY(:, 2:end);
                obj.TrailY(:, end) = py;

                tLen = obj.TrailLen;

                if isCyc
                    % Cyclotron: fading patch trails (Newton's Cradle style)
                    lineH = obj.CycLineH;
                    for p = 1:nNow
                        if p > numel(lineH) || isempty(lineH{p}) ...
                                || ~isvalid(lineH{p}); continue; end
                        tx = obj.TrailX(p, :)';
                        ty = obj.TrailY(p, :)';
                        validMask = ~isnan(tx);
                        nValid = sum(validMask);
                        if nValid < 3
                            set(lineH{p}, "XData", NaN, "YData", NaN, ...
                                "CData", NaN(1,1,3), "FaceVertexAlphaData", 0);
                            continue;
                        end
                        xv = tx(validMask);
                        yv = ty(validMask);
                        % Smooth orbital curves via makima interpolation
                        if nValid >= 4
                            tt = (1:nValid)';
                            nFine = nValid * 3;
                            ttFine = linspace(1, nValid, nFine)';
                            xv = interp1(tt, xv, ttFine, "makima");
                            yv = interp1(tt, yv, ttFine, "makima");
                            nValid = nFine;
                        end
                        rc = nodeCol(p, 1);
                        gc = nodeCol(p, 2);
                        bc = nodeCol(p, 3);
                        cdata = repmat(reshape([rc gc bc], 1, 1, 3), nValid, 1, 1);
                        alphaVals = linspace(0, 0.4, nValid)';
                        % NaN terminator prevents patch closure
                        xv(end+1) = NaN; %#ok<AGROW>
                        yv(end+1) = NaN; %#ok<AGROW>
                        cdata = cat(1, cdata, NaN(1,1,3));
                        alphaVals(end+1) = NaN; %#ok<AGROW>
                        set(lineH{p}, "XData", xv, "YData", yv, ...
                            "CData", cdata, "FaceVertexAlphaData", alphaVals);
                    end
                else
                    % E-field: shared trail patch
                    nVerts = nNow * (tLen + 1);
                    V = zeros(nVerts, 2);
                    C = repelem(nodeCol, tLen + 1, 1);
                    alphaRamp = linspace(0, 0.30, tLen)';
                    A = repmat([alphaRamp; 0], nNow, 1);

                    % Detect wrap/respawn jumps to break trails
                    dxT = diff(obj.TrailX, 1, 2);
                    dyT = diff(obj.TrailY, 1, 2);
                    jumpMask = (dxT.^2 + dyT.^2) > (ww * 0.25)^2;

                    trailXt = obj.TrailX';
                    trailYt = obj.TrailY';
                    for p = 1:nNow
                        bi = (p - 1) * (tLen + 1);
                        V(bi + 1:bi + tLen, 1) = trailXt(:, p);
                        V(bi + 1:bi + tLen, 2) = trailYt(:, p);
                        V(bi + tLen + 1, :) = [px(p), py(p)];
                        wIdx = find(jumpMask(p, :));
                        if ~isempty(wIdx)
                            A(bi + wIdx) = 0;
                            A(bi + min(wIdx + 1, tLen)) = 0;
                        end
                    end

                    % Rebuild trail patch
                    initF = reshape(1:nVerts, tLen + 1, nNow)';
                    if ~isempty(obj.TrailH) && isvalid(obj.TrailH)
                        set(obj.TrailH, "Vertices", V, "Faces", initF, ...
                            "FaceVertexCData", C, "FaceVertexAlphaData", A);
                    end
                end

                % Update particle scatter
                fs2 = obj.FontScale^2;
                if isCyc
                    coreSize = 30 * fs2;  glowSize = 120 * fs2;
                else
                    coreSize = 14 * fs2;  glowSize = 50 * fs2;
                end
                if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH)
                    obj.NodeCoreH.XData = px;
                    obj.NodeCoreH.YData = py;
                    obj.NodeCoreH.CData = nodeCol;
                    obj.NodeCoreH.SizeData = coreSize * ones(nNow, 1);
                end
                if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH)
                    obj.NodeGlowH.XData = px;
                    obj.NodeGlowH.YData = py;
                    obj.NodeGlowH.CData = nodeCol;
                    obj.NodeGlowH.SizeData = glowSize * ones(nNow, 1);
                end
            end

            % Throttled HUD update (particle count changes)
            if isCyc && mod(obj.FrameCount, 10) == 0
                obj.updateHud();
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all EM field graphics.
            obj.NodeCount = 100;
            obj.cleanupCyclotronGraphics();
            handles = {obj.FieldImageH, obj.QuiverH, ...
                obj.ChargeGlowH, obj.ChargeCoreH, ...
                obj.TrailH, obj.NodeGlowH, ...
                obj.NodeCoreH, obj.ModeTextH};
            for k = 1:numel(handles)
                hh = handles{k};
                if ~isempty(hh) && isvalid(hh); delete(hh); end
            end
            obj.FieldImageH = [];
            obj.QuiverH = [];
            obj.ChargeGlowH = [];
            obj.ChargeCoreH = [];
            obj.TrailH = [];
            obj.NodeGlowH = [];
            obj.NodeCoreH = [];
            obj.ModeTextH = [];
            obj.TrailX = [];
            obj.TrailY = [];
            obj.QGridX = [];
            obj.QGridY = [];
            obj.PosX = [];
            obj.PosY = [];
            obj.VelX = [];
            obj.VelY = [];
            obj.Hue = [];
            obj.CycLineH = {};
            obj.CycGlowLineH = {};
            obj.CycStreamH = [];
            obj.FrameCount = 0;
            obj.CycSimTime = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_emfield");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["monopole", "dipole", "quadrupole", "random", "cyclotron"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.applySubMode();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle EM field mode-specific keys.
            handled = true;

            switch key
                case "m"
                    modes = ["monopole", "dipole", "quadrupole", "random", "cyclotron"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.applySubMode();

                case "n"
                    if obj.FingerMode == "attract"
                        obj.FingerMode = "repel";
                    else
                        obj.FingerMode = "attract";
                    end
                    obj.updateHud();

                case "b"
                    obj.SpeedColors = ~obj.SpeedColors;
                    if obj.SubMode ~= "cyclotron"
                        vis = "on";
                        if ~obj.SpeedColors; vis = "off"; end
                        if ~isempty(obj.TrailH) && isvalid(obj.TrailH)
                            obj.TrailH.Visible = vis;
                        end
                        if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH)
                            obj.NodeGlowH.Visible = vis;
                        end
                        if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH)
                            obj.NodeCoreH.Visible = vis;
                        end
                    end
                    obj.updateHud();

                case {"uparrow", "downarrow"}
                    if obj.SubMode == "cyclotron"
                        if key == "uparrow"
                            obj.BUniform = min(0.30, obj.BUniform + 0.02);
                        else
                            obj.BUniform = max(0.02, obj.BUniform - 0.02);
                        end
                        obj.resetState();
                        obj.updateHud();
                    else
                        obj.changeParticleLevel(key);
                    end

                case {"leftarrow", "rightarrow"}
                    if obj.SubMode == "cyclotron"
                        stepVal = 0.05;
                        if key == "rightarrow"
                            obj.CycEAmp = min(1.0, obj.CycEAmp + stepVal);
                        else
                            obj.CycEAmp = max(0.05, obj.CycEAmp - stepVal);
                        end
                        obj.updateHud();
                    else
                        handled = false;
                    end

                otherwise
                    % Direct sub-mode selection via 1-5 and 0 for reset
                    if strlength(key) == 1 && key >= "0" && key <= "5"
                        d = double(key) - 48;
                        if d == 0
                            obj.resetState();
                        else
                            modes = ["monopole", "dipole", "quadrupole", "random", "cyclotron"];
                            obj.SubMode = modes(d);
                            obj.applySubMode();
                        end
                    else
                        handled = false;
                    end
            end
        end

        function r = getResults(obj)
            %getResults  Return EM-field-specific results.
            r.Title = "EM FIELD";
            elapsed = toc(obj.StartTic);
            if obj.SubMode == "cyclotron"
                r.Lines = {sprintf( ...
                    "Cyclotron B=%.2f  |  Extracted: %d  |  Charge: %s  |  Time: %.0fs", ...
                    obj.BUniform, obj.CycExtractions, obj.FingerMode, elapsed)};
            else
                r.Lines = {sprintf( ...
                    "E-Field: %s  |  Grid: %dx%d  |  Charge: %s  |  Time: %.0fs", ...
                    obj.SubMode, obj.GridNx, obj.GridNy, obj.FingerMode, elapsed)};
            end
        end

    end

    % =================================================================
    % PHYSICS HELPERS
    % =================================================================
    methods (Access = private)
        function [fieldEx, fieldEy] = computeEField(obj, qx, qy, fingerPos)
            %computeEField  Coulomb E from charge superposition.
            %   E = sum_k  q_k (r - r_k) / |r - r_k|^3  with softening.
            fieldEx = zeros(size(qx));
            fieldEy = zeros(size(qx));
            eps2 = obj.Softening^2;

            % Fixed charges
            for k = 1:numel(obj.ChargeQ)
                dxC = qx - obj.ChargeX(k);
                dyC = qy - obj.ChargeY(k);
                r2 = dxC.^2 + dyC.^2 + eps2;
                invR3 = obj.ChargeQ(k) ./ (r2 .^ 1.5);
                fieldEx = fieldEx + dxC .* invR3;
                fieldEy = fieldEy + dyC .* invR3;
            end

            % Finger charge
            if nargin > 3 && ~any(isnan(fingerPos))
                dxC = qx - fingerPos(1);
                dyC = qy - fingerPos(2);
                r2 = dxC.^2 + dyC.^2 + eps2;
                fQ = obj.FingerQ;
                if obj.FingerMode == "attract"
                    fQ = -fQ;
                end
                invR3 = fQ ./ (r2 .^ 1.5);
                fieldEx = fieldEx + dxC .* invR3;
                fieldEy = fieldEy + dyC .* invR3;
            end
        end

        function configureCharges(obj)
            %configureCharges  Set fixed charge layout per sub-mode.
            dxR = obj.Dx;
            dyR = obj.Dy;
            cx = mean(dxR);
            cy = mean(dyR);
            ww = diff(dxR);
            hh = diff(dyR);

            switch obj.SubMode
                case "monopole"
                    obj.ChargeX = [];
                    obj.ChargeY = [];
                    obj.ChargeQ = [];

                case "dipole"
                    obj.ChargeX = cx;
                    obj.ChargeY = cy;
                    obj.ChargeQ = -1;

                case "quadrupole"
                    dd = 0.22 * min(ww, hh);
                    obj.ChargeX = [cx-dd; cx+dd; cx+dd; cx-dd];
                    obj.ChargeY = [cy-dd; cy-dd; cy+dd; cy+dd];
                    obj.ChargeQ = [1; -1; 1; -1];

                case "random"
                    nC = 6;
                    obj.ChargeX = dxR(1) + rand(nC,1)*ww*0.8 + ww*0.1;
                    obj.ChargeY = dyR(1) + rand(nC,1)*hh*0.8 + hh*0.1;
                    obj.ChargeQ = 2*(rand(nC,1) > 0.5) - 1;

                case "cyclotron"
                    obj.ChargeX = [];
                    obj.ChargeY = [];
                    obj.ChargeQ = [];
            end
        end

        function borisPush(obj, fingerPos)
            %borisPush  Boris pusher for cyclotron particles.
            %
            %   Boris algorithm (energy-conserving, 2nd order):
            %     v_minus  = v + (q/m)*E*dt/2       (half E-kick)
            %     v_prime  = v_minus + v_minus x t   (half B-rotation)
            %     v_plus   = v_minus + v_prime x s   (full B-rotation)
            %     v_new    = v_plus  + (q/m)*E*dt/2  (half E-kick)
            %     x_new    = x + v_new * dt
            %   where t = (q/m)*B*dt/2, s = 2t/(1+|t|^2).

            nPart = numel(obj.PosX);
            if nPart == 0
                obj.CycSimTime = obj.CycSimTime ...
                    + obj.CycNSub * obj.CycDtSub;
                obj.CycPhase = obj.BUniform * obj.CycSimTime ...
                    + pi / 2;
                return;
            end

            px = obj.PosX(:);
            py = obj.PosY(:);
            vx = obj.VelX(:);
            vy = obj.VelY(:);

            if numel(px) ~= numel(vx); return; end

            cx   = obj.CycCx;
            gapW = obj.CycGapW;
            Bz   = obj.BUniform;
            eAmp = obj.CycEAmp;
            R    = obj.CycRadius;
            eps2 = obj.Softening^2;

            nSub  = max(1, round(obj.CycNSub * obj.DtScale));
            nSub  = min(nSub, obj.CycNSub * 4);  % safety cap
            dtSub = obj.CycDtSub;
            simT  = obj.CycSimTime;

            hasFinger = ~any(isnan(fingerPos));
            if hasFinger
                fQ = obj.FingerQ * 25;
                if obj.FingerMode == "attract"
                    fQ = -fQ;
                end
                fx = fingerPos(1);
                fy = fingerPos(2);
            end

            % Boris rotation constants
            tB = Bz * dtSub * 0.5;
            sB = 2 * tB / (1 + tB^2);
            halfDt = dtSub * 0.5;

            for sub = 1:nSub
                simT = simT + dtSub;

                % E field per particle
                Epx = zeros(nPart, 1);
                Epy = zeros(nPart, 1);

                % Gap RF E-field
                inGap = abs(px - cx) < gapW;
                if any(inGap)
                    gapE = eAmp * cos(Bz * simT);
                    Epx(inGap) = gapE;
                end

                % Finger Coulomb E-field
                if hasFinger
                    dxC = px - fx;
                    dyC = py - fy;
                    r2  = dxC.^2 + dyC.^2 + eps2;
                    invR3 = fQ ./ (r2 .^ 1.5);
                    Epx = Epx + dxC .* invR3;
                    Epy = Epy + dyC .* invR3;
                end

                % Boris push (q/m = 1)
                vmx = vx + Epx * halfDt;
                vmy = vy + Epy * halfDt;

                vpx = vmx + vmy .* tB;
                vpy = vmy - vmx .* tB;
                vx  = vmx + vpy .* sB;
                vy  = vmy - vpx .* sB;

                vx = vx + Epx * halfDt;
                vy = vy + Epy * halfDt;

                px = px + vx * dtSub;
                py = py + vy * dtSub;
            end

            % Extraction: remove particles exiting the dees
            deeR = R * 0.88;
            dist2 = (px - cx).^2 + (py - obj.CycCy).^2;
            extracted = dist2 > deeR^2;
            if any(extracted)
                nExt = sum(extracted);
                extPx = px(extracted);
                extPy = py(extracted);
                extVx = vx(extracted);
                extVy = vy(extracted);
                extSpd = sqrt(extVx.^2 + extVy.^2);
                obj.CycExtractions = obj.CycExtractions + nExt;
                extPts = round(extSpd * 10);
                obj.addScore(sum(extPts));
                obj.Combo = obj.Combo + nExt;
                obj.MaxCombo = max(obj.MaxCombo, obj.Combo);

                % Extraction burst
                for ei2 = 1:nExt
                    spd2 = extSpd(ei2);
                    nrm = [extVx(ei2), extVy(ei2)] / max(spd2, 1e-6);
                    obj.spawnBounceEffect([extPx(ei2), extPy(ei2)], ...
                        nrm, extPts(ei2), spd2);
                end

                px(extracted)  = [];
                py(extracted)  = [];
                vx(extracted)  = [];
                vy(extracted)  = [];
                obj.Hue(extracted) = [];
                obj.TrailX(extracted, :) = [];
                obj.TrailY(extracted, :) = [];

                % Delete per-particle trail patch handles (backward loop)
                extIdx = find(extracted);
                for ei = numel(extIdx):-1:1
                    idx = extIdx(ei);
                    if ~isempty(obj.CycLineH) && idx <= numel(obj.CycLineH)
                        trailH = obj.CycLineH{idx};
                        if ~isempty(trailH) && isvalid(trailH); delete(trailH); end
                        obj.CycLineH(idx) = [];
                    end
                end

                nPart = numel(px); %#ok<NASGU>
            end

            % Speed cap
            spd = sqrt(vx.^2 + vy.^2);
            maxSpd = deeR * 0.15;
            tooFast = spd > maxSpd;
            if any(tooFast)
                scaleFactor = maxSpd ./ spd(tooFast);
                vx(tooFast) = vx(tooFast) .* scaleFactor;
                vy(tooFast) = vy(tooFast) .* scaleFactor;
            end

            obj.PosX = px;
            obj.PosY = py;
            obj.VelX = vx;
            obj.VelY = vy;
            obj.CycSimTime = simT;
            obj.CycPhase = Bz * simT + pi / 2;
        end

        function cycInject(obj)
            %cycInject  Inject a new particle near the cyclotron center.
            cx = obj.CycCx;
            cy = obj.CycCy;

            v0 = 0.5 + (rand() - 0.5) * 0.2;
            th = (rand() - 0.5) * 0.15;

            newX  = cx;
            newY  = cy + (rand() - 0.5) * obj.CycGapW;
            newVx = v0 * cos(th);
            newVy = v0 * sin(th);

            obj.PosX = [obj.PosX; newX];
            obj.PosY = [obj.PosY; newY];
            obj.VelX = [obj.VelX; newVx];
            obj.VelY = [obj.VelY; newVy];
            obj.CycTotalSpawned = obj.CycTotalSpawned + 1;
            obj.Hue = [obj.Hue; mod(obj.CycTotalSpawned * 0.618033988749895, 1)];

            % Extend trail arrays
            tLen = obj.TrailLen;
            obj.TrailX(end+1, :) = repmat(newX, 1, tLen);
            obj.TrailY(end+1, :) = repmat(newY, 1, tLen);

            % Create per-particle fading trail patch
            ax = obj.Ax;
            if ~isempty(ax) && isvalid(ax)
                trailPatch = patch(ax, "XData", NaN, "YData", NaN, ...
                    "CData", zeros(1, 1, 3), ...
                    "EdgeColor", "interp", "EdgeAlpha", "interp", ...
                    "FaceVertexAlphaData", 0, "AlphaDataMapping", "none", ...
                    "LineWidth", 2.0, "Tag", "GT_emfield");
                if isempty(obj.CycLineH)
                    obj.CycLineH = {trailPatch};
                else
                    obj.CycLineH{end+1} = trailPatch;
                end
            end
        end

        function initCyclotron(obj)
            %initCyclotron  Set up cyclotron geometry and spawn one particle.
            cx = mean(obj.Dx);
            cy = mean(obj.Dy);
            minDim = min(diff(obj.Dx), diff(obj.Dy));

            obj.CycCx       = cx;
            obj.CycCy       = cy;
            obj.CycRadius   = 0.42 * minDim;
            obj.CycGapW     = 0.012 * minDim;
            obj.CycEAmp     = 0.30;
            obj.CycSimTime  = 0;
            obj.CycSpawnTic = 0;
            obj.CycExtractions = 0;
            obj.CycTotalSpawned = 0;

            obj.CycNSub  = 8;
            obj.CycDtSub = 0.5;

            v0 = 0.5;
            obj.PosX = cx;
            obj.PosY = cy;
            obj.VelX = v0;
            obj.VelY = 0;
            obj.Hue  = 0;
            obj.CycPhase = pi / 2;

            tLen = obj.TrailLen;
            obj.TrailX = repmat(obj.PosX, 1, tLen);
            obj.TrailY = repmat(obj.PosY, 1, tLen);

            % Draw cyclotron structure
            obj.drawCyclotron();
        end
    end

    % =================================================================
    % RENDERING HELPERS
    % =================================================================
    methods (Access = private)
        function buildQuiver(obj)
            %buildQuiver  Create or rebuild quiver grid (full screen).
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dxR = obj.Dx;
            dyR = obj.Dy;
            baseCounts = [15, 20, 25, 30, 40, 50, 60];
            nx = baseCounts(min(obj.LevelIdx, numel(baseCounts)));
            aspectR = diff(dyR) / max(diff(dxR), 1);
            ny = max(round(nx * aspectR), 8);
            obj.GridNx = nx;
            obj.GridNy = ny;

            gx = linspace(dxR(1), dxR(2), nx);
            gy = linspace(dyR(1), dyR(2), ny);
            [obj.QGridX, obj.QGridY] = meshgrid(gx, gy);

            if ~isempty(obj.QuiverH) && isvalid(obj.QuiverH)
                delete(obj.QuiverH);
            end

            Uz = zeros(ny, nx);
            obj.QuiverH = quiver(ax, obj.QGridX, obj.QGridY, ...
                Uz, Uz, 0.6, "Color", [0.70, 0.88, 1.0], ...
                "LineWidth", 0.8, "MaxHeadSize", 0.35, ...
                "Tag", "GT_emfield", "AutoScale", "off");
        end

        function buildCyclotronQuiver(obj)
            %buildCyclotronQuiver  Quiver grid masked to cyclotron circle.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            cx = obj.CycCx;
            cy = obj.CycCy;
            R  = obj.CycRadius;

            baseCounts = [15, 20, 25, 30, 40, 50, 60];
            nx = baseCounts(min(obj.LevelIdx, numel(baseCounts)));
            ny = max(round(nx * 1), 8);  % cyclotron is circular

            deeR = R * 0.88;
            gx = linspace(cx - deeR, cx + deeR, nx);
            gy = linspace(cy - deeR, cy + deeR, ny);
            [GX, GY] = meshgrid(gx, gy);

            gapW = obj.CycGapW;
            dist2 = (GX - cx).^2 + (GY - cy).^2;
            insideCircle = dist2 < (deeR * 0.95)^2;
            outsideGap   = abs(GX - cx) > gapW * 1.5;
            inside = insideCircle & outsideGap;

            obj.QGridX = GX(inside);
            obj.QGridY = GY(inside);
            obj.GridNx = nx;
            obj.GridNy = ny;

            if ~isempty(obj.QuiverH) && isvalid(obj.QuiverH)
                delete(obj.QuiverH);
            end

            nPts = numel(obj.QGridX);
            Uz = zeros(nPts, 1);
            obj.QuiverH = quiver(ax, obj.QGridX, obj.QGridY, ...
                Uz, Uz, 0.6, "Color", [0.70, 0.88, 1.0], ...
                "LineWidth", 0.8, "MaxHeadSize", 0.35, ...
                "Tag", "GT_emfield", "AutoScale", "off");
        end

        function renderFieldImage(obj, fingerPos)
            %renderFieldImage  Render field magnitude as colored background.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            dxR = obj.Dx;
            dyR = obj.Dy;
            nX = 100;
            nY = max(round(nX * diff(dyR) / max(diff(dxR), 1)), 50);

            gx = linspace(dxR(1), dxR(2), nX);
            gy = linspace(dyR(1), dyR(2), nY);
            [GX, GY] = meshgrid(gx, gy);

            [Efx, Efy] = obj.computeEField(GX(:), GY(:), fingerPos);
            Emag = reshape(sqrt(Efx.^2 + Efy.^2), nY, nX);

            % Log-scale for visible contrast
            EmagLog = log1p(Emag * 5e4);
            maxLog = max(EmagLog(:));
            if maxLog < 1e-6; maxLog = 1; end
            Enorm = EmagLog / maxLog;

            % Colormap: black -> deep blue -> electric blue -> white
            fieldRGB = zeros(nY, nX, 3);
            fieldRGB(:,:,1) = 0.01 + 0.20*Enorm.^2 + 0.35*Enorm.^4;
            fieldRGB(:,:,2) = 0.01 + 0.08*Enorm + 0.25*Enorm.^3;
            fieldRGB(:,:,3) = 0.06 + 0.50*Enorm + 0.30*Enorm.^2;

            if ~isempty(obj.FieldImageH) && isvalid(obj.FieldImageH)
                obj.FieldImageH.CData = fieldRGB;
            else
                obj.FieldImageH = image(ax, "XData", dxR, "YData", dyR, ...
                    "CData", fieldRGB, "Tag", "GT_emfield");
                obj.FieldImageH.AlphaData = 0.45;
            end
        end

        function renderChargeMarkers(obj, fingerPos)
            %renderChargeMarkers  Glowing markers at charge positions.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            maxN = 8;
            allX = NaN(maxN, 1);
            allY = NaN(maxN, 1);
            allQ = zeros(maxN, 1);

            nFixed = numel(obj.ChargeX);
            if nFixed > 0
                allX(1:nFixed) = obj.ChargeX(:);
                allY(1:nFixed) = obj.ChargeY(:);
                allQ(1:nFixed) = obj.ChargeQ(:);
            end

            fi = nFixed + 1;
            if nargin > 1 && ~any(isnan(fingerPos))
                allX(fi) = fingerPos(1);
                allY(fi) = fingerPos(2);
                fQ = obj.FingerQ;
                if obj.FingerMode == "attract"
                    fQ = -fQ;
                end
                allQ(fi) = fQ;
            end

            colors = repmat([0.4, 0.4, 0.4], maxN, 1);
            for k = 1:maxN
                if allQ(k) > 0
                    colors(k, :) = [1.0, 0.3, 0.2];
                elseif allQ(k) < 0
                    colors(k, :) = [0.2, 0.5, 1.0];
                end
            end

            glowSz = 400 * ones(maxN, 1);
            coreSz = 80 * ones(maxN, 1);

            if ~isempty(obj.ChargeGlowH) && isvalid(obj.ChargeGlowH)
                set(obj.ChargeGlowH, "XData", allX, "YData", allY, ...
                    "SizeData", glowSz, "CData", colors);
                set(obj.ChargeCoreH, "XData", allX, "YData", allY, ...
                    "SizeData", coreSz, "CData", colors);
            else
                obj.ChargeGlowH = scatter(ax, allX, allY, glowSz, ...
                    colors, "filled", "MarkerFaceAlpha", 0.20, ...
                    "Tag", "GT_emfield");
                obj.ChargeCoreH = scatter(ax, allX, allY, coreSz, ...
                    colors, "filled", "MarkerFaceAlpha", 0.85, ...
                    "Tag", "GT_emfield");
            end
        end

        function drawCyclotron(obj)
            %drawCyclotron  Draw dees, gap indicator, boundary, and streamlines.
            ax = obj.Ax;
            if isempty(ax) || ~isvalid(ax); return; end

            cx   = obj.CycCx;
            cy   = obj.CycCy;
            R    = obj.CycRadius;
            gapW = obj.CycGapW;

            % Boundary circle
            thCircle = linspace(0, 2*pi, 128)';
            if isempty(obj.CycRingH) || ~isvalid(obj.CycRingH)
                obj.CycRingH = line(ax, cx + R * cos(thCircle), ...
                    cy + R * sin(thCircle), ...
                    "Color", [0.35, 0.55, 0.75, 0.7], "LineWidth", 3.5, ...
                    "Tag", "GT_emfield");
            else
                set(obj.CycRingH, "XData", cx + R * cos(thCircle), ...
                    "YData", cy + R * sin(thCircle));
            end

            % Dee geometry (inset from boundary)
            deeR    = R * 0.88;
            yHalf   = sqrt(max(deeR^2 - gapW^2, 0));
            nArcPts = 80;

            % Left dee
            thTopL = atan2(yHalf, -gapW);
            thBotL = atan2(-yHalf, -gapW);
            thArcL = linspace(thTopL, thBotL + 2*pi, nArcPts)';
            deeXL  = [cx - gapW; cx + deeR * cos(thArcL); cx - gapW];
            deeYL  = [cy + yHalf; cy + deeR * sin(thArcL); cy - yHalf];

            % Right dee
            thTopR = atan2(yHalf, gapW);
            thBotR = atan2(-yHalf, gapW);
            thArcR = linspace(thBotR, thTopR, nArcPts)';
            deeXR  = [cx + gapW; cx + deeR * cos(thArcR); cx + gapW];
            deeYR  = [cy - yHalf; cy + deeR * sin(thArcR); cy + yHalf];

            % Draw/update dee patches
            deeColor = [0.08, 0.10, 0.20];
            deeEdge  = [0.40, 0.60, 0.85];
            if isempty(obj.DeeH) || ~all(isvalid(obj.DeeH))
                if ~isempty(obj.DeeH)
                    for k = 1:numel(obj.DeeH)
                        if isvalid(obj.DeeH(k)); delete(obj.DeeH(k)); end
                    end
                end
                hL = patch(ax, deeXL, deeYL, deeColor, ...
                    "FaceAlpha", 0.45, "EdgeColor", deeEdge, ...
                    "LineWidth", 3.0, "Tag", "GT_emfield");
                hR = patch(ax, deeXR, deeYR, deeColor, ...
                    "FaceAlpha", 0.45, "EdgeColor", deeEdge, ...
                    "LineWidth", 3.0, "Tag", "GT_emfield");
                obj.DeeH = [hL, hR];
            else
                set(obj.DeeH(1), "XData", deeXL, "YData", deeYL);
                set(obj.DeeH(2), "XData", deeXR, "YData", deeYR);
            end

            % Gap indicator
            gapPatchX = [cx - gapW; cx + gapW; cx + gapW; cx - gapW];
            gapPatchY = [cy - yHalf; cy - yHalf; cy + yHalf; cy + yHalf];
            if isempty(obj.CycGapH) || ~isvalid(obj.CycGapH)
                obj.CycGapH = patch(ax, gapPatchX, gapPatchY, ...
                    [0.3, 0.5, 0.9], "FaceAlpha", 0.20, ...
                    "EdgeColor", "none", "Tag", "GT_emfield");
            else
                set(obj.CycGapH, "XData", gapPatchX, "YData", gapPatchY);
            end

            % Dee streamlines on top of dee patches
            if ~isempty(obj.CycStreamH)
                for k = 1:numel(obj.CycStreamH)
                    if isvalid(obj.CycStreamH(k))
                        delete(obj.CycStreamH(k));
                    end
                end
                obj.CycStreamH = [];
            end

            nStreams = 6;
            streamRadii = linspace(0.15, 0.85, nStreams) * deeR;
            streamCol = [0.5, 0.7, 1.0, 0.25];
            nArcStream = 60;
            hStream = gobjects(nStreams * 2, 1);
            si = 0;

            for s = 1:nStreams
                sR = streamRadii(s);
                if sR <= gapW; continue; end

                yH = sqrt(max(sR^2 - gapW^2, 0));

                % Left dee arc
                tL1 = atan2(yH, -gapW);
                tL2 = atan2(-yH, -gapW);
                thL = linspace(tL1, tL2 + 2*pi, nArcStream)';
                si = si + 1;
                hStream(si) = line(ax, cx + sR * cos(thL), ...
                    cy + sR * sin(thL), ...
                    "Color", streamCol, "LineWidth", 0.5, ...
                    "LineStyle", "-", "Tag", "GT_emfield");

                % Right dee arc
                tR1 = atan2(-yH, gapW);
                tR2 = atan2(yH, gapW);
                thR = linspace(tR1, tR2, nArcStream)';
                si = si + 1;
                hStream(si) = line(ax, cx + sR * cos(thR), ...
                    cy + sR * sin(thR), ...
                    "Color", streamCol, "LineWidth", 0.5, ...
                    "LineStyle", "-", "Tag", "GT_emfield");
            end
            obj.CycStreamH = hStream(1:si);
        end

        function updateGapIndicator(obj)
            %updateGapIndicator  Pulse gap color with RF E direction.
            if isempty(obj.CycGapH) || ~isvalid(obj.CycGapH); return; end

            sinPhase = sin(obj.CycPhase);
            absVal   = abs(sinPhase);

            if sinPhase > 0.01
                obj.CycGapH.FaceColor = [0.15, 0.50, 1.0];
            elseif sinPhase < -0.01
                obj.CycGapH.FaceColor = [1.0, 0.35, 0.15];
            else
                obj.CycGapH.FaceColor = [0.3, 0.3, 0.4];
            end

            obj.CycGapH.FaceAlpha = 0.08 + 0.35 * absVal;
        end
    end

    % =================================================================
    % STATE MANAGEMENT HELPERS
    % =================================================================
    methods (Access = private)
        function applySubMode(obj)
            %applySubMode  Transition between sub-modes.
            obj.Transitioning = true;

            ax = obj.Ax;
            isCyc = obj.SubMode == "cyclotron";

            % Hide ALL existing graphics immediately
            if ~isempty(ax) && isvalid(ax)
                allTagged = findall(ax, "Tag", "GT_emfield");
                for ci = 1:numel(allTagged)
                    if isprop(allTagged(ci), "Visible")
                        allTagged(ci).Visible = "off";
                    end
                end
            end

            % Field image: restore visibility early to avoid blank flashes
            if ~isCyc && ~isempty(obj.FieldImageH) ...
                    && isvalid(obj.FieldImageH)
                obj.FieldImageH.Visible = "on";
            end

            % Clean up mode-specific graphics
            obj.cleanupCyclotronGraphics();
            if ~isempty(obj.CycLineH)
                for k = 1:numel(obj.CycLineH)
                    trailH = obj.CycLineH{k};
                    if ~isempty(trailH) && isvalid(trailH); delete(trailH); end
                end
                obj.CycLineH = {};
            end
            obj.CycGlowLineH = {};
            if ~isempty(obj.QuiverH) && isvalid(obj.QuiverH)
                delete(obj.QuiverH);
                obj.QuiverH = [];
            end
            obj.QGridX = [];
            obj.QGridY = [];

            % Configure charges for new sub-mode
            obj.configureCharges();

            % Trail length
            if isCyc
                obj.TrailLen = 15;
            else
                obj.TrailLen = 20;
            end

            % Initialize particles for new sub-mode
            if isCyc
                obj.initCyclotron();
            else
                dxR = obj.Dx;
                dyR = obj.Dy;
                nPart = obj.NodeCount;
                obj.PosX = dxR(1) + rand(nPart, 1) * diff(dxR);
                obj.PosY = dyR(1) + rand(nPart, 1) * diff(dyR);
                obj.Hue  = rand(nPart, 1);
                obj.VelX = [];
                obj.VelY = [];
            end

            % Field image: update CData for new charges
            if ~isCyc
                obj.renderFieldImage([NaN NaN]);
            end

            % Rebuild quiver for new mode
            if isCyc
                obj.buildCyclotronQuiver();
            else
                obj.buildQuiver();
            end

            % Reset trail history
            nPart = numel(obj.PosX);
            tLen = obj.TrailLen;
            obj.TrailX = repmat(obj.PosX, 1, tLen);
            obj.TrailY = repmat(obj.PosY, 1, tLen);

            % Update shared trail patch
            nVerts = nPart * (tLen + 1);
            trailVis = "on";
            if isCyc || ~obj.SpeedColors; trailVis = "off"; end
            if ~isempty(obj.TrailH) && isvalid(obj.TrailH)
                initV = zeros(nVerts, 2);
                initF = reshape(1:nVerts, tLen + 1, nPart)';
                set(obj.TrailH, "Vertices", initV, "Faces", initF, ...
                    "FaceVertexCData", zeros(nVerts, 3), ...
                    "FaceVertexAlphaData", zeros(nVerts, 1), ...
                    "Visible", trailVis);
            end

            % Update scatter data
            if isCyc
                coreSize = 30;  glowSize = 120;
                coreAlpha = 0.95;  glowAlpha = 0.30;
            else
                coreSize = 14;  glowSize = 50;
                coreAlpha = 0.85;  glowAlpha = 0.15;
            end
            nodeCol = zeros(nPart, 3);
            if nPart > 0 && numel(obj.Hue) == nPart
                nodeCol = hsv2rgb([obj.Hue(:), ...
                    ones(nPart, 1) * 0.9, ones(nPart, 1) * 0.95]);
            end
            % Recreate scatter objects (particle count changes between modes)
            if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH)
                delete(obj.NodeGlowH);
            end
            if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH)
                delete(obj.NodeCoreH);
            end
            szG = glowSize * ones(max(nPart, 1), 1);
            szC = coreSize * ones(max(nPart, 1), 1);
            pX = obj.PosX; pY = obj.PosY;
            if nPart == 0; pX = NaN; pY = NaN; szG = 1; szC = 1; nodeCol = [0 0 0]; end
            obj.NodeGlowH = scatter(ax, pX, pY, szG, nodeCol, "filled", ...
                "MarkerFaceAlpha", glowAlpha, "Tag", "GT_emfield");
            obj.NodeCoreH = scatter(ax, pX, pY, szC, nodeCol, "filled", ...
                "MarkerFaceAlpha", coreAlpha, "Tag", "GT_emfield");

            % Per-particle trail patches for cyclotron
            if isCyc && ~isempty(ax) && isvalid(ax)
                obj.CycLineH = cell(nPart, 1);
                for k = 1:nPart
                    obj.CycLineH{k} = patch(ax, "XData", NaN, ...
                        "YData", NaN, "CData", zeros(1, 1, 3), ...
                        "EdgeColor", "interp", "EdgeAlpha", "interp", ...
                        "FaceVertexAlphaData", 0, ...
                        "AlphaDataMapping", "none", ...
                        "LineWidth", 2.0, "Tag", "GT_emfield");
                end
            end

            % Update charge markers + HUD
            obj.renderChargeMarkers();
            obj.FrameCount = 0;
            obj.CycSimTime = 0;
            obj.StartTic = tic;
            obj.updateHud();

            % Z-order: particles on top of dees/streamlines
            if isCyc
                if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH)
                    uistack(obj.NodeGlowH, "top");
                end
                if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH)
                    uistack(obj.NodeCoreH, "top");
                end
            end

            % Reveal all at once
            if ~isempty(ax) && isvalid(ax)
                allTagged = findall(ax, "Tag", "GT_emfield");
                for ci = 1:numel(allTagged)
                    if isprop(allTagged(ci), "Visible")
                        allTagged(ci).Visible = "on";
                    end
                end
            end
            % Restore correct visibility for conditionally hidden objects
            if isCyc || ~obj.SpeedColors
                if ~isempty(obj.TrailH) && isvalid(obj.TrailH)
                    obj.TrailH.Visible = "off";
                end
            end
            if ~isCyc && ~obj.SpeedColors
                if ~isempty(obj.NodeGlowH) && isvalid(obj.NodeGlowH)
                    obj.NodeGlowH.Visible = "off";
                end
                if ~isempty(obj.NodeCoreH) && isvalid(obj.NodeCoreH)
                    obj.NodeCoreH.Visible = "off";
                end
            end
            if isCyc
                if ~isempty(obj.FieldImageH) && isvalid(obj.FieldImageH)
                    obj.FieldImageH.Visible = "off";
                end
            end

            obj.Transitioning = false;
        end

        function cleanupCyclotronGraphics(obj)
            %cleanupCyclotronGraphics  Remove dee/ring/gap/trail handles.
            if ~isempty(obj.DeeH)
                for k = 1:numel(obj.DeeH)
                    if isvalid(obj.DeeH(k)); delete(obj.DeeH(k)); end
                end
                obj.DeeH = [];
            end
            if ~isempty(obj.CycRingH) && isvalid(obj.CycRingH)
                delete(obj.CycRingH);
                obj.CycRingH = [];
            end
            if ~isempty(obj.CycGapH) && isvalid(obj.CycGapH)
                delete(obj.CycGapH);
                obj.CycGapH = [];
            end
            obj.cycCleanupTrailLines();
            if ~isempty(obj.CycStreamH)
                for k = 1:numel(obj.CycStreamH)
                    if isvalid(obj.CycStreamH(k))
                        delete(obj.CycStreamH(k));
                    end
                end
                obj.CycStreamH = [];
            end
        end

        function cycCleanupTrailLines(obj)
            %cycCleanupTrailLines  Delete per-particle trail patch handles.
            if ~isempty(obj.CycLineH)
                for k = 1:numel(obj.CycLineH)
                    trailH = obj.CycLineH{k};
                    if ~isempty(trailH) && isvalid(trailH); delete(trailH); end
                end
                obj.CycLineH = {};
            end
            obj.CycGlowLineH = {};
        end

        function changeParticleLevel(obj, key)
            %changeParticleLevel  Change quiver grid density (Up/Down).
            baseCounts = [15, 20, 25, 30, 40, 50, 60];
            oldIdx = obj.LevelIdx;
            if key == "uparrow"
                obj.LevelIdx = min(numel(baseCounts), oldIdx + 1);
            else
                obj.LevelIdx = max(1, oldIdx - 1);
            end
            if obj.LevelIdx == oldIdx; return; end
            obj.buildQuiver();
            obj.updateHud();
        end

        function resetState(obj)
            %resetState  Reset particles and charges (0 key).
            obj.configureCharges();
            nPart = obj.NodeCount;
            isCyc = obj.SubMode == "cyclotron";
            if isCyc
                obj.TrailLen = 15;
                obj.cycCleanupTrailLines();
                obj.initCyclotron();
                ax = obj.Ax;
                if ~isempty(ax) && isvalid(ax)
                    nNew = numel(obj.PosX);
                    obj.CycLineH = cell(nNew, 1);
                    obj.CycGlowLineH = {};
                    for k = 1:nNew
                        obj.CycLineH{k} = patch(ax, "XData", NaN, ...
                            "YData", NaN, "CData", zeros(1, 1, 3), ...
                            "EdgeColor", "interp", "EdgeAlpha", "interp", ...
                            "FaceVertexAlphaData", 0, "AlphaDataMapping", "none", ...
                            "LineWidth", 2.0, "Tag", "GT_emfield");
                    end
                end
            else
                obj.PosX = obj.Dx(1) + rand(nPart,1) * diff(obj.Dx);
                obj.PosY = obj.Dy(1) + rand(nPart,1) * diff(obj.Dy);
                obj.Hue = rand(nPart, 1);
                obj.VelX = [];
                obj.VelY = [];
            end
            obj.TrailX = repmat(obj.PosX, 1, obj.TrailLen);
            obj.TrailY = repmat(obj.PosY, 1, obj.TrailLen);
            if ~isCyc
                obj.renderFieldImage([NaN NaN]);
            end
            obj.renderChargeMarkers();
            obj.Score = 0;
            obj.Combo = 0;
            obj.MaxCombo = 0;
            obj.FrameCount = 0;
            obj.StartTic = tic;
        end

        function updateHud(obj)
            %updateHud  Update HUD text with mode info and controls.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

        function hudStr = buildHudString(obj)
            %buildHudString  Compose HUD string for current state.
            isCyc = obj.SubMode == "cyclotron";
            arrows = char(8593) + string(char(8595));
            chSign = "+";
            if obj.FingerMode == "attract"; chSign = char(8722); end

            if isCyc
                nPart = numel(obj.PosX);
                lrArrows = char(8592) + string(char(8594));
                hudStr = "CYCLOTRON  B" + char(8857) + "=" ...
                    + sprintf("%.2f", obj.BUniform) ...
                    + " [" + arrows + "]  E=" ...
                    + sprintf("%.2f", obj.CycEAmp) ...
                    + " [" + lrArrows + "]  |  Charge " + chSign ...
                    + " [N]  |  " + nPart + "/25" ...
                    + "  |  " + obj.CycExtractions + " extracted" ...
                    + "  |  0=Reset";
            else
                partStr = "ON";
                if ~obj.SpeedColors; partStr = "OFF"; end
                hudStr = upper(obj.SubMode) ...
                    + " [1-5/M]  |  Charge " + chSign + " [N]  |  " ...
                    + "Particles " + partStr + " [B]  |  " ...
                    + obj.GridNx + "x" + obj.GridNy ...
                    + " [" + arrows + "]  |  0=Reset";
            end
        end
    end
end
