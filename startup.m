% STARTUP Automatically configure MATLAB search paths for EdgeTwin-2S
% Ensures that 'app', 'scripts', 'models', and all subdirectories are
% available immediately when MATLAB is started in the repository directory.

rootDir = fileparts(mfilename('fullpath'));
if isempty(rootDir)
    rootDir = pwd;
end

addpath(genpath(rootDir));
