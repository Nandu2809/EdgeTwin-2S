"""
NASA C-MAPSS Turbofan Engine Remaining Useful Life (RUL) & Prognostics Engine.

Operates as a dedicated predictive maintenance and prognostic module alongside
the continuous SKAB / reciprocating compressor diagnostic twin.

Data:
- NASA C-MAPSS Turbofan Engine Degradation Simulation (FD001: Sea-level HPC degradation).
- 100 training trajectories, 100 test trajectories with ground-truth remaining life cycles.

Methodology:
- Piecewise-linear RUL target modeling (max clipped RUL = 125 cycles).
- 14 informative degrading sensors (LPC/HPC temperatures, pressures, bypass ratio, bleed enthalpy).
- Deterministic Random Forest Regressor (random_state=42).
- Continuous Health Index (HI) computation: HI = clip(RUL_pred / 125.0, 0.0, 1.0).
- Standard NASA exponential scoring and Root Mean Squared Error (RMSE) evaluation.

Scope & Boundary Disclaimers:
- NASA C-MAPSS turbofan engine degradation prognostic modeling is a separate turbofan fleet
  prognostic module operating alongside the SKAB/compressor monitoring twin.
"""

from pathlib import Path
import json
import joblib
import numpy as np
import pandas as pd
import argparse
from typing import Dict, Any, List, Optional, Tuple
from sklearn.ensemble import RandomForestRegressor
from sklearn.metrics import mean_squared_error, mean_absolute_error, r2_score

PROJECT_ROOT = Path(__file__).resolve().parents[2]
CMAPSS_RAW_DIR = PROJECT_ROOT / "data" / "raw" / "cmapss"
RUL_MODEL_PATH = PROJECT_ROOT / "models" / "cmapss_rul_model.joblib"
RUL_REPORT_PATH = PROJECT_ROOT / "reports" / "cmapss_rul_metrics.json"

_MODEL_CACHE: Dict[str, Tuple[float, Dict[str, Any]]] = {}

CMAPSS_COLUMNS = ["unit", "time", "setting1", "setting2", "setting3"] + [f"s{i}" for i in range(1, 22)]

# 14 informative sensors with non-flat variance under single sea-level operating condition (FD001)
INFORMATIVE_SENSORS = [
    "s2", "s3", "s4", "s7", "s8", "s9", "s11", "s12", "s13", "s14", "s15", "s17", "s20", "s21"
]

SENSOR_DESCRIPTIONS = {
    "s2": "Total temperature at LPC outlet (R)",
    "s3": "Total temperature at HPC outlet (R)",
    "s4": "Total temperature at LPT outlet (R)",
    "s7": "Total pressure at HPC outlet (psia)",
    "s8": "Physical fan speed (rpm)",
    "s9": "Physical core speed (rpm)",
    "s11": "Static pressure at HPC outlet (psia)",
    "s12": "Ratio of fuel flow to Ps30 (pps/psia)",
    "s13": "Corrected fan speed (rpm)",
    "s14": "Corrected core speed (rpm)",
    "s15": "Bypass Ratio",
    "s17": "Bleed Enthalpy",
    "s20": "HPT coolant bleed (lbm/s)",
    "s21": "LPT coolant bleed (lbm/s)"
}

RUL_CLIP_THRESHOLD = 125.0


def compute_nasa_score(y_true: np.ndarray, y_pred: np.ndarray) -> float:
    """Compute asymmetric NASA C-MAPSS evaluation score."""
    diff = y_pred - y_true
    score = 0.0
    for d in diff:
        if d < 0:
            score += np.exp(-d / 13.0) - 1.0
        else:
            score += np.exp(d / 10.0) - 1.0
    return float(score)


