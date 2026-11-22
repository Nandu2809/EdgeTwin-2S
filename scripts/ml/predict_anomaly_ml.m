function [prob, isAnom, topFeat] = predict_anomaly_ml(tel)
%PREDICT_ANOMALY_ML Strict 8-feature contract enforcement for SKAB ML model.
% Requires genuine 8-feature SKAB telemetry:
%   Accelerometer1RMS, Accelerometer2RMS, Current, Pressure,
%   Temperature, Thermocouple, Voltage, Volume Flow RateRMS.
%
% If 5-sensor compressor telemetry is passed or features are missing,
% this function returns prob = NaN and isAnom = false to uphold strict
% scope honesty and NEVER fabricate synthetic features.

skabFields = {'Accelerometer1RMS', 'Accelerometer2RMS', 'Current', 'Pressure', ...
              'Temperature', 'Thermocouple', 'Voltage', 'VolumeFlowRateRMS'};
skabFieldsAlt = {'Accelerometer1RMS', 'Accelerometer2RMS', 'Current', 'Pressure', ...
                 'Temperature', 'Thermocouple', 'Voltage', 'Volume_Flow_RateRMS'};

hasFields = false;
if isstruct(tel)
    if all(isfield(tel, skabFields))
        hasFields = true;
        x8 = [tel.Accelerometer1RMS, tel.Accelerometer2RMS, tel.Current, tel.Pressure, ...
              tel.Temperature, tel.Thermocouple, tel.Voltage, tel.VolumeFlowRateRMS];
    elseif all(isfield(tel, skabFieldsAlt))
        hasFields = true;
        x8 = [tel.Accelerometer1RMS, tel.Accelerometer2RMS, tel.Current, tel.Pressure, ...
              tel.Temperature, tel.Thermocouple, tel.Voltage, tel.Volume_Flow_RateRMS];
    end
elseif isnumeric(tel) && numel(tel) == 8
    hasFields = true;
    x8 = tel(:)';
end

if ~hasFields
    prob = NaN;
    isAnom = false;
    topFeat = 'ML UNAVAILABLE (5-sensor telemetry; 8-feature SKAB required)';
    return;
end

if ~all(isfinite(x8))
    error('predict_anomaly_ml:NonFiniteInput', 'Input vector contains non-finite values (NaN/Inf).');
end

% Check if edge_anomaly_model.mat is present
thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(fileparts(thisDir));
mdlFile = fullfile(rootDir, 'models', 'edge_anomaly_model.mat');

if exist(mdlFile, 'file') == 2
    S = load(mdlFile, 'mdl', 'mu', 'sig', 'bestTh', 'featNames');
    z = (x8 - S.mu) ./ S.sig;
    [~, pMat] = predict(S.mdl, z);
    prob = pMat(end, 2);
    isAnom = prob >= S.bestTh;
    [~, idxMax] = max(abs(z));
    topFeat = S.featNames{min(idxMax, numel(S.featNames))};
else
    prob = 0.0;
    isAnom = false;
    topFeat = 'Model bundle not found on disk';
end
end
