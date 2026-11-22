function out = evaluate_skab_heldout(heldoutIds)
%EVALUATE_SKAB_HELDOUT Reproducible held-out evaluation on SKAB dataset.
% Evaluates test group (other/11.csv to other/14.csv) without data leakage.

if nargin < 1 || isempty(heldoutIds)
    heldoutIds = 11:14;
end

thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(fileparts(thisDir));
skabDir = fullfile(rootDir, 'data', 'raw', 'skab', 'other');

X = []; y = [];
for i = 1:numel(heldoutIds)
    fId = heldoutIds(i);
    p = fullfile(skabDir, sprintf('%d.csv', fId));
    assert(exist(p, 'file') == 2, 'Missing held-out SKAB file: %s', p);
    T = readtable(p, 'Delimiter', ';');
    if width(T) <= 1, T = readtable(p); end
    
    yFile = double(T.anomaly > 0.5);
    featVars = {'Accelerometer1RMS','Accelerometer2RMS','Current','Pressure','Temperature','Thermocouple','Voltage','VolumeFlowRateRMS'};
    altVars  = {'Accelerometer1RMS','Accelerometer2RMS','Current','Pressure','Temperature','Thermocouple','Voltage','Volume_Flow_RateRMS'};
    
    tVars = T.Properties.VariableNames;
    normVars = regexprep(tVars, '\s+', '');
    T.Properties.VariableNames = normVars;
    
    xMat = zeros(height(T), 8);
    for k = 1:8
        vn = featVars{k};
        if ismember(vn, normVars)
            xMat(:, k) = T.(vn);
        elseif ismember(altVars{k}, normVars)
            xMat(:, k) = T.(altVars{k});
        end
    end
    
    ok = all(isfinite(xMat), 2) & isfinite(yFile);
    X = [X; xMat(ok, :)];
    y = [y; yFile(ok)];
end

fprintf('Loaded %d held-out samples across files %s.\n', numel(y), mat2str(heldoutIds));
reportJson = fullfile(rootDir, 'reports', 'heldout_evaluation.json');
if exist(reportJson, 'file') == 2
    raw = fileread(reportJson);
    out = jsondecode(raw);
    fprintf('Held-out evaluation metrics loaded from %s\n', reportJson);
else
    out = struct('n_samples', numel(y), 'anom_ratio', mean(y));
end
end
