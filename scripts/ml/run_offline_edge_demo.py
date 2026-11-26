"""
Offline Store-and-Forward & WAN Outage Demonstration.
Replays genuine held-out SKAB dataset records through EventStore and predict_reading().

Demonstrates 3 operational phases:
Phase A: Normal local operation with real-time forwarding to remote broker.
Phase B: Simulated WAN disconnect where events spool locally to disk with idempotent deduplication.
Phase C: WAN reconnect where spooled records drain in strict chronological order with zero loss or duplicates.

Exports audit verification to reports/offline_outage_resilience_report.json.
Exits with code 0 on full success.
"""

import sys
import json
from pathlib import Path
from datetime import datetime, timedelta
from typing import Dict, Any, List
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from scripts.ml.predict import predict_reading, REQUIRED_FEATURES
from scripts.ml.event_store import EventStore

REPORTS_DIR = PROJECT_ROOT / "reports"
DATA_FILE = PROJECT_ROOT / "data" / "raw" / "skab" / "other" / "11.csv"
if not DATA_FILE.exists():
    DATA_FILE = PROJECT_ROOT / "data" / "raw" / "SKAB" / "data" / "other" / "11.csv"


def run_offline_edge_demo() -> Dict[str, Any]:
    """Execute the 3-phase offline store-and-forward edge demonstration."""
    if not DATA_FILE.exists():
        raise FileNotFoundError(f"SKAB held-out test data missing at {DATA_FILE}")

    df = pd.read_csv(DATA_FILE, sep=";")
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    demo_store_csv = REPORTS_DIR / "offline_demo_store.csv"
    for p in [demo_store_csv, demo_store_csv.with_suffix(".sqlite"),
              demo_store_csv.with_suffix(".sqlite-wal"), demo_store_csv.with_suffix(".sqlite-shm")]:
        if p.exists():
            try:
                p.unlink()
            except Exception:
                pass

    store = EventStore(persistence_file=demo_store_csv)
    store.clear()

    # Mock remote broker sink
    remote_broker_inbox: List[Dict[str, Any]] = []

    def remote_broker_sink(event: Dict[str, Any]) -> bool:
        remote_broker_inbox.append(dict(event))
        return True

    # Base reference timestamp for synthetic replay
    base_time = datetime(2026, 11, 19, 10, 0, 0)

    # -------------------------------------------------------------------------
    # PHASE A: Normal Local Operation (Samples 0..19)
    # -------------------------------------------------------------------------
    phase_a_events = []
    for i in range(20):
        row = df.iloc[i]
        sample = {f: float(row[f]) for f in REQUIRED_FEATURES}
        pred = predict_reading(sample)

        ts = (base_time + timedelta(seconds=i)).isoformat()
        evt = {
            "timestamp": ts,
            "event_id": f"EVT-PHASE-A-{i:04d}",
            "scenario": "NORMAL_STREAM",
            "model_version": pred["model_version"],
            "anomaly_prob": pred["anomaly_probability"],
            "status": pred["status"],
            "p_hp_bar": float(row["Pressure"]),
            "t_ic_c": float(row["Temperature"]),
            "rpm": 1490.0,
            "vib_mm_s": float(row["Accelerometer1RMS"]),
            "current_a": float(row["Current"])
        }
        accepted = store.insert_event(evt)
        assert accepted, f"Phase A event {evt['event_id']} should be accepted"
        phase_a_events.append(evt)

        # Flush in real-time under normal connectivity
        flush_res = store.flush_forward(sink_fn=remote_broker_sink, simulated_outage=False)
        assert flush_res["status"] == "RECONCILED"

    assert len(remote_broker_inbox) == 20, f"Broker should have 20 events, got {len(remote_broker_inbox)}"
    assert len(store.get_buffered_events()) == 0, "Buffer should be empty during normal operation"

    # -------------------------------------------------------------------------
    # PHASE B: Simulated WAN Disconnect / Network Partition (Samples 20..49)
    # -------------------------------------------------------------------------
    phase_b_unique_count = 30
    duplicates_attempted = 5
    duplicates_rejected = 0

    # Ingest 30 events, deliberately including out-of-order timestamps and duplicates
    shuffled_indices = list(range(20, 50))
    # Create slight out-of-order sequence (e.g., swap pairs to simulate network jitter)
    shuffled_indices[2], shuffled_indices[5] = shuffled_indices[5], shuffled_indices[2]
    shuffled_indices[10], shuffled_indices[12] = shuffled_indices[12], shuffled_indices[10]

    for idx, sample_idx in enumerate(shuffled_indices):
        row = df.iloc[sample_idx]
        sample = {f: float(row[f]) for f in REQUIRED_FEATURES}
        pred = predict_reading(sample)

        ts = (base_time + timedelta(seconds=sample_idx)).isoformat()
        evt = {
            "timestamp": ts,
            "event_id": f"EVT-PHASE-B-{sample_idx:04d}",
            "scenario": "OUTAGE_STREAM",
            "model_version": pred["model_version"],
            "anomaly_prob": pred["anomaly_probability"],
            "status": pred["status"],
            "p_hp_bar": float(row["Pressure"]),
            "t_ic_c": float(row["Temperature"]),
            "rpm": 1485.0,
            "vib_mm_s": float(row["Accelerometer1RMS"]),
            "current_a": float(row["Current"])
        }

        # Insert event
        acc = store.insert_event(evt)
        assert acc, f"Unique Phase B event {evt['event_id']} must be accepted"

        # Inject deliberate duplicate every 6th iteration
        if idx % 6 == 0 and duplicates_rejected < duplicates_attempted:
            dup_acc = store.insert_event(evt)
            assert not dup_acc, f"Duplicate {evt['event_id']} must be rejected idempotently"
            duplicates_rejected += 1

        # Attempt transmission during outage: must buffer safely without data loss
        outage_flush = store.flush_forward(sink_fn=remote_broker_sink, simulated_outage=True)
        assert outage_flush["status"] == "BUFFERED_OUTAGE"

    # Assertions for Phase B outage state
    assert len(remote_broker_inbox) == 20, "Broker inbox count must not change during WAN outage"
    assert len(store.get_buffered_events()) == phase_b_unique_count, f"Store must buffer exactly {phase_b_unique_count} events"
    assert duplicates_rejected == duplicates_attempted, "All duplicate event_ids must be rejected"

    # Verify event-time chronological sorting in local spool
    spooled_events = store.get_buffered_events()
    spooled_timestamps = [e["timestamp"] for e in spooled_events]
    assert spooled_timestamps == sorted(spooled_timestamps), "Buffered events must be strictly sorted by event-time timestamp"

    # Verify persistent disk store exists and has all rows
    assert demo_store_csv.exists(), "Local store-and-forward CSV must persist on disk"

    # -------------------------------------------------------------------------
    # PHASE C: WAN Reconnect & Seamless Reconciliation
    # -------------------------------------------------------------------------
    # Network restored: trigger flush with simulated_outage=False
    reconnect_res = store.flush_forward(sink_fn=remote_broker_sink, simulated_outage=False)
    assert reconnect_res["status"] == "RECONCILED"
    assert reconnect_res["forwarded_count"] == phase_b_unique_count
    assert len(store.get_buffered_events()) == 0, "Local buffer must be 100% drained on reconnect"

    # Verify total events received by remote broker
    total_received = len(remote_broker_inbox)
    assert total_received == 20 + phase_b_unique_count, f"Broker must receive exactly 50 events, got {total_received}"

    # Verify 0 duplicates across the entire broker inbox
    received_ids = [e["event_id"] for e in remote_broker_inbox]
    assert len(received_ids) == len(set(received_ids)), "Broker inbox must contain zero duplicate event_ids"

    # Verify global chronological delivery order
    all_timestamps = [e["timestamp"] for e in remote_broker_inbox]
    assert all_timestamps == sorted(all_timestamps), "Entire broker stream must be in chronological event-time order"

    # Clean up demo store CSV
    if demo_store_csv.exists():
        demo_store_csv.unlink()

    # -------------------------------------------------------------------------
    # Build & Export Report Payload
    # -------------------------------------------------------------------------
    report_payload = {
        "report_name": "EdgeSentinel Offline Store-and-Forward WAN Outage Proof",
        "timestamp": datetime.now().isoformat(),
        "status": "PASS",
        "exit_code": 0,
        "phases": {
            "phase_a_normal_operation": {
                "description": "Continuous local inference with real-time WAN forwarding",
                "samples_processed": 20,
                "delivered_to_broker": 20,
                "buffered_remaining": 0,
                "status": "ONLINE_HEALTHY"
            },
            "phase_b_simulated_wan_outage": {
                "description": "WAN partition: local edge inference buffers events to disk with idempotent deduplication",
                "samples_processed": phase_b_unique_count,
                "duplicates_injected": duplicates_attempted,
                "duplicates_rejected_idempotently": duplicates_rejected,
                "events_spooled_locally": len(spooled_events),
                "broker_inbox_held_constant": 20,
                "event_time_ordering_preserved": True,
                "status": "OFFLINE_BUFFERING_ACTIVE"
            },
            "phase_c_wan_reconnection": {
                "description": "Network restored: queued events drain in strict chronological order with zero loss",
                "spooled_events_drained": reconnect_res["forwarded_count"],
                "total_events_at_broker": total_received,
                "final_buffer_count": 0,
                "dropped_alerts": 0,
                "duplicate_events_at_broker": 0,
                "chronological_order_verified": True,
                "status": "RECONCILED_SUCCESS"
            }
        },
        "conclusion": "Store-and-forward edge buffer verified 100% resilient across WAN outage and reconnection cycles."
    }

    out_file = REPORTS_DIR / "offline_outage_resilience_report.json"
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(report_payload, f, indent=2)

    return report_payload


if __name__ == "__main__":
    print("=" * 70)
    print(" Running Offline Edge Store-and-Forward WAN Outage Demonstration...")
    print("=" * 70)
    rep = run_offline_edge_demo()
    print(" [Phase A] Normal Operation:    20 events processed & delivered.")
    print(" [Phase B] Simulated Outage:     30 events spooled locally (5 duplicates rejected).")
    print(" [Phase C] WAN Reconnected:      30 spooled events drained in chronological order.")
    print(" [Result]  Total Broker Events:  50 unique events | 0 dropped | 0 duplicates.")
    print(f" Report exported to: {REPORTS_DIR / 'offline_outage_resilience_report.json'}")
    print(" Status: PASS (Exit Code 0)")
    print("=" * 70)
    sys.exit(0)
