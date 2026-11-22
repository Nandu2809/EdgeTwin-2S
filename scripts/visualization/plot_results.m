function plot_results(acc_pct, act_cmd, act_fb)
%PLOT_RESULTS Generate summary bar chart of supervisory commands vs feedback.

figure('Name', 'EdgeSentinel Supervisory Actuator Status', 'NumberTitle', 'off');
labels = {'MotorStop', 'Unloader', 'CoolingFan', 'Drain'};
bar([act_cmd(:), act_fb(:)]);
set(gca, 'XTickLabel', labels);
ylim([0, 1.25]);
ylabel('State (0 / 1)');
legend('Command', 'Feedback', 'Location', 'northwest');
title(sprintf('Actuator Command vs. Feedback | Validation Accuracy: %.1f%%', acc_pct));
grid on;
end