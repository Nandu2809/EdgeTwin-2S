"""
Closed-Loop Co-Simulation Bridge & Twin Actuator Verification Test Suite.

Verifies:
1. End-to-end closed-loop cycle: Twin Physics Step -> ML Feature Contract -> Supervisory Diagnostics -> Actuator Response -> Twin State Relaxation.
2. Normal operating condition: Fault code 0, all actuators unenergized.
3. High Pressure Fault (OVERPRESSURE_HP): Fault code 2, motor stop & unloader commanded, twin relieves pressure.
4. High Temp Fault (OVERTEMP_IC): Fault code 1, cooling fan commanded, twin temperature drops.
5. Corrupt Sensor Fault (SENSOR_FAULT): Non-finite values classified as sensor fault (code 4), unloader engaged.
6. Local IPC TCP socket loopback message loop: Validates network/IPC framing and round-trip JSON serialization.
7. Explicit software boundary notes distinguishing software/bridge execution from unmeasured physical hardware links.
"""

import sys
import json
import time
import socket
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from scripts.simulation.co_simulation_bridge import CoSimulationBridge, CompressorTwinEngine


class TestClosedLoopTwin(unittest.TestCase):
    """Closed-loop co-simulation test suite."""

    @classmethod
    def setUpClass(cls):
        cls.bridge = CoSimulationBridge()

    def test_01_normal_closed_loop_operation(self):
        """In nominal regime, fault code is 0 and actuators remain uncommanded."""
        act_fb = [0.0, 0.0, 0.0, 0.0]
        step_res = self.bridge.step_closed_loop(t=1.0, scenario="NORMAL", prev_act_fb=act_fb)

        self.assertEqual(step_res["diagnostic_fault_code"], 0)
        self.assertEqual(step_res["actuator_command"], [0.0, 0.0, 0.0, 0.0])
        self.assertEqual(step_res["ground_truth"]["fault_code"], 0)
        self.assertIn("software_boundary_note", step_res)
        self.assertLess(step_res["round_trip_latency_us"], 50000.0, "Step must execute in < 50ms")

    def test_02_overpressure_closed_loop_mitigation(self):
        """
        OVERPRESSURE_HP fault injection:
        - Detects fault code 2 (Overpressure HP).
        - Actuates motor_stop = 1.0, unloader = 1.0.
        - Subsequent closed-loop step with updated actuator feedback relaxes HP pressure.
        """
        act_fb = [0.0, 0.0, 0.0, 0.0]

        # Initial step under overpressure fault
        step_1 = self.bridge.step_closed_loop(t=1.0, scenario="OVERPRESSURE_HP", prev_act_fb=act_fb)
        self.assertEqual(step_1["diagnostic_fault_code"], 2)
        self.assertEqual(step_1["actuator_command"][0], 1.0, "Motor stop commanded")
        self.assertEqual(step_1["actuator_command"][1], 1.0, "Unloader commanded")

        p_hp_initial = step_1["telemetry"]["p_hp_bar"]
        self.assertGreater(p_hp_initial, 10.5, "Discharge pressure exceeds threshold")

        # Advance closed loop with updated actuator feedback
        act_fb = step_1["actuator_feedback"]
        for t_step in [1.2, 1.4, 1.6, 1.8, 2.0]:
            step_k = self.bridge.step_closed_loop(t=t_step, scenario="OVERPRESSURE_HP", prev_act_fb=act_fb)
            act_fb = step_k["actuator_feedback"]

        # Actuator unloader relaxation relieves discharge pressure
        p_hp_relieved = step_k["telemetry"]["p_hp_bar"]
        self.assertLess(p_hp_relieved, p_hp_initial, "Closed-loop unloader action must relieve HP pressure")

    def test_03_overtemp_closed_loop_mitigation(self):
        """
        OVERTEMP_IC fault injection:
        - Detects fault code 1 (Overtemperature Intercooler).
        - Actuates cooling_fan = 1.0.
        - Twin intercooler temperature drops under fan feedback.
        """
        act_fb = [0.0, 0.0, 0.0, 0.0]
        step_1 = self.bridge.step_closed_loop(t=1.0, scenario="OVERTEMP_IC", prev_act_fb=act_fb)
        self.assertEqual(step_1["diagnostic_fault_code"], 1)
        self.assertEqual(step_1["actuator_command"][2], 1.0, "Cooling fan commanded")

        t_ic_initial = step_1["telemetry"]["t_ic_c"]
        self.assertGreater(t_ic_initial, 135.0)

        # Advance closed loop with fan feedback active
        act_fb = step_1["actuator_feedback"]
        for t_step in [1.5, 2.0, 2.5]:
            step_k = self.bridge.step_closed_loop(t=t_step, scenario="OVERTEMP_IC", prev_act_fb=act_fb)
            act_fb = step_k["actuator_feedback"]

        t_ic_cooled = step_k["telemetry"]["t_ic_c"]
        self.assertLess(t_ic_cooled, t_ic_initial, "Cooling fan feedback must reduce intercooler temperature")

    def test_04_sensor_dropout_closed_loop(self):
        """SENSOR_FAULT injection (NaN reading): Classifies as fault code 4 and triggers fail-safe unloader."""
        step_res = self.bridge.step_closed_loop(t=1.0, scenario="SENSOR_FAULT", prev_act_fb=[0.0, 0.0, 0.0, 0.0])
        self.assertEqual(step_res["diagnostic_fault_code"], 4)
        self.assertEqual(step_res["actuator_command"][1], 1.0, "Unloader commanded on sensor fault")

    def test_05_tcp_ipc_message_loop(self):
        """Test local TCP socket IPC message loop for co-simulation."""
        bridge = CoSimulationBridge()
        port = bridge.start_tcp_server()
        self.assertGreater(port, 0)

        try:
            # Client socket connection
            client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            client.connect(("127.0.0.1", port))
            client.settimeout(3.0)

            req = {"command": "step", "t": 2.5, "scenario": "NORMAL", "act_fb": [0.0, 0.0, 0.0, 0.0]}
            t0 = time.perf_counter_ns()
            client.sendall((json.dumps(req) + "\n").encode("utf-8"))

            f = client.makefile("r", encoding="utf-8")
            resp_line = f.readline()
            t1 = time.perf_counter_ns()
            round_trip_ms = (t1 - t0) / 1_000_000.0

            resp = json.loads(resp_line)
            self.assertEqual(resp["scenario"], "NORMAL")
            self.assertEqual(resp["diagnostic_fault_code"], 0)
            self.assertIn("software_boundary_note", resp)
            self.assertLess(round_trip_ms, 50.0, "TCP loopback round-trip must be < 50ms")

            client.close()
        finally:
            bridge.stop_tcp_server()


if __name__ == "__main__":
    unittest.main()