def train_cmapss_rul_model(
    dataset_name: str = "FD001",
    n_estimators: int = 50,
    max_depth: int = 12,
    random_state: int = 42,
    output_dir: Optional[Path] = None
) -> Dict[str, Any]:
    """Train and evaluate C-MAPSS RUL regression model."""
    train_path = CMAPSS_RAW_DIR / f"train_{dataset_name}.txt"
    test_path = CMAPSS_RAW_DIR / f"test_{dataset_name}.txt"
    rul_path = CMAPSS_RAW_DIR / f"RUL_{dataset_name}.txt"

    if not train_path.exists():
        raise FileNotFoundError(f"C-MAPSS training file missing: {train_path}")
    if not test_path.exists():
        raise FileNotFoundError(f"C-MAPSS test file missing: {test_path}")
    if not rul_path.exists():
        raise FileNotFoundError(f"C-MAPSS ground-truth RUL file missing: {rul_path}")

    # Load data
    df_train = pd.read_csv(train_path, sep=r"\s+", header=None, names=CMAPSS_COLUMNS)
    df_test = pd.read_csv(test_path, sep=r"\s+", header=None, names=CMAPSS_COLUMNS)
    rul_true = pd.read_csv(rul_path, sep=r"\s+", header=None)[0].to_numpy()

    # Calculate remaining useful life per training unit
    max_cycles = df_train.groupby("unit")["time"].max().reset_index().rename(columns={"time": "max_cycle"})
    df_train = df_train.merge(max_cycles, on="unit")
    df_train["RUL"] = df_train["max_cycle"] - df_train["time"]
    df_train["RUL_target"] = df_train["RUL"].clip(upper=RUL_CLIP_THRESHOLD)

    X_train = df_train[INFORMATIVE_SENSORS]
    y_train = df_train["RUL_target"]

    reg = RandomForestRegressor(
        n_estimators=n_estimators,
        max_depth=max_depth,
        random_state=random_state,
        n_jobs=1
    )
    reg.fit(X_train, y_train)

    # Evaluate on test set using the final observation of each test unit
    last_test_snapshots = df_test.groupby("unit").last().reset_index()
    X_test = last_test_snapshots[INFORMATIVE_SENSORS]
    y_pred = reg.predict(X_test)

    rmse = float(np.sqrt(mean_squared_error(rul_true, y_pred)))
    mae = float(mean_absolute_error(rul_true, y_pred))
    r2 = float(r2_score(rul_true, y_pred))
    nasa_score = compute_nasa_score(rul_true, y_pred)

    feature_importances = {
        s: round(float(imp), 4)
        for s, imp in sorted(zip(INFORMATIVE_SENSORS, reg.feature_importances_), key=lambda x: x[1], reverse=True)
    }

    # Baseline sensor statistics for attribution
    baseline_stats = {
        s: {
            "mean": float(df_train[s].mean()),
            "std": float(df_train[s].std() or 1.0),
            "description": SENSOR_DESCRIPTIONS.get(s, "")
        }
        for s in INFORMATIVE_SENSORS
    }

    metrics = {
        "dataset": dataset_name,
        "n_train_samples": len(df_train),
        "n_test_engines": len(rul_true),
        "rmse_cycles": round(rmse, 2),
        "mae_cycles": round(mae, 2),
        "r2_score": round(r2, 4),
        "nasa_score": round(nasa_score, 2),
        "rul_clip_threshold": RUL_CLIP_THRESHOLD,
        "feature_importances": feature_importances,
        "prognostic_scope_disclaimer": (
            "NASA C-MAPSS turbofan engine degradation prognostic modeling is a separate turbofan fleet "
            "prognostic module operating alongside the SKAB/compressor monitoring twin."
        )
    }

    # Determine target paths
    if output_dir is not None:
        out_dir_path = Path(output_dir)
        target_model_path = out_dir_path / "cmapss_rul_model.joblib"
        target_report_path = out_dir_path / "cmapss_rul_metrics.json"
    else:
        target_model_path = RUL_MODEL_PATH
        target_report_path = RUL_REPORT_PATH

    # Save model bundle
    bundle = {
        "model": reg,
        "features": INFORMATIVE_SENSORS,
        "rul_clip_threshold": RUL_CLIP_THRESHOLD,
        "baseline_stats": baseline_stats,
        "metrics": metrics
    }
    target_model_path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(bundle, target_model_path)

    # Save metrics report
    target_report_path.parent.mkdir(parents=True, exist_ok=True)
    with open(target_report_path, "w", encoding="utf-8") as f:
        json.dump(metrics, f, indent=2)

    return metrics


