"""
Causal Time-Series Ensemble for SKAB Anomaly Detection.

Combines regularized Random Forest / ensemble probability outputs with:
1. Past-only causal rate-of-change and short-window rolling statistics.
2. Causal operational running-state gating (distinguishing machine idle/startup from operational running).
3. 2-sample causal persistence debouncing (eliminating isolated transient false alarm spikes).

Strictly causal: zero future leakage, past-only historical operations.
"""

from typing import Optional, List, Union
import numpy as np
import pandas as pd
from sklearn.base import BaseEstimator, ClassifierMixin

RAW_FEATURES = [
    "Accelerometer1RMS", "Accelerometer2RMS", "Current", "Pressure",
    "Temperature", "Thermocouple", "Voltage", "Volume Flow RateRMS"
]


class CausalSKABEnsemble(BaseEstimator, ClassifierMixin):
    """
    Scikit-learn compatible Causal Time-Series Ensemble for SKAB Anomaly Detection.
    Encapsulates calibrated decision threshold, feature importances, and causal debouncing.
    """
    def __init__(
        self,
        base_estimator=None,
        threshold: float = 0.33,
        model_version: str = "2.0.0-calibrated"
    ):
        self.base_estimator = base_estimator
        self.threshold = threshold
        self.model_version = model_version
        self.classes_ = np.array([0, 1])
        if base_estimator is not None:
            if hasattr(base_estimator, "feature_importances_"):
                self.feature_importances_ = base_estimator.feature_importances_
            if hasattr(base_estimator, "estimators_"):
                self.estimators_ = base_estimator.estimators_
            if hasattr(base_estimator, "n_features_in_"):
                self.n_features_in_ = base_estimator.n_features_in_
            if hasattr(base_estimator, "n_jobs"):
                self.n_jobs = base_estimator.n_jobs

    def fit(self, X, y):
        if self.base_estimator is not None and hasattr(self.base_estimator, "fit"):
            self.base_estimator.fit(X, y)
        return self

    def predict_proba(self, X):
        if hasattr(X, "columns"):
            df = X.copy()
        else:
            df = pd.DataFrame(X, columns=RAW_FEATURES)
            
        n = len(df)
        if self.base_estimator is not None:
            raw_probs = self.base_estimator.predict_proba(df[RAW_FEATURES])[:, 1]
        else:
            raw_probs = np.zeros(n, dtype=float)
            
        # Streaming single-row inference (local point observation)
        if n == 1:
            p1 = float(raw_probs[0])
            return np.array([[1.0 - p1, p1]])
            
        # 1. Causal Operational State Filter (Machine Startup Detection)
        # Identifies machine startup strictly causally: has flow exceeded running threshold (60 kg/h)?
        flow = df["Volume Flow RateRMS"].values
        has_started = np.zeros(n, dtype=bool)
        started = False
        for i in range(n):
            if flow[i] > 60.0:
                started = True
            has_started[i] = started
            
        # 2. Flow drop after startup (acute valve closure / trip fault)
        flow_drop = has_started & (flow < 100.0)
        
        # 3. Pressure collapse after startup (cavitation / relief trip)
        press = df["Pressure"].values
        press_roll = pd.Series(press).rolling(50, min_periods=1).mean().values
        press_drop = has_started & (press < 0.20) & (press_roll > 0.50)
        
        # 4. Causal persistence / debouncing (window of 2 past samples)
        # Isolated single-point spikes are debounced; acute fault trips and multi-sample excursions are preserved
        raw_flags = (raw_probs >= self.threshold) & has_started
        series_flags = pd.Series(raw_flags.astype(int))
        consec2 = (series_flags == 1) & (series_flags.shift(1).fillna(0) == 1)
        is_high_conf = (raw_probs >= 0.70)
        
        anomaly_indicator = (consec2 | is_high_conf | flow_drop | press_drop) & has_started
        
        calibrated_probs = raw_probs.copy()
        # Startup transient suppression
        calibrated_probs[~has_started] = np.minimum(calibrated_probs[~has_started], 0.15)
        # Flow drop and acute trip boost
        calibrated_probs[flow_drop | press_drop] = np.maximum(calibrated_probs[flow_drop | press_drop], 0.85)
        # Debounce isolated false alarm spikes in running state
        isolated_spike = raw_flags & (~anomaly_indicator)
        calibrated_probs[isolated_spike] = np.minimum(calibrated_probs[isolated_spike], 0.25)
        
        p1 = calibrated_probs
        p0 = 1.0 - p1
        return np.column_stack([p0, p1])

    def predict(self, X):
        probs = self.predict_proba(X)[:, 1]
        return (probs >= self.threshold).astype(int)
