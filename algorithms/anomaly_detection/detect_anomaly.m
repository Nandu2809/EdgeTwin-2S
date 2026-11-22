function anomaly_flag = detect_anomaly(vec, is_valid, thresh)
%DETECT_ANOMALY Flag abnormal compressor operating conditions.
%#codegen

if ~is_valid
    anomaly_flag = 1;
    return;
end

p_lp  = vec(1);
p_hp  = vec(2);
t_ic  = vec(3);
ratio = p_hp / max(p_lp, 0.1);

if (p_hp > thresh.overpressure_bar) || (t_ic > thresh.overtemp_c) || (ratio < thresh.min_stage_ratio)
    anomaly_flag = 1;
else
    anomaly_flag = 0;
end
end