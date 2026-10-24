"""Real Lua catalog/search/package regressions. No running game or save edits."""
from pathlib import Path
import unittest
import test_movement_packages as fixtures
from lupa.lua54 import LuaRuntime

ROOT=Path(__file__).resolve().parent.parent
FABRIC='/Game/Data/Assets/Materials/DA_Material_Fabric.DA_Material_Fabric'


class ItemSearch(unittest.TestCase):
    setUp=fixtures.Features.setUp

    def test_stoff_is_found_even_when_bridge_returns_english(self):
        self.lua.execute(f'''
          n=require('item_names')
          name,search=n.describe('Fabric','{FABRIC}')
          row={{name=name,path='{FABRIC}',search=search}}
          assert(not string.lower('Fabric'):find('stoff',1,true)) -- old search misses it
          for _,q in ipairs({{'Stoff','STOFF',' fabric ','Cloth','Textil'}}) do
            assert(n.matches(row,n.normalize(q)),q)
          end
        ''')

    def test_native_conversion_resolves_localized_name_and_keeps_english_search(self):
        self.lua.execute(f'''
          core=package.loaded.core; calls=0
          value={{source='Fabric',display='Stoff'}}
          core.str=function(v) return type(v)=='table' and v.source or v end
          core.lib=function(k) if k=='text' then return {{Conv_TextToString=function(_,v)
            assert(v==value);calls=calls+1;return v.display end}} end end
          n=require('item_names'); name,search=n.describe(value,'{FABRIC}')
          assert(name=='Stoff' and calls==1)
          row={{name=name,path='{FABRIC}',search=search}}
          for i=1,100 do assert(n.matches(row,'stoff') and n.matches(row,'fabric')) end
          assert(calls==1) -- searching never calls the engine
        ''')

    def test_native_conversion_failure_and_missing_stringtable_have_readable_fallback(self):
        self.lua.execute(f'''
          core=package.loaded.core; core.str=function() return '<MISSING STRING TABLE ENTRY>' end
          core.lib=function() return {{Conv_TextToString=function() error('unavailable') end}} end
          name,search=require('item_names').describe({{}},'{FABRIC}')
          assert(name=='Stoff' and search:find('stoff',1,true))
        ''')

    def test_german_unicode_case_and_literal_search(self):
        self.lua.execute('''
          n=require('item_names')
          assert(n.normalize('  RÖHREN ÄÖÜẞ  ')==n.normalize('röhren äöüß'))
          row={name='Gehäuse (groß)',path='/Game/Item.Item'}
          assert(n.matches(row,n.normalize('GEHÄUSE')))
          assert(not n.matches(row,'.*'))
        ''')

    def test_shared_catalog_gives_fabric_in_all_and_parts_exactly_once(self):
        for kind in ('all','parts'):
            self.setUp()
            self.lua.execute(f'''
              fabric=item('{FABRIC}',22,true);fabric.Name='Fabric'
              recipe=item('/Game/Recipe.Recipe',18,false,{{fabric}})
              package.loaded['data.item_paths']={{recipe.path,fabric.path,fabric.path}}
              p=require('features.packages');assert(p.start('{kind}',50));finish(p)
              assert(inventoryCounts[fabric.path]==50)
              rows,_,ready=require('features.catalog').snapshot()
              assert(ready and #rows==1 and require('item_names').matches(rows[1],'stoff'))
            ''')

    def test_search_does_not_bypass_inventory_restrictions_or_give_on_load(self):
        self.lua.execute(f'''
          fabric=item('{FABRIC}',22,true);fabric.Name='Fabric';fabric.BlockedInventoryTypes={{1}}
          package.loaded['data.item_paths']={{fabric.path}}
          c=require('features.catalog');c.start();for i=1,5 do c.tick() end
          rows=c.snapshot();assert(#rows==1 and not rows[1].player and rows[1].vault)
          assert(next(inventoryCounts)==nil)
          p=require('features.packages');assert(p.start('all',50));finish(p)
          assert(next(inventoryCounts)==nil)
        ''')

    def test_all_material_paths_are_present_and_searchable_with_german_names(self):
        self.lua.execute('''
          package.loaded['data.item_paths']=nil
          names=require('item_names'); manifest=require('data.item_paths')
          count=0
          for _,path in ipairs(manifest) do
            if path:find('/Materials/',1,true) then
              local name,search=names.describe(nil,path)
              assert(not name:find('DA_',1,true),path)
              assert(names.matches({search=search},names.normalize(name)),path)
              count=count+1
            end
          end
          assert(count==21)
        ''')

    def test_new_search_resets_stale_category_and_page(self):
        # Capture the real page's controls and results without emulating Slate.
        self.lua.execute(f'''
          cloth={{path='{FABRIC}',name='Stoff',lname='stoff',cat=22,player=true,vault=true,search='stoff fabric'}}
          gun={{path='/Game/Gun.Gun',name='Waffe',lname='waffe',cat=2,player=true,vault=true}}
          package.loaded['features.catalog']={{start=function() end,refresh=function() end,snapshot=function() return {{cloth,gun}},{{}},true,1,'ready' end}}
          controls={{}}; searches={{}}; pools={{}}
          ui={{F={{}},C={{}},CENTER=0}}
          function ui.newPage() return {{left={{}},refreshers={{}}}} end
          function ui.segmented(_,captions,onSelect)
            local s={{captions=captions,onSelect=onSelect}}
            s.set=function(i) s.selected=i end;controls[#controls+1]=s;return s
          end
          function ui.searchBox() local s={{value=''}};s.get=function() return s.value end;searches[#searches+1]=s;return s end
          function ui.listPool() local p={{}};p.set=function(rows) p.rows=rows end;pools[#pools+1]=p;return p end
          function ui.addRefresher(page,fn) page.refreshers[#page.refreshers+1]=fn end
          function ui.setText() end
          setmetatable(ui,{{__index=function() return function() return {{}} end end}})
          s=require('features.spawn');page=s.page(ui)
          local filters
          for _,c in ipairs(controls) do if c.captions[2]=='Material' then filters=c end end
          filters.onSelect(5);assert(#pools[2].rows==1 and pools[2].rows[1].name=='Waffe')
          searches[2].value=' STOFF ';s.refreshItems(true)
          assert(filters.selected==1 and #pools[2].rows==1 and pools[2].rows[1].name=='Stoff')
          -- A subsequent explicit category click still works with the same search.
          filters.onSelect(5);assert(#pools[2].rows==0)
        ''')


if __name__=='__main__':unittest.main()
