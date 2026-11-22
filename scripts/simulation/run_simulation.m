%% Run EdgeSentinel Simulation & Pipeline
cfg = init_edgesentinel();

modelName = string(cfg.model_name);

if exist(modelName, 'file') == 4
    %simOut = sim(modelName, 'StopTime', cfg.stop_time); %#ok<NASGU>
    %disp('Simulink model executed.');
else
    warning('Model %s not found on path; running standalone pipeline check.', modelName);
end

sample_vec = [2.2, 8.0, 142.0, 1490];
[clean_vec, is_valid] = preprocess_signals(sample_vec, cfg.limits);
anom = detect_anomaly(clean_vec, is_valid, cfg.thresh); %#ok<NASGU>
[f_code, cmd, fb] = diagnose_fault_and_actuate( ...
    clean_vec(1), clean_vec(2), clean_vec(3), clean_vec(4), ...
    is_valid, [0 0 0 0], cfg.thresh);

acc = evaluate_accuracy(cfg);
plot_results(acc, cmd, fb);

if cfg.ts.enable_upload && cfg.ts.channel_id > 0 && ~isempty(cfg.ts.write_key)
    thingSpeakWrite(cfg.ts.channel_id, [clean_vec, f_code, cmd(2), cmd(3)], ...
        'WriteKey', cfg.ts.write_key);
    disp('ThingSpeak telemetry sent.');
end
