function fig = EdgeSentinel_Dashboard(cfg)
%EDGESENTINEL_DASHBOARD Industrial SCADA/HMI prototype for 2-stage compressor.
% Features:
% - Responsive & scrollable full-screen & windowed layout (zero clipping on any DPI)
% - Direct quick-select scenario controls (Normal, High Temp, Overpress, etc.)
% - Abnormal graph highlighting (vivid markers & alert background) with clean reset
% - Dynamic Affected Machine Part, Potential Impact & Advisory UI readouts with large fonts
% - Interactive, clickable telemetry graphs with sample inspection banner & cursor
% - Arbitrary custom sensor injection with extreme thermal condition support (2000°C)
% - Closed-loop supervisory actuators with ACK audit logging & persistent event store

thisDir = fileparts(mfilename('fullpath'));
if ~isempty(thisDir)
    rootDir = fileparts(thisDir);
else
    rootDir = pwd;
end
addpath(genpath(rootDir));

if nargin < 1 || ~isstruct(cfg)
    if exist('init_edgesentinel', 'file') == 2
        cfg = init_edgesentinel();
    else
        cfg = default_cfg();
    end
end
cfg = normalize_cfg(cfg);

% Clean up previous instances and timers
oldFig = findall(0, 'Type', 'figure', 'Tag', 'EdgeSentinel_HMI_Fig');
if ~isempty(oldFig), delete(oldFig); end
oldTmr = timerfindall('Tag', 'EdgeSentinel_HMI_Timer');
if ~isempty(oldTmr), stop(oldTmr); delete(oldTmr); end

nl = string(newline);
cBg   = [0.06 0.08 0.11];
cCard = [0.11 0.14 0.19];
cSub  = [0.22 0.27 0.36];

% Adaptive initial figure sizing based on host screen
screenSize = get(0, 'ScreenSize'); % [x y width height]
screenW = screenSize(3);
screenH = screenSize(4);
figW = min(1440, max(960, screenW - 40));
figH = min(860,  max(640, screenH - 80));
figX = max(10, round((screenW - figW) / 2));
figY = max(35, round((screenH - figH) / 2));

fig = uifigure('Name', 'EdgeSentinel // Industrial Compressor SCADA-HMI', ...
    'Tag', 'EdgeSentinel_HMI_Fig', ...
    'Position', [figX figY figW figH], ...
    'Color', cBg, ...
    'AutoResizeChildren', 'off', ...
    'CloseRequestFcn', @onClose);

% Master Scrollable Root Container (guarantees accessibility on all resolutions)
rootScroll = uipanel(fig, ...
    'Position', [0 0 figW figH], ...
    'Scrollable', 'on', ...
    'BorderType', 'none', ...
    'BackgroundColor', cBg, ...
    'AutoResizeChildren', 'off');

% State struct initialization
state = struct();
state.t = 0;
state.dt = 0.25;
state.running = false;
state.scenario = 'NORMAL';
state.rec_action = 'NONE';
state.act_cmd = [0 0 0 0 0];
state.act_fb  = [0 0 0 0 0];
state.cmd_seq = 0;
state.last_cmd_sig = '';
state.last_cmd_time = datetime.empty;
state.last_ts_push = datetime('1970-01-01 00:00:00');
state.ts_interval_s = 16;
state.ts_buffer = {};
state.history_t = [];
state.history_p_hp = [];
state.history_t_ic = [];
state.history_vib = [];
state.history_curr = [];
state.history_anom = [];
state.inspect_t = NaN;
state.in_render = false;
state.cmd_log = {};
state.event_rows = {};
state.cfg = cfg;
state.rootDir = rootDir;
state.custom_sensors = struct('t_ic_c', 86.0, 'p_hp_bar', 8.10, 'rpm', 1485, 'vib_mm_s', 1.85, 'current_a', 24.2, 'p_lp_bar', 2.35);
state.last_tel = struct();

% --- TOP HEADER BAR ---
hdr = uipanel(rootScroll, 'Position', [10 800 min(1420, figW - 20) 42], 'BackgroundColor', cCard, 'BorderType', 'line', 'HighlightColor', [0.22 0.28 0.36]);
lblTitleApp  = uilabel(hdr, 'Position', [14 7 480 28], 'Text', 'EDGESENTINEL  |  COMPRESSOR UNIT-01 SUPERVISORY HMI', 'FontSize', 14, 'FontWeight', 'bold', 'FontColor', [0.94 0.97 1.0]);
lblModeBadge = uilabel(hdr, 'Position', [500 9 180 24], 'Text', 'MODE: SIMULATED TWIN (NO HW)', 'FontSize', 11, 'FontWeight', 'bold', 'FontColor', [0.35 0.85 0.98]);
lblMachineHealth = uilabel(hdr, 'Position', [690 9 370 24], 'Text', '● STATUS: NOMINAL  |  ALL CHANNELS HEALTHY', 'FontSize', 12.5, 'FontWeight', 'bold', 'FontColor', [0.25 0.92 0.48]);
lblClock = uilabel(hdr, 'Position', [1070 9 170 24], 'Text', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), 'FontSize', 11.5, 'FontColor', [0.76 0.82 0.90], 'HorizontalAlignment', 'right');

% --- COLUMN 1: PROCESS STREAM & SCENARIO CONTROLS ---
simPanel = uipanel(rootScroll, 'Title', 'Process Stream & Scenario Controls', 'Position', [10 354 310 496], ...
    'BackgroundColor', cCard, 'ForegroundColor', [0.88 0.93 1.0], 'FontWeight', 'bold', 'Scrollable', 'off');

% Quick Scenario Buttons (1-click access in full-screen & windowed modes)
uilabel(simPanel, 'Position', [8 444 200 18], 'Text', 'QUICK SCENARIOS (1-CLICK):', 'FontWeight', 'bold', 'FontSize', 10, 'FontColor', [0.82 0.88 0.98]);
btnScenNorm   = uibutton(simPanel, 'push', 'Position', [8   416 69 24], 'Text', 'Normal',     'BackgroundColor', [0.18 0.22 0.29], 'FontColor', [0.85 0.92 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) selectScenario('NORMAL'));
btnScenOverT  = uibutton(simPanel, 'push', 'Position', [81  416 69 24], 'Text', 'High Temp',  'BackgroundColor', [0.18 0.22 0.29], 'FontColor', [0.85 0.92 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) selectScenario('OVERTEMP_IC'));
btnScenOverP  = uibutton(simPanel, 'push', 'Position', [154 416 69 24], 'Text', 'Overpress',  'BackgroundColor', [0.18 0.22 0.29], 'FontColor', [0.85 0.92 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) selectScenario('OVERPRESSURE_HP'));
btnScenSpeed  = uibutton(simPanel, 'push', 'Position', [227 416 69 24], 'Text', 'Overspeed',  'BackgroundColor', [0.18 0.22 0.29], 'FontColor', [0.85 0.92 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) selectScenario('OVERSPEED_RPM'));

btnScenVib    = uibutton(simPanel, 'push', 'Position', [8   388 69 24], 'Text', 'High Vib',   'BackgroundColor', [0.18 0.22 0.29], 'FontColor', [0.85 0.92 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) selectScenario('HIGH_VIBRATION'));
btnScenLeak   = uibutton(simPanel, 'push', 'Position', [81  388 69 24], 'Text', 'Valve Leak', 'BackgroundColor', [0.18 0.22 0.29], 'FontColor', [0.85 0.92 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) selectScenario('VALVE_LEAKAGE'));
btnScenMulti  = uibutton(simPanel, 'push', 'Position', [154 388 69 24], 'Text', 'Multi-Fault','BackgroundColor', [0.18 0.22 0.29], 'FontColor', [0.85 0.92 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) selectScenario('MULTI_ABNORMAL'));
btnScenFault  = uibutton(simPanel, 'push', 'Position', [227 388 69 24], 'Text', 'Sens Fault', 'BackgroundColor', [0.18 0.22 0.29], 'FontColor', [0.85 0.92 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) selectScenario('SENSOR_FAULT'));

