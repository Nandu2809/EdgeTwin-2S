function [reportTxt, healthTxt, healthCol, recAct, recBanner, recColor, zones, partStr, impactStr, fixStr, advisoryStr] = analyzeContinuousState(tel, is_valid, anom, f_code, truth, act_fb, thresh, mlProb, topFeat, nl)
%ANALYZECONTINUOUSSTATE Evaluates compressor telemetry, identifies affected parts,
% diagnoses machine impact, generates plain-language advisories, and flags zones.
%
% Outputs:
%   reportTxt   - Full diagnostic string for logging / detail readout
%   healthTxt   - Concise machine health status string
%   healthCol   - RGB vector for machine status banner
%   recAct      - Recommended actuator action code
%   recBanner   - Multi-line banner string for recommended action
%   recColor    - RGB vector for recommendation banner
%   zones       - Structure of boolean zone flags for process diagram virtualization
%   partStr     - Plain-language affected compressor part / subsystem
%   impactStr   - Plain-language explanation of potential operational impact
%   fixStr      - Plain-language recommended mitigation / operator action
%   advisoryStr - Explicit disclaimer that recommendation is advisory / simulated

if nargin < 10 || isempty(nl), nl = string(newline); else, nl = string(nl); end
if nargin < 9, topFeat = 'Rule/Threshold'; end
if nargin < 8, mlProb = NaN; end
if nargin < 7 || ~isstruct(thresh), thresh = struct(); end
if nargin < 6, act_fb = [0 0 0 0 0]; end
if nargin < 5 || ~isstruct(truth), truth = struct('fault_label', 'UNKNOWN'); end
if nargin < 4, f_code = double(anom); end
if nargin < 3, anom = false; end
if nargin < 2, is_valid = true; end

is_valid = normalize_validity(is_valid, 4);

% Threshold normalization (handles both dashboard and init_edgesentinel schemas)
t_ic_lim = 130.0;
if isfield(thresh, 't_ic_high'), t_ic_lim = thresh.t_ic_high;
elseif isfield(thresh, 'overtemp_c'), t_ic_lim = thresh.overtemp_c; end

p_hp_lim = 10.5;
if isfield(thresh, 'p_hp_high'), p_hp_lim = thresh.p_hp_high;
elseif isfield(thresh, 'overpressure_bar'), p_hp_lim = thresh.overpressure_bar; end

rpm_lim = 1650.0;
if isfield(thresh, 'rpm_high'), rpm_lim = thresh.rpm_high; end

vib_lim = 4.5;
if isfield(thresh, 'vib_high'), vib_lim = thresh.vib_high; end

ratio_lim = 2.2;
if isfield(thresh, 'min_stage_ratio'), ratio_lim = thresh.min_stage_ratio; end

% Standard advisory disclaimer:
advisoryStr = 'SIMULATED SCADA-HMI ADVISORY: Digital-twin heuristics for demonstration/supervisory testing. Field safety relies on independent hardwired SIL-3 emergency stops, physical PRVs, and certified PLCs.';

zones = struct('motor', false, 'motor_warn', false, 'lp', false, 'lp_warn', false, 'ic', false, 'ic_warn', false, 'hp', false, 'hp_warn', false);

% Evaluate specific condition:
% Reserve SENSOR_FAULT strictly for non-finite or impossible electrical transducer fault codes (-99.9 or negative).
hp_bad = ~is_valid(2) || ~isfinite(tel.p_hp_bar) || (tel.p_hp_bar < -50) || isnan(tel.p_hp_bar);
gen_sensor_bad = any(~is_valid([1 3 4])) || ~isfinite(tel.p_lp_bar) || ~isfinite(tel.t_ic_c) || ~isfinite(tel.rpm) || ...
                 (tel.p_lp_bar < 0) || (tel.t_ic_c < -50) || (tel.rpm < 0);

is_temp_bad = isfinite(tel.t_ic_c) && (tel.t_ic_c > t_ic_lim);
is_press_bad = isfinite(tel.p_hp_bar) && (tel.p_hp_bar > p_hp_lim);
is_speed_bad = isfinite(tel.rpm) && (tel.rpm > rpm_lim);
is_vib_bad = isfinite(tel.vib_mm_s) && (tel.vib_mm_s > vib_lim);
ratioVal = tel.p_hp_bar / max(tel.p_lp_bar, 0.1);
is_leak_bad = isfinite(tel.p_hp_bar) && isfinite(tel.p_lp_bar) && (ratioVal < ratio_lim);

numFaults = is_temp_bad + is_press_bad + is_speed_bad + is_vib_bad + is_leak_bad;

