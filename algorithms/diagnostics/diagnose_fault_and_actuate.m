function [fault_code, act_cmd, act_fb] = diagnose_fault_and_actuate(p_lp, p_hp, t_ic, rpm, is_valid, prev_fb, thresh)
%DIAGNOSE_FAULT_AND_ACTUATE Classify fault and compute supervisory actuator commands.
% fault_code: 0=Normal, 1=Overtemp, 2=Overpressure, 3=Valve/Stage Drop, 4=Sensor Invalid
% act_cmd:    [motor_stop, unloader, cooling_fan, condensate_drain]
%#codegen

if nargin < 7
    thresh.overtemp_c       = 135;
    thresh.overpressure_bar = 10.5;
    thresh.min_stage_ratio  = 2.2;
end
if nargin < 6
    prev_fb = [0 0 0 0];
end
if nargin < 5
    is_valid = true;
end

fault_code = 0;
motor_stop = 0;
unloader   = 0;
fan_on     = 0;
drain_open = 0;

% Reserve SENSOR_FAULT strictly for corrupt/invalid readings:
% Non-finite (NaN, Inf) or negative transducer fault codes (e.g. -99.9), negative pressures/rpm
sensor_corrupt = ~isfinite(p_lp) || ~isfinite(p_hp) || ~isfinite(t_ic) || ~isfinite(rpm) || ...
                 (p_hp < -50) || (p_lp < 0) || (t_ic < -50) || (rpm < 0);

if sensor_corrupt
    fault_code = 4;
    unloader   = 1;
    fan_on     = 1;
elseif p_hp > thresh.overpressure_bar
    fault_code = 2;
    motor_stop = 1;
    unloader   = 1;
    fan_on     = 1;
elseif t_ic > thresh.overtemp_c
    fault_code = 1;
    unloader   = 1;
    fan_on     = 1;
elseif (p_hp / max(p_lp, 0.1)) < thresh.min_stage_ratio
    fault_code = 3;
    unloader   = 1;
    drain_open = 1;
end

act_cmd = [motor_stop, unloader, fan_on, drain_open];
act_fb  = prev_fb + 0.25 .* (act_cmd - prev_fb);
end
