"""
Automated Verification Suite for EdgeSentinel ML Pipeline (predict.py).

Verifies:
1. Strict 8-feature SKAB contract: Incomplete 5-sensor compressor telemetry
   returns status == 'UNAVAILABLE' and ml_available is False.
2. Complete valid 8-feature SKAB input returns ml_available is True,
   finite anomaly_probability in [0.0, 1.0], and status in {'NORMAL', 'ANOMALY'}.
3. Non-finite (NaN, Inf, -Inf) or non-numeric values cleanly raise ValueError.
4. Exit code discipline: Exits with 0 on pass, non-zero on any failure.
"""

import sys
import unittest
import math
from pathlib import Path
import numpy as np
import pandas as pd

# Add workspace root to sys.path
PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from scripts.ml.predict import predict_reading, REQUIRED_FEATURES, threshold, model_version


class TestMLPipeline(unittest.TestCase):
    """Test suite asserting strict contracts on predict.py."""

    def setUp(self):
        """Standard valid 8-feature sample and 5-sensor compressor sample."""
        self.five_sensor_sample = {
            "temperature": 75.0,
            "vibration": 0.22,
            "pressure": 7.2,
            "current": 18.0,
            "speed": 1450.0
        }

        self.valid_8_feature_sample = {
            "Accelerometer1RMS": 0.0820647,
            "Accelerometer2RMS": 0.133521,
            "Current": 1.27794,
            "Pressure": 0.054711,
            "Temperature": 92.2562,
            "Thermocouple": 22.2577,
            "Voltage": 209.639,
            "Volume Flow RateRMS": 76.0197
        }

    # =========================================================================
    # Test Category 1: Incomplete 5-sensor Telemetry & Contract Honesty
    # =========================================================================

    def test_five_sensor_telemetry_returns_unavailable(self):
        """Compressor 5-sensor telemetry must return UNAVAILABLE and not synthesize features."""
        result = predict_reading(self.five_sensor_sample)

        self.assertIsInstance(result, dict)
        self.assertEqual(result["status"], "UNAVAILABLE")
        self.assertIs(result["ml_available"], False)
        self.assertIsNone(result["anomaly_probability"])
        self.assertIn("missing_features", result)
        self.assertGreater(len(result["missing_features"]), 0)
        self.assertIn("REQUIRED FEATURES MISSING", result["message"])

        # Confirm missing features contain all SKAB-specific fields
        expected_missing = {"Accelerometer1RMS", "Accelerometer2RMS", "Thermocouple", "Voltage", "Volume Flow RateRMS"}
        actual_missing = set(result["missing_features"])
        self.assertTrue(expected_missing.issubset(actual_missing))

    def test_empty_dict_returns_unavailable(self):
        """Empty reading dictionary must return UNAVAILABLE with all 8 features missing."""
        result = predict_reading({})
        self.assertEqual(result["status"], "UNAVAILABLE")
        self.assertIs(result["ml_available"], False)
        self.assertIsNone(result["anomaly_probability"])
        self.assertEqual(set(result["missing_features"]), set(REQUIRED_FEATURES))

    def test_partial_features_returns_unavailable(self):
        """Missing even 1 of the 8 required features must strictly return UNAVAILABLE."""
        for feat in REQUIRED_FEATURES:
            partial_sample = dict(self.valid_8_feature_sample)
            del partial_sample[feat]
            result = predict_reading(partial_sample)
            self.assertEqual(result["status"], "UNAVAILABLE", f"Failed for missing feature: {feat}")
            self.assertIs(result["ml_available"], False)
            self.assertIn(feat, result["missing_features"])

    def test_none_value_treated_as_missing(self):
        """A feature set to None must be treated as missing and return UNAVAILABLE."""
        sample_with_none = dict(self.valid_8_feature_sample)
        sample_with_none["Pressure"] = None
        result = predict_reading(sample_with_none)
        self.assertEqual(result["status"], "UNAVAILABLE")
        self.assertIs(result["ml_available"], False)
        self.assertIn("Pressure", result["missing_features"])

    # =========================================================================
    # Test Category 2: Complete Valid 8-Feature SKAB Telemetry
    # =========================================================================

    def test_valid_eight_feature_inference_succeeds(self):
        """Complete 8-feature SKAB input must succeed with finite probability in [0, 1]."""
        result = predict_reading(self.valid_8_feature_sample)

        self.assertIsInstance(result, dict)
        self.assertIs(result["ml_available"], True)
        self.assertIn(result["status"], {"NORMAL", "ANOMALY"})

        prob = result["anomaly_probability"]
        self.assertIsInstance(prob, float)
        self.assertTrue(np.isfinite(prob))
        self.assertGreaterEqual(prob, 0.0)
        self.assertLessEqual(prob, 1.0)

        # Status must align with calibrated decision threshold
        if prob >= result["threshold"]:
            self.assertEqual(result["status"], "ANOMALY")
        else:
            self.assertEqual(result["status"], "NORMAL")

        # Explainability attributes
        self.assertIn("top_contributor", result)
        self.assertIn("top_contributors", result)
        self.assertIn("contributing_features", result)
        self.assertIsInstance(result["contributing_features"], list)
        self.assertIsInstance(result["top_contributors"], list)
        self.assertIn("regime_note", result)
        self.assertIsInstance(result["regime_note"], str)
        self.assertGreater(len(result["regime_note"]), 0)

    def test_alias_mapping_snake_case_support(self):
        """Lowercase snake_case aliases must map correctly to standard PascalCase features."""
        snake_sample = {
            "accelerometer1_rms": 0.082,
            "accelerometer2_rms": 0.133,
            "current": 1.28,
            "pressure": 0.055,
            "temperature": 92.25,
            "thermocouple": 22.26,
            "voltage": 209.6,
            "volume_flow_rate_rms": 76.02
        }
        result = predict_reading(snake_sample)
        self.assertIs(result["ml_available"], True)
        self.assertIn(result["status"], {"NORMAL", "ANOMALY"})
        self.assertTrue(0.0 <= result["anomaly_probability"] <= 1.0)

    def test_inference_on_real_heldout_dataset_rows(self):
        """Validate inference against real rows from held-out SKAB files."""
        skab_file = PROJECT_ROOT / "data" / "raw" / "skab" / "other" / "11.csv"
        if not skab_file.exists():
            self.skipTest(f"Held-out dataset file not found at {skab_file}")

        df = pd.read_csv(skab_file, sep=";")
        self.assertGreater(len(df), 100)

        # Test normal sample from file 11
        normal_row = df[df["anomaly"] == 0].iloc[0]
        normal_dict = {f: float(normal_row[f]) for f in REQUIRED_FEATURES}
        res_norm = predict_reading(normal_dict)
        self.assertIs(res_norm["ml_available"], True)
        self.assertTrue(0.0 <= res_norm["anomaly_probability"] <= 1.0)

        # Test anomaly sample from file 11
        anomaly_row = df[df["anomaly"] == 1].iloc[0]
        anomaly_dict = {f: float(anomaly_row[f]) for f in REQUIRED_FEATURES}
        res_anom = predict_reading(anomaly_dict)
        self.assertIs(res_anom["ml_available"], True)
        self.assertTrue(0.0 <= res_anom["anomaly_probability"] <= 1.0)

    # =========================================================================
    # Test Category 3: Non-Finite (NaN/Inf) & Non-Numeric Input Handling
    # =========================================================================

    def test_nan_raises_value_error(self):
        """NaN value in any required feature must raise ValueError."""
        for feat in REQUIRED_FEATURES:
            bad_sample = dict(self.valid_8_feature_sample)
            bad_sample[feat] = float("nan")
            with self.assertRaises(ValueError, msg=f"Should raise ValueError for NaN in {feat}"):
                predict_reading(bad_sample)

    def test_positive_inf_raises_value_error(self):
        """+Infinity in any required feature must raise ValueError."""
        bad_sample = dict(self.valid_8_feature_sample)
        bad_sample["Current"] = float("inf")
        with self.assertRaises(ValueError):
            predict_reading(bad_sample)

    def test_negative_inf_raises_value_error(self):
        """-Infinity in any required feature must raise ValueError."""
        bad_sample = dict(self.valid_8_feature_sample)
        bad_sample["Voltage"] = float("-inf")
        with self.assertRaises(ValueError):
            predict_reading(bad_sample)

    def test_string_non_numeric_raises_value_error(self):
        """Unparseable string values must raise ValueError."""
        bad_sample = dict(self.valid_8_feature_sample)
        bad_sample["Volume Flow RateRMS"] = "INVALID_ALPHA_VALUE"
        with self.assertRaises(ValueError):
            predict_reading(bad_sample)

    def test_non_dict_input_raises_value_error(self):
        """Passing non-dict input (list, string, int) must raise ValueError."""
        with self.assertRaises(ValueError):
            predict_reading("not a dict")
        with self.assertRaises(ValueError):
            predict_reading([1, 2, 3, 4, 5, 6, 7, 8])
        with self.assertRaises(ValueError):
            predict_reading(None)


def run_tests() -> int:
    """Run all assertions and return exit code 0 on success, non-zero on failure."""
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestMLPipeline)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    exit_code = run_tests()
    sys.exit(exit_code)
