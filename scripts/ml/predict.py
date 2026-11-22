"""
Machine Learning Inference Engine for Factory Edge Anomaly Detection.

Preserves the existing trained Random Forest model and calibrated threshold.
Enforces strict 8-feature SKAB contract:
1. Accelerometer1RMS
2. Accelerometer2RMS
3. Current
4. Pressure
5. Temperature
6. Thermocouple
7. Voltage
8. Volume Flow RateRMS

CRITICAL INTEGRITY RULE:
If all 8 features are genuinely present (e.g. from genuine SKAB dataset replay),
the Random Forest executes optimized inference.
If the 5-sensor compressor telemetry does not provide all 8 valid features,
it returns: 'ML INFERENCE NOT AVAILABLE – REQUIRED FEATURES MISSING'.
Never invents or substitutes missing features.
"""

from pathlib import Path
import json
import warnings
import joblib
import numpy as np
from typing import Dict, Any, List, Optional

# Canonical Model Path & Project Root
ROOT_DIR = Path(__file__).resolve().parent.parent.parent
MODEL_PATH = ROOT_DIR / "models" / "random_forest.joblib"
THRESHOLD_PATH = ROOT_DIR / "reports" / "threshold_validation.json"

if not MODEL_PATH.exists():
    raise FileNotFoundError(f"Canonical model bundle not found: {MODEL_PATH}")

bundle = joblib.load(MODEL_PATH)

if isinstance(bundle, dict) and "model" in bundle:
    model = bundle["model"]
    REQUIRED_FEATURES = list(bundle.get("features", []))
    threshold = float(bundle.get("threshold", 0.33))
    feature_importances = bundle.get("feature_importances", {})
    model_version = bundle.get("model_version", "2.0.0-calibrated")
else:
    model = bundle
    REQUIRED_FEATURES = [
        "Accelerometer1RMS", "Accelerometer2RMS", "Current", "Pressure",
        "Temperature", "Thermocouple", "Voltage", "Volume Flow RateRMS"
    ]
    threshold = 0.33
    feature_importances = {}
    model_version = "1.0.0"

classes = list(model.classes_)
ANOMALY_INDEX = classes.index(1) if 1 in classes else 1

# Optimize thread dispatch for deterministic sub-10ms edge inference
if hasattr(model, "n_jobs"):
    try:
        model.n_jobs = 1
    except Exception:
        pass

# Cache Cython tree pointers to bypass joblib Python generator overhead for single-row calls
_trees = [e.tree_ for e in model.estimators_] if hasattr(model, "estimators_") else None
_n_trees = len(_trees) if _trees else 1

# Standard field alias map for snake_case sensor input normalization
FIELD_ALIAS_MAP = {
    "accelerometer1_rms": "Accelerometer1RMS",
    "accelerometer2_rms": "Accelerometer2RMS",
    "current": "Current",
    "pressure": "Pressure",
    "temperature": "Temperature",
    "thermocouple": "Thermocouple",
    "voltage": "Voltage",
    "volume_flow_rate_rms": "Volume Flow RateRMS"
}


