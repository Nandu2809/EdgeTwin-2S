function [cleaned_vec, is_valid] = preprocess_signals(raw_vec, limits)
%PREPROCESS_SIGNALS Validate sensor readings [P_lp, P_hp, T_ic, rpm].
%#codegen

p_lp = raw_vec(1);
p_hp = raw_vec(2);
t_ic = raw_vec(3);
rpm  = raw_vec(4);

in_lp  = (p_lp >= limits.lp_pressure_bar(1)) && (p_lp <= limits.lp_pressure_bar(2));
in_hp  = (p_hp >= limits.hp_pressure_bar(1)) && (p_hp <= limits.hp_pressure_bar(2));
in_t   = (t_ic >= limits.temp_c(1))          && (t_ic <= limits.temp_c(2));
in_rpm = (rpm  >= limits.rpm_range(1))       && (rpm  <= limits.rpm_range(2));

is_valid = all(isfinite(raw_vec)) && in_lp && in_hp && in_t && in_rpm;
cleaned_vec = raw_vec;
end