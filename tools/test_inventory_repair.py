"""Inventory scope, Lazarus recipes and bounded repairs; no game launch."""
import json
import unittest
from pathlib import Path
from lupa.lua54 import LuaRuntime
import test_movement_packages as fixtures
from test_boat import HARNESS

ROOT=Path(__file__).resolve().parent.parent

class InventoryScope(unittest.TestCase):
    def setUp(self):
        fixture=fixtures.Features();fixture.setUp();self.lua=fixture.lua

    def test_all_923_shipped_assets_and_large_tanks(self):
        rows=json.loads((ROOT/'verification/inventory-assets.json').read_text())
        identities=json.loads((ROOT/'verification/item-identities.json').read_text())
        self.assertEqual({r['path'] for r in rows},{r['path'] for r in identities})
        check=self.lua.eval('''function(path,support,filter,desiredOnly,desired,blocked)
            local a=item(path,18,support);a.CraftFilter=filter
            a.bOnlyAllowDesiredInventory=desiredOnly;a.DesiredInventory=desired
            a.BlockedInventoryTypes=blocked
            return require('features.packages').eligible(a,1)
        end''')
        enums={'Undefined':0,'PlayerInventory':1,'PlayerVault':2,'Container':4,'Hidden':5}
        for r in rows:
            blocked=[enums.get(v,v) for v in r['blocked']]
            # Buildable-only routing, inventory flag and target restrictions.
            buildOnly=r['buildable'] and not (r['craftFilter'] & (2|16))
            expected=r['supportInventory'] and not buildOnly and not (r['desiredOnly'] and r['desired']=='Vault') and 1 not in blocked
            with self.subTest(asset=r['path']):
                self.assertEqual(check(r['path'],r['supportInventory'],r['craftFilter'],r['desiredOnly'],1 if r['desired']=='Vault' else 0,self.lua.table_from(blocked)),expected)
        self.assertEqual(sum(r['oldEligible'] and r['buildable'] and not r['craftFilter']&2 for r in rows),116)

    def test_live_and_cached_give_cannot_bypass_build_or_inventory_rejection(self):
        self.lua.execute('''
            local p=require('features.packages')
            local tank=item('/Mod/LargeTank.LargeTank',18,true);tank.CraftFilter=9
            local cloth=item('/Game/Cloth.Cloth',22,true)
            local rejected=item('/Mod/Restricted.Restricted',19,true);rejected.rejectInventory=true
            package.loaded['data.item_paths']={tank.path,cloth.path,rejected.path}
            assert(p.start('all',3));finish(p)
            assert(inventoryCounts[tank.path]==nil and inventoryCounts[rejected.path]==nil)
            assert(inventoryCounts[cloth.path]==3)
            local rows=require('features.catalog').snapshot();assert(#rows==1)
            cloth.CraftFilter=9 -- eligibility changed after the catalog was cached
            assert(p.give(cloth,50,1)==0 and inventoryCounts[cloth.path]==3)
            assert(p.give(tank,1,2)==0)
            cloth.CraftFilter=0;inv.CanAddItem=function() error('unreadable inventory') end
            assert(p.give(cloth,50,1)==0 and inventoryCounts[cloth.path]==3)
        ''')

    def test_native_build_override_and_mixed_fabricator_recipe(self):
        self.lua.execute('''
            local p=require('features.packages')
            local custom=item('/Mod/Custom.Custom',18,true)
            function custom:IsBuildable() return true end
            assert(not p.eligible(custom,1))
            custom.CraftFilter=11 -- Nixie tubes have both build and fabricator routes
            assert(p.eligible(custom,1))
            custom.CraftFilter=nil;custom.IsBuildable=nil
            assert(not p.eligible(custom,1))
        ''')

    def test_lazarus_includes_live_recipes_but_never_pods_or_unrelated_items(self):
        self.lua.execute('''
            local p=require('features.packages')
            local seed=item('/Game/Data/Assets/Consumables/DA_HumanSeed.DA_HumanSeed',14,true)
            local ingredient=item('/Mod/Ingredient.Ingredient',16,true)
            local nutrient=item('/Mod/Nutrient.Nutrient',6,true)
            local food=item('/Mod/Food.Food',24,true,{ingredient,nutrient})
            local memory=item('/Mod/Memory.Memory',25,true)
            local pod=item('/Mod/Pod.Pod',18,true);pod.CraftFilter=9
            local weapon=item('/Mod/Gun.Gun',2,true)
            package.loaded['data.item_paths']={ingredient.path,food.path,memory.path,seed.path,pod.path,weapon.path}
            assert(p.start('lazarus',50));finish(p)
            for _,o in ipairs({ingredient,nutrient,food,memory,seed}) do assert(inventoryCounts[o.path]==50,o.path) end
            assert(inventoryCounts[pod.path]==nil and inventoryCounts[weapon.path]==nil)
            local cycle=item('/Mod/Cycle.Cycle',24,true,{food})
            food.Components.ForEach=function(_,fn) fn(cycle) end
            package.loaded['data.item_paths']={cycle.path}
            require('features.catalog').reset()
            assert(p.start('lazarus',1));finish(p) -- recursive recipes terminate
            assert(inventoryCounts[cycle.path]==1)
        ''')

