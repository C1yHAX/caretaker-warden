"""Boat regression + build-specific reflection checks. Never starts/installs TLC.

Run with an existing Python containing lupa.lua54:
    python tools/test_boat.py
Optional: WARDEN_JMAP=<path to supplied jmap.pkl or jmap.gz>
          WARDEN_UE4SS_SOURCE=<directory containing LuaUObject.cpp/LuaUFunction.hpp>

The strict Lua doubles test control flow and failure accounting. They cannot prove
native ProcessEvent safety, rotor physics, actual module membership or game visuals.
Reflection tests load the repository's compressed JMAP (no pickle needed by default).
"""

import gzip
import json
import os
from pathlib import Path
import pickle
import re
import unittest

from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
BOAT_FILE = ROOT / "Warden/Scripts/features/boat.lua"
SCRATCH = ROOT / "reference"

# Verified parameter storage, including return values and padding, in this build.
FUNCTIONS = {
    "/Script/Voyage.VoyageVehiclePawn:GetDriver": (8, []),
    "/Script/Voyage.VoyageVehiclePawn:OnEnterVehicle": (8, ["NewPossessor"]),
    "/Script/Voyage.VoyageBoatPawn:GetTotalEnginePower": (4, []),
    "/Script/Engine.Actor:GetLevel": (8, []),
    "/Script/Engine.Actor:GetAttachParentActor": (8, []),
    "/Script/Engine.Actor:GetAttachedActors": (24, ["OutActors", "bResetArray", "bRecursivelyIncludeAttachedActors"]),
    "/Script/Engine.Actor:K2_GetComponentsByClass": (24, ["ComponentClass"]),
    "/Script/Engine.Actor:K2_GetActorLocation": (24, []),
    "/Script/Engine.Actor:HasAuthority": (1, []),
    "/Script/Engine.Actor:IsActorBeingDestroyed": (1, []),
    "/Script/Engine.ActorComponent:GetOwner": (8, []),
    "/Script/Engine.GameplayStatics:GetAllActorsOfClass": (32, ["WorldContextObject", "ActorClass", "OutActors"]),
    "/Script/Engine.Controller:K2_GetPawn": (8, []),
    "/Script/Voyage.VoyageBoatPawn:GetAllModules": (16, ["Modules"]),
    "/Script/Voyage.VoyageModuleComponent:GetPrimaryResourceType": (1, []),
    "/Script/Voyage.VoyageModuleComponent:GetResourceAmount": (16, ["Type"]),
    "/Script/Voyage.VoyageModuleComponent:GetMaxResourceAmount": (16, ["Type"]),
    "/Script/Voyage.VoyageModuleComponent:ForceAddResource": (24, ["Type", "AddAmount"]),
    "/Script/Voyage.VoyageBoatPawn:AddUprightForce": (4, ["Multiplier"]),
    "/Script/Voyage.VoyageBoatPawn:LiftAnchors": (0, []),
    "/Script/Voyage.VoyageBoatPawn:DropAnchors": (0, []),
    "/Script/Voyage.VoyageModuleComponent:GetDurability": (4, []),
    "/Script/Voyage.VoyageModuleComponent:GetMaxDurability": (4, []),
    "/Script/Voyage.VoyageModuleComponent:Repair": (4, ["Amount"]),
    "/Script/Voyage.VoyageDestructibleObjectComponent:OverrideHealth": (4, ["NewHealth"]),
}

