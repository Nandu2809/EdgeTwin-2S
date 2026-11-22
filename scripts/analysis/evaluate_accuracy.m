function acc_pct = evaluate_accuracy(cfg)
%EVALUATE_ACCURACY Benchmark diagnostic logic on synthetic test scenarios.

rng(42);
n_trials = 200;
true_codes = randi([0, 3], n_trials, 1);
pred_codes = zeros(n_trials, 1);

for i = 1:n_trials
    switch true_codes(i)
        case 0 % Normal
            x = [2.2, 7.8, 85.0, 1485];
        case 1 % Overtemp
            x = [2.2, 8.0, 142.0, 1485];
        case 2 % Overpressure
            x = [2.4, 11.2, 95.0, 1485];
        case 3 % Low pressure ratio (valve degradation)
            x = [3.5, 5.0, 90.0, 1485];
    end
    [cx, ok] = preprocess_signals(x, cfg.limits);
    [pred_codes(i), ~, ~] = diagnose_fault_and_actuate(cx(1), cx(2), cx(3), cx(4), ok, [0 0 0 0], cfg.thresh);
end

acc_pct = mean(pred_codes == true_codes) * 100;
fprintf('Diagnostic validation accuracy: %.2f%% (%d/%d)\n', acc_pct, sum(pred_codes == true_codes), n_trials);
end