AREA_HARNESS = r'''
area=require('features.repair'); candidates={};finds=0;resolved={};H.boxes={}
local originalFind=StaticFindObject
H.classes['/Script/Engine.Actor']=object('Class','Actor',{path='/Script/Engine.Actor'})
local sys={}
function sys:IsValid() return true end
function sys:BoxOverlapActors(pawn,center,extent,types,cls,ignore,out)
    finds=finds+1
    assert(pawn==H.pc.p.Pawn and cls==H.classes['/Script/Engine.Actor'])
    assert(#types==6 and types[1]==0 and types[6]==5 and #ignore==1)
    assert(extent.X<=2500 and extent.Y<=2500)
    H.boxes[#H.boxes+1]={center=center,extent=extent}
    if H.queryFail then error('spatial query failed') end
    if H.dense then for i=1,129 do out[i]=H.pawn end;return true end
    for _,actor in ipairs(candidates) do
        if math.abs(actor.p.x-center.X)<=extent.X and math.abs((actor.p.y or 0)-center.Y)<=extent.Y
            and math.abs((actor.p.z or 0)-center.Z)<=extent.Z then
            out[#out+1]=actor
        end
    end
    return #out>0
end
StaticFindObject=function(path)
    if path=='/Script/Engine.Default__KismetSystemLibrary' then return sys end
    return resolved[path] or originalFind(path)
end
function FindAllOf() error('Global scans forbidden') end
function track(o)
    o.p.lookup='/TestWorld.PersistentLevel.'..o.p.id
    rawset(o,'GetFullName',function(self) return 'Class '..self.p.lookup end)
    resolved[o.p.lookup]=o
    return o
end
function target(name,x,health)
    local actor=track(object('Structure',name,{level=H.level,x=x}))
    rawset(actor,'K2_GetActorLocation',function(self) return {X=self.p.x,Y=self.p.y or 0,Z=self.p.z or 0} end)
    local damage=track(makeDamage(actor,health or 20))
    rawset(damage,'bInitialized',true)
    candidates[#candidates+1]=actor
    return actor,damage
end
function drainArea() for _=1,2000 do if not area.busy() then return end;area.tick() end;error('unfinished') end
local ui={card=function()return {}end,button=function()end,infoRow=function()end,
    paragraph=function()end,add=function()end,toast=function()end,
    stepperRow=function(_,_,_,opts)H.areaStep=opts end}
area.addToPage(ui,{},{});H.areaStep.set(1)
'''