def get_cached_rul_bundle(model_path: Path = RUL_MODEL_PATH) -> Dict[str, Any]:
    """Retrieve RUL model bundle from memory cache, reloading if file mtime changed."""
    p = Path(model_path).resolve()
    p_str = str(p)
    if not p.exists():
        raise FileNotFoundError(f"RUL model bundle not found at {p}")
    mtime = p.stat().st_mtime
    if p_str in _MODEL_CACHE:
        cached_mtime, cached_bundle = _MODEL_CACHE[p_str]
        if cached_mtime == mtime:
            return cached_bundle
    bundle = joblib.load(p)
    _MODEL_CACHE[p_str] = (mtime, bundle)
    return bundle


def estimate_engine_rul(sensor_readings: Dict[str, Any], model_path: Optional[Path] = None) -> Dict[str, Any]:
    """
    Estimate Remaining Useful Life (RUL) and Health Index (HI) from turbofan sensor readings.
    Provides sensor attribution detailing which parameters indicate degradation.
    """
    target_path = Path(model_path) if model_path is not None else RUL_MODEL_PATH
    if not target_path.exists():
        # Train on demand if bundle not yet written
        train_cmapss_rul_model(output_dir=target_path.parent if model_path is not None else None)

    bundle = get_cached_rul_bundle(target_path)
    reg = bundle["model"]
    features = bundle["features"]
    baseline_stats = bundle["baseline_stats"]

    if not isinstance(sensor_readings, dict):
        return {
            "status": "UNAVAILABLE",
            "message": "Input sensor_readings must be a dictionary",
            "predicted_rul_cycles": None,
            "health_index": None
        }

    missing = [f for f in features if f not in sensor_readings]
    if missing:
        return {
            "status": "UNAVAILABLE",
            "message": f"Missing C-MAPSS sensor features: {missing}",
            "predicted_rul_cycles": None,
            "health_index": None
        }

    invalid_reasons = []
    numeric_values = []
    for f in features:
        val = sensor_readings[f]
        if val is None:
            invalid_reasons.append(f"{f}=None")
            continue
        try:
            val_float = float(val)
            if not np.isfinite(val_float):
                invalid_reasons.append(f"{f}={val}")
            else:
                numeric_values.append(val_float)
        except (ValueError, TypeError):
            invalid_reasons.append(f"{f}={val}")

    if invalid_reasons:
        return {
            "status": "UNAVAILABLE",
            "message": f"Non-finite, null, or invalid sensor values: {invalid_reasons}",
            "predicted_rul_cycles": None,
            "health_index": None
        }

    x = pd.DataFrame([numeric_values], columns=features)
    pred_rul = float(reg.predict(x)[0])
    clipped_max = float(bundle.get("rul_clip_threshold", 125.0))
    health_index = float(np.clip(pred_rul / clipped_max, 0.0, 1.0))

    if pred_rul < 25.0:
        prognostic_status = "CRITICAL_MAINTENANCE_REQUIRED"
    elif pred_rul < 60.0:
        prognostic_status = "MAINTENANCE_DUE"
    else:
        prognostic_status = "HEALTHY_NOMINAL"

    # Per-sensor degradation attribution
    attributions = []
    for f in features:
        val = float(sensor_readings[f])
        mean = baseline_stats[f]["mean"]
        std = baseline_stats[f]["std"]
        sigma_dev = (val - mean) / std
        attributions.append({
            "sensor": f,
            "description": baseline_stats[f]["description"],
            "value": round(val, 4),
            "deviation_sigma": round(sigma_dev, 2),
            "direction": "HIGH" if sigma_dev > 0 else "LOW"
        })

    attributions.sort(key=lambda item: abs(item["deviation_sigma"]), reverse=True)

    return {
        "status": "SUCCESS",
        "predicted_rul_cycles": round(pred_rul, 1),
        "health_index": round(health_index, 4),
        "prognostic_status": prognostic_status,
        "top_degrading_sensors": attributions[:3],
        "prognostic_scope_disclaimer": bundle["metrics"]["prognostic_scope_disclaimer"]
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Train and evaluate C-MAPSS RUL model.")
    parser.add_argument("--output-dir", type=str, default=None, help="Directory to save model bundle and metrics")
    parser.add_argument("--dataset", type=str, default="FD001", help="Dataset name (e.g. FD001)")
    args = parser.parse_args()

    out_dir = Path(args.output_dir) if args.output_dir else None
    res = train_cmapss_rul_model(dataset_name=args.dataset, output_dir=out_dir)
    print("C-MAPSS Model Trained:")
    print(json.dumps(res, indent=2))
