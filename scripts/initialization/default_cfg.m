function cfg = default_cfg()
%DEFAULT_CFG Returns default configuration structure for EdgeSentinel.

if exist('init_edgesentinel', 'file') == 2
    cfg = init_edgesentinel();
else
    cfg = struct();
    cfg.model_name = 'EdgeSentinel_Compressor_Twin_arch';
    cfg.stop_time  = '0.2';
    
    cfg.params.crank_radius     = 0.045;
    cfg.params.conn_rod_len     = 0.18;
    cfg.params.hp_phase_offset  = pi/2;
    cfg.params.omega_sync       = 157.08;
    cfg.params.s_breakdown      = 0.20;
    cfg.params.max_motor_torque = 240;
    
    cfg.limits.lp_pressure_bar = [0.8, 4.5];
    cfg.limits.hp_pressure_bar = [3.0, 12.0];
    cfg.limits.temp_c          = [15, 160];
    cfg.limits.rpm_range       = [0, 1650];
    
    cfg.thresh.overtemp_c       = 135;
    cfg.thresh.overpressure_bar = 10.5;
    cfg.thresh.min_stage_ratio  = 2.2;
    
    cfg.ts.enable_upload = false;
    cfg.ts.channel_id    = 0;
    cfg.ts.write_key     = '';
end

if exist('normalize_cfg', 'file') == 2
    cfg = normalize_cfg(cfg);
end
end
