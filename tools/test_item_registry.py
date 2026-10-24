"""Registered mod assets must reach a cached catalogue and both inventory packages."""
import unittest
import test_movement_packages as fixtures
from test_release_100_reopen_boat import Param


class ItemRegistry(unittest.TestCase):
    def setUp(self):
        fixtures.Features.setUp(self)
        self.lua.globals().wrap=Param
        self.lua.execute('''
          core=package.loaded.core
          package.loaded.core=nil;package.preload.UEHelpers=function() return {} end
          actual=require('core')
          core.outList=actual.outList;core.outValue=actual.outValue
          core.unwrap=actual.unwrap;core.str=actual.str;core.logOnce=core.log
          package.loaded.core=core
          now=100;os.clock=function() return now end
          classQueries,packageQueries,tagQueries=0,0,0
          assetRows={};native=obj({path='/Engine/AssetRegistry'})
          cdo=obj({path='/Script/AssetRegistry.Default__AssetRegistryImpl'})
          FindAllOf=function(cls)
            if cls=='AssetRegistryImpl' then return {wrap(cdo),wrap(native)} end
            return {}
          end
          function assetRow(path,kind)
            return {PackageName=path:match('^(.+)%.[^%.]+$'),
              AssetName=path:match('%.([^%.]+)$'),kind=kind}
          end
          registry['/Script/AssetRegistry.AssetRegistry:GetAssetsByClass']=function(context,cls,out,recursive)
            assert(context==native and cls.PackageName=='/Script/Voyage')
            assert(cls.AssetName=='VoyageItem' and recursive==true)
            classQueries=classQueries+1;out.OutAssetData={}
            for _,row in ipairs(assetRows) do table.insert(out.OutAssetData,wrap(row)) end
            return true
          end
          registry['/Script/AssetRegistry.AssetRegistry:GetAssetsByPackageName']=function(context,pkg,out,disk,skip)
            assert(context==native and disk==false and skip==false)
            packageQueries=packageQueries+1
            for _,row in ipairs(assetRows) do
              if row.PackageName==pkg then out[#out+1]=wrap(row) end
            end
            return true
          end
          registry['/Script/AssetRegistry.Default__AssetRegistryHelpers']={GetTagValue=function(_,row,tag,out)
            assert(tag=='PrimaryAssetType');tagQueries=tagQueries+1
            if not row.kind then return false end
            out.OutTagValue=row.kind;return true
          end}
        ''')

    def test_registered_unloaded_mod_item_is_discovered_without_loading_or_tags(self):
        self.lua.execute('''
          modPath='/MyMod/Items/DA_ModFabric.DA_ModFabric'
          assetRows={assetRow(modPath,'ModMaterial'),assetRow(modPath,'ModMaterial'),{}}
          LoadAsset=function() error('discovery must not load assets') end
          r=require('item_registry');paths=r.paths()
          assert(#paths==1 and paths[1]==modPath and classQueries==1)
          assert(tagQueries==0 and packageQueries==0)
          assert(r.assetType(modPath)=='ModMaterial')
          assert(r.assetType(modPath)=='ModMaterial' and tagQueries==1 and packageQueries==1)
        ''')

    def test_unknown_type_is_not_guessed_and_late_metadata_can_recover(self):
        self.lua.execute('''
          path='/Mod/Part.Part';assetRows={assetRow(path,nil)}
          r=require('item_registry');assert(r.assetType(path)==nil)
          assetRows[1].kind='CustomPart'
          assert(r.assetType(path)=='CustomPart' and tagQueries==2)
        ''')

    def test_dynamic_type_drives_native_fallback_and_package_delivery(self):
        for kind in ('all','parts'):
            self.setUp()
            self.lua.execute(f'''
              mod=item('/Mod/DA_NewFabric.DA_NewFabric',22,true)
              assetRows={{assetRow(mod.path,'CustomFabric')}};registry[mod.path]=nil
              LoadAsset=function() return nil,false,false end
              local old=core.lib
              core.lib=function(name)
                if name=='blueprintUI' then return {{LoadDataAssetsById=function(_,ids)
                  assert(ids[1].PrimaryAssetType.Name=='CustomFabric')
                  assert(ids[1].PrimaryAssetName=='DA_NewFabric');return {{wrap(mod)}}
                end}} end
                return old(name)
              end
              p=require('features.packages');assert(p.start('{kind}',50));finish(p)
              assert(inventoryCounts[mod.path]==50 and tagQueries==1)
              rows,_,ready=require('features.catalog').snapshot()
              assert(ready and #rows==1 and rows[1].path==mod.path)
            ''')

    def test_refresh_adds_new_mod_item_without_reloading_cached_items(self):
        self.lua.execute('''
          a=item('/Game/A.A',19,true);assetRows={assetRow(a.path,'Part')}
          p=require('features.packages');local old=p.load;local loaded={}
          p.load=function(path) loaded[#loaded+1]=path;return old(path) end
          c=require('features.catalog');c.start();for i=1,10 do c.tick() end
          assert(#loaded==1 and classQueries==1)
          b=item('/Mod/B.B',22,true);assetRows[#assetRows+1]=assetRow(b.path,'Material')
          for i=1,1000 do c.start();c.tick() end
          assert(#loaded==1 and classQueries==1)
          c.refresh();c.tick();assert(classQueries==1) -- rapid reopen is throttled
          now=106;c.refresh();for i=1,10 do c.tick() end
          rows,_,ready=c.snapshot()
          assert(ready and #rows==2 and #loaded==2 and loaded[2]==b.path)
          assert(classQueries==2 and tagQueries==0)
          assert(require('item_names').matches(rows[2],'/mod/b'))
        ''')

    def test_package_request_discovers_mod_registered_after_ready_catalog(self):
        for kind in ('all','parts'):
            self.setUp()
            self.lua.execute(f'''
              a=item('/Game/A.A',19,true);assetRows={{assetRow(a.path,'Part')}}
              c=require('features.catalog');c.start();for i=1,10 do c.tick() end
              b=item('/Mod/B.B',22,true);assetRows[#assetRows+1]=assetRow(b.path,'Material')
              now=106;p=require('features.packages');assert(p.start('{kind}',50));finish(p)
              assert(inventoryCounts[a.path]==50 and inventoryCounts[b.path]==50)
              assert(classQueries==2)
            ''')

    def test_missing_registry_still_uses_manifest_and_loaded_objects(self):
        self.lua.execute('''
          a=item('/Game/A.A',19,true);package.loaded['data.item_paths']={a.path}
          b=item('/Mod/B.B',22,true)
          FindAllOf=function(cls) if cls=='VoyageItem' then return {b} end return {} end
          p=require('features.packages');assert(p.start('all',1));finish(p)
          assert(inventoryCounts[a.path]==1 and inventoryCounts[b.path]==1)
        ''')


if __name__=='__main__':unittest.main()
