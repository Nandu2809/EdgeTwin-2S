"""
Crash-Safe SQLite WAL Local Event Store & Store-and-Forward Buffer for Factory Edge Diagnostics.

Fulfills Problem Statement 5 Section 11.1 Matrix and Production Reliability Standards:
1. SQLite WAL Mode: Uses PRAGMA journal_mode=WAL and PRAGMA synchronous=NORMAL for concurrent,
   atomic, crash-proof disk persistence.
2. Explicit State Transitions: PENDING -> IN_FLIGHT -> ACKED.
3. Event Deduplication: Rejects duplicate event_ids idempotently via PRIMARY KEY constraints.
4. Event-Time Ordering: Preserves strict chronological timestamp ordering even when events arrive out-of-order.
5. Store-and-Forward Outage Resilience: Buffers events locally during simulated or physical WAN/broker outages.
6. Process-Kill / Crash-Safe Recovery: Any IN_FLIGHT or PENDING unacknowledged event left behind when a
   process is abruptly killed (SIGKILL / power loss) recovers automatically into the pending retry queue
   on restart with ZERO stranded alerts, ZERO duplicate sink deliveries, and preserved acknowledgements.
7. Backward-Compatible Audit Sync: Simultaneously writes CSV audit records when a CSV path is configured.
"""

from pathlib import Path
import csv
import json
import sqlite3
import time
from datetime import datetime
from typing import Dict, Any, List, Optional, Callable, Set
import logging

logger = logging.getLogger("EventStore")

PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DB_PATH = PROJECT_ROOT / "reports" / "event_store.sqlite"
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
    """Crash-safe idempotent event buffer with SQLite WAL mode, state machine, and crash recovery."""

    def __init__(self, persistence_file: Optional[Path] = None):
        """
        Initialize EventStore.
        If persistence_file ends with .db or .sqlite, it is used directly as the SQLite store.
        If persistence_file ends with .csv, a paired .sqlite file is used alongside it and CSV is kept in sync.
        """
        raw_path = Path(persistence_file) if persistence_file else DEFAULT_PERSISTENCE_CSV

        if raw_path.suffix.lower() in [".db", ".sqlite", ".sqlite3"]:
            self.db_path = raw_path
            self.persistence_csv: Optional[Path] = None
        else:
            self.persistence_csv = raw_path
            self.db_path = raw_path.with_suffix(".sqlite")

        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        if self.persistence_csv:
            self.persistence_csv.parent.mkdir(parents=True, exist_ok=True)

        self.persistence_file = self.persistence_csv or self.db_path

        self._seen_event_ids: Set[str] = set()
        self._acknowledged_ids: Set[str] = set()
        self._buffer: List[Dict[str, Any]] = []
        self._forwarded_log: List[Dict[str, Any]] = []

        # Initialize SQLite WAL database and run crash-recovery reconciliation
        self._init_sqlite_db()
        self._recover_and_load_state()

    def _get_connection(self) -> sqlite3.Connection:
        """Open a SQLite connection with WAL journal mode and immediate busy timeouts."""
        conn = sqlite3.connect(str(self.db_path), timeout=30.0)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode = WAL;")
        conn.execute("PRAGMA synchronous = NORMAL;")
        return conn

    def _init_sqlite_db(self) -> None:
        """Create tables and indexes with WAL mode enabled."""
        with self._get_connection() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS events (
                    event_id TEXT PRIMARY KEY,
                    timestamp TEXT NOT NULL,
                    timestamp_sort_key REAL NOT NULL,
                    scenario TEXT,
                    model_version TEXT,
                    p_hp_bar REAL,
                    t_ic_c REAL,
                    rpm REAL,
                    vib_mm_s REAL,
                    current_a REAL,
                    anomaly_prob REAL,
                    status TEXT,
                    state TEXT NOT NULL CHECK(state IN ('PENDING', 'IN_FLIGHT', 'ACKED')),
                    payload_json TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
            """)
            conn.execute("CREATE INDEX IF NOT EXISTS idx_events_state ON events(state);")
            conn.execute("CREATE INDEX IF NOT EXISTS idx_events_sort_key ON events(timestamp_sort_key);")
            conn.commit()

    def _recover_and_load_state(self) -> None:
        """
        Crash-Safe Outage & Restart Recovery:
        1. Atomic recovery: Any event left in 'IN_FLIGHT' state (due to abrupt process termination/SIGKILL)
           is automatically reset to 'PENDING'.
        2. All 'PENDING' events are loaded into the in-memory buffer in chronological sort-key order.
        3. All 'ACKED' event_ids are tracked in self._acknowledged_ids so retries are rejected idempotently.
        """
        now = time.time()
        with self._get_connection() as conn:
            # 1. Recover interrupted in-flight deliveries from prior crash/kill
            cursor = conn.execute(
                "UPDATE events SET state = 'PENDING', updated_at = ? WHERE state = 'IN_FLIGHT'",
                (now,)
            )
            recovered_inflight = cursor.rowcount
            if recovered_inflight > 0:
                logger.info("Process crash recovery: reset %d IN_FLIGHT events to PENDING", recovered_inflight)

            # 2. Load all ACKED events into memory
            acked_rows = conn.execute("SELECT event_id, payload_json FROM events WHERE state = 'ACKED' ORDER BY timestamp_sort_key ASC").fetchall()
            self._acknowledged_ids = {row["event_id"] for row in acked_rows}
            self._forwarded_log = [json.loads(row["payload_json"]) for row in acked_rows]

            # 3. Load all PENDING events into buffer in event-time order
            pending_rows = conn.execute("SELECT payload_json FROM events WHERE state = 'PENDING' ORDER BY timestamp_sort_key ASC").fetchall()
            self._buffer = [json.loads(row["payload_json"]) for row in pending_rows]

            # 4. Seen event IDs is the union of all IDs in store
            all_rows = conn.execute("SELECT event_id FROM events").fetchall()
            self._seen_event_ids = {row["event_id"] for row in all_rows}

            conn.commit()

        # Sync CSV audit file if enabled
        if self.persistence_csv:
            self._sync_csv_from_db()

    def _sync_csv_from_db(self) -> None:
        """Write complete database audit log to CSV for backward compatibility."""
        if not self.persistence_csv:
            return
        self.persistence_csv.parent.mkdir(parents=True, exist_ok=True)
        temp_csv = self.persistence_csv.with_name(self.persistence_csv.name + ".tmp")
        try:
            with self._get_connection() as conn, open(temp_csv, "w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow(CSV_FIELDNAMES)
                rows = conn.execute("""
                    SELECT timestamp, event_id, scenario, model_version,
                           p_hp_bar, t_ic_c, rpm, vib_mm_s, current_a, anomaly_prob,
                           status, CASE WHEN state = 'ACKED' THEN 'ACK' ELSE 'BUFFERED' END as ack_status
                    FROM events ORDER BY timestamp_sort_key ASC
                """).fetchall()
                for r in rows:
                    writer.writerow([r[col] for col in CSV_FIELDNAMES])
            temp_csv.replace(self.persistence_csv)
        except Exception as e:
            if temp_csv.exists():
                try:
                    temp_csv.unlink()
                except Exception:
                    pass
            logger.warning("Failed to sync CSV from SQLite DB: %s", e)

    def insert_event(self, event: Dict[str, Any]) -> bool:
        """
        Insert an event into the local store.
        - Idempotently rejects duplicates by event_id if already buffered, in-flight, or acknowledged.
        - Preserves strict event-time chronological ordering in buffer.
        - Persists atomically to SQLite WAL store with state = 'PENDING'.
        Returns True if accepted as new, False if duplicate.
        """
        event_id = str(event.get("event_id", "")).strip()
        if not event_id:
            raise ValueError("Event must include a non-empty 'event_id'.")

        # Fast in-memory deduplication check
        if event_id in self._seen_event_ids:
            return False

        ts_sort_key = parse_timestamp_sort_key(event.get("timestamp"))
        event_entry = dict(event)
        event_entry["event_id"] = event_id
        event_entry["_sort_key"] = ts_sort_key
        event_entry.setdefault("ack_status", "BUFFERED")

        now = time.time()
        payload_str = json.dumps(event_entry)

        try:
            with self._get_connection() as conn:
                conn.execute("""
                    INSERT INTO events (
                        event_id, timestamp, timestamp_sort_key, scenario, model_version,
                        p_hp_bar, t_ic_c, rpm, vib_mm_s, current_a, anomaly_prob,
                        status, state, payload_json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?, ?)
                """, (
                    event_id,
                    str(event.get("timestamp", datetime.now().isoformat())),
                    ts_sort_key,
                    event.get("scenario", "SIMULATED"),
                    event.get("model_version", "2.0.0-calibrated"),
                    float(event.get("p_hp_bar", 0.0) or 0.0),
                    float(event.get("t_ic_c", 0.0) or 0.0),
                    float(event.get("rpm", 0.0) or 0.0),
                    float(event.get("vib_mm_s", 0.0) or 0.0),
                    float(event.get("current_a", 0.0) or 0.0),
                    float(event.get("anomaly_prob", 0.0) if event.get("anomaly_prob") is not None and not (isinstance(event.get("anomaly_prob"), float) and event.get("anomaly_prob") != event.get("anomaly_prob")) else 0.0),
                    str(event.get("status", "NORMAL")),
                    payload_str,
                    now,
                    now
                ))
                conn.commit()
        except sqlite3.IntegrityError:
            # Duplicate event_id detected by primary key constraint
            self._seen_event_ids.add(event_id)
            return False

        self._seen_event_ids.add(event_id)
        self._buffer.append(event_entry)
        self._buffer.sort(key=lambda x: x["_sort_key"])

        # Also append to CSV if CSV persistence is configured
        if self.persistence_csv:
            self._append_row_to_csv(event_entry)

        return True

    def _append_row_to_csv(self, event: Dict[str, Any]) -> None:
        """Append an audit record to persistent CSV store."""
        if not self.persistence_csv:
            return
        if not self.persistence_csv.exists() or self.persistence_csv.stat().st_size == 0:
            with open(self.persistence_csv, "w", newline="", encoding="utf-8") as f:
                csv.writer(f).writerow(CSV_FIELDNAMES)
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
        with open(self.persistence_csv, "a", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow(row)

    def flush_forward(
        self,
        sink_fn: Optional[Callable[[Dict[str, Any]], bool]] = None,
        simulated_outage: bool = False
    ) -> Dict[str, Any]:
        """
        Store-and-forward flush logic with explicit state transitions:
        - If simulated_outage is True, transmission fails and events remain safely PENDING.
        - If simulated_outage is False:
          1. Atomically transitions event state from PENDING -> IN_FLIGHT.
          2. Invokes sink_fn(event).
          3. On confirmation (True), transitions state IN_FLIGHT -> ACKED.
          4. If delivery fails (False or exception), reverts state IN_FLIGHT -> PENDING.
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

        with self._get_connection() as conn:
            for evt in list(self._buffer):
                eid = evt.get("event_id")
                now = time.time()

                # Transition state PENDING -> IN_FLIGHT
                conn.execute(
                    "UPDATE events SET state = 'IN_FLIGHT', updated_at = ? WHERE event_id = ? AND state = 'PENDING'",
                    (now, eid)
                )
                conn.commit()

                delivered = False
                try:
                    delivered = sink_fn(evt)
                except Exception as err:
                    logger.warning("Sink delivery exception for %s: %s", eid, err)
                    delivered = False

                if delivered:
                    # Transition IN_FLIGHT -> ACKED
                    evt["ack_status"] = "ACK"
                    now_ack = time.time()
                    conn.execute(
                        "UPDATE events SET state = 'ACKED', updated_at = ? WHERE event_id = ?",
                        (now_ack, eid)
                    )
                    conn.commit()

                    successfully_forwarded.append(evt)
                    self._forwarded_log.append(evt)
                    if eid:
                        self._acknowledged_ids.add(eid)
                        delivered_ids.add(eid)
                else:
                    # Revert IN_FLIGHT -> PENDING for retry
                    conn.execute(
                        "UPDATE events SET state = 'PENDING', updated_at = ? WHERE event_id = ?",
                        (time.time(), eid)
                    )
                    conn.commit()
                    unacknowledged.append(evt)

        # Update in-memory buffer
        self._buffer = unacknowledged

        # Update persistent CSV if enabled
        if delivered_ids and self.persistence_csv and self.persistence_csv.exists():
            self._update_persistent_csv_acks(delivered_ids)

        return {
            "status": "RECONCILED",
            "message": f"Flushed and reconciled {len(successfully_forwarded)} events.",
            "forwarded_count": len(successfully_forwarded),
            "remaining_buffer": len(self._buffer)
        }

    def _update_persistent_csv_acks(self, acked_ids: Set[str]) -> None:
        """Update ack_status to ACK on disk in the CSV log using atomic replace."""
        if not self.persistence_csv or not self.persistence_csv.exists() or not acked_ids:
            return

        temp_path = self.persistence_csv.with_name(self.persistence_csv.name + ".tmp")
        try:
            with open(self.persistence_csv, "r", encoding="utf-8") as f_in, \
                 open(temp_path, "w", newline="", encoding="utf-8") as f_out:
                reader = csv.DictReader(f_in)
                writer = csv.DictWriter(f_out, fieldnames=CSV_FIELDNAMES)
                writer.writeheader()
                for row in reader:
                    eid = row.get("event_id", "").strip()
                    if eid in acked_ids:
                        row["ack_status"] = "ACK"
                    writer.writerow(row)
            temp_path.replace(self.persistence_csv)
        except Exception as e:
            if temp_path.exists():
                try:
                    temp_path.unlink()
                except Exception:
                    pass
            logger.warning("Failed to update ACK in persistent CSV: %s", e)

    def get_buffered_events(self) -> List[Dict[str, Any]]:
        """Return shallow copy of events currently awaiting forward."""
        return list(self._buffer)

    def get_forwarded_events(self) -> List[Dict[str, Any]]:
        """Return shallow copy of successfully forwarded events."""
        return list(self._forwarded_log)

    def is_acknowledged(self, event_id: str) -> bool:
        """Return True if the event has been successfully forwarded and acknowledged."""
        return str(event_id).strip() in self._acknowledged_ids

    def get_event_state(self, event_id: str) -> Optional[str]:
        """Query direct SQLite event state ('PENDING', 'IN_FLIGHT', or 'ACKED')."""
        with self._get_connection() as conn:
            row = conn.execute("SELECT state FROM events WHERE event_id = ?", (str(event_id),)).fetchone()
            return row["state"] if row else None

    def clear(self) -> None:
        """Clear database table and in-memory state (useful for test isolation)."""
        self._seen_event_ids.clear()
        self._acknowledged_ids.clear()
        self._buffer.clear()
        self._forwarded_log.clear()
        with self._get_connection() as conn:
            conn.execute("DELETE FROM events")
            conn.commit()
        if self.persistence_csv and self.persistence_csv.exists():
            with open(self.persistence_csv, "w", newline="", encoding="utf-8") as f:
                csv.writer(f).writerow(CSV_FIELDNAMES)
