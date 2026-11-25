"""
Idempotent Local Event Store & Store-and-Forward Buffer for Factory Edge Diagnostics.

Fulfills Problem Statement 5 Section 11.1 Matrix:
1. Event Deduplication: Rejects duplicate event_ids idempotently once acknowledged.
2. Event-Time Ordering: Preserves strict event timestamp ordering even when events arrive out-of-order.
3. Store-and-Forward Buffer: Buffers events locally during simulated WAN/broker network outages.
4. Restart-Safe State Recovery: Persists pending delivery and acknowledgement state durably across process restarts.
   Reopening EventStore reloads and replays unacknowledged/pending events instead of stranding them.
5. Persistent Audit Log: Appends records to reports/persistent_event_store.csv with durable atomic updates.
"""

from pathlib import Path
import csv
from datetime import datetime
from typing import Dict, Any, List, Optional, Callable, Set
import logging

logger = logging.getLogger("EventStore")

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

NUMERIC_FIELDS = ["p_hp_bar", "t_ic_c", "rpm", "vib_mm_s", "current_a", "anomaly_prob"]


def parse_timestamp_sort_key(ts: Any) -> float:
    """Standardize timestamp for chronological sorting."""
    if isinstance(ts, (int, float)):
        return float(ts)
    if isinstance(ts, str):
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        except Exception:
            try:
                return datetime.strptime(ts, "%Y-%m-%d %H:%M:%S").timestamp()
            except Exception:
                pass
    return datetime.now().timestamp()


