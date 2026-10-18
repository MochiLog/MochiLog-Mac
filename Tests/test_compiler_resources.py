"""Keep CI parallelism within the runner budget, including unknown hardware."""

import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "compiler_resources", Path(__file__).resolve().parents[1] / "scripts/compiler-resources.py"
)
resources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resources)


class CompilerResourcesTests(unittest.TestCase):
    def test_standard_mac_runner_uses_all_three_cpus(self):
        policy = resources.resource_policy(3, 7 * 1024 * resources.MIB)
        self.assertEqual(policy["compilerJobs"], 3)
        self.assertFalse(policy["lowMemory"])

    def test_standard_windows_runner_uses_all_four_cpus(self):
        policy = resources.resource_policy(4, 16 * 1024 * resources.MIB)
        self.assertEqual(policy["compilerJobs"], 4)
        self.assertFalse(policy["lowMemory"])

    def test_memory_budget_limits_a_large_cpu_count(self):
        policy = resources.resource_policy(32, 5 * 1024 * resources.MIB)
        self.assertEqual(policy["compilerJobs"], 2)
        self.assertTrue(policy["lowMemory"])

    def test_unknown_hardware_uses_one_job_and_low_memory(self):
        policy = resources.resource_policy(None, None)
        self.assertEqual(policy["compilerJobs"], 1)
        self.assertTrue(policy["lowMemory"])

    def test_parallelism_has_a_hard_cap_and_a_positive_minimum(self):
        self.assertEqual(
            resources.resource_policy(64, 128 * 1024 * resources.MIB)["compilerJobs"], 8
        )
        self.assertEqual(resources.resource_policy(0, 1)["compilerJobs"], 1)


if __name__ == "__main__":
    unittest.main()