HARNESS = r'''
BOAT = "/Script/Voyage.VoyageBoatPawn"
ROTOR = "/Script/Voyage.VoyageModuleRotorActor"
MODULE = "/Script/Voyage.VoyageModuleComponent"
DAMAGE = "/Script/Voyage.VoyageDestructibleObjectComponent"
H = { id=0, scans=0, lists=0, componentLists=0, writes=0, repairs=0, accesses=0,
    logs={}, boats={}, buttons={}, refreshers={}, labels={}, failScan=false }
local methods = {}
function methods:IsValid() return self.p.valid end
function methods:GetAddress() return self.p.id end
function methods:GetFullName() return self.p.name end
function methods:IsA(class) return self.p.class == class end
function methods:IsActorBeingDestroyed() return self.p.destroying end
function methods:GetLevel() return self.p.level end
function methods:GetAttachParentActor() return self.p.parent end
function methods:K2_GetActorLocation() return {X=self.p.x, Y=0, Z=0} end
function methods:HasAuthority() return self.p.authority end
function methods:K2_GetPawn() return self.p.Pawn end
function methods:GetOwner() return self.p.owner end
function methods:GetAttachedActors(out, reset, recursive)
    assert(type(out)=="table" and reset==true and recursive==true)
    H.lists = H.lists+1
    if self.p.failAttachments then error("attachment read failed") end
    for i,v in ipairs(self.p.attached) do out[i]=v end
end
function methods:GetAllModules(out)
    assert(type(out)=="table")
    H.lists = H.lists+1
    if self.p.failModules then error("module read failed") end
    if self.p.namedOut then out.Modules = self.p.modules
    else for i,v in ipairs(self.p.modules) do out[i]=v end end
end
function methods:K2_GetComponentsByClass(class)
    H.componentLists = H.componentLists+1
    if self.p.failComponents then error("component read failed") end
    assert(class.p.path==MODULE or class.p.path==DAMAGE)
    local out = {}
    for _,v in ipairs(self.p.components) do
        if v.p.class==class.p.path then out[#out+1]=v end
    end
    return out
end
function methods:GetPrimaryResourceType() return self.p.resource or 0 end
function methods:GetResourceAmount(kind) return self.p.amount or 0 end
function methods:GetMaxResourceAmount(kind) return self.p.capacity or 0 end
function methods:ForceAddResource(kind, amount)
    self.p.amount=math.min(self.p.capacity or 0, (self.p.amount or 0)+amount)
    H.refills=(H.refills or 0)+1
end
function methods:GetDurability()
    if self.p.failRead then error("no durability") end
    if self.p.DestructibleObjectReference then return self.p.DestructibleObjectReference.p.Health end
    return self.p.durability
end
function methods:GetMaxDurability() return self.p.maximum end
function methods:Repair(amount)
    assert(type(amount)=="number" and amount>0)
    H.repairs=H.repairs+1
    if self.p.repairMode=="throw" then error("repair failed") end
    if self.p.repairMode=="noop" then return end
    if self.p.repairMode=="partial" then amount=amount/2 end
    if self.p.DestructibleObjectReference then
        local p=self.p.DestructibleObjectReference.p
        p.Health=math.min(self.p.maximum, p.Health+amount)
    else self.p.durability=math.min(self.p.maximum,self.p.durability+amount) end
end
function methods:OverrideHealth(value)
    assert(type(value)=="number")
    H.repairs=H.repairs+1
    if self.p.repairMode=="throw" then error("health write failed") end
    if self.p.repairMode=="noop" then return end
    if self.p.repairMode=="partial" then value=(self.p.Health+value)/2 end
    self.p.Health=value
end
function methods:GetAllActorsOfClass(pc, cls, out)
    assert(pc==H.pc and cls.p.path==BOAT and type(out)=="table")
    H.scans=H.scans+1
    if H.failScan then error("world scan failed") end
    for i,v in ipairs(H.boats) do out[i]=v end
end
local fields = { Pawn=true, OwningWorld=true, DestructibleObjectComponent=true,
    DestructibleObjectReference=true, DestructibleObjectProperties=true, Health=true,
    RotationSpeedToLinearSpeed=true }
function object(class, name, props)
    H.id=H.id+1
    local p={ class=class, name=name or ('object'..H.id), id=H.id, valid=true,
        authority=true, destroying=false, x=0, attached={}, modules={}, components={} }
    for k,v in pairs(props or {}) do p[k]=v end
    return setmetatable({p=p},{
        __index=function(o,k)
            if k=='IsValid' then
                H.accesses=H.accesses+1
                if o.p.poison then error('STALE WRAPPER EVEN IsValid') end
                return methods[k]
            end
            H.accesses=H.accesses+1
            assert(o.p.valid and not o.p.poison, 'stale object accessed: '..k)
            if methods[k] then return methods[k] end
            if fields[k] then return o.p[k] end
            error('unknown member: '..k)
        end,
        __newindex=function(o,k,v)
            assert(o.p.valid and not o.p.poison, 'stale write')
            assert(k=='RotationSpeedToLinearSpeed', 'unapproved write: '..k)
            assert(type(v)=='number')
            H.writes=H.writes+1
            if o.p.rejectWrite then error('write rejected') end
            if o.p.ignoreWrite then return end
            o.p[k]=v
            if o.p.throwAfterWrite then o.p.throwAfterWrite=false error('error after mutation') end
        end
    })
end
H.world=object('World','World1')
H.level=object('Level','Level1',{OwningWorld=H.world})
H.pawn=object('Character','Player',{level=H.level})
H.pc=object('Controller','Controller',{Pawn=H.pawn, level=H.level})
H.gs=object('GameplayStatics','GameplayStatics')
H.classes={}
for _,c in ipairs({BOAT, MODULE, DAMAGE}) do H.classes[c]=object('Class',c,{path=c}) end
function StaticFindObject(path)
    if path=='/Script/Engine.Default__GameplayStatics' then return H.gs end
    return H.classes[path]
end
package.preload.UEHelpers=function() return {GetPlayerController=function() return H.pc end} end
print=function(s) H.logs[#H.logs+1]=s end
function makeBoat(name,x)
    local boat=object(BOAT,name,{level=H.level,x=x or 0})
    H.boats[#H.boats+1]=boat
    return boat
end
function attach(boat, actor, parent)
    actor.p.parent=parent or boat
    actor.p.level=boat.p.level
    boat.p.attached[#boat.p.attached+1]=actor
    return actor
end
function makeRotor(boat,name,value)
    return attach(boat,object(ROTOR,name,{RotationSpeedToLinearSpeed=value or 10}))
end
function makeDamage(owner, health, max)
    local damage=object(DAMAGE,owner.p.name..'_damage'..#owner.p.components,
        {owner=owner,Health=health,DestructibleObjectProperties={Health=max or 100}})
    owner.p.components[#owner.p.components+1]=damage
    return damage
end
function makeModule(owner, value, mode, nativeBoat)
    local module=object(MODULE,owner.p.name..'_module'..#owner.p.components,
        {owner=owner,durability=value,maximum=100,repairMode=mode})
    owner.p.components[#owner.p.components+1]=module
    if nativeBoat then nativeBoat.p.modules[#nativeBoat.p.modules+1]=module end
    return module
end
local ui={}
function ui.card(parent,title) return {} end
function ui.infoRow(page,parent,label,fn) H.labels[label]=fn end
function ui.button(parent,label,kind,fn) H.buttons[label]=fn end
function ui.buttonGrid(parent,n,items)
    assert(n==2)
    for _,item in ipairs(items) do H.buttons[item[1]]=item[2] end
end
function ui.add(parent,item) end
function ui.paragraph(s) local w={text=s} H.lastParagraph=w return w end
function ui.setText(w,s) w.text=s end
function ui.addRefresher(page,fn) H.refreshers[#H.refreshers+1]=fn end
function ui.stepperRow(page,parent,label,opts) H.step=opts end
function ui.toggleRow(page,parent,label,get,set,note) H.getActive=get H.toggle=set end
function ui.toast(msg,kind) H.message=msg H.kind=kind end
feature=require('features.boat')
feature.addToPage(ui, {}, {})
function selectBoat() return H.buttons['Boot waehlen']() end
function speed(index) H.step.set(index) H.toggle(true) end
function repair() H.buttons['Alles reparieren']() end
function drain(n) for i=1,(n or 400) do feature.tick() end end
function contains(s) assert(H.message and H.message:find(s,1,true), (H.message or 'nil')..' expected '..s) end
function refresh() for _,fn in ipairs(H.refreshers) do fn() end end
'''