if hp_bad
    zones.hp = true;
    healthTxt = '● STATUS: SENSOR FAULT (HP)';
    healthCol = [1.0 0.35 0.35];
    recAct = 'RESET';
    recBanner = string('RECOMMENDED ACTUATOR: RESET / QUARANTINE') + nl + string('HP signal out-of-range (-99.9 bar or NaN). Quarantine & check sensor.');
    recColor = [1.0 0.45 0.45];
    partStr = 'HP Pressure Transducer / Signal Path';
    impactStr = 'Corrupted or missing telemetry stream (-99.9 bar or NaN). Closed-loop supervisory control blinded to HP discharge; stage ratio calculation corrupted.';
    fixStr = 'Quarantine HP transducer channel; switch to fail-safe manual monitoring and inspect sensor wiring.';

elseif gen_sensor_bad
    zones.hp_warn = true;
    healthTxt = '● STATUS: SENSOR FAULT (CORRUPT/NEGATIVE)';
    healthCol = [1.0 0.35 0.35];
    recAct = 'RESET';
    recBanner = string('RECOMMENDED ACTUATOR: RESET / QUARANTINE') + nl + string('Sensor signal non-finite or impossible electrical code. Quarantine channel.');
    recColor = [1.0 0.45 0.45];
    partStr = 'Telemetry Transducer / Signal Interface';
    impactStr = 'Non-finite or out-of-range electrical sensor reading received. Signal stream quarantined.';
    fixStr = 'Inspect transducer wiring, power supply, and ADC conversion loop.';

elseif act_fb(1) > 0.5
    zones.motor = true;
    healthTxt = '● STATUS: COMPRESSOR STOPPED (SAFE IDLE | MOTOR STOP ACTIVE)';
    healthCol = [0.35 0.75 1.0];
    recAct = 'RESET';
    recBanner = string('SUPERVISORY STATE: MOTOR STOPPED (IDLE)') + nl + string('Compressor drive stopped safely (0 RPM). Reset to re-engage.');
    recColor = [0.35 0.75 1.0];
    partStr = 'Motor Drive Train & Crankshaft Assembly';
    impactStr = 'Drive halted (0 RPM, 0 A); cylinders depressurizing to atmospheric (1.01 bar). Mechanical fatigue and vibration eliminated.';
    fixStr = 'Release / toggle Motor Stop off to restart simulated twin motor drive.';

elseif numFaults >= 2
    % Compound multi-fault (2 or more simultaneous abnormal conditions)
    healthTxt = sprintf('● STATUS: CRITICAL MULTI-FAULT (%d FAULTS)', numFaults);
    healthCol = [1.0 0.25 0.25];
    
    partsList = {};
    impactsList = {};
    fixesList = {};
    
    if is_temp_bad
        zones.ic = true; zones.hp_warn = true;
        partsList{end+1} = 'Intercooler';
        impactsList{end+1} = sprintf('Thermal oil degradation (IC %.1f°C > %.1f°C)', tel.t_ic_c, t_ic_lim);
        fixesList{end+1} = 'Engage COOLING_FAN';
    end
    if is_press_bad
        zones.hp = true; zones.motor_warn = true;
        partsList{end+1} = 'HP Stage Head & Receiver';
        impactsList{end+1} = sprintf('High-cycle pressure stress (HP %.2f bar > %.2f bar)', tel.p_hp_bar, p_hp_lim);
        fixesList{end+1} = 'Engage UNLOADER valve';
    end
    if is_speed_bad
        zones.motor = true; zones.hp_warn = true;
        partsList{end+1} = 'Motor Drive & Governor';
        impactsList{end+1} = sprintf('Excessive reciprocating inertia (%.0f RPM > %.0f RPM)', tel.rpm, rpm_lim);
        fixesList{end+1} = 'Reduce speed / issue MOTOR_STOP';
    end
    if is_vib_bad
        zones.motor_warn = true; zones.lp_warn = true; zones.hp_warn = true;
        partsList{end+1} = 'Crankcase & Bearings';
        impactsList{end+1} = sprintf('Dynamic unbalance & bearing fatigue (%.2f mm/s > %.2f mm/s)', tel.vib_mm_s, vib_lim);
        fixesList{end+1} = 'Unload compressor & check mounts';
    end
    if is_leak_bad
        zones.lp = true; zones.hp_warn = true;
        partsList{end+1} = 'LP/HP Valve Plates';
        impactsList{end+1} = sprintf('Gas recirculation & flow loss (Ratio %.2f < %.1f)', ratioVal, ratio_lim);
        fixesList{end+1} = 'Inspect valve reeds';
    end
    
    partStr = strjoin(partsList, ' + ');
    impactStr = ['Compound multi-subsystem distress: ', strjoin(impactsList, '; '), '. Accelerated degradation and imminent trip risk.'];
    fixStr = strjoin(fixesList, '; ');
    
    if is_temp_bad
        recAct = 'COOLING_FAN';
        recBanner = string('RECOMMENDED ACTUATOR: COOLING_FAN (then UNLOADER)') + nl + string(sprintf('Multi-fault active (%d faults): High IC temp + mechanical load.', numFaults));
        recColor = [1.0 0.35 0.35];
    else
        recAct = 'UNLOADER';
        recBanner = string('RECOMMENDED ACTUATOR: UNLOADER (then MOTOR_STOP)') + nl + string(sprintf('Multi-fault active (%d faults): Mechanical overload detected.', numFaults));
        recColor = [1.0 0.35 0.35];
    end

