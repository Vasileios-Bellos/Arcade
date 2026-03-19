classdef (Sealed) ScoreManager
    %ScoreManager  Persistent high-score tracking for all arcade games.
    %   Static-only utility class. Stores per-game high scores, combo records,
    %   play counts, and session times in a .mat file. Auto-creates records
    %   for new games on first play — no registration needed.
    %
    %   Usage:
    %       [isNew, prev] = ScoreManager.submit("FlickIt", 5000, 45, 120);
    %       rec = ScoreManager.get("FlickIt");
    %       ScoreManager.clearAll();
    %
    %   See also GameHost, ArcadeGameLauncher, GameBase

    methods (Static)

        function [isNewHigh, previousBest] = submit(gameId, score, maxCombo, elapsed)
            %submit  Record a game session result.
            %   Returns true if the score is a new high score, plus the
            %   previous best score (0 if first time playing).
            arguments
                gameId      (1,1) string
                score       (1,1) double
                maxCombo    (1,1) double
                elapsed     (1,1) double
            end

            data = ScoreManager.loadData();
            if ~isfield(data.Games, gameId)
                data.Games.(gameId) = ScoreManager.emptyRecord();
            end
            rec = data.Games.(gameId);

            previousBest = rec.highScore;
            isNewHigh = score > rec.highScore;

            if isNewHigh
                rec.highScore = score;
                rec.highScoreDate = datetime("now");
            end
            if maxCombo > rec.maxCombo
                rec.maxCombo = maxCombo;
                rec.maxComboDate = datetime("now");
            end

            rec.timesPlayed = rec.timesPlayed + 1;
            rec.totalTime = rec.totalTime + elapsed;
            rec.lastPlayed = datetime("now");

            data.Games.(gameId) = rec;
            ScoreManager.saveData(data);
        end

        function rec = get(gameId)
            %get  Get high score record for a game.
            %   Returns a struct with highScore, maxCombo, timesPlayed, etc.
            %   Returns an empty record (all zeros/NaT) if game has no history.
            arguments
                gameId (1,1) string
            end
            data = ScoreManager.loadData();
            if isfield(data.Games, gameId)
                rec = data.Games.(gameId);
            else
                rec = ScoreManager.emptyRecord();
            end
        end

        function allGames = getAll()
            %getAll  Get the full Games struct (one field per game ID).
            %   Returns struct() if no scores exist.
            data = ScoreManager.loadData();
            allGames = data.Games;
        end

        function tf = isHighScore(gameId, score)
            %isHighScore  Check if score would beat the current high score.
            arguments
                gameId (1,1) string
                score  (1,1) double
            end
            rec = ScoreManager.get(gameId);
            tf = score > rec.highScore;
        end

        function clearGame(gameId)
            %clearGame  Reset scores for one game.
            arguments
                gameId (1,1) string
            end
            data = ScoreManager.loadData();
            if isfield(data.Games, gameId)
                data.Games = rmfield(data.Games, gameId);
                ScoreManager.saveData(data);
            end
        end

        function clearAll()
            %clearAll  Reset all scores. Deletes the scores file.
            p = ScoreManager.filePath();
            if isfile(p)
                delete(p);
            end
        end

        function id = classToId(className)
            %classToId  Extract game ID from full class name.
            %   "games.FlickIt" -> "FlickIt"
            %   "FlickIt"       -> "FlickIt"
            s = string(className);
            dotIdx = strfind(s, ".");
            if isempty(dotIdx)
                id = s;
            else
                id = extractAfter(s, dotIdx(end));
            end
        end
    end

    % =================================================================
    % PRIVATE — Storage
    % =================================================================
    methods (Static, Access = private)

        function data = loadData()
            %loadData  Load scores from .mat file.
            %   Returns struct with Version and Games fields.
            %   Missing or corrupt file returns fresh empty data.
            p = ScoreManager.filePath();
            if isfile(p)
                try
                    raw = load(p);
                    if isfield(raw, "Version") && raw.Version == 1 ...
                            && isfield(raw, "Games") && isstruct(raw.Games)
                        data.Version = raw.Version;
                        data.Games = raw.Games;
                        return;
                    end
                    % Version mismatch or unexpected format — start fresh
                    warning("ScoreManager:VersionMismatch", ...
                        "Score file version mismatch. Resetting scores.");
                catch ME
                    warning("ScoreManager:LoadError", ...
                        "Failed to load scores: %s. Resetting.", ME.message);
                end
            end
            % Fresh data
            data.Version = 1;
            data.Games = struct();
        end

        function saveData(data)
            %saveData  Save scores to .mat file.
            Version = data.Version;
            Games = data.Games;
            try
                save(ScoreManager.filePath(), "Version", "Games");
            catch ME
                warning("ScoreManager:SaveError", ...
                    "Failed to save scores: %s", ME.message);
            end
        end

        function p = filePath()
            %filePath  Return path to the scores .mat file.
            p = fullfile(fileparts(which("ScoreManager")), ...
                "ScoreManager_scores.mat");
        end

        function rec = emptyRecord()
            %emptyRecord  Return a fresh per-game record with defaults.
            rec.highScore = 0;
            rec.highScoreDate = NaT;
            rec.maxCombo = 0;
            rec.maxComboDate = NaT;
            rec.timesPlayed = 0;
            rec.totalTime = 0;
            rec.lastPlayed = NaT;
        end
    end
end
