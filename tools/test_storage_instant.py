"""Behavior regressions for resource targeting and native-owned craft completion."""
from pathlib import Path
import unittest
from lupa.lua54 import LuaRuntime

ROOT=Path(__file__).resolve().parent.parent
HARNESS=r'''
H={id=0,actors={},fabs={},logs={},scans=0}
function obj(t)
 H.id=H.id+1;t.id=H.id
 function t:IsValid() return not self.dead end
 function t:HasAuthority() return self.authority~=false end
 function t:IsActorBeingDestroyed() return self.dead==true end
 function t:GetLevel() return {OwningWorld=self.world or world,IsValid=function() return true end} end
 function t:IsA(c) return true end
 return t
end
world=obj({});pawn=obj({x=0})
core={isValid=function(o) return o and o.IsValid and o:IsValid() end,
 address=function(o) return o and o.id end,pawn=function() return pawn end,
 location=function(o) if o then return o.x or 0,0,0 end end,
 find=function(p) return p end,shortName=function(o) return tostring(o.id) end,
 log=function(s) H.logs[#H.logs+1]=s end,
 actorsOf=function(c) H.scans=H.scans+1;assert(c=='/Script/Voyage.VoyageModuleActor');return H.actors end,
 outList=function(_,fn) return fn() end, unwrap=function(v) return v end}
package.loaded.core=core
function FindAllOf(c) H.scans=H.scans+1;assert(c=='VoyageFabricatorComponent');return H.fabs end
function storage(primary,x,energy,capacity)
 local m=obj({primary=primary,values=energy or {},caps=capacity or {},writes={}})
 function m:GetPrimaryResourceType() return self.primary end
 function m:IsDisabled() return self.disabled==true end
 function m:GetResourceAmount(k) return self.values[k] or 0 end
 function m:GetMaxResourceAmount(k) return self.caps[k] or 0 end
 function m:ForceAddResource(k,v) self.writes[#self.writes+1]=k;if not self.reject then self.values[k]=(self.values[k] or 0)+v end end
 local a=obj({x=x,modules={m}})
 function a:K2_GetComponentsByClass(c) return self.modules end
 H.actors[#H.actors+1]=a
 return m,a
end
function craft(x,buildable)
 local item=obj({build=buildable==true})
 function item:IsBuildable() return self.build end
 function item:IsCraftable() return true end
 local owner=obj({x=x})
 local f=obj({owner=owner,paused=false,active=true,CurrentFabricationId=17,ItemQueue={{Item=item}},
 ProgressTimerMax=10,ProgressTimerRemaining=8,CurrentResourcesConsumed={energy=20},OutputTimer=3})
 function f:GetOwner() return self.owner end
 function f:IsPaused() return self.paused end
 function f:IsFabricating() return self.active end
 function f:GetQueueIndexByFabricationId(id) assert(id==17);return 0 end
 H.fabs[#H.fabs+1]=f
 return f,owner,item
end
S=require('features.storage');I=require('features.instant')
'''

