classdef StringHarmonics < GameBase
    %StringHarmonics  1D wave equation string with standing waves and spectrum.
    %   Single vibrating string with two sub-modes:
    %     harmonics    — cross the string to inject pure mode (finger X picks
    %                    harmonic 1-9, or use number keys)
    %     superposition — cross to pluck with Gaussian pulse (amplitude
    %                    proportional to crossing speed), hold near string to
    %                    mute locally, 1-9 toggle harmonics on/off
    %   Standing wave envelope, 9-bar DST spectrum, node markers, color
    %   burst at pluck/injection point.
    %
    %   Standalone: games.StringHarmonics().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "String Harmonics"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        % Physics
        U               double                       % Nx1 displacement
        UPrev           double                       % Nx1 previous displacement
        NumPoints       (1,1) double = 300           % points per string
        WaveSpeed       (1,1) double = 0.8           % wave speed
        Damping         (1,1) double = 0.9998        % damping factor
        SubSteps        (1,1) double = 8             % wave equation sub-steps per frame
        SubMode         (1,1) string = "superposition"
        XPos            (:,1) double                 % normalized [0,1] x positions

        % Interaction
        PrevFingerY     (1,1) double = 0             % previous finger Y for crossing detection
        ActiveHarm      (1,:) logical = false(1, 9)  % toggled harmonics (superposition mode)
        HarmonicN       (1,1) double = 1             % current harmonic (harmonics mode)

        % Frame counter
        FrameCount      (1,1) double = 0
        PeakAmp         (1,1) double = 0

        % Display
        StringY         (1,1) double = 0             % Y center of the string (display)
        StringHue       (1,1) double = 0.55          % hue [0,1]

        % Metadata
        PluckCount      (1,1) double = 0
        PluckVels       (:,1) double
        PluckPosX       (:,1) double
        MuteCount       (1,1) double = 0
        EnvelopeMax     (:,1) double                 % peak displacement envelope
        LastPluckFrame  (1,1) double = 0

        % Pluck flash
        PluckFlashIdx   (1,1) double = 0
        PluckFlashAmp   (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        LineH                    % patch handle (main line)
        GlowH                   % patch handle (glow)
        EnvelopeH               % patch handle (envelope max/min)
        SpectrumH       = {}    % cell of patch handles (spectrum bars)
        NodeH                   % scatter handle for nodes
        ImageH                  % background image
        ModeTextH               % HUD text
        SpecBgH                 % spectrum background patch
        SpecLabelH      = {}    % spectrum bar labels
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create string instrument with spectrum display.
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

            dx = displayRange.X;
            dy = displayRange.Y;
            N = obj.NumPoints;

            % Apply sub-mode configuration
            obj.applySubMode();

            % Initialize physics state
            obj.XPos = linspace(0, 1, N)';
            obj.U = zeros(N, 1);
            obj.UPrev = zeros(N, 1);
            obj.PrevFingerY = 0;
            obj.FrameCount = 0;
            obj.PeakAmp = 0;

            % String at vertical center of usable area (above spectrum)
            usableTop = dy(1) + diff(dy) * 0.08;
            usableBot = dy(2) - diff(dy) * 0.22;
            obj.StringY = mean([usableTop, usableBot]);
            obj.StringHue = 0.55;

            % If superposition mode, inject active harmonics
            if obj.SubMode == "superposition"
                obj.injectActiveHarmonics();
            end

            % Dark background image
            obj.ImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", uint8(repmat(reshape([8, 5, 18], 1, 1, 3), 2, 2)), ...
                "AlphaData", ones(2, 2) * 0.92, ...
                "AlphaDataMapping", "none", "Tag", "GT_stringharmonics");
            uistack(obj.ImageH, "bottom");
            uistack(obj.ImageH, "up");

            % Display coordinates
            dispX = dx(1) + obj.XPos * diff(dx);
            sy = obj.StringY;
            dispY = repmat(sy, N, 1);
            [rC, gC, bC] = GameBase.hsvToRgb(obj.StringHue);
            baseColor = [rC, gC, bC];
            dimColor = baseColor * 0.3 + [0.1, 0.1, 0.15];

            % Glow line (wide, dim)
            obj.GlowH = patch(ax, "XData", [dispX; NaN], ...
                "YData", [dispY; NaN], ...
                "EdgeColor", "interp", "EdgeAlpha", 0.08, ...
                "FaceColor", "none", "LineWidth", 10, ...
                "FaceVertexCData", repmat(dimColor, N + 1, 1), ...
                "Tag", "GT_stringharmonics");

            % Main string line
            obj.LineH = patch(ax, "XData", [dispX; NaN], ...
                "YData", [dispY; NaN], ...
                "EdgeColor", "interp", "EdgeAlpha", 1, ...
                "FaceColor", "none", "LineWidth", 2.5, ...
                "FaceVertexCData", repmat(dimColor, N + 1, 1), ...
                "Tag", "GT_stringharmonics");

            % Node markers (zero-crossings)
            obj.NodeH = scatter(ax, NaN, NaN, 50, "w", ...
                "filled", "MarkerFaceAlpha", 0.6, ...
                "Tag", "GT_stringharmonics");

            % Standing wave envelope
            obj.EnvelopeMax = zeros(N, 1);
            obj.EnvelopeH = patch(ax, ...
                "XData", [dispX; flipud(dispX); dispX(1)], ...
                "YData", [repmat(sy, N, 1); repmat(sy, N, 1); sy], ...
                "FaceColor", baseColor * 0.4 + [0.1, 0.1, 0.15], ...
                "FaceAlpha", 0.08, "EdgeColor", "none", ...
                "Tag", "GT_stringharmonics");
            uistack(obj.EnvelopeH, "bottom");
            uistack(obj.EnvelopeH, "up", 2);

            % Fixed endpoint markers
            scatter(ax, [dx(1), dx(2)], [sy, sy], 60, [0.5, 0.6, 0.8], ...
                "filled", "MarkerFaceAlpha", 0.7, ...
                "Tag", "GT_stringharmonics");

            % Initialize metadata
            obj.PluckFlashIdx = 0;
            obj.PluckFlashAmp = 0;
            obj.PluckCount = 0;
            obj.PluckVels = [];
            obj.PluckPosX = [];
            obj.MuteCount = 0;
            obj.LastPluckFrame = 0;

            % --- Spectrum display (bottom 18% of screen) ---
            specBot = dy(2) - diff(dy) * 0.18;
            specTop = dy(2) - diff(dy) * 0.02;

            obj.SpecBgH = patch(ax, ...
                [dx(1), dx(2), dx(2), dx(1)], ...
                [specBot, specBot, specTop, specTop], ...
                [0, 0, 0], "FaceAlpha", 0.5, "EdgeColor", "none", ...
                "Tag", "GT_stringharmonics");

            nBars = 9;
            barGap = diff(dx) * 0.005;
            totalGap = (nBars - 1) * barGap;
            barW = (diff(dx) - totalGap) / nBars;
            hues = linspace(0, 0.85, nBars);
            obj.SpectrumH = cell(1, nBars);
            obj.SpecLabelH = cell(1, nBars);
            for k = 1:nBars
                bx = dx(1) + (k - 1) * (barW + barGap);
                [rB, gB, bB] = GameBase.hsvToRgb(hues(k));
                barColor = [rB, gB, bB];
                obj.SpectrumH{k} = patch(ax, ...
                    [bx, bx + barW, bx + barW, bx], ...
                    [specBot, specBot, specBot, specBot], ...
                    barColor, "FaceAlpha", 0.8, ...
                    "EdgeColor", min(1, barColor * 1.5 + 0.1), ...
                    "LineWidth", 1.0, "Tag", "GT_stringharmonics");
                obj.SpecLabelH{k} = text(ax, bx + barW / 2, specBot + 2, ...
                    string(k), "Color", [0.5, 0.5, 0.6], "FontSize", 7, ...
                    "HorizontalAlignment", "center", ...
                    "VerticalAlignment", "top", ...
                    "Tag", "GT_stringharmonics");
            end

            % HUD text (top-left)
            obj.ModeTextH = text(ax, dx(1) + 5, dy(1) + 5, "", ...
                "Color", [0.7, 0.8, 1.0, 0.7], "FontSize", 9, ...
                "FontWeight", "bold", ...
                "VerticalAlignment", "top", "Tag", "GT_stringharmonics");
            obj.updateHud();
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame standing wave simulation.
            if isempty(obj.U); return; end

            N = obj.NumPoints;
            dx = obj.DisplayRange.X;
            dy = obj.DisplayRange.Y;
            uVec = obj.U;
            uPrevVec = obj.UPrev;
            strX = obj.XPos;
            sy = obj.StringY;
            ampScale = diff(dy) * 0.12;

            % --- Finger interaction ---
            if ~any(isnan(pos))
                fx = (pos(1) - dx(1)) / diff(dx);
                fx = max(0.02, min(0.98, fx));
                fy = pos(2);
                pluckIdx = max(2, min(N - 1, round(fx * (N - 1)) + 1));

                if obj.SubMode == "harmonics"
                    if obj.PrevFingerY ~= 0
                        stringAtFinger = sy + uVec(pluckIdx) * ampScale;
                        prevRel = obj.PrevFingerY - stringAtFinger;
                        currRel = fy - stringAtFinger;

                        pluckCooldown = 5;
                        if prevRel * currRel < 0 && ...
                                (obj.FrameCount - obj.LastPluckFrame) >= pluckCooldown
                            obj.LastPluckFrame = obj.FrameCount;
                            harmonicN = max(1, min(9, floor(fx * 9) + 1));
                            obj.HarmonicN = harmonicN;

                            strumDir = sign(fy - obj.PrevFingerY);
                            omegaDt = obj.WaveSpeed * harmonicN * pi / (obj.NumPoints - 1);
                            obj.U = zeros(N, 1);
                            obj.UPrev = -strumDir * 1.2 * omegaDt * ...
                                sin(harmonicN * pi * obj.XPos);
                            uVec = obj.U;
                            uPrevVec = obj.UPrev;
                            obj.EnvelopeMax = abs(obj.U);

                            obj.PluckFlashIdx = pluckIdx;
                            obj.PluckFlashAmp = 1.0;

                            obj.PluckCount = obj.PluckCount + 1;
                            obj.PluckPosX(end + 1) = fx;
                            obj.updateHud();
                        end
                    end
                    obj.PrevFingerY = fy;

                elseif obj.SubMode == "superposition"
                    if obj.PrevFingerY ~= 0
                        stringAtFinger = sy + uVec(pluckIdx) * ampScale;
                        prevRel = obj.PrevFingerY - stringAtFinger;
                        currRel = fy - stringAtFinger;

                        pluckCooldown = 5;
                        if prevRel * currRel < 0 && ...
                                (obj.FrameCount - obj.LastPluckFrame) >= pluckCooldown
                            obj.LastPluckFrame = obj.FrameCount;
                            crossSpeed = abs(fy - obj.PrevFingerY) / ampScale;

                            pluckAmp = min(2.0, 1.2 * sqrt(crossSpeed));
                            pluckAmp = max(0.3, pluckAmp);

                            sigma = N * 0.06;
                            gaussProfile = exp(-((1:N)' - pluckIdx).^2 / (2 * sigma^2));
                            gaussProfile(1) = 0;
                            gaussProfile(N) = 0;

                            pluckDir = sign(fy - obj.PrevFingerY);
                            displ = pluckDir * pluckAmp * gaussProfile;
                            uVec = uVec + displ;
                            uPrevVec = uPrevVec + displ;

                            obj.PluckCount = obj.PluckCount + 1;
                            obj.PluckVels(end + 1) = crossSpeed;
                            obj.PluckPosX(end + 1) = fx;

                            obj.PluckFlashIdx = pluckIdx;
                            obj.PluckFlashAmp = 1.0;

                            obj.updateHud();
                        else
                            % Muting: finger near string damps locally
                            distToString = abs(fy - stringAtFinger);
                            muteThresh = diff(dy) * 0.025;
                            if distToString < muteThresh
                                sigma = N * 0.04;
                                muteProfile = exp(-((1:N)' - pluckIdx).^2 / (2 * sigma^2));
                                muteFactor = 1 - 0.15 * muteProfile;
                                uVec = uVec .* muteFactor;
                                uPrevVec = uPrevVec .* muteFactor;
                                obj.MuteCount = obj.MuteCount + 1;
                            end
                        end
                    end
                    obj.PrevFingerY = fy;
                end
            else
                obj.PrevFingerY = 0;
            end

            % Decay pluck flash intensity (frame-rate scaled)
            ds = obj.DtScale;
            if obj.PluckFlashAmp > 0.01
                obj.PluckFlashAmp = obj.PluckFlashAmp * 0.85^ds;
            else
                obj.PluckFlashAmp = 0;
            end

            % --- Physics: finite difference wave equation (sub-stepped) ---
            r2 = obj.WaveSpeed^2;
            dampVal = obj.Damping;
            nSubScaled = max(1, round(obj.SubSteps * ds));
            nSubScaled = min(nSubScaled, obj.SubSteps * 4);  % safety cap

            for ss = 1:nSubScaled
                uNew = zeros(N, 1);
                uNew(2:N-1) = 2 * uVec(2:N-1) - uPrevVec(2:N-1) + ...
                    r2 * (uVec(3:N) - 2 * uVec(2:N-1) + uVec(1:N-2));
                uNew(2:N-1) = uVec(2:N-1) + dampVal * (uNew(2:N-1) - uVec(2:N-1));
                uPrevVec = uVec;
                uVec = uNew;
            end

            obj.U = uVec;
            obj.UPrev = uPrevVec;
            obj.FrameCount = obj.FrameCount + 1;

            % Track peak amplitude
            maxAmp = max(abs(uVec));
            if maxAmp > obj.PeakAmp
                obj.PeakAmp = maxAmp;
            end

            % Update standing wave envelope
            absU = abs(uVec);
            if ~isempty(obj.EnvelopeMax)
                if obj.SubMode == "harmonics"
                    obj.EnvelopeMax = max(obj.EnvelopeMax, absU);
                else
                    obj.EnvelopeMax = max(obj.EnvelopeMax * 0.995^ds, absU);
                end
            end

            % --- Rendering ---
            dispX = dx(1) + strX * diff(dx);
            dispY = sy + uVec * ampScale;

            normU = min(1, absU / max(max(absU), 0.01));

            [rBase, gBase, bBase] = GameBase.hsvToRgb(obj.StringHue);
            baseColor = [rBase, gBase, bBase];
            dimColor = baseColor * 0.2 + [0.06, 0.06, 0.1];
            brightColor = min(1, baseColor * 1.5 + 0.15);
            whiteColor = [1, 1, 1];

            colors = zeros(N, 3);
            tVal = normU;
            loMask = tVal < 0.3;
            hiMask = ~loMask;
            sLo = tVal / 0.3;
            sHi = min(1, (tVal - 0.3) / 0.7);
            colors(loMask, :) = (1 - sLo(loMask)) .* dimColor + sLo(loMask) .* brightColor;
            colors(hiMask, :) = (1 - sHi(hiMask)) .* brightColor + sHi(hiMask) .* whiteColor;

            totalEnergy = mean(absU);
            glowAlpha = min(0.7, 0.02 + totalEnergy * 10);
            glowColors = (1 - normU * 0.4) .* brightColor + (normU * 0.4) .* whiteColor;

            % Apply pluck color burst
            if obj.PluckFlashAmp > 0 && obj.PluckFlashIdx > 0
                flashSigma = N * 0.06;
                flashProfile = obj.PluckFlashAmp * ...
                    exp(-((1:N)' - obj.PluckFlashIdx).^2 / (2 * flashSigma^2));
                warmWhite = [1.0, 0.95, 0.7];
                colors = colors .* (1 - flashProfile) + flashProfile .* warmWhite;
                colors = min(1, colors);
                glowColors = glowColors .* (1 - flashProfile * 0.5) + ...
                    flashProfile * 0.5 .* warmWhite;
                glowColors = min(1, glowColors);
                glowAlpha = max(glowAlpha, obj.PluckFlashAmp * 0.5);
            end

            % Update glow
            if ~isempty(obj.GlowH) && isvalid(obj.GlowH)
                obj.GlowH.XData = [dispX; NaN];
                obj.GlowH.YData = [dispY; NaN];
                obj.GlowH.FaceVertexCData = [glowColors; glowColors(end,:)];
                obj.GlowH.EdgeAlpha = glowAlpha;
            end

            % Update main line
            if ~isempty(obj.LineH) && isvalid(obj.LineH)
                obj.LineH.XData = [dispX; NaN];
                obj.LineH.YData = [dispY; NaN];
                obj.LineH.FaceVertexCData = [colors; colors(end,:)];
            end

            % Update envelope shape
            if ~isempty(obj.EnvelopeH) && isvalid(obj.EnvelopeH) ...
                    && ~isempty(obj.EnvelopeMax)
                envY = obj.EnvelopeMax * ampScale;
                obj.EnvelopeH.XData = [dispX; flipud(dispX); dispX(1)];
                obj.EnvelopeH.YData = [sy + envY; sy - flipud(envY); sy + envY(1)];
                envEnergy = max(obj.EnvelopeMax);
                obj.EnvelopeH.FaceAlpha = min(0.15, 0.02 + envEnergy * 0.8);
            end

            % Node markers at zero-crossings
            signs = uVec(1:end-1) .* uVec(2:end);
            crossIdx = find(signs < 0);
            if ~isempty(obj.NodeH) && isvalid(obj.NodeH)
                if ~isempty(crossIdx)
                    frac = abs(uVec(crossIdx)) ./ ...
                        (abs(uVec(crossIdx)) + abs(uVec(crossIdx + 1)) + 1e-15);
                    cx = dispX(crossIdx) + frac .* (dispX(crossIdx + 1) - dispX(crossIdx));
                    cy = repmat(sy, numel(cx), 1);
                    obj.NodeH.XData = cx';
                    obj.NodeH.YData = cy';
                    nodeAlpha = min(0.7, 0.1 + totalEnergy * 6);
                    obj.NodeH.MarkerFaceAlpha = nodeAlpha;
                    obj.NodeH.Visible = "on";
                else
                    obj.NodeH.Visible = "off";
                end
            end

            % --- DST Spectrum ---
            nBars = min(9, numel(obj.SpectrumH));
            uInterior = uVec(2:end-1);
            nInterior = numel(uInterior);
            jj = (1:nInterior)';
            harmonicEnergy = zeros(nBars, 1);
            for k = 1:nBars
                coeff = sum(uInterior .* sin(k * pi * jj / (nInterior + 1)));
                harmonicEnergy(k) = coeff^2;
            end
            harmonicEnergy = sqrt(harmonicEnergy);

            specBot = dy(2) - diff(dy) * 0.18;
            specTop = dy(2) - diff(dy) * 0.02;
            specH = specTop - specBot;
            maxMag = max(harmonicEnergy) + 1e-10;
            for k = 1:nBars
                if k <= numel(obj.SpectrumH)
                    hBar = obj.SpectrumH{k};
                    if ~isempty(hBar) && isvalid(hBar)
                        barFrac = min(1, harmonicEnergy(k) / maxMag);
                        barH = specH * barFrac;
                        yy = hBar.YData;
                        yy(3) = specBot + barH;
                        yy(4) = specBot + barH;
                        hBar.YData = yy;
                        hBar.FaceAlpha = 0.3 + 0.6 * barFrac;
                    end
                end
                % Highlight active harmonics
                if k <= numel(obj.SpecLabelH)
                    lbl = obj.SpecLabelH{k};
                    if ~isempty(lbl) && isvalid(lbl)
                        isActive = false;
                        if obj.SubMode == "superposition" && ...
                                k <= numel(obj.ActiveHarm) && obj.ActiveHarm(k)
                            isActive = true;
                        elseif obj.SubMode == "harmonics" && k == obj.HarmonicN
                            isActive = true;
                        end
                        if isActive
                            lbl.Color = [1, 1, 0.5];
                            lbl.FontWeight = "bold";
                        else
                            lbl.Color = [0.5, 0.5, 0.6];
                            lbl.FontWeight = "normal";
                        end
                    end
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete standing wave graphics and state.
            if ~isempty(obj.LineH) && isvalid(obj.LineH)
                delete(obj.LineH);
            end
            if ~isempty(obj.GlowH) && isvalid(obj.GlowH)
                delete(obj.GlowH);
            end
            singles = {obj.NodeH, obj.ImageH, obj.ModeTextH, ...
                obj.SpecBgH, obj.EnvelopeH};
            for k = 1:numel(singles)
                hDel = singles{k};
                if ~isempty(hDel) && isvalid(hDel); delete(hDel); end
            end
            for k = 1:numel(obj.SpectrumH)
                h = obj.SpectrumH{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            for k = 1:numel(obj.SpecLabelH)
                h = obj.SpecLabelH{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end

            obj.LineH = [];
            obj.GlowH = [];
            obj.NodeH = [];
            obj.ImageH = [];
            obj.ModeTextH = [];
            obj.SpecBgH = [];
            obj.EnvelopeH = [];
            obj.PluckFlashIdx = 0;
            obj.PluckFlashAmp = 0;
            obj.SpectrumH = {};
            obj.SpecLabelH = {};
            obj.U = [];
            obj.UPrev = [];
            obj.XPos = [];
            obj.FrameCount = 0;
            obj.PrevFingerY = 0;
            obj.PluckCount = 0;
            obj.PluckVels = [];
            obj.PluckPosX = [];
            obj.MuteCount = 0;
            obj.ActiveHarm(:) = false;
            obj.HarmonicN = 1;
            obj.EnvelopeMax = [];
            obj.PeakAmp = 0;

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_stringharmonics");
        end

        function onScroll(obj, delta)
            %onScroll  Scroll wheel cycles sub-modes.
            modes = ["superposition", "harmonics"];
            idx = find(modes == obj.SubMode, 1);
            if isempty(idx); idx = 1; end
            newIdx = mod(idx - 1 + delta, numel(modes)) + 1;
            obj.SubMode = modes(newIdx);
            obj.onCleanup();
            obj.onInit(obj.Ax, obj.DisplayRange, struct());
            obj.beginGame();
        end

        function handled = onKeyPress(obj, key)
            %onKeyPress  Handle mode-specific keys.
            handled = true;
            switch key
                case "m"
                    modes = ["superposition", "harmonics"];
                    idx = find(modes == obj.SubMode, 1);
                    obj.SubMode = modes(mod(idx, numel(modes)) + 1);
                    obj.onCleanup();
                    obj.onInit(obj.Ax, obj.DisplayRange, struct());
                    obj.beginGame();
                otherwise
                    if strlength(key) == 1 && key >= "0" && key <= "9"
                        n = double(key) - 48;
                        if n == 0
                            % Reset: kill all vibration
                            N = obj.NumPoints;
                            obj.U = zeros(N, 1);
                            obj.UPrev = zeros(N, 1);
                            obj.EnvelopeMax = zeros(N, 1);
                            obj.ActiveHarm(:) = false;
                            obj.PluckFlashAmp = 0;
                        elseif obj.SubMode == "harmonics" && ~isempty(obj.XPos)
                            obj.HarmonicN = n;
                            omegaDt = obj.WaveSpeed * n * pi / (obj.NumPoints - 1);
                            obj.U = zeros(obj.NumPoints, 1);
                            obj.UPrev = -1.2 * omegaDt * sin(n * pi * obj.XPos);
                            obj.EnvelopeMax = zeros(obj.NumPoints, 1);
                        elseif obj.SubMode == "superposition" && ...
                                n <= numel(obj.ActiveHarm)
                            obj.ActiveHarm(n) = ~obj.ActiveHarm(n);
                            obj.injectActiveHarmonics();
                            if ~isempty(obj.EnvelopeMax)
                                obj.EnvelopeMax = abs(obj.U);
                            end
                        end
                        obj.updateHud();
                    else
                        handled = false;
                    end
            end
        end

        function r = getResults(obj)
            %getResults  Return string harmonics results.
            r.Title = "STRING HARMONICS";
            avgVel = 0;
            if ~isempty(obj.PluckVels)
                avgVel = mean(obj.PluckVels);
            end
            r.Lines = {
                sprintf("%s  |  Plucks: %d  |  Avg Speed: %.2f  |  Peak: %.3f  |  Mutes: %d", ...
                    upper(obj.SubMode), obj.PluckCount, avgVel, ...
                    obj.PeakAmp, obj.MuteCount)
            };
        end

    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function applySubMode(obj)
            %applySubMode  Configure wave speed and damping for sub-mode.
            switch obj.SubMode
                case "harmonics"
                    obj.WaveSpeed = 0.8;
                    obj.Damping = 1.0;       % no damping — pure modes persist
                case "superposition"
                    obj.WaveSpeed = 0.8;
                    obj.Damping = 0.9994;    % visible decay ~5-8 seconds
                otherwise
                    obj.WaveSpeed = 0.8;
                    obj.Damping = 0.9998;
            end
        end

        function injectActiveHarmonics(obj)
            %injectActiveHarmonics  Set string to sum of toggled harmonics.
            if isempty(obj.XPos); return; end
            N = obj.NumPoints;
            uVec = zeros(N, 1);
            nActive = nnz(obj.ActiveHarm);
            if nActive == 0
                obj.U = uVec;
                obj.UPrev = uVec;
                return;
            end
            ampPer = 1.2;
            for k = 1:numel(obj.ActiveHarm)
                if obj.ActiveHarm(k)
                    uVec = uVec + ampPer * sin(k * pi * obj.XPos);
                end
            end
            obj.U = uVec;
            obj.UPrev = uVec;
        end

        function updateHud(obj)
            %updateHud  Update HUD text for standing wave mode.
            if ~isempty(obj.ModeTextH) && isvalid(obj.ModeTextH)
                obj.ModeTextH.String = obj.buildHudString();
            end
        end

        function s = buildHudString(obj)
            %buildHudString  Build HUD string.
            modeNames = struct("harmonics", "HARMONICS", ...
                "superposition", "SUPERPOSITION");
            modeName = "UNKNOWN";
            if isfield(modeNames, obj.SubMode)
                modeName = modeNames.(obj.SubMode);
            end
            s = modeName + " [M]";
            switch obj.SubMode
                case "harmonics"
                    s = s + "  |  n=" + obj.HarmonicN + ...
                        " [cross string / 1-9]  |  0=reset, R=restart";
                case "superposition"
                    active = find(obj.ActiveHarm);
                    if isempty(active)
                        activeStr = "none";
                    else
                        activeStr = strjoin(string(active), "+");
                    end
                    s = s + "  |  " + activeStr + ...
                        " [1-9 toggle]  |  Plucks: " + obj.PluckCount;
                    if ~isempty(obj.PluckVels)
                        s = s + "  |  Avg speed: " + ...
                            sprintf("%.2f", mean(obj.PluckVels));
                    end
                    s = s + "  |  0=reset, R=restart";
            end
        end
    end
end