class EventStore:
    """Idempotent event buffer with local store-and-forward, persistence, and restart recovery."""

    def __init__(self, persistence_file: Optional[Path] = None):
        self.persistence_file = Path(persistence_file) if persistence_file else DEFAULT_PERSISTENCE_CSV
        self._seen_event_ids: Set[str] = set()
        self._acknowledged_ids: Set[str] = set()
        self._buffer: List[Dict[str, Any]] = []
        self._forwarded_log: List[Dict[str, Any]] = []

        # Load existing store state if CSV exists to ensure session restart persistence
        if self.persistence_file.exists():
            self._load_state_from_disk()

    def _load_state_from_disk(self) -> None:
        """
        Read historical event records from disk.
        - Acknowledged events (ACK) are tracked in _acknowledged_ids and _forwarded_log.
        - Pending/unacknowledged events (BUFFERED/PENDING) are reloaded into _buffer in timestamp order.
        Guards against corrupt rows and raises on critical I/O errors.
        """
        if not self.persistence_file.exists() or self.persistence_file.stat().st_size == 0:
            return

        buffered_events: List[Dict[str, Any]] = []
        forwarded_events: List[Dict[str, Any]] = []
        seen: Set[str] = set()
        acked: Set[str] = set()

        try:
            with open(self.persistence_file, "r", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                for line_num, row in enumerate(reader, start=2):
                    eid = row.get("event_id", "").strip()
                    if not eid:
                        continue

                    ack = row.get("ack_status", "BUFFERED").strip().upper()
                    seen.add(eid)

                    # Reconstruct event payload with appropriate types
                    event_dict: Dict[str, Any] = dict(row)
                    for num_field in NUMERIC_FIELDS:
                        val = event_dict.get(num_field)
                        if val is not None and val != "":
                            try:
                                event_dict[num_field] = float(val)
                            except (ValueError, TypeError):
                                pass

                    event_dict["_sort_key"] = parse_timestamp_sort_key(event_dict.get("timestamp"))

                    if ack == "ACK":
                        acked.add(eid)
                        event_dict["ack_status"] = "ACK"
                        forwarded_events.append(event_dict)
                    else:
                        # Unacknowledged/pending event: reload into buffer for replay
                        event_dict["ack_status"] = "BUFFERED"
                        buffered_events.append(event_dict)

            # Sort buffer to preserve event-time ordering
            buffered_events.sort(key=lambda x: x["_sort_key"])
            forwarded_events.sort(key=lambda x: x["_sort_key"])

            self._seen_event_ids = seen
            self._acknowledged_ids = acked
            self._buffer = buffered_events
            self._forwarded_log = forwarded_events

        except Exception as e:
            logger.error("Failed to load EventStore from %s: %s", self.persistence_file, e)
            raise IOError(f"EventStore disk recovery error on {self.persistence_file}: {e}") from e

    def _ensure_csv_header(self) -> None:
        """Create persistent CSV file with standard headers if it does not exist or is empty."""
        if not self.persistence_file.exists() or self.persistence_file.stat().st_size == 0:
            self.persistence_file.parent.mkdir(parents=True, exist_ok=True)
            try:
                with open(self.persistence_file, "w", newline="", encoding="utf-8") as f:
                    writer = csv.writer(f)
                    writer.writerow(CSV_FIELDNAMES)
            except Exception as e:
                raise IOError(f"Cannot initialize CSV header at {self.persistence_file}: {e}") from e

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
            event.get("ack_status", "BUFFERED")
        ]
        try:
            with open(self.persistence_file, "a", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow(row)
        except Exception as e:
            raise IOError(f"Failed to append event to {self.persistence_file}: {e}") from e

    def _update_persistent_csv_acks(self, acked_ids: Set[str]) -> None:
        """
        Durably update ack_status to ACK on disk for delivered events using an atomic replace.
        Ensures consistency between in-memory state and persistent storage.
        """
        if not self.persistence_file.exists() or not acked_ids:
            return

        temp_path = self.persistence_file.with_name(self.persistence_file.name + ".tmp")
        try:
            with open(self.persistence_file, "r", encoding="utf-8") as f_in, \
                 open(temp_path, "w", newline="", encoding="utf-8") as f_out:
                reader = csv.DictReader(f_in)
                writer = csv.DictWriter(f_out, fieldnames=CSV_FIELDNAMES)
                writer.writeheader()
                for row in reader:
                    eid = row.get("event_id", "").strip()
                    if eid in acked_ids:
                        row["ack_status"] = "ACK"
                    writer.writerow(row)

            # Atomic replace on file system
            temp_path.replace(self.persistence_file)
        except Exception as e:
            if temp_path.exists():
                try:
                    temp_path.unlink()
                except Exception:
                    pass
            logger.error("Failed to update ACK status in persistent CSV: %s", e)
            raise IOError(f"Failed to update ACK status in {self.persistence_file}: {e}") from e

    def insert_event(self, event: Dict[str, Any]) -> bool:
        """
        Insert an event into the local store.
        - Idempotently rejects duplicates by event_id if already buffered or acknowledged.
        - Preserves strict event-time chronological ordering in buffer.
        - Persists to audit file.
        Returns True if accepted as new, False if duplicate.
        """
        event_id = str(event.get("event_id", "")).strip()
        if not event_id:
            raise ValueError("Event must include a non-empty 'event_id'.")

        # Reject duplicate if already acknowledged
        if event_id in self._acknowledged_ids:
            return False

        # Reject duplicate if currently in pending buffer
        if any(b.get("event_id") == event_id for b in self._buffer):
            return False

        self._seen_event_ids.add(event_id)

        # Standardize timestamp for sorting
        ts_sort_key = parse_timestamp_sort_key(event.get("timestamp"))

        event_entry = dict(event)
        event_entry["event_id"] = event_id
        event_entry["_sort_key"] = ts_sort_key
        event_entry.setdefault("ack_status", "BUFFERED")

        # Insert and sort by event timestamp (preserves event-time ordering)
        self._buffer.append(event_entry)
        self._buffer.sort(key=lambda x: x["_sort_key"])

        # Write to persistent audit log on disk
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
        On delivery success, updates in-memory ACK tracking and durably commits ACK status to disk.
        """
        if simulated_outage:
            return {
                "status": "BUFFERED_OUTAGE",
                "message": "WAN/broker outage simulated. Events retained in local buffer.",
                "buffered_count": len(self._buffer),
                "forwarded_count": 0
            }

        if sink_fn is None:
            sink_fn = lambda evt: True

        successfully_forwarded: List[Dict[str, Any]] = []
        unacknowledged: List[Dict[str, Any]] = []
        delivered_ids: Set[str] = set()

        for evt in self._buffer:
            try:
                delivered = sink_fn(evt)
                if delivered:
                    evt["ack_status"] = "ACK"
                    successfully_forwarded.append(evt)
                    self._forwarded_log.append(evt)
                    eid = evt.get("event_id")
                    if eid:
                        self._acknowledged_ids.add(eid)
                        delivered_ids.add(eid)
                else:
                    unacknowledged.append(evt)
            except Exception as err:
                logger.warning("Sink delivery exception for %s: %s", evt.get("event_id"), err)
                unacknowledged.append(evt)

        # Update in-memory buffer
        self._buffer = unacknowledged

        # Durably update ACK status on disk
        if delivered_ids:
            self._update_persistent_csv_acks(delivered_ids)

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

    def is_acknowledged(self, event_id: str) -> bool:
        """Return True if the event has been successfully forwarded and acknowledged."""
        return str(event_id).strip() in self._acknowledged_ids

    def clear(self) -> None:
        """Clear in-memory state (useful for test isolation)."""
        self._seen_event_ids.clear()
        self._acknowledged_ids.clear()
        self._buffer.clear()
        self._forwarded_log.clear()
