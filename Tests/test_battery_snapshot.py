"""The Python bridge transports registry data without interpreting it."""
import importlib.util
from pathlib import Path
import plistlib
import unittest
from datetime import datetime, timezone

spec = importlib.util.spec_from_file_location(
    "battery_bridge", Path(__file__).parents[1] / "BatterySnapshot.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BatteryBridgeTests(unittest.TestCase):
    def test_lossless_transport(self):
        registry = {
            "CycleCount": 245,
            "IsCharging": False,
            "BatteryData": {"DesignCapacity": 4000},
            "Huge": 2**64 - 1,
            "Blob": b"\x00\xff",
            "Date": datetime(2026, 10, 8, tzinfo=timezone.utc),
            "Flags": [True, False],
            "Empty": {},
        }
        payload = module.encode_registry(registry)
        self.assertEqual(plistlib.loads(payload, aware_datetime=True), registry)
        self.assertNotIn(b"detailsRevision", payload)
        self.assertNotIn(b"acquiredAt", payload)

    def test_transport_limits(self):
        for registry in (None, [], {}, {"Long": "x" * 1048577}):
            with self.assertRaises(ValueError):
                module.encode_registry(registry)

    def test_no_field_selection_in_bridge(self):
        registry = {"Unknown": False, "CurrentCapacity": 101, "CycleCount": True}
        decoded = plistlib.loads(module.encode_registry(registry))
        self.assertEqual(decoded, registry)
        self.assertIs(decoded["CycleCount"], True)


if __name__ == "__main__":
    unittest.main()
