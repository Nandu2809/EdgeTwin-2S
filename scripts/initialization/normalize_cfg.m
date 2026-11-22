function cfg = normalize_cfg(cfg)
%NORMALIZE_CFG Validate and populate complete EdgeSentinel configuration structure.
% Ensures limits, thresholds, aliases, and ThingSpeak cloud telemetry fields exist.

if nargin < 1 || ~isstruct(cfg)
    cfg = struct();
end

if ~isfield(cfg, 'limits') || ~isstruct(cfg.limits), cfg.limits = struct(); end
if ~isfield(cfg.limits, 'lp_pressure_bar'), cfg.limits.lp_pressure_bar = [0.8, 4.5]; end
if ~isfield(cfg.limits, 'hp_pressure_bar'), cfg.limits.hp_pressure_bar = [3.0, 12.0]; end
if ~isfield(cfg.limits, 'temp_c'),          cfg.limits.temp_c          = [15, 160]; end
if ~isfield(cfg.limits, 'rpm_range'),       cfg.limits.rpm_range       = [0, 1650]; end

if ~isfield(cfg, 'thresh') || ~isstruct(cfg.thresh), cfg.thresh = struct(); end
if ~isfield(cfg.thresh, 'overtemp_c'),       cfg.thresh.overtemp_c       = 135.0; end
if ~isfield(cfg.thresh, 'overpressure_bar'), cfg.thresh.overpressure_bar = 10.5; end
if ~isfield(cfg.thresh, 'min_stage_ratio'),  cfg.thresh.min_stage_ratio  = 2.2; end

% Map threshold aliases used across dashboard and diagnostics
if ~isfield(cfg.thresh, 't_ic_high'), cfg.thresh.t_ic_high = cfg.thresh.overtemp_c; end
if ~isfield(cfg.thresh, 'p_hp_high'), cfg.thresh.p_hp_high = cfg.thresh.overpressure_bar; end
if ~isfield(cfg.thresh, 'rpm_high'),  cfg.thresh.rpm_high  = cfg.limits.rpm_range(2); end
if ~isfield(cfg.thresh, 'vib_high'),  cfg.thresh.vib_high  = 4.5; end

if ~isfield(cfg, 'ts') || ~isstruct(cfg.ts), cfg.ts = struct(); end
if ~isfield(cfg.ts, 'enable_upload'), cfg.ts.enable_upload = false; end
if ~isfield(cfg.ts, 'channel_id'),    cfg.ts.channel_id    = 0; end
if ~isfield(cfg.ts, 'write_key'),     cfg.ts.write_key     = ''; end
end