elseif is_temp_bad
    zones.ic = true; zones.hp_warn = true;
    healthTxt = '● STATUS: HIGH TEMP (IC)';
    healthCol = [1.0 0.55 0.20];
    recAct = 'COOLING_FAN';
    recBanner = string('RECOMMENDED ACTUATOR: COOLING_FAN') + nl + string(sprintf('IC temp (%.1f °C) > threshold (%.1f °C). Engage CoolingFan.', tel.t_ic_c, t_ic_lim));
    recColor = [1.0 0.65 0.25];
    partStr = 'Interstage Intercooler (Stage 1 -> Stage 2)';
    impactStr = 'High discharge gas temperature degrades lubricating oil film; hot intake into HP stage increases compression work and accelerates discharge valve thermal fatigue.';
    fixStr = 'Actuate COOLING_FAN to restore heat rejection; inspect intercooler fins for fouling or fan failure.';

elseif is_press_bad
    zones.hp = true; zones.motor_warn = true;
    healthTxt = '● STATUS: HIGH PRESS (HP)';
    healthCol = [1.0 0.35 0.35];
    recAct = 'UNLOADER';
    recBanner = string('RECOMMENDED ACTUATOR: UNLOADER (or DRAIN)') + nl + string(sprintf('HP pressure (%.2f bar) > threshold (%.2f bar). Relieve load.', tel.p_hp_bar, p_hp_lim));
    recColor = [1.0 0.45 0.45];
    partStr = 'HP Stage Discharge Head & Receiver Tank';
    impactStr = 'Excessive mechanical pressure cycle stress on HP cylinder head, discharge reeds, and receiver vessel; causes motor overcurrent and risks pressure relief lifting.';
    fixStr = 'Actuate UNLOADER valve (or DRAIN) to relieve line pressure; verify receiver demand and check check-valve.';

elseif is_speed_bad
    zones.motor = true; zones.hp_warn = true;
    healthTxt = '● STATUS: HIGH SPEED (RPM)';
    healthCol = [1.0 0.45 0.25];
    recAct = 'UNLOADER';
    recBanner = string('RECOMMENDED ACTUATOR: UNLOADER / MOTOR_STOP') + nl + string(sprintf('Speed (%.0f RPM) > threshold (%.0f RPM). Unload or stop.', tel.rpm, rpm_lim));
    recColor = [1.0 0.55 0.30];
    partStr = 'Motor Drive & Crankshaft Speed Governor';
    impactStr = 'Excessive reciprocating inertia forces on connecting rods and bearings; increased mechanical friction, vibration, and stator overheating.';
    fixStr = 'Actuate UNLOADER and issue MOTOR_STOP; verify VFD speed loop and inverter controller.';

elseif is_vib_bad
    zones.motor_warn = true; zones.lp_warn = true; zones.hp_warn = true;
    healthTxt = '● STATUS: HIGH VIBRATION';
    healthCol = [1.0 0.55 0.20];
    recAct = 'UNLOADER';
    recBanner = string('RECOMMENDED ACTUATOR: UNLOADER / MOTOR_STOP') + nl + string(sprintf('Vibration (%.2f mm/s) > threshold (%.2f mm/s). Unload & inspect.', tel.vib_mm_s, vib_lim));
    recColor = [1.0 0.65 0.25];
    partStr = 'Crankcase, Bearings & Structural Mounts';
    impactStr = 'High mechanical vibration indicates dynamic unbalance, loose foundation fasteners, or bearing fatigue; risks catastrophic bearing seizure if prolonged.';
    fixStr = 'Actuate UNLOADER (or MOTOR_STOP) to relieve reciprocating forces; inspect mounting bolts and main bearings.';

