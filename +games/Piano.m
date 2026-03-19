classdef Piano < GameBase
    %Piano  Interactive piano keyboard with synthesized tones.
    %   25-key piano (C3-C5, 2 octaves + 1) with realistic layout, ADSR
    %   envelope synthesis with stretched partials, and dwell-based key
    %   press via finger hover. Black keys checked first (on top), white
    %   keys underneath.
    %
    %   Standalone: games.Piano().play()
    %   Hosted:     GameHost registers this and calls onInit/onUpdate/onCleanup
    %
    %   See also GameBase, GameHost

    properties (Constant)
        Name = "Piano"
    end

    % =================================================================
    % GAME STATE
    % =================================================================
    properties (Access = private)
        NWhiteKeys      (1,1) double = 15       % white keys (C3 to C5 = 15)
        NKeys           (1,1) double = 25       % total keys (2 octaves + 1)
        KeyRects        (:,4) double            % [xLeft yTop xRight yBottom] per key
        IsBlack         (:,1) logical           % which keys are black
        Frequencies     (:,1) double            % frequency per key (Hz)
        ActiveKey       (1,1) double = 0        % currently pressed key (0=none)
        AudioPlayer                             % audioplayer for current tone
        SampleRate      (1,1) double = 44100    % audio sample rate
        ToneDuration    (1,1) double = 3.0      % max tone duration (s)
        NoteNames       (:,1) string            % note name per key
        NotesPlayed     (1,1) double = 0        % total notes played
        ReleaseFrames   (1,1) double = 0        % frames since release (for fade)
        LastKeyIdx      (1,1) double = 0        % last pressed key (for glow fade)
        FrameCount      (1,1) double = 0
    end

    % =================================================================
    % GRAPHICS HANDLES
    % =================================================================
    properties (Access = private)
        KeyPatchH       (:,1)                   % patch handles for keys
        HighlightH                              % patch for active key glow
        BgImageH                                % background image
        LabelH          (:,1)                   % text handles for note labels
    end

    % =================================================================
    % ABSTRACT METHOD IMPLEMENTATIONS
    % =================================================================
    methods
        function onInit(obj, ax, displayRange, ~)
            %onInit  Create realistic piano keyboard with 25 keys (C3-C5).
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
            dispW = diff(dx);
            dispH = diff(dy);

            obj.FrameCount = 0;
            obj.NotesPlayed = 0;
            obj.ActiveKey = 0;
            obj.LastKeyIdx = 0;
            obj.ReleaseFrames = 0;
            obj.AudioPlayer = [];

            % --- Build key layout ---
            % Piano pattern per octave: W B W B W W B W B W B W
            octavePattern = [false, true, false, true, false, false, true, ...
                             false, true, false, true, false];
            isBlk = [octavePattern, octavePattern, false]';  % 25 keys
            obj.IsBlack = isBlk;
            nKeys = numel(isBlk);
            obj.NKeys = nKeys;

            nWhite = sum(~isBlk);
            obj.NWhiteKeys = nWhite;

            % --- Compute frequencies (equal temperament, A4=440Hz) ---
            % C3 = MIDI 48, A4 = MIDI 69. f = 440 * 2^((midi-69)/12)
            midiStart = 48;  % C3
            midiNums = midiStart + (0:nKeys-1)';
            obj.Frequencies = 440 * 2.^((midiNums - 69) / 12);

            % --- Note names ---
            noteLabels = ["C", "C#", "D", "D#", "E", "F", "F#", ...
                          "G", "G#", "A", "A#", "B"];
            names = strings(nKeys, 1);
            for k = 1:nKeys
                octave = floor((midiNums(k)) / 12) - 1;
                noteIdx = mod(midiNums(k), 12) + 1;
                names(k) = noteLabels(noteIdx) + string(octave);
            end
            obj.NoteNames = names;

            % --- Layout geometry ---
            % Piano occupies bottom 45% of display, centered horizontally
            pianoH = dispH * 0.45;
            pianoW = dispW * 0.92;
            pianoLeft = dx(1) + (dispW - pianoW) / 2;
            pianoBottom = dy(2) - dispH * 0.05;
            pianoTop = pianoBottom - pianoH;

            whiteKeyW = pianoW / nWhite;
            blackKeyW = whiteKeyW * 0.58;
            blackKeyH = pianoH * 0.62;

            % Compute rectangles [xLeft yTop xRight yBottom]
            rects = zeros(nKeys, 4);
            whiteIdx = 0;
            whiteXPositions = zeros(nWhite, 1);

            % First pass: white keys
            for k = 1:nKeys
                if ~isBlk(k)
                    whiteIdx = whiteIdx + 1;
                    x0 = pianoLeft + (whiteIdx - 1) * whiteKeyW;
                    rects(k, :) = [x0, pianoTop, x0 + whiteKeyW, pianoBottom];
                    whiteXPositions(whiteIdx) = x0 + whiteKeyW / 2;
                end
            end

            % Second pass: black keys between adjacent white keys
            whiteIdx = 0;
            for k = 1:nKeys
                if ~isBlk(k)
                    whiteIdx = whiteIdx + 1;
                elseif isBlk(k)
                    xCenter = whiteXPositions(whiteIdx) + whiteKeyW / 2;
                    x0 = xCenter - blackKeyW / 2;
                    rects(k, :) = [x0, pianoTop, x0 + blackKeyW, pianoTop + blackKeyH];
                end
            end
            obj.KeyRects = rects;

            % --- Dark background ---
            obj.BgImageH = image(ax, "XData", dx, "YData", dy, ...
                "CData", zeros(2, 2, 3, "uint8"), ...
                "AlphaData", ones(2, 2) * 0.88, ...
                "AlphaDataMapping", "none", "Tag", "GT_piano");
            uistack(obj.BgImageH, "bottom");
            uistack(obj.BgImageH, "up");

            % --- Draw keys as patches ---
            obj.KeyPatchH = gobjects(nKeys, 1);
            obj.LabelH = gobjects(nKeys, 1);

            whiteKeyColor = [0.96, 0.96, 0.94];
            whiteKeyBorder = [0.55, 0.55, 0.52];
            blackKeyColor = [0.12, 0.12, 0.14];
            blackKeyBorder = [0.05, 0.05, 0.06];
            blackKeyTopColor = [0.22, 0.22, 0.24];

            % White keys first (behind)
            for k = 1:nKeys
                if ~isBlk(k)
                    r = rects(k, :);
                    xp = [r(1), r(3), r(3), r(1)];
                    yp = [r(2), r(2), r(4), r(4)];
                    obj.KeyPatchH(k) = patch(ax, xp, yp, whiteKeyColor, ...
                        "EdgeColor", whiteKeyBorder, "LineWidth", 1.2, ...
                        "Tag", "GT_piano");

                    % Note label at bottom of white key
                    if startsWith(names(k), "C") && ~startsWith(names(k), "C#")
                        labelStr = names(k);
                    else
                        labelStr = extractBefore(names(k), strlength(names(k)));
                        if isempty(labelStr); labelStr = names(k); end
                    end
                    obj.LabelH(k) = text(ax, ...
                        mean([r(1), r(3)]), r(4) - (r(4) - r(2)) * 0.06, ...
                        labelStr, "Color", [0.45, 0.45, 0.42], ...
                        "FontSize", 7, "FontWeight", "bold", ...
                        "HorizontalAlignment", "center", ...
                        "VerticalAlignment", "bottom", ...
                        "Tag", "GT_piano");
                end
            end

            % Black keys (on top of white)
            for k = 1:nKeys
                if isBlk(k)
                    r = rects(k, :);
                    xp = [r(1), r(3), r(3), r(1)];
                    yp = [r(2), r(2), r(4), r(4)];
                    obj.KeyPatchH(k) = patch(ax, xp, yp, blackKeyColor, ...
                        "EdgeColor", blackKeyBorder, "LineWidth", 1.0, ...
                        "Tag", "GT_piano");

                    % Lighter strip at top for 3D look
                    stripH = (r(4) - r(2)) * 0.12;
                    xps = [r(1) + 0.5, r(3) - 0.5, r(3) - 0.5, r(1) + 0.5];
                    yps = [r(2), r(2), r(2) + stripH, r(2) + stripH];
                    patch(ax, xps, yps, blackKeyTopColor, ...
                        "EdgeColor", "none", "Tag", "GT_piano");
                end
            end

            % --- Highlight overlay (hidden, shown on key press) ---
            obj.HighlightH = patch(ax, NaN, NaN, [1, 0.85, 0.2], ...
                "FaceAlpha", 0.45, "EdgeColor", [1, 0.9, 0.3], ...
                "LineWidth", 2, "Tag", "GT_piano", "Visible", "off");
        end

        function onUpdate(obj, pos)
            %onUpdate  Per-frame update: detect key hover and play tones.
            obj.FrameCount = obj.FrameCount + 1;

            % --- Key release glow fade ---
            if obj.ReleaseFrames > 0
                obj.ReleaseFrames = obj.ReleaseFrames + 1;
                fadeFrames = 12;
                if obj.ReleaseFrames > fadeFrames
                    obj.ReleaseFrames = 0;
                    obj.LastKeyIdx = 0;
                    if ~isempty(obj.HighlightH) && isvalid(obj.HighlightH)
                        obj.HighlightH.Visible = "off";
                    end
                else
                    fadeAlpha = 0.45 * (1 - obj.ReleaseFrames / fadeFrames);
                    if ~isempty(obj.HighlightH) && isvalid(obj.HighlightH)
                        obj.HighlightH.FaceAlpha = max(0, fadeAlpha);
                    end
                end
            end

            % --- Hit detection ---
            if any(isnan(pos))
                if obj.ActiveKey > 0
                    obj.releaseKey();
                end
                return;
            end

            fx = pos(1);
            fy = pos(2);
            rects = obj.KeyRects;
            isBlk = obj.IsBlack;

            % Check black keys first (they are on top)
            hitKey = 0;
            for k = 1:obj.NKeys
                if isBlk(k)
                    r = rects(k, :);
                    if fx >= r(1) && fx <= r(3) && fy >= r(2) && fy <= r(4)
                        hitKey = k;
                        break;
                    end
                end
            end

            % If no black key hit, check white keys
            if hitKey == 0
                for k = 1:obj.NKeys
                    if ~isBlk(k)
                        r = rects(k, :);
                        if fx >= r(1) && fx <= r(3) && fy >= r(2) && fy <= r(4)
                            hitKey = k;
                            break;
                        end
                    end
                end
            end

            % --- Key state transitions ---
            if hitKey ~= obj.ActiveKey
                if obj.ActiveKey > 0
                    obj.releaseKey();
                end
                if hitKey > 0
                    obj.pressKey(hitKey);
                end
            end
        end

        function onCleanup(obj)
            %onCleanup  Delete all piano graphics and stop audio.

            % Stop audio
            if ~isempty(obj.AudioPlayer)
                try
                    stop(obj.AudioPlayer);
                catch
                end
                obj.AudioPlayer = [];
            end

            % Delete key patches
            if ~isempty(obj.KeyPatchH)
                for k = 1:numel(obj.KeyPatchH)
                    if isvalid(obj.KeyPatchH(k))
                        delete(obj.KeyPatchH(k));
                    end
                end
                obj.KeyPatchH = [];
            end

            % Delete labels
            if ~isempty(obj.LabelH)
                for k = 1:numel(obj.LabelH)
                    if isvalid(obj.LabelH(k))
                        delete(obj.LabelH(k));
                    end
                end
                obj.LabelH = [];
            end

            % Delete highlight, background
            handles = {obj.HighlightH, obj.BgImageH};
            for k = 1:numel(handles)
                h = handles{k};
                if ~isempty(h) && isvalid(h); delete(h); end
            end
            obj.HighlightH = [];
            obj.BgImageH = [];

            % Orphan guard
            GameBase.deleteTaggedGraphics(obj.Ax, "^GT_piano");

            % Reset state
            obj.ActiveKey = 0;
            obj.LastKeyIdx = 0;
            obj.ReleaseFrames = 0;
            obj.KeyRects = [];
            obj.IsBlack = [];
            obj.Frequencies = [];
            obj.NoteNames = [];
            obj.FrameCount = 0;
        end

        function handled = onKeyPress(~, ~)
            %onKeyPress  No mode-specific keys for piano.
            handled = false;
        end

        function r = getResults(obj)
            %getResults  Return piano-specific results.
            r.Title = "PIANO";
            r.Lines = {
                sprintf("Notes Played: %d", obj.NotesPlayed)
            };
        end
    end

    % =================================================================
    % PRIVATE METHODS
    % =================================================================
    methods (Access = private)

        function pressKey(obj, keyIdx)
            %pressKey  Start playing a tone and highlight the key.
            obj.ActiveKey = keyIdx;
            obj.NotesPlayed = obj.NotesPlayed + 1;
            obj.ReleaseFrames = 0;

            % --- Generate piano-like tone ---
            freq = obj.Frequencies(keyIdx);
            sr = obj.SampleRate;
            dur = obj.ToneDuration;
            t = (0:1/sr:dur)';

            % Rich piano tone: fundamental + harmonics with inharmonicity
            inharmonicity = 0.0005;
            h1 = sin(2 * pi * freq * t);
            h2 = 0.50 * sin(2 * pi * 2 * freq * sqrt(1 + 4 * inharmonicity) * t);
            h3 = 0.25 * sin(2 * pi * 3 * freq * sqrt(1 + 9 * inharmonicity) * t);
            h4 = 0.12 * sin(2 * pi * 4 * freq * sqrt(1 + 16 * inharmonicity) * t);
            h5 = 0.06 * sin(2 * pi * 5 * freq * sqrt(1 + 25 * inharmonicity) * t);
            h6 = 0.03 * sin(2 * pi * 6 * freq * sqrt(1 + 36 * inharmonicity) * t);
            tone = h1 + h2 + h3 + h4 + h5 + h6;

            % ADSR envelope
            attackTime = 0.008;
            decayTime = 0.15;
            sustainLevel = 0.35;

            nSamples = numel(t);
            env = ones(nSamples, 1);

            attackSamples = round(attackTime * sr);
            decaySamples = round(decayTime * sr);
            releaseSamples = round(0.2 * sr);

            % Attack
            attackIdx = min(attackSamples, nSamples);
            env(1:attackIdx) = linspace(0, 1, attackIdx)';

            % Decay (exponential to sustain level)
            decayStart = attackIdx + 1;
            decayEnd = min(decayStart + decaySamples - 1, nSamples);
            if decayEnd >= decayStart
                decayLen = decayEnd - decayStart + 1;
                env(decayStart:decayEnd) = sustainLevel + ...
                    (1 - sustainLevel) * exp(-5 * (0:decayLen-1)' / decayLen);
            end

            % Sustain with gradual exponential decay
            sustainStart = decayEnd + 1;
            releaseIdx = max(sustainStart, nSamples - releaseSamples + 1);
            if releaseIdx > sustainStart
                sustainLen = releaseIdx - sustainStart;
                env(sustainStart:releaseIdx-1) = sustainLevel * ...
                    exp(-1.5 * (0:sustainLen-1)' / sustainLen);
            end

            % Release
            if releaseIdx <= nSamples
                releaseLen = nSamples - releaseIdx + 1;
                baseLevel = env(max(1, releaseIdx - 1));
                env(releaseIdx:end) = baseLevel * ...
                    linspace(1, 0, releaseLen)';
            end

            % Higher notes decay faster
            freqDamping = 1 + max(0, (freq - 261) / 1000);
            env = env .* exp(-t * freqDamping * 0.8);

            tone = tone .* env * 0.28;

            % Stop previous player if still playing
            if ~isempty(obj.AudioPlayer)
                try
                    stop(obj.AudioPlayer);
                catch
                end
            end

            % Play
            obj.AudioPlayer = audioplayer(tone, sr);
            play(obj.AudioPlayer);

            % Visual highlight
            obj.showHighlight(keyIdx);
        end

        function releaseKey(obj)
            %releaseKey  Stop tone and begin highlight fade.
            if obj.ActiveKey == 0; return; end

            obj.LastKeyIdx = obj.ActiveKey;
            obj.ActiveKey = 0;
            obj.ReleaseFrames = 1;

            if ~isempty(obj.AudioPlayer)
                try
                    stop(obj.AudioPlayer);
                catch
                end
                obj.AudioPlayer = [];
            end
        end

        function showHighlight(obj, keyIdx)
            %showHighlight  Show glow overlay on the active key.
            if isempty(obj.HighlightH) || ~isvalid(obj.HighlightH)
                return;
            end
            r = obj.KeyRects(keyIdx, :);
            xp = [r(1), r(3), r(3), r(1)];
            yp = [r(2), r(2), r(4), r(4)];
            obj.HighlightH.XData = xp;
            obj.HighlightH.YData = yp;

            if obj.IsBlack(keyIdx)
                obj.HighlightH.FaceColor = obj.ColorCyan;
                obj.HighlightH.EdgeColor = [0.3, 0.95, 1];
            else
                obj.HighlightH.FaceColor = obj.ColorGold;
                obj.HighlightH.EdgeColor = [1, 0.9, 0.3];
            end
            obj.HighlightH.FaceAlpha = 0.45;
            obj.HighlightH.Visible = "on";
        end
    end
end