class Repairs(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f'package.path={json.dumps((ROOT/"Warden/Scripts/?.lua").as_posix()+";")}..package.path')
        self.lua.execute('require("i18n").setLanguage("de")')
        self.lua.execute(HARNESS)
        self.lua.execute(AREA_HARNESS)

    def test_native_member_without_scene_attachment_and_direct_health_override(self):
        self.lua.execute('''
            local a=makeBoat('A')
            local loose=object('ModuleActor','Snapped',{level=H.level})
            local damage=makeDamage(loose,10)
            local secondary=makeDamage(loose,20)
            local m=makeModule(loose,10,'noop',a);m.p.DestructibleObjectReference=damage
            repair();drain()
            assert(damage.Health==100 and secondary.Health==100 and H.repairs==2)
            contains('Repariert: 1 Module, 1 Bauteile')
        ''')

    def test_native_member_removed_before_processing_is_not_repaired(self):
        self.lua.execute('''
            local a=makeBoat('A')
            local loose=object('ModuleActor','Disconnected',{level=H.level})
            local damage=makeDamage(loose,10)
            local m=makeModule(loose,10,nil,a);m.p.DestructibleObjectReference=damage
            repair();a.p.modules={};drain()
            assert(damage.Health==10 and H.repairs==0)
        ''')

    def test_wrong_owner_damage_reference_is_not_modified(self):
        self.lua.execute('''
            local a=makeBoat('A');local b=makeBoat('B',500)
            local actor=attach(a,object('ModuleActor','Own'))
            local foreign=makeDamage(b,10)
            local m=makeModule(actor,10,nil,a);m.p.DestructibleObjectReference=foreign
            repair();drain();assert(foreign.Health==10 and H.repairs==0)
            contains('fehlgeschlagen: 1')
        ''')

    def test_radius_boundary_world_authority_destroyed_and_duplicate_filters(self):
        self.lua.execute('''
            local inside,d1=target('Inside',999)
            local edge,d2=target('Boundary',1000)
            local outside,d3=target('Outside',1001)
            local foreign,d4=target('OtherWorld',0);foreign.p.level=object('Level','Other',{OwningWorld=object('World','Other')})
            local dead,d5=target('Destroyed',0);dead.p.destroying=true
            local client,d6=target('Client',0);client.p.authority=false
            local npc,d7=target('NPC',0);npc.p.class='/Script/Engine.Pawn'
            candidates[#candidates+1]=inside
            assert(area.start());drainArea()
            assert(d1.Health==100 and d2.Health==100 and H.repairs==2 and finds==1)
            for _,d in ipairs({d3,d4,d5,d6,d7}) do assert(d.Health==20) end
            assert(area.status():find('2 repariert',1,true))
        ''')

    def test_snapshot_origin_work_budget_no_idle_scans_and_reentry(self):
        self.lua.execute('''
            for i=1,100 do target('Target'..i,0) end
            for _=1,10 do area.tick() end;assert(finds==0)
            assert(area.start());assert(not area.start());area.tick();assert(finds==1)
            H.pawn.p.x=100000 -- fixed center, no moving sweep through the world
            local last=H.repairs
            while area.busy() do area.tick();assert(H.repairs-last<=1);last=H.repairs end
            assert(H.repairs==100 and finds==1)
            area.tick();assert(finds==1)
        ''')

    def test_cancel_world_change_and_client_do_not_mutate(self):
        self.lua.execute('''
            local actor,damage=target('Target',0)
            H.pawn.p.authority=false;assert(not area.start());assert(finds==0)
            H.pawn.p.authority=true;assert(area.start());area.cancel();area.tick();assert(finds==0)
            assert(area.start());area.tick();damage.p.poison=true
            H.level=object('Level','New',{OwningWorld=object('World','New')})
            H.pawn=object('Character','NewPlayer',{level=H.level});H.pc.p.Pawn=H.pawn
            area.tick();assert(not area.busy() and H.repairs==0)
            assert(area.start());area.onWorldChanged();area.tick();assert(finds==1)
        ''')

    def test_partial_failed_and_already_healthy_are_reported(self):
        self.lua.execute('''
            local a,d=target('Noop',0);d.p.repairMode='noop'
            local b,e=target('Partial',0);e.p.repairMode='partial'
            local c,f=target('Healthy',0,100)
            assert(area.start());drainArea()
            assert(area.status():find('0 repariert, 1 intakt, 1 teilweise, 1 Fehler',1,true))
        ''')

if __name__=='__main__':unittest.main(verbosity=2)