class BoatBehavior(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        scripts = (ROOT / "Warden/Scripts").as_posix()
        self.lua.execute(f'package.path = {json.dumps(scripts + "/?.lua;")} .. package.path')
        self.lua.execute(HARNESS)

    def run_lua(self, code):
        self.lua.execute(code)

    def test_exports_and_ui_do_no_world_scans(self):
        self.run_lua('''
            local n=0 for key in pairs(feature) do n=n+1 end assert(n==5)
            assert(feature.addToPage and feature.tick and feature.onWorldChanged)
            drain(); refresh(); assert(H.scans==0 and H.lists==0 and H.writes==0)
            assert(not H.getActive())
        ''')

    def test_cylinders_go_to_inventory_without_retrofit_or_actor_deletion(self):
        self.run_lua('''
          local paths={}
          package.loaded['features.packages']={
            load=function(p) paths[#paths+1]=p;return {path=p} end,
            give=function(item,n,target) assert(n==4 and target==1);return 4 end,
          }
          for kind=1,3 do for level=1,5 do assert(feature.giveCylinder(kind,level,4)) end end
          assert(#paths==15 and paths[5]:find('ElectricEngineCylinder_CheatBooster',1,true))
          assert(paths[15]:find('PetrolEngineCylinder_CheatBooster',1,true))
          assert(H.scans==0 and H.writes==0 and H.repairs==0)
          assert(not feature.giveCylinder(0,1,4) and not feature.giveCylinder(1,1,1000))
          package.loaded['features.packages'].give=function() return 2,'voll' end
          local ok,msg=feature.giveCylinder(1,1,4)
          assert(not ok and msg:find('2/4',1,true))
        ''')
        source=BOAT_FILE.read_text(encoding='utf-8')
        self.assertNotIn('"SetBoatEnginesLevel"',source)
        self.assertNotIn(':DestroyActor(',source)

    def test_nearest_boat_only_and_reversible_without_compounding(self):
        self.run_lua('''
            a=makeBoat('A',500); b=makeBoat('B',1000)
            r=makeRotor(a,'RotorA',10); other=makeRotor(b,'RotorB',17)
            assert(selectBoat()); assert(H.labels.Zielboot()=='A'); assert(H.scans==1)
            speed(6); assert(r.RotationSpeedToLinearSpeed==20 and other.RotationSpeedToLinearSpeed==17)
            H.step.set(7); assert(r.RotationSpeedToLinearSpeed==30)
            local scans,lists=H.scans,H.lists
            drain(); refresh(); assert(H.scans==scans and H.lists==lists)
            H.toggle(false); assert(r.RotationSpeedToLinearSpeed==10 and not H.getActive())
        ''')

    def test_possessed_boat_beats_nearest_without_scan(self):
        self.run_lua('''
            a=makeBoat('Near',50); b=makeBoat('Driven',50000)
            H.pc.p.Pawn=b
            assert(selectBoat()); assert(H.labels.Zielboot()=='Driven' and H.scans==0)
        ''')

    def test_player_attachment_chain_beats_nearest(self):
        self.run_lua('''
            a=makeBoat('Near',50); b=makeBoat('OnBoard',1000)
            seat=attach(b,object('Seat','Seat'))
            H.pawn.p.parent=seat
            assert(selectBoat()); assert(H.labels.Zielboot()=='OnBoard' and H.scans==0)
        ''')

    def test_range_world_and_non_boat_class_are_checked(self):
        self.run_lua('''
            a=makeBoat('Far',10001)
            b=makeBoat('OtherWorld',1); b.p.level=object('Level','OtherLevel',{OwningWorld=object('World','Other')})
            c=makeBoat('NotBoat',2); c.p.class='Forklift'
            assert(not selectBoat()); assert(H.writes==0)
            contains('Kein Boot')
        ''')

    def test_client_cannot_mutate(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'Rotor'); a.p.authority=false
            speed(6); repair(); drain()
            assert(H.writes==0 and H.repairs==0 and not H.getActive())
            contains('nur Host')
        ''')

    def test_no_rotor_fails_honestly(self):
        self.run_lua('''
            a=makeBoat('A'); speed(6)
            assert(not H.getActive() and H.writes==0); contains('Kein unterstuetzter')
        ''')

    def test_module_ownership_does_not_pull_in_another_boats_rotor(self):
        self.run_lua('''
            a=makeBoat('A'); b=makeBoat('B',500)
            own=makeRotor(a,'Own'); other=makeRotor(b,'Other')
            makeModule(other,30,nil,a)
            speed(6); assert(own.RotationSpeedToLinearSpeed==20 and other.RotationSpeedToLinearSpeed==10)
        ''')

    def test_transaction_rolls_back_after_partial_write_failure(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R',10); s=makeRotor(a,'S',15)
            s.p.throwAfterWrite=true
            speed(6)
            assert(not H.getActive() and r.RotationSpeedToLinearSpeed==10 and s.RotationSpeedToLinearSpeed==15)
            contains('nicht bestaetigt')
        ''')

    def test_restore_failure_keeps_snapshot_for_retry(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); speed(6)
            r.p.rejectWrite=true; H.toggle(false)
            assert(not H.getActive() and r.RotationSpeedToLinearSpeed==20); contains('1 offen')
            r.p.rejectWrite=false; feature.tick()
            assert(r.RotationSpeedToLinearSpeed==10); contains('1 Rotorwerte restauriert')
        ''')

    def test_external_edit_is_preserved_and_other_rotors_restored(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); s=makeRotor(a,'S',15); speed(6)
            r.p.RotationSpeedToLinearSpeed=77
            feature.tick()
            assert(not H.getActive() and r.RotationSpeedToLinearSpeed==77 and s.RotationSpeedToLinearSpeed==15)
            contains('1 externe Aenderungen')
        ''')

    def test_detachment_stops_and_restores_without_retarget(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); speed(6)
            r.p.parent=nil; local scans=H.scans; drain(3)
            assert(not H.getActive() and r.RotationSpeedToLinearSpeed==10 and H.scans==scans)
        ''')

    def test_pawn_change_in_same_world_restores(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); speed(6)
            H.pc.p.Pawn=object('Character','Respawn',{level=H.level})
            feature.tick()
            assert(not H.getActive() and r.RotationSpeedToLinearSpeed==10)
            assert(H.labels.Zielboot()=='Keines')
        ''')

    def test_pawn_disappears_in_same_world_restores(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); speed(6)
            H.pc.p.Pawn=nil; feature.tick()
            assert(not H.getActive() and r.RotationSpeedToLinearSpeed==10)
        ''')

    def test_world_callback_never_touches_even_validity_of_old_refs(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); speed(6); repair()
            a.p.poison=true; r.p.poison=true; H.pc.p.poison=true; H.pawn.p.poison=true
            local accesses,writes=H.accesses,H.writes
            feature.onWorldChanged(); feature.tick(); refresh()
            assert(H.accesses==accesses and H.writes==writes)
            assert(not H.getActive() and H.step.index()==3 and H.labels.Zielboot()=='Keines')
        ''')

    def test_tick_world_detection_discards_without_reading_old_boat(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); speed(6)
            a.p.poison=true; r.p.poison=true
            H.level=object('Level','NewLevel',{OwningWorld=object('World','World2')})
            H.pc=object('Controller','Controller2',{level=H.level,Pawn=object('Character','Player2',{level=H.level})})
            local writes=H.writes
            feature.tick(); assert(H.writes==writes and not H.getActive())
            assert(H.labels.Zielboot()=='Keines')
        ''')

    def test_pending_restore_is_discarded_when_world_changes_later(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); speed(6)
            r.p.rejectWrite=true
            H.pc.p.Pawn=object('Character','NewPawn',{level=H.level})
            feature.tick(); assert(not H.getActive())
            r.p.poison=true; a.p.poison=true
            H.level=object('Level','NewLevel',{OwningWorld=object('World','World2')})
            H.pc=object('Controller','Controller2',{level=H.level,Pawn=object('Character','Player2',{level=H.level})})
            local writes=H.writes; feature.tick(); assert(H.writes==writes)
            local accesses=H.accesses; feature.tick(); assert(H.accesses==accesses)
        ''')

    def test_reset_button_after_world_change_does_not_restore_old_world(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); speed(6)
            a.p.poison=true; r.p.poison=true
            local accesses=H.accesses; refresh(); H.labels.Zielboot(); assert(H.accesses==accesses)
            H.level=object('Level','NewLevel',{OwningWorld=object('World','World2')})
            H.pc=object('Controller','Controller2',{level=H.level,Pawn=object('Character','Player2',{level=H.level})})
            local writes=H.writes; H.buttons.Originaltempo(); assert(H.writes==writes)
            assert(not H.getActive() and H.labels.Zielboot()=='Keines')
        ''')

    def test_leaving_range_restores_session(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); speed(6)
            H.pawn.p.x=20000; feature.tick()
            assert(not H.getActive() and r.RotationSpeedToLinearSpeed==10)
        ''')

    def test_broken_modules_and_non_module_structural_components_repaired(self):
        self.run_lua('''
            a=makeBoat('A'); hull=makeDamage(a,20)
            actor=attach(a,object('ModuleActor','BrokenModule'))
            broken=makeModule(actor,0) -- not returned by GetAllModules
            structure=attach(a,object('Structure','Rail'))
            d1=makeDamage(structure,15); d2=makeDamage(structure,60)
            nested=attach(a,object('Structure','Nested'),structure); d3=makeDamage(nested,25)
            b=makeBoat('Other',500); other=makeDamage(b,10)
            repair(); drain()
            assert(broken:GetDurability()==100 and hull.Health==100 and d1.Health==100 and d2.Health==100 and d3.Health==100)
            assert(other.Health==10 and H.repairs==5)
            contains('Repariert: 1 Module, 4 Bauteile'); contains('fehlgeschlagen: 0')
            assert(H.kind=='good')
        ''')

    def test_native_duplicates_and_shared_damage_not_counted_twice(self):
        self.run_lua('''
            a=makeBoat('A'); actor=attach(a,object('ModuleActor','Module'))
            d=makeDamage(actor,10); m=makeModule(actor,10,nil,a); m.p.DestructibleObjectReference=d
            a.p.modules[#a.p.modules+1]=m; a.p.attached[#a.p.attached+1]=actor
            a.p.namedOut=true
            repair(); drain()
            assert(H.repairs==1 and d.Health==100); contains('Repariert: 1 Module, 0 Bauteile')
            contains('Intakt: 0')
        ''')

    def test_noop_throw_partial_and_healthy_have_distinct_counts(self):
        self.run_lua('''
            a=makeBoat('A')
            for i,mode in ipairs({'noop','throw','partial','healthy','normal'}) do
                actor=attach(a,object('ModuleActor','M'..i))
                makeModule(actor,mode=='healthy' and 100 or 20,mode,a)
            end
            repair(); drain()
            contains('Repariert: 1 Module, 0 Bauteile'); contains('Intakt: 1')
            contains('teilweise: 1'); contains('fehlgeschlagen: 2'); assert(H.kind=='bad')
        ''')

    def test_refill_is_scoped_to_selected_boat_and_verified(self):
        self.run_lua('''
            a=makeBoat('A'); b=makeBoat('B',500)
            m=makeModule(attach(a,object('ModuleActor','Battery')),100,nil,a)
            m.p.amount=20; m.p.capacity=100
            other=makeModule(attach(b,object('ModuleActor','OtherBattery')),100,nil,b)
            other.p.amount=5; other.p.capacity=100
            H.buttons['Tanks & Batterien fuellen'](); drain()
            assert(m.p.amount==100 and other.p.amount==5 and H.refills==1)
            contains('Aufgefuellt: 1 Module'); assert(H.kind=='good')
        ''')

    def test_structural_noop_does_not_fake_success(self):
        self.run_lua('''
            a=makeBoat('A'); d=makeDamage(a,10); d.p.repairMode='noop'
            repair(); drain()
            assert(d.Health==10); contains('Repariert: 0 Module, 0 Bauteile'); contains('fehlgeschlagen: 1')
        ''')

    def test_foreign_unattached_and_invalid_components_are_skipped(self):
        self.run_lua('''
            a=makeBoat('A'); b=makeBoat('B',500)
            foreign=attach(b,object('ModuleActor','Foreign')); m=makeModule(foreign,10,nil,a)
            dead=attach(a,object('ModuleActor','Dead')); m2=makeModule(dead,10,nil,a); dead.p.valid=false
            repair(); drain()
            assert(m:GetDurability()==10 and m2.p.durability==10 and H.repairs==0)
            contains('uebersprungen:'); assert(H.kind=='bad')
        ''')

    def test_discovery_failure_does_not_report_all_repaired(self):
        self.run_lua('''
            a=makeBoat('A'); a.p.failModules=true
            repair(); drain(); assert(H.repairs==0); contains('nicht gestartet')
            a.p.failModules=false; a.p.failComponents=true
            repair(); drain(); contains('Lesefehler: 2'); assert(H.kind=='bad')
        ''')

    def test_repair_budget_no_tick_world_scan_and_reentry_guard(self):
        self.run_lua('''
            a=makeBoat('A')
            for i=1,100 do makeDamage(attach(a,object('Structure','Part'..i)),20) end
            repair(); local scans,lists=H.scans,H.lists
            repair(); contains('laeuft bereits')
            assert(not selectBoat()); contains('Reparatur laeuft')
            for i=1,100 do
                local repairs,components=H.repairs,H.componentLists
                feature.tick()
                assert(H.repairs-repairs<=12 and H.componentLists-components<=4)
            end
            assert(H.repairs==100 and H.scans==scans and H.lists==lists)
            contains('100 Bauteile')
        ''')

    def test_repair_cancels_on_pawn_change_and_never_replays(self):
        self.run_lua('''
            a=makeBoat('A'); d=makeDamage(a,20); repair()
            H.pc.p.Pawn=object('Character','NewPawn',{level=H.level})
            drain(); assert(H.repairs==0 and d.Health==20)
            contains('Reparatur abgebrochen nach 0')
        ''')

    def test_invalid_numbers_fail_closed(self):
        self.run_lua('''
            a=makeBoat('A'); r=makeRotor(a,'R'); r.p.RotationSpeedToLinearSpeed=0/0
            speed(6); assert(not H.getActive() and H.writes==0)
            H.step.set(0/0); H.step.set(1.5); H.step.set(1000); assert(H.step.index()==6)
            r.p.RotationSpeedToLinearSpeed=3e38
            speed(8); assert(H.writes==0 and not H.getActive())
            d=makeDamage(a,20,0); repair(); drain(); contains('fehlgeschlagen: 1')
        ''')


class ReflectionContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(os.environ.get("WARDEN_JMAP", str(ROOT / "reference/Voyage-0.10.0.653173.jmap.gz")))
        if not path.exists() and "WARDEN_JMAP" not in os.environ:
            raise unittest.SkipTest("Optional game reflection dump absent; set WARDEN_JMAP to run ABI checks")
        if path.suffix == ".pkl":
            # Only opt into the explicitly provided trusted local pickle.
            with path.open("rb") as handle:
                cls.dump = pickle.load(handle)
        else:
            with gzip.open(path, "rt", encoding="utf-8") as handle:
                cls.dump = json.load(handle)
        cls.dump = cls.dump.get("objects", cls.dump)

    def test_every_function_parameters_including_return_fit_512_bytes(self):
        for path, (size, names) in FUNCTIONS.items():
            with self.subTest(function=path):
                fn = self.dump[path]
                self.assertEqual(fn["type"], "Function")
                self.assertEqual(fn["properties_size"], size)
                self.assertLessEqual(size, 512)
                props = [p for p in fn["properties"] if "CPF_Parm" in p.get("flags", "")]
                self.assertEqual([p["name"] for p in props if "CPF_ReturnParm" not in p["flags"]], names)
                for prop in props:
                    self.assertLessEqual(prop["offset"] + prop["size"] * prop["array_dim"], 512)
                    self.assertNotIn(prop["type"], ["SoftObjectProperty", "SoftClassProperty"])

    def test_dynamic_calls_have_audited_signatures(self):
        source = BOAT_FILE.read_text(encoding="utf-8")
        source = re.sub(r"--\[\[.*?\]\]", "", source, flags=re.S)
        source = re.sub(r"--[^\n]*", "", source)
        invoked = set(re.findall(r'(?:call|outArray)\([^,\n]+,\s*"([A-Za-z_]+)"', source))
        allowed = {path.split(":")[1] for path in FUNCTIONS} | {"IsA"}
        self.assertTrue(invoked)
        self.assertEqual(invoked - allowed, set())
        for forbidden in [":SetStyle(", "SoftObjectPtr", "core.console(", "core.setCvar(", "FindAllOf("]:
            self.assertNotIn(forbidden, source)
        self.assertNotIn("Kein Nachweis im Spiel", source)
        self.assertNotIn("autoritativ", source)

    def test_rotor_property_is_instance_float_not_savegame_and_movement_deprecated(self):
        props = {p["name"]: p for p in self.dump["/Script/Voyage.VoyageModuleRotorActor"]["properties"]}
        prop = props["RotationSpeedToLinearSpeed"]
        self.assertEqual((prop["type"], prop["offset"], prop["size"]), ("FloatProperty", 0x314, 4))
        self.assertNotIn("CPF_SaveGame", prop["flags"])
        props = {p["name"]: p for p in self.dump["/Script/Voyage.VoyageBoatPawn"]["properties"]}
        self.assertIn("CPF_Deprecated", props["BoatMovementComponent"]["flags"])

    def test_direct_health_struct_read_avoids_oversized_function(self):
        struct = self.dump["/Script/Voyage.VoyageDestructibleObjectProperties"]
        self.assertEqual(struct["properties_size"], 0x320)
        health = next(p for p in struct["properties"] if p["name"] == "Health")
        self.assertEqual((health["type"], health["offset"], health["size"]), ("FloatProperty", 0, 4))
        oversized = self.dump["/Script/Voyage.VoyageDestructibleObjectComponent:UpdateDestructibleObjectProperties"]
        self.assertGreater(oversized["properties_size"], 512)
        self.assertNotIn('"UpdateDestructibleObjectProperties"', BOAT_FILE.read_text(encoding="utf-8"))

    def test_ue4ss_source_buffer_out_array_and_property_dispatch(self):
        source = Path(os.environ.get("WARDEN_UE4SS_SOURCE", str(SCRATCH / "ue4ss-src-527a")))
        if not (source / "LuaUFunction.hpp").exists():
            self.skipTest("UE4SS source not present; set WARDEN_UE4SS_SOURCE to check it")
        header = (source / "LuaUFunction.hpp").read_text(encoding="utf-8")
        cpp = (source / "LuaUObject.cpp").read_text(encoding="utf-8")
        self.assertRegex(header, r"uint8_t\s+data\[0x200\]")
        self.assertIn("auto reuse_same_table =", cpp)
        self.assertIn("param->IsA<Unreal::FArrayProperty>()", cpp)
        self.assertIn("iterate_array_and_turn_into_lua_table", cpp)
        self.assertIn("auto handle_unreal_property_value(", cpp)


if __name__ == "__main__":
    unittest.main(verbosity=2)
