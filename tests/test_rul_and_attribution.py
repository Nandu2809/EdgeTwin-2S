"""
Test Suite for Per-Alert Sensor Attribution, Streaming Drift Detection, and C-MAPSS RUL Prognostics.

Verifies:
1. Fast Per-Alert Sensor Attribution: Direction (HIGH/LOW), sigma-deviation, and attribution percentage share.
2. Streaming Drift Detection & Regime-Shift Flagging: Page-Hinkley / PSI detection, REGIME_SHIFT_DETECTED status, and recalibration advisory.
3. NASA C-MAPSS Remaining Useful Life (RUL) Module: Dataset loading, piecewise-linear RUL training, RMSE validation, and Health Index computation.
4. Scope Disclaimers: Validates honest disclaimers distinguishing C-MAPSS turbofan modeling from the compressor twin.
"""

import sys
import unittest
import numpy as np
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from scripts.ml.predict import predict_reading, StreamingDriftDetector
from scripts.ml.cmapss_rul import (
    train_cmapss_rul_model,
    estimate_engine_rul,
    get_cached_rul_bundle,
    RUL_MODEL_PATH,
    RUL_REPORT_PATH
)


class TestRULAndAttribution(unittest.TestCase):
    """Test suite for sensor attribution, drift detection, and RUL prognostics."""

    def test_01_per_alert_sensor_attribution_direction_and_share(self):
        """Verify per-alert sensor attribution returns direction, sigma deviation, and share percentage."""
        # Reading with heavily elevated sensors triggering anomaly alert
        reading = {
            "Accelerometer1RMS": 0.45,
            "Accelerometer2RMS": 0.35,
            "Current": 2.12,
            "Pressure": 0.38,
            "Temperature": 125.0,
            "Thermocouple": 32.0,
            "Voltage": 230.5,
            "Volume Flow RateRMS": 135.0
        }

        res = predict_reading(reading)
        self.assertEqual(res["status"], "ANOMALY")
        self.assertIn("sensor_attribution", res)
        self.assertIsInstance(res["sensor_attribution"], list)
        self.assertGreaterEqual(len(res["sensor_attribution"]), 1)

        # Top attributing sensor direction and deviation
        top_attr = res["sensor_attribution"][0]
        self.assertEqual(top_attr["direction"], "HIGH")
        self.assertGreater(top_attr["deviation_sigma"], 1.5)
        self.assertGreater(top_attr["attribution_share_pct"], 15.0)

        # Attribution summary text should mention sensor and direction
        self.assertIn("attribution_summary", res)
        self.assertIn("HIGH", res["attribution_summary"])

    def test_02_streaming_drift_detector_and_regime_shift_flag(self):
        """Verify drift detector surfaces REGIME_SHIFT_DETECTED and advisory on sustained setpoint shift."""
        detector = StreamingDriftDetector(window_size=50, psi_threshold=0.25)

        # Feed 30 shifted observations (e.g. constant shifted valve pressure)
        shifted_vector = [0.165, 0.210, 2.12, 0.38, 120.0, 25.5, 230.5, 60.0]
        for _ in range(35):
            drift_detected, psi_score, advisory = detector.update(shifted_vector)

        self.assertTrue(drift_detected, "Sustained shift must trigger drift detection")
        self.assertGreaterEqual(psi_score, 0.25)
        self.assertIn("recalibration", advisory.lower())

        # Test predict_reading with check_drift=True
        reading = {
            "Accelerometer1RMS": shifted_vector[0],
            "Accelerometer2RMS": shifted_vector[1],
            "Current": shifted_vector[2],
            "Pressure": shifted_vector[3],
            "Temperature": shifted_vector[4],
            "Thermocouple": shifted_vector[5],
            "Voltage": shifted_vector[6],
            "Volume Flow RateRMS": shifted_vector[7]
        }
        res = predict_reading(reading, check_drift=True, drift_detector=detector)
        self.assertTrue(res["regime_shift_detected"])
        self.assertEqual(res["status"], "REGIME_SHIFT_DETECTED")
        self.assertIsNotNone(res["recalibration_advisory"])

    def test_03_cmapss_rul_training_and_rmse_bound(self):
        """Verify C-MAPSS RUL model training, metric report generation, and RMSE bound."""
        metrics = train_cmapss_rul_model(dataset_name="FD001", n_estimators=40, max_depth=10)

        self.assertIn("rmse_cycles", metrics)
        self.assertLess(metrics["rmse_cycles"], 25.0, "C-MAPSS FD001 RMSE must be < 25 cycles")
        self.assertIn("nasa_score", metrics)
        self.assertTrue(RUL_REPORT_PATH.exists())

        # Check disclaimer
        self.assertIn("prognostic_scope_disclaimer", metrics)
        self.assertIn("turbofan", metrics["prognostic_scope_disclaimer"].lower())

    def test_04_cmapss_rul_inference_and_health_index(self):
        """Verify single engine observation RUL and Health Index estimation."""
        # Simulated observation with moderate wear
        sample_sensors = {
            "s2": 642.35,
            "s3": 1585.20,
            "s4": 1404.50,
            "s7": 553.80,
            "s8": 2388.06,
            "s9": 9050.10,
            "s11": 47.35,
            "s12": 521.80,
            "s13": 2388.05,
            "s14": 8130.20,
            "s15": 8.42,
            "s17": 392.0,
            "s20": 38.85,
            "s21": 23.35
        }

        est = estimate_engine_rul(sample_sensors)
        self.assertEqual(est["status"], "SUCCESS")
        self.assertIsInstance(est["predicted_rul_cycles"], float)
        self.assertGreaterEqual(est["predicted_rul_cycles"], 0.0)
        self.assertTrue(0.0 <= est["health_index"] <= 1.0)
        self.assertIn(est["prognostic_status"], {"HEALTHY_NOMINAL", "MAINTENANCE_DUE", "CRITICAL_MAINTENANCE_REQUIRED"})
        self.assertGreaterEqual(len(est["top_degrading_sensors"]), 1)
        self.assertIn("prognostic_scope_disclaimer", est)

    def test_05_cmapss_rul_nan_none_and_invalid_guard(self):
        """Verify estimate_engine_rul guards against missing, None, NaN, Inf, and non-numeric values."""
        valid_sample = {
            "s2": 642.35, "s3": 1585.20, "s4": 1404.50, "s7": 553.80,
            "s8": 2388.06, "s9": 9050.10, "s11": 47.35, "s12": 521.80,
            "s13": 2388.05, "s14": 8130.20, "s15": 8.42, "s17": 392.0,
            "s20": 38.85, "s21": 23.35
        }

        # Non-dict
        res = estimate_engine_rul(None)
        self.assertEqual(res["status"], "UNAVAILABLE")
        self.assertIsNone(res["predicted_rul_cycles"])

        # Missing feature
        partial = dict(valid_sample)
        del partial["s11"]
        res = estimate_engine_rul(partial)
        self.assertEqual(res["status"], "UNAVAILABLE")
        self.assertIn("Missing", res["message"])

        # None value
        with_none = dict(valid_sample)
        with_none["s11"] = None
        res = estimate_engine_rul(with_none)
        self.assertEqual(res["status"], "UNAVAILABLE")
        self.assertIn("s11=None", res["message"])

        # NaN value
        with_nan = dict(valid_sample)
        with_nan["s3"] = float("nan")
        res = estimate_engine_rul(with_nan)
        self.assertEqual(res["status"], "UNAVAILABLE")

        # Inf value
        with_inf = dict(valid_sample)
        with_inf["s7"] = float("inf")
        res = estimate_engine_rul(with_inf)
        self.assertEqual(res["status"], "UNAVAILABLE")

        # Non-numeric string
        with_str = dict(valid_sample)
        with_str["s2"] = "corrupt_data"
        res = estimate_engine_rul(with_str)
        self.assertEqual(res["status"], "UNAVAILABLE")

    def test_06_cmapss_rul_module_level_cache(self):
        """Verify module-level cache avoids reloading from disk when mtime is unchanged."""
        bundle1 = get_cached_rul_bundle(RUL_MODEL_PATH)
        bundle2 = get_cached_rul_bundle(RUL_MODEL_PATH)
        self.assertIs(bundle1, bundle2, "Cached bundle reference must be reused when file is unmodified")

    def test_07_cmapss_custom_output_dir(self):
        """Verify train_cmapss_rul_model writes cleanly to custom output_dir."""
        scratch_dir = PROJECT_ROOT / "reports" / "test_scratch_rul"
        if scratch_dir.exists():
            import shutil
            shutil.rmtree(scratch_dir)

        metrics = train_cmapss_rul_model(dataset_name="FD001", n_estimators=10, max_depth=5, output_dir=scratch_dir)
        self.assertTrue((scratch_dir / "cmapss_rul_model.joblib").exists())
        self.assertTrue((scratch_dir / "cmapss_rul_metrics.json").exists())
        self.assertIn("rmse_cycles", metrics)

        # Clean up
        import shutil
        shutil.rmtree(scratch_dir)


if __name__ == "__main__":
    unittest.main()
