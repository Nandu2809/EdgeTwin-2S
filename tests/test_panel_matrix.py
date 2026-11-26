"""
MAH Quantum / IBM watsonx / Team Quanta Core Industrial Verification Test Matrix.
Problem Statement 5 - Section 11.1 Minimum Test Matrix Suite.

Verifies:
1. Normal & Known Faults: Valid probabilities in [0, 1] and correct class outputs.
2. Incomplete 5-Sensor Input: Strict UNAVAILABLE contract without synthetic data injection.
3. Sensor Dropout / Invalid Values: Non-numeric, NaN, Inf, and missing fields handled safely.
4. Duplicate / Out-of-Order Event Deduplication & Store-and-Forward Buffer (scripts/ml/event_store.py).
5. Latency Benchmark: 500 timed predict_reading() calls -> reports/latency_benchmark.json.
6. Execution summary saved to reports/test_suite_report.json (exit code 0 on pass, 1 on fail).
"""

import sys
import time
import json
import unittest
from pathlib import Path
from datetime import datetime
import numpy as np
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from scripts.ml.predict import predict_reading, REQUIRED_FEATURES, threshold, model_version
from scripts.ml.event_store import EventStore
from scripts.ml.run_offline_edge_demo import run_offline_edge_demo

REPORTS_DIR = PROJECT_ROOT / "reports"


