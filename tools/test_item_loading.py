"""Missing assets must be retried and actually reach inventory, not only search."""
from pathlib import Path
import json
import unittest
import test_movement_packages as fixtures
from test_release_100_reopen_boat import Param

ROOT=Path(__file__).resolve().parent.parent
FABRIC='/Game/Data/Assets/Materials/DA_Material_Fabric.DA_Material_Fabric'


class ItemLoading(unittest.TestCase):
    def setUp(self):
        fixtures.Features.setUp(self)
        self.lua.globals().wrap=Param
        self.lua.execute(f'''
          fabric=item('{FABRIC}',22,true);fabric.Name='Fabric'
          package.loaded['data.item_paths']={{fabric.path}}
          registry[fabric.path]=nil
          core=package.loaded.core
          loads=0;nativeLoads=0
          LoadAsset=function() loads=loads+1;return nil,false,false end
        ''')

    def install_native_loader(self):
        self.lua.execute('''
          previous=core.lib
          core.lib=function(k)
            if k=='blueprintUI' then return {LoadDataAssetsById=function(_,ids)
              assert(#ids==1 and ids[1].PrimaryAssetType.Name=='Material')
              assert(ids[1].PrimaryAssetName=='DA_Material_Fabric')
              nativeLoads=nativeLoads+1
              return {wrap(fabric)}
            end} end
            return previous(k)
          end
          -- Production UE4SS return-array unwrapping, including actual userdata.
          package.loaded.core=nil;package.preload.UEHelpers=function() return {} end
          actual=require('core');core.outList=actual.outList;core.unwrap=actual.unwrap
          package.loaded.core=core
        ''')

    def test_primary_loader_supplies_missing_fabric_to_both_packages(self):
        for kind in ('all','parts'):
            self.setUp();self.install_native_loader()
            self.lua.execute(f'''
              p=require('features.packages');assert(p.start('{kind}',50));finish(p)
              assert(inventoryCounts[fabric.path]==50 and nativeLoads>=2)
              rows,_,ready,_,_,failed=require('features.catalog').snapshot()
              assert(ready and failed==0 and #rows==1 and rows[1].player)
            ''')

    def test_native_loader_rejects_different_asset_with_same_type(self):
        self.install_native_loader()
        self.lua.execute('''
          expected=fabric.path;fabric.path='/Game/Wrong.Wrong'
          p=require('features.packages');assert(p.load(expected)==nil)
          assert(next(inventoryCounts)==nil)
        ''')

    def test_already_loaded_items_never_invoke_either_loader(self):
        self.install_native_loader()
        self.lua.execute('''
          registry[fabric.path]=fabric
          assert(require('features.packages').load(fabric.path)==fabric)
          assert(loads==0 and nativeLoads==0)
        ''')

    def test_second_scan_pass_recovers_transient_failure_without_duplicates(self):
        self.lua.execute('''
          LoadAsset=function(path)
            loads=loads+1
            if loads==2 then registry[path]=fabric;return fabric,true,true end
            return nil,false,false
          end
          p=require('features.packages');assert(p.start('parts',50));finish(p)
          rows,_,ready,_,_,failed=require('features.catalog').snapshot()
          assert(ready and loads==2 and failed==0 and #rows==1)
          assert(inventoryCounts[fabric.path]==50)
        ''')

    def test_package_retries_previously_cached_missing_asset(self):
        self.lua.execute('''
          a=item('/Game/A.A',19,true);package.loaded['data.item_paths']={a.path,fabric.path}
          c=require('features.catalog');c.start();for i=1,8 do c.tick() end
          rows,_,ready,_,_,failed=c.snapshot();assert(ready and failed==1 and #rows==1)
          -- World data becomes available after the UI's earlier incomplete scan.
          registry[fabric.path]=fabric
          p=require('features.packages');assert(p.start('parts',50));finish(p)
          rows,_,ready,_,_,failed=c.snapshot()
          assert(ready and failed==0 and #rows==2)
          assert(inventoryCounts[fabric.path]==50 and inventoryCounts[a.path]==50)
        ''')

    def test_failed_scan_does_not_retry_forever_during_ui_refresh(self):
        self.lua.execute('''
          c=require('features.catalog');c.start();for i=1,8 do c.tick() end
          assert(loads==2)
          for i=1,1000 do c.start();c.tick() end
          assert(loads==2)
          _,_,ready,_,_,failed=c.snapshot();assert(ready and failed==1)
        ''')

    def test_persistent_missing_item_is_never_reported_as_complete(self):
        self.lua.execute('''
          p=require('features.packages');success=nil
          assert(p.start('all',50,function(_,ok) success=ok end));finish(p)
          assert(success==false and next(inventoryCounts)==nil)
          assert(p.status():find('1 Assets nicht geladen',1,true))
          assert(table.concat(logs,';'):find('DA_Material_Fabric',1,true))
        ''')

    def test_player_change_cancels_retries_before_any_new_load(self):
        self.lua.execute('''
          c=require('features.catalog');c.start();c.tick();local count=loads
          pc=obj({});c.tick();assert(loads==count)
          rows,_,ready=c.snapshot();assert(#rows==0 and not ready)
        ''')

    def test_identity_manifest_exactly_matches_cooked_items(self):
        rows=json.loads((ROOT/'verification/item-identities.json').read_text())
        self.assertEqual(len(rows),923)
        self.assertFalse(any('error' in row for row in rows))
        self.lua.execute("package.loaded['data.item_paths']=nil; paths=require('data.item_paths'); types=require('data.item_types')")
        types=self.lua.globals().types
        self.assertEqual(len(list(types)),923)
        for row in rows:
            self.assertEqual(types[row['path']],row['assetType'])
        self.assertEqual(types[FABRIC],'Material')


if __name__=='__main__':unittest.main()
