"""
Idempotent Local Event Store & Store-and-Forward Buffer for Factory Edge Diagnostics.

Fulfills Problem Statement 5 Section 11.1 Matrix:
1. Event Deduplication: Rejects duplicate event_ids idempotently.
2. Event-Time Ordering: Preserves strict event timestamp ordering even when events arrive out-of-order.
3. Store-and-Forward Buffer: Buffers events locally during simulated WAN/broker network outages.
4. Reconciliation: Automatically flushes and reconciles buffered events in timestamp order upon network recovery.
5. Persistent Audit Log: Appends records to reports/persistent_event_store.csv.
"""

from pathlib import Path
import csv
from datetime import datetime
from typing import Dict, Any, List, Optional, Callable, Set

PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PERSISTENCE_CSV = PROJECT_ROOT / "reports" / "persistent_event_store.csv"

CSV_FIELDNAMES = [
    "timestamp",
    "event_id",
    "scenario",
    "model_version",
    "p_hp_bar",
    "t_ic_c",
    "rpm",
    "vib_mm_s",
    "current_a",
    "anomaly_prob",
    "status",
    "ack_status"
]


class EventStore:
    """Idempotent event buffer with local store-and-forward and persistence capabilities."""

    def __init__(self, persistence_file: Optional[Path] = None):
        self.persistence_file = Path(persistence_file) if persistence_file else DEFAULT_PERSISTENCE_CSV
        self._seen_event_ids: Set[str] = set()
        self._buffer: List[Dict[str, Any]] = []
        self._forwarded_log: List[Dict[str, Any]] = []

        # Load existing event IDs if CSV exists to ensure session restart persistence
        if self.persistence_file.exists():
            self._load_seen_ids_from_disk()

    def _load_seen_ids_from_disk(self) -> None:
        """Read historical event_ids from disk to prevent duplicate ingestion after restart."""
        try:
            with open(self.persistence_file, "r", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    eid = row.get("event_id")
                    if eid:
                        self._seen_event_ids.add(eid)
        except Exception:
            pass

    def _ensure_csv_header(self) -> None:
        """Create persistent CSV file with standard headers if it does not exist."""
        if not self.persistence_file.exists():
            self.persistence_file.parent.mkdir(parents=True, exist_ok=True)
            with open(self.persistence_file, "w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow(CSV_FIELDNAMES)

    def append_to_persistent_csv(self, event: Dict[str, Any]) -> None:
        """Append an audit record to persistent CSV store."""
        self._ensure_csv_header()
        row = [
            event.get("timestamp", datetime.now().isoformat()),
            event.get("event_id", ""),
            event.get("scenario", "SIMULATED"),
            event.get("model_version", "2.0.0-calibrated"),
            event.get("p_hp_bar", 0.0),
            event.get("t_ic_c", 0.0),
            event.get("rpm", 0.0),
            event.get("vib_mm_s", 0.0),
            event.get("current_a", 0.0),
            event.get("anomaly_prob", 0.0),
            event.get("status", "NORMAL"),
            event.get("ack_status", "PENDING")
        ]
        with open(self.persistence_file, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(row)

    def insert_event(self, event: Dict[str, Any]) -> bool:
        """
        Insert an event into the local store.
        - Idempotently rejects duplicates by event_id.
        - Sorts buffer by timestamp to preserve event-time ordering.
        - Persists to audit file.
        Returns True if accepted as new, False if duplicate.
        """
        event_id = str(event.get("event_id", "")).strip()
        if not event_id:
            raise ValueError("Event must include a non-empty 'event_id'.")

        if event_id in self._seen_event_ids:
            return False  # Duplicate detected; idempotently ignore

        self._seen_event_ids.add(event_id)

        # Standardize timestamp for sorting
        ts = event.get("timestamp")
        if isinstance(ts, (int, float)):
            ts_sort_key = float(ts)
        elif isinstance(ts, str):
            try:
                ts_sort_key = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            except Exception:
                ts_sort_key = datetime.now().timestamp()
        else:
            ts_sort_key = datetime.now().timestamp()

        event_entry = dict(event)
        event_entry["_sort_key"] = ts_sort_key
        event_entry.setdefault("ack_status", "BUFFERED")

        # Insert and sort by event timestamp (preserves event-time ordering)
        self._buffer.append(event_entry)
        self._buffer.sort(key=lambda x: x["_sort_key"])

        # Write to disk
        self.append_to_persistent_csv(event_entry)
        return True

    def flush_forward(
        self,
        sink_fn: Optional[Callable[[Dict[str, Any]], bool]] = None,
        simulated_outage: bool = False
    ) -> Dict[str, Any]:
        """
        Store-and-forward flush logic.
        If simulated_outage is True, transmission fails and events remain safely buffered.
        If simulated_outage is False, transmits queued events in timestamp order to sink_fn.
        """
        if simulated_outage:
            return {
                "status": "BUFFERED_OUTAGE",
                "message": "WAN/broker outage simulated. Events retained in local buffer.",
                "buffered_count": len(self._buffer),
                "forwarded_count": 0
            }

        if sink_fn is None:
            # Default sink: mock broker acknowledge
            sink_fn = lambda evt: True

        successfully_forwarded = []
        unacknowledged = []

        for evt in self._buffer:
            try:
                delivered = sink_fn(evt)
                if delivered:
                    evt["ack_status"] = "ACK"
                    successfully_forwarded.append(evt)
                    self._forwarded_log.append(evt)
                else:
                    unacknowledged.append(evt)
            except Exception:
                unacknowledged.append(evt)

        self._buffer = unacknowledged
        return {
            "status": "RECONCILED",
            "message": f"Flushed and reconciled {len(successfully_forwarded)} events.",
            "forwarded_count": len(successfully_forwarded),
            "remaining_buffer": len(self._buffer)
        }

    def get_buffered_events(self) -> List[Dict[str, Any]]:
        """Return shallow copy of events currently awaiting forward."""
        return list(self._buffer)

    def get_forwarded_events(self) -> List[Dict[str, Any]]:
        """Return shallow copy of successfully forwarded events."""
        return list(self._forwarded_log)

    def clear(self) -> None:
        """Clear in-memory state (useful for test isolation)."""
        self._seen_event_ids.clear()
        self._buffer.clear()
        self._forwarded_log.clear()
