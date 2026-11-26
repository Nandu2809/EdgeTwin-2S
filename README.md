# EdgeSentinel: Industrial Digital Twin & SCADA-HMI Prototype

[![MATLAB Verification](https://img.shields.io/badge/MATLAB-Verification%20Passed%20(100%25)-green.svg)](#matlab-verification-suite)
[![Python Test Matrix](https://img.shields.io/badge/Python%20Matrix-Section%2011.1%20Passed-green.svg)](#section-111-minimum-test-matrix-suite)
[![SKAB Contract](https://img.shields.io/badge/SKAB%20Contract-Strict%208--Feature-blue.svg)](#strict-ml-scope-honesty--contracts)
[![Scope Honesty](https://img.shields.io/badge/Scope-Simulated%20Digital%20Twin-orange.svg)](#scope-honesty--engineering-disclaimer)

---

## Scope Honesty & Engineering Disclaimer

> [!IMPORTANT]
> **Panel-Standard Scope Statement**
> **A laptop-hosted, simulated industrial edge anomaly-monitoring and SCADA-HMI proof of concept using SKAB benchmark data and a MATLAB 2-stage compressor digital twin (no physical sensors, PLC, or safety-rated control hardware).**
>
> 1. **No Physical Machine**: This system is entirely simulated software. There is no physical compressor, pressurized vessel, electric induction motor, or mechanical piping.
> 2. **No Calibrated Field Sensors**: All sensor observations (`p_lp_bar`, `p_hp_bar`, `t_ic_c`, `rpm`, `vib_mm_s`, `current_a`) are digitally synthesized from continuous kinematic, thermodynamic, and stochastic noise differential equations.
> 3. **Separation from Safety-Rated Control Hardware**: This prototype does not run on industrial PLCs (Programmable Logic Controllers), PACs, RTUs, or safety-instrumented systems (SIS/SIL). Supervisory actuator commands (`MotorStop`, `Unloader`, `CoolingFan`, `Drain`, `SpeedTrim`) are advisory software recommendations within the simulated twin. In production environments, emergency shutdowns and thermal trips are governed exclusively by hardwired, safety-rated interlocks operating independently of software or ML models.

---

## Target Enterprise Deployment Architecture (IBM Infrastructure)

To scale EdgeSentinel from a local digital-twin prototype to an enterprise-grade industrial deployment, the system is designed to map to the following IBM target topology:

```text
+---------------------------------------------------------------------------------+
|                              PLANT FLOOR / EDGE TIER                            |
|  - Physical Compressor Skid (Sensors: PT, TT, Tach, Vib, CT)                     |
|  - Independent SIL-3 Safety PLC (Hardwired E-Stop, Rupture Disc, Thermal Trip)   |
|  - Edge Compute: IBM Power S1012 Edge Server                                    |
|      * Local containerized inference (Random Forest / Digital Twin)              |
|      * Store-and-forward local event buffer (EventStore deduplication)           |
+----------------------------------------+----------------------------------------+
                                         | Secure TLS / MQTT Telemetry
                                         v
+---------------------------------------------------------------------------------+
|                          ENTERPRISE DATA & CACHE TIER                           |
|  - Low-Latency Telemetry Cache: IBM FlashSystem (NVMe-oF sub-ms ingest)         |
|  - Distributed Scale-Out File/Object Lake: IBM Storage Scale (GPFS)              |
|      * Ingests high-frequency raw vibration & thermodynamic streams              |
|      * Retains quarantined validation & held-out benchmark splits                |
+----------------------------------------+----------------------------------------+
                                         | S3 / Enterprise Bus
                                         v
+---------------------------------------------------------------------------------+
|                       GOVERNANCE & LONG-TERM ARCHIVE TIER                       |
|  - Enterprise Governance & Provenance: IBM Z Mainframe System                   |
|      * Model versioning, regulatory compliance audit trails                     |
|      * Immutable cryptographically signed event records                         |
|  - Deep Cold Archive: IBM TS4500 Tape Library                                   |
|      * Automated air-gapped tape cartridges (10-30 yr compliance retention)     |
|      * Zero-power-at-rest long-term data preservation                            |
+---------------------------------------------------------------------------------+
```

---

## System Architecture & Repository Layout

```text
EdgeSentinel_Submission/
├── app/
│   └── EdgeSentinel_Dashboard.m          # MATLAB App Designer SCADA-HMI dashboard
├── algorithms/
│   ├── anomaly_detection/
│   │   └── detect_anomaly.m              # Threshold & ratio anomaly detector
│   ├── diagnostics/
│   │   ├── diagnose_fault_and_actuate.m  # Fault isolation & supervisory actuator policy
│   │   └── analyzeContinuousState.m      # Subsystem part attribution, impact analysis & advisory
│   └── preprocessing/
│       └── preprocess_signals.m          # Sensor limits & validity boundary checker
├── scripts/
│   ├── initialization/
│   │   └── init_edgesentinel.m           # Physical parameters, operating limits, thresholds
│   ├── simulation/
│   │   ├── step_compressor_twin.m        # Continuous 2-stage compressor digital twin
│   │   └── run_simulation.m              # Simulation batch driver
│   ├── visualization/
│   │   └── plot_results.m                # Telemetry & actuator visualizer
│   ├── analysis/
│   │   └── evaluate_accuracy.m           # Offline simulation accuracy analysis
│   └── ml/
│       ├── predict.py                    # Sub-10ms strict 8-feature SKAB ML inference engine
│       ├── predict_anomaly_ml.m          # MATLAB ML contract interface (rejects 5-sensor data)
│       ├── event_store.py                # Idempotent deduplication & store-forward buffer
│       ├── run_offline_edge_demo.py      # Offline store-and-forward WAN outage demonstration
│       ├── train_and_evaluate_skab.py    # Grouped leak-free training & evaluation runner
│       └── evaluate_skab_heldout.py      # Zero-leakage held-out SKAB evaluation runner
├── models/
│   └── random_forest.joblib              # Calibrated 8-feature Random Forest bundle
├── tests/
│   ├── test_panel_matrix.py              # Section 11.1 Minimum Test Matrix Suite
│   ├── test_accuracy_audit.py            # Comprehensive 10-point accuracy & calibration audit
│   ├── test_ml_pipeline.py               # Assertion-based Python verification unit tests
│   └── run_edgesentinel_verify.m         # Assertion-based MATLAB verification test suite
├── reports/
│   ├── random_forest_metrics.json        # Section 11.1 official ML benchmark evaluation
│   ├── per_file_metrics.csv              # Per-file breakdown for held-out test files 11..14
│   ├── threshold_validation.json         # Threshold grid search on validation files 9..10
│   ├── latency_benchmark.json            # 500-call sub-10ms inference latency percentiles
│   ├── offline_outage_resilience_report.json # 3-phase WAN outage store-and-forward proof
│   ├── accuracy_audit_report.json        # Full accuracy, calibration & edge-case audit
│   ├── test_suite_report.json            # Section 11.1 automated test matrix execution report
│   ├── matlab_verify_report.txt          # MATLAB twin verification pass/fail execution log
│   ├── heldout_evaluation.json           # Detailed held-out evaluation payload
│   └── persistent_event_store.csv        # Persistent session-restart audit log
├── data/raw/
│   └── skab/                             # Benchmark SKAB dataset files
├── requirements.txt                      # Pinned Python dependencies (joblib, pandas, numpy, scikit-learn, pytest)
└── README.md                             # System documentation, contracts, and test instructions
```

---

## Strict ML Scope Honesty & Contracts

### The 5-Sensor vs 8-Feature Contract
The compressor digital twin generates a 5-sensor industrial observation vector:
- `p_lp_bar`: Low-Pressure stage suction/discharge (bar)
- `p_hp_bar`: High-Pressure cylinder discharge (bar)
- `t_ic_c`: Intercooler heat exchanger temperature (°C)
- `rpm`: Crankshaft rotational speed (RPM)
- `vib_mm_s`: Mechanical vibration velocity RMS (mm/s)
- `current_a`: Electric motor stator current (A)

In contrast, the SKAB benchmark dataset requires **8 specific hydraulic/electrical features**:
1. `Accelerometer1RMS`
2. `Accelerometer2RMS`
3. `Current`
4. `Pressure`
5. `Temperature`
6. `Thermocouple`
7. `Voltage`
8. `Volume Flow RateRMS`

### Strict Integrity Rule
`predict.py` and `random_forest.joblib` strictly enforce this contract:
- **Missing Features**: If 5-sensor compressor telemetry or any subset missing the required 8 features is supplied, the inference engine **MUST NEVER fabricate, interpolate, or synthesize fake values**. It immediately returns:
  ```json
  {
    "status": "UNAVAILABLE",
    "ml_available": false,
    "message": "ML INFERENCE NOT AVAILABLE – REQUIRED FEATURES MISSING",
    "anomaly_probability": null
  }
  ```
- **Deterministic Fallback**: The SCADA dashboard (`EdgeSentinel_Dashboard.m`) detects this condition and relies on deterministic rule-based thermodynamics and boundary diagnostics (`Rule/Threshold`), preserving complete architectural honesty.

---

## Reproducible Held-Out Benchmark Results (Section 11.1)

Run the training and evaluation pipeline:
```bash
python scripts/ml/train_and_evaluate_skab.py
```

### Data Split Discipline & Partition Isolation (Zero Data Leakage)
- **Training Group**: other/1.csv through other/8.csv (8,392 samples, used exclusively for model fitting).
- **Validation Group**: other/9.csv and other/10.csv (2,471 raw samples; 2,450 isolated samples).
  * **21-Row Overlap Exclusion**: The last 21 observations of other/10.csv (2020-02-08 18:10:42 to 18:11:02) duplicate the beginning of held-out test file other/11.csv. These 21 duplicate rows are excluded from the isolated validation partition to enforce strictly zero leakage across all partition pairs (Train vs Val = 0, Train vs Test = 0, Val vs Test = 0).
- **Held-Out Test Group**: other/11.csv, 12.csv, 13.csv, 14.csv (4,066 samples total, completely quarantined).
- **Lineage Audit & Manifest**: Full provenance, dataset hashes, split definitions, random seed (42), decision threshold (tau = 0.33), and artifact SHA-256 are cryptographically tracked in [reports/training_manifest.json](file:///c:/EdgeTwin-2S/reports/training_manifest.json). Clean retraining runs deterministically without reusing stale model files when explicit retraining (--retrain) is invoked.

### Complete Held-Out Test Table (`11.csv` through `14.csv`)

| File Name | Test Samples ($N$) | Anomaly % | Accuracy | Precision | Recall | F1-Score | FPR | TP | TN | FP | FN |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `other/11.csv` | 1,190 | 37.9% | 99.41% | 100.00% | 98.45% | **99.22%** | 0.00% | 444 | 739 | 0 | 7 |
| `other/12.csv` | 1,048 | 29.5% | 97.04% | 100.00% | 89.97% | **94.72%** | 0.00% | 278 | 739 | 0 | 31 |
| `other/13.csv` | 923 | 28.7% | 97.07% | 95.42% | 94.34% | **94.88%** | **1.82%** | 250 | 646 | 12 | 15 |
| `other/14.csv` | 905 | 33.4% | 97.57% | 95.75% | 97.02% | **96.38%** | 2.16% | 293 | 590 | 13 | 9 |
| **AGGREGATE** | **4,066** | **32.6%** | **97.86%** | **98.06%** | **95.33%** | **96.68%** | **0.91%** | **1,265** | **2,714** | **25** | **62** |

*(Calibrated decision threshold $\tau = 0.33$ selected on isolated validation files `9.csv`–`10.csv`, achieving aggregate Recall of **95.33%**, F1-Score of **96.68%**, and Accuracy of **97.86% (~98%)** with a low false alarm rate of **0.91%** on completely held-out test data).*

### Cross-Regime Evaluation & Honest Scope Disclosures

To prevent overclaiming single-regime transfer on unseen factory dynamics, the model was evaluated across all SKAB operating regimes ([reports/cross_regime_evaluation.json](file:///c:/EdgeTwin-2S/reports/cross_regime_evaluation.json)):

| Operating Regime | Description | Total Samples | Raw Unadapted FPR | Naive Mean-Shift | Fault-Preserving Adaptive Metric |
| :--- | :--- | :---: | :---: | :---: | :--- |
| **other (Held-Out)** | Quarantined test split (11..14) | 4,066 | **0.91%** | 0.91% | High in-regime generalization ($F_1 = 96.68\%$, Recall: $95.33\%$, Acc: $97.86\%$). |
| **anomaly-free** | Continuous nominal benchmark | 9,405 | **0.00%** | 0.00% | Exceptional specificity (=9,405$, =0$, Specificity: .0\%$). |
| **valve1** | Hydraulic throttling regime 1 | 18,160 | **100.00%** | 0.00% (\text{-TP}$) | ** = 68.5\%$**, Recall: **.9\%$**, FPR: **.7\%$** (=5,420$). |
| **valve2** | Hydraulic throttling regime 2 | 4,312 | **100.00%** | 0.00% (\text{-TP}$) | ** = 63.2\%$**, Recall: **.9\%$**, FPR: **.0\%$** (=984$). |

> [!WARNING]
> **Engineering Scope Honesty: Cross-Regime Generalization Limits**
> A model trained solely on nominal data from the other baseline regime flags unadapted valve throttling regimes (alve1, alve2) as continuous anomalies ( = 100\%$) because closed valves alter normal baseline pressure and flow distributions. Conversely, naive mean subtraction collapses anomaly signatures along with the setpoint, creating a \text{-TP} / 100\%\text{ FN}$ failure mode. Factory edge deployment requires **fault-preserving adaptive normalization** (combining rate-of-change / delta features with local variance-scaled thresholds) or multi-regime training rather than assuming single-regime zero-shot transfer.

### Honest Disclosure of Distribution Shift
- **Incipient Delay (File 12)**: Zero false alarms ($FPR = 0.00\%$), with 89.97% recall ($FN=31$) during subtle incipient onset before full mechanical degradation develops.
- **Hydraulic Turbulence (File 13)**: Causal startup state gating suppresses pre-startup idle flow surges, reducing FPR to 1.82% ($FP=12$) while maintaining 94.34% recall ($F_1 = 94.88\%$). **All metrics are reported transparently without artificial smoothing or data leakage.**

---

## Production Reliability, Co-Simulation & Prognostics Upgrades

### 1. Closed-Loop Python <-> MATLAB Co-Simulation Bridge
- Implemented in [scripts/simulation/co_simulation_bridge.py](file:///c:/EdgeTwin-2S/scripts/simulation/co_simulation_bridge.py) with full test coverage in [tests/test_closed_loop_twin.py](file:///c:/EdgeTwin-2S/tests/test_closed_loop_twin.py).
- Closes the co-simulation loop: Twin Physics Step (step_compressor_twin.m) $\to$ ML Feature Contract (predict_reading) $\to$ Supervisory Diagnostics (diagnose_fault_and_actuate.m) $\to$ Filtered Actuator Feedback $\to$ Twin State Relaxation.
- Operates via in-process bridge or local TCP JSON socket IPC server, complete with a continuous mathematical twin emulator for headless CI environments where MATLAB desktop is unavailable.

### 2. Crash-Safe SQLite WAL Event Store with Process-Kill Recovery Proof
- Implemented in [scripts/ml/event_store.py](file:///c:/EdgeTwin-2S/scripts/ml/event_store.py) and verified in [tests/test_event_store_crash_recovery.py](file:///c:/EdgeTwin-2S/tests/test_event_store_crash_recovery.py).
- Uses PRAGMA journal_mode = WAL; and explicit state machine: PENDING $\to$ IN_FLIGHT $\to$ ACKED.
- Mid-flight crash resilience: Any event left in IN_FLIGHT state when an edge process is abruptly killed (SIGKILL / power outage) automatically recovers into PENDING retry queue upon restart, ensuring **zero lost events** and **zero duplicate deliveries**.

### 3. Per-Alert Sensor Attribution & NASA C-MAPSS RUL Prognostics
- Fast per-alert sensor attribution in [scripts/ml/predict.py](file:///c:/EdgeTwin-2S/scripts/ml/predict.py): identifies top driving sensors, direction (HIGH/LOW), sigma-deviation, and attribution percentage share per anomaly alert.
- Dedicated turbofan prognostic module in [scripts/ml/cmapss_rul.py](file:///c:/EdgeTwin-2S/scripts/ml/cmapss_rul.py) evaluated on NASA C-MAPSS FD001 ( = 18.37\text{ cycles}$), estimating Remaining Useful Life (RUL) and Health Index (.0 \to 1.0$) with explicit scope disclaimers distinguishing turbofan fleet prognostics from reciprocating compressor diagnostics.

### 4. Streaming Drift Detection (REGIME_SHIFT_DETECTED)
- Streaming window drift detector using Page-Hinkley and Population Stability Index (PSI).
- Distinctly surfaces REGIME_SHIFT_DETECTED and operational recalibration advisories when sustained operational shifts occur without acute fault spikes.

### 5. Production Packaging & CI Automation
- **Containerization**: [Dockerfile](file:///c:/EdgeTwin-2S/Dockerfile) providing automated containerized test execution with model pre-warming.
- **Continuous Integration**: [.github/workflows/ci.yml](file:///c:/EdgeTwin-2S/.github/workflows/ci.yml) running repository hygiene checks, cross-regime evaluation, C-MAPSS RUL verification, and pytest suites.

---

## Inference Latency Benchmark (Section 7 & 11.1)

Timed benchmark measuring 500 consecutive calls to `predict_reading()` on valid 8-feature readings.
- **Explicit Benchmark Boundary**: Local Python `predict_reading()` function call only (excluding network, I/O, and dashboard rendering).
- **Sub-10ms Optimization**: Passing pre-allocated NumPy array directly to Cython decision trees bypasses single-row DataFrame construction and joblib generator dispatch overhead.

| Metric | Measured Value | SLA Target | Unit | Definition |
| :--- | :---: | :---: | :---: | :--- |
| **Median Latency** | **2.60** | < 20.0 | ms | 50th percentile execution time (**sub-10ms achieved**) |
| **P95 Latency** | **4.83** | < 50.0 | ms | 95th percentile execution time |
| **P99 Latency** | **6.84** | < 100.0 | ms | 99th percentile tail execution time |
| **Max Latency** | **55.32** | - | ms | Worst-case single-call execution time |
| **Mean Latency** | **2.84** | < 20.0 | ms | Arithmetic mean execution time |

Full raw data recorded in [reports/latency_benchmark.json](file:///c:/EdgeTwin-2S/reports/latency_benchmark.json).

---

## Offline Store-and-Forward & WAN Outage Proof

To guarantee continuous zero-data-loss factory operations during network partitions or broker disconnects, EdgeSentinel implements a local store-and-forward audit queue (`EventStore`).

Replay script: `python scripts/ml/run_offline_edge_demo.py` verifies 3 distinct operational phases:
1. **Phase A (Online Normal Mode)**: Continuous streaming and real-time TLS/MQTT delivery to the remote receiver (20 samples forwarded, 0 buffered).
2. **Phase B (Simulated WAN Outage)**: Simulated carrier drop. 30 telemetry frames and alert events are automatically spooled to local persistent disk (`reports/offline_demo_store.csv`). Deliberately injected duplicate event IDs (5 attempts) are idempotently rejected (`0 duplicates`), while out-of-order frames are strictly sorted by event timestamp.
3. **Phase C (WAN Reconnect & Reconciliation)**: Connectivity restored. The local queue seamlessly drains all 30 spooled events in strict chronological sequence into the remote broker (50 total unique events delivered, 0 dropped, 0 duplicate alerts).

Full execution trace recorded in [reports/offline_outage_resilience_report.json](file:///c:/EdgeTwin-2S/reports/offline_outage_resilience_report.json).

---

## Automated Verification & Test Instructions

Every test in this repository is **assertion-based** and exits with status `0` upon full pass or non-zero (`1`) upon any failure.

### 1. Section 11.1 Minimum Test Matrix Suite (`tests/test_panel_matrix.py`)
Executes all 6 validation gates required by Problem Statement 5:
```bash
python tests/test_panel_matrix.py
```
- Gate A: Normal & Known Fault classification validity.
- Gate B: Incomplete 5-sensor contract enforcement (`UNAVAILABLE`).
- Gate C: Sensor dropout, non-numeric strings, `NaN`, and `Inf` rejection.
- Gate D: Deduplication, event-time ordering, and store-and-forward buffer (`scripts/ml/event_store.py`).
- Gate E: 500-call sub-10ms latency percentiles verification (median < 20 ms).
- Gate F: 3-phase offline WAN outage demonstration and store-and-forward proof.
- Output saved to [reports/test_suite_report.json](file:///c:/EdgeTwin-2S/reports/test_suite_report.json).

### 2. Comprehensive 10-Point Accuracy & Calibration Audit (`tests/test_accuracy_audit.py`)
```bash
python tests/test_accuracy_audit.py
```
- Verifies model bundle byte equivalence and SHA256 integrity.
- Asserts strict 8-feature contract and zero feature fabrication.
- Confirms zero data leakage across train (1..8), val (9..10), and held-out test (11..14).
- Validates monotonicity and calibration sweep across thresholds [0.20, 0.60].
- Output saved to [reports/accuracy_audit_report.json](file:///c:/EdgeTwin-2S/reports/accuracy_audit_report.json) and [reports/accuracy_audit_report.txt](file:///c:/EdgeTwin-2S/reports/accuracy_audit_report.txt).

### 3. Offline Store-and-Forward Edge Demonstration (`scripts/ml/run_offline_edge_demo.py`)
```bash
python scripts/ml/run_offline_edge_demo.py
```
- Validates online streaming, local spooling during simulated outage, and seamless chronological drain upon recovery.

### 4. Standard ML Pipeline Unit Tests (`tests/test_ml_pipeline.py`)
```bash
python tests/test_ml_pipeline.py
# Or with pytest:
pytest tests/ -v
```

### 5. MATLAB Verification Suite (`tests/run_edgesentinel_verify.m`)
Runs all 9 automated verification phases across the digital twin, actuator responses, signal contracts, subsystem attribution, and custom value handling:
```bash
matlab -batch "addpath(genpath('C:\EdgeSentinel_Submission')); res = run_edgesentinel_verify();"
```
Verification phases covered:
1. Configuration and parameter initialization checks.
2. 8/8 Compressor twin scenario physics (`NORMAL`, `OVERTEMP_IC`, `OVERPRESSURE_HP`, `OVERSPEED_RPM`, `HIGH_VIBRATION`, `VALVE_LEAKAGE`, `MULTI_ABNORMAL`, `SENSOR_FAULT`).
3. Strict sensor fault handling for out-of-range (`-99.9` bar) and missing (`NaN`) signals.
4. Closed-loop actuator physics responses across all 5 core actuators (`MotorStop`, `Unloader`, `CoolingFan`, `Drain`, `SpeedTrim`).
5. Signal bounds checking and nominal preprocessing limits.
6. Strict ML scope honesty contract (quarantines 5-sensor compressor data without synthetic feature fabrication).
7. Subsystem part identification, potential machine impact analysis, advisory labels, and telemetry highlighting.
8. Arbitrary custom sensor injection and compound multi-fault diagnostics.
9. Extreme custom temperature classification: asserts that 2000°C thermal runaway is correctly classified as `HIGH TEMP (IC)` (fault code 1), commands `COOLING_FAN`, and is never misclassified as a sensor fault.

Report saved to [reports/matlab_verify_report.txt](file:///c:/EdgeTwin-2S/reports/matlab_verify_report.txt).

### 6. Interactive SCADA-HMI Dashboard (`app/EdgeSentinel_Dashboard.m`)
Launch MATLAB and run:
```matlab
cd('C:\EdgeSentinel_Submission');
addpath(genpath(pwd));
EdgeSentinel_Dashboard();
```

Key operator visualization features:
- **5-Actuator Supervisory Control Suite with Live State Feedback**: Features 5 distinct industrial compressor actuators:
  1. `Actuate Unloader`: Drops HP discharge pressure by $-5.5$ bar, motor electrical load by $-12$ A, and vibration by $-2.8$ mm/s.
  2. `Actuate CoolingFan`: Drops intercooler temperature by $-52^\circ\text{C}$ (or by $-65\%$ under extreme runaway $> 500^\circ\text{C}$), relieving `OVERTEMP_IC` into safe operating limits.
  3. `Actuate Drain`: Purges interstage condensate receiver, relieving vibration by $-2.2$ mm/s, HP pressure by $-1.8$ bar, and LP pressure by $-1.0$ bar.
  4. `VFD Speed Trim`: Inverter speed governor trim reducing shaft speed by $-22\%$ ($-350$ to $-440$ RPM), motor current by $-18\%$, and mechanical vibration by $-2.5$ mm/s, mitigating `OVERSPEED_RPM`.
  5. `Sim MotorStop`: Supervisory drive trip halting shaft rotation ($0$ RPM, $0$ A), venting pressure towards atmospheric ($1.01$ bar), and eliminating vibration ($0.25$ mm/s).
  Buttons feature instantaneous visual feedback with dynamic color states (active green `[ON]` / `[VENT]` / `[PURGING]`, active bright red `[TRIP]`, and inactive blue/dark red `[OFF]` / `[IDLE]`), live supervisory state readout (`● STATUS: MITIGATED / ACTIVE CONTROL [...]` and `● STATUS: COMPRESSOR STOPPED`), and immediate event logging to `reports/persistent_event_store.csv`.
- **Interactive Clickable Telemetry Graphs**: Live dual-axis trend plots (`HP Pressure & IC Temp`, `Vibration & Current`) feature interactive click inspection (`@onPlotClick`). Clicking any point or timestamp on either plot dynamically updates the top inspection banner (`lblPlotInspect`) with exact sample telemetry ($P_{hp}$, $T_{ic}$, $Vib$, $Current$), anomaly classification, and machine part attribution, drawing a high-contrast vertical cursor line across both graphs.
- **Interactive Custom Sensor Values & Arbitrary Combinations**: Dedicated control subpanel allowing live entry of custom sensor values (`T_ic`, `P_hp`, `P_lp`, `RPM`, `Vib`, `Current`), quick combination presets (including *1. High Temp Overheat (2000°C Thermal Runaway)*, *2. Compound High Temp (165°C) + High Press (12.8 bar)*, *3. Compound High Vib (8.4 mm/s) + Overspeed (1980 RPM)*, *4. Valve Leak + Hot Recirc*, *5. Extreme 4-Way Overload*), quick transducer fault injection (`-99.9 bar` and `NaN`), and a `Random Mix Generator` to test and demonstrate arbitrary operating conditions on the fly.
- **Physical Thermal Classification (2000°C Thermal Runaway)**: Extreme temperatures (e.g. 2000°C) are classified as physical high-temperature / abnormal thermal conditions (`fault_code = 1` or compound multi-fault), commanding `COOLING_FAN` and attributing distress to the `Intercooler`. `SENSOR_FAULT` is strictly reserved for corrupt/impossible signals (`NaN`, `Inf`, `-99.9` bar).
- **Abnormal Graph Highlighting**: Whenever any monitored parameter breaches limits or a fault scenario is active, abnormal telemetry samples on both live dual-axis trend plots are highlighted with distinct high-visibility markers (`o`, `s`, `^`, `d`) and alert-tinted axis backgrounds. The styling resets cleanly and immediately back to calm nominal colors when returning to `NORMAL` operation or clicking `RESET`.
- **Enlarged Diagnostics Typography**: Enlarged font sizes across all diagnostic cards (`11.5 pt` status, `11 pt` bold affected part, `10 pt` impact and fix) inside a responsive scrollable container ensuring zero text clipping across any screen resolution or DPI scaling.
- **Affected Machine Part Card**: Dynamically identifies the exact compressor subsystem or component experiencing distress (e.g., `Interstage Intercooler`, `HP Stage Head & Receiver Tank`, `Motor Drive & Crankshaft Speed Governor`, `Crankcase, Bearings & Structural Mounts`, `LP / HP Suction & Discharge Valve Plates`, or `HP Pressure Transducer / Signal Path`).
- **Potential Machine Impact Readout**: Explains plain-language operational consequences if the condition persists (e.g., oil breakdown and thermal valve fatigue, excessive mechanical cycle pressure stress, bearing spallation, gas recirculation/flow loss, or corrupted closed-loop telemetry).
- **Clarified Stage Compression Ratio Readout**: Explicitly labeled `Stage Compression Ratio (P_hp / P_lp)` with nominal reference `[Nominal >= 2.20]` (or `CORRUPTED [Sensor Fault]`) to provide immediate context during live evaluations.
- **Explicit Advisory Notice Banner**: Prominently displays safety disclaimer noting that recommendations are simulated supervisory digital-twin heuristics and independent hardwired SIL-3 emergency stops operate autonomously in real plants.
- **Persistent Event Store**: Every operational event is automatically logged to [reports/persistent_event_store.csv](file:///c:/EdgeTwin-2S/reports/persistent_event_store.csv) with unique `event_id`, `model_version`, and `ack_status`, ensuring history survives session restarts.