class StorageInstant(unittest.TestCase):
 def setUp(self):
  self.lua=LuaRuntime(unpack_returned_tuples=True)
  self.lua.execute(f'package.path="{(ROOT/"Warden/Scripts").as_posix()}/?.lua;"..package.path')
  self.lua.execute(HARNESS)
 def test_detached_medium_battery_and_secondary_components(self):
  self.lua.execute('''
   m,a=storage(0,100,{[0]=5},{[0]=40000});n,b=storage(0,150,{[0]=0},{[0]=100})
   a.modules[#a.modules+1]=n -- component discovered twice is charged once
   assert(S.fill(0));assert(m.values[0]==40000 and n.values[0]==100)
   assert(#m.writes==1 and #n.writes==1)
  ''')
 def test_resource_buttons_do_not_mix_tanks(self):
  self.lua.execute('''
   diesel=storage(16,100,{[16]=5},{[16]=500,[1]=500})
   petrol=storage(1,100,{[1]=0},{[1]=800,[16]=800})
   battery=storage(0,100,{[0]=5},{[0]=400})
   assert(S.fill(16));assert(diesel.values[16]==500)
   assert(#petrol.writes==0 and #battery.writes==0)
   assert(S.fill(1));assert(petrol.values[1]==800 and not diesel.values[1])
  ''')
 def test_radius_world_destroyed_and_authority(self):
  self.lua.execute('''
   far=storage(0,5001,{}, {[0]=10});foreign,a=storage(0,1,{}, {[0]=10});a.world=obj({})
   gone,b=storage(0,1,{}, {[0]=10});b.dead=true
   client,c=storage(0,1,{}, {[0]=10});c.authority=false
   assert(not S.fill(0));assert(#far.writes+#foreign.writes+#gone.writes+#client.writes==0)
  ''')
 def test_failed_refill_is_not_reported_as_success(self):
  self.lua.execute('''m=storage(0,0,{[0]=5},{[0]=100});m.reject=true;assert(not S.fill(0));assert(m.values[0]==5)''')
 def test_zero_capacity_and_full(self):
  self.lua.execute('''
   m=storage(0,0,{},{});assert(not S.fill(0));assert(#m.writes==0)
   n=storage(0,0,{[0]=100},{[0]=100});assert(S.fill(0));assert(#n.writes==0)
  ''')
 def test_disabled_module_masked_zero_never_gets_overfilled(self):
  self.lua.execute('''
   m=storage(0,0,{[0]=50},{[0]=100});m.disabled=true
   assert(not S.fill(0));assert(#m.writes==0 and m.values[0]==50)
  ''')
 def test_all_material_resource_buttons_have_unique_verified_enum(self):
  self.lua.execute('''
   seen={};for _,row in ipairs(S.resources) do assert(not seen[row[1]]);seen[row[1]]=true end
   for _,id in ipairs({0,16,1,10,2,4,3,11,17,12}) do assert(seen[id]) end
   assert(not S.fill(14))
  ''')
 def test_instant_off_has_no_scans_or_writes(self):
  self.lua.execute('''f=craft(0);I.tick();assert(H.scans==0 and f.ProgressTimerMax==10)''')
 def test_inventory_and_machine_preserve_fraction_and_costs(self):
  self.lua.execute('''
   a=craft(0);a.owner=pawn;b=craft(100)
   I.setEnabled(true);I.tick()
   assert(a.ProgressTimerMax==0.05 and b.ProgressTimerMax==0.05)
   assert(math.abs(a.ProgressTimerRemaining/a.ProgressTimerMax-0.8)<1e-6)
   assert(a.CurrentResourcesConsumed.energy==20 and a.ItemQueue[1].Item and a.OutputTimer==3)
   assert(a.ProgressTimerRemaining>0) -- never force-finish, native update still owns completion
  ''')
 def test_paused_unstarted_build_far_and_other_world_untouched(self):
  self.lua.execute('''
   paused=craft(0);paused.paused=true
   idle=craft(0);idle.active=false
   build=craft(0,true);far=craft(5001)
   foreign,o=craft(0);o.world=obj({})
   I.setEnabled(true);I.tick()
   for _,f in ipairs(H.fabs) do assert(f.ProgressTimerMax==10) end
  ''')
 def test_disable_and_world_change_stop_future_acceleration(self):
  self.lua.execute('''
   a=craft(0);I.setEnabled(true);I.tick();I.setEnabled(false)
   b=craft(0);I.tick();assert(b.ProgressTimerMax==10)
   I.setEnabled(true);I.onWorldChanged();I.tick();assert(b.ProgressTimerMax==10)
  ''')
 def test_invalid_numbers_and_missing_queue_are_ignored(self):
  self.lua.execute('''
   a=craft(0);a.ProgressTimerMax=0/0
   b=craft(0);b.ItemQueue={}
   c=craft(0);c.ProgressTimerRemaining=math.huge
   I.setEnabled(true);I.tick();assert(b.ProgressTimerMax==10 and c.ProgressTimerMax==10)
  ''')
if __name__=='__main__': unittest.main()