class TestPanelMatrix(unittest.TestCase):
    """Section 11.1 Minimum Test Matrix Suite."""

    @classmethod
    def setUpClass(cls):
        """Prepare sample test vectors."""
        cls.normal_8_reading = {
            "Accelerometer1RMS": 0.0820647,
            "Accelerometer2RMS": 0.133521,
            "Current": 1.27794,
            "Pressure": 0.054711,
            "Temperature": 92.2562,
            "Thermocouple": 22.2577,
            "Voltage": 209.639,
            "Volume Flow RateRMS": 76.0197
        }
        cls.five_sensor_compressor = {
            "temperature": 85.0,
            "vibration": 1.85,
            "pressure": 8.1,
            "current": 24.2,
            "speed": 1485.0
        }

    # =========================================================================
    # Test 1: Normal & Known Faults (Section 11.1 Item A)
    # =========================================================================
    def test_normal_and_known_faults(self):
        """Verify normal and anomaly readings yield valid probabilities and classes."""
        # Normal reading test
        res_norm = predict_reading(self.normal_8_reading)
        self.assertTrue(res_norm["ml_available"])
        self.assertIn(res_norm["status"], {"NORMAL", "ANOMALY"})
        self.assertIsInstance(res_norm["anomaly_probability"], float)
        self.assertTrue(0.0 <= res_norm["anomaly_probability"] <= 1.0)
        self.assertTrue(np.isfinite(res_norm["anomaly_probability"]))
        self.assertIn("top_contributor", res_norm)
        self.assertIn("top_contributors", res_norm)
        self.assertIn("contributing_features", res_norm)
        self.assertIn("regime_note", res_norm)
        self.assertIsInstance(res_norm["regime_note"], str)
        self.assertGreater(len(res_norm["regime_note"]), 0)

        # Real held-out anomaly row test (from other/11.csv)
        data_path = PROJECT_ROOT / "data" / "raw" / "skab" / "other" / "11.csv"
        if not data_path.exists():
            data_path = PROJECT_ROOT / "data" / "raw" / "SKAB" / "data" / "other" / "11.csv"

        if data_path.exists():
            df = pd.read_csv(data_path, sep=";")
            anom_rows = df[df["anomaly"] == 1]
            if len(anom_rows) > 0:
                anom_sample = {f: float(anom_rows.iloc[0][f]) for f in REQUIRED_FEATURES}
                res_anom = predict_reading(anom_sample)
                self.assertTrue(res_anom["ml_available"])
                self.assertTrue(0.0 <= res_anom["anomaly_probability"] <= 1.0)

    # =========================================================================
    # Test 2: Incomplete 5-Sensor Input (Section 11.1 Item B)
    # =========================================================================
    def test_incomplete_five_sensor_input(self):
        """Incomplete 5-sensor compressor telemetry must return UNAVAILABLE without fabricating values."""
        res = predict_reading(self.five_sensor_compressor)
        self.assertEqual(res["status"], "UNAVAILABLE")
        self.assertFalse(res["ml_available"])
        self.assertIsNone(res["anomaly_probability"])
        self.assertIn("missing_features", res)
        self.assertGreater(len(res["missing_features"]), 0)
        self.assertIn("REQUIRED FEATURES MISSING", res["message"])

        # Confirm strict missing list contains SKAB-only sensors
        missing_set = set(res["missing_features"])
        self.assertTrue({"Accelerometer1RMS", "Accelerometer2RMS", "Thermocouple", "Voltage", "Volume Flow RateRMS"}.issubset(missing_set))

    # =========================================================================
    # Test 3: Sensor Dropout / Invalid Values (Section 11.1 Item C)
    # =========================================================================
    def test_sensor_dropout_and_invalid_values(self):
        """Verify missing fields, NaN, Inf, and non-numeric strings are handled safely."""
        # Missing field (7 of 8 features)
        partial = dict(self.normal_8_reading)
        del partial["Volume Flow RateRMS"]
        res_partial = predict_reading(partial)
        self.assertEqual(res_partial["status"], "UNAVAILABLE")
        self.assertFalse(res_partial["ml_available"])
        self.assertIn("Volume Flow RateRMS", res_partial["missing_features"])

        # NaN rejection
        bad_nan = dict(self.normal_8_reading)
        bad_nan["Pressure"] = float("nan")
        with self.assertRaises(ValueError):
            predict_reading(bad_nan)

        # Inf rejection
        bad_inf = dict(self.normal_8_reading)
        bad_inf["Current"] = float("inf")
        with self.assertRaises(ValueError):
            predict_reading(bad_inf)

        # Non-numeric string rejection
        bad_str = dict(self.normal_8_reading)
        bad_str["Temperature"] = "SENSOR_FAILURE_SIGNAL"
        with self.assertRaises(ValueError):
            predict_reading(bad_str)

        # Non-dict rejection
        with self.assertRaises(ValueError):
            predict_reading("invalid_container_string")

    # =========================================================================
    # Test 4: Deduplication & Store-and-Forward Buffer (Section 11.1 Item D)
    # =========================================================================
    def test_deduplication_and_store_and_forward_buffer(self):
        """Verify event deduplication, event-time ordering, and store-and-forward outage reconciliation."""
        test_csv_path = REPORTS_DIR / "test_store_audit.csv"
        for p in [test_csv_path, test_csv_path.with_suffix(".sqlite"),
                  test_csv_path.with_suffix(".sqlite-wal"), test_csv_path.with_suffix(".sqlite-shm")]:
            if p.exists():
                try:
                    p.unlink()
                except Exception:
                    pass

        store = EventStore(persistence_file=test_csv_path)
        store.clear()

        # Ingest events out-of-order: t=30, t=10, t=20
        e1 = {"event_id": "EVT-001", "timestamp": "2026-11-19T10:00:30", "scenario": "NORMAL", "p_hp_bar": 8.1}
        e2 = {"event_id": "EVT-002", "timestamp": "2026-11-19T10:00:10", "scenario": "NORMAL", "p_hp_bar": 8.0}
        e3 = {"event_id": "EVT-003", "timestamp": "2026-11-19T10:00:20", "scenario": "NORMAL", "p_hp_bar": 8.2}

        self.assertTrue(store.insert_event(e1))
        self.assertTrue(store.insert_event(e2))
        self.assertTrue(store.insert_event(e3))

        # Idempotency / Deduplication test: re-insert e2
        duplicate_accepted = store.insert_event(e2)
        self.assertFalse(duplicate_accepted, "Duplicate event_id must be rejected idempotently")

        # Verify event-time ordering in buffer (should be EVT-002 [10:00:10], EVT-003 [10:00:20], EVT-001 [10:00:30])
        buf = store.get_buffered_events()
        self.assertEqual(len(buf), 3)
        self.assertEqual(buf[0]["event_id"], "EVT-002")
        self.assertEqual(buf[1]["event_id"], "EVT-003")
        self.assertEqual(buf[2]["event_id"], "EVT-001")

        # Simulated WAN Outage: flush with simulated_outage=True
        outage_res = store.flush_forward(simulated_outage=True)
        self.assertEqual(outage_res["status"], "BUFFERED_OUTAGE")
        self.assertEqual(len(store.get_buffered_events()), 3, "Buffer must remain intact during outage")

        # Verify restart-safety: reopen EventStore on disk and assert pending events reload cleanly
        restarted_store = EventStore(persistence_file=test_csv_path)
        restarted_buf = restarted_store.get_buffered_events()
        self.assertEqual(len(restarted_buf), 3, "Restarted store must reload all unacknowledged pending events")
        self.assertEqual(restarted_buf[0]["event_id"], "EVT-002")
        self.assertEqual(restarted_buf[1]["event_id"], "EVT-003")
        self.assertEqual(restarted_buf[2]["event_id"], "EVT-001")

        # WAN Recovery / Reconciliation: flush with simulated_outage=False from restarted store
        delivered_order = []

        def mock_broker(evt):
            delivered_order.append(evt["event_id"])
            return True

        recovery_res = restarted_store.flush_forward(sink_fn=mock_broker, simulated_outage=False)
        self.assertEqual(recovery_res["status"], "RECONCILED")
        self.assertEqual(recovery_res["forwarded_count"], 3)
        self.assertEqual(len(restarted_store.get_buffered_events()), 0, "Buffer must be empty after reconciliation")
        self.assertEqual(delivered_order, ["EVT-002", "EVT-003", "EVT-001"], "Broker must receive events in event-time order")

        # Verify durable ACK persistence across subsequent restart
        reopened_post_ack = EventStore(persistence_file=test_csv_path)
        self.assertEqual(len(reopened_post_ack.get_buffered_events()), 0, "Acknowledged events must not reload into pending buffer")
        self.assertTrue(reopened_post_ack.is_acknowledged("EVT-001"))
        self.assertTrue(reopened_post_ack.is_acknowledged("EVT-002"))
        self.assertTrue(reopened_post_ack.is_acknowledged("EVT-003"))
        self.assertFalse(reopened_post_ack.insert_event(e1), "Delivered acknowledged events must be rejected as duplicates")

        # Verify persistent CSV exists and contains rows
        self.assertTrue(test_csv_path.exists())
        with open(test_csv_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
            self.assertGreaterEqual(len(lines), 4)  # 1 header + 3 rows

        # Clean up test audit file
        for p in [test_csv_path, test_csv_path.with_suffix(".sqlite"),
                  test_csv_path.with_suffix(".sqlite-wal"), test_csv_path.with_suffix(".sqlite-shm")]:
            if p.exists():
                try:
                    p.unlink()
                except Exception:
                    pass

    # =========================================================================
    # Test 5: Latency Benchmark (Section 7 & 11.1 Item E)
    # =========================================================================
    def test_latency_benchmark(self):
        """Run 500 timed inference calls on predict_reading() and export reports/latency_benchmark.json."""
        latencies_ms = []
        n_trials = 500

        # Dedicated warm-up: 25 calls to prime Python byte-compilation and CPU cache
        for _ in range(25):
            predict_reading(self.normal_8_reading)

        # Timed benchmark: Local Python predict_reading() in-memory execution boundary only
        for _ in range(n_trials):
            t0 = time.perf_counter()
            predict_reading(self.normal_8_reading)
            t1 = time.perf_counter()
            latencies_ms.append((t1 - t0) * 1000.0)

        lat_arr = np.array(latencies_ms)
        median_ms = round(float(np.median(lat_arr)), 3)
        p95_ms = round(float(np.percentile(lat_arr, 95)), 3)
        p99_ms = round(float(np.percentile(lat_arr, 99)), 3)
        p999_ms = round(float(np.percentile(lat_arr, 99.9)), 3)
        max_ms = round(float(np.max(lat_arr)), 3)
        min_ms = round(float(np.min(lat_arr)), 3)
        mean_ms = round(float(np.mean(lat_arr)), 3)
        std_ms = round(float(np.std(lat_arr)), 3)

        self.assertGreater(median_ms, 0.0, "Inference median latency must be positive")
        self.assertLess(median_ms, 20.0, f"Optimized inference median latency must be well below 20 ms, got {median_ms} ms")
        self.assertLess(p95_ms, 30.0, f"Tail latency p95 must be below 30 ms, got {p95_ms} ms")
        self.assertGreaterEqual(max_ms, median_ms, "Max latency must be >= median latency")

        benchmark_payload = {
            "benchmark_name": "EdgeSentinel Section 11.1 Inference Latency Benchmark",
            "benchmark_boundary": "local Python predict_reading() function call only (excluding network, I/O, and dashboard rendering)",
            "measurement_scope": (
                "Software-only execution timing of local Python predict_reading() in memory. "
                "Excludes physical transducer ADC conversion, hardware fieldbus propagation, "
                "MQTT/TLS broker network hops, and UI rendering. Physical hardware and broker "
                "telemetry latencies are simulated."
            ),
            "model_version": model_version,
            "num_calls": n_trials,
            "warmup_calls": 25,
            "median_ms": median_ms,
            "p95_ms": p95_ms,
            "p99_ms": p99_ms,
            "p999_ms": p999_ms,
            "max_ms": max_ms,
            "min_ms": min_ms,
            "mean_ms": mean_ms,
            "std_ms": std_ms,
            "sla_threshold_ms": 20.0,
            "sla_passed": bool(median_ms < 20.0),
            "timestamp": datetime.now().isoformat()
        }

        REPORTS_DIR.mkdir(parents=True, exist_ok=True)
        with open(REPORTS_DIR / "latency_benchmark.json", "w", encoding="utf-8") as f:
            json.dump(benchmark_payload, f, indent=2)

        print("\n" + "=" * 65)
        print(" Latency Benchmark Summary (500 timed predict_reading calls):")
        print(f"   Median: {median_ms} ms | P95: {p95_ms} ms | P99: {p99_ms} ms | Max: {max_ms} ms")
        print("=" * 65)

    # =========================================================================
    # Test 6: Offline Store-and-Forward & WAN Outage Resilience Proof
    # =========================================================================
    def test_offline_wan_outage_resilience(self):
        """Verify 3-phase offline store-and-forward edge demonstration and report generation."""
        report = run_offline_edge_demo()
        self.assertIsInstance(report, dict)
        self.assertEqual(report["status"], "PASS")
        self.assertEqual(report["exit_code"], 0)
        self.assertEqual(report["phases"]["phase_a_normal_operation"]["delivered_to_broker"], 20)
        self.assertEqual(report["phases"]["phase_b_simulated_wan_outage"]["events_spooled_locally"], 30)
        self.assertEqual(report["phases"]["phase_b_simulated_wan_outage"]["duplicates_rejected_idempotently"], 5)
        self.assertEqual(report["phases"]["phase_c_wan_reconnection"]["total_events_at_broker"], 50)
        self.assertEqual(report["phases"]["phase_c_wan_reconnection"]["dropped_alerts"], 0)
        self.assertTrue(report["phases"]["phase_c_wan_reconnection"]["chronological_order_verified"])

        out_json = REPORTS_DIR / "offline_outage_resilience_report.json"
        self.assertTrue(out_json.exists(), "offline_outage_resilience_report.json must be written to reports/")


def run_suite_and_export_report() -> int:
    """Execute test suite and export reports/test_suite_report.json with proper exit code and dynamic checklist."""
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestPanelMatrix)
    runner = unittest.TextTestRunner(verbosity=2)
    start_time = datetime.now()
    result = runner.run(suite)
    end_time = datetime.now()

    all_passed = result.wasSuccessful()

    # Dynamically derive checklist status from real test execution results
    failed_test_names = {
        test.id().split(".")[-1]
        for test, _ in result.failures + result.errors
    }

    report = {
        "test_suite_name": "MAH Quantum Section 11.1 Minimum Test Matrix Suite",
        "timestamp_start": start_time.isoformat(),
        "timestamp_end": end_time.isoformat(),
        "duration_seconds": round((end_time - start_time).total_seconds(), 3),
        "total_tests_run": result.testsRun,
        "failures_count": len(result.failures),
        "errors_count": len(result.errors),
        "overall_status": "PASS" if all_passed else "FAIL",
        "exit_code": 0 if all_passed else 1,
        "coverage_checklist": {
            "A_normal_and_known_faults": "FAIL" if "test_normal_and_known_faults" in failed_test_names else "PASS",
            "B_incomplete_five_sensor_unavailable": "FAIL" if "test_incomplete_five_sensor_input" in failed_test_names else "PASS",
            "C_sensor_dropout_nan_inf_rejection": "FAIL" if "test_sensor_dropout_and_invalid_values" in failed_test_names else "PASS",
            "D_deduplication_and_store_forward_buffer": "FAIL" if "test_deduplication_and_store_and_forward_buffer" in failed_test_names else "PASS",
            "E_latency_benchmark_percentiles": "FAIL" if "test_latency_benchmark" in failed_test_names else "PASS",
            "F_offline_wan_outage_resilience": "FAIL" if "test_offline_wan_outage_resilience" in failed_test_names else "PASS"
        }
    }

    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(REPORTS_DIR / "test_suite_report.json", "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    print(f"\nSaved test suite report to {REPORTS_DIR / 'test_suite_report.json'}")
    return 0 if all_passed else 1


if __name__ == "__main__":
    exit_code = run_suite_and_export_report()
    sys.exit(exit_code)
