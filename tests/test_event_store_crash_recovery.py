"""
Crash-Safe SQLite WAL Event Store & Process-Kill Recovery Proof.

Verifies:
1. SQLite WAL mode activation (PRAGMA journal_mode=WAL).
2. Explicit state transitions: PENDING -> IN_FLIGHT -> ACKED.
3. Abrupt process-kill / SIGKILL resilience:
   - Spawns a worker subprocess that inserts events and enters an in-flight delivery loop.
   - Abruptly kills the worker subprocess mid-outage via SIGKILL/kill().
   - Reopens EventStore from disk and asserts automatic recovery of all IN_FLIGHT events back to PENDING.
   - Flushes to a verified sink, asserting ZERO stranded events and ZERO duplicate deliveries.
   - Reopens again, asserting persistent acknowledgement across subsequent restarts.
"""

import os
import sys
import time
import subprocess
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from scripts.ml.event_store import EventStore


class TestEventStoreCrashRecovery(unittest.TestCase):
    """Crash-safe SQLite WAL process termination and recovery suite."""

    def setUp(self):
        self.test_dir = PROJECT_ROOT / "reports" / "test_scratch"
        self.test_dir.mkdir(parents=True, exist_ok=True)
        self.test_db = self.test_dir / "crash_test_store.sqlite"
        self.test_csv = self.test_dir / "crash_test_store.csv"

        for p in [self.test_db, self.test_csv, self.test_db.with_name(self.test_db.name + "-wal"), self.test_db.with_name(self.test_db.name + "-shm")]:
            if p.exists():
                try:
                    p.unlink()
                except Exception:
                    pass

    def tearDown(self):
        for p in [self.test_db, self.test_csv, self.test_db.with_name(self.test_db.name + "-wal"), self.test_db.with_name(self.test_db.name + "-shm")]:
            if p.exists():
                try:
                    p.unlink()
                except Exception:
                    pass

    def test_wal_mode_and_state_transitions(self):
        """Verify SQLite operates in WAL mode and follows PENDING -> IN_FLIGHT -> ACKED transitions."""
        store = EventStore(persistence_file=self.test_db)

        # Check WAL mode via raw connection
        with store._get_connection() as conn:
            mode = conn.execute("PRAGMA journal_mode;").fetchone()[0]
            self.assertEqual(mode.lower(), "wal", "Database must operate in Write-Ahead Logging (WAL) mode")

        # Insert test event
        evt = {"event_id": "CRASH-001", "timestamp": "2026-11-25T12:00:00", "p_hp_bar": 8.0}
        self.assertTrue(store.insert_event(evt))
        self.assertEqual(store.get_event_state("CRASH-001"), "PENDING")

        # Simulate sink that observes IN_FLIGHT state
        in_flight_observed = []

        def observing_sink(e):
            st = store.get_event_state(e["event_id"])
            in_flight_observed.append(st)
            return True

        res = store.flush_forward(sink_fn=observing_sink)
        self.assertEqual(res["status"], "RECONCILED")
        self.assertEqual(res["forwarded_count"], 1)
        self.assertEqual(in_flight_observed, ["IN_FLIGHT"], "Event must transition to IN_FLIGHT during delivery")
        self.assertEqual(store.get_event_state("CRASH-001"), "ACKED", "Event must transition to ACKED upon delivery")
        self.assertTrue(store.is_acknowledged("CRASH-001"))

    def test_process_kill_mid_flight_recovery(self):
        """
        Process-Kill Resilience Test:
        1. Subprocess ingests 5 events and begins forwarding with an intentional stall.
        2. Subprocess is abruptly terminated (kill/SIGKILL) mid-flight.
        3. A fresh EventStore process opens the store.
        4. Asserts that any IN_FLIGHT/PENDING events are safely recovered into PENDING.
        5. Asserts reconciliation delivers all 5 events with zero duplicates and zero loss.
        """
        worker_code = f"""
import sys, time
from pathlib import Path
sys.path.insert(0, r"{PROJECT_ROOT}")
from scripts.ml.event_store import EventStore

store = EventStore(persistence_file=Path(r"{self.test_db}"))
for i in range(1, 6):
    store.insert_event({{
        "event_id": f"PKILL-{{i:03d}}",
        "timestamp": f"2026-11-25T12:00:{{i:02d}}",
        "p_hp_bar": 8.0 + i * 0.1
    }})

# Sink that signals ready, delivers first event, then stalls while holding second event in-flight
print("READY", flush=True)

def stalling_sink(evt):
    if evt["event_id"] == "PKILL-001":
        return True
    # Deliberately sleep indefinitely to be killed mid-flight
    time.sleep(100)
    return True

store.flush_forward(sink_fn=stalling_sink)
"""

        proc = subprocess.Popen(
            [sys.executable, "-c", worker_code],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        # Wait until worker outputs READY
        line = proc.stdout.readline()
        self.assertIn("READY", line)

        # Give small window so event 2 transitions to IN_FLIGHT in SQLite
        time.sleep(0.5)

        # Abruptly kill the worker process simulating SIGKILL / power loss
        proc.kill()
        proc.wait(timeout=5)

        # Verify process is terminated
        self.assertIsNotNone(proc.poll())

        # Now instantiate EventStore in fresh process context
        recovered_store = EventStore(persistence_file=self.test_db)

        # Event PKILL-001 was delivered before the stall, so it should be ACKED
        self.assertTrue(recovered_store.is_acknowledged("PKILL-001"))

        # Events PKILL-002 through 005 must be safely recovered into the pending buffer!
        buf = recovered_store.get_buffered_events()
        self.assertEqual(len(buf), 4, f"Expected 4 recovered events in pending buffer, got {len(buf)}")
        recovered_ids = [b["event_id"] for b in buf]
        self.assertEqual(recovered_ids, ["PKILL-002", "PKILL-003", "PKILL-004", "PKILL-005"])

        # Flush to working sink and verify zero duplicate deliveries and zero dropped events
        delivered_ids = []

        def working_sink(e):
            delivered_ids.append(e["event_id"])
            return True

        flush_res = recovered_store.flush_forward(sink_fn=working_sink)
        self.assertEqual(flush_res["forwarded_count"], 4)
        self.assertEqual(delivered_ids, ["PKILL-002", "PKILL-003", "PKILL-004", "PKILL-005"])
        self.assertEqual(len(recovered_store.get_buffered_events()), 0)

        # Reopen once more to confirm durable ACK persistence
        reopened_store = EventStore(persistence_file=self.test_db)
        self.assertEqual(len(reopened_store.get_buffered_events()), 0)
        for i in range(1, 6):
            self.assertTrue(reopened_store.is_acknowledged(f"PKILL-{i:03d}"))


if __name__ == "__main__":
    unittest.main()
