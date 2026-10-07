import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('snapshot', Path(__file__).parents[1] / 'BatterySnapshot.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SnapshotTests(unittest.TestCase):
    def test_nested_registry_and_no_private_fields(self):
        raw = {'CycleCount':245, 'CurrentCapacity':67, 'IsCharging':False,
               'SerialNumber':'private', 'BatteryData':{'DesignCapacity':4000,
               'NominalChargeCapacity':3820, 'AppleRawMaxCapacity':3850,
               'FullChargeCapacity':3800, 'CurrentCapacity':2500}}
        result = module.snapshot(raw)
        self.assertEqual(result['values'], {'CycleCount':245,'CurrentCapacity':67,'IsCharging':False,
           'DesignCapacity':4000,'NominalChargeCapacity':3820,'AppleRawMaxCapacity':3850,'FullChargeCapacity':3800})
        self.assertNotIn('private',str(result))
    def test_hash_changes_only_for_values_not_time_or_serial(self):
        raw={'CycleCount':2,'DesignCapacity':4000}
        first=module.snapshot(raw)
        raw['SerialNumber']='ignored'
        self.assertEqual(first['revision'],module.snapshot(raw)['revision'])
        raw['CycleCount']=3
        self.assertNotEqual(first['revision'],module.snapshot(raw)['revision'])
    def test_reject_bool_nan_sentinels_and_wrong_types(self):
        with self.assertRaises(ValueError):
            module.snapshot({'CycleCount':True,'DesignCapacity':float('nan'),'FullChargeCapacity':2**64-1})
        self.assertEqual(module.filter_values({'CycleCount':0,'DesignCapacity':'4000','CurrentCapacity':101}),{'CycleCount':0})
    def test_missing_fields_not_zero(self):
        result=module.snapshot({'CycleCount':10})
        self.assertNotIn('DesignCapacity',result['values'])
    def test_no_battery_entry(self):
        for raw in [None,[],{'CurrentCapacity':50}]:
            with self.assertRaises(ValueError):module.snapshot(raw)

if __name__=='__main__':unittest.main()