% Scenario Dropdown & Custom Button (synchronized with buttons)
allScenarios = {'NORMAL','OVERTEMP_IC','OVERPRESSURE_HP','OVERSPEED_RPM','HIGH_VIBRATION','VALVE_LEAKAGE','MULTI_ABNORMAL','SENSOR_FAULT','CUSTOM'};
uilabel(simPanel, 'Position', [8 359 56 22], 'Text', 'Scenario:', 'FontSize', 10, 'FontWeight', 'bold', 'FontColor', [0.80 0.86 0.94]);
ddScenario = uidropdown(simPanel, 'Position', [66 358 154 24], 'Items', allScenarios, 'Value', 'NORMAL', ...
    'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 10, 'ValueChangedFcn', @(src, ~) selectScenario(src.Value));
btnScenCustom = uibutton(simPanel, 'push', 'Position', [225 358 71 24], 'Text', 'Custom', 'BackgroundColor', [0.18 0.22 0.29], 'FontColor', [0.85 0.92 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) onApplyCustom());

scenBtns = [btnScenNorm, btnScenOverT, btnScenOverP, btnScenSpeed, btnScenVib, btnScenLeak, btnScenMulti, btnScenFault, btnScenCustom];
scenKeys = {'NORMAL','OVERTEMP_IC','OVERPRESSURE_HP','OVERSPEED_RPM','HIGH_VIBRATION','VALVE_LEAKAGE','MULTI_ABNORMAL','SENSOR_FAULT','CUSTOM'};

% --- CUSTOM SENSOR VALUES / ARBITRARY COMBINATION PANEL ---
pnlCustom = uipanel(simPanel, 'Title', 'Custom Sensor Values & Arbitrary Injection', 'Position', [6 168 296 184], ...
    'BackgroundColor', [0.09 0.12 0.17], 'ForegroundColor', [0.55 0.82 1.0], 'FontWeight', 'bold', 'BorderType', 'line', 'HighlightColor', [0.24 0.35 0.48]);

lblCustomMode = uilabel(pnlCustom, 'Position', [8 142 278 16], 'Text', '● MODE: DIGITAL TWIN (NORMAL)', 'FontSize', 9.5, 'FontWeight', 'bold', 'FontColor', [0.25 0.92 0.48]);

uilabel(pnlCustom, 'Position', [6 119 46 20], 'Text', 'Preset:', 'FontSize', 9.5, 'FontColor', [0.78 0.85 0.94]);
presetItems = {'-- Select Combination Preset --', ...
    '1. High Temp Overheat (2000°C Thermal Runaway)', ...
    '2. Compound: High Temp (165°C) + High Press (12.8 bar)', ...
    '3. Compound: High Vib (8.4 mm/s) + Overspeed (1980 RPM)', ...
    '4. Compound: Valve Leak (Ratio 1.19) + Hot Recirc', ...
    '5. Extreme: 4-Way Overload (Temp+Press+Vib+Speed)', ...
    '6. Marginal: Near Prototype Thresholds (132°C / 10.4 bar)', ...
    '7. Fault: Transducer Broken/Open (-99.9)', ...
    '8. Fault: Transducer Missing (NaN)', ...
    '9. Reset to Nominal Baseline'};
ddCustomPresets = uidropdown(pnlCustom, 'Position', [54 118 234 22], 'Items', presetItems, 'Value', presetItems{1}, ...
    'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 9, 'ValueChangedFcn', @onPresetSelected);

% 6 Sensor Fields (2 columns)
uilabel(pnlCustom, 'Position', [6 93 48 18], 'Text', 'T_ic(°C):', 'FontSize', 9, 'FontColor', [0.76 0.84 0.94]);
efCustomTic = uieditfield(pnlCustom, 'numeric', 'Position', [56 92 80 20], 'Value', 86.0, 'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 9.5);

uilabel(pnlCustom, 'Position', [6 69 48 18], 'Text', 'P_hp(bar):', 'FontSize', 9, 'FontColor', [0.76 0.84 0.94]);
efCustomPhp = uieditfield(pnlCustom, 'numeric', 'Position', [56 68 80 20], 'Value', 8.10, 'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 9.5);

uilabel(pnlCustom, 'Position', [6 45 48 18], 'Text', 'P_lp(bar):', 'FontSize', 9, 'FontColor', [0.76 0.84 0.94]);
efCustomPlp = uieditfield(pnlCustom, 'numeric', 'Position', [56 44 80 20], 'Value', 2.35, 'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 9.5);

uilabel(pnlCustom, 'Position', [144 93 46 18], 'Text', 'RPM:', 'FontSize', 9, 'FontColor', [0.76 0.84 0.94]);
efCustomRpm = uieditfield(pnlCustom, 'numeric', 'Position', [192 92 94 20], 'Value', 1485, 'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 9.5);

uilabel(pnlCustom, 'Position', [144 69 46 18], 'Text', 'Vib(mm/s):', 'FontSize', 9, 'FontColor', [0.76 0.84 0.94]);
efCustomVib = uieditfield(pnlCustom, 'numeric', 'Position', [192 68 94 20], 'Value', 1.85, 'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 9.5);

uilabel(pnlCustom, 'Position', [144 45 46 18], 'Text', 'Curr(A):', 'FontSize', 9, 'FontColor', [0.76 0.84 0.94]);
efCustomCurr = uieditfield(pnlCustom, 'numeric', 'Position', [192 44 94 20], 'Value', 24.2, 'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 9.5);

% Quick fault buttons
btnFaultNeg99 = uibutton(pnlCustom, 'push', 'Position', [6 23 138 19], 'Text', 'Set HP: -99.9 (Fault)', 'FontSize', 8.5, ...
    'BackgroundColor', [0.42 0.20 0.20], 'FontColor', [1 1 1], 'ButtonPushedFcn', @(~,~) applyQuickFault(-99.9));
btnFaultNaN   = uibutton(pnlCustom, 'push', 'Position', [148 23 140 19], 'Text', 'Set HP: NaN (Fault)', 'FontSize', 8.5, ...
    'BackgroundColor', [0.42 0.20 0.20], 'FontColor', [1 1 1], 'ButtonPushedFcn', @(~,~) applyQuickFault(NaN));

% Action buttons
btnInjectCustom = uibutton(pnlCustom, 'push', 'Position', [6 2 138 20], 'Text', 'Inject Custom Values', 'FontSize', 8.5, 'FontWeight', 'bold', ...
    'BackgroundColor', [0.18 0.48 0.74], 'FontColor', [1 1 1], 'ButtonPushedFcn', @(~,~) onApplyCustom());
btnRandomMix    = uibutton(pnlCustom, 'push', 'Position', [148 2 140 20], 'Text', 'Random Mix Generator', 'FontSize', 8.5, 'FontWeight', 'bold', ...
    'BackgroundColor', [0.65 0.40 0.14], 'FontColor', [1 1 1], 'ButtonPushedFcn', @(~,~) onRandomMix());

% Stream transport buttons
btnStart = uibutton(simPanel, 'push', 'Position', [8  134 90 26], 'Text', 'Start Stream', 'BackgroundColor', [0.14 0.55 0.33], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @onStart);
btnStop  = uibutton(simPanel, 'push', 'Position', [102 134 90 26], 'Text', 'Pause',        'BackgroundColor', [0.65 0.44 0.12], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @onPause);
btnStep  = uibutton(simPanel, 'push', 'Position', [196 134 90 26], 'Text', 'Step Once',    'BackgroundColor', [0.20 0.43 0.68], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @onSingleStep);

uilabel(simPanel, 'Position', [8 104 54 20], 'Text', 'Step (s):', 'FontSize', 9.5, 'FontColor', [0.80 0.86 0.94]);
efPeriod = uieditfield(simPanel, 'numeric', 'Position', [64 103 48 22], 'Value', 0.35, 'Limits', [0.1 10], 'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 9.5, 'ValueChangedFcn', @onPeriodChanged);
lblPistonPos = uilabel(simPanel, 'Position', [118 101 178 26], 'Text', 'LP: +0.0mm | HP: +0.0mm  (t = 0.00s)', 'FontColor', [0.65 0.88 1.0], 'FontSize', 9.5);

lblRecAct = uilabel(simPanel, 'Position', [8 44 288 52], 'Text', 'RECOMMENDED ACTUATOR: NONE' + nl + 'Machine operating within normal limits.', ...
    'FontColor', [0.25 0.94 0.55], 'FontSize', 10, 'FontWeight', 'bold', 'WordWrap', 'on', 'VerticalAlignment', 'top');
btnExecRec = uibutton(simPanel, 'push', 'Position', [8 8 138 30], 'Text', 'Execute Rec. Action', 'BackgroundColor', [0.17 0.48 0.70], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) sendCommand(state.rec_action));
btnExportCsv = uibutton(simPanel, 'push', 'Position', [152 8 138 30], 'Text', 'Export CSV Log', 'BackgroundColor', [0.22 0.46 0.42], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @onExportCsv);

% --- COLUMN 1 LOWER: SUPERVISORY ACTUATORS & ACK LOG ---
actPanel = uipanel(rootScroll, 'Title', 'Supervisory Actuators & ACK Log', 'Position', [10 10 310 334], ...
    'BackgroundColor', cCard, 'ForegroundColor', [0.88 0.93 1.0], 'FontWeight', 'bold', 'Scrollable', 'off');
btnUnloader   = uibutton(actPanel, 'push', 'Position', [10  268 140 28], 'Text', 'Actuate Unloader [OFF]',   'BackgroundColor', [0.18 0.35 0.55], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) sendCommand('UNLOADER'));
btnCoolingFan = uibutton(actPanel, 'push', 'Position', [158 268 140 28], 'Text', 'Actuate CoolingFan [OFF]',  'BackgroundColor', [0.18 0.35 0.55], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) sendCommand('COOLING_FAN'));
btnDrain      = uibutton(actPanel, 'push', 'Position', [10  236 140 28], 'Text', 'Actuate Drain [OFF]',       'BackgroundColor', [0.18 0.35 0.55], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) sendCommand('DRAIN'));
btnSpeedTrim  = uibutton(actPanel, 'push', 'Position', [158 236 140 28], 'Text', 'VFD Speed Trim [OFF]',      'BackgroundColor', [0.18 0.35 0.55], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) sendCommand('SPEED_TRIM'));
btnMotorStop  = uibutton(actPanel, 'push', 'Position', [10  204 140 28], 'Text', 'Sim MotorStop [IDLE]',      'BackgroundColor', [0.55 0.22 0.22], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) sendCommand('MOTOR_STOP'));
btnReset      = uibutton(actPanel, 'push', 'Position', [158 204 140 28], 'Text', 'Reset All Actuators',       'BackgroundColor', [0.27 0.32 0.39], 'FontColor', [1 1 1], 'FontSize', 10, 'FontWeight', 'bold', 'ButtonPushedFcn', @(~,~) sendCommand('RESET'));
lblActState   = uilabel(actPanel, 'Position', [10 162 290 36], 'Text', 'Cmd [Stop Unld Fan Drn Trim]: [0 0 0 0 0]' + nl + 'Fb  [Stop Unld Fan Drn Trim]: [0 0 0 0 0]', 'FontColor', [0.90 0.94 0.98], 'FontSize', 10, 'FontWeight', 'bold', 'WordWrap', 'on', 'VerticalAlignment', 'top');
tblCmd        = uitable(actPanel, 'Position', [10 10 290 146], 'ColumnName', {'CmdID','Action','Lifecycle'}, 'ColumnWidth', {65, 105, 115}, 'Data', cell(0, 3), 'FontSize', 10);

% --- COLUMN 2: PROCESS SCHEMATIC & TELEMETRY ---
twinPanel = uipanel(rootScroll, 'Title', '2-Stage Reciprocating Compressor Process Schematic', 'Position', [330 520 600 250], 'BackgroundColor', cCard, 'ForegroundColor', [0.88 0.93 1.0], 'FontWeight', 'bold');
axTwin = uiaxes(twinPanel, 'Position', [8 8 584 216], 'BackgroundColor', cBg, 'XColor', 'none', 'YColor', 'none');
axis(axTwin, [0 100 0 44]); disableDefaultInteractivity(axTwin);

kpiPanel = uipanel(rootScroll, 'Title', 'Live Telemetry (Temp | Speed | Pressure | Vibration | Current)', 'Position', [330 418 600 92], 'BackgroundColor', cCard, 'ForegroundColor', [0.88 0.93 1.0], 'FontWeight', 'bold');
lblTIC  = uilabel(kpiPanel, 'Position', [8 42 190 26], 'Text', '1. Temp (IC): -- °C', 'FontSize', 11.5, 'FontWeight', 'bold', 'FontColor', [1.0 0.76 0.42]);
lblRPM  = uilabel(kpiPanel, 'Position', [202 42 190 26], 'Text', '2. Speed: -- RPM', 'FontSize', 11.5, 'FontWeight', 'bold', 'FontColor', [0.72 0.95 0.76]);
lblPHP  = uilabel(kpiPanel, 'Position', [396 42 190 26], 'Text', '3. Press (HP): -- bar', 'FontSize', 11.5, 'FontWeight', 'bold', 'FontColor', [0.65 0.88 1.0]);
lblVIB  = uilabel(kpiPanel, 'Position', [8 10 190 26], 'Text', '4. Vib: -- mm/s', 'FontSize', 11.5, 'FontWeight', 'bold', 'FontColor', [0.95 0.75 0.95]);
lblCURR = uilabel(kpiPanel, 'Position', [202 10 190 26], 'Text', '5. Current: -- A', 'FontSize', 11.5, 'FontWeight', 'bold', 'FontColor', [0.95 0.90 0.65]);
lblPLP  = uilabel(kpiPanel, 'Position', [396 10 190 26], 'Text', 'LP Stage: -- bar', 'FontSize', 11.5, 'FontWeight', 'bold', 'FontColor', [0.76 0.84 0.94]);

% Interactive Plot Inspection Banner
pnlInspect = uipanel(rootScroll, 'Position', [330 384 600 24], ...
    'BackgroundColor', [0.10 0.13 0.18], 'BorderType', 'line', 'HighlightColor', [0.24 0.35 0.48]);
lblPlotInspect = uilabel(pnlInspect, 'Position', [8 2 584 20], ...
    'Text', '🔍 INTERACTIVE GRAPH: Click any sample point on either plot to inspect instant telemetry, anomaly flag & affected part.', ...
    'FontSize', 10.5, 'FontWeight', 'bold', 'FontColor', [0.65 0.88 1.0]);

% Live dual-axis trend plots with abnormal highlight & click-to-inspect capability
ax1 = uiaxes(rootScroll, 'Position', [330 10 295 366], 'BackgroundColor', cBg, 'XColor', [0.76 0.82 0.90], 'ButtonDownFcn', @onPlotClick);
title(ax1, 'HP Press (L) & IC Temp (R)', 'Color', [0.92 0.95 1.0]); grid(ax1, 'on');
ax2 = uiaxes(rootScroll, 'Position', [635 10 295 366], 'BackgroundColor', cBg, 'XColor', [0.76 0.82 0.90], 'ButtonDownFcn', @onPlotClick);
title(ax2, 'Vib (L) & Current (R)', 'Color', [0.92 0.95 1.0]); grid(ax2, 'on');

% --- COLUMN 3: DIAGNOSTICS, AFFECTED PART & IMPACT READOUT ---
diagPanel = uipanel(rootScroll, 'Title', 'Machine Diagnostics, Subsystem Impact & Advisory', 'Position', [940 354 350 496], ...
    'BackgroundColor', cCard, 'ForegroundColor', [0.88 0.93 1.0], 'FontWeight', 'bold', 'Scrollable', 'off');

% Sub-Card 1: Machine Health & Metric Overview (Increased font size, filled proportionally)
pnlStatusCard = uipanel(diagPanel, 'Position', [10 382 330 88], 'BackgroundColor', [0.13 0.16 0.22], 'BorderType', 'line', 'HighlightColor', [0.24 0.30 0.40]);
lblStatusTitle = uilabel(pnlStatusCard, 'Position', [10 58 310 24], 'Text', '● STATUS: NOMINAL  |  ALL CHANNELS HEALTHY', 'FontSize', 12.5, 'FontWeight', 'bold', 'FontColor', [0.25 0.92 0.48]);
lblMetricsSummary = uilabel(pnlStatusCard, 'Position', [10 32 310 22], 'Text', 'Anom Flag: 0 | Fault Code: 0 | ML Prob: 0.00 (Rule/Threshold)', 'FontSize', 11, 'FontColor', [0.85 0.90 0.98]);
lblRatioContext = uilabel(pnlStatusCard, 'Position', [10 8 310 20], 'Text', 'Stage Compression Ratio (P_hp / P_lp): 3.48  [Nominal >= 2.20]', 'FontSize', 11, 'FontColor', [0.88 0.92 1.0]);

% Sub-Card 2: Affected Machine Part / Subsystem (Increased font size, filled proportionally)
pnlPartCard = uipanel(diagPanel, 'Position', [10 296 330 78], 'BackgroundColor', [0.13 0.16 0.22], 'BorderType', 'line', 'HighlightColor', [0.24 0.30 0.40]);
lblPartHeader = uilabel(pnlPartCard, 'Position', [10 52 310 20], 'Text', '● AFFECTED MACHINE PART / SUBSYSTEM', 'FontSize', 10.5, 'FontWeight', 'bold', 'FontColor', [0.42 0.85 1.0]);
lblAffectedPart = uilabel(pnlPartCard, 'Position', [10 6 310 44], 'Text', 'None — All Subsystems Nominal' + nl + 'Cylinders, Intercooler, Valves & Bearings Healthy', 'FontSize', 11.5, 'FontWeight', 'bold', 'FontColor', [1.0 1.0 1.0], 'WordWrap', 'on', 'VerticalAlignment', 'top');

% Sub-Card 3: Potential Impact & Operational Consequence (Increased font size, filled proportionally)
pnlImpactCard = uipanel(diagPanel, 'Position', [10 132 330 156], 'BackgroundColor', [0.13 0.16 0.22], 'BorderType', 'line', 'HighlightColor', [0.24 0.30 0.40]);
lblImpactHeader = uilabel(pnlImpactCard, 'Position', [10 130 310 20], 'Text', '● POTENTIAL MACHINE IMPACT & CONSEQUENCE', 'FontSize', 10.5, 'FontWeight', 'bold', 'FontColor', [1.0 0.82 0.35]);
lblImpactDesc = uilabel(pnlImpactCard, 'Position', [10 68 310 58], 'Text', 'Operating within thermodynamic and mechanical design limits. Stable 2-stage compression.', 'FontSize', 10.5, 'FontColor', [0.90 0.94 1.0], 'WordWrap', 'on', 'VerticalAlignment', 'top');
lblRecommendedFix = uilabel(pnlImpactCard, 'Position', [10 6 310 58], 'Text', 'Fix: No intervention required. System running nominally within configured prototype thresholds.', 'FontSize', 11, 'FontWeight', 'bold', 'FontColor', [0.35 0.94 0.65], 'WordWrap', 'on', 'VerticalAlignment', 'top');

% Sub-Card 4: Advisory Disclaimer (Increased font size, filled proportionally)
pnlAdvisoryCard = uipanel(diagPanel, 'Position', [10 20 330 104], 'BackgroundColor', [0.16 0.13 0.10], 'BorderType', 'line', 'HighlightColor', [0.55 0.38 0.16]);
lblAdvisoryHeader = uilabel(pnlAdvisoryCard, 'Position', [10 78 310 20], 'Text', '⚠ ADVISORY NOTICE (SIMULATED SCADA-HMI)', 'FontSize', 10.5, 'FontWeight', 'bold', 'FontColor', [1.0 0.78 0.28]);
lblAdvisoryBody = uilabel(pnlAdvisoryCard, 'Position', [10 6 310 68], 'Text', 'Simulated digital-twin advisory for testing/demonstration. Not an industrial safety interlock. Field compressors require independent hardwired SIL-3 emergency stops, physical PRVs, and certified PLCs.', 'FontSize', 9.5, 'FontColor', [0.92 0.88 0.80], 'WordWrap', 'on', 'VerticalAlignment', 'top');

lblDiag = uilabel(diagPanel, 'Position', [1 1 1 1], 'Visible', 'off');

% --- COLUMN 3 LOWER: THINGSPEAK CLOUD ---
tsPanel = uipanel(rootScroll, 'Title', 'ThingSpeak Cloud Telemetry', 'Position', [940 10 350 334], ...
    'BackgroundColor', cCard, 'ForegroundColor', [0.88 0.93 1.0], 'FontWeight', 'bold', 'Scrollable', 'off');
cbTsEnable = uicheckbox(tsPanel, 'Position', [14 280 320 22], 'Text', 'Enable ThingSpeak Cloud Sync', 'Value', false, 'FontSize', 11, 'FontColor', [0.92 0.96 1.0]);
lblTsCh = uilabel(tsPanel, 'Position', [14 246 90 22], 'Text', 'Channel ID:', 'FontSize', 10, 'FontColor', [0.80 0.86 0.94]);
initChStr = ''; if cfg.ts.channel_id > 0, initChStr = num2str(cfg.ts.channel_id); end
efTsCh = uieditfield(tsPanel, 'text', 'Position', [108 244 228 24], 'Value', initChStr, 'Placeholder', 'Type Channel ID & press Enter', 'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 10, 'ValueChangedFcn', @onTsInfo);
lblTsKey = uilabel(tsPanel, 'Position', [14 214 90 22], 'Text', 'Write API Key:', 'FontSize', 10, 'FontColor', [0.80 0.86 0.94]);
efTsKey = uieditfield(tsPanel, 'text', 'Position', [108 212 228 24], 'Value', cfg.ts.write_key, 'Placeholder', 'Type Write API Key & press Enter', 'BackgroundColor', cSub, 'FontColor', [1 1 1], 'FontSize', 10, 'ValueChangedFcn', @onTsInfo);
btnTsFlush = uibutton(tsPanel, 'push', 'Position', [14 172 154 28], 'Text', 'Flush Buffer Now', 'BackgroundColor', [0.19 0.44 0.65], 'FontColor', [1 1 1], 'FontSize', 10, 'ButtonPushedFcn', @(~,~) flushThingSpeak(true));
btnTsClear = uibutton(tsPanel, 'push', 'Position', [174 172 162 28], 'Text', 'Clear Buffer', 'BackgroundColor', [0.33 0.35 0.41], 'FontColor', [1 1 1], 'FontSize', 10, 'ButtonPushedFcn', @onClearBuffer);
lblTsStatus = uilabel(tsPanel, 'Position', [14 8 322 154], 'Text', 'Status: IDLE (Min cadence: 16s)' + nl + 'Buffered packets: 0' + nl + 'Last push: NEVER', 'FontColor', [0.82 0.90 0.98], 'FontSize', 10, 'WordWrap', 'on', 'VerticalAlignment', 'top');

% Timer setup
tmr = timer('ExecutionMode', 'fixedSpacing', 'Period', 0.35, 'Tag', 'EdgeSentinel_HMI_Timer', 'TimerFcn', @onTimerTick);

% Initial responsive layout execution & first step render
fig.SizeChangedFcn = @onFigResize;
relayout(figW, figH);
updateScenarioButtons('NORMAL');
updateActuatorButtons();
stepAndRender(false);

    % --- SCENARIO SELECTION HANDLER ---
    function selectScenario(scenName)
        state.scenario = scenName;
        ddScenario.Value = scenName;
        if strcmp(scenName, 'NORMAL')
            state.history_anom = zeros(size(state.history_t));
        end
        updateScenarioButtons(scenName);
        if strcmp(scenName, 'CUSTOM')
            lblCustomMode.Text = '● MODE: CUSTOM INJECTED READINGS';
            lblCustomMode.FontColor = [0.98 0.65 0.20];
        else
            lblCustomMode.Text = '● MODE: DIGITAL TWIN (' + string(scenName) + ')';
            lblCustomMode.FontColor = [0.25 0.92 0.48];
        end
        stepAndRender(true);
        syncCustomInputsFromTel();
    end

    function updateScenarioButtons(activeScen)
        for si = 1:numel(scenKeys)
            if strcmp(scenKeys{si}, activeScen)
                scenBtns(si).FontWeight = 'bold';
                scenBtns(si).BackgroundColor = [0.22 0.52 0.78];
                scenBtns(si).FontColor = [1 1 1];
            else
                scenBtns(si).FontWeight = 'normal';
                scenBtns(si).BackgroundColor = [0.16 0.20 0.27];
                scenBtns(si).FontColor = [0.82 0.88 0.94];
            end
        end
    end

    % --- RESPONSIVE LAYOUT MANAGER ---
    function onFigResize(~, ~)
        if ~isvalid(fig) || ~isvalid(rootScroll), return; end
        curPos = fig.Position;
        rootScroll.Position = [0 0 max(100, curPos(3)) max(100, curPos(4))];
        relayout(curPos(3), curPos(4));
    end

    function relayout(curW, curH)
        % Fit into screen horizontally: ZERO horizontal scrollbar under any resolution
        % 32px right padding guarantees room for vertical scrollbar without triggering horizontal scrolling
        usableW = max(860, curW - 32);
        contentH = max(840, curH);

        % Top Header Bar (spans full usable width)
        hdr.Position = [10, contentH - 46, usableW, 40];
        lblTitleApp.Position      = [12, 6, min(480, round(usableW * 0.38)), 28];
        lblModeBadge.Position     = [round(usableW * 0.39), 8, 180, 24];
        lblMachineHealth.Position = [round(usableW * 0.55), 8, min(360, round(usableW * 0.28)), 24];
        lblClock.Position         = [usableW - 175, 8, 165, 24];

        % Column 1 (Left): Controls & Actuators
        col1W = 310;
        col1X = 10;

        % Column 3 (Right): Diagnostics & ThingSpeak
        col3W = max(290, min(390, round(usableW * 0.28)));
        col3X = usableW - col3W + 10;

        % Column 2 (Middle): Process schematic, KPI, & Live plots
        col2X = col1X + col1W + 10;
        col2W = col3X - col2X - 10;

        topY = contentH - 54;

        % Column 1: Heights & Positioning
        simH = 496;
        simY = topY - simH;
        simPanel.Position = [col1X, simY, col1W, simH];

        actH = max(270, simY - 14);
        actPanel.Position = [col1X, 10, col1W, actH];

        % Actuator buttons (3 pairs of buttons)
        btnH = 28;
        r1Y = actH - 58;
        r2Y = actH - 90;
        r3Y = actH - 122;
        wBtn = floor((col1W - 28) / 2);
        btnUnloader.Position   = [10,             r1Y, wBtn, btnH];
        btnCoolingFan.Position = [10 + wBtn + 8, r1Y, wBtn, btnH];
        btnDrain.Position      = [10,             r2Y, wBtn, btnH];
        btnSpeedTrim.Position  = [10 + wBtn + 8, r2Y, wBtn, btnH];
        btnMotorStop.Position  = [10,             r3Y, wBtn, btnH];
        btnReset.Position      = [10 + wBtn + 8, r3Y, wBtn, btnH];

        lblActState.Position   = [10, actH - 164, col1W - 20, 36];
        tblCmd.Position        = [10, 8, col1W - 20, max(60, actH - 176)];

        % Column 3: Heights & Positioning
        diagH = 496;
        diagY = topY - diagH;
        diagPanel.Position = [col3X, diagY, col3W, diagH];

        cardW = col3W - 20;
        innerW = cardW - 24;

        % Diagnostics Sub-Cards: Perfectly proportioned to eliminate awkward empty voids
        % Card 1: Status & Metric Overview (h=88)
        c1H = 88;
        c1Y = diagH - 26 - c1H; % 496 - 26 - 88 = 382
        pnlStatusCard.Position     = [10, c1Y, cardW, c1H];
        lblStatusTitle.Position    = [10, 58, innerW, 24];
        lblMetricsSummary.Position = [10, 32, innerW, 22];
        lblRatioContext.Position   = [10, 8,  innerW, 20];

        % Card 2: Affected Machine Part / Subsystem (h=78)
        c2H = 78;
        c2Y = c1Y - 8 - c2H;    % 382 - 8 - 78 = 296
        pnlPartCard.Position       = [10, c2Y, cardW, c2H];
        lblPartHeader.Position     = [10, 52, innerW, 20];
        lblAffectedPart.Position   = [10, 6,  innerW, 44];

        % Card 3: Potential Impact & Consequence (h=156)
        c3H = 156;
        c3Y = c2Y - 8 - c3H;   % 296 - 8 - 156 = 132
        pnlImpactCard.Position     = [10, c3Y, cardW, c3H];
        lblImpactHeader.Position   = [10, 130, innerW, 20];
        lblImpactDesc.Position     = [10, 68,  innerW, 58];
        lblRecommendedFix.Position = [10, 6,   innerW, 58];

        % Card 4: Advisory Disclaimer (h=104)
        c4H = 104;
        c4Y = c3Y - 8 - c4H;   % 132 - 8 - 104 = 20
        pnlAdvisoryCard.Position   = [10, c4Y, cardW, c4H];
        lblAdvisoryHeader.Position = [10, 78, innerW, 20];
        lblAdvisoryBody.Position   = [10, 6,  innerW, 68];

        % ThingSpeak Panel (below diagPanel, responsive layout without internal scroll)
        tsH = max(240, diagY - 14);
        tsPanel.Position = [col3X, 10, col3W, tsH];

        tsW = col3W;
        cbTsEnable.Position  = [14, tsH - 46, tsW - 28, 22];
        lblTsCh.Position     = [14, tsH - 76, 85, 22];
        efTsCh.Position      = [102, tsH - 78, tsW - 116, 24];
        lblTsKey.Position    = [14, tsH - 106, 85, 22];
        efTsKey.Position     = [102, tsH - 108, tsW - 116, 24];

        wTsBtn = floor((tsW - 36) / 2);
        btnTsFlush.Position  = [14, tsH - 146, wTsBtn, 28];
        btnTsClear.Position  = [14 + wTsBtn + 8, tsH - 146, wTsBtn, 28];
        lblTsStatus.Position = [14, 8, tsW - 28, max(50, tsH - 160)];

        % Column 2: Heights & Positioning
        twinH = 246;
        twinY = topY - twinH;
        twinPanel.Position = [col2X, twinY, col2W, twinH];
        axTwin.Position = [6, 6, col2W - 12, twinH - 30];

        kpiH = 92;
        kpiY = twinY - kpiH - 8;
        kpiPanel.Position = [col2X, kpiY, col2W, kpiH];
        wKpiCol = floor((col2W - 20) / 3);
        lblTIC.Position  = [6,                  42, wKpiCol, 26];
        lblRPM.Position  = [6 + wKpiCol + 4,    42, wKpiCol, 26];
        lblPHP.Position  = [6 + 2*(wKpiCol + 4), 42, wKpiCol, 26];
        lblVIB.Position  = [6,                  10, wKpiCol, 26];
        lblCURR.Position = [6 + wKpiCol + 4,    10, wKpiCol, 26];
        lblPLP.Position  = [6 + 2*(wKpiCol + 4), 10, wKpiCol, 26];

        inspectH = 24;
        inspectY = kpiY - inspectH - 6;
        pnlInspect.Position = [col2X, inspectY, col2W, inspectH];
        lblPlotInspect.Position = [8, 2, col2W - 16, 20];

        plotH = max(180, inspectY - 18);
        plotW = max(180, floor((col2W - 10) / 2));
        ax1.Position = [col2X, 10, plotW, plotH];
        ax2.Position = [col2X + plotW + 10, 10, plotW, plotH];
    end

    % --- CALLBACK FUNCTIONS ---
    function onTsInfo(~, ~)
        flushThingSpeak(false);
    end
    function onPresetSelected(src, ~)
        val = src.Value;
        switch val
            case '1. High Temp Overheat (2000°C Thermal Runaway)'
                efCustomTic.Value  = 2000.0; efCustomPhp.Value  = 8.10;  efCustomPlp.Value  = 2.35;
                efCustomRpm.Value  = 1485;   efCustomVib.Value  = 1.85;  efCustomCurr.Value = 24.2;
            case '2. Compound: High Temp (165°C) + High Press (12.8 bar)'
                efCustomTic.Value  = 165.0;  efCustomPhp.Value  = 12.80; efCustomPlp.Value  = 2.35;
                efCustomRpm.Value  = 1485;   efCustomVib.Value  = 2.40;  efCustomCurr.Value = 32.5;
            case '3. Compound: High Vib (8.4 mm/s) + Overspeed (1980 RPM)'
                efCustomTic.Value  = 92.0;   efCustomPhp.Value  = 8.90;  efCustomPlp.Value  = 2.35;
                efCustomRpm.Value  = 1980;   efCustomVib.Value  = 8.40;  efCustomCurr.Value = 30.0;
            case '4. Compound: Valve Leak (Ratio 1.19) + Hot Recirc'
                efCustomTic.Value  = 124.5;  efCustomPhp.Value  = 4.60;  efCustomPlp.Value  = 3.85;
                efCustomRpm.Value  = 1480;   efCustomVib.Value  = 3.80;  efCustomCurr.Value = 25.0;
            case '5. Extreme: 4-Way Overload (Temp+Press+Vib+Speed)'
                efCustomTic.Value  = 172.0;  efCustomPhp.Value  = 13.10; efCustomPlp.Value  = 2.35;
                efCustomRpm.Value  = 1980;   efCustomVib.Value  = 8.80;  efCustomCurr.Value = 37.0;
            case '6. Marginal: Near Prototype Thresholds (132°C / 10.4 bar)'
                efCustomTic.Value  = 132.0;  efCustomPhp.Value  = 10.35; efCustomPlp.Value  = 2.35;
                efCustomRpm.Value  = 1640;   efCustomVib.Value  = 4.40;  efCustomCurr.Value = 26.5;
            case '7. Fault: Transducer Broken/Open (-99.9)'
                efCustomTic.Value  = 86.0;   efCustomPhp.Value  = -99.9; efCustomPlp.Value  = 2.35;
                efCustomRpm.Value  = 1485;   efCustomVib.Value  = 1.85;  efCustomCurr.Value = 24.2;
            case '8. Fault: Transducer Missing (NaN)'
                efCustomTic.Value  = 86.0;   efCustomPhp.Value  = NaN;   efCustomPlp.Value  = 2.35;
                efCustomRpm.Value  = 1485;   efCustomVib.Value  = 1.85;  efCustomCurr.Value = 24.2;
            case '9. Reset to Nominal Baseline'
                efCustomTic.Value  = 86.0;   efCustomPhp.Value  = 8.10;  efCustomPlp.Value  = 2.35;
                efCustomRpm.Value  = 1485;   efCustomVib.Value  = 1.85;  efCustomCurr.Value = 24.2;
            otherwise
                return;
        end
        onApplyCustom();
    end
    function applyQuickFault(faultVal)
        efCustomPhp.Value = faultVal;
        onApplyCustom();
    end
    function onRandomMix(~, ~)
        fDim = randperm(5, randi([1, 3]));
        t_ic = 82 + rand() * 10;
        p_hp = 7.8 + rand() * 0.8;
        p_lp = 2.2 + rand() * 0.3;
        rpm  = 1475 + rand() * 20;
        vib  = 1.6 + rand() * 0.5;
        curr = 23.5 + rand() * 1.5;
        for d = fDim
            switch d
                case 1, t_ic = 160 + rand() * 50;
                case 2, p_hp = 12.0 + rand() * 2.5;
                case 3, rpm  = 1850 + rand() * 250;
                case 4, vib  = 7.2 + rand() * 3.0;
                case 5, p_lp = 3.6 + rand() * 0.5; p_hp = 4.4 + rand() * 0.5;
            end
        end
        efCustomTic.Value  = round(t_ic, 1);
        efCustomPhp.Value  = round(p_hp, 2);
        efCustomPlp.Value  = round(p_lp, 2);
        efCustomRpm.Value  = round(rpm, 0);
        efCustomVib.Value  = round(vib, 2);
        efCustomCurr.Value = round(curr, 1);
        onApplyCustom();
    end
    function onApplyCustom(~, ~)
        state.custom_sensors.t_ic_c    = efCustomTic.Value;
        state.custom_sensors.p_hp_bar  = efCustomPhp.Value;
        state.custom_sensors.p_lp_bar  = efCustomPlp.Value;
        state.custom_sensors.rpm       = efCustomRpm.Value;
        state.custom_sensors.vib_mm_s  = efCustomVib.Value;
        state.custom_sensors.current_a = efCustomCurr.Value;
        state.scenario = 'CUSTOM';
        ddScenario.Value = 'CUSTOM';
        updateScenarioButtons('CUSTOM');
        lblCustomMode.Text = '● MODE: CUSTOM INJECTED READINGS';
        lblCustomMode.FontColor = [0.98 0.65 0.20];
        stepAndRender(false);
    end
    function syncCustomInputsFromTel()
        if ~isfield(state, 'last_tel') || isempty(state.last_tel), return; end
        lt = state.last_tel;
        if isfield(lt, 't_ic_c') && isfinite(lt.t_ic_c),    efCustomTic.Value  = round(lt.t_ic_c, 1); end
        if isfield(lt, 'p_hp_bar'),                         efCustomPhp.Value  = round(lt.p_hp_bar, 2); end
        if isfield(lt, 'p_lp_bar') && isfinite(lt.p_lp_bar),  efCustomPlp.Value  = round(lt.p_lp_bar, 2); end
        if isfield(lt, 'rpm') && isfinite(lt.rpm),            efCustomRpm.Value  = round(lt.rpm, 0); end
        if isfield(lt, 'vib_mm_s') && isfinite(lt.vib_mm_s),  efCustomVib.Value  = round(lt.vib_mm_s, 2); end
        if isfield(lt, 'current_a') && isfinite(lt.current_a), efCustomCurr.Value = round(lt.current_a, 1); end
    end
    function onTimerTick(~, ~)
        if ~isvalid(fig) || ~state.running, return; end
        stepAndRender(true);
    end
    function onStart(~, ~)
        state.running = true;
        if strcmp(tmr.Running, 'off'), start(tmr); end
    end
    function onPause(~, ~)
        state.running = false;
        if strcmp(tmr.Running, 'on'), stop(tmr); end
        lblClock.Text = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
    end
    function onSingleStep(~, ~)
        stepAndRender(true);
    end
    function onPeriodChanged(src, ~)
        wasRunning = strcmp(tmr.Running, 'on');
        if wasRunning, stop(tmr); end
        tmr.Period = src.Value;
        if wasRunning, start(tmr); end
    end
    function onClearBuffer(~, ~)
        state.ts_buffer = {};
        updateTsLabel('Status: BUFFER CLEARED' + nl + 'Buffered packets: 0' + nl + 'Last push: ' + string(formatLastPush()));
    end
    function onExportCsv(~, ~)
        outCsv = fullfile(state.rootDir, 'reports', 'hmi_event_log.csv');
        if isempty(state.event_rows), return; end
        Tlog = cell2table(state.event_rows, 'VariableNames', {'Time','Scenario','TempC','RPM','PressBar','VibMMS','CurrA','MLProb','MLTopFeat','Action'});
        writetable(Tlog, outCsv);
        appendCmdLog(sprintf('CMD-%04d', state.cmd_seq+1), 'EXPORT_CSV', 'SAVED OK');
        state.cmd_seq = state.cmd_seq + 1;
    end
    function updateActuatorButtons()
        % 1: Motor Stop
        if state.act_cmd(1) > 0.5
            btnMotorStop.Text = 'Motor: STOPPED [TRIP]';
            btnMotorStop.BackgroundColor = [0.85 0.20 0.20];
            btnMotorStop.FontWeight = 'bold';
        else
            btnMotorStop.Text = 'Sim MotorStop [IDLE]';
            btnMotorStop.BackgroundColor = [0.55 0.22 0.22];
            btnMotorStop.FontWeight = 'normal';
        end
        % 2: Unloader
        if state.act_cmd(2) > 0.5
            btnUnloader.Text = 'Unloader: ACTIVE [VENT]';
            btnUnloader.BackgroundColor = [0.14 0.55 0.33];
            btnUnloader.FontWeight = 'bold';
        else
            btnUnloader.Text = 'Actuate Unloader [OFF]';
            btnUnloader.BackgroundColor = [0.18 0.35 0.55];
            btnUnloader.FontWeight = 'normal';
        end
        % 3: Cooling Fan
        if state.act_cmd(3) > 0.5
            btnCoolingFan.Text = 'CoolingFan: ACTIVE [ON]';
            btnCoolingFan.BackgroundColor = [0.14 0.55 0.33];
            btnCoolingFan.FontWeight = 'bold';
        else
            btnCoolingFan.Text = 'Actuate CoolingFan [OFF]';
            btnCoolingFan.BackgroundColor = [0.18 0.35 0.55];
            btnCoolingFan.FontWeight = 'normal';
        end
        % 4: Drain
        if state.act_cmd(4) > 0.5
            btnDrain.Text = 'Drain: PURGING [OPEN]';
            btnDrain.BackgroundColor = [0.14 0.55 0.33];
            btnDrain.FontWeight = 'bold';
        else
            btnDrain.Text = 'Actuate Drain [OFF]';
            btnDrain.BackgroundColor = [0.18 0.35 0.55];
            btnDrain.FontWeight = 'normal';
        end
        % 5: Speed Trim
        if numel(state.act_cmd) >= 5 && state.act_cmd(5) > 0.5
            btnSpeedTrim.Text = 'SpeedTrim: ACTIVE [-22%]';
            btnSpeedTrim.BackgroundColor = [0.14 0.55 0.33];
            btnSpeedTrim.FontWeight = 'bold';
        else
            btnSpeedTrim.Text = 'VFD Speed Trim [OFF]';
            btnSpeedTrim.BackgroundColor = [0.18 0.35 0.55];
            btnSpeedTrim.FontWeight = 'normal';
        end
    end

    function sendCommand(actionName)
        actionName = upper(strtrim(char(string(actionName))));
        if strcmp(actionName, 'NONE') || isempty(actionName)
            state.cmd_seq = state.cmd_seq + 1;
            appendCmdLog(sprintf('CMD-%04d', state.cmd_seq), 'NONE', 'NO ACTION NEEDED');
            return;
        end
        nowDt = datetime('now');
        state.last_cmd_sig = actionName;
        state.last_cmd_time = nowDt;
        state.cmd_seq = state.cmd_seq + 1;
        cid = sprintf('CMD-%04d', state.cmd_seq);
        switch actionName
            case 'UNLOADER',    state.act_cmd(2) = double(~(state.act_cmd(2) > 0.5));
            case 'COOLING_FAN', state.act_cmd(3) = double(~(state.act_cmd(3) > 0.5));
            case 'DRAIN',       state.act_cmd(4) = double(~(state.act_cmd(4) > 0.5));
            case 'SPEED_TRIM',  state.act_cmd(5) = double(~(numel(state.act_cmd)>=5 && state.act_cmd(5) > 0.5));
            case 'MOTOR_STOP',  state.act_cmd(1) = double(~(state.act_cmd(1) > 0.5));
            case 'RESET'
                state.act_cmd = [0 0 0 0 0]; state.act_fb = [0 0 0 0 0];
                state.scenario = 'NORMAL'; ddScenario.Value = 'NORMAL';
                state.history_anom = zeros(size(state.history_t));
                state.inspect_t = NaN;
                updateScenarioButtons('NORMAL');
        end
        state.act_fb = state.act_cmd;
        updateActuatorButtons();
        appendCmdLog(cid, actionName, 'EXECUTED (ACK)');
        lblActState.Text = sprintf('Cmd [Stop Unld Fan Drn Trim]: [%d %d %d %d %d]', state.act_cmd) + nl + ...
                           sprintf('Fb  [Stop Unld Fan Drn Trim]: [%d %d %d %d %d]', state.act_fb);
        if isfield(state, 'last_tel') && ~isempty(state.last_tel)
            lt = state.last_tel;
            appendPersistentStore(datestr(nowDt, 'yyyy-mm-dd HH:MM:SS.FFF'), cid, state.scenario, '2.0.0', ...
                lt.p_hp_bar, lt.t_ic_c, lt.rpm, lt.vib_mm_s, lt.current_a, 0.0, ...
                sprintf('ACTUATOR_%s', actionName), 'ACK');
        end
        stepAndRender(false);
    end
    function appendCmdLog(cid, actionName, statusStr)
        state.cmd_log = [{cid, actionName, statusStr}; state.cmd_log];
        if size(state.cmd_log, 1) > 30, state.cmd_log = state.cmd_log(1:30, :); end
        tblCmd.Data = state.cmd_log;
    end
    function appendPersistentStore(ts, eid, sc, mv, php, tic, rpm, vib, curr, prob, stat, ack)
        persistentCsv = fullfile(state.rootDir, 'reports', 'persistent_event_store.csv');
        csvDir = fileparts(persistentCsv);
        if exist(csvDir, 'dir') ~= 7, mkdir(csvDir); end
        if exist(persistentCsv, 'file') ~= 2
            fidH = fopen(persistentCsv, 'w');
            if fidH > 0
                fprintf(fidH, 'timestamp,event_id,scenario,model_version,p_hp_bar,t_ic_c,rpm,vib_mm_s,current_a,anomaly_prob,status,ack_status\n');
                fclose(fidH);
            end
        end
        fidA = fopen(persistentCsv, 'a');
        if fidA > 0
            cleanStat = regexprep(char(string(stat)), '[,|\n\r]+', ' ');
            cleanStat = strtrim(cleanStat);
            fprintf(fidA, '%s,%s,%s,%s,%.2f,%.2f,%.1f,%.2f,%.2f,%.4f,%s,%s\n', ...
                char(string(ts)), char(string(eid)), char(string(sc)), char(string(mv)), ...
                double(php), double(tic), double(rpm), double(vib), double(curr), ...
                double(prob), cleanStat, char(string(ack)));
            fclose(fidA);
        end
    end

    % --- INTERACTIVE PLOT CLICK HANDLER ---
    function onPlotClick(src, evt)
        if isempty(state.history_t), return; end
        clickT = NaN;
        if nargin >= 2 && ~isempty(evt)
            if isprop(evt, 'IntersectionPoint') && ~isempty(evt.IntersectionPoint)
                clickT = evt.IntersectionPoint(1);
            end
        end
        if ~isfinite(clickT)
            targetAx = ax1;
            if nargin >= 1 && ~isempty(src)
                try
                    foundAx = ancestor(src, 'axes');
                    if ~isempty(foundAx), targetAx = foundAx; end
                catch
                end
            end
            if isprop(targetAx, 'CurrentPoint') && ~isempty(targetAx.CurrentPoint)
                cp = targetAx.CurrentPoint;
                clickT = cp(1, 1);
            end
        end
        if ~isfinite(clickT)
            clickT = state.history_t(end);
        end
        [~, idx] = min(abs(state.history_t - clickT));
        if isempty(idx) || idx < 1 || idx > numel(state.history_t), return; end

        tVal    = state.history_t(idx);
        phpVal  = state.history_p_hp(idx);
        ticVal  = state.history_t_ic(idx);
        vibVal  = state.history_vib(idx);
        currVal = state.history_curr(idx);
        anomVal = state.history_anom(idx);

        state.inspect_t = tVal;

        phpStr = sprintf('%.2f bar', phpVal);
        if ~isfinite(phpVal) || phpVal < -50
            phpStr = 'BAD/CORRUPT (-99.9)';
        end

        if anomVal > 0.5
            statStr = 'ABNORMAL / FAULT';
            statCol = [1.0 0.40 0.40];
        else
            statStr = 'NOMINAL (HEALTHY)';
            statCol = [0.25 0.92 0.48];
        end

        lblPlotInspect.Text = sprintf('🔍 SAMPLE INSPECT [t = %.2f s]: %s | P_hp: %s | T_ic: %.1f°C | Vib: %.2f mm/s | Current: %.1f A', ...
            tVal, statStr, phpStr, ticVal, vibVal, currVal);
        lblPlotInspect.FontColor = statCol;
        pnlInspect.HighlightColor = statCol;

        stepAndRender(false);
    end

    % --- STEP & RENDER ENGINE ---
    function stepAndRender(advanceTime)
        if ~isvalid(fig), return; end
        if isfield(state, 'in_render') && state.in_render, return; end
        state.in_render = true;
        try
            stepAndRenderInternal(advanceTime);
        catch ME
            % Safeguard against transient graphics interrupts
        end
        state.in_render = false;
    end

    function stepAndRenderInternal(advanceTime)
        if ~isvalid(fig), return; end
        if advanceTime, state.t = state.t + state.dt; end
        twinParams = struct('custom_sensors', state.custom_sensors);
        [tel, truth] = step_compressor_twin(state.t, state.scenario, state.act_fb, twinParams);
        state.last_tel = tel;
        raw_vec = [tel.p_lp_bar, tel.p_hp_bar, tel.t_ic_c, tel.rpm];
        limits = state.cfg.limits; thresh = state.cfg.thresh;

        % Strict channel validity: reserve SENSOR_FAULT strictly for corrupt/impossible signals
        hp_sensor_fault  = ~isfinite(tel.p_hp_bar) || (tel.p_hp_bar < -50);
        lp_sensor_fault  = ~isfinite(tel.p_lp_bar) || (tel.p_lp_bar < 0);
        tic_sensor_fault = ~isfinite(tel.t_ic_c)   || (tel.t_ic_c < -50);
        rpm_sensor_fault = ~isfinite(tel.rpm)       || (tel.rpm < 0);

        is_valid = [~lp_sensor_fault, ~hp_sensor_fault, ~tic_sensor_fault, ~rpm_sensor_fault];
        hp_ok = ~hp_sensor_fault;

        clean_vec = raw_vec;
        if ~hp_ok, clean_vec(2) = 0; end

        % Anomaly detection
        ratioVal = tel.p_hp_bar / max(tel.p_lp_bar, 0.1);
        anom = hp_sensor_fault || lp_sensor_fault || tic_sensor_fault || rpm_sensor_fault || ...
               (tel.t_ic_c > thresh.overtemp_c) || ...
               (hp_ok && tel.p_hp_bar > thresh.overpressure_bar) || ...
               (tel.rpm > limits.rpm_range(2)) || ...
               (tel.vib_mm_s > 4.5) || ...
               (hp_ok && ratioVal < thresh.min_stage_ratio);

        if exist('diagnose_fault_and_actuate', 'file') == 2
            [f_code, ~, ~] = diagnose_fault_and_actuate(clean_vec(1), clean_vec(2), clean_vec(3), clean_vec(4), is_valid, [0 0 0 0], thresh);
        else
            f_code = double(anom);
        end

        if exist('predict_anomaly_ml', 'file') == 2
            [mlProb, ~, topFeat] = predict_anomaly_ml(tel);
            if isnan(mlProb)
                mlProb = double(anom);
                topFeat = 'Rule/Threshold';
            end
        else
            mlProb = double(anom); topFeat = 'Rule/Threshold';
        end

        [diagReport, healthSummary, healthColor, recAct, recBanner, recColor, activeZones, partStr, impactStr, fixStr, advisoryStr] = ...
            analyzeContinuousState(tel, is_valid, anom, f_code, truth, state.act_fb, thresh, mlProb, topFeat, nl);
        state.rec_action = recAct;
        lblMachineHealth.Text = healthSummary; lblMachineHealth.FontColor = healthColor;
        lblRecAct.Text = recBanner; lblRecAct.FontColor = recColor;
        lblDiag.Text = diagReport;

        % Dynamic readout updates for Affected Part, Potential Impact & Advisory
        lblStatusTitle.Text = healthSummary;
        lblStatusTitle.FontColor = healthColor;
        lblMetricsSummary.Text = sprintf('Anom Flag: %d | Fault Code: %d | ML Prob: %.2f (%s)', ...
            double(anom), double(f_code), mlProb, char(topFeat));
        if hp_ok
            lblRatioContext.Text = sprintf('Stage Compression Ratio (P_hp / P_lp): %.2f  [Nominal >= 2.20]', ratioVal);
            lblRatioContext.FontColor = [0.78 0.85 0.94];
        else
            lblRatioContext.Text = 'Stage Compression Ratio (P_hp / P_lp): CORRUPTED  [Sensor Fault]';
            lblRatioContext.FontColor = [1.0 0.45 0.45];
        end
        lblAffectedPart.Text = char(partStr);
        lblImpactDesc.Text = char(impactStr);
        lblRecommendedFix.Text = char('Fix: ' + string(fixStr));
        lblAdvisoryBody.Text = char(advisoryStr);

        if anom
            pnlStatusCard.HighlightColor  = healthColor;
            pnlStatusCard.BackgroundColor = [0.18 0.10 0.12];
            pnlPartCard.HighlightColor    = [0.85 0.35 0.35];
            pnlPartCard.BackgroundColor   = [0.18 0.10 0.12];
            pnlImpactCard.HighlightColor  = [0.85 0.55 0.20];
            pnlImpactCard.BackgroundColor = [0.18 0.13 0.10];
        else
            pnlStatusCard.HighlightColor  = [0.20 0.35 0.28];
            pnlStatusCard.BackgroundColor = [0.11 0.16 0.14];
            pnlPartCard.HighlightColor    = [0.22 0.28 0.36];
            pnlPartCard.BackgroundColor   = [0.13 0.16 0.22];
            pnlImpactCard.HighlightColor  = [0.22 0.28 0.36];
            pnlImpactCard.BackgroundColor = [0.13 0.16 0.22];
        end

        lblPistonPos.Text = sprintf('LP: %+.1fmm | HP: %+.1fmm', tel.x_lp_mm, tel.x_hp_mm) + nl + sprintf('t = %.2f s', tel.t_s);
        nowStr = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
        lblClock.Text = nowStr;
        lblTIC.Text  = sprintf('1. Temp (IC): %.1f °C', tel.t_ic_c);
        lblRPM.Text  = sprintf('2. Speed: %.0f RPM', tel.rpm);
        if hp_ok, lblPHP.Text = sprintf('3. Press (HP): %.2f bar', tel.p_hp_bar); else, lblPHP.Text = sprintf('3. Press (HP): BAD (%.1f)', tel.p_hp_bar); end
        lblVIB.Text  = sprintf('4. Vib: %.2f mm/s', tel.vib_mm_s);
        lblCURR.Text = sprintf('5. Current: %.2f A', tel.current_a);
        lblPLP.Text  = sprintf('LP Stage: %.2f bar', tel.p_lp_bar);
        renderCompressorVirtualization(axTwin, tel, state.act_fb, activeZones, nl);

        hpPlotVal = tel.p_hp_bar; if ~hp_ok, hpPlotVal = NaN; end
        if isempty(state.history_t)
            state.history_t = state.t;
            state.history_p_hp = hpPlotVal;
            state.history_t_ic = tel.t_ic_c;
            state.history_vib = tel.vib_mm_s;
            state.history_curr = tel.current_a;
            state.history_anom = double(anom);
        elseif advanceTime
            state.history_t = [state.history_t, state.t];
            state.history_p_hp = [state.history_p_hp, hpPlotVal];
            state.history_t_ic = [state.history_t_ic, tel.t_ic_c];
            state.history_vib = [state.history_vib, tel.vib_mm_s];
            state.history_curr = [state.history_curr, tel.current_a];
            state.history_anom = [state.history_anom, double(anom)];
        else
            % When not advancing time (e.g. click inspection or paused scenario update),
            % update current latest sample in place rather than appending duplicate timestamps
            state.history_p_hp(end) = hpPlotVal;
            state.history_t_ic(end) = tel.t_ic_c;
            state.history_vib(end) = tel.vib_mm_s;
            state.history_curr(end) = tel.current_a;
            state.history_anom(end) = double(anom);
        end
        maxPts = 70;
        if numel(state.history_t) > maxPts
            idx = (numel(state.history_t)-maxPts+1):numel(state.history_t);
            state.history_t = state.history_t(idx); state.history_p_hp = state.history_p_hp(idx); state.history_t_ic = state.history_t_ic(idx); state.history_vib = state.history_vib(idx); state.history_curr = state.history_curr(idx);
            state.history_anom = state.history_anom(idx);
        end
        anomIdx = find(state.history_anom > 0.5);
        hasAnom = anom || ~isempty(anomIdx);

        % Synchronized X-axis Limits across both trend plots
        tMin = min(state.history_t);
        tMax = max(state.history_t);
        if tMax > tMin
            tSpan = max(6.0, (tMax - tMin) * 1.02);
            tLim = [tMax - tSpan, tMax + 0.2];
            if tLim(1) < tMin, tLim(1) = tMin; end
        else
            tLim = [0, 6.0];
        end

        % Live Plot 1: HP Pressure (left) & IC Temperature (right) with abnormal highlighting
        if hasAnom
            ax1.Color = [0.15 0.08 0.10];
            ax1.GridColor = [0.65 0.35 0.38];
            ax1.GridAlpha = 0.35;
            title(ax1, 'HP Press (L) & IC Temp (R)  [ALERT / FAULT]', 'Color', [1.0 0.40 0.40], 'FontSize', 10.5, 'FontWeight', 'bold');
        else
            ax1.Color = [0.09 0.11 0.14];
            ax1.GridColor = [0.35 0.40 0.48];
            ax1.GridAlpha = 0.22;
            title(ax1, 'HP Press (L) & IC Temp (R)', 'Color', [0.92 0.95 1.0], 'FontSize', 10.5, 'FontWeight', 'bold');
        end
        yyaxis(ax1, 'left'); cla(ax1); hold(ax1, 'on');
        hHpLine = plot(ax1, state.history_t, state.history_p_hp, '-', 'LineWidth', 2.0, 'Color', [0.38 0.68 0.88], 'DisplayName', 'HP (bar)');
        set(hHpLine, 'ButtonDownFcn', @onPlotClick);
        validHp = state.history_p_hp(isfinite(state.history_p_hp));
        if ~isempty(validHp)
            plot(ax1, state.history_t(end), validHp(end), 'o', 'MarkerSize', 5.5, ...
                'MarkerFaceColor', [0.38 0.68 0.88], 'MarkerEdgeColor', 'w', 'HandleVisibility', 'off', 'HitTest', 'off');
        end
        if ~isempty(anomIdx)
            anomHp = anomIdx(isfinite(state.history_p_hp(anomIdx)));
            if ~isempty(anomHp)
                hHpAnom = plot(ax1, state.history_t(anomHp), state.history_p_hp(anomHp), 'o', 'MarkerSize', 8.0, ...
                    'MarkerFaceColor', [1.0 0.25 0.25], 'MarkerEdgeColor', 'w', 'LineWidth', 1.4, 'HandleVisibility', 'off');
                set(hHpAnom, 'ButtonDownFcn', @onPlotClick);
            end
        end
        hold(ax1, 'off');
        ax1.YColor = [0.55 0.76 0.90];
        ylabel(ax1, 'HP Press (bar)', 'FontSize', 9.5, 'FontWeight', 'bold');
        if isempty(validHp)
            ylim(ax1, [0, 15.0]);
        else
            hpMin = min(validHp); hpMax = max(validHp);
            ylim(ax1, [max(0, hpMin - 1.5), max(12.5, hpMax + 1.8)]);
        end

        yyaxis(ax1, 'right'); cla(ax1); hold(ax1, 'on');
        hTicLine = plot(ax1, state.history_t, state.history_t_ic, '-', 'LineWidth', 2.0, 'Color', [0.92 0.65 0.35], 'DisplayName', 'IC (°C)');
        set(hTicLine, 'ButtonDownFcn', @onPlotClick);
        validTic = state.history_t_ic(isfinite(state.history_t_ic));
        if ~isempty(validTic)
            plot(ax1, state.history_t(end), validTic(end), 's', 'MarkerSize', 5.5, ...
                'MarkerFaceColor', [0.92 0.65 0.35], 'MarkerEdgeColor', 'w', 'HandleVisibility', 'off', 'HitTest', 'off');
        end
        if ~isempty(anomIdx)
            anomTic = anomIdx(isfinite(state.history_t_ic(anomIdx)));
            if ~isempty(anomTic)
                hTicAnom = plot(ax1, state.history_t(anomTic), state.history_t_ic(anomTic), 's', 'MarkerSize', 8.0, ...
                    'MarkerFaceColor', [1.0 0.45 0.15], 'MarkerEdgeColor', 'w', 'LineWidth', 1.4, 'HandleVisibility', 'off');
                set(hTicAnom, 'ButtonDownFcn', @onPlotClick);
            end
        end
        hold(ax1, 'off');
        ax1.YColor = [0.90 0.70 0.45];
        ylabel(ax1, 'IC Temp (°C)', 'FontSize', 9.5, 'FontWeight', 'bold');
        if isempty(validTic)
            ylim(ax1, [20.0, 150.0]);
        else
            ticMin = min(validTic); ticMax = max(validTic);
            ylim(ax1, [max(20.0, ticMin - 10.0), max(135.0, ticMax + 12.0)]);
        end
        xlim(ax1, tLim);
        xlabel(ax1, 'Time (s)', 'FontSize', 9.5, 'FontWeight', 'bold', 'Color', [0.80 0.86 0.94]);

        % Draw vertical inspection cursor if active
        if isfield(state, 'inspect_t') && ~isempty(state.inspect_t) && isfinite(state.inspect_t) && ...
           state.inspect_t >= min(state.history_t) && state.inspect_t <= max(state.history_t)
            try, xline(ax1, state.inspect_t, '--', 'Color', [0.98 0.85 0.25], 'LineWidth', 1.8, 'HitTest', 'off', 'HandleVisibility', 'off'); catch, end
        end
        
        try
            if isvalid(hHpLine) && isvalid(hTicLine)
                if ~isempty(ax1.Legend) && isvalid(ax1.Legend), delete(ax1.Legend); end
                if hasAnom
                    legend(ax1, [hHpLine, hTicLine], {'HP (bar)', 'IC (°C)'}, ...
                        'TextColor', [0.95 0.85 0.85], 'Color', [0.18 0.12 0.14], 'EdgeColor', [0.65 0.35 0.38], ...
                        'Location', 'north', 'Orientation', 'horizontal', 'AutoUpdate', 'off');
                else
                    legend(ax1, [hHpLine, hTicLine], {'HP (bar)', 'IC (°C)'}, ...
                        'TextColor', [0.82 0.86 0.92], 'Color', [0.11 0.14 0.19], 'EdgeColor', [0.24 0.29 0.36], ...
                        'Location', 'north', 'Orientation', 'horizontal', 'AutoUpdate', 'off');
                end
            end
        catch
        end
        grid(ax1, 'on'); box(ax1, 'off');

        % Live Plot 2: Vibration (left) & Current (right) with abnormal highlighting
        if hasAnom
            ax2.Color = [0.15 0.08 0.10];
            ax2.GridColor = [0.65 0.35 0.38];
            ax2.GridAlpha = 0.35;
            title(ax2, 'Vib (L) & Current (R)  [ALERT / FAULT]', 'Color', [1.0 0.40 0.40], 'FontSize', 10.5, 'FontWeight', 'bold');
        else
            ax2.Color = [0.09 0.11 0.14];
            ax2.GridColor = [0.35 0.40 0.48];
            ax2.GridAlpha = 0.22;
            title(ax2, 'Vib (L) & Current (R)', 'Color', [0.92 0.95 1.0], 'FontSize', 10.5, 'FontWeight', 'bold');
        end
        yyaxis(ax2, 'left'); cla(ax2); hold(ax2, 'on');
        hVibLine = plot(ax2, state.history_t, state.history_vib, '-', 'LineWidth', 2.0, 'Color', [0.72 0.62 0.88], 'DisplayName', 'Vib (mm/s)');
        set(hVibLine, 'ButtonDownFcn', @onPlotClick);
        validVib = state.history_vib(isfinite(state.history_vib));
        if ~isempty(validVib)
            plot(ax2, state.history_t(end), validVib(end), '^', 'MarkerSize', 5.5, ...
                'MarkerFaceColor', [0.72 0.62 0.88], 'MarkerEdgeColor', 'w', 'HandleVisibility', 'off', 'HitTest', 'off');
        end
        if ~isempty(anomIdx)
            anomVib = anomIdx(isfinite(state.history_vib(anomIdx)));
            if ~isempty(anomVib)
                hVibAnom = plot(ax2, state.history_t(anomVib), state.history_vib(anomVib), '^', 'MarkerSize', 8.0, ...
                    'MarkerFaceColor', [1.0 0.25 0.25], 'MarkerEdgeColor', 'w', 'LineWidth', 1.4, 'HandleVisibility', 'off');
                set(hVibAnom, 'ButtonDownFcn', @onPlotClick);
            end
        end
        hold(ax2, 'off');
        ax2.YColor = [0.74 0.68 0.88];
        ylabel(ax2, 'Vibration (mm/s)', 'FontSize', 9.5, 'FontWeight', 'bold');
        if isempty(validVib)
            ylim(ax2, [0, 6.0]);
        else
            vibMax = max(validVib);
            ylim(ax2, [0, max(6.0, vibMax + 1.2)]);
        end

        yyaxis(ax2, 'right'); cla(ax2); hold(ax2, 'on');
        hCurrLine = plot(ax2, state.history_t, state.history_curr, '-', 'LineWidth', 2.0, 'Color', [0.46 0.78 0.58], 'DisplayName', 'Curr (A)');
        set(hCurrLine, 'ButtonDownFcn', @onPlotClick);
        validCurr = state.history_curr(isfinite(state.history_curr));
        if ~isempty(validCurr)
            plot(ax2, state.history_t(end), validCurr(end), 'd', 'MarkerSize', 5.5, ...
                'MarkerFaceColor', [0.46 0.78 0.58], 'MarkerEdgeColor', 'w', 'HandleVisibility', 'off', 'HitTest', 'off');
        end
        if ~isempty(anomIdx)
            anomCurr = anomIdx(isfinite(state.history_curr(anomIdx)));
            if ~isempty(anomCurr)
                hCurrAnom = plot(ax2, state.history_t(anomCurr), state.history_curr(anomCurr), 'd', 'MarkerSize', 8.0, ...
                    'MarkerFaceColor', [1.0 0.60 0.15], 'MarkerEdgeColor', 'w', 'LineWidth', 1.4, 'HandleVisibility', 'off');
                set(hCurrAnom, 'ButtonDownFcn', @onPlotClick);
            end
        end
        hold(ax2, 'off');
        ax2.YColor = [0.56 0.80 0.64];
        ylabel(ax2, 'Current (A)', 'FontSize', 9.5, 'FontWeight', 'bold');
        if isempty(validCurr)
            ylim(ax2, [0, 35.0]);
        else
            currMax = max(validCurr);
            ylim(ax2, [0, max(35.0, currMax + 5.0)]);
        end
        xlim(ax2, tLim);
        xlabel(ax2, 'Time (s)', 'FontSize', 9.5, 'FontWeight', 'bold', 'Color', [0.80 0.86 0.94]);

        % Draw vertical inspection cursor if active
        if isfield(state, 'inspect_t') && ~isempty(state.inspect_t) && isfinite(state.inspect_t) && ...
           state.inspect_t >= min(state.history_t) && state.inspect_t <= max(state.history_t)
            try, xline(ax2, state.inspect_t, '--', 'Color', [0.98 0.85 0.25], 'LineWidth', 1.8, 'HitTest', 'off', 'HandleVisibility', 'off'); catch, end
        end
        
        try
            if isvalid(hVibLine) && isvalid(hCurrLine)
                if ~isempty(ax2.Legend) && isvalid(ax2.Legend), delete(ax2.Legend); end
                if hasAnom
                    legend(ax2, [hVibLine, hCurrLine], {'Vib (mm/s)', 'Curr (A)'}, ...
                        'TextColor', [0.95 0.85 0.85], 'Color', [0.18 0.12 0.14], 'EdgeColor', [0.65 0.35 0.38], ...
                        'Location', 'north', 'Orientation', 'horizontal', 'AutoUpdate', 'off');
                else
                    legend(ax2, [hVibLine, hCurrLine], {'Vib (mm/s)', 'Curr (A)'}, ...
                        'TextColor', [0.82 0.86 0.92], 'Color', [0.11 0.14 0.19], 'EdgeColor', [0.24 0.29 0.36], ...
                        'Location', 'north', 'Orientation', 'horizontal', 'AutoUpdate', 'off');
                end
            end
        catch
        end
        grid(ax2, 'on'); box(ax2, 'off');

        if advanceTime || isempty(state.event_rows)
            state.event_rows(end+1, :) = {nowStr, state.scenario, tel.t_ic_c, tel.rpm, tel.p_hp_bar, tel.vib_mm_s, tel.current_a, mlProb, topFeat, recAct};
            if size(state.event_rows, 1) > 500, state.event_rows = state.event_rows(end-499:end, :); end
            
            % Audit log: append event with event_id, model_version and ack_status
            state.cmd_seq = state.cmd_seq + 1;
            eventId = sprintf('EVT-%s-%04d', char(datetime('now', 'Format', 'yyyyMMddHHmmss')), state.cmd_seq);
            appendPersistentStore(nowStr, eventId, state.scenario, '2.0.0-calibrated', tel.p_hp_bar, tel.t_ic_c, tel.rpm, tel.vib_mm_s, tel.current_a, mlProb, healthSummary, 'ACK');
            
            hpTsVal = tel.p_hp_bar; if ~hp_ok, hpTsVal = 0; end
            pkt = [tel.t_ic_c, tel.rpm, hpTsVal, tel.vib_mm_s, tel.current_a, tel.p_lp_bar, double(f_code), double(anom)];
            state.ts_buffer{end+1} = pkt;
            flushThingSpeak(false);
        end
    end
    function flushThingSpeak(forceNow)
        nBuf = numel(state.ts_buffer); lpStr = string(formatLastPush());
        if ~cbTsEnable.Value, updateTsLabel('Status: DISABLED' + nl + 'Buffered packets: ' + string(nBuf) + nl + 'Last push: ' + lpStr); return; end
        chId = str2double(regexprep(strtrim(char(string(efTsCh.Value))), '\D', ''));
        wKey = strtrim(char(string(efTsKey.Value)));
        if ~isfinite(chId) || ~(chId > 0) || isempty(wKey), updateTsLabel('Status: ENTER VALID CHANNEL ID & KEY' + nl + 'Buffered packets: ' + string(nBuf) + nl + 'Last push: ' + lpStr); return; end
        if exist('thingSpeakWrite', 'file') ~= 2, updateTsLabel('Status: thingSpeakWrite MISSING' + nl + 'Buffered packets: ' + string(nBuf) + nl + 'Last push: ' + lpStr); return; end
        if nBuf == 0, updateTsLabel('Status: READY (Buffer empty)' + nl + 'Buffered packets: 0' + nl + 'Last push: ' + lpStr); return; end
        elapsed = seconds(datetime('now') - state.last_ts_push);
        if ~forceNow && elapsed < state.ts_interval_s, updateTsLabel(sprintf('Status: RATE-PACED (%.0fs / %.0fs)', elapsed, state.ts_interval_s) + nl + 'Buffered packets: ' + string(nBuf) + nl + 'Last push: ' + lpStr); return; end
        latestPkt = state.ts_buffer{end};
        try
            thingSpeakWrite(chId, latestPkt, 'WriteKey', wKey);
            state.ts_buffer = {}; state.last_ts_push = datetime('now');
            updateTsLabel('Status: PUSHED OK' + nl + 'Buffered packets: 0' + nl + 'Last push: ' + string(formatLastPush()));
        catch ME
            updateTsLabel('Status: BUFFERED (Check Ch ID/Key/Net)' + nl + 'Buffered packets: ' + string(nBuf) + nl + 'Last push: ' + lpStr);
        end
    end
    function s = formatLastPush()
        if year(state.last_ts_push) <= 1970, s = 'NEVER'; else, s = char(datetime(state.last_ts_push, 'Format', 'HH:mm:ss')); end
    end
    function updateTsLabel(txt)
        if isvalid(lblTsStatus), lblTsStatus.Text = txt; end
    end
    function onClose(~, ~)
        try, if strcmp(tmr.Running, 'on'), stop(tmr); end, delete(tmr); catch, end
        if isvalid(fig), delete(fig); end
    end
end

function vOut = normalize_validity(vIn, targetLen)
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

function renderCompressorVirtualization(ax, tel, act_fb, zones, nl)
cla(ax); hold(ax, 'on');
xlim(ax, [0 100]); ylim(ax, [0 44]);
ax.XColor = 'none'; ax.YColor = 'none';

% Color definitions
cNom   = [0.13 0.19 0.27];
cWarn  = [0.68 0.42 0.10];
cFault = [0.72 0.16 0.18];
cAct   = [0.14 0.55 0.34];

colMotor = cNom; if zones.motor, colMotor = cFault; elseif zones.motor_warn, colMotor = cWarn; end
colLP    = cNom; if zones.lp,    colLP    = cFault; elseif zones.lp_warn,    colLP    = cWarn; end
colIC    = cNom; if zones.ic,    colIC    = cFault; elseif zones.ic_warn,    colIC    = cWarn; end
colHP    = cNom; if zones.hp,    colHP    = cFault; elseif zones.hp_warn,    colHP    = cWarn; end
colTank  = cNom; if act_fb(2) > 0.1 || act_fb(4) > 0.1, colTank = cAct; end

% Subtle schematic frame
rectangle(ax, 'Position', [1 15 98 27], 'FaceColor', [0.08 0.11 0.15], 'EdgeColor', [0.18 0.24 0.32], 'Curvature', 0.04);

% 1. Inter-stage Piping with Directional Flow Arrows
% Mechanical drive coupling from Motor to LP
plot(ax, [18 23], [29 29], '-', 'Color', [0.55 0.62 0.72], 'LineWidth', 2.5);
rectangle(ax, 'Position', [19.5 27 2 4], 'FaceColor', [0.70 0.76 0.85], 'EdgeColor', [0.3 0.3 0.3]);

% LP to Intercooler process line
plot(ax, [41 46], [29 29], '-', 'Color', [0.30 0.70 0.95], 'LineWidth', 2.5);
patch(ax, [43 45.2 43], [30.4 29 27.6], [0.35 0.85 1.0], 'EdgeColor', 'none');

% Intercooler to HP Stage process line
plot(ax, [64 69], [29 29], '-', 'Color', [0.30 0.70 0.95], 'LineWidth', 2.5);
patch(ax, [66 68.2 66], [30.4 29 27.6], [0.35 0.85 1.0], 'EdgeColor', 'none');

% HP Stage to Receiver Tank discharge line
plot(ax, [85 88], [29 29], '-', 'Color', [0.95 0.58 0.25], 'LineWidth', 2.5);
patch(ax, [86.2 87.8 86.2], [30.4 29 27.6], [1.0 0.70 0.30], 'EdgeColor', 'none');

% 2. Motor Unit
rectangle(ax, 'Position', [2 21 16 16], 'FaceColor', colMotor, 'EdgeColor', [0.65 0.78 0.92], 'Curvature', 0.15);
plot(ax, [5 5; 7 7; 9 9; 11 11; 13 13]', [22 36; 22 36; 22 36; 22 36; 22 36]', ':', 'Color', [0.28 0.40 0.55], 'LineWidth', 1);
text(ax, 10, 34, 'MOTOR DRIVE', 'Color', [0.85 0.92 1.0], 'FontSize', 7.5, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
text(ax, 10, 28, sprintf('%.0f RPM', tel.rpm), 'Color', [0.45 0.95 0.65], 'FontSize', 8.5, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
text(ax, 10, 23.5, sprintf('%.1f A', tel.current_a), 'Color', [0.95 0.90 0.55], 'FontSize', 8, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

% 3. LP Stage Compression Cylinder
rectangle(ax, 'Position', [23 21 18 16], 'FaceColor', colLP, 'EdgeColor', [0.65 0.78 0.92], 'Curvature', 0.05);
lpPistonX = 25 + min(max(tel.x_lp_mm / 90, 0), 1) * 8;
plot(ax, [24 lpPistonX], [29 29], '-k', 'LineWidth', 2.2);
rectangle(ax, 'Position', [lpPistonX 23.5 5 11], 'FaceColor', [0.86 0.89 0.94], 'EdgeColor', [0.15 0.15 0.15]);
text(ax, 32, 39.5, sprintf('LP STAGE (%.2f bar)', tel.p_lp_bar), 'Color', [0.85 0.92 1.0], 'FontSize', 8, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
text(ax, 32, 23.5, 'STAGE 1', 'Color', [0.65 0.75 0.88], 'FontSize', 7, 'HorizontalAlignment', 'center');

% 4. Intercooler (IC) Heat Exchanger Stage
rectangle(ax, 'Position', [46 21 18 16], 'FaceColor', colIC, 'EdgeColor', [0.65 0.78 0.92], 'Curvature', 0.08);
for finX = [49 52 55 58 61]
    plot(ax, [finX finX], [22.5 35.5], '-', 'Color', [0.25 0.42 0.60], 'LineWidth', 1.2);
end
fanActive = act_fb(3) > 0.1;
if fanActive
    text(ax, 55, 39.5, 'IC COOLER [FAN ❄]', 'Color', [0.35 0.95 0.65], 'FontSize', 8, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
else
    text(ax, 55, 39.5, 'IC HEAT EXCH', 'Color', [0.85 0.92 1.0], 'FontSize', 8, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
end
text(ax, 55, 29, sprintf('%.1f °C', tel.t_ic_c), 'Color', [1.0 0.80 0.45], 'FontSize', 9, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
text(ax, 55, 23.5, 'FIN TUBE CORE', 'Color', [0.65 0.75 0.88], 'FontSize', 7, 'HorizontalAlignment', 'center');

% 5. HP Stage Compression Cylinder
rectangle(ax, 'Position', [69 21 16 16], 'FaceColor', colHP, 'EdgeColor', [0.65 0.78 0.92], 'Curvature', 0.05);
hpPistonX = 71 + min(max(tel.x_hp_mm / 90, 0), 1) * 6;
plot(ax, [70 hpPistonX], [29 29], '-k', 'LineWidth', 2.0);
rectangle(ax, 'Position', [hpPistonX 24 4.5 10], 'FaceColor', [0.86 0.89 0.94], 'EdgeColor', [0.15 0.15 0.15]);
hpStr = sprintf('%.2f bar', tel.p_hp_bar); if ~isfinite(tel.p_hp_bar) || tel.p_hp_bar < -50, hpStr = 'BAD SIG'; end
text(ax, 77, 39.5, sprintf('HP STAGE (%s)', hpStr), 'Color', [0.85 0.92 1.0], 'FontSize', 8, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
text(ax, 77, 23.5, 'STAGE 2', 'Color', [0.65 0.75 0.88], 'FontSize', 7, 'HorizontalAlignment', 'center');

% 6. Receiver & Discharge Tank
rectangle(ax, 'Position', [88 19 10 20], 'FaceColor', colTank, 'EdgeColor', [0.65 0.78 0.92], 'Curvature', [0.45 0.45]);
plot(ax, [93 93], [39 41.5], '-', 'Color', [0.70 0.78 0.88], 'LineWidth', 2); % Relief line
plot(ax, [93 93], [19 16.5], '-', 'Color', [0.70 0.78 0.88], 'LineWidth', 2); % Drain tap
text(ax, 93, 30, char("RCVR" + nl + "& ACT"), 'Color', 'w', 'FontSize', 7.5, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

% 7. Lower Actuator Status Badges (Y = 6 to 13.5)
% 5 Pill Cards: STOP | UNLOAD | FAN | DRAIN | TRIM
% Pill 1: Motor Stop
isStop = act_fb(1) > 0.5;
if isStop, colPill = [0.82 0.20 0.20]; txtPill = '● STOP: TRIP'; txtCol = 'w';
else, colPill = [0.13 0.17 0.23]; txtPill = '○ STOP: RUN'; txtCol = [0.75 0.82 0.90]; end
rectangle(ax, 'Position', [2 6 17 7.5], 'FaceColor', colPill, 'EdgeColor', [0.28 0.36 0.46], 'Curvature', 0.35);
text(ax, 10.5, 9.75, txtPill, 'Color', txtCol, 'FontSize', 7.5, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

% Pill 2: Unloader
isUnld = act_fb(2) > 0.5;
if isUnld, colPill = [0.14 0.55 0.33]; txtPill = '● UNLD: VENT'; txtCol = 'w';
else, colPill = [0.13 0.17 0.23]; txtPill = '○ UNLD: LOAD'; txtCol = [0.75 0.82 0.90]; end
rectangle(ax, 'Position', [21 6 18 7.5], 'FaceColor', colPill, 'EdgeColor', [0.28 0.36 0.46], 'Curvature', 0.35);
text(ax, 30, 9.75, txtPill, 'Color', txtCol, 'FontSize', 7.5, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

% Pill 3: Cooling Fan
isFan = act_fb(3) > 0.5;
if isFan, colPill = [0.14 0.55 0.33]; txtPill = '● FAN: ACTIVE'; txtCol = 'w';
else, colPill = [0.13 0.17 0.23]; txtPill = '○ FAN: OFF'; txtCol = [0.75 0.82 0.90]; end
rectangle(ax, 'Position', [41 6 18 7.5], 'FaceColor', colPill, 'EdgeColor', [0.28 0.36 0.46], 'Curvature', 0.35);
text(ax, 50, 9.75, txtPill, 'Color', txtCol, 'FontSize', 7.5, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

% Pill 4: Drain Valve
isDrn = act_fb(4) > 0.5;
if isDrn, colPill = [0.14 0.55 0.33]; txtPill = '● DRN: PURGE'; txtCol = 'w';
else, colPill = [0.13 0.17 0.23]; txtPill = '○ DRN: SHUT'; txtCol = [0.75 0.82 0.90]; end
rectangle(ax, 'Position', [61 6 18 7.5], 'FaceColor', colPill, 'EdgeColor', [0.28 0.36 0.46], 'Curvature', 0.35);
text(ax, 70, 9.75, txtPill, 'Color', txtCol, 'FontSize', 7.5, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

% Pill 5: Speed Trim
isTrim = (numel(act_fb) >= 5 && act_fb(5) > 0.5);
if isTrim, colPill = [0.14 0.55 0.33]; txtPill = '● TRIM: -22%'; txtCol = 'w';
else, colPill = [0.13 0.17 0.23]; txtPill = '○ TRIM: OFF'; txtCol = [0.75 0.82 0.90]; end
rectangle(ax, 'Position', [81 6 17 7.5], 'FaceColor', colPill, 'EdgeColor', [0.28 0.36 0.46], 'Curvature', 0.35);
text(ax, 89.5, 9.75, txtPill, 'Color', txtCol, 'FontSize', 7.5, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');

% Disclaimer note
text(ax, 2, 2.0, 'Simulated 2-stage twin (no physical hardware). Safety interlocks stay independent.', 'Color', [0.65 0.72 0.82], 'FontSize', 7.5);
hold(ax, 'off');
end

function [reportTxt, healthTxt, healthCol, recAct, recBanner, recColor, zones, partStr, impactStr, fixStr, advisoryStr] = analyzeContinuousState(tel, is_valid, anom, f_code, truth, act_fb, thresh, mlProb, topFeat, nl)
if nargin < 10 || isempty(nl), nl = string(newline); else, nl = string(nl); end
if nargin < 9, topFeat = 'Rule/Threshold'; end
if nargin < 8, mlProb = double(anom); end
if nargin < 7 || ~isstruct(thresh), thresh = struct(); end
if nargin < 6, act_fb = [0 0 0 0]; end
if nargin < 5 || ~isstruct(truth), truth = struct('fault_label', 'UNKNOWN'); end
if nargin < 4, f_code = double(anom); end
if nargin < 3, anom = false; end
if nargin < 2, is_valid = true; end

is_valid = normalize_validity(is_valid, 4);

% Threshold normalization
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

advisoryStr = 'SIMULATED SCADA-HMI ADVISORY: Digital-twin heuristics for demonstration/supervisory testing. Field safety relies on independent hardwired SIL-3 emergency stops, physical PRVs, and certified PLCs.';

zones = struct('motor', false, 'motor_warn', false, 'lp', false, 'lp_warn', false, 'ic', false, 'ic_warn', false, 'hp', false, 'hp_warn', false);

% Evaluate specific condition:
% Reserve SENSOR_FAULT strictly for non-finite or impossible electrical codes (-99.9 or negative).
hp_bad = ~isfinite(tel.p_hp_bar) || (tel.p_hp_bar < -50) || isnan(tel.p_hp_bar);
gen_sensor_bad = ~isfinite(tel.p_lp_bar) || ~isfinite(tel.t_ic_c) || ~isfinite(tel.rpm) || ...
                 (tel.p_lp_bar < 0) || (tel.t_ic_c < -50) || (tel.rpm < 0);

is_temp_bad = isfinite(tel.t_ic_c) && (tel.t_ic_c > t_ic_lim);
is_press_bad = isfinite(tel.p_hp_bar) && (tel.p_hp_bar > p_hp_lim);
is_speed_bad = isfinite(tel.rpm) && (tel.rpm > rpm_lim);
is_vib_bad = isfinite(tel.vib_mm_s) && (tel.vib_mm_s > vib_lim);
ratioVal = tel.p_hp_bar / max(tel.p_lp_bar, 0.1);
is_leak_bad = isfinite(tel.p_hp_bar) && isfinite(tel.p_lp_bar) && (ratioVal < ratio_lim);

numFaults = is_temp_bad + is_press_bad + is_speed_bad + is_vib_bad + is_leak_bad;

if hp_bad
    zones.hp = true; healthTxt = '● STATUS: SENSOR FAULT (HP)'; healthCol = [1.0 0.35 0.35]; recAct = 'RESET';
    recBanner = string('RECOMMENDED ACTUATOR: RESET / QUARANTINE') + nl + string('HP signal out-of-range (-99.9 bar or NaN). Quarantine & check sensor.');
    recColor = [1.0 0.45 0.45]; partStr = sprintf('HP Pressure Transducer / Signal Path\n4-20mA Sensor Loop, Wiring Harness & ADC Input');
    impactStr = 'Corrupted or missing telemetry stream (-99.9 bar or NaN). Closed-loop supervisory control blinded to HP discharge; stage ratio calculation corrupted.';
    fixStr = 'Quarantine HP transducer channel; switch to fail-safe manual monitoring and inspect sensor wiring.';

elseif gen_sensor_bad
    zones.hp_warn = true; healthTxt = '● STATUS: SENSOR FAULT (CORRUPT/NEGATIVE)'; healthCol = [1.0 0.35 0.35]; recAct = 'RESET';
    recBanner = string('RECOMMENDED ACTUATOR: RESET / QUARANTINE') + nl + string('Sensor signal non-finite or impossible electrical code. Quarantine channel.');
    recColor = [1.0 0.45 0.45]; partStr = sprintf('Telemetry Transducer / Signal Interface\nAnalog Channel Conditioning & Wiring Harness');
    impactStr = 'Non-finite or out-of-range electrical sensor reading received. Signal stream quarantined.';
    fixStr = 'Inspect transducer wiring, power supply, and ADC conversion loop.';

elseif act_fb(1) > 0.5
    zones.motor = true;
    healthTxt = '● STATUS: COMPRESSOR STOPPED (SAFE IDLE | MOTOR STOP ACTIVE)';
    healthCol = [0.35 0.75 1.0];
    recAct = 'RESET';
    recBanner = string('SUPERVISORY STATE: MOTOR STOPPED (IDLE)') + nl + string('Compressor drive stopped safely (0 RPM). Reset to re-engage.');
    recColor = [0.35 0.75 1.0];
    partStr = sprintf('Motor Drive Train & Crankshaft Assembly\nPrime Mover Drive De-energized [Safe Idle]');
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
    partStr = sprintf('Interstage Intercooler (Stage 1 -> Stage 2)\nCooling Fins, Airflow Ducting & Shell Core');
    impactStr = 'High discharge gas temperature degrades lubricating oil film; hot intake into HP stage increases compression work and accelerates discharge valve thermal fatigue.';
    fixStr = 'Actuate COOLING_FAN to restore heat rejection; inspect intercooler fins for fouling or fan failure.';

elseif is_press_bad
    zones.hp = true; zones.motor_warn = true;
    healthTxt = '● STATUS: HIGH PRESS (HP)';
    healthCol = [1.0 0.35 0.35];
    recAct = 'UNLOADER';
    recBanner = string('RECOMMENDED ACTUATOR: UNLOADER (or DRAIN)') + nl + string(sprintf('HP pressure (%.2f bar) > threshold (%.2f bar). Relieve load.', tel.p_hp_bar, p_hp_lim));
    recColor = [1.0 0.45 0.45];
    partStr = sprintf('HP Stage Discharge Head & Receiver Tank\nDischarge Reed Valves, Delivery Manifold & Vessel');
    impactStr = 'Excessive mechanical pressure cycle stress on HP cylinder head, discharge reeds, and receiver vessel; causes motor overcurrent and risks pressure relief lifting.';
    fixStr = 'Actuate UNLOADER valve (or DRAIN) to relieve line pressure; verify receiver demand and check check-valve.';

elseif is_speed_bad
    zones.motor = true; zones.hp_warn = true;
    healthTxt = '● STATUS: HIGH SPEED (RPM)';
    healthCol = [1.0 0.45 0.25];
    recAct = 'UNLOADER';
    recBanner = string('RECOMMENDED ACTUATOR: UNLOADER / MOTOR_STOP') + nl + string(sprintf('Speed (%.0f RPM) > threshold (%.0f RPM). Unload or stop.', tel.rpm, rpm_lim));
    recColor = [1.0 0.55 0.30];
    partStr = sprintf('Motor Drive & Crankshaft Speed Governor\nInverter Frequency Controller & Rotational Coupling');
    impactStr = 'Excessive reciprocating inertia forces on connecting rods and bearings; increased mechanical friction, vibration, and stator overheating.';
    fixStr = 'Actuate UNLOADER and issue MOTOR_STOP; verify VFD speed loop and inverter controller.';

elseif is_vib_bad
    zones.motor_warn = true; zones.lp_warn = true; zones.hp_warn = true;
    healthTxt = '● STATUS: HIGH VIBRATION';
    healthCol = [1.0 0.55 0.20];
    recAct = 'UNLOADER';
    recBanner = string('RECOMMENDED ACTUATOR: UNLOADER / MOTOR_STOP') + nl + string(sprintf('Vibration (%.2f mm/s) > threshold (%.2f mm/s). Unload & inspect.', tel.vib_mm_s, vib_lim));
    recColor = [1.0 0.65 0.25];
    partStr = sprintf('Crankcase, Bearings & Structural Mounts\nFoundation Anchor Fasteners & Main Bearings');
    impactStr = 'High mechanical vibration indicates dynamic unbalance, loose foundation fasteners, or bearing fatigue; risks catastrophic bearing seizure if prolonged.';
    fixStr = 'Actuate UNLOADER (or MOTOR_STOP) to relieve reciprocating forces; inspect mounting bolts and main bearings.';

elseif is_leak_bad
    zones.lp = true; zones.hp_warn = true; zones.ic_warn = true;
    healthTxt = '● STATUS: VALVE LEAKAGE';
    healthCol = [1.0 0.78 0.25];
    recAct = 'UNLOADER';
    recBanner = string('RECOMMENDED ACTUATOR: UNLOADER') + nl + string(sprintf('Stage ratio (%.2f) < %.1f. Unload & inspect valves.', ratioVal, ratio_lim));
    recColor = [1.0 0.82 0.30];
    partStr = sprintf('LP / HP Suction & Discharge Valve Plates\nReed Port Flappers, Return Springs & Seat Seals');
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
        targetSub = '';
        if contains(actStr, 'COOLING_FAN'), targetSub = 'Target Subsystem: Interstage Cooling & Thermal Management';
        elseif contains(actStr, 'UNLOADER'), targetSub = 'Target Subsystem: HP Discharge Cylinder & Receiver Depressurization';
        elseif contains(actStr, 'DRAIN'), targetSub = 'Target Subsystem: Interstage Moisture Separator & Condensate Traps';
        elseif contains(actStr, 'SPEED_TRIM'), targetSub = 'Target Subsystem: Motor Inverter VFD Speed Loop Trim';
        elseif contains(actStr, 'MOTOR_STOP'), targetSub = 'Target Subsystem: Prime Mover & Main Crankshaft Drive';
        end
        if ~isempty(targetSub)
            partStr = sprintf('Supervisory Control: %s Engaged\n%s', actStr, targetSub);
        else
            partStr = sprintf('Supervisory Control: %s Engaged', actStr);
        end
        impactStr = sprintf('Active mitigation in progress (%s). Thermodynamic load relieved; operating within safe margins.', actStr);
        fixStr = sprintf('Maintain %s until thermal/mechanical equilibrium stabilizes, or return to unforced nominal mode.', actStr);
    else
        healthTxt = '● STATUS: NOMINAL  |  ALL CHANNELS HEALTHY';
        healthCol = [0.25 0.92 0.48];
        recAct = 'NONE';
        recBanner = string('RECOMMENDED ACTUATOR: NONE (Nominal)') + nl + string('All monitored channels within normal operating limits.');
        recColor = [0.25 0.92 0.52];
        partStr = sprintf('None — All Subsystems Nominal\nCylinders, Intercooler, Valves & Bearings Healthy');
        impactStr = 'Operating within thermodynamic and mechanical design limits. Stable 2-stage compression, balanced thermal dissipation, and normal vibration levels.';
        fixStr = 'No intervention required. System running nominally within configured prototype thresholds.';
    end
end

ratioVal = tel.p_hp_bar / max(tel.p_lp_bar, 0.1);
reportTxt = string(healthTxt) + nl + ...
    string(sprintf('Anom:%d | Code:%d | ML:%.2f (%s)', double(anom), double(f_code), mlProb, string(topFeat))) + nl + ...
    string(sprintf('Ratio:%.2f | ActFb:[%s]', ratioVal, num2str(act_fb > 0.1))) + nl + nl + ...
    'AFFECTED PART:' + nl + string(partStr) + nl + nl + ...
    'POTENTIAL IMPACT:' + nl + string(impactStr) + nl + nl + ...
    'HOW TO FIX:' + nl + string(fixStr) + nl + nl + ...
    'ADVISORY NOTICE:' + nl + string(advisoryStr) + nl + nl + ...
    'Twin Ref: ' + string(truth.fault_label);
end

function cfg = default_cfg()
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
cfg = normalize_cfg(cfg);
end

function cfg = normalize_cfg(cfg)
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