elseif is_leak_bad
    zones.lp = true; zones.hp_warn = true; zones.ic_warn = true;
    healthTxt = '● STATUS: VALVE LEAKAGE';
    healthCol = [1.0 0.78 0.25];
    recAct = 'UNLOADER';
    recBanner = string('RECOMMENDED ACTUATOR: UNLOADER') + nl + string(sprintf('Stage ratio (%.2f) < %.1f. Unload & inspect valves.', ratioVal, ratio_lim));
    recColor = [1.0 0.82 0.30];
    partStr = 'LP / HP Suction & Discharge Valve Plates';
    impactStr = 'Interstage valve slip causes continuous gas recirculation, severe delivery flow loss, and localized interstage reheating.';
    fixStr = 'Actuate UNLOADER to depressurize; inspect and replace worn or carbonized suction/discharge valve plates.';

else
    activeList = {};
    if numel(act_fb) >= 2 && act_fb(2) > 0.5, activeList{end+1} = 'UNLOADER'; end
    if numel(act_fb) >= 3 && act_fb(3) > 0.5, activeList{end+1} = 'COOLING_FAN'; end
    if numel(act_fb) >= 4 && act_fb(4) > 0.5, activeList{end+1} = 'DRAIN'; end
    if numel(act_fb) >= 5 && act_fb(5) > 0.5, activeList{end+1} = 'SPEED_TRIM'; end
    if ~isempty(activeList)
        actStr = strjoin(activeList, ' + ');
        healthTxt = sprintf('● STATUS: MITIGATED / ACTIVE CONTROL [%s]', actStr);
        healthCol = [0.20 0.85 0.55];
        recAct = 'MONITOR';
        recBanner = string(sprintf('ACTIVE CONTROL ENGAGED: %s', actStr)) + nl + string('Actuator applied. Telemetry channels brought into safe threshold limits.');
        recColor = [0.20 0.85 0.55];
        partStr = sprintf('Supervisory Control: %s Engaged', actStr);
        impactStr = sprintf('Active mitigation in progress (%s). Thermodynamic load relieved; operating within safe margins.', actStr);
        fixStr = sprintf('Maintain %s until thermal/mechanical equilibrium stabilizes, or return to unforced nominal mode.', actStr);
    else
        healthTxt = '● STATUS: NOMINAL  |  ALL CHANNELS HEALTHY';
        healthCol = [0.25 0.92 0.48];
        recAct = 'NONE';
        recBanner = string('RECOMMENDED ACTUATOR: NONE (Nominal)') + nl + string('All monitored channels within normal operating limits.');
        recColor = [0.25 0.92 0.52];
        partStr = 'None — All Subsystems Nominal';
        impactStr = 'Operating within thermodynamic and mechanical design limits. Stable 2-stage compression, balanced thermal dissipation, and normal vibration levels.';
        fixStr = 'No intervention required. System running nominally within configured prototype thresholds.';
    end
end

ratioVal = tel.p_hp_bar / max(tel.p_lp_bar, 0.1);
if isnan(mlProb)
    mlInfoStr = sprintf('Anom:%d | Code:%d | ML: UNAVAILABLE [Rule-Only] (%s)', double(anom), double(f_code), string(topFeat));
else
    mlInfoStr = sprintf('Anom:%d | Code:%d | ML:%.2f (%s)', double(anom), double(f_code), mlProb, string(topFeat));
end
reportTxt = string(healthTxt) + nl + ...
    string(mlInfoStr) + nl + ...
    string(sprintf('Ratio:%.2f | ActFb:[%s]', ratioVal, num2str(act_fb > 0.1))) + nl + nl + ...
    'AFFECTED PART:' + nl + string(partStr) + nl + nl + ...
    'POTENTIAL IMPACT:' + nl + string(impactStr) + nl + nl + ...
    'HOW TO FIX:' + nl + string(fixStr) + nl + nl + ...
    'ADVISORY NOTICE:' + nl + string(advisoryStr) + nl + nl + ...
    'Twin Ref: ' + string(truth.fault_label);
end

function vOut = normalize_validity(vIn, targetLen)
if nargin < 2, targetLen = 4; end
if isempty(vIn)
    vOut = false(1, targetLen);
elseif isscalar(vIn)
    vOut = repmat(logical(vIn), 1, targetLen);
else
    vOut = logical(vIn(:).' );
    if numel(vOut) < targetLen
        vOut(end+1:targetLen) = true;
    elseif numel(vOut) > targetLen
        vOut = vOut(1:targetLen);
    end
end
end