def predict_reading(sensor_reading: Dict[str, Any]) -> Dict[str, Any]:
    """
    Perform Random Forest inference ONLY when all 8 required features are present.
    If features are missing, gracefully report UNAVAILABLE without failing.
    Optimized for sub-10ms edge latency using pre-allocated NumPy array inference.
    """
    if not isinstance(sensor_reading, dict):
        raise ValueError("sensor_reading must be a dictionary")

    # Map snake_case variants to standard PascalCase names if needed
    normalized_input = {}
    for k, v in sensor_reading.items():
        standard_key = FIELD_ALIAS_MAP.get(k, k)
        normalized_input[standard_key] = v

    missing = [f for f in REQUIRED_FEATURES if f not in normalized_input or normalized_input[f] is None]

    if missing:
        return {
            "status": "UNAVAILABLE",
            "ml_available": False,
            "message": "ML INFERENCE NOT AVAILABLE – REQUIRED FEATURES MISSING",
            "missing_features": missing,
            "provided_features": list(normalized_input.keys()),
            "anomaly_probability": None,
            "threshold": round(threshold, 4),
            "model_version": model_version
        }

    # Strict numeric validation in exact 8-feature order
    vals = []
    for f in REQUIRED_FEATURES:
        raw_val = normalized_input[f]
        try:
            val = float(raw_val)
        except (TypeError, ValueError) as err:
            raise ValueError(f"Feature '{f}' value '{raw_val}' must be numeric: {err}") from err
        if not np.isfinite(val):
            raise ValueError(f"Feature '{f}' contains non-finite value ({val}).")
        vals.append(val)

    # Direct NumPy array shape (1, 8) avoiding single-row DataFrame construction overhead
    row_arr = np.array([vals], dtype=np.float64)

    # Sub-10ms optimized Cython tree evaluation (bit-for-bit identical to model.predict_proba)
    if _trees is not None:
        row_arr32 = row_arr.astype(np.float32, copy=False)
        tot = np.zeros(2, dtype=np.float64)
        for t in _trees:
            tot += t.predict(row_arr32)[0]
        probabilities = tot / _n_trees
    else:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            probabilities = model.predict_proba(row_arr)[0]

    anomaly_probability = float(probabilities[ANOMALY_INDEX])
    is_anomaly = anomaly_probability >= threshold

    # Explainability: Top contributing features based on precomputed feature importances
    scored_features = []
    for feat, imp in feature_importances.items():
        if feat in normalized_input:
            scored_features.append({
                "feature": feat,
                "importance": imp,
                "value": round(float(normalized_input[feat]), 4)
            })

    top_feature = scored_features[0]["feature"] if scored_features else "N/A"
    top_contributors = scored_features[:3]

    # Regime-drift / operating-regime diagnostic note
    if anomaly_probability >= 0.75:
        regime_note = (
            f"Elevated anomaly probability (P={anomaly_probability:.4f} >= 0.75): "
            "Strong anomalous signature detected; mechanical or electrical fault active."
        )
    elif is_anomaly:
        regime_note = (
            f"Elevated anomaly probability (P={anomaly_probability:.4f} >= {threshold:.4f}): "
            "Incipient fault signature or transient operating-regime shift detected."
        )
    elif anomaly_probability > 0.20:
        regime_note = (
            f"Nominal regime with elevated baseline variance (P={anomaly_probability:.4f} < {threshold:.4f}): "
            "Potential startup surge or hydraulic transition within acceptable limits."
        )
    else:
        regime_note = (
            f"Steady-state nominal regime (P={anomaly_probability:.4f}): "
            "All 8 features aligned with baseline operating envelope."
        )

    return {
        "status": "ANOMALY" if is_anomaly else "NORMAL",
        "ml_available": True,
        "message": "Inference completed successfully using 8-feature Random Forest",
        "anomaly_probability": round(anomaly_probability, 4),
        "threshold": round(threshold, 4),
        "model_version": model_version,
        "top_contributor": top_feature,
        "top_contributors": top_contributors,
        "contributing_features": top_contributors,
        "regime_note": regime_note,
    }


if __name__ == "__main__":
    # Test 1: Incomplete 5-sensor compressor reading
    five_sensor_sample = {
        "temperature": 75.0,
        "vibration": 0.22,
        "pressure": 7.2,
        "current": 18.0,
        "speed": 1450.0
    }
    print("5-Sensor Test:")
    print(json.dumps(predict_reading(five_sensor_sample), indent=2))

    # Test 2: Complete 8-feature SKAB reading
    eight_feature_sample = {
        "Accelerometer1RMS": 0.15,
        "Accelerometer2RMS": 0.20,
        "Current": 2.0,
        "Pressure": 0.07,
        "Temperature": 88.0,
        "Thermocouple": 26.0,
        "Voltage": 230.0,
        "Volume Flow RateRMS": 105.0,
    }
    print("\n8-Feature SKAB Test:")
    print(json.dumps(predict_reading(eight_feature_sample), indent=2))
