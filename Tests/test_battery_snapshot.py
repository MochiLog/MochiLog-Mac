import importlib.util
from pathlib import Path
import unittest, json, hashlib
from datetime import datetime, timezone
spec=importlib.util.spec_from_file_location('snapshot',Path(__file__).parents[1]/'BatterySnapshot.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
class SnapshotTests(unittest.TestCase):
 def test_core_compatibility_and_all_fields(self):
  raw={'CycleCount':245,'CurrentCapacity':67,'IsCharging':False,'SerialNumber':'synthetic',
       'BatteryData':{'DesignCapacity':4000,'CurrentCapacity':2500},'Flags':[True,False,None],
       'Blob':b'\x00\xff','Huge':2**64-1,'Date':datetime(2026,10,8,tzinfo=timezone.utc),'Empty':{}}
  result=module.snapshot(raw); rows=json.loads(result['detailsJSON']); fields={tuple(x['path']):x for x in rows}
  self.assertEqual(result['values'],{'CycleCount':245,'CurrentCapacity':67,'IsCharging':False,'DesignCapacity':4000})
  self.assertEqual(fields[('Huge',)]['value'],'18446744073709551615')
  self.assertEqual(fields[('Blob',)]['value'],'AP8=')
  self.assertEqual(fields[('Flags','[1]')]['value'],'false')
  self.assertEqual(fields[('SerialNumber',)]['value'],'synthetic')
  self.assertEqual(fields[('BatteryData','CurrentCapacity')]['value'],'2500')
  self.assertEqual(result['detailsRevision'],hashlib.sha256(result['detailsJSON'].encode()).hexdigest())
 def test_independent_revisions(self):
  raw={'CycleCount':2,'DesignCapacity':4000}; a=module.snapshot(raw); raw['SerialNumber']='synthetic'; b=module.snapshot(raw)
  self.assertEqual(a['revision'],b['revision']); self.assertNotEqual(a['detailsRevision'],b['detailsRevision'])
  raw['CycleCount']=3; self.assertNotEqual(b['revision'],module.snapshot(raw)['revision'])
 def test_no_invented_core_values(self):
  result=module.snapshot({'CycleCount':True,'DesignCapacity':float('nan'),'FullChargeCapacity':2**64-1})
  self.assertEqual(result['values'],{}); self.assertEqual(len(json.loads(result['detailsJSON'])),3)
  self.assertEqual(module.filter_values({'CycleCount':0,'DesignCapacity':'4000','CurrentCapacity':101}),{'CycleCount':0})
 def test_unknown_fields_retained(self):
  self.assertNotIn('DesignCapacity',module.snapshot({'CycleCount':10})['values'])
  self.assertEqual(module.snapshot({'UnknownFlag':False})['values'],{})
 def test_bounds(self):
  for raw in [None,[],{}, {'Long':'x'*131073}, {'x':object()}, {'x'*513:1}]:
   with self.assertRaises(ValueError): module.snapshot(raw)
 def test_order_is_stable(self):
  self.assertEqual(module.snapshot({'B':2,'A':1})['detailsRevision'],module.snapshot({'A':1,'B':2})['detailsRevision'])
if __name__=='__main__':unittest.main()
