function [telemetry, truth] = step_compressor_twin(t, scenario, act_fb, params)
%STEP_COMPRESSOR_TWIN Continuous 2-stage reciprocating compressor twin step.
% Supports NORMAL, OVERTEMP_IC, OVERPRESSURE_HP, OVERSPEED_RPM,
% HIGH_VIBRATION, VALVE_LEAKAGE, MULTI_ABNORMAL, SENSOR_FAULT, and CUSTOM.

if nargin < 4 || ~isstruct(params)
    params = struct();
end
if ~isfield(params, 'r'), params.r = 0.045; end
if ~isfield(params, 'L'), params.L = 0.180; end
if ~isfield(params, 'phase_hp'), params.phase_hp = pi/2; end

if numel(act_fb) < 4
    act_fb = [0 0 0 0 0];
elseif numel(act_fb) < 5
    act_fb = [act_fb(:)' 0];
end

% Continuous crank angle and slider-crank piston positions (mm)
rpm_nom = 1485;
if act_fb(1) > 0.1
    rpm_nom = rpm_nom * max(0, 1 - act_fb(1));
elseif numel(act_fb) >= 5 && act_fb(5) > 0.1
    rpm_nom = rpm_nom * max(0, 1 - min(0.35, 0.22 * act_fb(5)));
end
omega = rpm_nom * 2 * pi / 60;
theta = omega * t;
r = params.r; L = params.L;
x_lp_m = r * (1 - cos(theta)) + (r^2 / (4*L)) * (1 - cos(2*theta));
theta_hp = theta + params.phase_hp;
x_hp_m = r * (1 - cos(theta_hp)) + (r^2 / (4*L)) * (1 - cos(2*theta_hp));

% Base nominal 2-stage reciprocating compressor state
rpm_val  = rpm_nom + 6 * sin(2*pi*0.5*t) + 1.8 * randn();
p_lp_val = 2.35 + 0.14 * sin(2*pi*2.0*t) + 0.02 * randn();
p_hp_val = 8.10 + 0.28 * sin(2*pi*2.0*t + pi/2) + 0.04 * randn();
t_ic_val = 86.0 + 1.4 * sin(2*pi*0.12*t) + 0.25 * randn();
vib_val  = 1.85 + 0.14 * sin(2*pi*4.0*t) + 0.05 * randn();
curr_val = 24.2 + 0.55 * sin(2*pi*1.0*t) + 0.12 * randn();

fault_code      = 0;
fault_label     = 'NORMAL';
fault_subsystem = 'None (All Subsystems Nominal)';

switch upper(strtrim(string(scenario)))
    case "OVERTEMP_IC"
        t_ic_val        = 165.0 + 2.5 * sin(2*pi*0.2*t) + 0.35 * randn();
        p_hp_val        = p_hp_val + 0.85;
        curr_val        = curr_val + 1.8;
        fault_code      = 1;
        fault_label     = 'F-02: High Temp (Intercooler)';
        fault_subsystem = 'Intercooler (Stage 1->2 Heat Exchanger)';
    case "OVERPRESSURE_HP"
        p_hp_val        = 12.80 + 0.28 * sin(2*pi*1.5*t) + 0.05 * randn();
        curr_val        = 32.5 + 0.35 * randn();
        t_ic_val        = t_ic_val + 12.0;
        fault_code      = 2;
        fault_label     = 'F-03: High Press (HP Discharge)';
        fault_subsystem = 'HP Cylinder & Discharge Line';
    case "OVERSPEED_RPM"
        rpm_val         = 1980 + 20 * sin(2*pi*0.8*t) + 3.5 * randn();
        vib_val         = 4.80 + 0.25 * sin(2*pi*5.0*t) + 0.08 * randn();
        p_hp_val        = p_hp_val + 0.95;
        curr_val        = curr_val + 2.8;
        fault_code      = 5;
        fault_label     = 'F-05: High Speed (Shaft Overspeed)';
        fault_subsystem = 'Motor Drive & Crankshaft Train';
    case "HIGH_VIBRATION"
        vib_val         = 8.40 + 0.40 * sin(2*pi*4.5*t) + 0.12 * randn();
        curr_val        = 29.5 + 0.45 * randn();
        t_ic_val        = t_ic_val + 9.5;
        fault_code      = 6;
        fault_label     = 'F-06: High Vibration (Mechanical/Imbalance)';
        fault_subsystem = 'Crankshaft / Bearings / Mounting';
    case "VALVE_LEAKAGE"
        p_lp_val        = 3.85 + 0.14 * randn();
        p_hp_val        = 4.60 + 0.18 * randn();
        t_ic_val        = 124.5 + 0.45 * randn();
        vib_val         = 3.80 + 0.20 * randn();
        fault_code      = 3;
        fault_label     = 'F-01: Valve Leakage / Ratio Drop';
        fault_subsystem = 'LP / HP Suction & Discharge Valves';
    case "MULTI_ABNORMAL"
        t_ic_val        = 172.0 + 0.5 * randn();
        vib_val         = 8.60 + 0.35 * randn();
        curr_val        = 36.5 + 0.4 * randn();
        p_hp_val        = 13.10 + 0.20 * randn();
        rpm_val         = 1880 + 15 * randn();
        fault_code      = 1;
        fault_label     = 'MULTI: High Temp + Vib + Press/Load';
        fault_subsystem = 'Intercooler + Crank/Bearing + HP/Motor';
    case "SENSOR_FAULT"
        if isfield(params, 'sensor_fault_nan') && params.sensor_fault_nan
            p_hp_val        = NaN;
        elseif isfield(params, 'sensor_fault_val')
            p_hp_val        = params.sensor_fault_val;
        else
            p_hp_val        = -99.9;
        end
        fault_code      = 4;
        fault_label     = 'SENSOR: HP Pressure Transducer Fault';
        fault_subsystem = 'Measurement Interface (HP Pressure Ch)';
    case "CUSTOM"
        if isfield(params, 'custom_sensors') && isstruct(params.custom_sensors)
            cs = params.custom_sensors;
            if isfield(cs, 't_ic_c'),                              t_ic_val = cs.t_ic_c; end
            if isfield(cs, 'p_hp_bar'),                            p_hp_val = cs.p_hp_bar; end
            if isfield(cs, 'p_lp_bar') && isfinite(cs.p_lp_bar),   p_lp_val = cs.p_lp_bar; end
            if isfield(cs, 'rpm') && isfinite(cs.rpm),             rpm_val  = cs.rpm; end
            if isfield(cs, 'vib_mm_s') && isfinite(cs.vib_mm_s),   vib_val  = cs.vib_mm_s; end
            if isfield(cs, 'current_a') && isfinite(cs.current_a), curr_val = cs.current_a; end
        end
        % Reserve sensor fault strictly for non-finite or impossible electrical codes
        is_sensor_fault = ~isfinite(p_hp_val) || (p_hp_val < -50) || ~isfinite(t_ic_val) || (t_ic_val < -50) || ~isfinite(rpm_val) || (rpm_val < 0);
        if is_sensor_fault
            fault_code      = 4;
            fault_label     = 'CUSTOM: Sensor Transducer Fault';
            fault_subsystem = 'Measurement Interface';
        elseif t_ic_val > 135
            fault_code      = 1;
            fault_label     = 'CUSTOM: High Temp (Intercooler)';
            fault_subsystem = 'Intercooler';
        elseif p_hp_val > 10.5
            fault_code      = 2;
            fault_label     = 'CUSTOM: Overpressure (HP)';
            fault_subsystem = 'HP Stage Head & Receiver';
        elseif (p_hp_val / max(p_lp_val, 0.1)) < 2.2
            fault_code      = 3;
            fault_label     = 'CUSTOM: Valve Leakage';
            fault_subsystem = 'Valve Plates';
        elseif rpm_val > 1650
            fault_code      = 5;
            fault_label     = 'CUSTOM: Overspeed';
            fault_subsystem = 'Motor Drive';
        elseif vib_val > 4.5
            fault_code      = 6;
            fault_label     = 'CUSTOM: High Vibration';
            fault_subsystem = 'Crankcase & Bearings';
        else
            fault_code      = 0;
            fault_label     = 'CUSTOM: Nominal Injection';
            fault_subsystem = 'Custom User Test Vectors';
        end
end

% Apply supervisory actuator feedback [MotorStop, Unloader, CoolingFan, Drain, SpeedTrim]
if act_fb(1) > 0.1
    stop_f   = min(1, act_fb(1));
    rpm_val  = rpm_val * (1 - stop_f);
    p_lp_val = 1.01 + (p_lp_val - 1.01) * (1 - stop_f);
    p_hp_val = 1.01 + (p_hp_val - 1.01) * (1 - stop_f);
    curr_val = curr_val * (1 - stop_f);
    vib_val  = 0.25 + (vib_val - 0.25) * (1 - stop_f);
end
if act_fb(2) > 0.1 && isfinite(p_hp_val) && p_hp_val > -50
    p_hp_val = max(1.05, p_hp_val - 5.5 * act_fb(2));
    curr_val = max(6.0,  curr_val - 12.0 * act_fb(2));
    vib_val  = max(0.5,  vib_val - 2.8 * act_fb(2));
end
if act_fb(3) > 0.1 && isfinite(t_ic_val) && t_ic_val > -50
    if t_ic_val > 500
        t_ic_val = max(45.0, t_ic_val * (1 - 0.65 * act_fb(3)));
    else
        t_ic_val = max(45.0, t_ic_val - 52.0 * act_fb(3));
    end
end
if act_fb(4) > 0.1 && isfinite(p_hp_val) && p_hp_val > -50
    p_hp_val = max(1.05, p_hp_val - 1.8 * act_fb(4));
    p_lp_val = max(1.01, p_lp_val - 1.0 * act_fb(4));
    vib_val  = max(0.5,  vib_val - 2.2 * act_fb(4));
end
if numel(act_fb) >= 5 && act_fb(5) > 0.1
    trim_f   = min(0.35, 0.22 * act_fb(5));
    rpm_val  = max(0, rpm_val * (1 - trim_f));
    curr_val = max(5.0, curr_val * (1 - 0.18 * act_fb(5)));
    vib_val  = max(0.5, vib_val - 2.5 * act_fb(5));
end

telemetry.timestamp   = datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss.SSS');
telemetry.source      = 'simulated';
telemetry.machine_id  = 'compressor-001';
telemetry.t_s         = t;
telemetry.x_lp_mm     = x_lp_m * 1000;
telemetry.x_hp_mm     = x_hp_m * 1000;
telemetry.p_lp_bar    = p_lp_val;
telemetry.p_hp_bar    = p_hp_val;
telemetry.t_ic_c      = t_ic_val;
telemetry.rpm         = rpm_val;
telemetry.vib_mm_s    = vib_val;
telemetry.current_a   = curr_val;

% Quarantined ground truth (never fed into sensor observation vector)
truth.fault_code      = fault_code;
truth.fault_label     = fault_label;
truth.fault_subsystem = fault_subsystem;
end
